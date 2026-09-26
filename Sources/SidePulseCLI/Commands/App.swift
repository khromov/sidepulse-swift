import Foundation
import SidePulseCore

/// `sidepulse app [start|stop|restart|status|install|uninstall] [--foreground]`
/// (alias `status-bar`): the menu-bar app and its LaunchAgent.
///
/// - `start` (default): start the app; see `AppLauncher.start`.
/// - `stop`: boot the agent out (the plist stays, so it returns at next login).
/// - `restart`: kickstart -k.
/// - `status`: plist / launchd / socket state; exit 0 only when the app answers.
/// - `install` / `uninstall`: write+start / boot out+delete the LaunchAgent.
/// - `--foreground`: run the app binary as a child process and wait for it.
enum AppCommand: CLICommand {
    static let subcommands = ["start", "stop", "restart", "status", "install", "uninstall"]

    static let spec = CommandSpec(
        name: "app",
        synopsis: "[start|stop|restart|status|install|uninstall] [--foreground]",
        summary: "Start, stop or inspect the menu-bar app",
        details: "'install' adds the LaunchAgent \(SidePulseConstants.launchAgentLabel) (starts at login);\n"
            + "'uninstall' removes it. 'stop' keeps it, so the app returns at the next login.",
        positionals: PositionalSpec(name: "action", choices: subcommands),
        options: [OptionSpec("foreground", help: "run the app in this terminal instead of via launchd")]
    )

    static func run(_ arguments: ParsedArguments, _ env: CLIEnvironment) throws -> Int32 {
        let action = arguments.positionals.first ?? "start"
        if arguments.has("foreground") {
            guard action == "start" else { throw UsageError("--foreground can only be combined with start") }
            return try foreground(env)
        }
        let agent = env.launchAgent
        let plist = "  plist: \(agent.plistPath.path)"
        switch action {
        case "status":
            let ping = PingReply(data: env.app.request("ping", JSONObject(), 0.5))
            env.stdout.line(AppStatusText.render(state: agent.status(), plistPath: agent.plistPath,
                                                 socketPath: env.paths.socketPath, ping: ping,
                                                 appBinary: env.appLocator.locate()))
            return ping != nil ? ExitCode.ok : ExitCode.failure
        case "stop":
            guard agent.status().loaded else {
                if env.app.isRunning() {
                    throw CommandFailure(message: "the app is running outside launchd; quit it from the menu bar.")
                }
                env.stdout.line("app: not running")
                return ExitCode.ok
            }
            try agent.stop()
            env.stdout.line("app: stopped")
            env.stdout.line(plist + " (kept: the app starts again at login; 'sidepulse app uninstall' removes it)")
        case "install":
            guard let binary = env.appLocator.locate() else { throw CommandFailure(message: env.appLocator.notFoundMessage) }
            env.stdout.line("app: \(try AppLauncher.install(env, binary: binary))")
            env.stdout.line(plist)
            env.stdout.line("  binary: \(binary)")
        case "uninstall":
            if FileManager.default.fileExists(atPath: agent.plistPath.path) || agent.status().loaded {
                try agent.uninstall()
                env.stdout.line("app: removed")
            } else {
                env.stdout.line("app: already removed")
            }
            env.stdout.line(plist)
        default: // start, restart
            let launch = try AppLauncher.start(env, restart: action == "restart")
            env.stdout.line("app: \(launch.outcome)")
            env.stdout.line(plist)
            if let note = launch.note { env.stdout.line("  note: \(note)") }
        }
        return ExitCode.ok
    }

    /// Runs the app binary as a child and returns its exit status. Ctrl-C / SIGTERM
    /// are forwarded; the child ending on one of them counts as a clean exit.
    static func foreground(_ env: CLIEnvironment) throws -> Int32 {
        guard let binary = env.appLocator.locate() else { throw CommandFailure(message: env.appLocator.notFoundMessage) }
        if env.app.isRunning() {
            throw CommandFailure(message: "the SidePulse app is already running (stop it first: sidepulse app stop).")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        do {
            try process.run()
        } catch {
            throw CommandFailure(message: "could not start \(binary): \(ErrorText.describe(error))")
        }
        // Installed after launch so the child does not inherit ignored signals.
        let trap = SignalTrap { number in
            if process.isRunning { kill(process.processIdentifier, number) }
        }
        process.waitUntilExit()
        trap.cancel()
        if process.terminationReason == .uncaughtSignal {
            let number = process.terminationStatus
            return number == SIGINT || number == SIGTERM ? ExitCode.ok : 128 + number
        }
        return process.terminationStatus
    }
}

/// Starting the app (`app start|restart|install`, `setup`, `settings`). Every path
/// pings first: a second copy would only find the socket taken and exit.
enum AppLauncher {
    /// The instance answering `ping`, and whether it is the LaunchAgent's own
    /// (launchd reports the same pid). nil when nothing answers.
    static func runningInstance(_ env: CLIEnvironment) -> (ping: PingReply, underLaunchd: Bool)? {
        guard let ping = PingReply(data: env.app.request("ping", JSONObject(), 0.5)) else { return nil }
        let status = env.launchAgent.status()
        return (ping, status.loaded && ping.pid != nil && status.pid == ping.pid)
    }

    /// ` (pid 123)` or "".
    private static func pidText(_ ping: PingReply) -> String { ping.pid.map { " (pid \($0))" } ?? "" }

    /// Starts the app without changing the login item: through launchd when the
    /// LaunchAgent plist exists, otherwise for this session only (`openApp`), since
    /// writing the plist would turn Launch at Login back on. A plist that runs
    /// another binary is started as it is, with a note. A running app is left
    /// alone (`restart` kickstarts only the LaunchAgent's own instance).
    static func start(_ env: CLIEnvironment, restart: Bool) throws -> (outcome: String, note: String?) {
        let agent = env.launchAgent
        if let running = runningInstance(env) {
            let pid = pidText(running.ping)
            guard running.underLaunchd else {
                if restart {
                    throw CommandFailure(message: "SidePulse is running outside launchd\(pid); "
                        + "quit it from the menu bar, then run 'sidepulse app start'.")
                }
                return ("already running outside launchd\(pid)", nil)
            }
            guard restart else { return ("already running\(pid)", nil) }
            try agent.start(true)
            return ("restarted", nil)
        }
        let binary = env.appLocator.locate()
        guard FileManager.default.fileExists(atPath: agent.plistPath.path) else {
            guard let binary else { throw CommandFailure(message: env.appLocator.notFoundMessage) }
            try agent.openApp(binary)
            return ("started (Launch at Login is off; 'sidepulse app install' turns it on)", nil)
        }
        try agent.start(restart)
        var note: String?
        if let binary, let program = agent.installedProgram(), program != [binary] {
            note = "the LaunchAgent runs \(program.first ?? "?"); 'sidepulse app install' points it at \(binary)"
        }
        return (restart ? "restarted" : "started", note)
    }

    /// Writes the LaunchAgent plist and starts it. When SidePulse already runs
    /// outside launchd only the plist is written (the agent takes over at the next
    /// login); an unchanged agent that is already running is left alone.
    static func install(_ env: CLIEnvironment, binary: String) throws -> String {
        let agent = env.launchAgent
        guard let running = runningInstance(env) else {
            let changed = try agent.install([binary], true)
            return "\(changed ? "installed" : "already installed") and started"
        }
        let pid = pidText(running.ping)
        let changed = try agent.install([binary], false)
        guard running.underLaunchd else {
            return "\(changed ? "installed" : "already installed"), not started: SidePulse already runs "
                + "outside launchd\(pid); the LaunchAgent takes over at the next login"
        }
        guard changed else { return "already installed and running\(pid)" }
        _ = try agent.install([binary], true) // reloads the changed plist
        return "updated and restarted"
    }
}
