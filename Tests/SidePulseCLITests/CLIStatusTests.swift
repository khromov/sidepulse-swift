import XCTest
@testable import SidePulseCLI
import SidePulseCore

final class CLIStatusTests: XCTestCase {
    // MARK: describe / render (differential against the Python output)

    func testDescribeMatchesPython() {
        let now = CLIFixtures.now
        XCTAssertEqual(StatusText.describe(CLIFixtures.a, now: now), CLIPythonGolden.describeA)
        XCTAssertEqual(StatusText.describe(CLIFixtures.b, now: now), CLIPythonGolden.describeB)
        XCTAssertEqual(StatusText.describe(CLIFixtures.c, now: now), CLIPythonGolden.describeC)
        // Empty origin/tool strings are omitted like Python's truthiness checks.
        XCTAssertEqual(StatusText.describe(CLIFixtures.d, now: now), CLIPythonGolden.describeD)
    }

    func testDescribeReferenceExample() {
        let status = CLIFixtures.status("claude", "claude:session:1", "proj: task", .toolRunning, age: 5,
                                        event: "PreToolUse", tool: "Bash", cwd: "/tmp/proj")
        XCTAssertEqual(StatusText.describe(status, now: CLIFixtures.now),
                       "proj: task: Tool Running event=PreToolUse tool=Bash age=5s cwd=/tmp/proj")
    }

    func testDescribeClampsFutureTimestampsToZero() {
        let future = CLIFixtures.status("codex", "codex:session:1", "x", .working, age: -30, event: "UserPromptSubmit")
        XCTAssertEqual(StatusText.describe(future, now: CLIFixtures.now), "x: Working event=UserPromptSubmit age=0s")
    }

    func testRenderMatchesPython() {
        XCTAssertEqual(StatusText.render(CLIFixtures.snapshot, includeStale: false, fileExists: CLIFixtures.fileExists),
                       CLIPythonGolden.render)
        XCTAssertEqual(StatusText.render(CLIFixtures.snapshot, includeStale: true, fileExists: CLIFixtures.fileExists),
                       CLIPythonGolden.renderAll)
        XCTAssertEqual(StatusText.render(CLIFixtures.empty, includeStale: false, fileExists: CLIFixtures.fileExists),
                       CLIPythonGolden.renderEmpty)
    }

    func testRenderWithoutSources() {
        let text = StatusText.render(MonitorSnapshot.empty(now: CLIFixtures.now), includeStale: true)
        XCTAssertEqual(text, "Aggregate: Idle / Ready (0 active, 0 stale)\n\nSources:\n  none\n\nAgents:\n  none")
    }

    func testOriginHeaders() {
        XCTAssertEqual(SnapshotOrigin.app.headerLine, "Source: SidePulse app (live)")
        XCTAssertEqual(SnapshotOrigin.logsAppNotRunning.headerLine, "Source: hook logs (app not running)")
        XCTAssertEqual(SnapshotOrigin.logsOffline.headerLine, "Source: hook logs (offline)")
    }

    // MARK: status command

    private func harness(app: MonitorSnapshot?, logs: MonitorSnapshot, calls: CallLog) -> CLIHarness {
        let harness = CLIHarness()
        harness.env.snapshots = SnapshotLoader(
            fromApp: { _ in calls.app += 1; return app },
            fromLogs: { _ in calls.logs += 1; return logs }
        )
        return harness
    }

    final class CallLog { var app = 0; var logs = 0 }

    func testStatusPrefersTheApp() {
        let calls = CallLog()
        let h = harness(app: CLIFixtures.snapshot, logs: CLIFixtures.empty, calls: calls)
        XCTAssertEqual(h.run(["status"]), 0)
        XCTAssertEqual(calls.app, 1)
        XCTAssertEqual(calls.logs, 0)
        let expectedBody = StatusText.render(CLIFixtures.snapshot, includeStale: false)
        XCTAssertEqual(h.stdout.text, "Source: SidePulse app (live)\n" + expectedBody + "\n")
    }

    func testStatusFallsBackToLogs() {
        let calls = CallLog()
        let h = harness(app: nil, logs: CLIFixtures.snapshot, calls: calls)
        XCTAssertEqual(h.run(["status", "--all"]), 0)
        XCTAssertEqual([calls.app, calls.logs], [1, 1])
        XCTAssertTrue(h.stdout.text.hasPrefix("Source: hook logs (app not running)\nAggregate: Waiting for Input"))
        XCTAssertTrue(h.stdout.text.contains("  Done thing: Completed event=Stop age=4000s stale\n"))
    }

    func testStatusOfflineSkipsTheApp() {
        let calls = CallLog()
        let h = harness(app: CLIFixtures.snapshot, logs: CLIFixtures.empty, calls: calls)
        XCTAssertEqual(h.run(["status", "--offline"]), 0)
        XCTAssertEqual([calls.app, calls.logs], [0, 1])
        XCTAssertTrue(h.stdout.text.hasPrefix("Source: hook logs (offline)\nAggregate: Idle / Ready (0 active, 0 stale)"))
    }

    func testWatchClearsTheScreenAndRedrawsEveryTwoSeconds() {
        let calls = CallLog()
        let h = harness(app: CLIFixtures.snapshot, logs: CLIFixtures.empty, calls: calls)
        let started = h.clock
        StatusCommand.watch(ParsedArguments(flags: ["watch"]), h.env, frames: 3)
        XCTAssertEqual(calls.app, 3)
        let frame = "\u{1B}[H\u{1B}[2J" + "Source: SidePulse app (live)\n"
            + StatusText.render(CLIFixtures.snapshot, includeStale: false) + "\n"
        XCTAssertEqual(h.stdout.text, String(repeating: frame, count: 3))
        XCTAssertEqual(h.clock.timeIntervalSince(started), 4, "two waits between three frames")
    }

    // MARK: leds --once text

    func testLedsResultLines() {
        let snapshot = CLIFixtures.snapshot
        let target = URL(fileURLWithPath: "/Volumes/PulseDot/LEDS.LED")
        let wrote = LedSyncResult(changed: true, program: "#FFB000 pulse\nrepeat", target: target)
        XCTAssertEqual(LedsText.render(wrote, snapshot: snapshot, dryRun: false),
                       "LEDs: wrote Ask to /Volumes/PulseDot/LEDS.LED (aggregate=Waiting for Input, active=3)")
        XCTAssertEqual(LedsText.render(wrote, snapshot: snapshot, dryRun: true),
                       "LEDs: would write Ask to /Volumes/PulseDot/LEDS.LED (aggregate=Waiting for Input, active=3)\n"
                           + "#FFB000 pulse\nrepeat")
        let noTarget = LedSyncResult(changed: false)
        XCTAssertEqual(LedsText.render(noTarget, snapshot: CLIFixtures.empty, dryRun: true),
                       "LEDs: would write Idle to - (aggregate=Idle / Ready, active=0)")
        let failed = LedSyncResult(changed: false, target: target, error: "Permission denied")
        XCTAssertEqual(LedsText.render(failed, snapshot: snapshot, dryRun: false), "LEDs: Ask error=Permission denied")
    }

    func testLedsStateLabelsFollowDisplayState() {
        func label(_ mode: AgentMode) -> String {
            let snapshot = MonitorSnapshot(collectedAt: CLIFixtures.now, sources: [],
                                           aggregate: AggregateStatus(mode: mode, activeCount: 0, staleCount: 0,
                                                                      representative: nil),
                                           statuses: [], staleStatuses: [])
            return LedsText.render(LedSyncResult(changed: true), snapshot: snapshot, dryRun: false)
        }
        XCTAssertTrue(label(.blockedError).hasPrefix("LEDs: wrote Ask "))
        XCTAssertTrue(label(.waitingForInput).hasPrefix("LEDs: wrote Ask "))
        XCTAssertTrue(label(.toolRunning).hasPrefix("LEDs: wrote Working "))
        XCTAssertTrue(label(.longTaskProgress).hasPrefix("LEDs: wrote Working "))
        XCTAssertTrue(label(.working).hasPrefix("LEDs: wrote Working "))
        XCTAssertTrue(label(.completed).hasPrefix("LEDs: wrote Done "))
        XCTAssertTrue(label(.idleReady).hasPrefix("LEDs: wrote Idle "))
        XCTAssertTrue(label(.unknown).hasPrefix("LEDs: wrote Idle "))
    }
}
