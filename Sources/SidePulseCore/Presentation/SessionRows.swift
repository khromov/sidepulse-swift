import Foundation

/// One row of the menu's Agents section (spec status-bar §5 "Session rows").
public struct SessionRow: Sendable, Equatable, Identifiable {
    /// The status the row was built from.
    public var status: AgentStatus
    /// Task title: the display name without its project prefix and short-id suffix.
    /// Rows whose titles collide get a ` (<session_id[:8]>)` suffix.
    public var title: String
    /// Project name (git root or cwd basename, else the `project: ` prefix of the
    /// display name). nil when absent or equal to the title.
    public var project: String?
    /// `title + "  " + project` (two spaces; the project is omitted when nil).
    public var menuTitle: String
    /// One-line detail used as the row tooltip, e.g.
    /// `Working · PreToolUse · Bash · 2m ago · Claude Code CLI`.
    public var detail: String

    public init(status: AgentStatus, title: String, project: String?, menuTitle: String, detail: String) {
        self.status = status; self.title = title; self.project = project
        self.menuTitle = menuTitle; self.detail = detail
    }

    /// The status key (unique per row after coalescing).
    public var id: String { status.agentID }

    /// Drives the row glyph (same mapping as the menu-bar icon).
    public var displayState: DisplayState { status.mode.displayState }
}

/// Builds the recent-session rows shown in the status menu. Pure logic (the only
/// I/O is the cached `.git` lookup of `DisplayNames.projectName(cwd:)`), ported
/// from Python `status_bar.recent_statuses` / `native_session_menu_title` /
/// `session_title_parts`.
public enum SessionRows {
    /// Python `STATUS_BAR_SESSION_HISTORY_LIMIT`.
    public static let limit = 10

    /// Resolves a project name for a cwd. Injectable so tests need no filesystem.
    public typealias ProjectResolver = (String?) -> String?

    // MARK: Selection

    /// Python `menu_statuses`: the snapshot's fresh rows plus stale Completed rows
    /// whose age (relative to `snapshot.collectedAt`) is within `retention`.
    public static func candidates(snapshot: MonitorSnapshot, retention: TimeInterval) -> [AgentStatus] {
        let now = snapshot.collectedAt
        let recentDone = snapshot.staleStatuses.filter { $0.mode == .completed && $0.age(now: now) <= retention }
        return snapshot.statuses + recentDone
    }

    /// Python `coalesced_menu_statuses`: one status per (lowercased provider,
    /// session id), keeping the lowest (priority, subagent penalty, -updatedAt), so a
    /// subagent collapses into its session. Earlier statuses win exact ties.
    /// Statuses without a session id pass through unchanged, after the coalesced
    /// ones (dictionary insertion order, like Python).
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

    /// Python `recent_statuses`: candidates → coalesce → stable sort by
    /// (priority, newest first) → first `limit`.
    public static func recent(snapshot: MonitorSnapshot, retention: TimeInterval, limit: Int = limit) -> [AgentStatus] {
        let coalesced = coalesce(candidates(snapshot: snapshot, retention: retention))
        let sorted = coalesced.enumerated().sorted { lhs, rhs in
            let l = (lhs.element.mode.priority, -lhs.element.updatedAt.timeIntervalSince1970)
            let r = (rhs.element.mode.priority, -rhs.element.updatedAt.timeIntervalSince1970)
            return l != r ? l < r : lhs.offset < rhs.offset
        }
        return sorted.prefix(max(0, limit)).map(\.element)
    }

    /// The menu rows: `recent(...)` with titles, projects, collision suffixes and
    /// detail text.
    /// - Parameters:
    ///   - now: reference time for the detail's relative age (defaults to the
    ///     snapshot's collection time).
    ///   - projectName: cwd → project resolver (defaults to the `.git` lookup).
    public static func rows(snapshot: MonitorSnapshot, retention: TimeInterval, now: Date? = nil,
                            limit: Int = limit, projectName: ProjectResolver = projectName(cwd:)) -> [SessionRow] {
        let statuses = recent(snapshot: snapshot, retention: retention, limit: limit)
        return rows(for: statuses, now: now ?? snapshot.collectedAt, projectName: projectName)
    }

    /// Builds rows for already-selected statuses, adding ` (<sid8>)` to the titles of
    /// rows that share (provider, normalized `title  project`) with another row.
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

    /// Python `session_title_parts`:
    /// 1. strip the short-id suffix (`stripShortID`);
    /// 2. drop a leading `"<project>: "`; otherwise split on the first `": "` —
    ///    the left part becomes the project when none was resolved from the cwd;
    /// 3. drop the project when it equals the title after
    ///    `DisplayNames.normalizeForComparison` (Python `normalized_menu_part`).
    /// An empty title falls back to the full display name.
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

    /// Python `strip_session_short_id`: trims, then removes a trailing
    /// ` (<session_id[:8]>)`, or any trailing ` (<6-12 alphanumerics or '-'>)`.
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

    /// `title + "  " + project` (Python `native_session_menu_title`).
    public static func menuTitle(title: String, project: String?) -> String {
        guard let project, !project.isEmpty else { return title }
        return "\(title)  \(project)"
    }

    /// The default project resolver (Python `project_name_from_cwd`):
    /// `DisplayNames.projectName(cwd:)`.
    public static func projectName(cwd: String?) -> String? {
        DisplayNames.projectName(cwd: cwd)
    }

    // MARK: Detail

    /// `<state> · <event> · <tool> · <age> ago · <origin or provider>`; empty parts
    /// are skipped. e.g. `Working · PreToolUse · Bash · 2m ago · Claude Code CLI`.
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

    /// The provider name shown in the menu: `HookProvider.label` ("Claude Code" /
    /// "Codex") for the supported providers, else the provider name with its first
    /// letter uppercased. (Fallback row labels use
    /// `DisplayNames.fallbackProviderLabel` instead.)
    public static func menuProviderLabel(_ provider: String) -> String {
        if let known = HookProvider(rawValue: provider.lowercased()) { return known.label }
        guard let first = provider.first else { return "Agent" }
        return first.uppercased() + provider.dropFirst()
    }

    // MARK: Helpers

    static func shortID(_ sessionID: String) -> String { String(sessionID.prefix(8)) }

    /// Python `session_title_collision_key`: provider + normalized native title.
    static func collisionKey(provider: String, title: String, project: String?) -> String {
        provider.lowercased() + "\u{0}" + DisplayNames.normalizeForComparison(menuTitle(title: title, project: project))
    }

    /// Python `menu_status_sort_key`.
    private static func coalesceRank(_ status: AgentStatus) -> (Int, Int, Double) {
        (status.mode.priority, status.isSubagent ? 1 : 0, -status.updatedAt.timeIntervalSince1970)
    }
}

/// Age strings for menus and tooltips.
public enum AgeFormat {
    /// Relative age: `45s ago`, `2m ago`, `3h ago`, `2d ago` (truncated, never negative).
    public static func relative(_ seconds: TimeInterval) -> String {
        let total = wholeSeconds(seconds)
        if total < 60 { return "\(total)s ago" }
        if total < 3600 { return "\(total / 60)m ago" }
        if total < 86_400 { return "\(total / 3600)h ago" }
        return "\(total / 86_400)d ago"
    }

    /// Python `int(x)` for an age: truncated, never negative, 0 for NaN/infinity,
    /// capped at `Int32.max`.
    public static func wholeSeconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds, Double(Int32.max)))
    }
}
