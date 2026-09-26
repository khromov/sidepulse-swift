import Foundation
import SidePulseCore

enum StatusCommand: CLICommand {
    static let spec = CommandSpec(
        name: "status",
        synopsis: "[--json] [--all] [--offline] [--watch]",
        summary: "Show the current agent status",
        details: "Asks the running SidePulse app. When the app is not running (or with --offline)\n"
            + "the status is rebuilt from the hook logs.",
        options: [
            OptionSpec("json", help: "print the snapshot as JSON"),
            OptionSpec("all", help: "also list stale agents"),
            OptionSpec("offline", help: "read the hook logs instead of asking the app"),
            OptionSpec("watch", help: "clear the screen and redraw every 2 seconds until Ctrl-C"),
        ]
    )

    static let watchInterval: TimeInterval = 2

    static func run(_ arguments: ParsedArguments, _ env: CLIEnvironment) throws -> Int32 {
        if arguments.has("watch") {
            watch(arguments, env)
        } else {
            show(arguments, env)
        }
        return ExitCode.ok
    }

    /// macOS has no `watch`; `frames` bounds the loop for tests.
    static func watch(_ arguments: ParsedArguments, _ env: CLIEnvironment, frames: Int = .max) {
        for frame in 0..<frames {
            if frame > 0 { env.sleep(watchInterval) }
            env.stdout.write("\u{1B}[H\u{1B}[2J")
            show(arguments, env)
        }
    }

    private static func show(_ arguments: ParsedArguments, _ env: CLIEnvironment) {
        let (snapshot, origin) = env.snapshots.load(env, offline: arguments.has("offline"))
        if arguments.has("json") {
            env.stdout.line(snapshot.toJSON().serialized(pretty: true))
        } else {
            env.stdout.line(origin.headerLine)
            env.stdout.line(StatusText.render(snapshot, includeStale: arguments.has("all")))
        }
    }
}

extension SnapshotLoader {
    func load(_ env: CLIEnvironment, offline: Bool) -> (MonitorSnapshot, SnapshotOrigin) {
        if !offline, let snapshot = fromApp(env) { return (snapshot, .app) }
        return (fromLogs(env), offline ? .logsOffline : .logsAppNotRunning)
    }
}
