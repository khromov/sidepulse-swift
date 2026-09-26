import Foundation
import XCTest
@testable import SidePulseCLI
import SidePulseCore

final class CLIOutputCapture {
    private(set) var text = ""
    var output: TextOutput { TextOutput { [unowned self] in self.text += $0 } }
}

final class CLIFakeLaunchAgent {
    var state = LaunchAgentStatus(installed: false, loaded: false)
    var installChanged = true
    var installError: Error?
    private(set) var installs: [(arguments: [String], start: Bool)] = []
    private(set) var starts: [Bool] = []
    private(set) var stops = 0
    private(set) var uninstalls = 0
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
            openApp: { [unowned self] binary in opened.append(binary) }
        )
    }

    static func plist(_ arguments: [String]) -> String { "PLIST " + arguments.joined(separator: " ") }
}

final class CLIFakeApp {
    var running = false
    /// A command missing here gets no answer.
    var replies: [String: Data] = [:]
    /// Runs before the reply is looked up, so a test can script the app starting after N tries.
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
        let fm = FileManager.default
        root = Self.makeShortTempDir()
        home = root.appendingPathComponent("home", isDirectory: true)
        stateDir = root.appendingPathComponent("state", isDirectory: true)
        applicationsDir = root.appendingPathComponent("Applications", isDirectory: true)
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        try? fm.createDirectory(at: applicationsDir, withIntermediateDirectories: true)
        clock = now

        var variables = ["SIDEPULSE_HOME": stateDir.path, "HOME": home.path, "SIDEPULSE_CLI_PATH": Self.cliPath]
        variables.merge(extra) { $1 }
        let paths = SidePulsePaths(environment: variables, home: home)
        precondition(paths.socketPath.hasPrefix(root.path), "the socket must live in the temp root")
        env = CLIEnvironment(
            variables: variables,
            paths: paths,
            stdout: stdout.output,
            stderr: stderr.output,
            stdin: .terminal,
            executablePath: "/usr/local/bin/sidepulse",
            now: { [unowned self] in clock },
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

    /// `TMPDIR` can be long enough to push the socket past the 104-byte `sun_path` limit into the real
    /// `/tmp/sidepulse-<uid>` fallback, so the root is made directly under `/tmp`.
    static func makeShortTempDir() -> URL {
        var template = Array("/tmp/spcli.XXXXXX".utf8CString)
        let created = template.withUnsafeMutableBufferPointer { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return mkdtemp(base) != nil
        }
        precondition(created, "mkdtemp failed")
        let path = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    var paths: SidePulsePaths { env.paths }

    @discardableResult
    func run(_ arguments: [String]) -> Int32 { SidePulseCLI.run(arguments, environment: env) }

    @discardableResult
    func makeExecutable(_ url: URL) -> String {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: Data("#!/bin/sh\nexit 0\n".utf8),
                      attributes: [.posixPermissions: 0o755])
        return url.path
    }

    @discardableResult
    func installFakeApp() -> String {
        makeExecutable(AppLocator.appBinary(inBundle: applicationsDir.appendingPathComponent(AppLocator.bundleName)))
    }
}

/// Must match the values used to generate `CLIPythonGolden`.
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
