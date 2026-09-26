import Foundation
import SidePulseCore

/// `sidepulse status [--json] [--all] [--offline]`: one-shot agent status.
///
/// Asks the running app (`status` socket command); when it does not answer, or
/// with `--offline`, rebuilds the snapshot from the hook logs with the same
/// state machine and the user's timeouts.
enum StatusCommand: CLICommand {
    static let spec = CommandSpec(
        name: "status",
        synopsis: "[--json] [--all] [--offline]",
        summary: "Show the current agent status",
        details: "Asks the running SidePulse app. When the app is not running (or with --offline)\n"
            + "the status is rebuilt from the hook logs.",
        options: [
            OptionSpec("json", help: "print the snapshot as JSON"),
            OptionSpec("all", help: "also list stale agents"),
            OptionSpec("offline", help: "read the hook logs instead of asking the app"),
        ]
    )

    static func run(_ arguments: ParsedArguments, _ env: CLIEnvironment) throws -> Int32 {
        let (snapshot, origin) = env.snapshots.load(env, offline: arguments.has("offline"))
        if arguments.has("json") {
            env.stdout.line(snapshot.toJSON().serialized(pretty: true))
        } else {
            env.stdout.line(origin.headerLine)
            env.stdout.line(StatusText.render(snapshot, includeStale: arguments.has("all")))
        }
        return ExitCode.ok
    }
}

extension SnapshotLoader {
    /// The app's snapshot unless `offline`, else (or when the app does not answer)
    /// the one rebuilt from the logs.
    func load(_ env: CLIEnvironment, offline: Bool) -> (MonitorSnapshot, SnapshotOrigin) {
        if !offline, let snapshot = fromApp(env) { return (snapshot, .app) }
        return (fromLogs(env), offline ? .logsOffline : .logsAppNotRunning)
    }
}
