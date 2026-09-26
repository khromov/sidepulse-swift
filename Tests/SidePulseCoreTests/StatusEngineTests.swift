import XCTest
@testable import SidePulseCore

final class StatusEngineTests: XCTestCase {
    private let t0 = TimeFormat.parse("2026-09-20T10:00:00Z")!

    private func stamp(_ offset: TimeInterval) -> JSONValue {
        .string(TimeFormat.pythonISO(t0.addingTimeInterval(offset)))
    }

    private func codexLine(_ event: String, at offset: TimeInterval, _ fields: JSONObject = [:]) -> JSONObject {
        claudeLine(event, at: offset, fields)
    }

    private func claudeLine(_ event: String, at offset: TimeInterval, _ fields: JSONObject = [:]) -> JSONObject {
        var line: JSONObject = ["logged_at": stamp(offset), "hook_event_name": .string(event)]
        for (key, value) in fields { line[key] = value }
        return line
    }

    private func bash(_ command: String) -> JSONValue { .object(["command": .string(command)]) }

    // MARK: Aggregation and snapshot rules

    func testAggregatesHighestPriorityStatus() {
        // Python's version uses an idle_prompt, which is ignored here without a row, so
        // this uses a permission prompt.
        let engine = StatusEngine(config: MonitorConfig(staleAfter: 999_999_999))
        engine.ingest(provider: "codex", line: codexLine("PreToolUse", at: 0, ["session_id": .string("codex-session"), "tool_name": .string("Bash")]))
        engine.ingest(provider: "claude", line: claudeLine("Notification", at: 1, [
            "session_id": .string("claude-session"), "notification_type": .string("permission_prompt"),
            "message": .string("Claude needs your permission to use Edit"),
        ]))
        let snapshot = engine.snapshot(now: t0.addingTimeInterval(2))
        XCTAssertEqual(snapshot.aggregate.mode, .waitingForInput)
        XCTAssertEqual(snapshot.statuses.count, 2)
        XCTAssertEqual(snapshot.statuses.map(\.agentID), ["claude:session:claude-session", "codex:session:codex-session"])
        XCTAssertEqual(snapshot.aggregate.representative?.agentID, "claude:session:claude-session")
        XCTAssertEqual(snapshot.aggregate.activeCount, 2)
    }

    func testOrphanedToolRunningExpiresBeforeSessionStaleTimeout() {
        let engine = StatusEngine(config: MonitorConfig(staleAfter: 300, toolRunningTimeout: 120))
        engine.ingest(provider: "codex", line: codexLine("PreToolUse", at: 0, ["session_id": .string("codex-session"), "tool_name": .string("Bash")]))
        let snapshot = engine.snapshot(now: t0.addingTimeInterval(180))
        XCTAssertEqual(snapshot.aggregate.mode, .idleReady)
        XCTAssertEqual(snapshot.statuses, [])
        XCTAssertEqual(snapshot.staleStatuses.map(\.mode), [.toolRunning])
        XCTAssertEqual(snapshot.staleStatuses.first?.stale, true)
        XCTAssertEqual(snapshot.aggregate.staleCount, 1)
        XCTAssertNil(snapshot.aggregate.representative)
    }

    func testCompletedStatusExpiresBeforeSessionStaleTimeout() {
        let engine = StatusEngine(config: MonitorConfig(staleAfter: 3600, completedVisible: 15))
        engine.ingest(provider: "codex", line: codexLine("Stop", at: 0, ["session_id": .string("codex-session"), "last_assistant_message": .string("Done.")]))
        let snapshot = engine.snapshot(now: t0.addingTimeInterval(60))
        XCTAssertEqual(snapshot.aggregate.mode, .idleReady)
        XCTAssertEqual(snapshot.statuses, [])
        XCTAssertEqual(snapshot.staleStatuses.map(\.mode), [.completed])
    }

    func testCompletedStatusStaysVisibleForTwentyMinutesByDefault() {
        let engine = StatusEngine()
        engine.ingest(provider: "codex", line: codexLine("Stop", at: 0, ["session_id": .string("codex-session"), "last_assistant_message": .string("Done.")]))
        let snapshot = engine.snapshot(now: t0.addingTimeInterval(19 * 60))
        XCTAssertEqual(snapshot.aggregate.mode, .completed)
        XCTAssertEqual(snapshot.statuses.count, 1)
        XCTAssertEqual(snapshot.aggregate.activeCount, 0)
        XCTAssertEqual(engine.snapshot(now: t0.addingTimeInterval(21 * 60)).aggregate.mode, .idleReady)
    }

    func testCompletedStatusIsHiddenWhenActiveWorkExists() {
        let engine = StatusEngine(config: MonitorConfig(staleAfter: 3600, completedVisible: 15))
        engine.ingest(provider: "codex", line: codexLine("Stop", at: 0, ["session_id": .string("done-session"), "last_assistant_message": .string("Done.")]))
        engine.ingest(provider: "codex", line: codexLine("PreToolUse", at: 0, ["session_id": .string("working-session"), "tool_name": .string("Bash")]))
        let snapshot = engine.snapshot(now: t0)
        XCTAssertEqual(snapshot.aggregate.activeCount, 1)
        XCTAssertEqual(snapshot.statuses.map(\.sessionID), ["working-session"])
        XCTAssertEqual(snapshot.staleStatuses.first?.sessionID, "done-session")
        XCTAssertEqual(snapshot.staleStatuses.first?.stale, true)
    }

    func testIdleRowsAreHiddenImmediately() {
        let engine = StatusEngine()
        engine.ingest(provider: "claude", line: claudeLine("SessionStart", at: 0, ["session_id": .string("s"), "source": .string("resume")]))
        XCTAssertEqual(engine.statuses["claude:session:s"]?.mode, .idleReady)
        XCTAssertEqual(engine.snapshot(now: t0).statuses.count, 1, "age 0 is not > 0")
        XCTAssertEqual(engine.snapshot(now: t0.addingTimeInterval(0.5)).statuses, [])
    }

    func testIdleNotificationDoesNotResurrectCompletedClaudeSession() {
        let engine = StatusEngine()
        engine.ingest(provider: "claude", line: claudeLine("Stop", at: 0, [
            "session_id": .string("claude-session"), "cwd": .string("/tmp/project"), "last_assistant_message": .string("Done and verified."),
            "background_tasks": .array([]), "session_crons": .array([]),
        ]))
        let ignored = engine.ingest(provider: "claude", line: claudeLine("Notification", at: 60, [
            "session_id": .string("claude-session"), "cwd": .string("/tmp/project"), "notification_type": .string("idle_prompt"),
            "message": .string("Claude is waiting for your input"),
        ]))
        XCTAssertNil(ignored)
        let snapshot = engine.snapshot(now: t0.addingTimeInterval(25 * 60))
        XCTAssertEqual(snapshot.aggregate.mode, .idleReady)
        XCTAssertEqual(snapshot.statuses, [])
        XCTAssertEqual(snapshot.staleStatuses.first?.mode, .completed)
    }

    /// Regression: Claude also sends idle_prompt about a minute after SessionStart.
    func testIdlePromptDoesNotTurnFreshSessionIntoAsk() {
        let engine = StatusEngine()
        let idlePrompt: JSONObject = [
            "session_id": .string("s"), "notification_type": .string("idle_prompt"),
            "message": .string("Claude is waiting for your input"),
        ]
        engine.ingest(provider: "claude", line: claudeLine("SessionStart", at: 0, ["session_id": .string("s"), "source": .string("clear")]))
        XCTAssertNil(engine.ingest(provider: "claude", line: claudeLine("Notification", at: 60, idlePrompt)))
        XCTAssertEqual(engine.statuses["claude:session:s"]?.eventName, "SessionStart")
        XCTAssertEqual(engine.snapshot(now: t0.addingTimeInterval(120)).aggregate.mode, .idleReady)

        // Other Notifications still apply to an Idle row.
        engine.ingest(provider: "claude", line: claudeLine("Notification", at: 90, [
            "session_id": .string("s"), "notification_type": .string("permission_prompt"),
            "message": .string("Claude needs your permission to use Bash"),
        ]))
        XCTAssertEqual(engine.statuses["claude:session:s"]?.mode, .waitingForInput)
    }

    func testSettledPostToolUseRowIsStillWorkingForTransitionRules() {
        // The row settles to Completed only in the snapshot, so a later Notification still applies.
        let engine = StatusEngine()
        engine.ingest(provider: "claude", line: claudeLine("PostToolUse", at: 0, ["session_id": .string("s"), "tool_name": .string("Read")]))
        XCTAssertEqual(engine.snapshot(now: t0.addingTimeInterval(121)).aggregate.mode, .completed)
        engine.ingest(provider: "claude", line: claudeLine("Notification", at: 180, [
            "session_id": .string("s"), "notification_type": .string("idle_prompt"), "message": .string("Claude is waiting for your input"),
        ]))
        XCTAssertEqual(engine.statuses["claude:session:s"]?.mode, .waitingForInput)
    }

    func testPostToolUseDoesNotStayWorkingIndefinitely() {
        let status = AgentStatus(provider: "codex", agentID: "codex:session:tool-session", displayName: "tool-session",
                                 mode: .working, updatedAt: t0.addingTimeInterval(-121), eventName: "PostToolUse",
                                 sessionID: "tool-session", cwd: "/tmp/project", toolName: "webrun")
        let snapshot = SnapshotBuilder.build(statuses: [status], config: MonitorConfig(), now: t0, sources: [])
        XCTAssertEqual(snapshot.aggregate.mode, .completed)
        XCTAssertEqual(snapshot.aggregate.activeCount, 0)
        XCTAssertEqual(snapshot.statuses.first?.eventName, "PostToolUse")
        XCTAssertEqual(snapshot.statuses.first?.updatedAt, status.updatedAt)

        let fresh = SnapshotBuilder.build(statuses: [status], config: MonitorConfig(), now: t0.addingTimeInterval(-2), sources: [])
        XCTAssertEqual(fresh.aggregate.mode, .working)
    }

    func testNegativeWindowsDisableSpecialCases() {
        let completed = AgentStatus(provider: "codex", agentID: "codex:session:a", displayName: "a", mode: .completed,
                                    updatedAt: t0.addingTimeInterval(-7200), eventName: "Stop")
        var config = MonitorConfig(staleAfter: 10_000, completedVisible: -1)
        XCTAssertEqual(SnapshotBuilder.build(statuses: [completed], config: config, now: t0, sources: []).statuses.count, 1)
        config.staleAfter = 3600
        XCTAssertEqual(SnapshotBuilder.build(statuses: [completed], config: config, now: t0, sources: []).statuses.count, 0)
    }

    func testSnapshotOrderIsPriorityThenNewestThenKey() {
        func status(_ key: String, _ mode: AgentMode, _ offset: TimeInterval) -> AgentStatus {
            AgentStatus(provider: "claude", agentID: key, displayName: key, mode: mode, updatedAt: t0.addingTimeInterval(offset),
                        eventName: "PreToolUse")
        }
        let rows = [status("c", .toolRunning, -5), status("b", .toolRunning, -5), status("a", .toolRunning, -10),
                    status("z", .blockedError, -50), status("w", .working, -1)]
        let snapshot = SnapshotBuilder.build(statuses: rows, config: MonitorConfig(), now: t0,
                                             sources: [SourceInfo(provider: "claude", path: "/x")])
        XCTAssertEqual(snapshot.statuses.map(\.agentID), ["z", "b", "c", "a", "w"])
        XCTAssertEqual(snapshot.sources.first?.path, "/x")
        XCTAssertEqual(snapshot.collectedAt, t0)
    }

    // MARK: Permissions and Interrupt

    func testPermissionRequestStaysAskDuringUnrelatedToolActivity() {
        let engine = StatusEngine()
        let session = "019f179b-7fdc-7eb0-a3af-1ca3eb128eee"
        let server = ".venv/bin/bambucuts server --host 127.0.0.1 --port 5425"
        let curl = "curl -s http://127.0.0.1:5425/api/status | head -c 1000"
        let base: JSONObject = ["session_id": .string(session), "cwd": .string("/Users/pero/pgit/a1plotter"), "tool_name": .string("Bash")]
        func with(_ extra: JSONObject) -> JSONObject { var o = base; for (k, v) in extra { o[k] = v }; return o }
        engine.ingest(provider: "codex", line: codexLine("PreToolUse", at: 0, with(["tool_input": bash(server)])))
        engine.ingest(provider: "codex", line: codexLine("PermissionRequest", at: 1, with(["tool_input": bash(server)])))
        XCTAssertNil(engine.ingest(provider: "codex", line: codexLine("PreToolUse", at: 2, with(["tool_input": bash(curl)]))))
        XCTAssertNil(engine.ingest(provider: "codex", line: codexLine("PostToolUse", at: 3, with(["tool_input": bash(curl), "tool_response": .string("{}")]))))
        let snapshot = engine.snapshot(now: t0.addingTimeInterval(4))
        XCTAssertEqual(snapshot.aggregate.mode, .waitingForInput)
        XCTAssertEqual(snapshot.statuses.first?.eventName, "PermissionRequest")
        XCTAssertEqual(engine.pendingPermissions["codex:session:\(session)"], ["Bash\u{0}\(server)"])
    }

    func testPermissionRequestClearsWhenMatchingToolFinishes() {
        let engine = StatusEngine()
        let command = "curl -s http://127.0.0.1:5425/api/status | head -c 1000"
        let fields: JSONObject = ["session_id": .string("s"), "tool_name": .string("Bash"), "tool_input": bash(command)]
        engine.ingest(provider: "codex", line: codexLine("PreToolUse", at: 0, fields))
        engine.ingest(provider: "codex", line: codexLine("PermissionRequest", at: 1, fields))
        var done = fields
        done["tool_response"] = .string("{}")
        engine.ingest(provider: "codex", line: codexLine("PostToolUse", at: 2, done))
        let snapshot = engine.snapshot(now: t0.addingTimeInterval(3))
        XCTAssertEqual(snapshot.aggregate.mode, .working)
        XCTAssertEqual(snapshot.statuses.first?.eventName, "PostToolUse")
        XCTAssertEqual(engine.pendingPermissions, [:])
    }

    func testPermissionWithoutCommandIsNotSticky() {
        let engine = StatusEngine()
        engine.ingest(provider: "claude", line: claudeLine("PermissionRequest", at: 0, [
            "session_id": .string("s"), "tool_name": .string("ExitPlanMode"), "tool_input": .object(["plan": .string("1. do it")]),
        ]))
        XCTAssertEqual(engine.pendingPermissions, [:])
        engine.ingest(provider: "claude", line: claudeLine("PreToolUse", at: 1, ["session_id": .string("s"), "tool_name": .string("Read")]))
        XCTAssertEqual(engine.statuses["claude:session:s"]?.mode, .toolRunning)
    }

    func testDeniedPermissionStaysStickyUntilNextPrompt() {
        let engine = StatusEngine()
        let fields: JSONObject = ["session_id": .string("s"), "tool_name": .string("Bash"), "tool_input": bash("rm -rf build")]
        engine.ingest(provider: "claude", line: claudeLine("PermissionRequest", at: 0, fields))
        XCTAssertNil(engine.ingest(provider: "claude", line: claudeLine("PermissionDenied", at: 1, fields)))
        XCTAssertNil(engine.ingest(provider: "claude", line: claudeLine("PreToolUse", at: 2, ["session_id": .string("s"), "tool_name": .string("Read")])))
        XCTAssertEqual(engine.statuses["claude:session:s"]?.mode, .waitingForInput)
        engine.ingest(provider: "claude", line: claudeLine("UserPromptSubmit", at: 3, ["session_id": .string("s"), "prompt": .string("never mind")]))
        XCTAssertEqual(engine.statuses["claude:session:s"]?.mode, .working)
        XCTAssertEqual(engine.pendingPermissions, [:])
    }

    /// Regression (real log): an approved command that exits non-zero logs
    /// PostToolUseFailure, not PostToolUse, and the row stayed on Ask.
    func testFailedApprovedCommandReleasesPermission() {
        let engine = StatusEngine()
        let session: JSONObject = ["session_id": .string("s"), "tool_name": .string("Bash")]
        func with(_ command: String, _ extra: JSONObject = [:]) -> JSONObject {
            var o = session
            o["tool_input"] = bash(command)
            for (k, v) in extra { o[k] = v }
            return o
        }
        engine.ingest(provider: "claude", line: claudeLine("PreToolUse", at: 0, with("head -80 page.svelte")))
        engine.ingest(provider: "claude", line: claudeLine("PermissionRequest", at: 1, with("head -80 page.svelte")))
        XCTAssertNil(engine.ingest(provider: "claude", line: claudeLine("PostToolUseFailure", at: 2, with("other", ["error": .string("Exit code 1")]))),
                     "another command's failure keeps the prompt up")
        XCTAssertEqual(engine.ingest(provider: "claude", line: claudeLine("PostToolUseFailure", at: 3,
                                                                          with("head -80 page.svelte", ["error": .string("Exit code 1")])))?.mode,
                       .blockedError)
        XCTAssertEqual(engine.pendingPermissions, [:])
        engine.ingest(provider: "claude", line: claudeLine("PreToolUse", at: 4, with("ls")))
        XCTAssertEqual(engine.snapshot(now: t0.addingTimeInterval(5)).aggregate.mode, .toolRunning)
    }

    /// Regression (real log): turn-ending events never carry a subagent's agent_id, so
    /// ignoring its own SubagentStop left the row on Ask.
    func testSubagentStopReleasesItsPermission() {
        let engine = StatusEngine()
        let agent: JSONObject = ["session_id": .string("s"), "agent_id": .string("a49ad5bb06ef208c9"),
                                 "tool_name": .string("Bash"), "tool_input": bash("cd site && head -80 x")]
        engine.ingest(provider: "claude", line: claudeLine("PermissionRequest", at: 0, agent))
        XCTAssertNil(engine.ingest(provider: "claude", line: claudeLine("PreToolUse", at: 1, agent)))
        let stop = engine.ingest(provider: "claude", line: claudeLine("SubagentStop", at: 2, [
            "session_id": .string("s"), "agent_id": .string("a49ad5bb06ef208c9"), "last_assistant_message": .string("Found it."),
        ]))
        XCTAssertEqual(stop?.mode, .completed)
        XCTAssertEqual(engine.pendingPermissions, [:])
        XCTAssertEqual(engine.snapshot(now: t0.addingTimeInterval(60)).aggregate.mode, .completed)
    }

    func testPermissionSignatureUsesRawToolName() {
        let event = HookEvent(provider: "claude", loggedAt: t0, eventName: "PermissionRequest",
                              raw: ["tool_input": bash("ls")], toolName: "FromRecord")
        XCTAssertEqual(StatusEngine.permissionSignature(event), "FromRecord\u{0}ls")
        let empty = HookEvent(provider: "claude", loggedAt: t0, eventName: "PermissionRequest", raw: ["tool_input": bash("")])
        XCTAssertNil(StatusEngine.permissionSignature(empty))
        let noTool = HookEvent(provider: "claude", loggedAt: t0, eventName: "PermissionRequest", raw: ["tool_input": bash("ls")])
        XCTAssertEqual(StatusEngine.permissionSignature(noTool), "\u{0}ls")
    }

    func testCodexInterruptClearsActiveStatusAndPermissions() throws {
        for activeEvent in ["UserPromptSubmit", "PreToolUse", "PermissionRequest"] {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StatusEngine-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let store = LatestStore(url: tmp.appendingPathComponent("latest.json"))
            let engine = StatusEngine()
            func ingest(_ name: String, at offset: TimeInterval) {
                engine.ingest(provider: "codex", line: codexLine(name, at: offset, [
                    "session_id": .string("interrupted-session"), "turn_id": .string("interrupted-turn"), "tool_name": .string("Bash"),
                    "tool_input": bash("sleep 100"),
                ]))
            }
            ingest(activeEvent, at: 0)
            XCTAssertEqual(engine.snapshot(now: t0.addingTimeInterval(1)).aggregate.activeCount, 1, activeEvent)
            ingest("Interrupt", at: 1)
            XCTAssertEqual(engine.snapshot(now: t0.addingTimeInterval(1)).aggregate.activeCount, 0, activeEvent)
            XCTAssertEqual(engine.pendingPermissions, [:], activeEvent)
            let status = try XCTUnwrap(engine.statuses["codex:session:interrupted-session"])
            XCTAssertEqual(status.mode, .idleReady)
            XCTAssertEqual(status.eventName, "Interrupt")

            try store.save(Array(engine.statuses.values), now: t0.addingTimeInterval(1))
            let reloaded = StatusEngine()
            reloaded.load(store.load())
            XCTAssertEqual(reloaded.snapshot(now: t0.addingTimeInterval(1)).aggregate.activeCount, 0, activeEvent)

            ingest("UserPromptSubmit", at: 2)
            XCTAssertEqual(engine.snapshot(now: t0.addingTimeInterval(2)).aggregate.mode, .working, activeEvent)
        }
    }

    // MARK: Orphaned subagents

    /// Regression (real log): Claude quit mid-tool and the subagent, never getting a
    /// SubagentStop, stayed Tool Running for an hour.
    func testSessionEndCompletesTheSessionsActiveSubagents() throws {
        let engine = StatusEngine()
        func sub(_ event: String, _ agent: String, at offset: TimeInterval, session: String = "s", provider: String = "claude",
                 _ extra: JSONObject = [:]) {
            var fields: JSONObject = ["session_id": .string(session), "agent_id": .string(agent), "tool_name": .string("Bash")]
            for (k, v) in extra { fields[k] = v }
            engine.ingest(provider: provider, line: claudeLine(event, at: offset, fields))
        }
        engine.ingest(provider: "claude", line: claudeLine("UserPromptSubmit", at: 0, ["session_id": .string("s"), "prompt": .string("go")]))
        sub("PreToolUse", "running", at: 1)
        sub("SubagentStop", "finished", at: 2)
        sub("PermissionRequest", "asking", at: 3, ["tool_input": bash("rm -rf build")])
        sub("PreToolUse", "other-session", at: 4, session: "t")
        sub("PreToolUse", "codex-agent", at: 5, provider: "codex")
        engine.ingest(provider: "claude", line: claudeLine("SessionEnd", at: 10, ["session_id": .string("s"), "reason": .string("prompt_input_exit")]))

        for key in ["claude:agent:running", "claude:agent:asking"] {
            let row = try XCTUnwrap(engine.statuses[key])
            XCTAssertEqual(row.mode, .completed, key)
            XCTAssertEqual(row.updatedAt, t0.addingTimeInterval(10), key)
            XCTAssertEqual(row.eventName, "SessionEnd", key)
            XCTAssertNil(row.toolName, key)
        }
        XCTAssertEqual(engine.pendingPermissions, [:])
        XCTAssertEqual(engine.statuses["claude:agent:finished"]?.updatedAt, t0.addingTimeInterval(2), "inactive rows are left alone")
        XCTAssertEqual(engine.statuses["claude:agent:other-session"]?.mode, .toolRunning)
        XCTAssertEqual(engine.statuses["codex:agent:codex-agent"]?.mode, .toolRunning)
        XCTAssertEqual(engine.statuses["claude:session:s"]?.mode, .completed)
    }

    func testParentStopCompletesSubagentsItDoesNotListAsRunning() {
        let engine = StatusEngine()
        for agent in ["listed", "dead"] {
            engine.ingest(provider: "claude", line: claudeLine("PreToolUse", at: 1, ["session_id": .string("s"), "agent_id": .string(agent)]))
        }
        // No list (a Codex or older payload): nothing is closed.
        engine.ingest(provider: "claude", line: claudeLine("Stop", at: 2, ["session_id": .string("s")]))
        // A subagent's own Stop never closes its siblings.
        engine.ingest(provider: "claude", line: claudeLine("SubagentStop", at: 3, [
            "session_id": .string("s"), "agent_id": .string("other"), "background_task_ids": .array([]),
        ]))
        XCTAssertEqual(engine.statuses["claude:agent:dead"]?.mode, .toolRunning)

        engine.ingest(provider: "claude", line: claudeLine("Stop", at: 4, [
            "session_id": .string("s"), "background_task_ids": .array([.string("listed"), .string("bu7j64oq8")]),
        ]))
        XCTAssertEqual(engine.statuses["claude:agent:listed"]?.mode, .toolRunning)
        XCTAssertEqual(engine.statuses["claude:agent:dead"]?.mode, .completed)
        XCTAssertEqual(engine.statuses["claude:agent:dead"]?.eventName, "Stop")

        // Through the hook: a real Stop payload's background_tasks.
        let payload = #"{"hook_event_name":"Stop","session_id":"s","background_tasks":[]}"#
        let record = HookRuntime.makeRecord(provider: .claude, payload: Data(payload.utf8), now: t0.addingTimeInterval(5), origin: nil)
        engine.ingest(provider: "claude", line: record)
        XCTAssertEqual(engine.statuses["claude:agent:listed"]?.mode, .completed)
    }

    // MARK: Codex helper sessions

    func testInternalCodexHelperSessionsAreIgnored() {
        let engine = StatusEngine()
        XCTAssertNil(engine.ingest(provider: "codex", line: codexLine("UserPromptSubmit", at: 0, [
            "session_id": .string("codex-helper"), "cwd": .string("/Users/example/pgit/sidepulse"),
            "prompt": .string("Overview\nGenerate 0 to 3 hyperpersonalized suggestions for what this user might do."),
        ])))
        XCTAssertNil(engine.ingest(provider: "codex", line: codexLine("PostToolUse", at: 0, [
            "session_id": .string("codex-helper"), "cwd": .string("/Users/example/pgit/sidepulse"),
            "tool_name": .string("mcp__codex_apps__gmail__batch_read_email"),
        ])))
        let snapshot = engine.snapshot(now: t0)
        XCTAssertEqual(snapshot.aggregate.mode, .idleReady)
        XCTAssertEqual(snapshot.statuses, [])
        XCTAssertEqual(engine.statuses, [:])
    }

    func testHelperFilterIsCodexOnly() {
        let engine = StatusEngine()
        engine.ingest(provider: "claude", line: claudeLine("UserPromptSubmit", at: 0, [
            "session_id": .string("s"), "prompt": .string("You are an expert at upholding safety and compliance standards."),
        ]))
        XCTAssertEqual(engine.statuses.count, 1)
    }

    // MARK: Display names

    func testSessionDisplayNameUsesPromptContextAfterLaterEvents() throws {
        let engine = StatusEngine()
        let session = "dddddddd-eeee-7fff-8aaa-bbbbbbbbbbbb"
        let prompt = "\n# Files mentioned by the user:\n\n## codex-clipboard.png: /var/folders/tmp/codex-clipboard.png\n\n## My request for Codex:\nteam id YOUR_TEAM_ID, push key '/path/to/AuthKey_YOUR_KEY_ID.p8'\n"
        engine.ingest(provider: "codex", line: codexLine("UserPromptSubmit", at: 0, [
            "session_id": .string(session), "cwd": .string("/Users/pero/pgit/sidepulse"), "prompt": .string(prompt),
        ]))
        engine.ingest(provider: "codex", line: codexLine("PreToolUse", at: 11, [
            "session_id": .string(session), "cwd": .string("/Users/pero/pgit/sidepulse"), "tool_name": .string("Bash"),
        ]))
        let name = try XCTUnwrap(engine.snapshot(now: t0.addingTimeInterval(12)).statuses.first?.displayName)
        XCTAssertEqual(name, "sidepulse: team id YOUR_TEAM_ID, push key '/path/to/AuthKey_YOUR_KEY_ID.p8' (dddddddd)")
    }

    func testCodexDisplayNameUsesSessionIndexThreadName() throws {
        let session = "bbbbbbbb-cccc-7ddd-8eee-ffffffffffff"
        let titles = [session: "Refine README agent status modes"]
        let engine = StatusEngine(codexTitle: { titles[$0] })
        let fields: JSONObject = ["session_id": .string(session), "cwd": .string("/Users/pero/pgit/sidepulse")]
        var prompt = fields
        prompt["prompt"] = .string("Why are we burning so much CPU")
        engine.ingest(provider: "codex", line: codexLine("UserPromptSubmit", at: 0, prompt))
        var tool = fields
        tool["tool_name"] = .string("Bash")
        engine.ingest(provider: "codex", line: codexLine("PreToolUse", at: 0, tool))
        let name = try XCTUnwrap(engine.statuses["codex:session:\(session)"]?.displayName)
        XCTAssertEqual(name, "sidepulse: Refine README agent status modes (bbbbbbbb)")
    }

    func testSessionDisplayNameKeepsInitialPromptTitle() throws {
        let engine = StatusEngine()
        let session = "019ffd37-1458-7d92-b077-3d0f92aedde4"
        let base: JSONObject = ["session_id": .string(session), "cwd": .string("/Users/pero/temp/msdosfs")]
        func line(_ event: String, _ offset: TimeInterval, _ prompt: String?) -> JSONObject {
            var fields = base
            if let prompt { fields["prompt"] = .string(prompt) }
            return claudeLine(event, at: offset, fields)
        }
        engine.ingest(provider: "claude", line: line("UserPromptSubmit", 0, "<user_query>\nWhat is here\n</user_query>"))
        engine.ingest(provider: "claude", line: line("UserPromptSubmit", 30, "<user_query>\nNow check permissions\n</user_query>"))
        engine.ingest(provider: "claude", line: line("Stop", 60, nil))
        let status = try XCTUnwrap(engine.statuses["claude:session:\(session)"])
        XCTAssertEqual(status.displayName, "msdosfs: What is here (019ffd37)")
        XCTAssertEqual(status.mode, .completed)
    }

    func testTaskNotificationDoesNotReplaceSessionDisplayName() throws {
        let engine = StatusEngine()
        let session = "1ca4348e-2aec-4147-9e81-d7d56364d257"
        let fields: JSONObject = ["session_id": .string(session), "cwd": .string("/Users/pero/pgit/sdstatus_bitbang")]
        var first = fields
        first["prompt"] = .string("convert these videos to mp4")
        engine.ingest(provider: "claude", line: claudeLine("UserPromptSubmit", at: 0, first))
        var second = fields
        second["prompt"] = .string("<task-notification><status>completed</status></task-notification>")
        engine.ingest(provider: "claude", line: claudeLine("UserPromptSubmit", at: 245, second))
        let name = try XCTUnwrap(engine.statuses["claude:session:\(session)"]?.displayName)
        XCTAssertEqual(name, "sdstatus_bitbang: convert these videos to mp4 (1ca4348e)")
    }

    func testSubagentRowsInheritSessionTitleAndFallbacks() throws {
        let engine = StatusEngine()
        engine.ingest(provider: "claude", line: claudeLine("UserPromptSubmit", at: 0, [
            "session_id": .string("sess-1234-abcd"), "cwd": .string("/Users/dev/Projects/demo-app"), "prompt": .string("Add a feature"),
        ]))
        engine.ingest(provider: "claude", line: claudeLine("PreToolUse", at: 1, [
            "session_id": .string("sess-1234-abcd"), "agent_id": .string("a72ce317aff816536"), "tool_name": .string("Grep"),
        ]))
        let sub = try XCTUnwrap(engine.statuses["claude:agent:a72ce317aff816536"])
        XCTAssertEqual(sub.displayName, "demo-app: Add a feature (agent a72ce317)")
        XCTAssertTrue(sub.isSubagent)
        XCTAssertNil(sub.cwd, "the row keeps the event's own cwd")

        engine.ingest(provider: "codex", line: codexLine("PreToolUse", at: 2, ["agent_id": .string("zz9900aabb")]))
        XCTAssertEqual(engine.statuses["codex:agent:zz9900aabb"]?.displayName, "Codex agent zz9900aa")
        engine.ingest(provider: "claude", line: claudeLine("Stop", at: 3, ["session_id": .string("bare-session-id")]))
        XCTAssertEqual(engine.statuses["claude:session:bare-session-id"]?.displayName, "Claude session bare-ses")
        engine.ingest(provider: "claude", line: claudeLine("Stop", at: 4))
        XCTAssertEqual(engine.statuses["claude:unknown"]?.displayName, "Claude")
    }

    func testOriginPropagatesFromEarlierEvents() {
        let engine = StatusEngine()
        engine.ingest(provider: "claude", line: claudeLine("UserPromptSubmit", at: 0, ["session_id": .string("s"), "agent_origin": .string("Claude in VS Code")]))
        engine.ingest(provider: "claude", line: claudeLine("Stop", at: 1, ["session_id": .string("s")]))
        XCTAssertEqual(engine.statuses["claude:session:s"]?.origin, "Claude in VS Code")
        engine.ingest(provider: "claude", line: claudeLine("PreToolUse", at: 2, ["session_id": .string("s"), "agent_id": .string("sub")]))
        XCTAssertEqual(engine.statuses["claude:agent:sub"]?.origin, "Claude in VS Code", "subagents inherit the session origin")
    }

    func testLiveIngestUsesArrivalOrder() {
        let engine = StatusEngine()
        engine.ingest(provider: "claude", line: claudeLine("Stop", at: 10, ["session_id": .string("s")]))
        engine.ingest(provider: "claude", line: claudeLine("PreToolUse", at: 5, ["session_id": .string("s")]))
        XCTAssertEqual(engine.statuses["claude:session:s"]?.mode, .toolRunning, "a late, older event still overwrites")
    }

    func testUnknownEventsAreDropped() {
        let engine = StatusEngine()
        XCTAssertNil(engine.ingest(provider: "claude", line: ["hook_event_name": .string("ParseError"), "session_id": .string("s")]))
        XCTAssertEqual(engine.statuses, [:])
    }

    // MARK: Restart: load, reconcile, prune

    func testLoadSeedsTitleSoLabelsSurviveRestart() throws {
        let first = StatusEngine()
        first.ingest(provider: "claude", line: claudeLine("UserPromptSubmit", at: 0, [
            "session_id": .string("abcdef12-3456"), "cwd": .string("/Users/dev/Projects/demo-app"), "prompt": .string("Ship: the release notes"),
            "agent_origin": .string("Claude Code CLI"),
        ]))
        first.ingest(provider: "claude", line: claudeLine("PreToolUse", at: 1, [
            "session_id": .string("abcdef12-3456"), "agent_id": .string("feedface00"), "cwd": .string("/Users/dev/Projects/demo-app"), "tool_name": .string("Bash"),
        ]))
        let restored = Array(first.statuses.values)

        let second = StatusEngine()
        second.load(restored)
        second.ingest(provider: "claude", line: claudeLine("PreToolUse", at: 60, [
            "session_id": .string("abcdef12-3456"), "cwd": .string("/Users/dev/Projects/demo-app"), "tool_name": .string("Bash"),
        ]))
        second.ingest(provider: "claude", line: claudeLine("PostToolUse", at: 61, [
            "session_id": .string("abcdef12-3456"), "agent_id": .string("feedface00"), "tool_name": .string("Bash"),
        ]))
        second.ingest(provider: "claude", line: claudeLine("UserPromptSubmit", at: 62, [
            "session_id": .string("abcdef12-3456"), "prompt": .string("a later prompt must not replace the title"),
        ]))
        XCTAssertEqual(second.statuses["claude:session:abcdef12-3456"]?.displayName, "demo-app: Ship: the release notes (abcdef12)")
        XCTAssertEqual(second.statuses["claude:session:abcdef12-3456"]?.origin, "Claude Code CLI")
        XCTAssertEqual(second.statuses["claude:agent:feedface00"]?.displayName, "demo-app: Ship: the release notes (agent feedface)")
    }

    func testTitleFromDisplayName() {
        func status(_ name: String, cwd: String? = "/Users/dev/Projects/demo-app", key: String = "claude:session:abcdef1234",
                    session: String? = "abcdef1234") -> AgentStatus {
            AgentStatus(provider: "claude", agentID: key, displayName: name, mode: .working, updatedAt: t0,
                        eventName: "Stop", sessionID: session, cwd: cwd)
        }
        XCTAssertEqual(StatusEngine.titleFromDisplayName(status("demo-app: Fix it (abcdef12)")), "Fix it")
        XCTAssertEqual(StatusEngine.titleFromDisplayName(status("Demo App (abcdef12)")), "Demo App")
        XCTAssertNil(StatusEngine.titleFromDisplayName(status("demo-app (abcdef12)")), "project-only label")
        XCTAssertNil(StatusEngine.titleFromDisplayName(status("Claude session abcdef12")), "fallback label")
        XCTAssertNil(StatusEngine.titleFromDisplayName(status("demo-app: a very long title...")), "truncated label")
        XCTAssertNil(StatusEngine.titleFromDisplayName(status("demo-app: Fix it (abcdef12)", cwd: nil)), "no cwd")
        XCTAssertEqual(StatusEngine.titleFromDisplayName(status("demo-app: Fix it (agent 0123abcd)", key: "claude:agent:0123abcdef")),
                       "Fix it")
        XCTAssertNil(StatusEngine.titleFromDisplayName(status("x (y)", key: "claude:unknown", session: nil)))
    }

    func testLoadRefreshesCodexDisplayNameFromSessionIndex() {
        let session = "cccccccc-dddd-7eee-8fff-aaaaaaaaaaaa"
        let titles = [session: "Refine README agent status modes"]
        let engine = StatusEngine(codexTitle: { titles[$0] })
        engine.load([AgentStatus(provider: "codex", agentID: "codex:session:\(session)",
                                 displayName: "sidepulse: Why are we burning so much CPU (cccccccc)", mode: .working,
                                 updatedAt: t0, eventName: "UserPromptSubmit", sessionID: session, cwd: "/Users/pero/pgit/sidepulse")])
        let name = engine.snapshot(now: t0).statuses.first?.displayName
        XCTAssertEqual(name, "sidepulse: Refine README agent status modes (cccccccc)")
    }

    func testReconcileReplacesOnlyWhenNotOlderAndDifferent() {
        func status(_ mode: AgentMode, _ event: String, _ offset: TimeInterval) -> AgentStatus {
            AgentStatus(provider: "codex", agentID: "codex:session:codex-session", displayName: "project: Restart recovery",
                        mode: mode, updatedAt: t0.addingTimeInterval(offset), eventName: event, sessionID: "codex-session",
                        cwd: "/tmp/project")
        }
        // Recovers a Stop missed during restart.
        let engine = StatusEngine()
        engine.load([status(.working, "UserPromptSubmit", -10)])
        XCTAssertTrue(engine.reconcile(with: [status(.completed, "Stop", -5)]))
        XCTAssertEqual(engine.statuses["codex:session:codex-session"]?.eventName, "Stop")
        XCTAssertFalse(engine.reconcile(with: [status(.completed, "Stop", -5)]), "identical rows are not a change")

        // Never replaces a newer cached state.
        let newer = StatusEngine()
        newer.load([status(.completed, "Stop", -5)])
        XCTAssertFalse(newer.reconcile(with: [status(.working, "UserPromptSubmit", -10)]))
        XCTAssertEqual(newer.statuses["codex:session:codex-session"]?.mode, .completed)

        // Equal timestamps: the recovered row wins.
        let tie = StatusEngine()
        tie.load([status(.working, "PreToolUse", -5)])
        XCTAssertTrue(tie.reconcile(with: [status(.completed, "Stop", -5)]))

        let empty = StatusEngine()
        XCTAssertTrue(empty.reconcile(with: [status(.working, "UserPromptSubmit", -10)]))
        XCTAssertEqual(empty.statuses.count, 1)
    }

    func testReconcileKeepsKnownTitleWhenScanWindowMissedTheFirstPrompt() throws {
        let key = "claude:session:abcdef12-3456"
        let fields: JSONObject = ["session_id": .string("abcdef12-3456"), "cwd": .string("/Users/dev/Projects/demo-app")]
        func line(_ event: String, _ offset: TimeInterval, prompt: String? = nil, agent: String? = nil) -> JSONObject {
            var extra = fields
            if let prompt { extra["prompt"] = .string(prompt) }
            if let agent { extra["agent_id"] = .string(agent) }
            return claudeLine(event, at: offset, extra)
        }
        // The live engine saw the whole session and saved it.
        let live = StatusEngine()
        for record in [line("UserPromptSubmit", 0, prompt: "Ship the release notes"),
                       line("UserPromptSubmit", 5, prompt: "and bump the version"),
                       line("PreToolUse", 8, agent: "feedface00"), line("Stop", 10)] {
            live.ingest(provider: "claude", line: record)
        }
        XCTAssertEqual(live.statuses[key]?.displayName, "demo-app: Ship the release notes (abcdef12)")

        // The recovery scan's tail window starts after the first prompt.
        let scan = StatusEngine()
        for record in [line("UserPromptSubmit", 5, prompt: "and bump the version"), line("PreToolUse", 8, agent: "feedface00"),
                       line("Stop", 10)] {
            scan.ingest(provider: "claude", line: record)
        }
        XCTAssertEqual(scan.statuses[key]?.displayName, "demo-app: and bump the version (abcdef12)")

        let restarted = StatusEngine()
        restarted.load(Array(live.statuses.values))
        XCTAssertFalse(restarted.reconcile(with: Array(scan.statuses.values)), "same events; only the scan's labels differ")
        XCTAssertEqual(restarted.statuses[key]?.displayName, "demo-app: Ship the release notes (abcdef12)")
        XCTAssertEqual(restarted.statuses["claude:agent:feedface00"]?.displayName, "demo-app: Ship the release notes (agent feedface)")

        // A newer recovered row is taken but keeps the known label.
        scan.ingest(provider: "claude", line: line("UserPromptSubmit", 20, prompt: "one more thing"))
        scan.ingest(provider: "claude", line: line("Stop", 30))
        XCTAssertTrue(restarted.reconcile(with: Array(scan.statuses.values)))
        let row = try XCTUnwrap(restarted.statuses[key])
        XCTAssertEqual(row.updatedAt, t0.addingTimeInterval(30))
        XCTAssertEqual(row.displayName, "demo-app: Ship the release notes (abcdef12)")

        // Without a known title the scan's label is used (and then remembered).
        let blank = StatusEngine()
        blank.load([AgentStatus(provider: "claude", agentID: key, displayName: "demo-app (abcdef12)", mode: .working,
                                updatedAt: t0.addingTimeInterval(5), eventName: "UserPromptSubmit", sessionID: "abcdef12-3456",
                                cwd: "/Users/dev/Projects/demo-app")])
        XCTAssertTrue(blank.reconcile(with: [try XCTUnwrap(scan.statuses[key])]))
        XCTAssertEqual(blank.statuses[key]?.displayName, "demo-app: and bump the version (abcdef12)")
        blank.ingest(provider: "claude", line: line("PreToolUse", 40))
        XCTAssertEqual(blank.statuses[key]?.displayName, "demo-app: and bump the version (abcdef12)")
    }

    /// Regression: a log scan whose tail window missed a session's Stop took the
    /// idle_prompt that followed as Ask.
    func testIdlePromptWithoutHistoryIsIgnored() {
        let engine = StatusEngine()
        XCTAssertNil(engine.ingest(provider: "claude", line: claudeLine("Notification", at: 60, [
            "session_id": .string("s"), "notification_type": .string(" Idle_Prompt "),
            "message": .string("Claude is waiting for your input"),
        ])))
        XCTAssertNil(engine.statuses["claude:session:s"])
        XCTAssertEqual(engine.ingest(provider: "claude", line: claudeLine("Notification", at: 61, [
            "session_id": .string("s"), "notification_type": .string("permission_prompt"),
            "message": .string("Claude needs your permission to use Edit"),
        ]))?.mode, .waitingForInput)
    }

    func testReconcilePrefersCodexIndexTitleOverRestoredTitle() {
        // A Codex thread renamed while the app was down.
        let session = "cccccccc-dddd-7eee-8fff-aaaaaaaaaaaa"
        let titles = [session: "Renamed thread"]
        func agentRow(_ name: String) -> AgentStatus {
            AgentStatus(provider: "codex", agentID: "codex:agent:0123456789ab", displayName: name, mode: .completed,
                        updatedAt: t0, eventName: "SubagentStop", sessionID: session, cwd: "/tmp/project")
        }
        let engine = StatusEngine(codexTitle: { titles[$0] })
        engine.load([agentRow("project: Old thread name (agent 01234567)")])
        XCTAssertTrue(engine.reconcile(with: [agentRow("project: Renamed thread (agent 01234567)")]))
        XCTAssertEqual(engine.statuses["codex:agent:0123456789ab"]?.displayName, "project: Renamed thread (agent 01234567)")
    }

    func testPruneDropsOldRowsAndTheirState() {
        let engine = StatusEngine(config: MonitorConfig(staleAfter: 3600, retention: 7200))
        let fields: JSONObject = ["session_id": .string("old"), "cwd": .string("/tmp/p"), "tool_name": .string("Bash"), "tool_input": bash("x")]
        engine.ingest(provider: "claude", line: claudeLine("PermissionRequest", at: 0, fields))
        engine.ingest(provider: "claude", line: claudeLine("PreToolUse", at: 7000, ["session_id": .string("new")]))
        XCTAssertEqual(engine.pendingPermissions.count, 1)

        engine.prune(now: t0.addingTimeInterval(7100))
        XCTAssertEqual(engine.statuses.count, 2, "nothing is older than max(staleAfter, retention)")
        engine.prune(now: t0.addingTimeInterval(7300))
        XCTAssertEqual(Array(engine.statuses.keys), ["claude:session:new"])
        XCTAssertEqual(engine.pendingPermissions, [:])

        // The pruned session's metadata is gone too: no title/cwd comes back.
        engine.ingest(provider: "claude", line: claudeLine("Stop", at: 7400, ["session_id": .string("old")]))
        XCTAssertEqual(engine.statuses["claude:session:old"]?.displayName, "Claude session old")
    }
}
