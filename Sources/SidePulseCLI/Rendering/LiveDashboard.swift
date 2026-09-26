import Foundation
import SidePulseCore

/// Settings for one dashboard frame.
public struct LiveDashboardOptions: Sendable {
    /// Refresh interval, shown as `refresh=1s`.
    public var interval: Double = 1
    /// Only rows updated within this many seconds are shown (0 = no limit).
    public var recentSeconds: Double = 3600
    /// `--all`: show fresh and stale rows, no age filter.
    public var includeStale = false
    /// ANSI colors.
    public var color = false
    /// Terminal width (the frame uses at least `LiveDashboard.minimumWidth` columns).
    public var width = 120
    public var timeZone: TimeZone = .current
    public var origin: SnapshotOrigin = .logsAppNotRunning

    public init() {}
}

/// The full-screen `sidepulse live` dashboard (Python `render_watch_dashboard`).
///
/// ```
/// SidePulse  aggregate=Working  agents=1  updated=2026-09-26 10:00:00
/// refresh=1s  showing=last 1h00m  active=1  stale=0  source=app  quit=Ctrl-C
/// ========...
/// reason: <describe(representative)>
///
/// Sources
///   OK   claude  /…/logs/claude.jsonl
///
/// Recently Active Agents
/// +-----------+------------------------+-...
/// | Provider  | Agent                  | Origin | Mode | Age | Event | Tool | Cwd |
/// ```
public enum LiveDashboard {
    public static let title = "SidePulse"
    public static let headers = ["Provider", "Agent", "Origin", "Mode", "Age", "Event", "Tool", "Cwd"]
    /// Widths of every column except the last (Cwd), as in Python.
    public static let fixedWidths = [9, 22, 18, 20, 8, 18, 16]
    public static let minimumCwdWidth = 18
    /// Narrower terminals get a narrower table: Origin, Event and Tool go first
    /// (in that order), then columns shrink towards these widths (Mode keeps room
    /// for its longest label).
    static let droppedFirst = [2, 5, 6]
    static let minimumWidths = [6, 8, 0, 18, 6, 0, 0, 8]
    /// The frame is never narrower than the smallest table.
    public static let minimumWidth = 62

    /// ANSI sequences used by the redraw loop.
    public static let clearScreen = "\u{1B}[2J\u{1B}[H"
    public static let hideCursor = "\u{1B}[?25l"
    public static let showCursor = "\u{1B}[?25h"

    public static func render(_ snapshot: MonitorSnapshot, options: LiveDashboardOptions,
                              fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let width = max(minimumWidth, options.width)
        let color = options.color
        let statuses = visibleStatuses(snapshot, recentSeconds: options.recentSeconds, includeStale: options.includeStale)
        let aggregate = snapshot.aggregate
        let showing = options.includeStale ? "all known agents" : "last \(formatDuration(options.recentSeconds))"

        // Narrow terminals drop `updated=` and `quit=Ctrl-C`, and cut the info line.
        let counts = "  agents=\(statuses.count)"
        let updated = "  updated=\(localTimestamp(snapshot.collectedAt, timeZone: options.timeZone))"
        let headerWidth = title.count + "  aggregate=".count + aggregate.mode.label.count + counts.count
        var info = "refresh=\(formatG(options.interval))s  showing=\(showing)  active=\(aggregate.activeCount)"
            + "  stale=\(aggregate.staleCount)  source=\(options.origin.shortLabel)"
        if info.count + 13 <= width { info += "  quit=Ctrl-C" }
        var lines = [
            "\(colorize(title, "1", color))  aggregate=\(colorize(aggregate.mode.label, modeColor(aggregate.mode), color))"
                + counts + (headerWidth + updated.count <= width ? updated : ""),
            truncate(info, width),
            String(repeating: "=", count: min(width, 120)),
        ]
        if let representative = aggregate.representative {
            let reason = truncate(singleLine(StatusText.describe(representative, now: snapshot.collectedAt)), width - 8)
            lines.append("reason: " + colorize(reason, modeColor(representative.mode), color))
        } else {
            lines.append("reason: no recent agent status")
        }

        lines += ["", "Sources"]
        for source in snapshot.sources {
            // Pad before colorizing so the column lines up with colors on.
            let marker = fileExists(source.path)
                ? colorize(pad("OK", 4), "32", color)
                : colorize(pad("MISS", 4), "31", color)
            lines.append("  \(marker) \(pad(source.provider, 7)) \(truncate(source.path, width - 15))")
        }

        lines += ["", "Recently Active Agents"]
        guard !statuses.isEmpty else {
            lines.append("  none")
            return lines.joined(separator: "\n")
        }

        let columns = visibleColumns(width: width)
        let widths = columnWidths(width: width, columns: columns)
        let modeColumn = columns.firstIndex(of: 3)
        lines.append(separator(widths))
        lines.append(row(columns.map { headers[$0] }, widths: widths))
        lines.append(separator(widths))
        for status in statuses {
            let cells = [
                status.provider,
                status.displayName,
                nonEmpty(status.origin) ?? "-",
                status.mode.label,
                formatDuration(status.age(now: snapshot.collectedAt)),
                status.eventName,
                nonEmpty(status.toolName) ?? "-",
                nonEmpty(status.cwd) ?? "-",
            ]
            lines.append(row(columns.map { cells[$0] }, widths: widths, modeColumn: modeColumn, mode: status.mode,
                             color: color))
        }
        lines.append(separator(widths))
        return lines.joined(separator: "\n")
    }

    /// Fresh rows (plus stale ones with `includeStale`), filtered to
    /// `age <= recentSeconds` unless `includeStale` or `recentSeconds <= 0`, sorted by
    /// (priority, newest first). The sort is stable.
    public static func visibleStatuses(_ snapshot: MonitorSnapshot, recentSeconds: Double, includeStale: Bool) -> [AgentStatus] {
        var statuses = snapshot.statuses
        if includeStale {
            statuses += snapshot.staleStatuses
        } else if recentSeconds > 0 {
            statuses = statuses.filter { $0.age(now: snapshot.collectedAt) <= recentSeconds }
        }
        return statuses.enumerated().sorted { lhs, rhs in
            let (a, b) = (lhs.element, rhs.element)
            if a.mode.priority != b.mode.priority { return a.mode.priority < b.mode.priority }
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Indices into `headers` of the columns that fit `width`: all eight from 154
    /// columns up, then without Origin, Event and Tool, one at a time.
    public static func visibleColumns(width: Int) -> [Int] {
        var columns = Array(headers.indices)
        for dropped in droppedFirst where tableWidth(fullWidths(columns)) > width {
            columns.removeAll { $0 == dropped }
        }
        return columns
    }

    /// Widths of `columns` for a table at most `width` wide (never below
    /// `minimumWidths`). From 154 columns up this is Python's layout
    /// (`cwd = max(18, min(width, 140) - 129)`, always 18), except that Cwd grows
    /// into the extra room. Narrower, the widest column shrinks first.
    public static func columnWidths(width: Int, columns: [Int]? = nil) -> [Int] {
        let columns = columns ?? visibleColumns(width: width)
        var widths = fullWidths(columns)
        widths[widths.count - 1] += max(0, width - tableWidth(widths))
        while tableWidth(widths) > width {
            let shrinkable = widths.indices.filter { widths[$0] > minimumWidths[columns[$0]] }
            guard let widest = shrinkable.max(by: { widths[$0] < widths[$1] }) else { break }
            widths[widest] -= 1
        }
        return widths
    }

    private static func fullWidths(_ columns: [Int]) -> [Int] {
        columns.map { $0 < fixedWidths.count ? fixedWidths[$0] : minimumCwdWidth }
    }

    /// Cells plus `| ` / ` | ` / ` |` borders.
    private static func tableWidth(_ widths: [Int]) -> Int {
        widths.reduce(0, +) + 3 * widths.count + 1
    }

    /// `+-----+----+`
    public static func separator(_ widths: [Int]) -> String {
        "+" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "+") + "+"
    }

    /// `| cell | cell |`, every cell truncated then left-justified; the mode column
    /// is colored after padding.
    public static func row(_ cells: [String], widths: [Int], modeColumn: Int? = nil, mode: AgentMode? = nil,
                           color: Bool = false) -> String {
        var padded: [String] = []
        for (index, (cell, width)) in zip(cells, widths).enumerated() {
            var text = pad(truncate(singleLine(cell), width), width)
            if index == modeColumn, let mode { text = colorize(text, modeColor(mode), color) }
            padded.append(" \(text) ")
        }
        return "|" + padded.joined(separator: "|") + "|"
    }

    /// Keeps `text` if it fits, else its first `width - 1` characters plus ".".
    public static func truncate(_ text: String, _ width: Int) -> String {
        guard text.count > width else { return text }
        guard width > 1 else { return String(text.prefix(max(0, width))) }
        return String(text.prefix(width - 1)) + "."
    }

    /// `59s`, `1m00s`, `59m59s`, `1h00m`, `24h01m` (negative → `0s`).
    public static func formatDuration(_ seconds: Double) -> String {
        let total = StatusText.wholeSeconds(seconds)
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m\(twoDigits(total % 60))s" }
        return "\(minutes / 60)h\(twoDigits(minutes % 60))m"
    }

    /// Python `f"{value:g}"`: `1`, `0.5`, `2.25`, `1e-05`.
    public static func formatG(_ value: Double) -> String {
        String(format: "%g", value)
    }

    /// `\e[<code>m<text>\e[0m` when enabled.
    public static func colorize(_ text: String, _ code: String, _ enabled: Bool) -> String {
        enabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    public static func modeColor(_ mode: AgentMode) -> String {
        switch mode {
        case .blockedError: return "31;1"
        case .waitingForInput: return "33;1"
        case .toolRunning: return "36;1"
        case .longTaskProgress: return "35;1"
        case .working: return "34;1"
        case .completed: return "32;1"
        case .idleReady, .unknown: return "37"
        }
    }

    /// Color is on unless `--no-color`, `NO_COLOR` is set (any value), or stdout is
    /// not a terminal.
    public static func shouldUseColor(noColorFlag: Bool, environment: [String: String], stdoutIsTTY: Bool) -> Bool {
        !noColorFlag && environment["NO_COLOR"] == nil && stdoutIsTTY
    }

    /// `2026-09-26 10:00:00` in `timeZone`.
    public static func localTimestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    // MARK: Helpers

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func twoDigits(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// Control characters (newlines, tabs, ESC) and Unicode line/paragraph
    /// separators would break the table layout; they become spaces. Format
    /// characters such as the zero-width joiner inside emoji are kept.
    static func singleLine(_ text: String) -> String {
        func breaksLayout(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
        guard text.unicodeScalars.contains(where: breaksLayout) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.map { breaksLayout($0) ? " " : $0 }))
    }
}
