import XCTest
@testable import SidePulseCore

final class StatusModeClassifierTests: XCTestCase {
    private func event(_ name: String, _ raw: JSONObject = [:]) -> HookEvent {
        HookEvent(provider: "claude", loggedAt: Date(timeIntervalSince1970: 0), eventName: name, raw: raw, sessionID: "s")
    }

    private func mode(_ name: String, _ raw: JSONObject = [:]) -> AgentMode? {
        ModeClassifier.mode(for: event(name, raw))
    }

    func testEventMappingTable() {
        XCTAssertEqual(mode("Interrupt"), .idleReady)
        XCTAssertEqual(mode("PostToolUseFailure"), .blockedError)
        XCTAssertEqual(mode("StopFailure"), .blockedError)
        XCTAssertEqual(mode("PermissionRequest"), .waitingForInput)
        XCTAssertNil(mode("Notification"))
        XCTAssertEqual(mode("PreToolUse"), .toolRunning)
        XCTAssertEqual(mode("PostToolUse"), .working)
        for name in ["UserPromptSubmit", "PreCompact", "PostCompact", "SubagentStart"] {
            XCTAssertEqual(mode(name), .working, name)
        }
        XCTAssertEqual(mode("Stop"), .completed)
        XCTAssertEqual(mode("SubagentStop"), .completed)
        XCTAssertEqual(mode("SessionEnd"), .completed)
        XCTAssertEqual(mode("SessionStart"), .idleReady)
        XCTAssertNil(mode("ParseError"))
    }

    /// The agent's text never picks the state: no question guessing, no markers.
    func testMessageTextNeverChangesTheMode() {
        for text in ["Committed but not pushed. Want me to push?", "Which mode do you see now?",
                     "I need your choice.\n<!-- sidepulse:ask -->", "[sidepulse status: blocked]"] {
            XCTAssertEqual(mode("Stop", ["last_assistant_message": .string(text)]), .completed, text)
            XCTAssertEqual(mode("SubagentStop", ["last_assistant_message": .string(text)]), .completed, text)
            XCTAssertEqual(mode("PreToolUse", ["last_assistant_message": .string(text)]), .toolRunning, text)
        }
        XCTAssertEqual(mode("Stop", ["sidepulse_status": .string("ask"), "sidepulse_mode": .string("ask")]), .completed)
        XCTAssertEqual(mode("Interrupt", ["sidepulse_status": .string("done")]), .idleReady)
        XCTAssertEqual(mode("PermissionRequest", ["message": .string("cat >> AGENTS.md <<'EOF'\n<!-- sidepulse:done -->\nEOF")]),
                       .waitingForInput)
    }

    func testNotificationClassifier() {
        func notification(_ type: String?, _ message: String?) -> AgentMode? {
            var raw = JSONObject()
            if let type { raw["notification_type"] = .string(type) }
            if let message { raw["message"] = .string(message) }
            return mode("Notification", raw)
        }
        // Only the type counts, whatever the message says.
        XCTAssertEqual(notification("idle_prompt", "Claude is waiting for your input"), .waitingForInput)
        XCTAssertEqual(notification("idle_prompt", "Turn complete"), .waitingForInput)
        XCTAssertEqual(notification("permission_prompt", "Task completed"), .waitingForInput)
        XCTAssertEqual(notification(" Elicitation_Dialog ", "Pick one"), .waitingForInput)
        XCTAssertEqual(notification("elicitation_url_dialog", "Open the link"), .waitingForInput)
        XCTAssertEqual(notification("agent_needs_input", "Reviewer is blocked"), .waitingForInput)
        XCTAssertNil(notification(nil, "Claude is waiting for your input"))
        XCTAssertNil(notification(nil, "Task completed; please confirm"))
        XCTAssertNil(mode("Notification", ["notification_type": .null, "message": .string("needs your permission")]))
        XCTAssertNil(notification("other", "done"))
        XCTAssertNil(notification("auth_success", "Authentication successful"))
        XCTAssertNil(notification("elicitation_complete", "please confirm"))
        XCTAssertNil(notification("agent_completed", "Task completed"))
    }

    func testToolResponseFailure() {
        let failed: [JSONValue] = [
            .object(["interrupted": .bool(true)]), .object(["success": .bool(false)]),
            .object(["exit_code": .number("1")]), .object(["exit_code": .number("-9")]),
            .object(["exit_code": .string("0")]), .object(["exit_code": .bool(true)]),
            .string("Error: Exit code: 127"), .string("Traceback (most recent call last)"),
        ]
        let ok: [JSONValue?] = [
            nil, .null, .object([:]), .object(["exit_code": .null]), .object(["exit_code": .number("0")]),
            .object(["exit_code": .number("0.0")]), .object(["exit_code": .bool(false)]),
            .object(["interrupted": .number("1"), "success": .bool(true)]), .string("{}"), .string("exit code: 0"),
            .array([.string("traceback")]), .number("1"),
        ]
        for value in failed { XCTAssertTrue(ModeClassifier.toolResponseLooksFailed(value), "\(value)") }
        for value in ok { XCTAssertFalse(ModeClassifier.toolResponseLooksFailed(value), "\(String(describing: value))") }
    }

    func testPrecomputedToolFailureFlagWins() {
        XCTAssertEqual(mode("PostToolUse", ["tool_response": .object(["exit_code": .number("0")]), "tool_response_failed": .bool(true)]),
                       .blockedError)
        XCTAssertEqual(mode("PostToolUse", ["tool_response": .string("Traceback"), "tool_response_failed": .bool(false)]), .working)
        XCTAssertEqual(mode("PostToolUse", ["tool_response": .string("Traceback"), "tool_response_failed": .string("no")]),
                       .blockedError, "a non-bool flag is ignored")
    }
}
