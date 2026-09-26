import XCTest
@testable import SidePulseCore

final class StatusEventParserTests: XCTestCase {
    private let now = TimeFormat.parse("2026-09-20T12:00:00Z")!

    private func parse(_ provider: String, _ json: String) -> HookEvent? {
        EventParser.parseLine(provider: provider, line: json, now: now)
    }

    func testCanonicalEventNamesMatchPython() {
        // Expected values produced by sidepulse.providers.canonical_event_name.
        let vectors: [(String, String?)] = [
            ("PreToolUse", "PreToolUse"), ("pre_tool_use", "PreToolUse"), ("preToolUse", "PreToolUse"),
            ("stop", "Stop"), ("STOP", "Stop"), ("subagent_end", "SubagentStop"), ("Subagent-End", "SubagentStop"),
            ("user prompt submit", "UserPromptSubmit"), ("  Stop  ", "Stop"),
            ("PostToolUseFailure", "PostToolUseFailure"), ("post-tool-use-failure", "PostToolUseFailure"),
            ("Unknown", nil), ("ParseError", nil), ("__stop__", "Stop"), ("sessionStart", "SessionStart"),
            ("SESSION_START", "SessionStart"), ("\u{E9} stop", "Stop"), ("", nil), ("   ", nil),
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(EventParser.canonicalEventName(input), expected, input)
        }
        for event in EventParser.knownEvents {
            XCTAssertEqual(EventParser.canonicalEventName(event), event)
            XCTAssertEqual(EventParser.canonicalEventName(EventParser.snakeCase(event)), event)
        }
    }

    func testCodexWrapperIsUnwrapped() throws {
        let event = try XCTUnwrap(parse("codex", #"""
        {"logged_at":"2026-09-17T17:41:23Z","event":{"session_id":"01a0b075","turn_id":"t1","cwd":"/tmp/p",
         "hook_event_name":"UserPromptSubmit","prompt":"hi","agent_origin":"Codex CLI"}}
        """#))
        XCTAssertEqual(event.provider, "codex")
        XCTAssertEqual(event.eventName, "UserPromptSubmit")
        XCTAssertEqual(event.loggedAt, TimeFormat.parse("2026-09-17T17:41:23Z"))
        XCTAssertEqual(event.sessionID, "01a0b075")
        XCTAssertEqual(event.turnID, "t1")
        XCTAssertEqual(event.cwd, "/tmp/p")
        XCTAssertEqual(event.origin, "Codex CLI")
        XCTAssertNil(event.message, "prompt is not copied into message")
        XCTAssertEqual(event.raw["logged_at"], .string("2026-09-17T17:41:23Z"), "wrapper time copied into raw")
        XCTAssertEqual(event.raw["prompt"], .string("hi"))
    }

    func testWrapperFallsBackToInnerLoggedAt() throws {
        let event = try XCTUnwrap(parse("codex", #"{"event":{"hook_event_name":"Stop","session_id":"s","logged_at":"2026-09-17T10:00:00Z"}}"#))
        XCTAssertEqual(event.loggedAt, TimeFormat.parse("2026-09-17T10:00:00Z"))
    }

    func testFlatRecordWithOwnEventNameIsNotUnwrapped() throws {
        let event = try XCTUnwrap(parse("claude", #"{"hook_event_name":"Stop","session_id":"outer","event":{"hook_event_name":"PreToolUse","session_id":"inner"}}"#))
        XCTAssertEqual(event.eventName, "Stop")
        XCTAssertEqual(event.sessionID, "outer")
    }

    func testOurFlatRecordShape() throws {
        let event = try XCTUnwrap(parse("claude", #"""
        {"logged_at":"2026-09-26T00:31:49.123Z","hook_event_name":"PostToolUse","session_id":"s1","agent_id":"a1",
         "agent_type":"Explore","cwd":"/tmp/p","tool_name":"Bash","tool_input":{"command":"ls"},
         "tool_response":{"exit_code":0},"tool_response_failed":true,"agent_origin":"Claude Code CLI"}
        """#))
        XCTAssertEqual(event.loggedAt.timeIntervalSince1970, TimeFormat.parse("2026-09-26T00:31:49Z")!.timeIntervalSince1970 + 0.123,
                       accuracy: 1e-6)
        XCTAssertEqual(event.statusKey, "claude:agent:a1")
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertEqual(event.raw["tool_response_failed"], .bool(true))
        XCTAssertEqual(event.origin, "Claude Code CLI")
    }

    func testCamelCasePayloadIsNormalized() throws {
        // Port of test_grok_log_line_normalizes_camel_case_payload.
        let event = try XCTUnwrap(parse("grok", #"""
        {"hookEventName":"pre_tool_use","sessionId":"grok-session","workspaceRoot":"/tmp/project",
         "toolName":"run_terminal_command","toolInput":{"command":"date"},"timestamp":"2026-07-18T12:00:00Z"}
        """#))
        XCTAssertEqual(event.provider, "grok")
        XCTAssertEqual(event.eventName, "PreToolUse")
        XCTAssertEqual(event.sessionID, "grok-session")
        XCTAssertEqual(event.cwd, "/tmp/project")
        XCTAssertEqual(event.toolName, "run_terminal_command")
        XCTAssertEqual(event.raw["tool_input"], .object(["command": .string("date")]))
        XCTAssertEqual(event.raw["hook_event_name"], .string("PreToolUse"))
        XCTAssertEqual(event.raw["logged_at"], .string("2026-07-18T12:00:00Z"))
        XCTAssertEqual(event.loggedAt, TimeFormat.parse("2026-07-18T12:00:00Z"))
    }

    func testProviderIsPassedThroughWithoutGrokSniffing() throws {
        // Python re-labelled this Claude-log line as "grok"; the Swift port keeps the
        // provider it was given but still normalizes the camelCase keys.
        let event = try XCTUnwrap(parse("claude", #"""
        {"hookEventName":"notification","sessionId":"019f7724-da8c-7df0-b41d-bda99e0cac9f",
         "workspaceRoot":"/Users/pero/git/ai_food/","transcriptPath":"/Users/pero/.grok/sessions/x/updates.jsonl",
         "notificationType":"idle_prompt","message":"Turn complete","timestamp":"2026-07-18T21:55:14Z"}
        """#))
        XCTAssertEqual(event.provider, "claude")
        XCTAssertEqual(event.eventName, "Notification")
        XCTAssertEqual(event.raw["notification_type"], .string("idle_prompt"))
        XCTAssertEqual(event.message, "Turn complete")
        XCTAssertEqual(ModeClassifier.mode(for: event), .completed)
    }

    func testSnakeKeysWinOverCamelAliases() throws {
        let event = try XCTUnwrap(parse("claude", #"{"hook_event_name":"Stop","session_id":"snake","sessionId":"camel","cwd":"","workspaceRoot":"/w"}"#))
        XCTAssertEqual(event.raw["session_id"], .string("snake"))
        XCTAssertEqual(event.sessionID, "snake")
        XCTAssertEqual(event.raw["cwd"], .string(""), "an existing (empty) snake key is not replaced")
        XCTAssertEqual(event.cwd, "/w", "empty values fall through to the camelCase spelling")
    }

    func testEventNameKeyPrecedence() throws {
        XCTAssertEqual(parse("claude", #"{"hook_event_name":"","event_name":"stop"}"#)?.eventName, "Stop")
        XCTAssertEqual(parse("claude", #"{"eventName":"SessionEnd"}"#)?.eventName, "SessionEnd")
        XCTAssertNil(parse("claude", #"{"hook_event_name":1,"eventName":"Stop"}"#), "a truthy non-string name is not skipped")
    }

    func testFieldsAreStringifiedLikePython() throws {
        let event = try XCTUnwrap(parse("claude", #"{"hook_event_name":"Stop","session_id":42,"agent_id":null,"message":"","error_details":"boom","tool_name":true}"#))
        XCTAssertEqual(event.sessionID, "42")
        XCTAssertNil(event.agentID)
        XCTAssertEqual(event.toolName, "True")
        XCTAssertEqual(event.message, "boom", "message falls back to error_details")
    }

    func testMessageFallsBackToLastAssistantMessage() throws {
        let event = try XCTUnwrap(parse("claude", #"{"hook_event_name":"Stop","session_id":"s","lastAssistantMessage":"All set."}"#))
        XCTAssertEqual(event.message, "All set.")
        XCTAssertEqual(event.raw["last_assistant_message"], .string("All set."))
    }

    func testMissingOrBadTimestampUsesNow() throws {
        XCTAssertEqual(parse("claude", #"{"hook_event_name":"Stop","session_id":"s"}"#)?.loggedAt, now)
        XCTAssertEqual(parse("claude", #"{"hook_event_name":"Stop","logged_at":"garbage"}"#)?.loggedAt, now)
        XCTAssertEqual(parse("claude", #"{"hook_event_name":"Stop","logged_at":"","timestamp":"2026-07-18T12:00:00+02:00"}"#)?.loggedAt,
                       TimeFormat.parse("2026-07-18T10:00:00Z"))
    }

    func testInvalidLinesAreDropped() {
        for line in ["", "   ", "{not json", "[1,2]", "\"Stop\"", #"{"hook_event_name":"ParseError","raw":"x"}"#, #"{"session_id":"s"}"#] {
            XCTAssertNil(parse("claude", line), line)
        }
        XCTAssertNotNil(parse("claude", "  {\"hook_event_name\":\"Stop\"}\r\n"))
    }

    func testOriginLabel() {
        XCTAssertEqual(EventParser.originLabel(["agent_origin": .string("  Claude   in VS Code ")]), "Claude in VS Code")
        XCTAssertEqual(EventParser.originLabel(["agent_origin": .string("  "), "origin_label": .string("Codex UI")]), "Codex UI")
        XCTAssertEqual(EventParser.originLabel(["agentOrigin": .string("Camel")]), "Camel")
        XCTAssertEqual(EventParser.originLabel(["agent_origin": .number("5"), "agent_origin_label": .string("Label")]), "Label")
        XCTAssertEqual(EventParser.originLabel(["sidepulse_origin": .object(["name": .string("Named")])]), "Named")
        XCTAssertEqual(EventParser.originLabel(["sidepulse_origin": .object(["label": .string(""), "origin": .string("O")])]), "O")
        XCTAssertEqual(EventParser.originLabel(["sidepulse_origin": .string(""), "sidepulseOrigin": .string("Camel S")]), "Camel S")
        XCTAssertNil(EventParser.originLabel(["source": .string("codex-transcripts")]), "transcript sources are not ported")
        XCTAssertNil(EventParser.originLabel([:]))
    }
}
