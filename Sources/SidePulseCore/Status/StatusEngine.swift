import Foundation

public struct MonitorConfig: Sendable, Equatable {
    /// Rows older than this are stale (Python `stale_after_seconds`; app uses the
    /// settings idle timeout).
    public var staleAfter: TimeInterval = 3600
    /// 0 = disabled.
    public var toolRunningTimeout: TimeInterval = 0
    /// Completed rows stay visible this long (20 min).
    public var completedVisible: TimeInterval = 1200
    /// Idle rows are hidden immediately.
    public var idleVisible: TimeInterval = 0
    /// PostToolUse→Working settles to Completed after this long (2 min).
    public var postToolWorkingVisible: TimeInterval = 120
    /// Rows older than max(staleAfter, retention) are pruned from memory/latest.json.
    public var retention: TimeInterval = 172_800

    public init() {}
    public init(staleAfter: TimeInterval, toolRunningTimeout: TimeInterval = 0, completedVisible: TimeInterval = 1200,
                idleVisible: TimeInterval = 0, postToolWorkingVisible: TimeInterval = 120, retention: TimeInterval = 172_800) {
        self.staleAfter = staleAfter; self.toolRunningTimeout = toolRunningTimeout; self.completedVisible = completedVisible
        self.idleVisible = idleVisible; self.postToolWorkingVisible = postToolWorkingVisible; self.retention = retention
    }
}

/// The per-key state machine (Python `LiveAgentMonitor.ingest_record` /
/// `AgentMonitor._latest_statuses`). NOT thread-safe: callers serialize access.
///
/// For each event: update per-session and per-key metadata (cwd, origin, first
/// prompt title), compute the status (`ModeClassifier.mode`, display name), track
/// pending permissions (PermissionRequest with tool_input.command adds
/// `"<tool>\0<command>"`, PostToolUse/PostToolUseFailure remove, Stop/Interrupt/
/// SessionEnd/SubagentStop/UserPromptSubmit clear), close the session's finished
/// subagent rows (parent SessionEnd, or a parent Stop's running-task list), then
/// apply the ignore rules (Completed row ignores any Notification; an Idle row or a
/// key with no row ignores Claude's idle_prompt; a sticky PermissionRequest row
/// ignores other events while pending is non-empty) and store the status.
///
/// Events are applied in the order given; the engine never compares timestamps
/// (a late, older event overwrites). `LogScanner.scan` sorts before ingesting.
public final class StatusEngine {
    public var config: MonitorConfig
    public private(set) var statuses: [String: AgentStatus] = [:]

    private let codexTitle: ((String) -> String?)?
    /// Keyed by `"{provider}:session:{session_id}"`.
    private var metadataBySession: [String: StatusMetadata] = [:]
    /// Keyed by status key.
    private var metadataByStatus: [String: StatusMetadata] = [:]
    private var pending: [String: Set<String>] = [:]

    /// Prompts of Codex desktop background helper sessions (suggestions, safety
    /// checks). Codex events whose title/prompt/message mention them are dropped.
    static let codexHelperPrompts = [
        "generate 0 to 3 hyperpersonalized suggestions",
        "you are an expert at upholding safety and compliance standards",
    ]

    /// - Parameter codexTitle: optional lookup of Codex session titles by session id
    ///   (from ~/.codex/session_index.jsonl); overrides prompt titles for Codex.
    public init(config: MonitorConfig = MonitorConfig(), codexTitle: ((String) -> String?)? = nil) {
        self.config = config
        self.codexTitle = codexTitle
    }

    /// Returns the accepted status, or nil when the event was dropped (unknown event,
    /// Codex helper session) or ignored by a transition rule.
    @discardableResult
    public func ingest(_ event: HookEvent) -> AgentStatus? {
        // Metadata is updated even when the event is dropped below.
        let metadata = updateMetadata(for: event)
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

    /// Convenience: `EventParser.parseRecord` + `ingest`.
    @discardableResult
    public func ingest(provider: String, line: JSONObject, now: Date = Date()) -> AgentStatus? {
        guard let event = EventParser.parseRecord(provider: provider, object: line, now: now) else { return nil }
        return ingest(event)
    }

    /// Restores rows (e.g. from latest.json) and seeds metadata (cwd/origin/title
    /// derived from display names where possible) so labels survive restarts.
    ///
    /// Restored rows replace current rows with the same key. Codex session rows get
    /// their display name refreshed from the session index (as Python does on load).
    public func load(_ restored: [AgentStatus]) {
        for var status in restored {
            if status.provider == "codex", !status.isSubagent,
               let sessionID = status.sessionID, let title = codexSessionTitle(sessionID) {
                status.displayName = DisplayNames.displayName(
                    project: DisplayNames.projectName(cwd: status.cwd), title: title,
                    short: PyText.prefix(sessionID, 8), fallback: status.displayName)
            }
            statuses[status.agentID] = status
            seedMetadata(from: status)
        }
    }

    /// Recovery: for each recovered row, replace the current one unless
    /// `recovered.updatedAt < current.updatedAt`, and only if different. Returns true
    /// if anything changed. Accepted rows also seed metadata, like `load`.
    ///
    /// The transition rules are not applied again: the scan applied them to events
    /// this engine never saw (a Notification after a missed turn is newer than a
    /// restored Done row, not Claude's idle_prompt).
    ///
    /// A recovered row is first relabeled with the title this engine already knows
    /// for its key (restored by `load` or seen live), because a log scan only sees
    /// its tail window: when the session's first prompt fell outside it, the scan
    /// labels the row with a later prompt or none. Without this, every restart
    /// would swap long sessions' labels (the log always repeats latest.json's last
    /// event, so the rows differ only by label).
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

    /// Drops rows (and their metadata/pending state) older than
    /// max(config.staleAfter, config.retention).
    public func prune(now: Date) {
        let cutoff = max(config.staleAfter, config.retention)
        statuses = statuses.filter { $0.value.age(now: now) <= cutoff }
        metadataByStatus = metadataByStatus.filter { now.timeIntervalSince($0.value.lastSeen) <= cutoff }
        metadataBySession = metadataBySession.filter { now.timeIntervalSince($0.value.lastSeen) <= cutoff }
        pending = pending.filter { statuses[$0.key] != nil }
    }

    public func snapshot(now: Date = Date(), sources: [SourceInfo] = []) -> MonitorSnapshot {
        SnapshotBuilder.build(statuses: Array(statuses.values), config: config, now: now, sources: sources)
    }

    /// Pending permission signatures per status key (for tests).
    var pendingPermissions: [String: Set<String>] {
        pending
    }

    // MARK: Metadata

    /// Python `metadata_for_record`: updates the session and status-key metadata
    /// with this event and returns the merged view (status-level values first).
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

    /// Python `title_from_event`: the Codex session-index title (which always wins),
    /// else the summarized prompt of a UserPromptSubmit.
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

    /// Fills metadata gaps from a restored/recovered row so the next live event
    /// keeps its label. Never overwrites metadata that live events already set.
    private func seedMetadata(from status: AgentStatus) {
        let seed = StatusMetadata(cwd: status.cwd, title: Self.titleFromDisplayName(status),
                                  origin: status.origin, lastSeen: status.updatedAt)
        metadataByStatus[status.agentID, default: StatusMetadata()].fill(from: seed)
        if let sessionID = status.sessionID, !sessionID.isEmpty {
            metadataBySession["\(status.provider):session:\(sessionID)", default: StatusMetadata()].fill(from: seed)
        }
    }

    /// Rebuilds `status.displayName` from the known title for its key, the way a
    /// live event would: a Codex session-index title first, then status-level
    /// metadata, then the session's. No known title leaves the row's own label alone.
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

    /// The `short` part of a row's label: `"agent {id8}"` for subagent keys, the
    /// session id's first 8 code points for session rows, nil otherwise.
    static func shortLabel(for status: AgentStatus) -> String? {
        let agentPrefix = "\(status.provider):agent:"
        if PyText.startsWith(status.agentID, agentPrefix) {
            let agentID = String(decoding: status.agentID.utf8.dropFirst(agentPrefix.utf8.count), as: UTF8.self)
            return "agent " + PyText.prefix(agentID, 8)
        }
        guard let sessionID = status.sessionID, !sessionID.isEmpty else { return nil }
        return PyText.prefix(sessionID, 8)
    }

    /// Recovers the title part of a display name built by `DisplayNames.displayName`
    /// (`"{project}: {title} ({short})"` or `"{title} ({short})"`). Returns nil for
    /// project-only names, fallbacks, truncated names and rows without a cwd (the
    /// project prefix could not be told apart from the title).
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

    /// Python `status_from_event`: nil when the event has no mode or belongs to a
    /// Codex helper session.
    private func makeStatus(for event: HookEvent, metadata: StatusMetadata) -> AgentStatus? {
        guard let mode = ModeClassifier.mode(for: event) else { return nil }
        if isCodexHelperEvent(event, metadata: metadata) { return nil }

        let label = DisplayNames.fallbackProviderLabel(event.provider)
        let displayName: String
        if let agentID = event.agentID, !agentID.isEmpty {
            let short = PyText.prefix(agentID, 8)
            displayName = self.displayName(for: event, metadata: metadata, short: "agent \(short)",
                                           fallback: "\(label) agent \(short)")
        } else if let sessionID = event.sessionID, !sessionID.isEmpty {
            let short = PyText.prefix(sessionID, 8)
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

    /// Python `should_ignore_record` (codex only). Because the title is per session,
    /// every later event of a helper session is dropped too.
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

    /// `"{tool_name}\0{command}"` when `raw.tool_input.command` is a non-empty string.
    static func permissionSignature(_ event: HookEvent) -> String? {
        guard let toolInput = event.raw["tool_input"]?.objectValue,
              let command = PyText.nonEmptyString(toolInput["command"]) else { return nil }
        let toolName = PyText.nonEmptyString(event.raw["tool_name"]) ?? event.toolName ?? ""
        return "\(toolName)\u{0}\(command)"
    }

    /// Python `track_pending_permissions`, plus two releases Python lacks: a
    /// PostToolUseFailure with the signature means the approved command ran and
    /// failed (a denial logs no PostToolUse*), and SubagentStop ends its subagent's
    /// prompts (the turn-ending events never carry the subagent's agent_id). A
    /// denied command (PermissionDenied) stays sticky until Stop or the next prompt.
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

    /// Claude sends no SubagentStop for a subagent killed with its session, which
    /// would leave its row active until the idle timeout. So a parent (no agent_id)
    /// SessionEnd marks every active subagent row of that session Completed, and a
    /// parent Stop does the same for the ones its `background_task_ids` (the hook's
    /// copy of the still-running tasks) leaves out; a Stop without the list changes
    /// nothing. Closed rows take the event's time and name and drop their prompts.
    private func completeFinishedSubagents(after event: HookEvent) {
        guard event.agentID?.isEmpty ?? true, let sessionID = event.sessionID, !sessionID.isEmpty else { return }
        let prefix = "\(event.provider):agent:"
        var running: Set<String> = []
        switch event.eventName {
        case "SessionEnd":
            break
        case "Stop":
            guard let ids = event.raw["background_task_ids"]?.arrayValue else { return }
            running = Set(ids.compactMap { $0.stringValue.map { prefix + $0 } })
        default:
            return
        }
        for (key, var row) in statuses where row.mode.isActive && row.sessionID == sessionID
            && PyText.startsWith(key, prefix) && !running.contains(key) {
            row.mode = .completed
            row.updatedAt = event.loggedAt
            row.eventName = event.eventName
            row.toolName = nil
            statuses[key] = row
            pending[key] = nil
        }
    }

    /// Python `should_ignore_status_transition`, plus two idle_prompt rules.
    /// `notificationType` is the event's lowercased, stripped `notification_type`.
    static func shouldIgnoreTransition(from previous: AgentStatus?, to current: AgentStatus, pending: Set<String>,
                                       notificationType: String? = nil) -> Bool {
        if current.eventName == "Notification" {
            // Claude's idle_prompt Notification (~60 s after Stop) must not turn Done into Ask,
            if previous?.mode == .completed { return true }
            // nor a session that never started work (it also follows SessionStart), nor
            // a key with no row: a log scan whose tail window begins after the Stop.
            if notificationType == "idle_prompt" && (previous == nil || previous?.mode == .idleReady) { return true }
        }
        guard let previous else { return false }
        // An approval prompt stays up until its command finishes or the turn ends.
        return previous.mode == .waitingForInput && previous.eventName == "PermissionRequest"
            && current.eventName != "PermissionRequest" && !pending.isEmpty
    }
}

/// A title candidate from one event. Codex session-index titles override an
/// existing title; prompt titles only fill an empty one (the first prompt sticks).
private struct EventTitle {
    var text: String
    var overrides: Bool
}

/// Per-session / per-key label metadata (Python `StatusMetadata`).
struct StatusMetadata: Equatable {
    var cwd: String?
    var title: String?
    var origin: String?
    /// Newest event time seen; used to prune.
    var lastSeen: Date = .distantPast

    /// Python `update_metadata`.
    fileprivate mutating func update(with event: HookEvent, title: EventTitle?) {
        if let cwd = event.cwd, !cwd.isEmpty { self.cwd = cwd }
        if let title, self.title == nil || title.overrides { self.title = title.text }
        if let origin = event.origin ?? EventParser.originLabel(event.raw) { self.origin = origin }
        lastSeen = max(lastSeen, event.loggedAt)
    }

    /// Sets only the fields that are still empty.
    mutating func fill(from seed: StatusMetadata) {
        cwd = cwd ?? seed.cwd
        title = title ?? seed.title
        origin = origin ?? seed.origin
        lastSeen = max(lastSeen, seed.lastSeen)
    }
}

/// Staleness, settling, demotion and aggregation (spec collector §6).
public enum SnapshotBuilder {
    /// 1. A Working row whose event is PostToolUse settles to Completed once older
    ///    than `postToolWorkingVisible` (updatedAt/eventName unchanged).
    /// 2. Stale: Completed older than `completedVisible`; Idle older than
    ///    `idleVisible`; anything else older than `staleAfter`, or Tool Running older
    ///    than `toolRunningTimeout` when that is > 0. (A negative visibility window
    ///    disables its special case.)
    /// 3. If any fresh row is active, fresh Completed/Idle rows move to stale.
    /// 4. Both lists sort by (priority asc, updatedAt desc, agentID asc).
    /// 5. Aggregate: the first fresh row, or Idle with no representative.
    public static func build(statuses: [AgentStatus], config: MonitorConfig, now: Date, sources: [SourceInfo]) -> MonitorSnapshot {
        var fresh: [AgentStatus] = []
        var stale: [AgentStatus] = []
        for original in statuses {
            var status = original
            if status.mode == .working, status.eventName == "PostToolUse", config.postToolWorkingVisible >= 0,
               status.age(now: now) > config.postToolWorkingVisible {
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

    static func isStale(_ status: AgentStatus, config: MonitorConfig, now: Date) -> Bool {
        let age = status.age(now: now)
        if status.mode == .completed && config.completedVisible >= 0 { return age > config.completedVisible }
        if status.mode == .idleReady && config.idleVisible >= 0 { return age > config.idleVisible }
        return age > config.staleAfter
            || (status.mode == .toolRunning && config.toolRunningTimeout > 0 && age > config.toolRunningTimeout)
    }

    /// (priority asc, updatedAt desc), then agentID so the order is deterministic.
    static func displayOrder(_ a: AgentStatus, _ b: AgentStatus) -> Bool {
        if a.mode.priority != b.mode.priority { return a.mode.priority < b.mode.priority }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.agentID < b.agentID
    }
}
