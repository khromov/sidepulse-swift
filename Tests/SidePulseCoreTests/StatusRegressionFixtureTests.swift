import XCTest
@testable import SidePulseCore

final class StatusRegressionFixtureTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StatusFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private struct Expected {
        var key: String
        var mode: AgentMode
        var event: String
        var name: String
        var updatedAt: String
        var origin: String?
        var tool: String?
        var message: String?
    }

    /// Produced by `sidepulse.collector.AgentMonitor._latest_statuses()` (Python).
    private let expected: [Expected] = [
        Expected(key: "claude:agent:a1b2c3d4e5f6a7b8c", mode: .completed, event: "SubagentStop",
                 name: "demo-app: Add a --verbose flag to ... and document it (agent a1b2c3d4)",
                 updatedAt: "2026-09-20T10:00:23+00:00", origin: "Claude in VS Code", tool: nil,
                 message: "Found 3 call sites in src/cli.ts."),
        Expected(key: "claude:session:aaaa1111-2222-4333-8444-555566667777", mode: .waitingForInput, event: "Notification",
                 name: "demo-app: Add a --verbose flag to ... and document it (aaaa1111)",
                 updatedAt: "2026-09-20T10:01:30+00:00", origin: "Claude in VS Code", tool: nil,
                 message: "Claude is waiting for your input"),
        Expected(key: "claude:session:bbbb2222-3333-4444-8555-666677778888", mode: .completed, event: "Stop",
                 name: "web: Fix the flaky login test in LoginForm.test.tsx (bbbb2222)",
                 updatedAt: "2026-09-20T10:02:05+00:00", origin: "Claude Code CLI", tool: nil,
                 message: "All done.\nAnything else?"),
        Expected(key: "claude:session:cccc3333-4444-4555-8666-777788889999", mode: .toolRunning, event: "PreToolUse",
                 name: "dev: hello there (cccc3333)", updatedAt: "2026-09-20T10:00:52+00:00",
                 origin: "Claude in VS Code", tool: "Bash", message: nil),
        Expected(key: "claude:session:dddd4444-5555-4666-8777-888899990000", mode: .blockedError, event: "PostToolUse",
                 name: "demo-app: Run the release script (dddd4444)", updatedAt: "2026-09-20T10:01:01.005000+00:00",
                 origin: "Claude Code CLI", tool: "Bash", message: nil),
        Expected(key: "claude:session:eeee5555-6666-4777-8888-999900001111", mode: .completed, event: "Stop",
                 name: "demo-app: Tidy up imports (eeee5555)", updatedAt: "2026-09-20T10:01:20+00:00",
                 origin: "Claude in VS Code", tool: nil, message: "Imports sorted."),
        Expected(key: "codex:session:01a0a7a7-0000-7000-8000-00000000a7a7", mode: .idleReady, event: "Interrupt",
                 name: "demo-app: Summarize the changelog (01a0a7a7)", updatedAt: "2026-09-20T10:00:23+00:00",
                 origin: "Codex CLI", tool: nil, message: nil),
        Expected(key: "codex:session:01a0b8b8-0000-7000-8000-00000000b8b8", mode: .waitingForInput, event: "PermissionRequest",
                 name: "demo-app: Start the dev server (01a0b8b8)", updatedAt: "2026-09-20T10:00:32+00:00",
                 origin: "Codex CLI", tool: "Bash", message: nil),
        Expected(key: "codex:session:01a0f6f6-0000-7000-8000-00000000f6f6", mode: .completed, event: "Stop",
                 name: "demo-app: Diagnose high CPU usage (01a0f6f6)", updatedAt: "2026-09-20T10:00:12+00:00",
                 origin: "Codex CLI", tool: nil, message: "It was the file watcher.\n<!-- sidepulse:done -->"),
    ]

    private func scanFixture() throws -> [AgentStatus] {
        let logs = tmp.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data((StatusRegressionFixture.claudeLog + "\n").utf8).write(to: logs.appendingPathComponent("claude.jsonl"))
        try Data((StatusRegressionFixture.codexLog + "\n").utf8).write(to: logs.appendingPathComponent("codex.jsonl"))
        let indexURL = tmp.appendingPathComponent("home/.codex/session_index.jsonl")
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((StatusRegressionFixture.codexSessionIndex + "\n").utf8).write(to: indexURL)
        let index = CodexSessionIndex(url: indexURL)
        return LogScanner.scan(sources: [SourceInfo(provider: "codex", path: logs.appendingPathComponent("codex.jsonl").path),
                                         SourceInfo(provider: "claude", path: logs.appendingPathComponent("claude.jsonl").path)],
                               codexTitle: index.title(forSession:))
    }

    func testFixtureMatchesPythonCollector() throws {
        let rows = try scanFixture()
        XCTAssertEqual(rows.map(\.agentID).sorted(), expected.map(\.key))
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.agentID, $0) })
        for row in expected {
            let status = try XCTUnwrap(byKey[row.key], row.key)
            XCTAssertEqual(status.mode, row.mode, row.key)
            XCTAssertEqual(status.eventName, row.event, row.key)
            XCTAssertEqual(status.displayName, row.name, row.key)
            XCTAssertEqual(TimeFormat.pythonISO(status.updatedAt), row.updatedAt, row.key)
            XCTAssertEqual(status.origin, row.origin, row.key)
            XCTAssertEqual(status.toolName, row.tool, row.key)
            XCTAssertEqual(status.message, row.message, row.key)
        }
    }

    func testFixtureSnapshotMatchesPython() throws {
        let rows = try scanFixture()
        let now = TimeFormat.parse("2026-09-20T10:02:10Z")!
        let snapshot = SnapshotBuilder.build(statuses: rows, config: MonitorConfig(), now: now, sources: [])
        XCTAssertEqual(snapshot.aggregate.mode, .blockedError)
        XCTAssertEqual(snapshot.aggregate.activeCount, 4)
        XCTAssertEqual(snapshot.aggregate.staleCount, 5)
        XCTAssertEqual(snapshot.aggregate.representative?.agentID, "claude:session:dddd4444-5555-4666-8777-888899990000")
        XCTAssertEqual(snapshot.statuses.map(\.agentID), [
            "claude:session:dddd4444-5555-4666-8777-888899990000",
            "claude:session:aaaa1111-2222-4333-8444-555566667777",
            "codex:session:01a0b8b8-0000-7000-8000-00000000b8b8",
            "claude:session:cccc3333-4444-4555-8666-777788889999",
        ])
        XCTAssertEqual(snapshot.staleStatuses.map { "\($0.agentID) \($0.mode.rawValue)" }, [
            "claude:session:bbbb2222-3333-4444-8555-666677778888 completed",
            "claude:session:eeee5555-6666-4777-8888-999900001111 completed",
            "claude:agent:a1b2c3d4e5f6a7b8c completed",
            "codex:session:01a0f6f6-0000-7000-8000-00000000f6f6 completed",
            "codex:session:01a0a7a7-0000-7000-8000-00000000a7a7 idle_ready",
        ])
    }

    func testFixtureLiveReplayMatchesScan() throws {
        // Timestamp order mirrors what the socket would deliver.
        let scanned = try scanFixture()
        let index = CodexSessionIndex(url: tmp.appendingPathComponent("home/.codex/session_index.jsonl"))
        let sources = [SourceInfo(provider: "codex", path: tmp.appendingPathComponent("logs/codex.jsonl").path),
                       SourceInfo(provider: "claude", path: tmp.appendingPathComponent("logs/claude.jsonl").path)]
        let live = StatusEngine(codexTitle: index.title(forSession:))
        for event in LogScanner.orderedEvents(sources: sources, maxLines: 100) { live.ingest(event) }
        XCTAssertEqual(live.statuses.values.sorted { $0.agentID < $1.agentID }, scanned.sorted { $0.agentID < $1.agentID })
        XCTAssertEqual(live.pendingPermissions, ["codex:session:01a0b8b8-0000-7000-8000-00000000b8b8": ["Bash\u{0}npm run dev"]])

        let store = LatestStore(url: tmp.appendingPathComponent("latest.json"))
        let now = TimeFormat.parse("2026-09-20T10:02:10Z")!
        try store.save(Array(live.statuses.values), now: now)
        let restarted = StatusEngine(codexTitle: index.title(forSession:))
        restarted.load(store.load())
        XCTAssertFalse(restarted.reconcile(with: scanned), "recovery finds nothing newer")
        XCTAssertEqual(restarted.snapshot(now: now).statuses.map(\.agentID),
                       SnapshotBuilder.build(statuses: scanned, config: MonitorConfig(), now: now, sources: []).statuses.map(\.agentID))
    }
}
