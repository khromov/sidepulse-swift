import Foundation
import SidePulseCore

enum LiveCommand: CLICommand {
    static let spec = CommandSpec(
        name: "live",
        synopsis: "[--interval 1] [--recent-seconds 3600] [--all] [--no-color] [--offline]",
        summary: "Live full-screen dashboard of agent status",
        details: "Redraws every --interval seconds until Ctrl-C. Colors are off with --no-color,\n"
            + "when NO_COLOR is set, or when stdout is not a terminal.",
        options: [
            OptionSpec("interval", value: "SECONDS", help: "refresh interval (default 1)"),
            OptionSpec("recent-seconds", value: "SECONDS", help: "hide agents idle longer (default 3600; 0 = all)"),
            OptionSpec("all", help: "show every known agent, including stale ones"),
            OptionSpec("no-color", help: "disable ANSI colors"),
            OptionSpec("offline", help: "read the hook logs instead of asking the app"),
        ]
    )

    static func run(_ arguments: ParsedArguments, _ env: CLIEnvironment) throws -> Int32 {
        var options = LiveDashboardOptions()
        options.interval = try arguments.double("interval", default: 1, minimum: 0, exclusive: true)
        options.recentSeconds = try arguments.double("recent-seconds", default: 3600, minimum: 0)
        options.includeStale = arguments.has("all")
        options.color = LiveDashboard.shouldUseColor(noColorFlag: arguments.has("no-color"),
                                                     environment: env.variables, stdoutIsTTY: env.stdoutIsTTY)
        options.timeZone = env.timeZone

        let trap = SignalTrap()
        defer { trap.cancel() }
        loop(env, options: options, offline: arguments.has("offline"), wait: trap.wait)
        return ExitCode.ok
    }

    /// `frames` bounds the loop for tests.
    static func loop(_ env: CLIEnvironment, options: LiveDashboardOptions, offline: Bool, frames: Int? = nil,
                     wait: (TimeInterval) -> Bool) {
        if env.stdoutIsTTY { env.stdout.write(LiveDashboard.hideCursor) }
        defer { if env.stdoutIsTTY { env.stdout.write(LiveDashboard.showCursor) } }
        var drawn = 0
        repeat {
            let (snapshot, origin) = env.snapshots.load(env, offline: offline)
            var frame = options
            frame.origin = origin
            frame.width = env.terminalColumns() ?? 120
            env.stdout.write(LiveDashboard.clearScreen + LiveDashboard.render(snapshot, options: frame) + "\n")
            drawn += 1
            if let frames, drawn >= frames { return }
        } while !wait(options.interval)
    }
}
