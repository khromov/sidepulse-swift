import XCTest
@testable import SidePulseCore

final class StatusPersistenceTests: XCTestCase {
    private var tmp: URL!
    private let t0 = TimeFormat.parse("2026-09-20T10:00:00Z")!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StatusPersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ text: String, _ name: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func status(_ key: String, _ mode: AgentMode, _ offset: TimeInterval, stale: Bool = false) -> AgentStatus {
        AgentStatus(provider: "codex", agentID: "codex:session:\(key)", displayName: "\(key) name", mode: mode,
                    updatedAt: t0.addingTimeInterval(offset), eventName: "PreToolUse", sessionID: key, cwd: "/tmp/project",
                    toolName: "Bash", origin: "Codex UI", stale: stale)
    }

    // MARK: LatestStore

    func testLatestStoreRoundTripAndFormat() throws {
        let store = LatestStore(url: tmp.appendingPathComponent("state/latest.json"))
        let rows = [status("older", .working, -10), status("newer", .toolRunning, -5, stale: true)]
        try store.save(rows, now: t0)

        let text = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("{\n  \"statuses\": [\n    {\n      \"age_seconds\": 5.0,\n      \"agent_id\": \"codex:session:newer\""), text)
        XCTAssertTrue(text.hasSuffix("  \"updated_at\": \"2026-09-20T10:00:00+00:00\"\n}\n"))
        XCTAssertFalse(text.contains("\"stale\": true"), "entries are written with stale false")

        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.agentID), ["codex:session:newer", "codex:session:older"])
        var expectedNewer = rows[1]
        expectedNewer.stale = false
        XCTAssertEqual(loaded.first, expectedNewer)
        XCTAssertEqual(loaded.last, rows[0])
    }

    func testLatestStoreReloadReproducesModeAndOrigin() throws {
        let engine = StatusEngine()
        engine.ingest(provider: "codex", line: [
            "logged_at": .string(TimeFormat.pythonISO(t0)), "hook_event_name": .string("PreToolUse"),
            "session_id": .string("codex-session"), "cwd": .string("/tmp/project"), "tool_name": .string("Bash"),
            "agent_origin": .string("Codex UI"),
        ])
        let snapshot = engine.snapshot(now: t0)
        XCTAssertEqual(snapshot.aggregate.mode, .toolRunning)
        XCTAssertEqual(snapshot.statuses.first?.toolName, "Bash")
        XCTAssertEqual(snapshot.statuses.first?.origin, "Codex UI")

        let store = LatestStore(url: tmp.appendingPathComponent("latest.json"))
        try store.save(Array(engine.statuses.values), now: t0)
        let reloaded = StatusEngine()
        reloaded.load(store.load())
        XCTAssertEqual(reloaded.snapshot(now: t0).aggregate.mode, .toolRunning)
        XCTAssertEqual(reloaded.snapshot(now: t0).statuses.first?.origin, "Codex UI")
    }

    func testLatestStoreToleratesBadInput() throws {
        XCTAssertEqual(LatestStore(url: tmp.appendingPathComponent("missing.json")).load(), [])
        XCTAssertEqual(LatestStore(url: try write("{truncated", "corrupt.json")).load(), [])
        XCTAssertEqual(LatestStore(url: try write(#"{"statuses": {}}"#, "wrong.json")).load(), [])
        let mixed = try write(#"""
        {"updated_at": "2026-09-20T10:00:00+00:00", "statuses": [
          {"provider": "claude", "agent_id": "claude:session:ok", "display_name": "ok", "mode": "working",
           "updated_at": "2026-09-20T09:59:00+00:00", "event_name": "UserPromptSubmit"},
          {"provider": "claude", "agent_id": "claude:session:bad", "display_name": "bad", "mode": "sleeping",
           "updated_at": "2026-09-20T09:59:00+00:00", "event_name": "Stop"},
          "not an object"
        ]}
        """#, "mixed.json")
        XCTAssertEqual(LatestStore(url: mixed).load().map(\.agentID), ["claude:session:ok"])
    }

    // MARK: readRecentLines

    func testReadRecentLinesReturnsTailOnly() throws {
        let url = try write((1...10).map { "line \($0)" }.joined(separator: "\n") + "\n", "tail.jsonl")
        XCTAssertEqual(LogScanner.readRecentLines(url: url, maxLines: 3), ["line 8", "line 9", "line 10"])
        XCTAssertEqual(LogScanner.readRecentLines(url: url, maxLines: 50).count, 10)
        XCTAssertEqual(LogScanner.readRecentLines(url: url, maxLines: 0), [])
        XCTAssertEqual(LogScanner.readRecentLines(url: tmp.appendingPathComponent("nope.jsonl"), maxLines: 5), [])
    }

    func testReadRecentLinesSplitsOnNewlineOnly() throws {
        // Python's splitlines() would also split on U+2028 and drop half a JSON row.
        let url = try write("a\u{2028}b\r\n\n\nc\u{0B}d\n\u{85}e", "separators.jsonl")
        XCTAssertEqual(LogScanner.readRecentLines(url: url, maxLines: 10), ["a\u{2028}b\r", "c\u{0B}d", "\u{85}e"])
    }

    func testReadRecentLinesDropsThePartialFirstLineOfTheWindow() throws {
        let long = String(repeating: "x", count: 40_000)
        let lines = (0..<6).map { "\($0):\(long)" }
        let url = try write(lines.joined(separator: "\n") + "\n", "big.jsonl")
        XCTAssertEqual(LogScanner.readRecentLines(url: url, maxLines: 6), lines)
        // A window of two and a half lines starts mid-line, so only the last two come back whole.
        XCTAssertEqual(LogScanner.readRecentLines(url: url, maxLines: 6, tailBytes: 100_000), Array(lines.suffix(2)))
        let noNewline = try write("first\nsecond", "nonl.jsonl")
        XCTAssertEqual(LogScanner.readRecentLines(url: noNewline, maxLines: 1), ["second"])
    }

    func testReadRecentLinesKeepsInvalidUTF8Lossy() throws {
        let url = tmp.appendingPathComponent("bytes.jsonl")
        try Data([0x61, 0xFF, 0x62, 0x0A, 0x63, 0x0A]).write(to: url)
        XCTAssertEqual(LogScanner.readRecentLines(url: url, maxLines: 5), ["a\u{FFFD}b", "c"])
    }

    func testReadRecentLinesIgnoresADirectory() throws {
        XCTAssertEqual(LogScanner.readRecentLines(url: tmp, maxLines: 5), [])
    }

    // MARK: Restart recovery through files

    func testRecoveryFromLogsRewritesLatestState() throws {
        // Wired the way the runtime starts: load latest.json, reconcile with a log scan, save.
        let now = Date()
        func stamp(_ offset: TimeInterval) -> String { TimeFormat.iso8601Seconds(now.addingTimeInterval(offset)) }
        func cached(_ mode: AgentMode, _ event: String, _ offset: TimeInterval) -> AgentStatus {
            AgentStatus(provider: "codex", agentID: "codex:session:codex-session", displayName: "project: Restart recovery",
                        mode: mode, updatedAt: TimeFormat.parse(stamp(offset))!, eventName: event, sessionID: "codex-session",
                        cwd: "/tmp/project")
        }
        func restart(latest: LatestStore, log: URL) throws -> AgentStatus? {
            let engine = StatusEngine()
            engine.load(latest.load())
            if engine.reconcile(with: LogScanner.scan(sources: [SourceInfo(provider: "codex", path: log.path)])) {
                try latest.save(Array(engine.statuses.values), now: now)
            }
            return engine.snapshot(now: now).aggregate.representative
        }

        let latest = LatestStore(url: tmp.appendingPathComponent("recover/latest.json"))
        try latest.save([cached(.working, "UserPromptSubmit", -10)], now: now)
        let log = try write(#"{"logged_at":"\#(stamp(-5))","hook_event_name":"Stop","session_id":"codex-session","cwd":"/tmp/project","last_assistant_message":"Done."}"#,
                            "recover/codex.jsonl")
        let recovered = try restart(latest: latest, log: log)
        XCTAssertEqual(recovered?.mode, .completed)
        XCTAssertEqual(recovered?.eventName, "Stop")
        XCTAssertEqual(latest.load().first?.mode, .completed, "latest.json is rewritten")

        let newer = LatestStore(url: tmp.appendingPathComponent("newer/latest.json"))
        try newer.save([cached(.completed, "Stop", -5)], now: now)
        let olderLog = try write(#"{"logged_at":"\#(stamp(-10))","hook_event_name":"UserPromptSubmit","session_id":"codex-session","cwd":"/tmp/project","prompt":"Restart recovery"}"#,
                                 "newer/codex.jsonl")
        XCTAssertEqual(try restart(latest: newer, log: olderLog)?.mode, .completed)
        XCTAssertEqual(newer.load().first?.mode, .completed)
    }

    private func restart(from live: StatusEngine, lines: [JSONObject], maxLines: Int = 2000) throws -> StatusEngine {
        let log = try write(lines.map { JSONValue.object($0).serialized() }.joined(separator: "\n"), "restart-\(UUID()).jsonl")
        let engine = StatusEngine()
        engine.load(Array(live.statuses.values))
        engine.reconcile(with: LogScanner.scan(sources: [SourceInfo(provider: "claude", path: log.path)], maxLines: maxLines))
        return engine
    }

    private func claude(_ event: String, _ offset: TimeInterval, _ fields: JSONObject = [:]) -> JSONObject {
        var line: JSONObject = ["logged_at": .string(TimeFormat.pythonISO(t0.addingTimeInterval(offset))),
                                "hook_event_name": .string(event), "session_id": .string("s"), "cwd": .string("/tmp/project")]
        for (key, value) in fields { line[key] = value }
        return line
    }

    private var idlePrompt: JSONObject {
        ["notification_type": .string("idle_prompt"), "message": .string("Claude is waiting for your input")]
    }

    /// Regression: the scan's tail window missed a session's Stop but not the
    /// idle_prompt that followed, which it took as Ask.
    func testIdlePromptWhoseStopFellOutsideTheScanStaysDone() throws {
        let filler = (0..<3).map { claude("PreToolUse", 30 + Double($0), ["session_id": .string("busy")]) }
        let lines = [claude("Stop", 0, ["last_assistant_message": .string("All done.")])] + filler
            + [claude("Notification", 60, idlePrompt)]
        let live = StatusEngine()
        for line in lines { live.ingest(provider: "claude", line: line) }
        XCTAssertEqual(live.statuses["claude:session:s"]?.mode, .completed)

        let restarted = try restart(from: live, lines: lines, maxLines: lines.count - 1)
        XCTAssertEqual(restarted.statuses["claude:session:s"]?.mode, .completed)
        XCTAssertEqual(restarted.statuses["claude:session:s"]?.eventName, "Stop")
        let log = try write(lines.map { JSONValue.object($0).serialized() }.joined(separator: "\n"), "offline.jsonl")
        let offline = LogScanner.scan(sources: [SourceInfo(provider: "claude", path: log.path)], maxLines: lines.count - 1)
        XCTAssertNil(offline.first { $0.agentID == "claude:session:s" }, "no row rather than a false Ask")
    }

    /// The app was down across a new turn, so the scanned Notification is newer than
    /// the restored Done row and wins.
    func testNotificationAfterMissedTurnReplacesRestoredDone() throws {
        let live = StatusEngine()
        live.ingest(provider: "claude", line: claude("Stop", 0, ["last_assistant_message": .string("All done.")]))
        let edit: JSONObject = ["tool_name": .string("Edit"), "tool_input": .object(["file_path": .string("/tmp/project/a.swift")])]
        let missed = [
            claude("UserPromptSubmit", 300, ["prompt": .string("rename it")]),
            claude("PreToolUse", 301, edit),
            claude("PermissionRequest", 302, edit),
            claude("Notification", 303, ["notification_type": .string("permission_prompt"),
                                         "message": .string("Claude needs your permission to use Edit")]),
        ]
        let restarted = try restart(from: live, lines: [claude("Stop", 0)] + missed)
        XCTAssertEqual(restarted.statuses["claude:session:s"]?.mode, .waitingForInput)
        XCTAssertEqual(restarted.statuses["claude:session:s"]?.eventName, "Notification")

        // An interrupted turn (no Stop) that Claude then reports idle.
        let interrupted = try restart(from: live, lines: [claude("UserPromptSubmit", 300, ["prompt": .string("go")]),
                                                          claude("Notification", 360, idlePrompt)])
        XCTAssertEqual(interrupted.statuses["claude:session:s"]?.mode, .waitingForInput)
    }

    // MARK: scan

    func testScanSortsStablyAcrossSources() throws {
        // Same-second events from two sources: ties keep source order, then line order.
        let codex = try write(#"""
        {"logged_at":"2026-09-20T10:00:05Z","hook_event_name":"UserPromptSubmit","session_id":"shared","prompt":"codex prompt"}
        {"logged_at":"2026-09-20T10:00:01Z","hook_event_name":"Stop","session_id":"c1","last_assistant_message":"Done."}
        """#, "logs/codex.jsonl")
        let claude = try write(#"""
        {"logged_at":"2026-09-20T10:00:05Z","hook_event_name":"PreToolUse","session_id":"k1","tool_name":"Bash"}
        {"logged_at":"2026-09-20T10:00:05Z","hook_event_name":"PostToolUse","session_id":"k1","tool_name":"Bash","tool_response":"Traceback: boom"}
        {"logged_at":"2026-09-20T10:00:00Z","hook_event_name":"UserPromptSubmit","session_id":"k1","prompt":"first"}
        """#, "logs/claude.jsonl")
        let rows = LogScanner.scan(sources: [SourceInfo(provider: "codex", path: codex.path),
                                             SourceInfo(provider: "claude", path: claude.path),
                                             SourceInfo(provider: "claude", path: claude.path)])
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.agentID, $0) })
        XCTAssertEqual(byKey["claude:session:k1"]?.mode, .blockedError, "the later line of a same-second pair wins")
        XCTAssertEqual(byKey["claude:session:k1"]?.displayName, "first (k1)", "the earlier prompt (last line) sorts first")
        XCTAssertEqual(byKey["codex:session:shared"]?.displayName, "codex prompt (shared)")
        XCTAssertEqual(byKey["codex:session:c1"]?.mode, .completed)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.last?.agentID, "codex:session:c1", "rows come back newest first")
    }

    func testScanPassesCodexTitleLookup() throws {
        let codex = try write(#"{"logged_at":"2026-09-20T10:00:05Z","hook_event_name":"UserPromptSubmit","session_id":"abcdef123456","prompt":"x"}"#,
                              "codex.jsonl")
        let rows = LogScanner.scan(sources: [SourceInfo(provider: "codex", path: codex.path)],
                                   codexTitle: { $0 == "abcdef123456" ? "Indexed title" : nil })
        XCTAssertEqual(rows.first?.displayName, "Indexed title (abcdef12)")
    }

    func testScanRespectsMaxLinesAndMissingSources() throws {
        let log = try write((0..<5).map { #"{"logged_at":"2026-09-20T10:00:0\#($0)Z","hook_event_name":"PreToolUse","session_id":"s\#($0)"}"# }
            .joined(separator: "\n"), "claude.jsonl")
        let rows = LogScanner.scan(sources: [SourceInfo(provider: "claude", path: log.path),
                                             SourceInfo(provider: "codex", path: tmp.appendingPathComponent("none.jsonl").path)],
                                   maxLines: 2)
        XCTAssertEqual(rows.map(\.agentID), ["claude:session:s4", "claude:session:s3"])
    }

    func testDefaultSources() throws {
        let home = tmp.appendingPathComponent("home", isDirectory: true)
        let paths = SidePulsePaths(environment: ["SIDEPULSE_HOME": tmp.appendingPathComponent("root").path, "HOME": home.path], home: home)
        XCTAssertEqual(LogScanner.defaultSources(paths: paths), [
            SourceInfo(provider: "codex", path: paths.logFile(for: "codex").path),
            SourceInfo(provider: "claude", path: paths.logFile(for: "claude").path),
            SourceInfo(provider: "opencode", path: paths.logFile(for: "opencode").path),
        ])
        try FileManager.default.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
        try Data().write(to: paths.logsDir.appendingPathComponent("claude.jsonl.1"))
        XCTAssertEqual(LogScanner.defaultSources(paths: paths).map(\.path), [
            paths.logFile(for: "codex").path,
            paths.logsDir.appendingPathComponent("claude.jsonl.1").path,
            paths.logFile(for: "claude").path,
            paths.logFile(for: "opencode").path,
        ])
    }

    func testRotatedLogIsReadBeforeCurrentLog() throws {
        let home = tmp.appendingPathComponent("home", isDirectory: true)
        let paths = SidePulsePaths(environment: ["SIDEPULSE_HOME": tmp.appendingPathComponent("root").path, "HOME": home.path], home: home)
        try FileManager.default.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
        // Same timestamp in both files: source order (rotated first) decides.
        try Data(#"{"logged_at":"2026-09-20T10:00:00Z","hook_event_name":"PreToolUse","session_id":"s"}"#.utf8)
            .write(to: paths.logsDir.appendingPathComponent("claude.jsonl.1"))
        try Data(#"{"logged_at":"2026-09-20T10:00:00Z","hook_event_name":"Stop","session_id":"s"}"#.utf8)
            .write(to: paths.logFile(for: "claude"))
        let rows = LogScanner.scan(sources: LogScanner.defaultSources(paths: paths))
        XCTAssertEqual(rows.first?.eventName, "Stop")
    }

    // MARK: CodexSessionIndex

    func testCodexSessionIndexLaterRowsWinAndTitlesTruncate() throws {
        let long = String(repeating: "word ", count: 20)
        let url = try write([
            #"{"id":"01a081bb","thread_name":"hi","updated_at":"2026-09-08T15:55:35Z"}"#,
            #"{"id":"01a081bb","thread_name":"  Respond to greeting  ","updated_at":"2026-09-08T15:55:39Z"}"#,
            #"{"id":"long","thread_name":"\#(long)"}"#,
            #"{"id":"blank","thread_name":"Old"}"#,
            #"{"id":"blank","thread_name":"   "}"#,
            "not json",
            #"{"id":"","thread_name":"no id"}"#,
            #"{"id":"n","thread_name":7}"#,
        ].joined(separator: "\n") + "\n", "home/.codex/session_index.jsonl")
        let index = CodexSessionIndex(url: url)
        XCTAssertEqual(index.title(forSession: "01a081bb"), "Respond to greeting")
        XCTAssertEqual(index.title(forSession: "long"), DisplayNames.truncate(PyText.strip(long), 72))
        XCTAssertEqual(index.title(forSession: "long")?.hasSuffix("..."), true)
        XCTAssertNil(index.title(forSession: "blank"), "a later blank name clears the title")
        XCTAssertNil(index.title(forSession: "n"))
        XCTAssertNil(index.title(forSession: ""))
        XCTAssertNil(index.title(forSession: "unknown"))
    }

    func testCodexSessionIndexReloadsWhenFileChanges() throws {
        let home = tmp.appendingPathComponent("home", isDirectory: true)
        let paths = SidePulsePaths(environment: ["SIDEPULSE_HOME": tmp.path, "HOME": home.path], home: home)
        let index = CodexSessionIndex(paths: paths)
        XCTAssertEqual(index.url, home.appendingPathComponent(".codex/session_index.jsonl"))
        XCTAssertNil(index.title(forSession: "s1"), "missing file")

        try FileManager.default.createDirectory(at: index.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"id":"s1","thread_name":"First"}"#.utf8).write(to: index.url)
        XCTAssertEqual(index.title(forSession: "s1"), "First")

        try Data((#"{"id":"s1","thread_name":"First"}"# + "\n" + #"{"id":"s1","thread_name":"Renamed thread"}"#).utf8).write(to: index.url)
        XCTAssertEqual(index.title(forSession: "s1"), "Renamed thread")

        try FileManager.default.removeItem(at: index.url)
        XCTAssertNil(index.title(forSession: "s1"))
    }
}
