import XCTest
@testable import SidePulseCore

final class StatusModelsTests: XCTestCase {
    private let t0 = TimeFormat.parse("2026-09-17T17:42:43Z")!

    private func sampleStatus(stale: Bool = false) -> AgentStatus {
        AgentStatus(provider: "codex", agentID: "codex:session:01a0b075", displayName: "tmp: Greet user (01a0b075)",
                    mode: .completed, updatedAt: t0, eventName: "Stop", sessionID: "01a0b075",
                    cwd: "/Users/k/Documents/GitHub/tmp", toolName: nil,
                    message: "Hi! What would you like to work on?", origin: "Codex CLI", stale: stale)
    }

    func testModeVocabularyMatchesPython() {
        let expected: [(AgentMode, String, Int, String)] = [
            (.blockedError, "blocked_error", 1, "Blocked / Error"),
            (.waitingForInput, "waiting_for_input", 2, "Waiting for Input"),
            (.toolRunning, "tool_running", 3, "Tool Running"),
            (.longTaskProgress, "long_task_progress", 4, "Long Task Progress"),
            (.working, "working", 5, "Working"),
            (.completed, "completed", 6, "Completed"),
            (.idleReady, "idle_ready", 7, "Idle / Ready"),
            (.unknown, "unknown", 99, "Unknown"),
        ]
        for (mode, raw, priority, label) in expected {
            XCTAssertEqual(mode.rawValue, raw)
            XCTAssertEqual(mode.priority, priority)
            XCTAssertEqual(mode.label, label)
        }
        XCTAssertFalse(AgentMode.completed.isActive)
        XCTAssertFalse(AgentMode.idleReady.isActive)
        XCTAssertTrue(AgentMode.unknown.isActive)
        XCTAssertEqual(AgentMode.blockedError.displayState, .ask)
        XCTAssertEqual(AgentMode.longTaskProgress.displayState, .working)
        XCTAssertEqual(AgentMode.unknown.displayState, .idle)
    }

    func testStatusKeyPrefersAgentThenSession() {
        var event = HookEvent(provider: "claude", loggedAt: t0, eventName: "Stop", raw: [:], sessionID: "s1", agentID: "a1")
        XCTAssertEqual(event.statusKey, "claude:agent:a1")
        event.agentID = ""
        XCTAssertEqual(event.statusKey, "claude:session:s1")
        event.sessionID = nil
        XCTAssertEqual(event.statusKey, "claude:unknown")
    }

    func testAgentStatusToJSONUsesPythonKeyOrderAndValues() {
        let json = sampleStatus().toJSON(now: t0.addingTimeInterval(715_782.1314))
        XCTAssertEqual(json.objectValue?.keys, [
            "provider", "agent_id", "display_name", "mode", "mode_label", "priority", "updated_at", "age_seconds",
            "event_name", "session_id", "cwd", "tool_name", "message", "origin", "stale",
        ])
        XCTAssertEqual(json["updated_at"], .string("2026-09-17T17:42:43+00:00"))
        XCTAssertEqual(json["age_seconds"], .number("715782.131"))
        XCTAssertEqual(json["priority"], .number("6"))
        XCTAssertEqual(json["mode_label"], .string("Completed"))
        XCTAssertEqual(json["tool_name"], .null)
        XCTAssertEqual(json["stale"], .bool(false))
    }

    func testAgeIsNeverNegative() {
        let json = sampleStatus().toJSON(now: t0.addingTimeInterval(-30))
        XCTAssertEqual(json["age_seconds"], .number("0.0"))
        XCTAssertEqual(sampleStatus().age(now: t0.addingTimeInterval(-30)), 0)
    }

    func testAgentStatusRoundTrip() {
        let status = sampleStatus(stale: true)
        XCTAssertEqual(AgentStatus.fromJSON(status.toJSON(now: t0)), status)
    }

    func testFromJSONAcceptsPythonLatestEntry() throws {
        let entry = try JSONValue.parse(#"""
        {"age_seconds":715782.131,"agent_id":"codex:session:01a0b075-x","cwd":"/Users/k/Documents/GitHub/tmp",
         "display_name":"tmp: Greet user (01a0b075)","event_name":"Stop","message":"","mode":"completed",
         "mode_label":"Completed","origin":"Codex CLI","priority":6,"provider":"codex","session_id":"01a0b075-x",
         "stale":false,"tool_name":null,"updated_at":"2026-09-17T17:41:28.131369+00:00"}
        """#)
        let status = try XCTUnwrap(AgentStatus.fromJSON(entry))
        XCTAssertEqual(status.mode, .completed)
        XCTAssertEqual(status.sessionID, "01a0b075-x")
        XCTAssertNil(status.message, "empty strings become nil")
        XCTAssertNil(status.toolName)
        XCTAssertEqual(status.updatedAt.timeIntervalSince1970, 1_789_666_888.131369, accuracy: 1e-5)
    }

    func testFromJSONRejectsIncompleteEntries() throws {
        let valid = sampleStatus().toJSON(now: t0)
        for key in ["provider", "agent_id", "display_name", "mode", "updated_at", "event_name"] {
            var object = try XCTUnwrap(valid.objectValue)
            object[key] = nil
            XCTAssertNil(AgentStatus.fromJSON(.object(object)), "missing \(key)")
        }
        var badMode = try XCTUnwrap(valid.objectValue)
        badMode["mode"] = .string("sleeping")
        XCTAssertNil(AgentStatus.fromJSON(.object(badMode)))
        var badDate = try XCTUnwrap(valid.objectValue)
        badDate["updated_at"] = .string("yesterday")
        XCTAssertNil(AgentStatus.fromJSON(.object(badDate)))
        XCTAssertNil(AgentStatus.fromJSON(.string("nope")))
    }

    func testAggregateToJSON() {
        let aggregate = AggregateStatus(mode: .waitingForInput, activeCount: 2, staleCount: 1, representative: nil)
        let json = aggregate.toJSON(now: t0)
        XCTAssertEqual(json.objectValue?.keys, ["mode", "mode_label", "active_count", "stale_count", "representative"])
        XCTAssertEqual(json.serialized(),
                       #"{"mode":"waiting_for_input","mode_label":"Waiting for Input","active_count":2,"stale_count":1,"representative":null}"#)
    }

    func testSnapshotRoundTrip() throws {
        let fresh = AgentStatus(provider: "claude", agentID: "claude:session:s1", displayName: "p (s1)", mode: .working,
                                updatedAt: t0, eventName: "UserPromptSubmit", sessionID: "s1")
        var stale = sampleStatus()
        stale.stale = true
        let snapshot = MonitorSnapshot(
            collectedAt: t0.addingTimeInterval(5),
            sources: [SourceInfo(provider: "claude", path: "/tmp/claude.jsonl")],
            aggregate: AggregateStatus(mode: .working, activeCount: 1, staleCount: 1, representative: fresh),
            statuses: [fresh], staleStatuses: [stale])
        let json = snapshot.toJSON()
        XCTAssertEqual(json.objectValue?.keys, ["collected_at", "sources", "aggregate", "statuses", "stale_statuses"])
        XCTAssertEqual(json["statuses"]?.arrayValue?.first?["age_seconds"], .number("5.0"))
        let decoded = try XCTUnwrap(MonitorSnapshot.fromJSON(try JSONValue.parse(json.serialized())))
        XCTAssertEqual(decoded, snapshot)
    }

    func testSnapshotFromJSONRequiresAggregate() {
        XCTAssertNil(MonitorSnapshot.fromJSON(.object(["collected_at": .string("2026-09-17T17:42:43+00:00")])))
    }
}
