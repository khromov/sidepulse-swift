import Darwin
import XCTest
@testable import SidePulseCore

private let fixedNow = Date(timeIntervalSince1970: 1_790_382_709.125)
private let fixedOrigin = AgentOrigin(label: "Claude Code CLI", kind: "claude_cli", source: "process:claude", confidence: "inferred")

private func hookRecord(_ provider: HookProvider = .claude, _ json: String, origin: AgentOrigin? = nil) -> JSONObject {
    HookRuntime.makeRecord(provider: provider, payload: Data(json.utf8), now: fixedNow, origin: origin)
}

private func jsonString(_ object: JSONObject) -> String { JSONValue.object(object).serialized() }

final class HookRuntimeRecordTests: XCTestCase {
    func testFullClaudePayloadIsTrimmedInContractOrder() {
        let payload = """
        {"session_id":"s1","transcript_path":"/Users/k/.claude/projects/x.jsonl","cwd":"/Users/k/src/app",
         "permission_mode":"auto","hook_event_name":"PostToolUse","tool_name":"Bash",
         "tool_input":{"command":"ls -la","description":"List","timeout":600},
         "tool_response":{"stdout":"a\\nb","stderr":"","interrupted":false,"isImage":false},
         "tool_use_id":"toolu_1","agent_id":"a1","agent_type":"Explore","turn_id":"t1",
         "prompt":"hi","last_assistant_message":"done","message":"m","notification_type":"idle_prompt",
         "error":"Exit code 1","error_details":"details","source":"startup","reason":"clear",
         "sidepulse_status":"ask","sidepulse_mode":"working","model":"opus"}
        """
        let result = hookRecord(.claude, payload, origin: fixedOrigin)
        XCTAssertEqual(result.keys, [
            "logged_at", "hook_event_name", "session_id", "turn_id", "agent_id", "agent_type", "cwd", "tool_name",
            "tool_input", "tool_response", "tool_response_failed", "prompt", "last_assistant_message", "message",
            "notification_type", "error", "error_details", "source", "reason", "sidepulse_status", "sidepulse_mode",
            "agent_origin", "agent_origin_kind", "agent_origin_source", "agent_origin_confidence",
        ])
        XCTAssertEqual(jsonString(result), #"{"logged_at":"2026-09-26T00:31:49.125Z","hook_event_name":"PostToolUse","session_id":"s1","turn_id":"t1","agent_id":"a1","agent_type":"Explore","cwd":"/Users/k/src/app","tool_name":"Bash","tool_input":{"command":"ls -la"},"tool_response":{"interrupted":false},"tool_response_failed":false,"prompt":"hi","last_assistant_message":"done","message":"m","notification_type":"idle_prompt","error":"Exit code 1","error_details":"details","source":"startup","reason":"clear","sidepulse_status":"ask","sidepulse_mode":"working","agent_origin":"Claude Code CLI","agent_origin_kind":"claude_cli","agent_origin_source":"process:claude","agent_origin_confidence":"inferred"}"#)
    }

    func testAbsentValuesAreOmitted() {
        XCTAssertEqual(jsonString(hookRecord(.claude, #"{"hook_event_name":"Stop","session_id":"s1"}"#)),
                       #"{"logged_at":"2026-09-26T00:31:49.125Z","hook_event_name":"Stop","session_id":"s1"}"#)
        XCTAssertEqual(jsonString(hookRecord(.claude, #"{"hook_event_name":"Stop","session_id":"","cwd":null,"message":""}"#)),
                       #"{"logged_at":"2026-09-26T00:31:49.125Z","hook_event_name":"Stop"}"#)
    }

    func testLoggedAtUsesMillisecondUTC() {
        XCTAssertEqual(hookRecord(.claude, "{}")["logged_at"], .string(TimeFormat.iso8601Millis(fixedNow)))
        XCTAssertEqual(hookRecord(.claude, "{}")["logged_at"], .string("2026-09-26T00:31:49.125Z"))
        XCTAssertEqual(hookRecord(.claude, #"{"logged_at":"1999-01-01T00:00:00Z"}"#)["logged_at"], .string("2026-09-26T00:31:49.125Z"))
    }

    func testToolInputKeepsOnlyStringCommand() {
        XCTAssertNil(hookRecord(.claude, #"{"tool_input":{"file_path":"/a","content":"x"}}"#)["tool_input"])
        XCTAssertNil(hookRecord(.claude, #"{"tool_input":{"command":["ls"]}}"#)["tool_input"])
        XCTAssertNil(hookRecord(.claude, #"{"tool_input":"ls"}"#)["tool_input"])
        let long = String(repeating: "c", count: 2500)
        XCTAssertEqual(hookRecord(.claude, #"{"tool_input":{"command":"\#(long)"}}"#)["tool_input"]?["command"],
                       .string(String(repeating: "c", count: 2000)))
    }

    func testToolResponseObjectFilteringAndFailure() {
        let cases: [(String, String?, Bool)] = [
            (#"{"stdout":"x","stderr":"","interrupted":false,"isImage":false}"#, #"{"interrupted":false}"#, false),
            (#"{"interrupted":true}"#, #"{"interrupted":true}"#, true),
            (#"{"success":false,"error":"boom"}"#, #"{"success":false}"#, true),
            (#"{"success":true}"#, #"{"success":true}"#, false),
            (#"{"exit_code":1,"output":"..."}"#, #"{"exit_code":1}"#, true),
            (#"{"exit_code":0}"#, #"{"exit_code":0}"#, false),
            (#"{"exit_code":0.0}"#, #"{"exit_code":0.0}"#, false),
            (#"{"exit_code":null}"#, #"{"exit_code":null}"#, false),
            (#"{"exit_code":"0"}"#, #"{"exit_code":"0"}"#, true), // Python quirk: "0" != 0
            (#"{"exit_code":false}"#, #"{"exit_code":false}"#, false), // Python: False == 0
            (#"{"exit_code":-1}"#, #"{"exit_code":-1}"#, true),
            (#"{"exit_code":1,"success":true,"interrupted":false}"#, #"{"interrupted":false,"success":true,"exit_code":1}"#, true),
            (#"{"stdout":"only"}"#, nil, false),
            ("{}", nil, false),
        ]
        for (response, expected, failed) in cases {
            let result = hookRecord(.claude, #"{"hook_event_name":"PostToolUse","tool_response":\#(response)}"#)
            XCTAssertEqual(result["tool_response"].map { $0.serialized() }, expected, response)
            XCTAssertEqual(result["tool_response_failed"], .bool(failed), response)
        }
    }

    /// Expected values are outputs of Python `_tool_response_looks_failed`.
    func testFailureFlagMatchesPythonEdgeVectors() {
        let vectors: [(String, Bool)] = [
            (#"{"exit_code":1e0}"#, true), (#"{"exit_code":0e5}"#, false), (#"{"exit_code":-0}"#, false),
            (#"{"exit_code":1e400}"#, true), (#"{"exit_code":true}"#, true), (#"{"exit_code":[]}"#, true),
            (#"{"exit_code":{}}"#, true), (#"{"exit_code":""}"#, true), (#"{"interrupted":1}"#, false),
            (#"{"success":0}"#, false), (#"{"success":null}"#, false), (#"{"interrupted":"true"}"#, false),
            (#""EXIT CODE: 12""#, true), (#""exit code:1""#, false), (#""TRACEBACK""#, true), ("[]", false), ("5", false),
            // Python's `in` compares code points, which an old grapheme-based comparison missed.
            (#""Exit code: 1\u0301""#, true),
        ]
        for (json, failed) in vectors {
            XCTAssertEqual(hookRecord(.claude, #"{"tool_response":\#(json)}"#)["tool_response_failed"], .bool(failed), json)
        }
    }

    func testToolResponseStringTruncatedButClassifiedOnFullText() {
        let cases: [(String, Bool)] = [
            ("Exit code: 1\nfoo", true),
            ("exit code: 127", true),
            ("EXIT CODE: 1", true),
            ("Traceback (most recent call last):", true),
            ("Exit code: 0", false),
            ("all good", false),
            ("", false),
        ]
        for (text, failed) in cases {
            let payload = JSONValue.object(["tool_response": .string(text)]).serialized()
            XCTAssertEqual(hookRecord(.claude, payload)["tool_response_failed"], .bool(failed), text)
        }
        let long = String(repeating: "o", count: 800) + " Traceback"
        let result = hookRecord(.claude, JSONValue.object(["tool_response": .string(long)]).serialized())
        XCTAssertEqual(result["tool_response"], .string(String(repeating: "o", count: 500)))
        XCTAssertEqual(result["tool_response_failed"], .bool(true))
    }

    func testToolResponseOtherTypes() {
        for response in ["[1,2]", "5", "true"] {
            let result = hookRecord(.claude, #"{"tool_response":\#(response)}"#)
            XCTAssertNil(result["tool_response"], response)
            XCTAssertEqual(result["tool_response_failed"], .bool(false), response)
        }
        let null = hookRecord(.claude, #"{"tool_response":null}"#)
        XCTAssertNil(null["tool_response"])
        XCTAssertNil(null["tool_response_failed"])
    }

    func testFieldLimits() {
        func value(_ key: String, _ length: Int) -> JSONValue? {
            let payload = JSONValue.object([key: .string(String(repeating: "z", count: length))]).serialized()
            return hookRecord(.claude, payload)[key]
        }
        XCTAssertEqual(value("prompt", 5000), .string(String(repeating: "z", count: 4000)))
        XCTAssertEqual(value("prompt", 4000), .string(String(repeating: "z", count: 4000)))
        XCTAssertEqual(value("message", 3000), .string(String(repeating: "z", count: 2000)))
        XCTAssertEqual(value("error", 600), .string(String(repeating: "z", count: 500)))
        XCTAssertEqual(value("error_details", 700), .string(String(repeating: "z", count: 500)))
        XCTAssertEqual(value("session_id", 5000), .string(String(repeating: "z", count: HookRuntime.defaultFieldLimit)))
        XCTAssertEqual(value("cwd", 300), .string(String(repeating: "z", count: 300)))
    }

    func testLastAssistantMessageKeepsHeadAndTail() {
        let exact = String(repeating: "a", count: 16000)
        XCTAssertEqual(hookRecord(.claude, JSONValue.object(["last_assistant_message": .string(exact)]).serialized())["last_assistant_message"],
                       .string(exact))

        let long = String(repeating: "h", count: 4000) + String(repeating: "m", count: 5000) + String(repeating: "t", count: 12000)
        let trimmed = hookRecord(.claude, JSONValue.object(["last_assistant_message": .string(long)]).serialized())["last_assistant_message"]?.stringValue
        XCTAssertEqual(trimmed, String(repeating: "h", count: 4000) + "\n\u{2026}\n" + String(repeating: "t", count: 12000))
        XCTAssertEqual(trimmed?.unicodeScalars.count, 16003)
    }

    func testLastAssistantMessageDropsFencedCode() {
        func message(_ text: String) -> JSONValue? {
            hookRecord(.claude, JSONValue.object(["last_assistant_message": .string(text)]).serialized())["last_assistant_message"]
        }
        XCTAssertEqual(message("Done.\n```swift\nlet x = 1\n```\nbye"), .string("Done.\n\nbye"))
        XCTAssertEqual(message("one ``` unpaired fence"), .string("one ``` unpaired fence"))
        XCTAssertNil(message("```\nonly code\n```"))
        XCTAssertNil(message(""))
        // The limits apply to what is left.
        let long = String(repeating: "h", count: 4000) + "```" + String(repeating: "c", count: 30_000) + "```"
            + String(repeating: "t", count: 15_000)
        XCTAssertEqual(message(long)?.stringValue?.unicodeScalars.count, 16003)
    }

    /// Regression: a head+tail cut through a code block re-paired the remaining fences, so a long Stop that
    /// is Done in full was logged as asking.
    func testTrimmedMessageClassifiesLikeTheFullMessage() throws {
        func mode(_ object: JSONObject) throws -> AgentMode? {
            ModeClassifier.mode(for: try XCTUnwrap(EventParser.parseRecord(provider: "claude", object: object)))
        }
        func stop(_ text: String) -> JSONObject {
            ["hook_event_name": .string("Stop"), "session_id": .string("s"), "last_assistant_message": .string(text)]
        }
        // A code block opens at scalar 3990, inside the kept head, and closes in the
        // dropped middle; the prose after it keeps the text long after stripping.
        let start = String(repeating: "Prose line.\n", count: 332) + "Here:\n```swift\n"
            + String(repeating: "let value = 1\n", count: 40) + "```\n" + String(repeating: "Details.\n", count: 1450)
        let endings = [
            "Add this line to CLAUDE.md:\n```text\n<!-- sidepulse:ask -->\n```\nAll finished.\n<!-- sidepulse:done -->",
            "Paste this prompt:\n```text\nWhich file should I edit?\n```\nAll finished, tests pass.",
        ]
        for ending in endings {
            let full = start + ending
            XCTAssertEqual(try mode(stop(full)), .completed, ending)
            XCTAssertEqual(try mode(stop(HookRuntime.headAndTail(full))), .waitingForInput, "a fence-blind cut flips it")
            let record = HookRuntime.makeRecord(provider: .claude, payload: Data(JSONValue.object(stop(full)).serialized().utf8),
                                                now: fixedNow, origin: nil)
            XCTAssertEqual(record["last_assistant_message"]?.stringValue?.unicodeScalars.count, 16003, "still trimmed")
            XCTAssertEqual(try mode(record), .completed, ending)
        }
    }

    /// The task shapes are the ones Claude logs.
    func testBackgroundTaskIDs() {
        func ids(_ tasks: String) -> JSONValue? {
            hookRecord(.claude, #"{"hook_event_name":"Stop","background_tasks":\#(tasks)}"#)["background_task_ids"]
        }
        XCTAssertEqual(ids("[]"), .array([]))
        XCTAssertEqual(ids(#"[{"id":"ac12f632eacd952bb","type":"subagent","status":"running","description":"Riso","agent_type":"general-purpose"},"#
                           + #"{"id":"bu7j64oq8","type":"shell","status":"running","command":"bun src/index.ts"}]"#),
                       .array([.string("ac12f632eacd952bb"), .string("bu7j64oq8")]))
        let full = (0..<HookRuntime.maxBackgroundTasks).map { #"{"id":"a\#($0)"}"# }.joined(separator: ",")
        XCTAssertEqual(ids("[\(full)]")?.arrayValue?.count, HookRuntime.maxBackgroundTasks)
        XCTAssertNil(ids("[\(full),{\"id\":\"extra\"}]"), "too many to keep whole")
        let longID = String(repeating: "x", count: HookRuntime.maxBackgroundTaskIDLength + 1)
        for bad in [#"[{"id":"\#(longID)"}]"#, #"[{"id":"a"},{"type":"shell"}]"#, #"[{"id":7}]"#, #"[{"id":""}]"#, #"["a"]"#,
                    #"{"id":"a"}"#, "null"] {
            XCTAssertNil(ids(bad), bad)
        }
        XCTAssertEqual(hookRecord(.claude, #"{"backgroundTasks":[{"id":"a"}]}"#)["background_task_ids"], .array([.string("a")]))
        XCTAssertNil(hookRecord(.claude, #"{"hook_event_name":"Stop"}"#)["background_task_ids"])
        XCTAssertEqual(hookRecord(.claude, #"{"sidepulse_status":"done","background_tasks":[],"reason":"r"}"#).keys,
                       ["logged_at", "reason", "background_task_ids", "sidepulse_status"])
    }

    func testLengthsCountUnicodeScalars() {
        let emoji = String(repeating: "\u{1F600}", count: 4001)
        let prompt = hookRecord(.claude, JSONValue.object(["prompt": .string(emoji)]).serialized())["prompt"]?.stringValue
        XCTAssertEqual(prompt, String(repeating: "\u{1F600}", count: 4000))
    }

    func testCodexWrappedPayloadIsUnwrapped() {
        let wrapped = #"{"logged_at":"2026-09-17T17:41:23Z","event":{"session_id":"c1","turn_id":"t1","hook_event_name":"UserPromptSubmit","prompt":"hi","agent_origin":"Codex CLI","agent_origin_kind":"codex_cli","agent_origin_source":"process:codex","agent_origin_confidence":"inferred"}}"#
        XCTAssertEqual(jsonString(hookRecord(.codex, wrapped, origin: fixedOrigin)),
                       #"{"logged_at":"2026-09-26T00:31:49.125Z","hook_event_name":"UserPromptSubmit","session_id":"c1","turn_id":"t1","prompt":"hi","agent_origin":"Codex CLI","agent_origin_kind":"codex_cli","agent_origin_source":"process:codex","agent_origin_confidence":"inferred"}"#)
        XCTAssertEqual(hookRecord(.codex, #"{"hook_event_name":"Stop","session_id":"c2"}"#)["session_id"], .string("c2"))
        // Only Codex payloads are unwrapped.
        XCTAssertNil(hookRecord(.claude, #"{"event":{"hook_event_name":"Stop"}}"#)["hook_event_name"])
    }

    func testInvalidJSONBecomesParseError() throws {
        let result = hookRecord(.claude, "definitely not json", origin: fixedOrigin)
        XCTAssertEqual(result.keys, ["logged_at", "hook_event_name", "parse_error"])
        XCTAssertEqual(result["hook_event_name"], .string("ParseError"))
        XCTAssertTrue(try XCTUnwrap(result["parse_error"]?.stringValue).contains("Invalid JSON"))
        // Whitespace-only is a parse error too (Python json.loads semantics).
        XCTAssertEqual(hookRecord(.claude, "   \n\t ")["hook_event_name"], .string("ParseError"))
        XCTAssertEqual(hookRecord(.claude, #"{"hook_event_name": "PreToo"#)["hook_event_name"], .string("ParseError"))
    }

    func testNonObjectJSONBecomesParseError() {
        let cases = ["null": "null", "[1, 2, 3]": "an array", "\"just a string\"": "a string", "42": "a number", "true": "a boolean"]
        for (payload, kind) in cases {
            let result = hookRecord(.claude, payload)
            XCTAssertEqual(result["hook_event_name"], .string("ParseError"), payload)
            XCTAssertEqual(result["parse_error"], .string("Expected a JSON object, got \(kind)"), payload)
        }
    }

    func testEmptyPayloadCountsAsEmptyObject() {
        XCTAssertEqual(jsonString(hookRecord(.claude, "", origin: fixedOrigin)),
                       #"{"logged_at":"2026-09-26T00:31:49.125Z","agent_origin":"Claude Code CLI","agent_origin_kind":"claude_cli","agent_origin_source":"process:claude","agent_origin_confidence":"inferred"}"#)
    }

    func testPayloadOriginWinsAndSkipsDetection() {
        let payload = #"{"hook_event_name":"Stop","agent_origin":"Claude in VS Code","agent_origin_kind":"claude_vscode"}"#
        let result = HookRuntime.makeRecord(provider: .claude, payload: Data(payload.utf8), now: fixedNow) {
            XCTFail("origin detection must be skipped when the payload has one")
            return fixedOrigin
        }
        XCTAssertEqual(result["agent_origin"], .string("Claude in VS Code"))
        XCTAssertEqual(result["agent_origin_kind"], .string("claude_vscode"))
        XCTAssertNil(result["agent_origin_source"])
        XCTAssertEqual(hookRecord(.claude, #"{"agentOrigin":"Custom"}"#, origin: fixedOrigin)["agent_origin"], .string("Custom"))
        XCTAssertEqual(hookRecord(.claude, #"{"hook_event_name":"Stop"}"#, origin: fixedOrigin)["agent_origin_source"], .string("process:claude"))
        XCTAssertNil(hookRecord(.claude, #"{"hook_event_name":"Stop"}"#)["agent_origin"])
    }

    func testCamelCaseFallbacks() {
        let result = hookRecord(.claude, #"{"hookEventName":"stop","sessionId":"g1","turnId":"t","agentId":"a","toolName":"Read","toolInput":{"command":"x"},"toolResponse":"Traceback","lastAssistantMessage":"bye","notificationType":"idle_prompt"}"#)
        XCTAssertEqual(jsonString(result), #"{"logged_at":"2026-09-26T00:31:49.125Z","hook_event_name":"stop","session_id":"g1","turn_id":"t","agent_id":"a","tool_name":"Read","tool_input":{"command":"x"},"tool_response":"Traceback","tool_response_failed":true,"last_assistant_message":"bye","notification_type":"idle_prompt"}"#)
        XCTAssertEqual(hookRecord(.claude, #"{"sessionId":"camel","session_id":"snake"}"#)["session_id"], .string("snake"))
    }

    func testWrongTypesAreDroppedOrKept() {
        let result = hookRecord(.claude, #"{"hook_event_name":12345,"session_id":[],"cwd":{"a":1},"tool_name":true,"agent_id":7}"#)
        XCTAssertEqual(result["hook_event_name"], .number("12345"))
        XCTAssertEqual(result["agent_id"], .number("7"))
        XCTAssertNil(result["session_id"])
        XCTAssertNil(result["cwd"])
        XCTAssertNil(result["tool_name"])
    }

    /// Regression: numbers and the kept tool_response values were copied without a
    /// cap, so a hostile payload produced a 600 KB "trimmed" record.
    func testHostileValuesCannotBloatTheRecord() {
        let digits = String(repeating: "7", count: 200_000)
        let payload = #"{"hook_event_name":"PostToolUse","session_id":\#(digits),"sessionId":"fallback","turn_id":12,"#
            + #""agent_id":\#(String(repeating: "9", count: HookRuntime.defaultFieldLimit)),"#
            + #""tool_response":{"exit_code":"\#(String(repeating: "e", count: 300_000))","interrupted":[1,2,3],"success":\#(digits)}}"#
        let record = hookRecord(.claude, payload)
        XCTAssertEqual(record["session_id"], .string("fallback"), "an oversized number counts as absent")
        XCTAssertEqual(record["turn_id"], .number("12"))
        XCTAssertEqual(record["agent_id"], .number(String(repeating: "9", count: HookRuntime.defaultFieldLimit)), "at the limit is kept")
        XCTAssertEqual(record["tool_response"],
                       .object(["exit_code": .string(String(repeating: "e", count: HookRuntime.defaultFieldLimit))]))
        XCTAssertEqual(record["tool_response_failed"], .bool(true), "classified on the full value")
        XCTAssertLessThan(jsonString(record).utf8.count, 4_000)

        // A container exit code is dropped from the record but still counts as failed (Python rule).
        let nested = hookRecord(.claude, #"{"tool_response":{"exit_code":{"code":0},"interrupted":false}}"#)
        XCTAssertEqual(nested["tool_response"], .object(["interrupted": .bool(false)]))
        XCTAssertEqual(nested["tool_response_failed"], .bool(true))
    }

    func testBoundedValues() {
        XCTAssertEqual(HookRuntime.bounded(.null, limit: 3), .null)
        XCTAssertEqual(HookRuntime.bounded(.bool(false), limit: 3), .bool(false))
        XCTAssertEqual(HookRuntime.bounded(.number("-1.5"), limit: 4), .number("-1.5"))
        XCTAssertNil(HookRuntime.bounded(.number("-1.25"), limit: 4))
        XCTAssertEqual(HookRuntime.bounded(.string("abcdef"), limit: 4), .string("abcd"))
        XCTAssertNil(HookRuntime.bounded(.array([.null]), limit: 4))
        XCTAssertNil(HookRuntime.bounded(.object(JSONObject()), limit: 4))
    }

    /// Every field at its limit with characters that escape to six bytes, the worst case for one socket message.
    func testWorstCaseRecordFitsInOneSocketMessage() {
        let nasty = String(repeating: "\u{1}", count: 40_000)
        var payload = JSONObject()
        for key in ["hook_event_name", "session_id", "turn_id", "agent_id", "agent_type", "cwd", "tool_name", "prompt",
                    "last_assistant_message", "message", "notification_type", "error", "error_details", "source", "reason",
                    "sidepulse_status", "sidepulse_mode", "agent_origin", "agent_origin_kind", "agent_origin_source",
                    "agent_origin_confidence", "tool_response"] {
            payload[key] = .string(nasty)
        }
        payload["tool_input"] = .object(["command": .string(nasty)])
        let line = jsonString(hookRecord(.claude, JSONValue.object(payload).serialized()))
        XCTAssertLessThan(line.utf8.count, SidePulseConstants.maxEventBytes / 2)
    }

    func testRecordIsOnePhysicalLine() throws {
        let payload = JSONValue.object(["hook_event_name": .string("Stop"),
                                        "last_assistant_message": .string("line1\nline2\r\n\u{2028}\u{2029}\u{0}end")]).serialized()
        let line = jsonString(hookRecord(.claude, payload))
        XCTAssertFalse(line.contains("\n"))
        XCTAssertFalse(line.contains("\r"))
        XCTAssertFalse(line.contains("\u{2028}"))
        XCTAssertEqual(try JSONValue.parse(line)["last_assistant_message"], .string("line1\nline2\r\n\u{2028}\u{2029}\u{0}end"))
    }
}

final class HookRuntimeRunTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var paths: SidePulsePaths!
    private var servers: [EventSocketServer] = []
    private var descriptors: [Int32] = []
    /// An explicit origin keeps results independent of the machine's process tree.
    private let env = ["SIDEPULSE_AGENT_ORIGIN": "Test Rig"]

    override func setUp() {
        super.setUp()
        root = IPCTestSupport.makeShortTempDir("sphk")
        home = root.appendingPathComponent("home", isDirectory: true)
        paths = SidePulsePaths(environment: ["SIDEPULSE_HOME": root.appendingPathComponent("sp").path, "HOME": home.path], home: home)
        XCTAssertTrue(paths.socketPath.hasPrefix(root.path), "tests must never talk to a real socket")
    }

    override func tearDown() {
        servers.forEach { $0.stop() }
        descriptors.forEach { close($0) }
        IPCTestSupport.remove(root)
        super.tearDown()
    }

    private var claudeLog: URL { paths.logFile(for: "claude") }

    private func logLines(_ url: URL? = nil) -> [String] {
        guard let text = FileUtil.readText(url ?? claudeLog) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    @discardableResult
    private func runHook(_ payload: String, arguments: [String] = ["--provider", "claude"],
                         environment: [String: String]? = nil) -> Int32 {
        HookRuntime.run(arguments: arguments, stdin: Data(payload.utf8), environment: environment ?? env,
                        paths: paths, now: fixedNow)
    }

    private func startServer(_ inbox: IPCTestSupport.Inbox<IPCMessage>) throws {
        let server = EventSocketServer(path: paths.socketPath) { message in
            inbox.append(message)
            return nil
        }
        try server.start()
        servers.append(server)
    }

    // MARK: Arguments

    func testProviderArgumentParsing() {
        XCTAssertEqual(HookRuntime.providerArgument(["--provider", "claude"]), .claude)
        XCTAssertEqual(HookRuntime.providerArgument(["--provider=codex"]), .codex)
        XCTAssertEqual(HookRuntime.providerArgument(["--provider", "CODEX"]), .codex)
        XCTAssertEqual(HookRuntime.providerArgument(["hook-log", "--provider", "claude", "--log", "/tmp/x.jsonl", "--event", "Stop"]), .claude)
        XCTAssertEqual(HookRuntime.providerArgument(["--unknown", "--provider", "codex", "--verbose"]), .codex)
        for bad: [String] in [[], ["--provider"], ["--provider="], ["--provider", "grok"], ["--provider", "--log"],
                              ["--log", "/tmp/x.jsonl"], ["--unknown-flag", "value"], ["claude"], ["--providers", "claude"]] {
            XCTAssertNil(HookRuntime.providerArgument(bad), "\(bad)")
        }
    }

    func testBadArgumentsReturnZeroSilentlyWithoutLogging() {
        for arguments: [String] in [[], ["--provider"], ["--provider", "claude-desktop"], ["--log", "/tmp/x.jsonl"],
                                    ["--provider", "grok", "--log", "/tmp/x.jsonl"], ["--unknown-flag", "value"]] {
            let output = IPCTestSupport.captureStandardStreams(in: root) {
                XCTAssertEqual(runHook(#"{"hook_event_name":"Stop"}"#, arguments: arguments), 0)
            }
            XCTAssertEqual(output.count, 0, "\(arguments)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.logsDir.path))
    }

    func testSocketDisabledFlag() {
        for value in ["1", "true", "TRUE", "Yes", " yes "] {
            XCTAssertTrue(HookRuntime.eventSocketDisabled(["SIDEPULSE_DISABLE_EVENT_SOCKET": value]), value)
        }
        for value in ["", "0", "false", "no", "on"] {
            XCTAssertFalse(HookRuntime.eventSocketDisabled(["SIDEPULSE_DISABLE_EVENT_SOCKET": value]), value)
        }
        XCTAssertFalse(HookRuntime.eventSocketDisabled([:]))
    }

    // MARK: Happy path

    func testHappyPathAppendsOneLinePerCall() throws {
        XCTAssertEqual(runHook(#"{"hook_event_name":"Stop","session_id":"s1"}"#), 0)
        var lines = logLines()
        XCTAssertEqual(lines.count, 1)
        let first = try JSONValue.parse(lines[0])
        XCTAssertEqual(first["hook_event_name"], .string("Stop"))
        XCTAssertEqual(first["session_id"], .string("s1"))
        XCTAssertEqual(first["logged_at"], .string("2026-09-26T00:31:49.125Z"))
        XCTAssertEqual(first["agent_origin"], .string("Test Rig"))
        XCTAssertEqual(first["agent_origin_kind"], .string("test_rig"))
        XCTAssertEqual(first["agent_origin_source"], .string("env:SIDEPULSE_AGENT_ORIGIN"))
        XCTAssertEqual(first["agent_origin_confidence"], .string("explicit"))

        for index in 0..<4 { runHook(#"{"hook_event_name":"PreToolUse","session_id":"s\#(index)"}"#) }
        lines = logLines()
        XCTAssertEqual(lines.count, 5, "append, never truncate")

        runHook(#"{"hook_event_name":"Stop","last_assistant_message":"a\nb\nc"}"#)
        XCTAssertEqual(logLines().count, 6, "embedded newlines stay escaped")

        var info = stat()
        XCTAssertEqual(stat(claudeLog.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testCodexGoesToItsOwnLog() throws {
        runHook(#"{"hook_event_name":"Stop","session_id":"c1"}"#, arguments: ["--provider=codex"],
                environment: ["TERM_PROGRAM": "vscode"])
        let lines = logLines(paths.logFile(for: "codex"))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(try JSONValue.parse(lines[0])["agent_origin"], .string("Codex in VS Code"))
        XCTAssertTrue(logLines().isEmpty)
    }

    func testVSCodeEnvironmentStampsOrigin() throws {
        runHook(#"{"hook_event_name":"UserPromptSubmit","session_id":"claude-session","prompt":"hi"}"#,
                environment: ["TERM_PROGRAM": "vscode"])
        let line = try JSONValue.parse(try XCTUnwrap(logLines().first))
        XCTAssertEqual(line["agent_origin"], .string("Claude in VS Code"))
        XCTAssertEqual(line["agent_origin_kind"], .string("claude_vscode"))
    }

    func testEventReachesSocketWithTheLoggedLine() throws {
        let inbox = IPCTestSupport.Inbox<IPCMessage>()
        try startServer(inbox)
        runHook(#"{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"Done."}"#)
        XCTAssertTrue(IPCTestSupport.waitUntil { inbox.count == 1 })
        let logged = try JSONValue.parse(try XCTUnwrap(logLines().first))
        guard case .event(let provider, let line)? = inbox.items.first else { return XCTFail("no event") }
        XCTAssertEqual(provider, "claude")
        XCTAssertEqual(JSONValue.object(line), logged)
    }

    func testDisabledSocketSkipsSend() throws {
        let inbox = IPCTestSupport.Inbox<IPCMessage>()
        try startServer(inbox)
        runHook(#"{"hook_event_name":"Stop"}"#, environment: ["SIDEPULSE_DISABLE_EVENT_SOCKET": "yes", "TERM_PROGRAM": "x"])
        usleep(200_000)
        XCTAssertEqual(inbox.count, 0)
        XCTAssertEqual(logLines().count, 1)
    }

    // MARK: Independence of steps

    func testDeadSocketStillWritesLog() throws {
        try FileManager.default.createDirectory(atPath: (paths.socketPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        IPCTestSupport.makeStaleSocket(at: paths.socketPath)
        let started = Date()
        XCTAssertEqual(runHook(#"{"hook_event_name":"Stop","session_id":"s1"}"#), 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
        XCTAssertEqual(logLines().count, 1)
    }

    func testHungServerCannotStallTheHook() throws {
        try FileManager.default.createDirectory(atPath: (paths.socketPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        descriptors.append(IPCTestSupport.makeSilentListener(at: paths.socketPath))
        let huge = JSONValue.object(["hook_event_name": .string("Stop"),
                                     "last_assistant_message": .string(String(repeating: "q", count: 500_000)),
                                     "prompt": .string(String(repeating: "p", count: 9000))]).serialized()
        for _ in 0..<3 {
            let started = Date()
            XCTAssertEqual(runHook(huge), 0)
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        }
        XCTAssertEqual(logLines().count, 3)
    }

    func testUnwritableLogStillSendsEvent() throws {
        let inbox = IPCTestSupport.Inbox<IPCMessage>()
        try startServer(inbox)
        // The log path is a directory, so the append fails.
        try FileManager.default.createDirectory(at: claudeLog, withIntermediateDirectories: true)
        let output = IPCTestSupport.captureStandardStreams(in: root) {
            XCTAssertEqual(runHook(#"{"hook_event_name":"Stop","session_id":"s1"}"#), 0)
        }
        XCTAssertEqual(output.count, 0)
        XCTAssertTrue(IPCTestSupport.waitUntil { inbox.count == 1 })
    }

    func testReadOnlyLogDirectoryIsSilent() throws {
        try FileManager.default.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
        chmod(paths.logsDir.path, 0o500)
        defer { chmod(paths.logsDir.path, 0o700) }
        let output = IPCTestSupport.captureStandardStreams(in: root) {
            XCTAssertEqual(runHook(#"{"hook_event_name":"Stop"}"#), 0)
        }
        XCTAssertEqual(output.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeLog.path))
    }

    // MARK: Hostile input

    private static func hostilePayloads() -> [(String, Data)] {
        var garbage = [UInt8](repeating: 0, count: 4096)
        for index in garbage.indices { garbage[index] = UInt8(truncatingIfNeeded: index &* 2654435761 >> 7) }
        let text: [(String, String)] = [
            ("empty", ""),
            ("whitespace", "   \n\t "),
            ("prose", "this is not json at all"),
            ("truncated", #"{"hook_event_name": "PreToo"#),
            ("null", "null"),
            ("array", "[1, 2, 3]"),
            ("array of objects", #"[{"hook_event_name":"Stop"}]"#),
            ("string", "\"just a string\""),
            ("number", "42"),
            ("empty object", "{}"),
            ("deeply nested", String(repeating: "{\"a\":", count: 5000) + "1" + String(repeating: "}", count: 5000)),
            ("deep arrays", String(repeating: "[", count: 100_000)),
            ("unicode", #"{"hook_event_name":"Stop","message":"héllo 🚀   世界"}"#),
            ("nul escape", #"{"hook_event_name":"Stop","message":"a\u0000b"}"#),
            ("huge message", JSONValue.object(["hook_event_name": .string("Stop"), "message": .string(String(repeating: "m", count: 500_000))]).serialized()),
            ("huge string", "\"" + String(repeating: "s", count: 2_000_000) + "\""),
            ("wrong types", #"{"hook_event_name":12345,"session_id":[]}"#),
            ("missing event", #"{"session_id":"s1"}"#),
            ("bad escapes", #"{"message":"\x\u12"}"#),
            ("lone surrogate", #"{"hook_event_name":"Stop","message":"\ud800"}"#),
            ("tool types", #"{"tool_input":"x","tool_response":5,"last_assistant_message":[1]}"#),
        ]
        var payloads = text.map { ($0.0, Data($0.1.utf8)) }
        payloads.append(("binary garbage", Data(garbage)))
        payloads.append(("invalid utf8 in string", Data([0x7B, 0x22, 0x6D, 0x22, 0x3A, 0x22, 0xC3, 0x28, 0xFF, 0x22, 0x7D])))
        payloads.append(("raw control chars", Data("{\"message\":\"a\u{01}\n\tb\"}".utf8)))
        return payloads
    }

    func testHostilePayloadsNeverWriteToStdoutOrStderr() throws {
        let payloads = Self.hostilePayloads()
        let output = IPCTestSupport.captureStandardStreams(in: root) {
            for (name, payload) in payloads {
                let code = HookRuntime.run(arguments: ["--provider", "claude"], stdin: payload, environment: [:],
                                           paths: paths, now: fixedNow)
                XCTAssertEqual(code, 0, name)
            }
        }
        XCTAssertEqual(output.count, 0, String(decoding: output.prefix(500), as: UTF8.self))

        let lines = logLines()
        XCTAssertEqual(lines.count, payloads.count, "exactly one line per payload")
        for (line, (name, _)) in zip(lines, payloads) {
            let value = try JSONValue.parse(line)
            XCTAssertNotNil(value.objectValue, name)
            XCTAssertEqual(value["logged_at"], .string("2026-09-26T00:31:49.125Z"), name)
            XCTAssertLessThan(line.utf8.count, 40_000, "\(name) stays trimmed")
        }
    }

    func testHostilePayloadsReachSocketSafely() throws {
        let inbox = IPCTestSupport.Inbox<IPCMessage>()
        try startServer(inbox)
        let payloads = Self.hostilePayloads()
        for (_, payload) in payloads {
            XCTAssertEqual(HookRuntime.run(arguments: ["--provider=codex"], stdin: payload, environment: env, paths: paths, now: fixedNow), 0)
        }
        XCTAssertTrue(IPCTestSupport.waitUntil { inbox.count == payloads.count }, "\(inbox.count)")
    }

    // MARK: Latency

    private static func fiftyKilobytePayload() -> Data {
        let stdout = (0..<700).map { "line \($0): drwxr-xr-x  12 k  staff   384 Sep 26 02:31 Sources/SidePulseCore" }.joined(separator: "\n")
        let payload: JSONObject = [
            "session_id": .string("fd6f0683-7c22-40a8-b03c-dc8bd48b5dd0"),
            "transcript_path": .string("/Users/k/.claude/projects/-Users-k-src/fd6f0683.jsonl"),
            "cwd": .string("/Users/k/Documents/GitHub/sidepulse-swift"),
            "permission_mode": .string("auto"),
            "hook_event_name": .string("PostToolUse"),
            "tool_name": .string("Bash"),
            "tool_input": .object(["command": .string("ls -la Sources"), "description": .string("List")]),
            "tool_response": .object(["stdout": .string(String(stdout.prefix(50_000))), "stderr": .string(""),
                                      "interrupted": .bool(false), "isImage": .bool(false)]),
            "tool_use_id": .string("toolu_01"),
        ]
        return Data(JSONValue.object(payload).serialized().utf8)
    }

    private func measure(_ label: String, environment: [String: String], iterations: Int = 40) -> (median: Double, p95: Double) {
        let payload = Self.fiftyKilobytePayload()
        XCTAssertGreaterThan(payload.count, 49_000)
        _ = HookRuntime.run(arguments: ["--provider", "claude"], stdin: payload, environment: environment, paths: paths)
        var samples: [Double] = []
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = HookRuntime.run(arguments: ["--provider", "claude"], stdin: payload, environment: environment, paths: paths)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        samples.sort()
        let result = (samples[samples.count / 2], samples[Int(Double(samples.count) * 0.95) - 1])
        print(String(format: "HookRuntime latency [%@] payload=%d B median=%.2f ms p95=%.2f ms", label, payload.count, result.0, result.1))
        return result
    }

    func testLatencyFiftyKilobytePayload() throws {
        // Worst case for origin: no env hints, so the process tree is walked.
        let noServer = measure("no server, ancestry walk", environment: [:])
        XCTAssertLessThan(noServer.median, 20, "hook must stay fast")

        let inbox = IPCTestSupport.Inbox<IPCMessage>()
        try startServer(inbox)
        let withServer = measure("live server, ancestry walk", environment: [:])
        XCTAssertLessThan(withServer.median, 20, "hook must stay fast")
        XCTAssertTrue(IPCTestSupport.waitUntil { inbox.count == 41 })
    }
}

final class HookRuntimeLogStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = IPCTestSupport.makeShortTempDir("splog")
    }

    override func tearDown() {
        IPCTestSupport.remove(dir)
        super.tearDown()
    }

    func testCreatesDirectoriesAndPrivateFile() throws {
        let url = dir.appendingPathComponent("deep/logs/claude.jsonl")
        try HookLogStore.append(line: #"{"a":1}"#, to: url)
        try HookLogStore.append(line: #"{"a":2}"#, to: url)
        XCTAssertEqual(FileUtil.readText(url), "{\"a\":1}\n{\"a\":2}\n")
        var info = stat()
        XCTAssertEqual(stat(url.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testRotatesOnlyWhenLargerThanLimit() throws {
        let url = dir.appendingPathComponent("claude.jsonl")
        let rotated = URL(fileURLWithPath: url.path + ".1")
        try HookLogStore.append(line: "12345678", to: url, rotateAt: 18) // 9 bytes
        try HookLogStore.append(line: "12345678", to: url, rotateAt: 18) // 18 bytes: not larger
        try HookLogStore.append(line: "abc", to: url, rotateAt: 18)      // 18 before write: no rotation
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotated.path))
        try HookLogStore.append(line: "new", to: url, rotateAt: 18)      // 22 > 18: rotate first
        XCTAssertEqual(FileUtil.readText(rotated), "12345678\n12345678\nabc\n")
        XCTAssertEqual(FileUtil.readText(url), "new\n")

        try HookLogStore.append(line: String(repeating: "x", count: 30), to: url, rotateAt: 18)
        try HookLogStore.append(line: "latest", to: url, rotateAt: 18)
        XCTAssertEqual(FileUtil.readText(rotated), "new\n" + String(repeating: "x", count: 30) + "\n")
        XCTAssertEqual(FileUtil.readText(url), "latest\n")
    }

    func testZeroRotateLimitDisablesRotation() throws {
        let url = dir.appendingPathComponent("codex.jsonl")
        for _ in 0..<3 { try HookLogStore.append(line: "0123456789", to: url, rotateAt: 0) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".1"))
        XCTAssertEqual(FileUtil.readText(url)?.count, 33)
    }

    func testConcurrentAppendsNeverInterleaveOrLoseLines() throws {
        let url = dir.appendingPathComponent("claude.jsonl")
        let line = String(repeating: "z", count: 3000)
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            try? HookLogStore.append(line: "\(index):" + line, to: url, rotateAt: 64 << 10)
        }
        let current = FileUtil.readText(url) ?? ""
        let previous = FileUtil.readText(URL(fileURLWithPath: url.path + ".1")) ?? ""
        let lines = (previous + current).split(separator: "\n")
        for entry in lines {
            XCTAssertTrue(entry.hasSuffix(line) && entry.split(separator: ":").count == 2, "torn line")
        }
        // Rotation discards everything older than the previous file, but never tears lines.
        XCTAssertGreaterThan(lines.count, 0)
        XCTAssertLessThanOrEqual(lines.count, 200)
    }

    func testFailsForDirectoryTarget() throws {
        let url = dir.appendingPathComponent("claude.jsonl")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try HookLogStore.append(line: "x", to: url))
    }
}

final class HookRuntimeOriginTests: XCTestCase {
    private func detect(_ provider: HookProvider, _ environment: [String: String] = [:],
                        _ processes: [ProcessSnapshot] = []) -> AgentOrigin {
        OriginDetector.detect(provider: provider, environment: environment, ancestry: { processes })
    }

    private func process(_ command: String, comm: String? = nil, path: String? = nil) -> ProcessSnapshot {
        let arguments = command.split(separator: " ").map(String.init)
        return ProcessSnapshot(pid: 100, parentPID: 1, comm: comm ?? (arguments.first.map { ($0 as NSString).lastPathComponent } ?? ""),
                               executablePath: path ?? (arguments.first ?? ""), arguments: arguments)
    }

    func testExplicitOverride() {
        XCTAssertEqual(detect(.claude, ["SIDEPULSE_AGENT_ORIGIN": "  My   Rig ", "TERM_PROGRAM": "vscode"]),
                       AgentOrigin(label: "My Rig", kind: "my_rig", source: "env:SIDEPULSE_AGENT_ORIGIN", confidence: "explicit"))
        XCTAssertEqual(detect(.codex, ["SIDEPULSE_AGENT_ORIGIN": "Remote", "SIDEPULSE_AGENT_ORIGIN_KIND": " remote  box "]).kind, "remote box")
        XCTAssertEqual(detect(.codex, ["SIDEPULSE_AGENT_ORIGIN": "!!!"]).kind, "custom")
        XCTAssertEqual(detect(.codex, ["SIDEPULSE_AGENT_ORIGIN": "   "]).confidence, "unknown")
        XCTAssertEqual(OriginDetector.normalizeKind("Claude in VS Code"), "claude_in_vs_code")
        XCTAssertEqual(OriginDetector.normalizeKind("__Héllo--World__"), "h_llo_world")
        // Python `re.sub('[^a-z0-9]+', '_', label.lower())` on Unicode input.
        XCTAssertEqual(OriginDetector.normalizeKind("\u{212A}elvin"), "kelvin") // KELVIN SIGN lowercases to "k"
        XCTAssertEqual(OriginDetector.normalizeKind("\u{DF}-stra\u{DF}e"), "stra_e")
        XCTAssertEqual(OriginDetector.normalizeKind("\u{130}x"), "i_x")
    }

    func testVSCodeEnvironment() {
        XCTAssertEqual(detect(.claude, ["TERM_PROGRAM": "vscode"]),
                       AgentOrigin(label: "Claude in VS Code", kind: "claude_vscode", source: "env:VSCODE", confidence: "inferred"))
        XCTAssertEqual(detect(.codex, ["TERM_PROGRAM": " VSCode "]).label, "Codex in VS Code")
        XCTAssertEqual(detect(.claude, ["VSCODE_PID": "1"]).label, "Claude in VS Code")
        XCTAssertEqual(detect(.claude, ["VSCODE_GIT_IPC_HANDLE": "x", "TERM_PROGRAM": "iTerm.app"]).source, "env:VSCODE")
    }

    func testBundleIdentifier() {
        XCTAssertEqual(detect(.codex, ["__CFBundleIdentifier": "com.openai.chat"]),
                       AgentOrigin(label: "Codex UI", kind: "codex_app", source: "env:__CFBundleIdentifier", confidence: "inferred"))
        XCTAssertEqual(detect(.codex, ["__CFBundleIdentifier": "com.openai.codex"]).label, "Codex UI")
        XCTAssertEqual(detect(.claude, ["__CFBundleIdentifier": "com.anthropic.claudefordesktop"]).label, "Claude App")
        // A bundle that is not the agent's own falls through to the next rules.
        XCTAssertEqual(detect(.claude, ["__CFBundleIdentifier": "com.openai.chat", "TERM_PROGRAM": "ghostty"]).label, "Claude Code CLI")
        XCTAssertEqual(detect(.codex, ["__CFBundleIdentifier": "com.apple.Terminal"]).label, "Codex")
    }

    func testProcessAncestryEditors() {
        // Python test vectors.
        XCTAssertEqual(detect(.claude, [:], [process("/Applications/Visual Studio Code.app/Contents/MacOS/Electron")]).label,
                       "Claude in VS Code")
        XCTAssertEqual(detect(.claude, [:], [process("claude", comm: "claude", path: "/opt/homebrew/bin/claude")]).label,
                       "Claude Code CLI")
        let chatGPT = process("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT")
        XCTAssertEqual(detect(.codex, [:], [chatGPT]),
                       AgentOrigin(label: "Codex UI", kind: "codex_app", source: "process:Codex.app", confidence: "inferred"))
        XCTAssertEqual(detect(.codex, [:], [process("/Applications/Codex.app/Contents/MacOS/Codex")]).label, "Codex UI")
        XCTAssertEqual(detect(.claude, [:], [chatGPT]).label, "Claude", "ChatGPT.app only identifies Codex")
        XCTAssertEqual(detect(.claude, [:], [process("/Applications/Claude.app/Contents/MacOS/Claude")]).label, "Claude App")

        let cursor = process("/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)")
        XCTAssertEqual(detect(.claude, [:], [cursor]).source, "process:Cursor")
        XCTAssertEqual(detect(.codex, [:], [cursor]).label, "Codex in Cursor")
        let windsurf = process("/Applications/Windsurf.app/Contents/MacOS/Electron")
        XCTAssertEqual(detect(.claude, [:], [windsurf]).label, "Claude in Windsurf")
        XCTAssertEqual(detect(.codex, [:], [process("/x/Code Helper (Plugin)")]).label, "Codex in VS Code")
        XCTAssertEqual(detect(.claude, [:], [process("node /Users/k/.vscode/extensions/anthropic.claude-code/cli.js")]).label,
                       "Claude in VS Code")
    }

    func testEditorAnywhereInAncestryBeatsCLIBasename() {
        let chain = [process("/bin/sh -c hook"), process("claude", comm: "2.1.283", path: "/Users/k/.local/share/claude/versions/2.1.283"),
                     process("/bin/zsh -il"), process("/Applications/Visual Studio Code.app/Contents/MacOS/Code")]
        XCTAssertEqual(detect(.claude, [:], chain).label, "Claude in VS Code")
        XCTAssertEqual(detect(.claude, [:], Array(chain.prefix(3))).label, "Claude Code CLI")
    }

    func testCLIBasenames() {
        // argv[0] wins over the versioned executable name of the native installer.
        XCTAssertEqual(process("claude", comm: "2.1.283", path: "/Users/k/.local/share/claude/versions/2.1.283").basename, "claude")
        XCTAssertEqual(detect(.claude, [:], [process("/usr/local/bin/claude-code --resume")]).source, "process:claude")
        XCTAssertEqual(detect(.codex, [:], [process("/bin/zsh -c x"), process("/opt/homebrew/lib/node_modules/@openai/codex/vendor/codex/codex")]),
                       AgentOrigin(label: "Codex CLI", kind: "codex_cli", source: "process:codex", confidence: "inferred"))
        // Shells, python and env are skipped when picking a basename.
        XCTAssertEqual(process("/bin/sh -c x").basename, "")
        XCTAssertEqual(process("/usr/bin/env node x", comm: "env", path: "/usr/bin/env").basename, "")
        XCTAssertEqual(process("python3 claude", comm: "python3", path: "/usr/bin/python3").basename, "")
        // A node-hosted CLI is not recognised by basename (same as Python).
        XCTAssertEqual(detect(.claude, [:], [process("node /opt/homebrew/bin/claude")]).label, "Claude")
        XCTAssertEqual(detect(.codex, [:], [process("claude")]).label, "Codex")
    }

    func testTerminalFallbackAndUnknown() {
        XCTAssertEqual(detect(.claude, ["TERM_PROGRAM": "Apple_Terminal"]),
                       AgentOrigin(label: "Claude Code CLI", kind: "claude_cli", source: "env:TERM_PROGRAM", confidence: "inferred"))
        XCTAssertEqual(detect(.codex, ["TERM_PROGRAM": "iTerm.app"]).label, "Codex CLI")
        XCTAssertEqual(detect(.claude), AgentOrigin(label: "Claude", kind: "claude_unknown", source: "fallback:provider", confidence: "unknown"))
        XCTAssertEqual(detect(.codex), AgentOrigin(label: "Codex", kind: "codex_unknown", source: "fallback:provider", confidence: "unknown"))
        // Process rules run before the terminal fallback.
        XCTAssertEqual(detect(.claude, ["TERM_PROGRAM": "Apple_Terminal"], [process("/Applications/Claude.app/Contents/MacOS/Claude")]).label,
                       "Claude App")
    }

    func testAncestryIsOnlyReadWhenNeeded() {
        var walked = 0
        _ = OriginDetector.detect(provider: .claude, environment: ["TERM_PROGRAM": "vscode"], ancestry: { walked += 1; return [] })
        XCTAssertEqual(walked, 0)
        _ = OriginDetector.detect(provider: .claude, environment: ["TERM_PROGRAM": "Apple_Terminal"], ancestry: { walked += 1; return [] })
        XCTAssertEqual(walked, 1)
    }

    func testAllLabels() {
        let expected: [HookProvider: [String]] = [
            .claude: ["Claude App", "Claude Code CLI", "Claude in VS Code", "Claude in Cursor", "Claude in Windsurf"],
            .codex: ["Codex UI", "Codex CLI", "Codex in VS Code", "Codex in Cursor", "Codex in Windsurf"],
        ]
        for (provider, labels) in expected {
            XCTAssertEqual(OriginDetector.Surface.allCases.map { OriginDetector.label(provider: provider, surface: $0) }, labels)
        }
    }

    func testReadsRealProcessTree() throws {
        let me = try XCTUnwrap(ProcessSnapshot.read(pid: getpid()))
        XCTAssertEqual(me.pid, getpid())
        XCTAssertEqual(me.parentPID, getppid())
        XCTAssertFalse(me.comm.isEmpty)
        XCTAssertTrue(me.executablePath.hasPrefix("/"), me.executablePath)
        XCTAssertFalse(me.arguments.isEmpty)
        XCTAssertEqual(me.arguments.first.map { ($0 as NSString).lastPathComponent }, CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent })

        let chain = ProcessSnapshot.ancestry(from: getpid())
        XCTAssertGreaterThanOrEqual(chain.count, 2)
        XCTAssertLessThanOrEqual(chain.count, OriginDetector.maxAncestors)
        XCTAssertEqual(chain.first?.pid, getpid())
        for (child, parent) in zip(chain, chain.dropFirst()) { XCTAssertEqual(child.parentPID, parent.pid) }
        XCTAssertNil(ProcessSnapshot.read(pid: 999_999))
        XCTAssertEqual(ProcessSnapshot.ancestry(from: 1), [])
        XCTAssertEqual(ProcessSnapshot.ancestry(from: getpid(), limit: 1).count, 1)

        let started = DispatchTime.now().uptimeNanoseconds
        let origin = OriginDetector.detect(provider: .claude, environment: [:])
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        print(String(format: "HookRuntime origin walk: %@ via %@ in %.3f ms (%d ancestors)", origin.label, origin.source, elapsedMs, chain.count))
        XCTAssertLessThan(elapsedMs, 20)
    }
}
