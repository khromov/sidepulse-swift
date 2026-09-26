import Foundation
import SidePulseCore

public struct LiveDashboardOptions: Sendable {
    public var interval: Double = 1
    /// 0 means no limit.
    public var recentSeconds: Double = 3600
    /// Also disables the `recentSeconds` filter.
    public var includeStale = false
    public var color = false
    public var width = 120
    public var timeZone: TimeZone = .current
    public var origin: SnapshotOrigin = .logsAppNotRunning

    public init() {}
}

/// Layout follows Python `render_watch_dashboard`.
public enum LiveDashboard {
    public static let title = "SidePulse"
    public static let headers = ["Provider", "Agent", "Origin", "Mode", "Age", "Event", "Tool", "Cwd"]
    /// Every column except the last (Cwd), as in Python.
    public static let fixedWidths = [9, 22, 18, 20, 8, 18, 16]
    public static let minimumCwdWidth = 18
    /// Narrow terminals drop Origin, Event and Tool in that order, then shrink columns towards
    /// `minimumWidths`, where Mode keeps room for its longest label.
    static let droppedFirst = [2, 5, 6]
    static let minimumWidths = [6, 8, 0, 18, 6, 0, 0, 8]
    /// The frame is never narrower than the smallest table.
    public static let minimumWidth = 62

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

    public static func visibleColumns(width: Int) -> [Int] {
        var columns = Array(headers.indices)
        for dropped in droppedFirst where tableWidth(fullWidths(columns)) > width {
            columns.removeAll { $0 == dropped }
        }
        return columns
    }

    /// Unlike Python's fixed layout, Cwd grows into any extra room and narrower terminals shrink
    /// the widest column first.
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

    public static func separator(_ widths: [Int]) -> String {
        "+" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "+") + "+"
    }

    /// The mode column is colored after padding so escape codes don't count towards its width.
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

    public static func truncate(_ text: String, _ width: Int) -> String {
        guard text.count > width else { return text }
        guard width > 1 else { return String(text.prefix(max(0, width))) }
        return String(text.prefix(width - 1)) + "."
    }

    public static func formatDuration(_ seconds: Double) -> String {
        let total = StatusText.wholeSeconds(seconds)
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m\(twoDigits(total % 60))s" }
        return "\(minutes / 60)h\(twoDigits(minutes % 60))m"
    }

    public static func formatG(_ value: Double) -> String {
        String(format: "%g", value)
    }

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

    public static func shouldUseColor(noColorFlag: Bool, environment: [String: String], stdoutIsTTY: Bool) -> Bool {
        !noColorFlag && environment["NO_COLOR"] == nil && stdoutIsTTY
    }

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

    /// Only characters that break the table layout become spaces, so format characters like the
    /// zero-width joiner in emoji survive.
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
