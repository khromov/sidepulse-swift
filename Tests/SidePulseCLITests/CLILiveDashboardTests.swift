import XCTest
@testable import SidePulseCLI
import SidePulseCore

final class CLILiveDashboardTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    /// Python rendered a 154-column table whatever the width (the goldens ran at
    /// COLUMNS=120); this port draws the same frame from 154 columns up.
    private func options(interval: Double = 1, recent: Double = 3600, all: Bool = false, color: Bool = false,
                         width: Int = 154) -> LiveDashboardOptions {
        var options = LiveDashboardOptions()
        options.interval = interval
        options.recentSeconds = recent
        options.includeStale = all
        options.color = color
        options.width = width
        options.timeZone = utc
        options.origin = .logsAppNotRunning
        return options
    }

    /// The Python frame with this port's documented deviations applied: the title
    /// is "SidePulse", line 2 names the snapshot source, the OK/MISS marker is
    /// padded before it is colored (Python padded the escape sequence, which broke
    /// the column when colors were on), and the reason is cut to the frame width.
    private func adapted(_ python: String, source: String = "logs", width: Int = 154) -> String {
        python
            .replacingOccurrences(of: "Agent Monitor", with: "SidePulse")
            .replacingOccurrences(of: "  quit=Ctrl-C", with: "  source=\(source)  quit=Ctrl-C")
            .replacingOccurrences(of: "\u{1B}[32mOK\u{1B}[0m", with: "\u{1B}[32mOK  \u{1B}[0m")
            .split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                guard line.hasPrefix("reason: ") else { return String(line) }
                var text = String(line.dropFirst(8))
                var (open, close) = ("", "")
                if text.hasPrefix("\u{1B}["), let m = text.firstIndex(of: "m"), text.hasSuffix("\u{1B}[0m") {
                    open = String(text[...m])
                    close = "\u{1B}[0m"
                    text = String(text[text.index(after: m)...].dropLast(close.count))
                }
                return "reason: " + open + LiveDashboard.truncate(text, width - 8) + close
            }
            .joined(separator: "\n")
    }

    private func render(_ snapshot: MonitorSnapshot, _ options: LiveDashboardOptions) -> String {
        LiveDashboard.render(snapshot, options: options, fileExists: CLIFixtures.fileExists)
    }

    // MARK: Differential against Python render_watch_dashboard

    func testDashboardMatchesPython() {
        XCTAssertEqual(render(CLIFixtures.snapshot, options()), adapted(CLIPythonGolden.dashboard))
    }

    func testDashboardAllWithColorMatchesPython() {
        XCTAssertEqual(render(CLIFixtures.snapshot, options(interval: 0.5, all: true, color: true)),
                       adapted(CLIPythonGolden.dashboardAllColor))
    }

    func testDashboardRecentFilterMatchesPython() {
        XCTAssertEqual(render(CLIFixtures.snapshot, options(interval: 2, recent: 60)),
                       adapted(CLIPythonGolden.dashboardRecent))
    }

    func testEmptyDashboardMatchesPython() {
        XCTAssertEqual(render(CLIFixtures.empty, options(recent: 0)), adapted(CLIPythonGolden.dashboardEmpty))
    }

    func testSourceLabelForAppSnapshots() {
        var appOptions = options()
        appOptions.origin = .app
        XCTAssertEqual(render(CLIFixtures.snapshot, appOptions), adapted(CLIPythonGolden.dashboard, source: "app"))
    }

    // MARK: Table geometry

    func testTableIsPythonsFrom154Columns() {
        XCTAssertEqual(LiveDashboard.visibleColumns(width: 154), Array(0..<8))
        XCTAssertEqual(LiveDashboard.columnWidths(width: 154), [9, 22, 18, 20, 8, 18, 16, 18])
    }

    /// Regression: the table was at least 154 columns wide, so on an 80-column
    /// terminal every row wrapped and the redrawn frame was unreadable.
    func testTableFitsNarrowerTerminals() {
        for width in [62, 70, 80, 100, 120, 133, 140, 153] {
            XCTAssertEqual(LiveDashboard.separator(LiveDashboard.columnWidths(width: width)).count, width, "\(width)")
        }
        // Origin, Event, then Tool are dropped; Mode keeps its longest label.
        XCTAssertEqual(LiveDashboard.visibleColumns(width: 140), [0, 1, 3, 4, 5, 6, 7])
        XCTAssertEqual(LiveDashboard.visibleColumns(width: 120), [0, 1, 3, 4, 6, 7])
        XCTAssertEqual(LiveDashboard.visibleColumns(width: 80), [0, 1, 3, 4, 7])
        XCTAssertEqual(LiveDashboard.columnWidths(width: 80), [9, 14, 18, 8, 15])

        var narrow = options(all: true, width: 80)
        narrow.color = false
        let frame = render(CLIFixtures.snapshot, narrow)
        for line in frame.split(separator: "\n") { XCTAssertLessThanOrEqual(line.count, 80, String(line)) }
        XCTAssertTrue(frame.contains("| Provider  | Agent          | Mode               | Age      | Cwd             |"), frame)
        XCTAssertTrue(frame.contains("| codex     | A very long d. | Waiting for Input  |"), frame)
    }

    func testCwdColumnGrowsOnWideTerminals() {
        let widths = LiveDashboard.columnWidths(width: 220)
        XCTAssertEqual(widths.last, 84)
        XCTAssertEqual(LiveDashboard.separator(widths).count, 220)
        let frame = render(CLIFixtures.snapshot, options(width: 220))
        XCTAssertTrue(frame.contains("| /Users/someone/Documents/GitHub/some-really-long-project" + String(repeating: " ", count: 29) + "|"))
        // The "=" rule is still capped at 120.
        XCTAssertTrue(frame.contains("\n" + String(repeating: "=", count: 120) + "\n"))
    }

    func testTinyTerminalUsesTheSmallestTable() {
        let frame = render(CLIFixtures.snapshot, options(width: 20))
        XCTAssertTrue(frame.contains("\n" + String(repeating: "=", count: LiveDashboard.minimumWidth) + "\n"))
        XCTAssertTrue(frame.contains("\n" + LiveDashboard.separator([6, 8, 18, 6, 8]) + "\n"))
    }

    /// Regression: below 80 columns the two header lines still wrapped (the
    /// `updated=` timestamp and a long `showing=` / `source=` line).
    func testHeaderLinesFitTheSmallestFrame() {
        let frame = render(CLIFixtures.snapshot, options(all: true, width: LiveDashboard.minimumWidth))
        for line in frame.split(separator: "\n") {
            XCTAssertLessThanOrEqual(line.count, LiveDashboard.minimumWidth, String(line))
        }
        XCTAssertFalse(frame.contains("updated="), frame)
        XCTAssertTrue(render(CLIFixtures.snapshot, options(all: true, width: 80)).contains("  updated="))
    }

    func testRowAndSeparator() {
        XCTAssertEqual(LiveDashboard.separator([1, 3]), "+---+-----+")
        XCTAssertEqual(LiveDashboard.row(["a", "abcdef"], widths: [2, 4]), "| a  | abc. |")
        XCTAssertEqual(LiveDashboard.row(["x\ny", "Working"], widths: [3, 7], modeColumn: 1, mode: .working, color: true),
                       "| x y | \u{1B}[34;1mWorking\u{1B}[0m |")
    }

    func testSingleLineKeepsEmojiJoinersButNotLineBreaks() {
        let coder = "\u{1F469}\u{200D}\u{1F4BB}" // woman technologist: a ZWJ sequence
        XCTAssertEqual(LiveDashboard.singleLine("a \(coder) b"), "a \(coder) b")
        XCTAssertEqual(LiveDashboard.singleLine("a\u{2028}b\tc\u{1B}d\r\ne\u{85}f"), "a b c d  e f")
        XCTAssertEqual(LiveDashboard.row(["\(coder)x"], widths: [3]), "| \(coder)x  |")
    }

    func testTerminalColumnsPreferCOLUMNSLikePython() {
        // shutil.get_terminal_size: $COLUMNS first, then the terminal, then the fallback.
        XCTAssertEqual(Terminal.columns(environment: ["COLUMNS": "200"], ttyColumns: { 90 }), 200)
        XCTAssertEqual(Terminal.columns(environment: ["COLUMNS": "0"], ttyColumns: { 90 }), 90)
        XCTAssertEqual(Terminal.columns(environment: ["COLUMNS": "wide"], ttyColumns: { 90 }), 90)
        XCTAssertEqual(Terminal.columns(environment: [:], ttyColumns: { 90 }), 90)
        XCTAssertNil(Terminal.columns(environment: [:], ttyColumns: { nil }))
    }

    // MARK: Helpers (Python vectors)

    func testFormatDuration() {
        let vectors: [(Double, String)] = [
            (0, "0s"), (0.9, "0s"), (59, "59s"), (60, "1m00s"), (61, "1m01s"), (3599, "59m59s"), (3600, "1h00m"),
            (3661, "1h01m"), (86461, "24h01m"), (-5, "0s"), (7200.7, "2h00m"), (.nan, "0s"),
        ]
        for (seconds, expected) in vectors {
            XCTAssertEqual(LiveDashboard.formatDuration(seconds), expected, "\(seconds)")
        }
    }

    func testFormatG() {
        let vectors: [(Double, String)] = [
            (1, "1"), (0.5, "0.5"), (2.25, "2.25"), (0.1, "0.1"), (10, "10"), (1e-05, "1e-05"),
            (123_456_789, "1.23457e+08"), (15, "15"),
        ]
        for (value, expected) in vectors {
            XCTAssertEqual(LiveDashboard.formatG(value), expected)
        }
    }

    func testTruncate() {
        XCTAssertEqual(LiveDashboard.truncate("abcdef", 3), "ab.")
        XCTAssertEqual(LiveDashboard.truncate("abc", 3), "abc")
        XCTAssertEqual(LiveDashboard.truncate("abcd", 1), "a")
        XCTAssertEqual(LiveDashboard.truncate("abcd", 0), "")
    }

    func testModeColors() {
        XCTAssertEqual(LiveDashboard.modeColor(.blockedError), "31;1")
        XCTAssertEqual(LiveDashboard.modeColor(.waitingForInput), "33;1")
        XCTAssertEqual(LiveDashboard.modeColor(.toolRunning), "36;1")
        XCTAssertEqual(LiveDashboard.modeColor(.longTaskProgress), "35;1")
        XCTAssertEqual(LiveDashboard.modeColor(.working), "34;1")
        XCTAssertEqual(LiveDashboard.modeColor(.completed), "32;1")
        XCTAssertEqual(LiveDashboard.modeColor(.idleReady), "37")
        XCTAssertEqual(LiveDashboard.modeColor(.unknown), "37")
        XCTAssertEqual(LiveDashboard.colorize("x", "1", false), "x")
        XCTAssertEqual(LiveDashboard.colorize("x", "1", true), "\u{1B}[1mx\u{1B}[0m")
    }

    func testShouldUseColor() {
        XCTAssertTrue(LiveDashboard.shouldUseColor(noColorFlag: false, environment: [:], stdoutIsTTY: true))
        XCTAssertFalse(LiveDashboard.shouldUseColor(noColorFlag: true, environment: [:], stdoutIsTTY: true))
        XCTAssertFalse(LiveDashboard.shouldUseColor(noColorFlag: false, environment: ["NO_COLOR": ""], stdoutIsTTY: true))
        XCTAssertFalse(LiveDashboard.shouldUseColor(noColorFlag: false, environment: [:], stdoutIsTTY: false))
    }

    // MARK: Visible rows

    func testWatchFiltersToRecentStatuses() {
        // Python test_watch_filters_to_recent_statuses.
        let recent = CLIFixtures.status("codex", "recent", "Recent", .working, age: 20, event: "PostToolUse")
        let older = CLIFixtures.status("claude", "older", "Older", .completed, age: 600, event: "Stop")
        let snapshot = MonitorSnapshot(collectedAt: CLIFixtures.now, sources: [],
                                       aggregate: AggregateStatus(mode: .working, activeCount: 2, staleCount: 0,
                                                                  representative: recent),
                                       statuses: [recent, older], staleStatuses: [])
        let visible = LiveDashboard.visibleStatuses(snapshot, recentSeconds: 120, includeStale: false)
        XCTAssertEqual(visible.map(\.agentID), ["recent"])
        XCTAssertEqual(LiveDashboard.visibleStatuses(snapshot, recentSeconds: 0, includeStale: false).map(\.agentID),
                       ["recent", "older"])
    }

    func testVisibleStatusesSortByPriorityThenNewestAndIncludeStaleWithAll() {
        let olderWorking = CLIFixtures.status("claude", "w1", "w1", .working, age: 100, event: "UserPromptSubmit")
        let newerWorking = CLIFixtures.status("claude", "w2", "w2", .working, age: 10, event: "UserPromptSubmit")
        let blocked = CLIFixtures.status("codex", "b", "b", .blockedError, age: 50, event: "PostToolUseFailure")
        let stale = CLIFixtures.status("codex", "s", "s", .waitingForInput, age: 99_999, event: "Notification", stale: true)
        let snapshot = MonitorSnapshot(collectedAt: CLIFixtures.now, sources: [],
                                       aggregate: AggregateStatus(mode: .blockedError, activeCount: 3, staleCount: 1,
                                                                  representative: blocked),
                                       statuses: [olderWorking, newerWorking, blocked], staleStatuses: [stale])
        XCTAssertEqual(LiveDashboard.visibleStatuses(snapshot, recentSeconds: 3600, includeStale: false).map(\.agentID),
                       ["b", "w2", "w1"])
        XCTAssertEqual(LiveDashboard.visibleStatuses(snapshot, recentSeconds: 60, includeStale: true).map(\.agentID),
                       ["b", "s", "w2", "w1"])
    }

    // MARK: Redraw loop

    func testLoopClearsScreenEachFrameAndRestoresCursorOnTTY() {
        let harness = CLIHarness()
        harness.env.stdoutIsTTY = true
        harness.env.terminalColumns = { 100 }
        var fetches = 0
        harness.env.snapshots = SnapshotLoader(fromApp: { _ in fetches += 1; return nil },
                                               fromLogs: { _ in CLIFixtures.empty })
        var waits: [TimeInterval] = []
        LiveCommand.loop(harness.env, options: options(interval: 0.25), offline: false, wait: { interval in
            waits.append(interval)
            return waits.count >= 2 // "Ctrl-C" during the second wait
        })
        let out = harness.stdout.text
        XCTAssertTrue(out.hasPrefix(LiveDashboard.hideCursor + LiveDashboard.clearScreen + "SidePulse  aggregate=Idle / Ready"))
        XCTAssertTrue(out.hasSuffix("  none\n" + LiveDashboard.showCursor))
        XCTAssertEqual(out.components(separatedBy: LiveDashboard.clearScreen).count - 1, 2)
        XCTAssertEqual(waits, [0.25, 0.25])
        XCTAssertEqual(fetches, 2)
        XCTAssertTrue(out.contains("source=logs"))
    }

    func testLoopWithoutTTYDoesNotTouchTheCursor() {
        let harness = CLIHarness()
        harness.env.snapshots = SnapshotLoader(fromApp: { _ in CLIFixtures.snapshot }, fromLogs: { _ in CLIFixtures.empty })
        LiveCommand.loop(harness.env, options: options(), offline: false, frames: 1, wait: { _ in false })
        let out = harness.stdout.text
        XCTAssertFalse(out.contains(LiveDashboard.hideCursor))
        XCTAssertFalse(out.contains(LiveDashboard.showCursor))
        XCTAssertTrue(out.hasPrefix(LiveDashboard.clearScreen))
        XCTAssertTrue(out.contains("source=app"))
    }
}
