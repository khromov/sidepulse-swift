import Foundation

public struct SessionRow: Sendable, Equatable, Identifiable {
    public var status: AgentStatus
    public var title: String
    public var project: String?
    public var menuTitle: String
    public var detail: String

    public init(status: AgentStatus, title: String, project: String?, menuTitle: String, detail: String) {
        self.status = status; self.title = title; self.project = project
        self.menuTitle = menuTitle; self.detail = detail
    }

    /// Unique per row only because rows are coalesced per session.
    public var id: String { status.agentID }

    public var displayState: DisplayState { status.mode.displayState }
}

public enum SessionRows {
    public static let limit = 10

    /// Injectable so tests need no filesystem.
    public typealias ProjectResolver = (String?) -> String?

    // MARK: Selection

    public static func candidates(snapshot: MonitorSnapshot, retention: TimeInterval) -> [AgentStatus] {
        let now = snapshot.collectedAt
        let recentDone = snapshot.staleStatuses.filter { $0.mode == .completed && $0.age(now: now) <= retention }
        return snapshot.statuses + recentDone
    }

    /// Keeps one status per provider session so a subagent collapses into its session; session-less
    /// statuses go last, matching Python's dict order.
    public static func coalesce(_ statuses: [AgentStatus]) -> [AgentStatus] {
        var order: [String] = []
        var byKey: [String: AgentStatus] = [:]
        var passthrough: [AgentStatus] = []
        for status in statuses {
            guard let sessionID = status.sessionID, !sessionID.isEmpty else {
                passthrough.append(status)
                continue
            }
            let key = status.provider.lowercased() + "\u{0}" + sessionID
            if let previous = byKey[key] {
                if coalesceRank(status) < coalesceRank(previous) { byKey[key] = status }
            } else {
                order.append(key)
                byKey[key] = status
            }
        }
        return order.compactMap { byKey[$0] } + passthrough
    }

    public static func recent(snapshot: MonitorSnapshot, retention: TimeInterval, limit: Int = limit) -> [AgentStatus] {
        let coalesced = coalesce(candidates(snapshot: snapshot, retention: retention))
        let sorted = coalesced.enumerated().sorted { lhs, rhs in
            let l = (lhs.element.mode.priority, -lhs.element.updatedAt.timeIntervalSince1970)
            let r = (rhs.element.mode.priority, -rhs.element.updatedAt.timeIntervalSince1970)
            return l != r ? l < r : lhs.offset < rhs.offset
        }
        return sorted.prefix(max(0, limit)).map(\.element)
    }

    public static func rows(snapshot: MonitorSnapshot, retention: TimeInterval, now: Date? = nil,
                            limit: Int = limit, projectName: ProjectResolver = projectName(cwd:)) -> [SessionRow] {
        let statuses = recent(snapshot: snapshot, retention: retention, limit: limit)
        return rows(for: statuses, now: now ?? snapshot.collectedAt, projectName: projectName)
    }

    public static func rows(for statuses: [AgentStatus], now: Date,
                            projectName: ProjectResolver = projectName(cwd:)) -> [SessionRow] {
        let parts = statuses.map { titleParts($0, project: projectName($0.cwd)) }
        var counts: [String: Int] = [:]
        let keys = zip(statuses, parts).map { status, part in
            collisionKey(provider: status.provider, title: part.title, project: part.project)
        }
        for key in keys { counts[key, default: 0] += 1 }
        return statuses.indices.map { index in
            let status = statuses[index]
            var title = parts[index].title
            if counts[keys[index], default: 0] > 1, let sessionID = status.sessionID, !sessionID.isEmpty {
                title += " (\(shortID(sessionID)))"
            }
            let project = parts[index].project
            return SessionRow(status: status, title: title, project: project,
                              menuTitle: menuTitle(title: title, project: project),
                              detail: detail(for: status, now: now))
        }
    }

    // MARK: Titles

    public static func titleParts(_ status: AgentStatus, project resolved: String?) -> (title: String, project: String?) {
        var project = resolved.flatMap { $0.isEmpty ? nil : $0 }
        var title = stripShortID(status.displayName, sessionID: status.sessionID)
        if let p = project, title.hasPrefix("\(p): ") {
            title = String(title.dropFirst(p.count + 2))
        } else if let separator = title.range(of: ": ") {
            if project == nil {
                let left = String(title[..<separator.lowerBound])
                project = left.isEmpty ? nil : left
            }
            title = String(title[separator.upperBound...])
        }
        if let p = project, DisplayNames.normalizeForComparison(p) == DisplayNames.normalizeForComparison(title) {
            project = nil
        }
        return (title.isEmpty ? status.displayName : title, project)
    }

    /// Like Python `strip_session_short_id`, this also strips any id-like ` (…)` suffix, not just this session's.
    public static func stripShortID(_ displayName: String, sessionID: String?) -> String {
        let text = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sessionID, !sessionID.isEmpty {
            let suffix = " (\(shortID(sessionID)))"
            if text.hasSuffix(suffix) {
                return String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) {
            let token = text[open.upperBound..<text.index(before: text.endIndex)]
            if (6...12).contains(token.count), token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
                return String(text[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    public static func menuTitle(title: String, project: String?) -> String {
        guard let project, !project.isEmpty else { return title }
        return "\(title)  \(project)"
    }

    public static func projectName(cwd: String?) -> String? {
        DisplayNames.projectName(cwd: cwd)
    }

    // MARK: Detail

    public static func detail(for status: AgentStatus, now: Date) -> String {
        var parts = [status.mode.displayState.label]
        for value in [status.eventName, status.toolName ?? ""] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
        parts.append(AgeFormat.relative(status.age(now: now)))
        let origin = status.origin?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        parts.append(origin.isEmpty ? menuProviderLabel(status.provider) : origin)
        return parts.joined(separator: " · ")
    }

    public static func menuProviderLabel(_ provider: String) -> String {
        if let known = HookProvider(rawValue: provider.lowercased()) { return known.label }
        guard let first = provider.first else { return "Agent" }
        return first.uppercased() + provider.dropFirst()
    }

    // MARK: Helpers

    static func shortID(_ sessionID: String) -> String { String(sessionID.prefix(8)) }

    static func collisionKey(provider: String, title: String, project: String?) -> String {
        provider.lowercased() + "\u{0}" + DisplayNames.normalizeForComparison(menuTitle(title: title, project: project))
    }

    private static func coalesceRank(_ status: AgentStatus) -> (Int, Int, Double) {
        (status.mode.priority, status.isSubagent ? 1 : 0, -status.updatedAt.timeIntervalSince1970)
    }
}

public enum AgeFormat {
    public static func relative(_ seconds: TimeInterval) -> String {
        let total = wholeSeconds(seconds)
        if total < 60 { return "\(total)s ago" }
        if total < 3600 { return "\(total / 60)m ago" }
        if total < 86_400 { return "\(total / 3600)h ago" }
        return "\(total / 86_400)d ago"
    }

    /// Python `int(x)` for an age, but 0 for NaN/infinity and capped at `Int32.max` so the conversion can't trap.
    public static func wholeSeconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds, Double(Int32.max)))
    }
}
