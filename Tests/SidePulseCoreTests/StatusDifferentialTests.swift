import XCTest
@testable import SidePulseCore

/// Differential check against the Python collector, run by hand.
///
/// Set `SIDEPULSE_STATUS_DIFF_DIR` to a scratch directory holding COPIES of
/// provider logs in `logs/{codex,claude}.jsonl` (and optionally
/// `home/.codex/session_index.jsonl`). The test writes `swift.json` there with one
/// entry per status key, in the same shape as the Python harness output, so the
/// two can be compared. Skipped when the variable is unset.
final class StatusDifferentialTests: XCTestCase {
    func testDumpScanForPythonComparison() throws {
        guard let dir = ProcessInfo.processInfo.environment["SIDEPULSE_STATUS_DIFF_DIR"], !dir.isEmpty else {
            throw XCTSkip("SIDEPULSE_STATUS_DIFF_DIR not set")
        }
        let root = URL(fileURLWithPath: dir)
        let maxLines = Int(ProcessInfo.processInfo.environment["SIDEPULSE_STATUS_DIFF_MAX_LINES"] ?? "") ?? 5000
        let sources = ["codex", "claude"].map {
            SourceInfo(provider: $0, path: root.appendingPathComponent("logs/\($0).jsonl").path)
        }
        let index = CodexSessionIndex(url: root.appendingPathComponent("home/.codex/session_index.jsonl"))

        let start = Date()
        let rows = LogScanner.scan(sources: sources, maxLines: maxLines, codexTitle: index.title(forSession:))
        let elapsed = Date().timeIntervalSince(start)

        var out = JSONObject()
        for row in rows.sorted(by: { $0.agentID < $1.agentID }) {
            out[row.agentID] = .object([
                "mode": .string(row.mode.rawValue), "event_name": .string(row.eventName),
                "display_name": .string(row.displayName), "updated_at": .string(TimeFormat.pythonISO(row.updatedAt)),
                "origin": JSONValue(row.origin), "cwd": JSONValue(row.cwd), "tool_name": JSONValue(row.toolName),
                "message": JSONValue(row.message), "session_id": JSONValue(row.sessionID),
            ])
        }
        try FileUtil.atomicWrite(JSONValue.object(out).serialized(pretty: true), to: root.appendingPathComponent("swift.json"))
        print("swift: \(rows.count) rows in \(String(format: "%.3f", elapsed))s")
    }
}
