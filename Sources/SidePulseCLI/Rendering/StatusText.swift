import Foundation
import SidePulseCore

/// Where a snapshot came from; printed as the first line of `sidepulse status`.
public enum SnapshotOrigin: Equatable, Sendable {
    /// The running app answered the `status` command.
    case app
    /// Rebuilt from the hook logs because the app did not answer.
    case logsAppNotRunning
    /// Rebuilt from the hook logs because `--offline` was given.
    case logsOffline

    public var headerLine: String {
        switch self {
        case .app: return "Source: SidePulse app (live)"
        case .logsAppNotRunning: return "Source: hook logs (app not running)"
        case .logsOffline: return "Source: hook logs (offline)"
        }
    }

    /// Short form for the live dashboard (`source=app`).
    public var shortLabel: String { self == .app ? "app" : "logs" }
}

/// Plain-text rendering of snapshots (Python `render_snapshot` / `describe_status`).
public enum StatusText {
    /// `{display_name}: {mode_label} event={event}[ origin=..][ tool=..] age={int}s[ stale][ cwd=..]`
    /// (empty optional fields are omitted, like Python's truthiness checks).
    public static func describe(_ status: AgentStatus, now: Date) -> String {
        let age = wholeSeconds(status.age(now: now))
        var text = "\(status.displayName): \(status.mode.label) event=\(status.eventName)"
        if let origin = status.origin, !origin.isEmpty { text += " origin=\(origin)" }
        if let tool = status.toolName, !tool.isEmpty { text += " tool=\(tool)" }
        text += " age=\(age)s"
        if status.stale { text += " stale" }
        if let cwd = status.cwd, !cwd.isEmpty { text += " cwd=\(cwd)" }
        return text
    }

    /// ```
    /// Aggregate: Working (1 active, 0 stale)
    /// Reason: <describe(representative)>        (only with a representative)
    ///
    /// Sources:
    ///   claude: /…/logs/claude.jsonl [ok|missing]
    ///
    /// Agents:
    ///   <describe(row)>                          (fresh rows, then stale ones with includeStale)
    /// ```
    public static func render(_ snapshot: MonitorSnapshot, includeStale: Bool,
                              fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let aggregate = snapshot.aggregate
        var lines = ["Aggregate: \(aggregate.mode.label) (\(aggregate.activeCount) active, \(aggregate.staleCount) stale)"]
        if let representative = aggregate.representative {
            lines.append("Reason: \(describe(representative, now: snapshot.collectedAt))")
        }
        lines += ["", "Sources:"]
        if snapshot.sources.isEmpty { lines.append("  none") }
        for source in snapshot.sources {
            lines.append("  \(source.provider): \(source.path) [\(fileExists(source.path) ? "ok" : "missing")]")
        }
        var statuses = snapshot.statuses
        if includeStale { statuses += snapshot.staleStatuses }
        lines += ["", "Agents:"]
        if statuses.isEmpty {
            lines.append("  none")
        } else {
            lines += statuses.map { "  \(describe($0, now: snapshot.collectedAt))" }
        }
        return lines.joined(separator: "\n")
    }

    /// Python `int(x)` for a non-negative age (truncation, safe for huge values).
    static func wholeSeconds(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(max(0, min(value, Double(Int32.max))))
    }
}
