import Foundation

public struct MonitorConfig: Sendable, Equatable {
    public var staleAfter: TimeInterval
    public var retention: TimeInterval

    public init(staleAfter: TimeInterval = 3600, retention: TimeInterval = 172_800) {
        self.staleAfter = staleAfter; self.retention = retention
    }
}

/// Not thread-safe, so callers must serialize access. Events are applied in the
/// order they are ingested, except that one logged shortly before its row's last
/// update is dropped as late (see `lateEventWindow`).
public final class StatusEngine {
    public var config: MonitorConfig
    public private(set) var statuses: [String: AgentStatus] = [:]

    private let codexTitle: ((String) -> String?)?
    private var metadataBySession: [String: StatusMetadata] = [:]
    private var metadataByStatus: [String: StatusMetadata] = [:]
    private var pending: [String: Set<String>] = [:]
    private var backgroundTasks: [String: Set<String>] = [:]

    /// The socket server stops waiting for a stalled message after about 0.25 s, so it
    /// can arrive after newer events; the bound keeps a backward clock jump from
    /// freezing a row.
    static let lateEventWindow: TimeInterval = 5

    /// Codex desktop's background helper sessions (suggestions, safety checks) use
    /// these prompts and must not show as rows.
    static let codexHelperPrompts = [
        "generate 0 to 3 hyperpersonalized suggestions",
        "you are an expert at upholding safety and compliance standards",
    ]

    public init(config: MonitorConfig = MonitorConfig(), codexTitle: ((String) -> String?)? = nil) {
        self.config = config
        self.codexTitle = codexTitle
    }

    @discardableResult
    public func ingest(_ event: HookEvent) -> AgentStatus? {
        // Metadata is updated even when the event is dropped below.
        let metadata = updateMetadata(for: event)
        if isLate(event) {
            // The command has finished either way, so its prompt must not stay sticky.
            if event.eventName == "PostToolUse" || event.eventName == "PostToolUseFailure" {
                trackPendingPermissions(event)
            }
            return nil
        }
        guard let status = makeStatus(for: event, metadata: metadata) else { return nil }
        trackPendingPermissions(event)
        completeFinishedSubagents(after: event)
        let key = status.agentID
        let notificationType = PyText.strip(PyText.str(event.raw["notification_type"])).lowercased()
        if Self.shouldIgnoreTransition(from: statuses[key], to: status, pending: pending[key] ?? [],
                                       notificationType: notificationType) { return nil }
        statuses[key] = status
        return status
    }

    @discardableResult
    public func ingest(provider: String, line: JSONObject, now: Date = Date()) -> AgentStatus? {
        guard let event = EventParser.parseRecord(provider: provider, object: line, now: now) else { return nil }
        return ingest(event)
    }

    private func isLate(_ event: HookEvent) -> Bool {
        guard let row = statuses[event.statusKey] else { return false }
        let lag = row.updatedAt.timeIntervalSince(event.loggedAt)
        return lag > 0 && lag <= Self.lateEventWindow
    }

    public func load(_ restored: [AgentStatus]) {
        for var status in restored {
            if status.provider == "codex", !status.isSubagent,
               let sessionID = status.sessionID, let title = codexSessionTitle(sessionID) {
                status.displayName = DisplayNames.displayName(
                    project: DisplayNames.projectName(cwd: status.cwd), title: title,
                    short: DisplayNames.shortID(sessionID), fallback: status.displayName)
            }
            statuses[status.agentID] = status
            seedMetadata(from: status)
        }
    }

    /// Transition rules are not reapplied because the scan already applied them to
    /// events this engine never saw.
    @discardableResult
    public func reconcile(with recovered: [AgentStatus]) -> Bool {
        var changed = false
        for var status in recovered {
            let current = statuses[status.agentID]
            if let current, status.updatedAt < current.updatedAt { continue }
            relabelWithKnownTitle(&status)
            if status != current {
                statuses[status.agentID] = status
                seedMetadata(from: status)
                changed = true
            }
        }
        return changed
    }

    /// Restores the scan's pending prompts only where the row is still that same
    /// PermissionRequest, so a newer row is never held on Ask by an old prompt.
    @discardableResult
    public func reconcile(with recovery: LogRecovery) -> Bool {
        let changed = reconcile(with: recovery.statuses)
        let scanned = Dictionary(recovery.statuses.map { ($0.agentID, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, signatures) in recovery.pendingPermissions {
            guard let row = statuses[key], let scannedRow = scanned[key], row.eventName == "PermissionRequest",
                  scannedRow.eventName == "PermissionRequest",
                  abs(row.updatedAt.timeIntervalSince(scannedRow.updatedAt)) < 0.001 else { continue }
            pending[key, default: []].formUnion(signatures)
        }
        return changed
    }

    /// Uses the absolute age so a row dated in the future (a backward clock jump) is
    /// pruned too.
    public func prune(now: Date) {
        let cutoff = max(config.staleAfter, config.retention)
        func keep(_ date: Date) -> Bool { abs(now.timeIntervalSince(date)) <= cutoff }
        statuses = statuses.filter { keep($0.value.updatedAt) }
        metadataByStatus = metadataByStatus.filter { keep($0.value.lastSeen) }
        metadataBySession = metadataBySession.filter { keep($0.value.lastSeen) }
        pending = pending.filter { statuses[$0.key] != nil }
        backgroundTasks = backgroundTasks.filter { statuses[$0.key] != nil }
    }

    public func snapshot(now: Date = Date(), sources: [SourceInfo] = []) -> MonitorSnapshot {
        SnapshotBuilder.build(statuses: Array(statuses.values), config: config, now: now, sources: sources)
    }

    var pendingPermissions: [String: Set<String>] {
        pending
    }

    // MARK: Metadata

    private func updateMetadata(for event: HookEvent) -> StatusMetadata {
        let title = titleFromEvent(event)
        var sessionMetadata: StatusMetadata?
        if let sessionID = event.sessionID, !sessionID.isEmpty {
            let key = "\(event.provider):session:\(sessionID)"
            var entry = metadataBySession[key] ?? StatusMetadata()
            entry.update(with: event, title: title)
            metadataBySession[key] = entry
            sessionMetadata = entry
        }
        var statusMetadata = metadataByStatus[event.statusKey] ?? StatusMetadata()
        statusMetadata.update(with: event, title: title)
        metadataByStatus[event.statusKey] = statusMetadata

        guard let sessionMetadata else { return statusMetadata }
        return StatusMetadata(cwd: statusMetadata.cwd ?? sessionMetadata.cwd,
                              title: statusMetadata.title ?? sessionMetadata.title,
                              origin: statusMetadata.origin ?? sessionMetadata.origin,
                              lastSeen: statusMetadata.lastSeen)
    }

    private func titleFromEvent(_ event: HookEvent) -> EventTitle? {
        if event.provider == "codex", let sessionID = event.sessionID, let title = codexSessionTitle(sessionID) {
            return EventTitle(text: title, overrides: true)
        }
        guard event.eventName == "UserPromptSubmit",
              let summary = DisplayNames.summarizePrompt(event.raw["prompt"]?.stringValue) else { return nil }
        return EventTitle(text: summary, overrides: false)
    }

    private func codexSessionTitle(_ sessionID: String) -> String? {
        guard !sessionID.isEmpty, let title = codexTitle?(sessionID), !title.isEmpty else { return nil }
        return title
    }

    /// Lets the next live event keep a restored row's label without overwriting
    /// metadata that live events already set.
    private func seedMetadata(from status: AgentStatus) {
        let seed = StatusMetadata(cwd: status.cwd, title: Self.titleFromDisplayName(status),
                                  origin: status.origin, lastSeen: status.updatedAt)
        metadataByStatus[status.agentID, default: StatusMetadata()].fill(from: seed)
        if let sessionID = status.sessionID, !sessionID.isEmpty {
            metadataBySession["\(status.provider):session:\(sessionID)", default: StatusMetadata()].fill(from: seed)
        }
    }

    /// A recovery scan only sees the log's tail, so without this it would relabel
    /// long sessions whose first prompt fell outside that window.
    private func relabelWithKnownTitle(_ status: inout AgentStatus) {
        guard let short = Self.shortLabel(for: status) else { return }
        let own = metadataByStatus[status.agentID]
        let session = status.sessionID.flatMap { $0.isEmpty ? nil : metadataBySession["\(status.provider):session:\($0)"] }
        let indexTitle = status.provider == "codex" ? status.sessionID.flatMap(codexSessionTitle) : nil
        guard let title = indexTitle ?? own?.title ?? session?.title else { return }
        // The row's cwd is its newest event's, which a live event would have
        // recorded before labeling.
        let cwd = status.cwd ?? own?.cwd ?? session?.cwd
        status.displayName = DisplayNames.displayName(project: DisplayNames.projectName(cwd: cwd), title: title,
                                                      short: short, fallback: status.displayName)
    }

    static func shortLabel(for status: AgentStatus) -> String? {
        let agentPrefix = "\(status.provider):agent:"
        if PyText.startsWith(status.agentID, agentPrefix) {
            let agentID = String(decoding: status.agentID.utf8.dropFirst(agentPrefix.utf8.count), as: UTF8.self)
            return "agent " + DisplayNames.shortID(agentID)
        }
        guard let sessionID = status.sessionID, !sessionID.isEmpty else { return nil }
        return DisplayNames.shortID(sessionID)
    }

    /// Nil without a cwd, because then the project prefix can't be told apart from
    /// the title.
    static func titleFromDisplayName(_ status: AgentStatus) -> String? {
        guard let cwd = status.cwd, let project = DisplayNames.projectName(cwd: cwd),
              let short = shortLabel(for: status) else { return nil }
        let suffix = " (\(short))"
        guard PyText.endsWith(status.displayName, suffix) else { return nil }
        let body = String(decoding: status.displayName.utf8.dropLast(suffix.utf8.count), as: UTF8.self)
        let projectPrefix = "\(project): "
        if PyText.startsWith(body, projectPrefix) {
            let title = String(decoding: body.utf8.dropFirst(projectPrefix.utf8.count), as: UTF8.self)
            return title.isEmpty ? nil : title
        }
        return body.isEmpty || body == project ? nil : body
    }

    // MARK: Status

    private func makeStatus(for event: HookEvent, metadata: StatusMetadata) -> AgentStatus? {
        guard let mode = ModeClassifier.mode(for: event) else { return nil }
        if isCodexHelperEvent(event, metadata: metadata) { return nil }

        let label = DisplayNames.fallbackProviderLabel(event.provider)
        let displayName: String
        if let agentID = event.agentID, !agentID.isEmpty {
            let short = DisplayNames.shortID(agentID)
            displayName = self.displayName(for: event, metadata: metadata, short: "agent \(short)",
                                           fallback: "\(label) agent \(short)")
        } else if let sessionID = event.sessionID, !sessionID.isEmpty {
            let short = DisplayNames.shortID(sessionID)
            displayName = self.displayName(for: event, metadata: metadata, short: short,
                                           fallback: "\(label) session \(short)")
        } else {
            displayName = label
        }

        return AgentStatus(provider: event.provider, agentID: event.statusKey, displayName: displayName,
                           mode: mode, updatedAt: event.loggedAt, eventName: event.eventName,
                           sessionID: event.sessionID, cwd: event.cwd, toolName: event.toolName,
                           message: event.message, origin: event.origin ?? metadata.origin)
    }

    private func displayName(for event: HookEvent, metadata: StatusMetadata, short: String, fallback: String) -> String {
        DisplayNames.displayName(project: DisplayNames.projectName(cwd: metadata.cwd ?? event.cwd),
                                 title: metadata.title, short: short, fallback: fallback)
    }

    /// Checking the session's title too drops every later event of a helper session.
    private func isCodexHelperEvent(_ event: HookEvent, metadata: StatusMetadata) -> Bool {
        guard event.provider == "codex" else { return false }
        let parts = [metadata.title,
                     PyText.nonEmptyString(event.raw["prompt"]),
                     PyText.nonEmptyString(event.raw["message"]),
                     PyText.nonEmptyString(event.raw["last_assistant_message"])]
        let text = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ").lowercased()
        guard !text.isEmpty else { return false }
        return PyText.contains(text, anyOf: Self.codexHelperPrompts)
    }

    // MARK: Permissions

    static func permissionSignature(_ event: HookEvent) -> String? {
        guard let toolInput = event.raw["tool_input"]?.objectValue,
              let command = PyText.nonEmptyString(toolInput["command"]) else { return nil }
        let toolName = PyText.nonEmptyString(event.raw["tool_name"]) ?? event.toolName ?? ""
        return "\(toolName)\u{0}\(command)"
    }

    /// Unlike Python, PostToolUseFailure releases a prompt (a denial logs no
    /// PostToolUse*, so the command ran) and SubagentStop clears its subagent's
    /// prompts, since turn-ending events never carry an agent_id.
    private func trackPendingPermissions(_ event: HookEvent) {
        let key = event.statusKey
        let signature = Self.permissionSignature(event)
        switch event.eventName {
        case "PermissionRequest" where signature != nil:
            pending[key, default: []].insert(signature!)
        case "PostToolUse", "PostToolUseFailure":
            guard let signature, var set = pending[key] else { return }
            set.remove(signature)
            pending[key] = set.isEmpty ? nil : set
        case "Stop", "Interrupt", "SessionEnd", "SubagentStop", "UserPromptSubmit":
            pending[key] = nil
        default:
            break
        }
    }

    /// Claude sends no SubagentStop for a subagent killed with its session, nor OpenCode
    /// for one that failed or asked (they run synchronously, so the parent's turn end closes them).
    /// A Claude Stop closes only ids its `background_task_ids` dropped since the last one,
    /// because the list also holds workflow and shell task ids.
    private func completeFinishedSubagents(after event: HookEvent) {
        guard event.agentID?.isEmpty ?? true, let sessionID = event.sessionID, !sessionID.isEmpty else { return }
        let prefix = "\(event.provider):agent:"
        let finished: (String) -> Bool
        if event.provider == "opencode", ["Stop", "StopFailure", "Interrupt"].contains(event.eventName) {
            finished = { _ in true }
        } else if event.eventName == "SessionEnd" {
            backgroundTasks[event.statusKey] = nil
            finished = { _ in true }
        } else if event.eventName == "Stop", let ids = event.raw["background_task_ids"]?.arrayValue {
            let running = Set(ids.compactMap(\.stringValue))
            let dropped = Set((backgroundTasks[event.statusKey] ?? []).subtracting(running).map { prefix + $0 })
            backgroundTasks[event.statusKey] = running
            finished = { dropped.contains($0) }
        } else {
            return
        }
        for (key, var row) in statuses where row.mode.isActive && row.sessionID == sessionID
            && PyText.startsWith(key, prefix) && finished(key) {
            row.mode = .completed
            row.updatedAt = event.loggedAt
            row.eventName = event.eventName
            row.toolName = nil
            statuses[key] = row
            pending[key] = nil
        }
    }

    /// `notificationType` must already be stripped and lowercased.
    static func shouldIgnoreTransition(from previous: AgentStatus?, to current: AgentStatus, pending: Set<String>,
                                       notificationType: String? = nil) -> Bool {
        if current.eventName == "Notification" {
            // Claude's idle_prompt Notification (~60 s after Stop) must not turn Done into Ask.
            if previous?.mode == .completed { return true }
            // idle_prompt also follows SessionStart, and a key with no row means a log
            // scan whose tail window began after the Stop.
            if notificationType == "idle_prompt" && (previous == nil || previous?.mode == .idleReady) { return true }
        }
        guard let previous else { return false }
        // An approval prompt stays up until its command finishes or the turn ends.
        return previous.mode == .waitingForInput && previous.eventName == "PermissionRequest"
            && current.eventName != "PermissionRequest" && !pending.isEmpty
    }
}

/// Codex session-index titles override an existing title, while prompt titles only
/// fill an empty one so the first prompt sticks.
private struct EventTitle {
    var text: String
    var overrides: Bool
}

struct StatusMetadata: Equatable {
    var cwd: String?
    var title: String?
    var origin: String?
    var lastSeen: Date = .distantPast

    fileprivate mutating func update(with event: HookEvent, title: EventTitle?) {
        if let cwd = event.cwd, !cwd.isEmpty { self.cwd = cwd }
        if let title, self.title == nil || title.overrides { self.title = title.text }
        if let origin = event.origin { self.origin = origin }
        lastSeen = max(lastSeen, event.loggedAt)
    }

    mutating func fill(from seed: StatusMetadata) {
        cwd = cwd ?? seed.cwd
        title = title ?? seed.title
        origin = origin ?? seed.origin
        lastSeen = max(lastSeen, seed.lastSeen)
    }
}

public enum SnapshotBuilder {
    static let completedVisible: TimeInterval = 1200
    /// A Working row from PostToolUse settles to Completed after this long.
    static let postToolWorkingVisible: TimeInterval = 120

    public static func build(statuses: [AgentStatus], config: MonitorConfig, now: Date, sources: [SourceInfo]) -> MonitorSnapshot {
        var fresh: [AgentStatus] = []
        var stale: [AgentStatus] = []
        for original in statuses {
            var status = original
            if status.mode == .working, status.eventName == "PostToolUse", status.age(now: now) > postToolWorkingVisible {
                status.mode = .completed
            }
            status.stale = isStale(status, config: config, now: now)
            if status.stale { stale.append(status) } else { fresh.append(status) }
        }

        if fresh.contains(where: { $0.mode.isActive }) {
            for var status in fresh where !status.mode.isActive {
                status.stale = true
                stale.append(status)
            }
            fresh.removeAll { !$0.mode.isActive }
        }

        fresh.sort(by: displayOrder)
        stale.sort(by: displayOrder)

        let aggregate = AggregateStatus(mode: fresh.first?.mode ?? .idleReady,
                                        activeCount: fresh.filter { $0.mode.isActive }.count,
                                        staleCount: stale.count,
                                        representative: fresh.first)
        return MonitorSnapshot(collectedAt: now, sources: sources, aggregate: aggregate,
                               statuses: fresh, staleStatuses: stale)
    }

    /// A row dated further ahead than this (a backward clock jump) would otherwise
    /// never age.
    static let futureTolerance: TimeInterval = 300

    static func isStale(_ status: AgentStatus, config: MonitorConfig, now: Date) -> Bool {
        if status.updatedAt.timeIntervalSince(now) > futureTolerance { return true }
        let age = status.age(now: now)
        switch status.mode {
        case .completed: return age > completedVisible
        // An idle row is only news at the moment it arrives.
        case .idleReady: return age > 0
        default: return age > config.staleAfter
        }
    }

    /// agentID breaks ties so the order is deterministic.
    static func displayOrder(_ a: AgentStatus, _ b: AgentStatus) -> Bool {
        if a.mode.priority != b.mode.priority { return a.mode.priority < b.mode.priority }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.agentID < b.agentID
    }
}
