import XCTest
@testable import SidePulseCore

/// Feeds what the OpenCode plugin sent in a recorded OpenCode 2.0.18 run (paths shortened) through the hook
/// runtime and the status engine.
final class StatusOpenCodeTests: XCTestCase {
    private let t0 = TimeFormat.parse("2026-09-26T15:32:08Z")!
    private let origin = #""agent_origin":"OpenCode","agent_origin_kind":"opencode","agent_origin_source":"plugin","agent_origin_confidence":"explicit""#

    private func run(_ steps: [(payload: String, key: String, mode: AgentMode)], engine: StatusEngine = StatusEngine(),
                     file: StaticString = #filePath, line: UInt = #line) -> StatusEngine {
        for (index, step) in steps.enumerated() {
            let payload = step.payload.dropLast() + "," + origin + "}"
            let record = HookRuntime.makeRecord(provider: .opencode, payload: Data(payload.utf8),
                                                now: t0.addingTimeInterval(Double(index)), origin: nil)
            engine.ingest(provider: "opencode", line: record)
            XCTAssertEqual(engine.statuses[step.key]?.mode, step.mode, "step \(index): \(step.payload)", file: file, line: line)
        }
        return engine
    }

    func testRecordedRunReachesEveryMode() throws {
        let a = "opencode:session:ses_f21a79fcdffeCyUagv2m6nYgg1"
        let b = "opencode:session:ses_f21a780deffeNxF4w7A05HFVt7"
        let c = "opencode:session:ses_f21a77012ffevs2QjXiDKFCmRk"
        let d = "opencode:session:ses_f21a76392ffezchKrN5VHPpriB"
        let sub = "opencode:agent:ses_f21a75481ffeHAfkHcYaH3t3yL"
        let engine = run([
            (#"{"hook_event_name":"SessionStart","session_id":"ses_f21a79fcdffeCyUagv2m6nYgg1","cwd":"/work/projA"}"#, a, .idleReady),
            (#"{"hook_event_name":"UserPromptSubmit","session_id":"ses_f21a79fcdffeCyUagv2m6nYgg1","cwd":"/work/projA","prompt":"Run the shell command 'echo hi' with your shell tool, then reply with the single word: done"}"#, a, .working),
            (#"{"hook_event_name":"PreToolUse","session_id":"ses_f21a79fcdffeCyUagv2m6nYgg1","cwd":"/work/projA","tool_name":"shell","tool_input":{"command":"echo hi"}}"#, a, .toolRunning),
            (#"{"hook_event_name":"PostToolUse","session_id":"ses_f21a79fcdffeCyUagv2m6nYgg1","cwd":"/work/projA","tool_name":"shell","tool_input":{"command":"echo hi"},"tool_response":{"exit_code":0}}"#, a, .working),
            (#"{"hook_event_name":"Stop","session_id":"ses_f21a79fcdffeCyUagv2m6nYgg1","cwd":"/work/projA","last_assistant_message":"finished"}"#, a, .completed),

            (#"{"hook_event_name":"SessionStart","session_id":"ses_f21a780deffeNxF4w7A05HFVt7","cwd":"/work/projB"}"#, b, .idleReady),
            (#"{"hook_event_name":"UserPromptSubmit","session_id":"ses_f21a780deffeNxF4w7A05HFVt7","cwd":"/work/projB","prompt":"Use your read tool to read the file /work/outside/note.txt and reply with its content."}"#, b, .working),
            (#"{"hook_event_name":"PreToolUse","session_id":"ses_f21a780deffeNxF4w7A05HFVt7","cwd":"/work/projB","tool_name":"read"}"#, b, .toolRunning),
            (#"{"hook_event_name":"PermissionRequest","session_id":"ses_f21a780deffeNxF4w7A05HFVt7","cwd":"/work/projB","tool_name":"read","message":"OpenCode needs permission: external_directory /work/outside/*"}"#, b, .waitingForInput),
            (#"{"hook_event_name":"PostToolUseFailure","session_id":"ses_f21a780deffeNxF4w7A05HFVt7","cwd":"/work/projB","tool_name":"read","error":"The user declined this tool call"}"#, b, .blockedError),
            (#"{"hook_event_name":"Interrupt","session_id":"ses_f21a780deffeNxF4w7A05HFVt7","cwd":"/work/projB","reason":"shutdown"}"#, b, .idleReady),

            (#"{"hook_event_name":"SessionStart","session_id":"ses_f21a77012ffevs2QjXiDKFCmRk","cwd":"/work/projB"}"#, c, .idleReady),
            (#"{"hook_event_name":"UserPromptSubmit","session_id":"ses_f21a77012ffevs2QjXiDKFCmRk","cwd":"/work/projB","prompt":"Reply with one short sentence that asks me whether you should also add unit tests."}"#, c, .working),
            (#"{"hook_event_name":"Stop","session_id":"ses_f21a77012ffevs2QjXiDKFCmRk","cwd":"/work/projB","last_assistant_message":"Should I also add unit tests for this?"}"#, c, .completed),

            (#"{"hook_event_name":"SessionStart","session_id":"ses_f21a76392ffezchKrN5VHPpriB","cwd":"/work/projA"}"#, d, .idleReady),
            (#"{"hook_event_name":"UserPromptSubmit","session_id":"ses_f21a76392ffezchKrN5VHPpriB","cwd":"/work/projA","prompt":"Use your subagent tool to start a 'general' subagent."}"#, d, .working),
            (#"{"hook_event_name":"PreToolUse","session_id":"ses_f21a76392ffezchKrN5VHPpriB","cwd":"/work/projA","tool_name":"subagent"}"#, d, .toolRunning),
            (#"{"hook_event_name":"SubagentStart","session_id":"ses_f21a76392ffezchKrN5VHPpriB","cwd":"/work/projA","agent_id":"ses_f21a75481ffeHAfkHcYaH3t3yL","agent_type":"general"}"#, sub, .working),
            (#"{"hook_event_name":"PreToolUse","session_id":"ses_f21a76392ffezchKrN5VHPpriB","cwd":"/work/projA","agent_id":"ses_f21a75481ffeHAfkHcYaH3t3yL","agent_type":"general","tool_name":"shell","tool_input":{"command":"echo sub"}}"#, sub, .toolRunning),
            (#"{"hook_event_name":"PostToolUse","session_id":"ses_f21a76392ffezchKrN5VHPpriB","cwd":"/work/projA","agent_id":"ses_f21a75481ffeHAfkHcYaH3t3yL","agent_type":"general","tool_name":"shell","tool_input":{"command":"echo sub"},"tool_response":{"exit_code":0}}"#, sub, .working),
            (#"{"hook_event_name":"SubagentStop","session_id":"ses_f21a76392ffezchKrN5VHPpriB","cwd":"/work/projA","agent_id":"ses_f21a75481ffeHAfkHcYaH3t3yL","agent_type":"general","last_assistant_message":"The exact output of `echo sub` is:\n\n```\nsub\n```"}"#, sub, .completed),
            (#"{"hook_event_name":"PostToolUse","session_id":"ses_f21a76392ffezchKrN5VHPpriB","cwd":"/work/projA","tool_name":"subagent"}"#, d, .working),
            (#"{"hook_event_name":"Stop","session_id":"ses_f21a76392ffezchKrN5VHPpriB","cwd":"/work/projA","last_assistant_message":"done"}"#, d, .completed),
        ])

        let first = try XCTUnwrap(engine.statuses[a])
        XCTAssertEqual(first.provider, "opencode")
        XCTAssertEqual(first.origin, "OpenCode")
        XCTAssertEqual(first.displayName, "projA: Run the shell command 'echo hi' with your shell tool, then reply with... (2m6nYgg1)")
        XCTAssertEqual(SessionRows.detail(for: first, now: t0.addingTimeInterval(30)), "Done \u{b7} Stop \u{b7} 26s ago \u{b7} OpenCode")
        XCTAssertEqual(engine.statuses[sub]?.sessionID, "ses_f21a76392ffezchKrN5VHPpriB")
        XCTAssertEqual(engine.snapshot(now: t0.addingTimeInterval(30)).aggregate.mode, .completed)
    }

    func testFailuresQuestionToolAndApprovedShellCommands() {
        let s = "opencode:session:ses_x"
        _ = run([
            (#"{"hook_event_name":"UserPromptSubmit","session_id":"ses_x","cwd":"/work/p","prompt":"clean up"}"#, s, .working),
            (#"{"hook_event_name":"PreToolUse","session_id":"ses_x","tool_name":"shell","tool_input":{"command":"rm -rf build"}}"#, s, .toolRunning),
            (#"{"hook_event_name":"PermissionRequest","session_id":"ses_x","tool_name":"shell","tool_input":{"command":"rm -rf build"},"message":"OpenCode needs permission: shell rm -rf build"}"#, s, .waitingForInput),
            (#"{"hook_event_name":"PostToolUse","session_id":"ses_x","tool_name":"shell","tool_input":{"command":"rm -rf build"},"tool_response":{"exit_code":0}}"#, s, .working),
            (#"{"hook_event_name":"PreToolUse","session_id":"ses_x","tool_name":"shell","tool_input":{"command":"ls missing"}}"#, s, .toolRunning),
            (#"{"hook_event_name":"PostToolUse","session_id":"ses_x","tool_name":"shell","tool_input":{"command":"ls missing"},"tool_response":{"exit_code":1}}"#, s, .blockedError),
            (#"{"hook_event_name":"PreToolUse","session_id":"ses_x","tool_name":"question"}"#, s, .toolRunning),
            (#"{"hook_event_name":"PermissionRequest","session_id":"ses_x","tool_name":"question","message":"OpenCode is asking: Tea or coffee?"}"#, s, .waitingForInput),
            (#"{"hook_event_name":"PostToolUse","session_id":"ses_x","tool_name":"question"}"#, s, .working),
            (#"{"hook_event_name":"Stop","session_id":"ses_x","last_assistant_message":"ready\n\n<!-- sidepulse:ask -->"}"#, s, .completed),
            (#"{"hook_event_name":"UserPromptSubmit","session_id":"ses_x","prompt":"go on"}"#, s, .working),
            (#"{"hook_event_name":"StopFailure","session_id":"ses_x","error":"provider.no-route","error_details":"Model unavailable: opencode/x"}"#, s, .blockedError),
            (#"{"hook_event_name":"UserPromptSubmit","session_id":"ses_x"}"#, s, .working),
            (#"{"hook_event_name":"Stop","session_id":"ses_x","last_assistant_message":"Want me to push?\n<!-- sidepulse:done -->"}"#, s, .completed),
            (#"{"hook_event_name":"SessionEnd","session_id":"ses_x"}"#, s, .completed),
        ])

        let engine = run([
            (#"{"hook_event_name":"StopFailure","session_id":"ses_y","error":"provider.no-route","error_details":"Model unavailable: opencode/x"}"#,
             "opencode:session:ses_y", .blockedError),
        ])
        XCTAssertEqual(engine.statuses["opencode:session:ses_y"]?.message, "Model unavailable: opencode/x")
        XCTAssertEqual(engine.statuses["opencode:session:ses_y"]?.displayName, "OpenCode session ses_y")
    }

    /// Regression: OpenCode sends no SubagentStop for a subagent that failed and never
    /// lists background tasks, so its Blocked row outlived the parent's turn.
    func testParentTurnEndClosesSubagentsThatFailedOrAsked() throws {
        let p = "opencode:session:ses_p"
        let c = "opencode:agent:ses_c"
        let failed = run([
            (#"{"hook_event_name":"UserPromptSubmit","session_id":"ses_p","prompt":"delegate"}"#, p, .working),
            (#"{"hook_event_name":"SubagentStart","session_id":"ses_p","agent_id":"ses_c","agent_type":"general"}"#, c, .working),
            (#"{"hook_event_name":"StopFailure","session_id":"ses_p","agent_id":"ses_c","error":"rate_limit","error_details":"Too many requests"}"#, c, .blockedError),
            (#"{"hook_event_name":"Stop","session_id":"ses_p","last_assistant_message":"The subagent failed."}"#, p, .completed),
        ])
        XCTAssertEqual(failed.statuses[c]?.mode, .completed)
        XCTAssertEqual(failed.statuses[c]?.eventName, "Stop")
        XCTAssertEqual(failed.snapshot(now: t0.addingTimeInterval(60)).aggregate.mode, .completed)

        let asked = run([
            (#"{"hook_event_name":"UserPromptSubmit","session_id":"ses_p","prompt":"delegate"}"#, p, .working),
            (#"{"hook_event_name":"SubagentStart","session_id":"ses_p","agent_id":"ses_c","agent_type":"general"}"#, c, .working),
            (#"{"hook_event_name":"PermissionRequest","session_id":"ses_p","agent_id":"ses_c","tool_name":"question","message":"OpenCode is asking: Which file?"}"#, c, .waitingForInput),
            (#"{"hook_event_name":"StopFailure","session_id":"ses_p","error":"provider.no-route"}"#, p, .blockedError),
        ])
        XCTAssertEqual(asked.statuses[c]?.mode, .completed)

        let interrupted = run([
            (#"{"hook_event_name":"UserPromptSubmit","session_id":"ses_p","prompt":"delegate"}"#, p, .working),
            (#"{"hook_event_name":"SubagentStart","session_id":"ses_p","agent_id":"ses_c","agent_type":"general"}"#, c, .working),
            (#"{"hook_event_name":"PermissionRequest","session_id":"ses_p","agent_id":"ses_c","tool_name":"shell","tool_input":{"command":"rm -rf build"}}"#, c, .waitingForInput),
            (#"{"hook_event_name":"Interrupt","session_id":"ses_p","reason":"user"}"#, p, .idleReady),
        ])
        XCTAssertEqual(interrupted.statuses[c]?.mode, .completed)
        XCTAssertEqual(interrupted.pendingPermissions, [:])
        XCTAssertEqual(interrupted.snapshot(now: t0.addingTimeInterval(60)).aggregate.activeCount, 0)
    }
}
