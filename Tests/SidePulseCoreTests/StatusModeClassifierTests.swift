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
        XCTAssertEqual(mode("PermissionDenied"), .blockedError)
        XCTAssertEqual(mode("StopFailure"), .blockedError)
        XCTAssertEqual(mode("PermissionRequest"), .waitingForInput)
        XCTAssertEqual(mode("Notification"), .working)
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

    func testInterruptBeatsMarkersAndMarkersBeatEverythingElse() {
        XCTAssertEqual(mode("Interrupt", ["sidepulse_status": .string("ask")]), .idleReady)
        XCTAssertEqual(mode("PreToolUse", ["sidepulse_status": .string("done")]), .completed)
        XCTAssertEqual(mode("PostToolUseFailure", ["sidepulse_mode": .string("working")]), .working)
        XCTAssertEqual(mode("Notification", ["message": .string("<!-- sidepulse:blocked -->")]), .blockedError)
        XCTAssertEqual(mode("SessionStart", ["sidepulse_status": .string("progress")]), .longTaskProgress)
        XCTAssertEqual(mode("Stop", ["sidepulse_status": .number("1"), "sidepulse_mode": .string("ask")]), .waitingForInput,
                       "non-string fields are skipped")
        XCTAssertEqual(mode("Stop", ["sidepulseStatus": .string("ask")]), .completed, "no camelCase alias for the field")
    }

    func testStopQuestionHeuristicAndMarkers() {
        // Vectors from tests/test_sidepulse.py (last_assistant_message on Stop).
        let vectors: [(String, AgentMode)] = [
            ("Which mode do you see now?", .waitingForInput),
            ("Anything else you want to tweak?\n\n* Cogitated for 40s - 1 shell still running\n\u{203B} recap: We built and deployed the SidePulse Pro/SidePulse Dot product status.", .completed),
            ("Committed as `67b0208` but not pushed. Want me to push?", .waitingForInput),
            ("Now:\n- `Committed but not pushed. Want me to push?` => `Ask`\n- `Which mode do you see now?` => `Ask`\n\nVerified: `42` tests pass.", .completed),
            ("Want me to run `git push`?", .waitingForInput),
            ("No. Nothing in this payload exposes live XYZ.\n\nWhat we can infer from this:\n\n- MQTT print status is useful for uploaded jobs.", .completed),
            ("I need your choice.\n<!-- sidepulse:ask -->", .waitingForInput),
            ("Anything else to tweak?\n<!-- sidepulse:done -->", .completed),
            ("Use:\n```text\n<!-- sidepulse:ask -->\n```", .completed),
        ]
        for (message, expected) in vectors {
            XCTAssertEqual(mode("Stop", ["last_assistant_message": .string(message)]), expected, message)
            XCTAssertEqual(mode("SubagentStop", ["last_assistant_message": .string(message)]), expected, message)
        }
        XCTAssertEqual(mode("Stop", ["last_assistant_message": .string("Done-ish."), "sidepulse_status": .string("ask")]), .waitingForInput)
        XCTAssertEqual(mode("Stop", ["message": .string("Which one?")]), .completed, "the heuristic only reads last_assistant_message")
    }

    func testQuestionHeuristicMatchesPython() {
        // Expected values produced by collector._assistant_message_asks_question.
        let vectors: [(String, Bool)] = [
            ("Hi! What would you like to work on?", false),
            ("- Want me to push?", false),
            ("**Should I** continue?", false),
            ("Done. Should I also update the docs", true),
            ("Should it be done?", false),
            ("Please confirm the deploy target", true),
            ("What changed:", false),
            ("Which option?\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8", true),
            ("Which option?\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8\nLine 9", false),
            ("Where is it?\r\nsummary line", true),
            ("Tests pass.\u{2028}Want me to push?", true),
            ("Could you check the logs?", true),
            ("How does this look", false),
            ("Done!  Want me to open a PR?", true),
            ("anything you'd like me to change?", false),
            ("Recap: should i do x?", false),
            ("```\nWant me to push?\n```", false),
            ("", false),
        ]
        for (message, expected) in vectors {
            XCTAssertEqual(ModeClassifier.assistantMessageAsksQuestion(message), expected, message)
        }
        XCTAssertFalse(ModeClassifier.assistantMessageAsksQuestion(nil))
    }

    func testOfferWordBoundaryUsesPythonWordCharacters() {
        // Python's `\b` treats combining marks and ZWJ as non-word characters (ICU's
        // `\b` does not); letters, digits (incl. No/Nl) and `_` continue the word.
        // Expected values produced by collector._assistant_message_asks_question.
        let vectors: [(String, Bool)] = [
            ("Want me to\u{301} push?", true),
            ("Done. Should I\u{301}", true),
            ("Should we\u{200D}", true),
            ("Want me to, maybe", true),
            ("Should we\u{E9} go", false),
            ("want me to_do it", false),
            ("want me to2", false),
            ("want me to\u{B2}", false),
            ("Should I\u{2163}", false),
            ("Want me to\u{915}", false),
        ]
        for (message, expected) in vectors {
            XCTAssertEqual(ModeClassifier.assistantMessageAsksQuestion(message), expected, message.debugDescription)
        }
    }

    func testMarkerModeMatchesPython() {
        // Expected values produced by collector.explicit_mode_from_message.
        let vectors: [(String, AgentMode?)] = [
            ("<!-- agent-monitor: blocked -->", .blockedError),
            ("<!-- Agent_Monitor:Working -->", .working),
            ("<!-- sidepulse status: progress -->", .longTaskProgress),
            ("[sidepulse mode: idle]", .idleReady),
            ("text <!-- sidepulse:ask --> inline", nil),
            ("<!--\n  sidepulse: ask\n-->", .waitingForInput),
            ("<!-- sidepulse:bogus -->\n<!-- sidepulse:done -->", .completed),
            ("<!-- sidepulse:done -->\n<!-- sidepulse:ask -->", .completed),
            ("[sidepulse status: ask]\n<!-- sidepulse:done -->", .completed),
            ("line\r<!-- sidepulse:ask -->", nil),
            ("line\r\n<!-- sidepulse:ask -->\r\n", .waitingForInput),
            ("line\u{2028}<!-- sidepulse:ask -->", nil),
            ("<!-- SIDEPULSE : Waiting For Input -->", .waitingForInput),
            ("<!-- sidepulse: long task progress -->", .longTaskProgress),
            ("  <!-- sidepulse:tool-running -->  ", .toolRunning),
            ("```\n<!-- sidepulse:ask -->\n```\n<!-- sidepulse:working -->", .working),
            ("no markers here", nil),
        ]
        for (text, expected) in vectors {
            XCTAssertEqual(ModeClassifier.markerMode(in: text), expected, text)
        }
    }

    func testMarkerValueVocabulary() {
        let vectors: [(String, AgentMode?)] = [
            ("ask", .waitingForInput), (" ASK ", .waitingForInput), ("Waiting-For-Input", .waitingForInput),
            ("question", .waitingForInput), ("input", .waitingForInput), ("waiting", .waitingForInput),
            ("blocked", .blockedError), ("error", .blockedError), ("blocked_error", .blockedError),
            ("long task progress", .longTaskProgress), ("progress", .longTaskProgress), ("tool running", .toolRunning),
            ("done!", .completed), ("complete", .completed), ("completed", .completed),
            ("__idle__", .idleReady), ("ready", .idleReady), ("idle_ready", .idleReady), ("working", .working),
            ("nope", nil), ("", nil),
        ]
        for (value, expected) in vectors {
            XCTAssertEqual(ModeClassifier.normalizeMarkerValue(value), expected, value)
        }
    }

    func testExplicitModeReadsLastAssistantMessageThenMessage() {
        XCTAssertEqual(ModeClassifier.explicitMode(raw: ["last_assistant_message": .string(""), "message": .string("<!-- sidepulse:ask -->")]),
                       .waitingForInput)
        XCTAssertNil(ModeClassifier.explicitMode(raw: ["last_assistant_message": .string("hi"), "message": .string("<!-- sidepulse:ask -->")]))
    }

    func testNotificationClassifier() {
        func notification(_ type: String?, _ message: String?) -> AgentMode? {
            var raw = JSONObject()
            if let type { raw["notification_type"] = .string(type) }
            if let message { raw["message"] = .string(message) }
            return mode("Notification", raw)
        }
        XCTAssertEqual(notification("idle_prompt", "Claude is waiting for your input"), .waitingForInput)
        XCTAssertEqual(notification("permission_prompt", "Claude needs your permission"), .waitingForInput)
        XCTAssertEqual(notification("permission_prompt", "Claude Code needs your approval for the plan"), .waitingForInput)
        XCTAssertEqual(notification("agent_needs_input", "X needs your input"), .waitingForInput)
        XCTAssertEqual(notification("idle_prompt", "Turn complete"), .completed)
        XCTAssertEqual(notification("idle_prompt", " Done "), .completed)
        XCTAssertEqual(notification("other", "done"), .working)
        XCTAssertEqual(notification(nil, "Task completed; please confirm"), .completed, "completion wins")
        XCTAssertEqual(notification(nil, "Deploy confirmed"), .waitingForInput, "plain substring: confirmed")
        XCTAssertEqual(notification("heartbeat", "still going"), .working)
        XCTAssertEqual(mode("Notification", ["notification_type": .null, "message": .string("x")]), .working)
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
