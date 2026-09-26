import Foundation
import SidePulseCore

/// The running menu-bar app, reached over its Unix socket (see `IPCMessage`).
public struct AppConnection {
    /// `ping` round-trip succeeded.
    public var isRunning: () -> Bool
    /// Sends a command and returns the raw reply (nil when nobody answers).
    public var request: (_ command: String, _ args: JSONObject, _ timeout: TimeInterval) -> Data?

    public init(isRunning: @escaping () -> Bool,
                request: @escaping (_ command: String, _ args: JSONObject, _ timeout: TimeInterval) -> Data?) {
        self.isRunning = isRunning
        self.request = request
    }

    public static func socket(path: String) -> AppConnection {
        AppConnection(
            isRunning: { EventSocketClient.isServerRunning(socketPath: path) },
            request: { command, args, timeout in
                EventSocketClient.request(command, args: args, socketPath: path, timeout: timeout)
            }
        )
    }

    /// Nothing is listening (tests, or "app not running").
    public static let unavailable = AppConnection(isRunning: { false }, request: { _, _, _ in nil })

    /// True when the reply to a command is the plain `ok` acknowledgement.
    public static func isOK(_ reply: Data?) -> Bool {
        guard let reply else { return false }
        return String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }
}

/// Parsed reply to the `ping` command: `{"ok":true,"pid":123,"version":"0.1.0"}`.
public struct PingReply: Equatable, Sendable {
    public var pid: Int?
    public var version: String?

    public init(pid: Int?, version: String?) { self.pid = pid; self.version = version }

    /// nil unless the reply is a JSON object with `"ok": true`.
    public init?(data: Data?) {
        guard let data, let value = try? JSONValue.parse(data), value["ok"]?.boolValue == true else { return nil }
        pid = value["pid"]?.intValue
        version = value["version"]?.stringValue
    }

    /// `pid 123, version 0.1.0` (the parts that are known; may be empty).
    public var details: String {
        [pid.map { "pid \($0)" }, version.map { "version \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Where `status`, `live` and `leds` get their snapshot from.
public struct SnapshotLoader {
    /// The app's live snapshot (`status` socket command), nil when it does not answer.
    public var fromApp: (CLIEnvironment) -> MonitorSnapshot?
    /// Offline snapshot rebuilt from the provider hook logs.
    public var fromLogs: (CLIEnvironment) -> MonitorSnapshot

    public init(fromApp: @escaping (CLIEnvironment) -> MonitorSnapshot?,
                fromLogs: @escaping (CLIEnvironment) -> MonitorSnapshot) {
        self.fromApp = fromApp
        self.fromLogs = fromLogs
    }

    public static let standard = SnapshotLoader(
        fromApp: { env in
            guard let reply = env.app.request("status", JSONObject(), 2),
                  let json = try? JSONValue.parse(reply) else { return nil }
            return MonitorSnapshot.fromJSON(json)
        },
        fromLogs: { env in
            // Same staleness/retention as the app, from the user's settings.
            let config = SettingsStore(url: env.paths.settingsFile).load().monitorConfig
            let statuses = LogScanner.scan(sources: LogScanner.defaultSources(paths: env.paths), config: config)
            // Show the live log files (not the rotated `.1` copies) as sources.
            let shown = HookProvider.allCases.map {
                SourceInfo(provider: $0.rawValue, path: env.paths.logFile(for: $0.rawValue).path)
            }
            return SnapshotBuilder.build(statuses: statuses, config: config, now: env.now(), sources: shown)
        }
    )
}

/// Hook installers, injectable so command logic is testable without touching
/// real agent configs.
public struct HookOperations {
    public var install: (_ provider: HookProvider, _ paths: SidePulsePaths, _ cliPath: String,
                         _ dryRun: Bool, _ trust: Bool) throws -> InstallResult
    public var uninstall: (_ provider: HookProvider, _ paths: SidePulsePaths, _ dryRun: Bool) throws -> InstallResult

    public init(install: @escaping (HookProvider, SidePulsePaths, String, Bool, Bool) throws -> InstallResult,
                uninstall: @escaping (HookProvider, SidePulsePaths, Bool) throws -> InstallResult) {
        self.install = install
        self.uninstall = uninstall
    }

    public static let standard = HookOperations(
        install: { try HookInstaller.perform(.install, provider: $0, paths: $1, cliPath: $2, dryRun: $3, trust: $4) },
        uninstall: { try HookInstaller.perform(.uninstall, provider: $0, paths: $1, cliPath: nil, dryRun: $2) }
    )
}

/// The app's LaunchAgent, starting the app without it, and the legacy Python
/// cleanup; injectable so `app`, `setup` and `settings` never touch launchd in tests.
public struct LaunchAgentOperations {
    public var plistPath: URL
    /// Writes the plist if changed and (when `start`) boots the agent out/in and
    /// kickstarts it. Returns true if the plist changed.
    public var install: (_ programArguments: [String], _ start: Bool) throws -> Bool
    public var uninstall: () throws -> Void
    public var start: (_ restart: Bool) throws -> Void
    public var stop: () throws -> Void
    public var status: () -> LaunchAgentStatus
    /// ProgramArguments of the installed plist (nil when there is none).
    public var installedProgram: () -> [String]?
    /// Starts the app for this login session only, without a LaunchAgent.
    public var openApp: (_ appBinary: String) throws -> Void
    /// `LegacyPythonMigration.run`: removes Python-era LaunchAgents; returns messages.
    public var migrateLegacy: (_ dryRun: Bool) -> [String]

    public init(plistPath: URL,
                install: @escaping ([String], Bool) throws -> Bool,
                uninstall: @escaping () throws -> Void,
                start: @escaping (Bool) throws -> Void,
                stop: @escaping () throws -> Void,
                status: @escaping () -> LaunchAgentStatus,
                installedProgram: @escaping () -> [String]?,
                openApp: @escaping (String) throws -> Void,
                migrateLegacy: @escaping (Bool) -> [String]) {
        self.plistPath = plistPath; self.install = install; self.uninstall = uninstall; self.start = start
        self.stop = stop; self.status = status; self.installedProgram = installedProgram; self.openApp = openApp
        self.migrateLegacy = migrateLegacy
    }

    public static func launchd(paths: SidePulsePaths) -> LaunchAgentOperations {
        let manager = LaunchAgentManager(paths: paths)
        return LaunchAgentOperations(
            plistPath: paths.launchAgentPlist(label: manager.label),
            install: { try manager.install(programArguments: $0, start: $1) },
            uninstall: { try manager.uninstall() },
            start: { try manager.start(restart: $0) },
            stop: { try manager.stop() },
            status: { manager.status() },
            installedProgram: { manager.installedProgramArguments() },
            openApp: { try openApp(binary: $0) },
            migrateLegacy: { LegacyPythonMigration.run(paths: paths, dryRun: $0) }
        )
    }

    /// `/usr/bin/open -a <bundle>` for a bundled app binary (Launch Services starts
    /// it like a Finder double-click); a bare binary is spawned detached.
    static func openApp(binary: String) throws {
        let process = Process()
        if let bundle = HookCLIPath.enclosingBundle(of: binary) {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", bundle.path]
        } else {
            process.executableURL = URL(fileURLWithPath: binary)
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CommandFailure(message: "could not start \(binary): \(ErrorText.describe(error))")
        }
        guard process.executableURL?.path == "/usr/bin/open" else { return }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw CommandFailure(message: "open -a \(process.arguments?.last ?? binary) failed (\(process.terminationStatus))")
        }
    }
}
