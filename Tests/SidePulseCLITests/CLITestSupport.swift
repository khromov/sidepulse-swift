import Foundation
import XCTest
@testable import SidePulseCLI
import SidePulseCore

/// Collects everything written to a `TextOutput`.
final class CLIOutputCapture {
    private(set) var text = ""
    var output: TextOutput { TextOutput { [unowned self] in self.text += $0 } }
}

/// Records the calls made to `LaunchAgentOperations`.
final class CLIFakeLaunchAgent {
    var state = LaunchAgentStatus(installed: false, loaded: false)
    var installChanged = true
    var installError: Error?
    var legacyMessages: [String] = []
    private(set) var installs: [(arguments: [String], start: Bool)] = []
    private(set) var starts: [Bool] = []
    private(set) var stops = 0
    private(set) var uninstalls = 0
    private(set) var migrations: [Bool] = []
    /// App binaries started without the LaunchAgent (`openApp`).
    private(set) var opened: [String] = []

    func operations(plistPath: URL) -> LaunchAgentOperations {
        LaunchAgentOperations(
            plistPath: plistPath,
            install: { [unowned self] arguments, start in
                if let installError { throw installError }
                installs.append((arguments, start))
                try FileManager.default.createDirectory(at: plistPath.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try CLIFakeLaunchAgent.plist(arguments).write(to: plistPath, atomically: true, encoding: .utf8)
                return installChanged
            },
            uninstall: { [unowned self] in uninstalls += 1 },
            start: { [unowned self] restart in starts.append(restart) },
            stop: { [unowned self] in stops += 1 },
            status: { [unowned self] in state },
            installedProgram: {
                guard let text = try? String(contentsOf: plistPath, encoding: .utf8), text.hasPrefix("PLIST ") else { return nil }
                return text.dropFirst("PLIST ".count).split(separator: " ").map(String.init)
            },
            openApp: { [unowned self] binary in opened.append(binary) },
            migrateLegacy: { [unowned self] dryRun in
                migrations.append(dryRun)
                return legacyMessages
            }
        )
    }

    static func plist(_ arguments: [String]) -> String { "PLIST " + arguments.joined(separator: " ") }
}

/// A scripted app on the other end of the socket.
final class CLIFakeApp {
    var running = false
    /// Replies per command name; missing = no answer.
    var replies: [String: Data] = [:]
    /// Called before answering a command (e.g. to "start" the app after N tries).
    var onRequest: ((String) -> Void)?
    private(set) var requests: [String] = []

    var connection: AppConnection {
        AppConnection(
            isRunning: { [unowned self] in running },
            request: { [unowned self] command, _, _ in
                requests.append(command)
                onRequest?(command)
                return replies[command]
            }
        )
    }
}

/// A `CLIEnvironment` in a temp directory with captured output and test doubles.
/// Nothing here touches the user's real files, launchd or the real app socket.
final class CLIHarness {
    let root: URL
    let home: URL
    let stateDir: URL
    let applicationsDir: URL
    let stdout = CLIOutputCapture()
    let stderr = CLIOutputCapture()
    let launchAgent = CLIFakeLaunchAgent()
    let app = CLIFakeApp()
    var clock: Date
    var env: CLIEnvironment!

    static let cliPath = "/opt/sidepulse/bin/sidepulse"

    init(variables extra: [String: String] = [:], now: Date = CLIFixtures.now) {
        // Short temp paths keep the socket path under the sun_path limit.
        let fm = FileManager.default
        root = fm.temporaryDirectory
            .appendingPathComponent("spcli-\(UUID().uuidString.prefix(8))", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        stateDir = root.appendingPathComponent("state", isDirectory: true)
        applicationsDir = root.appendingPathComponent("Applications", isDirectory: true)
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        try? fm.createDirectory(at: applicationsDir, withIntermediateDirectories: true)
        clock = now

        var variables = ["SIDEPULSE_HOME": stateDir.path, "HOME": home.path, "SIDEPULSE_CLI_PATH": Self.cliPath]
        variables.merge(extra) { $1 }
        let paths = SidePulsePaths(environment: variables, home: home)
        env = CLIEnvironment(
            variables: variables,
            paths: paths,
            stdout: stdout.output,
            stderr: stderr.output,
            stdin: .terminal,
            executablePath: "/usr/local/bin/sidepulse",
            now: { [unowned self] in clock },
            timeZone: TimeZone(identifier: "UTC")!,
            sleep: { [unowned self] seconds in clock = clock.addingTimeInterval(seconds) },
            app: app.connection,
            snapshots: SnapshotLoader(fromApp: { _ in nil }, fromLogs: { _ in MonitorSnapshot.empty(now: now) }),
            hooks: HookOperations(
                install: { _, _, _, _, _ in throw CommandFailure(message: "unexpected install") },
                uninstall: { _, _, _ in throw CommandFailure(message: "unexpected uninstall") }
            ),
            launchAgent: launchAgent.operations(plistPath: paths.launchAgentPlist()),
            systemApplicationsDir: applicationsDir
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var paths: SidePulsePaths { env.paths }

    @discardableResult
    func run(_ arguments: [String]) -> Int32 { SidePulseCLI.run(arguments, environment: env) }

    /// Creates an executable file (fake app binary) and returns its path.
    @discardableResult
    func makeExecutable(_ url: URL) -> String {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: Data("#!/bin/sh\nexit 0\n".utf8),
                      attributes: [.posixPermissions: 0o755])
        return url.path
    }

    /// Installs a fake `SidePulse.app` under the harness `/Applications`.
    @discardableResult
    func installFakeApp() -> String {
        makeExecutable(AppLocator.appBinary(inBundle: applicationsDir.appendingPathComponent(AppLocator.bundleName)))
    }
}

/// Snapshot values mirroring the ones used to generate `CLIPythonGolden`.
enum CLIFixtures {
    /// 2026-09-26T10:00:00Z
    static let now = Date(timeIntervalSince1970: 1_790_416_800)

    static func status(_ provider: String, _ key: String, _ name: String, _ mode: AgentMode, age: Double,
                       event: String, tool: String? = nil, cwd: String? = nil, origin: String? = nil,
                       stale: Bool = false) -> AgentStatus {
        AgentStatus(provider: provider, agentID: key, displayName: name, mode: mode,
                    updatedAt: now.addingTimeInterval(-age), eventName: event, cwd: cwd, toolName: tool,
                    origin: origin, stale: stale)
    }

    static let a = status("claude", "claude:session:abc", "proj: task (abc12345)", .toolRunning, age: 5.9,
                          event: "PreToolUse", tool: "Bash", cwd: "/tmp/proj", origin: "Claude Code CLI")
    static let b = status("codex", "codex:session:def", "A very long display name that will certainly be truncated here",
                          .waitingForInput, age: 125, event: "PermissionRequest",
                          cwd: "/Users/someone/Documents/GitHub/some-really-long-project")
    static let c = status("claude", "claude:session:ghi", "Done thing", .completed, age: 4000, event: "Stop", stale: true)
    static let d = status("codex", "codex:agent:x", "Sub agent", .working, age: 30, event: "PostToolUse", tool: "",
                          origin: "")

    static let sources = [SourceInfo(provider: "claude", path: "/state/logs/claude.jsonl"),
                          SourceInfo(provider: "codex", path: "/nonexistent/codex.jsonl")]

    static let snapshot = MonitorSnapshot(
        collectedAt: now, sources: sources,
        aggregate: AggregateStatus(mode: .waitingForInput, activeCount: 3, staleCount: 1, representative: b),
        statuses: [b, a, d], staleStatuses: [c])

    static let empty = MonitorSnapshot(
        collectedAt: now, sources: sources,
        aggregate: AggregateStatus(mode: .idleReady, activeCount: 0, staleCount: 0, representative: nil),
        statuses: [], staleStatuses: [])

    static func fileExists(_ path: String) -> Bool { path == "/state/logs/claude.jsonl" }
}
