import Foundation
import SidePulseCore

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
            return ping?.isHeadless == false ? ExitCode.ok : ExitCode.failure
        case "stop":
            // Booting out a loaded job would not stop an owner that launchd did not start.
            if let running = AppLauncher.runningInstance(env), !running.underLaunchd {
                let ping = running.ping
                throw CommandFailure(message: ping.isHeadless
                    ? "\(ping.headlessOwner) drives the LEDs, not the app; \(ping.headlessStopHint)."
                    : "SidePulse is running outside launchd\(AppLauncher.pidText(ping)); quit it from the menu bar.")
            }
            guard agent.status().loaded else {
                env.stdout.line("app: not running")
                return ExitCode.ok
            }
            try agent.stop()
            env.stdout.line("app: stopped")
            if FileManager.default.fileExists(atPath: agent.plistPath.path) {
                env.stdout.line(plist + " (kept: the app starts again at login; 'sidepulse app uninstall' removes it)")
            }
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

    /// A child ending on the forwarded SIGINT/SIGTERM counts as a clean exit.
    static func foreground(_ env: CLIEnvironment) throws -> Int32 {
        guard let binary = env.appLocator.locate() else { throw CommandFailure(message: env.appLocator.notFoundMessage) }
        if env.app.isRunning() {
            throw CommandFailure(message: AppLauncher.ownerRefusal(
                env, app: "the SidePulse app is already running (stop it first: sidepulse app stop).",
                headlessAlternative: " first"))
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

/// Every path pings first because a second copy would only find the socket taken and exit.
enum AppLauncher {
    static func runningInstance(_ env: CLIEnvironment) -> (ping: PingReply, underLaunchd: Bool)? {
        guard let ping = PingReply(data: env.app.request("ping", JSONObject(), 0.5)) else { return nil }
        let status = env.launchAgent.status()
        return (ping, status.loaded && ping.pid != nil && status.pid == ping.pid)
    }

    static func pidText(_ ping: PingReply) -> String { ping.pid.map { " (pid \($0))" } ?? "" }

    /// For `leds`, `run` and `app --foreground`, which cannot start while anything owns the socket.
    static func ownerRefusal(_ env: CLIEnvironment, app appMessage: String, headlessAlternative: String) -> String {
        guard let ping = PingReply(data: env.app.request("ping", JSONObject(), 0.5)), ping.isHeadless else {
            return appMessage
        }
        return "\(ping.headlessOwner) already drives the LEDs; \(ping.headlessStopHint)\(headlessAlternative)."
    }

    private static func headlessStartHint(_ ping: PingReply) -> String {
        "\(ping.headlessOwner) already drives the LEDs; \(ping.headlessStopHint), then run 'sidepulse app start'"
    }

    /// Without a LaunchAgent plist the app opens for this session only, since writing the plist
    /// would turn Launch at Login back on.
    static func start(_ env: CLIEnvironment, restart: Bool) throws -> (outcome: String, note: String?) {
        let agent = env.launchAgent
        if let running = runningInstance(env) {
            let pid = pidText(running.ping)
            if running.ping.isHeadless { throw CommandFailure(message: headlessStartHint(running.ping) + ".") }
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

    static func install(_ env: CLIEnvironment, binary: String) throws -> String {
        let agent = env.launchAgent
        guard let running = runningInstance(env) else {
            let changed = try agent.install([binary], true)
            return "\(changed ? "installed" : "already installed") and started"
        }
        let pid = pidText(running.ping)
        let changed = try agent.install([binary], false)
        let installed = changed ? "installed" : "already installed"
        if running.ping.isHeadless { return "\(installed), not started: \(headlessStartHint(running.ping))" }
        guard running.underLaunchd else {
            return "\(installed), not started: SidePulse already runs "
                + "outside launchd\(pid); the LaunchAgent takes over at the next login"
        }
        guard changed else { return "already installed and running\(pid)" }
        _ = try agent.install([binary], true) // reloads the changed plist
        return "updated and restarted"
    }
}
