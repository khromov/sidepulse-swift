import Foundation
import SidePulseCore

/// `sidepulse doctor [--json]`: hook installation per provider (`HookDoctor`),
/// followed by the app and CLI locations.
enum DoctorCommand: CLICommand {
    static let spec = CommandSpec(
        name: "doctor",
        synopsis: "[--json]",
        summary: "Check hook installation and the app",
        options: [OptionSpec("json", help: "print the report as JSON")]
    )

    static func run(_ arguments: ParsedArguments, _ env: CLIEnvironment) throws -> Int32 {
        let infos = HookDoctor.inspectAll(paths: env.paths, runningExecutable: env.executablePath)
        let app = DoctorAppInfo.gather(env)
        if arguments.has("json") {
            var report = HookDoctor.renderJSON(infos).objectValue ?? JSONObject()
            report["app"] = .object(app.json)
            env.stdout.line(JSONValue.object(report).serialized(pretty: true))
        } else {
            var text = HookDoctor.renderText(infos)
            while text.hasSuffix("\n") { text.removeLast() }
            env.stdout.line(text)
            env.stdout.line(app.text)
        }
        return ExitCode.ok
    }
}

/// The app part of the doctor report.
public struct DoctorAppInfo: Equatable, Sendable {
    public var appBinary: String?
    public var plistPath: String
    public var plistInstalled: Bool
    public var ping: PingReply?
    public var socketPath: String
    /// The CLI path `install` writes into new hook commands (`HookCLIPath.resolve`);
    /// what the installed hooks call is checked per provider.
    public var cliPath: String?
    /// `HookCLIPath.foreignLinkNote`: ~/.local/bin/sidepulse is not the SidePulse CLI.
    public var cliNote: String?

    public init(appBinary: String?, plistPath: String, plistInstalled: Bool, ping: PingReply?, socketPath: String,
                cliPath: String?, cliNote: String? = nil) {
        self.appBinary = appBinary; self.plistPath = plistPath; self.plistInstalled = plistInstalled
        self.ping = ping; self.socketPath = socketPath; self.cliPath = cliPath; self.cliNote = cliNote
    }

    /// Reads the plist from disk and pings the socket (no launchctl calls).
    static func gather(_ env: CLIEnvironment) -> DoctorAppInfo {
        let plist = env.launchAgent.plistPath
        return DoctorAppInfo(
            appBinary: env.appLocator.locate(),
            plistPath: plist.path,
            plistInstalled: FileManager.default.fileExists(atPath: plist.path),
            ping: PingReply(data: env.app.request("ping", JSONObject(), 0.5)),
            socketPath: env.paths.socketPath,
            cliPath: HookCLIPath.resolve(paths: env.paths, runningExecutable: env.executablePath),
            cliNote: HookCLIPath.foreignLinkNote(paths: env.paths, runningExecutable: env.executablePath)
        )
    }

    /// ```
    /// app:
    ///   binary: /Applications/SidePulse.app/Contents/MacOS/SidePulse | not found (run scripts/install.sh)
    ///   launch agent: <plist> (installed|missing)
    ///   running: yes (pid 123, version 0.1.0) | no
    ///   socket: <path>
    /// cli: <path> (written by install) | not found (…)
    ///   note: <cliNote>                                   (only when set)
    /// ```
    public var text: String {
        let details = ping?.details ?? ""
        let running = ping == nil ? "no" : details.isEmpty ? "yes" : "yes (\(details))"
        var lines = [
            "app:",
            "  binary: \(appBinary ?? "not found (run scripts/install.sh)")",
            "  launch agent: \(plistPath) (\(plistInstalled ? "installed" : "missing"))",
            "  running: \(running)",
            "  socket: \(socketPath)",
            "cli: " + (cliPath.map { "\($0) (written by install)" } ?? "not found (\(HookCLIPath.notFoundMessage))"),
        ]
        if let cliNote { lines.append("  note: \(cliNote)") }
        return lines.joined(separator: "\n")
    }

    /// `{binary, launch_agent_plist, launch_agent_installed, running, pid, version, socket_path, cli_path, cli_note}`
    public var json: JSONObject {
        [
            "binary": JSONValue(appBinary),
            "launch_agent_plist": .string(plistPath),
            "launch_agent_installed": .bool(plistInstalled),
            "running": .bool(ping != nil),
            "pid": ping?.pid.map { JSONValue($0) } ?? .null,
            "version": JSONValue(ping?.version),
            "socket_path": .string(socketPath),
            "cli_path": JSONValue(cliPath),
            "cli_note": JSONValue(cliNote),
        ]
    }
}
