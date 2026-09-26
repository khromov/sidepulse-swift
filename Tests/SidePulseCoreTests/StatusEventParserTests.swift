import XCTest
@testable import SidePulseCore

final class StatusEventParserTests: XCTestCase {
    private let now = TimeFormat.parse("2026-09-20T12:00:00Z")!

    private func parse(_ provider: String, _ json: String) -> HookEvent? {
        EventParser.parseLine(provider: provider, line: json, now: now)
    }

    func testCanonicalEventNames() {
        for event in EventParser.knownEvents {
            XCTAssertEqual(EventParser.canonicalEventName(event), event)
            XCTAssertEqual(EventParser.canonicalEventName(event.lowercased()), event)
        }
        XCTAssertEqual(EventParser.canonicalEventName("STOP"), "Stop")
        for name in ["", "Unknown", "ParseError", "pre_tool_use", " Stop "] {
            XCTAssertNil(EventParser.canonicalEventName(name), name)
        }
    }

    func testCodexRecord() throws {
        let event = try XCTUnwrap(parse("codex", #"""
        {"logged_at":"2026-09-17T17:41:23Z","hook_event_name":"UserPromptSubmit","session_id":"01a0b075","cwd":"/tmp/p",
         "prompt":"hi","agent_origin":"Codex CLI"}
        """#))
        XCTAssertEqual(event.provider, "codex")
        XCTAssertEqual(event.eventName, "UserPromptSubmit")
        XCTAssertEqual(event.loggedAt, TimeFormat.parse("2026-09-17T17:41:23Z"))
        XCTAssertEqual(event.sessionID, "01a0b075")
        XCTAssertEqual(event.cwd, "/tmp/p")
        XCTAssertEqual(event.origin, "Codex CLI")
        XCTAssertNil(event.message, "prompt is not copied into message")
        XCTAssertEqual(event.raw["prompt"], .string("hi"))
    }

    /// Only the shape `makeRecord` writes is read; the Python hook's wrapper and camelCase keys are not.
    func testOtherShapesAreIgnored() {
        XCTAssertNil(parse("codex", #"{"logged_at":"2026-09-17T17:41:23Z","event":{"hook_event_name":"Stop","session_id":"s"}}"#))
        XCTAssertNil(parse("claude", #"{"hookEventName":"Stop","sessionId":"s"}"#))
        XCTAssertNil(parse("claude", #"{"hook_event_name":1}"#))
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

    func testNumericIDsAreKeptAndOtherTypesDropped() throws {
        let event = try XCTUnwrap(parse("claude", #"{"hook_event_name":"Stop","session_id":42,"agent_id":null,"tool_name":true,"cwd":""}"#))
        XCTAssertEqual(event.sessionID, "42")
        XCTAssertNil(event.agentID)
        XCTAssertNil(event.toolName)
        XCTAssertNil(event.cwd)
    }

    func testMessageFallsBackToLastAssistantMessageThenErrorDetails() throws {
        XCTAssertEqual(parse("claude", #"{"hook_event_name":"Stop","message":"","last_assistant_message":"All set."}"#)?.message, "All set.")
        XCTAssertEqual(parse("opencode", #"{"hook_event_name":"StopFailure","error_details":"boom"}"#)?.message, "boom")
    }

    func testMissingOrBadTimestampUsesNow() throws {
        XCTAssertEqual(parse("claude", #"{"hook_event_name":"Stop","session_id":"s"}"#)?.loggedAt, now)
        XCTAssertEqual(parse("claude", #"{"hook_event_name":"Stop","logged_at":"garbage"}"#)?.loggedAt, now)
    }

    func testInvalidLinesAreDropped() {
        for line in ["", "   ", "{not json", "[1,2]", "\"Stop\"", #"{"hook_event_name":"ParseError","raw":"x"}"#, #"{"session_id":"s"}"#] {
            XCTAssertNil(parse("claude", line), line)
        }
        XCTAssertNotNil(parse("claude", "  {\"hook_event_name\":\"Stop\"}\r\n"))
    }

    func testOriginLabelIsCleaned() {
        XCTAssertEqual(parse("claude", #"{"hook_event_name":"Stop","agent_origin":"  Claude   in VS Code "}"#)?.origin, "Claude in VS Code")
        XCTAssertNil(parse("claude", #"{"hook_event_name":"Stop","agent_origin":"  "}"#)?.origin)
    }
}
