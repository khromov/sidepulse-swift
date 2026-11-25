import XCTest
@testable import SidePulseCore

final class StatusAntigravityTests: XCTestCase {
    private let t0 = TimeFormat.parse("2026-11-24T12:00:00Z")!

    private func record(_ payload: String, offset: TimeInterval = 0, origin: String? = nil) -> JSONObject {
        HookRuntime.makeRecord(provider: .antigravity, payload: Data(payload.utf8),
                               now: t0.addingTimeInterval(offset), origin: origin)
    }

    func testLifecycleReachesEveryModeAndExtractsTitleAndOrigin() throws {
        let engine = StatusEngine()
        let cid = "ec33ebf9-0cba-4100-8142-c61503f6c587"
        let key = "antigravity:session:\(cid)"
        let common = #""conversationId":"\#(cid)","cwd":"/work/proj","workspacePaths":["/work/proj"],"#
            + #""transcriptPath":"/Users/k/.gemini/antigravity-cli/brain/\#(cid)/transcript.jsonl""#

        let steps: [(String, AgentMode, String)] = [
            (#"{"hookEventName":"SessionStart",\#(common)}"#, .idleReady, "SessionStart"),
            (#"{"hookEventName":"PreInvocation","invocationNum":1,"lastUserInput":"Fix the failing unit test",\#(common)}"#,
             .working, "PreInvocation"),
            (#"{"hookEventName":"PreToolUse","toolCall":{"id":"t1","name":"run_command","args":{"CommandLine":"swift test"}},"lastUserInput":"Fix the failing unit test",\#(common)}"#,
             .toolRunning, "PreToolUse"),
            (#"{"hookEventName":"PostToolUse","toolCall":{"id":"t1","name":"run_command","args":{"CommandLine":"swift test"}},"error":"exit status 1",\#(common)}"#,
             .blockedError, "PostToolUseFailure"),
            (#"{"hookEventName":"PostInvocation","invocationNum":1,\#(common)}"#, .working, "PostInvocation"),
            (#"{"hookEventName":"PreInvocation","invocationNum":2,"lastUserInput":"Second prompt should not replace title",\#(common)}"#,
             .working, "PreInvocation"),
            (#"{"hookEventName":"PreToolUse","toolCall":{"id":"t2","name":"ask_question","args":{"questions":[{"question":"Which target should I update?"}]}},\#(common)}"#,
             .waitingForInput, "PermissionRequest"),
            (#"{"hookEventName":"PostToolUse","toolCall":{"id":"t2","name":"ask_question"},"error":"",\#(common)}"#,
             .working, "PostToolUse"),
            (#"{"hookEventName":"PreToolUse","toolCall":{"id":"t3","name":"notify_user","args":{"BlockedOnUser":true,"Message":"Please review the plan."}},\#(common)}"#,
             .waitingForInput, "PermissionRequest"),
            (#"{"hookEventName":"PostToolUse","toolCall":{"id":"t3","name":"notify_user"},\#(common)}"#,
             .working, "PostToolUse"),
            (#"{"hookEventName":"PreToolUse","toolCall":{"id":"t4","name":"notify_user","args":{"BlockedOnUser":false,"Message":"Heads up"}},\#(common)}"#,
             .toolRunning, "PreToolUse"),
            (#"{"hookEventName":"Stop","terminationReason":"NO_TOOL_CALL","error":"","fullyIdle":true,\#(common)}"#,
             .completed, "Stop"),
        ]

        for (index, step) in steps.enumerated() {
            let rec = record(step.0, offset: Double(index))
            if step.2 == "PreToolUse" && index == 2 {
                XCTAssertEqual(rec["tool_input"]?["command"], .string("swift test"))
                XCTAssertNil(rec["prompt"], "lastUserInput is only copied onto PreInvocation records")
            }
            if step.2 == "PostToolUseFailure" {
                XCTAssertEqual(rec["error_details"], .string("exit status 1"))
            }
            if step.2 == "PermissionRequest" && index == 6 {
                XCTAssertEqual(rec["message"], .string("Which target should I update?"))
                XCTAssertEqual(rec["tool_name"], .string("ask_question"))
            }
            engine.ingest(provider: "antigravity", line: rec)
            XCTAssertEqual(engine.statuses[key]?.mode, step.1, "step \(index)")
            XCTAssertEqual(engine.statuses[key]?.eventName, step.2, "step \(index)")
        }

        let status = try XCTUnwrap(engine.statuses[key])
        XCTAssertEqual(status.provider, "antigravity")
        XCTAssertEqual(status.origin, "Antigravity CLI")
        XCTAssertEqual(status.displayName, "proj: Fix the failing unit test (ec33ebf9)")
        XCTAssertEqual(SessionRows.detail(for: status, now: t0.addingTimeInterval(30)),
                       "Done \u{b7} Stop \u{b7} 19s ago \u{b7} Antigravity CLI")
    }

    func testStopTerminationReasonsMapToIdleOrBlocked() throws {
        let canceled = record(#"{"hookEventName":"Stop","conversationId":"c1","terminationReason":"USER_CANCELED","error":"canceled"}"#)
        XCTAssertEqual(canceled["hook_event_name"], .string("Interrupt"))
        let engine = StatusEngine()
        engine.ingest(provider: "antigravity", line: canceled)
        XCTAssertEqual(engine.statuses["antigravity:session:c1"]?.mode, .idleReady)

        let prefixedCancel = record(#"{"hookEventName":"Stop","conversationId":"c2","terminationReason":"EXECUTOR_TERMINATION_REASON_USER_CANCELED"}"#)
        XCTAssertEqual(prefixedCancel["hook_event_name"], .string("Interrupt"))

        let errored = record(#"{"hookEventName":"Stop","conversationId":"c3","terminationReason":"ERROR","error":"quota exceeded"}"#)
        XCTAssertEqual(errored["hook_event_name"], .string("StopFailure"))
        XCTAssertEqual(errored["error_details"], .string("quota exceeded"))
        engine.ingest(provider: "antigravity", line: errored)
        XCTAssertEqual(engine.statuses["antigravity:session:c3"]?.mode, .blockedError)
        XCTAssertEqual(engine.statuses["antigravity:session:c3"]?.message, "quota exceeded")

        for reason in ["MAX_INVOCATIONS", "MAX_FORCED_INVOCATIONS", "MAX_TOKEN_BUDGET_EXCEEDED",
                       "EXECUTOR_TERMINATION_REASON_ERROR"] {
            let rec = record(#"{"hookEventName":"Stop","conversationId":"s-\#(reason)","terminationReason":"\#(reason)","error":""}"#)
            XCTAssertEqual(rec["hook_event_name"], .string("StopFailure"), reason)
            XCTAssertNotNil(rec["error_details"], reason)
        }

        let normal = record(#"{"hookEventName":"Stop","conversationId":"c4","terminationReason":"TERMINAL_STEP_TYPE","error":""}"#)
        XCTAssertEqual(normal["hook_event_name"], .string("Stop"))
        engine.ingest(provider: "antigravity", line: normal)
        XCTAssertEqual(engine.statuses["antigravity:session:c4"]?.mode, .completed)
    }

    func testChildConversationReportsUnderItsRootAndClosesWithACancelledParent() throws {
        let top = record(#"{"hookEventName":"PreInvocation","conversationId":"root-1","rootConversationId":"root-1","lastUserInput":"Main task"}"#)
        XCTAssertEqual(top["session_id"], .string("root-1"))
        XCTAssertNil(top["agent_id"])
        let child = record(#"{"hookEventName":"PreInvocation","conversationId":"child-1","parentConversationId":"mid-1","rootConversationId":"root-1","lastUserInput":"Sub task"}"#,
                           offset: 1)
        XCTAssertEqual(child["session_id"], .string("root-1"))
        XCTAssertEqual(child["agent_id"], .string("child-1"))
        let parentOnly = record(#"{"hookEventName":"PreInvocation","conversationId":"child-2","parentConversationId":"root-1"}"#)
        XCTAssertEqual(parentOnly["session_id"], .string("root-1"))
        XCTAssertEqual(parentOnly["agent_id"], .string("child-2"))

        let engine = StatusEngine()
        engine.ingest(provider: "antigravity", line: top)
        engine.ingest(provider: "antigravity", line: child)
        let childRow = try XCTUnwrap(engine.statuses["antigravity:agent:child-1"])
        XCTAssertEqual(childRow.sessionID, "root-1")
        XCTAssertEqual(childRow.mode, .working)
        XCTAssertNil(engine.statuses["antigravity:session:child-1"])
        XCTAssertEqual(SessionRows.coalesce(engine.snapshot(now: t0.addingTimeInterval(2)).statuses).count, 1)

        engine.ingest(provider: "antigravity",
                      line: record(#"{"hookEventName":"Stop","conversationId":"root-1","terminationReason":"USER_CANCELED"}"#, offset: 3))
        XCTAssertEqual(engine.statuses["antigravity:session:root-1"]?.mode, .idleReady)
        XCTAssertEqual(engine.statuses["antigravity:agent:child-1"]?.mode, .completed)
    }

    func testPostInvocationSettlesToCompletedAfterTwoMinutes() {
        let engine = StatusEngine()
        engine.ingest(provider: "antigravity", line: record(#"{"hookEventName":"PostInvocation","conversationId":"p1"}"#))
        XCTAssertEqual(engine.snapshot(now: t0.addingTimeInterval(60)).aggregate.mode, .working)
        XCTAssertEqual(engine.snapshot(now: t0.addingTimeInterval(121)).aggregate.mode, .completed)
    }

    func testCwdFallsBackToFirstWorkspacePath() {
        let rec = record(#"{"hookEventName":"SessionStart","conversationId":"w1","workspacePaths":["/work/alpha","/work/beta"]}"#)
        XCTAssertEqual(rec["cwd"], .string("/work/alpha"))
        let explicit = record(#"{"hookEventName":"SessionStart","conversationId":"w2","cwd":"/work/explicit","workspacePaths":["/work/alpha"]}"#)
        XCTAssertEqual(explicit["cwd"], .string("/work/explicit"))
    }

    func testOriginDetectionFromTranscriptAndEnvironment() throws {
        let cases: [(String, String?)] = [
            ("/Users/k/.gemini/antigravity-cli/brain/1/transcript.jsonl", "Antigravity CLI"),
            ("/Users/k/.gemini/antigravity-ide/brain/1/transcript.jsonl", "Antigravity IDE"),
            ("/path/to/workspace/.gemini/antigravity/transcript.jsonl", "Antigravity App"),
            ("/Users/k/src/antigravity/transcript.jsonl", nil),
        ]
        for (path, expected) in cases {
            let rec = record(#"{"hookEventName":"Stop","conversationId":"o1","transcriptPath":"\#(path)"}"#)
            XCTAssertEqual(rec["agent_origin"], expected.map(JSONValue.string), path)
        }

        // artifactDirectoryPath is checked when transcriptPath is absent.
        let artifact = record(#"{"hookEventName":"Stop","conversationId":"o2","artifactDirectoryPath":"/Users/k/.gemini/antigravity-ide/artifacts"}"#)
        XCTAssertEqual(artifact["agent_origin"], .string("Antigravity IDE"))

        // SIDEPULSE_AGENT_ORIGIN overrides transcriptPath in HookRuntime.run.
        let root = IPCTestSupport.makeShortTempDir("spag")
        defer { IPCTestSupport.remove(root) }
        let paths = SidePulsePaths(environment: ["SIDEPULSE_HOME": root.path, "HOME": root.path], home: root)
        let payload = #"{"hookEventName":"Stop","conversationId":"o3","transcriptPath":"/Users/k/.gemini/antigravity-cli/transcript.jsonl"}"#
        XCTAssertEqual(HookRuntime.run(arguments: ["--provider", "antigravity"], stdin: Data(payload.utf8),
                                       environment: ["SIDEPULSE_DISABLE_EVENT_SOCKET": "1",
                                                     "SIDEPULSE_AGENT_ORIGIN": "Custom AGY"],
                                       paths: paths, now: t0), 0)
        let log = try XCTUnwrap(FileUtil.readText(paths.logFile(for: "antigravity")))
        XCTAssertEqual(try JSONValue.parse(log.trimmingCharacters(in: .whitespacesAndNewlines))["agent_origin"],
                       .string("Custom AGY"))

        // Without SIDEPULSE_AGENT_ORIGIN, transcriptPath beats generic terminal detection.
        let paths2 = SidePulsePaths(environment: ["SIDEPULSE_HOME": root.appendingPathComponent("s2").path, "HOME": root.path], home: root)
        XCTAssertEqual(HookRuntime.run(arguments: ["--provider", "antigravity"], stdin: Data(payload.utf8),
                                       environment: ["SIDEPULSE_DISABLE_EVENT_SOCKET": "1", "TERM_PROGRAM": "vscode"],
                                       paths: paths2, now: t0), 0)
        let log2 = try XCTUnwrap(FileUtil.readText(paths2.logFile(for: "antigravity")))
        XCTAssertEqual(try JSONValue.parse(log2.trimmingCharacters(in: .whitespacesAndNewlines))["agent_origin"],
                       .string("Antigravity CLI"))
    }
}
