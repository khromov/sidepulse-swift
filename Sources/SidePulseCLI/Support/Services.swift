import Foundation
import SidePulseCore

public struct AppConnection {
    public var isRunning: () -> Bool
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

    public static let unavailable = AppConnection(isRunning: { false }, request: { _, _, _ in nil })

    public static func isOK(_ reply: Data?) -> Bool {
        guard let reply else { return false }
        return String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }
}

public struct PingReply: Equatable, Sendable {
    public var pid: Int?
    public var version: String?
    /// Builds before the reply carried a kind were always the app.
    public var kind: InstanceKind

    public init(pid: Int?, version: String?, kind: InstanceKind = .app) {
        self.pid = pid; self.version = version; self.kind = kind
    }

    public init?(data: Data?) {
        guard let data, let value = try? JSONValue.parse(data), value["ok"]?.boolValue == true else { return nil }
        pid = value["pid"]?.intValue
        version = value["version"]?.stringValue
        kind = value["kind"]?.stringValue.flatMap(InstanceKind.init(rawValue:)) ?? .app
    }

    public var isHeadless: Bool { kind == .headless }

    public var details: String {
        [isHeadless ? "headless 'sidepulse run'" : nil, pid.map { "pid \($0)" }, version.map { "version \($0)" }]
            .compactMap { $0 }.joined(separator: ", ")
    }

    public var headlessOwner: String { "a headless 'sidepulse run'" + (pid.map { " (pid \($0))" } ?? "") }

    public var headlessStopHint: String { "stop it with Ctrl-C in its terminal" + (pid.map { " or 'kill \($0)'" } ?? "") }
}

public struct SnapshotLoader {
    public var fromApp: (CLIEnvironment) -> MonitorSnapshot?
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
            let index = CodexSessionIndex(paths: env.paths)
            let statuses = LogScanner.scan(sources: LogScanner.defaultSources(paths: env.paths), config: config,
                                           codexTitle: { index.title(forSession: $0) })
            // Show the live log files (not the rotated `.1` copies) as sources.
            let shown = HookProvider.allCases.map {
                SourceInfo(provider: $0.rawValue, path: env.paths.logFile(for: $0.rawValue).path)
            }
            return SnapshotBuilder.build(statuses: statuses, config: config, now: env.now(), sources: shown)
        }
    )
}

/// Injectable so tests never touch real agent configs.
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

/// Injectable so `app`, `setup` and `settings` never touch launchd in tests.
public struct LaunchAgentOperations {
    public var plistPath: URL
    /// Returns whether the plist changed.
    public var install: (_ programArguments: [String], _ start: Bool) throws -> Bool
    public var uninstall: () throws -> Void
    public var start: (_ restart: Bool) throws -> Void
    public var stop: () throws -> Void
    public var status: () -> LaunchAgentStatus
    public var installedProgram: () -> [String]?
    public var openApp: (_ appBinary: String) throws -> Void

    public init(plistPath: URL,
                install: @escaping ([String], Bool) throws -> Bool,
                uninstall: @escaping () throws -> Void,
                start: @escaping (Bool) throws -> Void,
                stop: @escaping () throws -> Void,
                status: @escaping () -> LaunchAgentStatus,
                installedProgram: @escaping () -> [String]?,
                openApp: @escaping (String) throws -> Void) {
        self.plistPath = plistPath; self.install = install; self.uninstall = uninstall; self.start = start
        self.stop = stop; self.status = status; self.installedProgram = installedProgram; self.openApp = openApp
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
            openApp: { try openApp(binary: $0) }
        )
    }

    /// Bundled binaries go through `open -a` so Launch Services starts them like a Finder double-click.
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
