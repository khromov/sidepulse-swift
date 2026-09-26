import Foundation
import SidePulseCore

public enum SnapshotOrigin: Equatable, Sendable {
    case app
    case logsAppNotRunning
    case logsOffline

    public var headerLine: String {
        switch self {
        case .app: return "Source: SidePulse app (live)"
        case .logsAppNotRunning: return "Source: hook logs (app not running)"
        case .logsOffline: return "Source: hook logs (offline)"
        }
    }

    public var shortLabel: String { self == .app ? "app" : "logs" }
}

/// Output follows Python `render_snapshot` / `describe_status`.
public enum StatusText {
    /// Empty optional fields are omitted, like Python's truthiness checks.
    public static func describe(_ status: AgentStatus, now: Date) -> String {
        let age = AgeFormat.wholeSeconds(status.age(now: now))
        var text = "\(status.displayName): \(status.mode.label) event=\(status.eventName)"
        if let origin = status.origin, !origin.isEmpty { text += " origin=\(origin)" }
        if let tool = status.toolName, !tool.isEmpty { text += " tool=\(tool)" }
        text += " age=\(age)s"
        if status.stale { text += " stale" }
        if let cwd = status.cwd, !cwd.isEmpty { text += " cwd=\(cwd)" }
        return text
    }

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
}
