import Foundation

/// Raw values are the wire/JSON values shared with Python.
public enum AgentMode: String, CaseIterable, Sendable, Codable {
    case blockedError = "blocked_error"
    case waitingForInput = "waiting_for_input"
    case toolRunning = "tool_running"
    case longTaskProgress = "long_task_progress"
    case working = "working"
    case completed = "completed"
    case idleReady = "idle_ready"
    case unknown = "unknown"

    /// Lower wins when aggregating.
    public var priority: Int {
        switch self {
        case .blockedError: return 1
        case .waitingForInput: return 2
        case .toolRunning: return 3
        case .longTaskProgress: return 4
        case .working: return 5
        case .completed: return 6
        case .idleReady: return 7
        case .unknown: return 99
        }
    }

    public var label: String {
        switch self {
        case .blockedError: return "Blocked / Error"
        case .waitingForInput: return "Waiting for Input"
        case .toolRunning: return "Tool Running"
        case .longTaskProgress: return "Long Task Progress"
        case .working: return "Working"
        case .completed: return "Completed"
        case .idleReady: return "Idle / Ready"
        case .unknown: return "Unknown"
        }
    }

    /// Unknown counts as active, matching Python `status_counts_active`.
    public var isActive: Bool { self != .completed && self != .idleReady }

    /// The three working modes always share one animation selection.
    public static let workingGroup: [AgentMode] = [.working, .toolRunning, .longTaskProgress]

    public var displayState: DisplayState {
        switch self {
        case .waitingForInput, .blockedError: return .ask
        case .working, .toolRunning, .longTaskProgress: return .working
        case .completed: return .done
        case .idleReady, .unknown: return .idle
        }
    }
}

public enum DisplayState: String, Sendable, CaseIterable {
    case idle, working, done, ask

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .done: return "Done"
        case .ask: return "Ask"
        }
    }

    public var symbolName: String {
        switch self {
        case .ask: return "questionmark.circle"
        case .working: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle"
        case .idle: return "circle"
        }
    }
}

public struct HookEvent: Sendable, Equatable {
    public var provider: String
    public var loggedAt: Date
    public var eventName: String
    /// Not the original payload: snake_case aliases, `hook_event_name` and
    /// `logged_at` are filled in.
    public var raw: JSONObject
    public var sessionID: String?
    public var turnID: String?
    public var agentID: String?
    public var cwd: String?
    public var toolName: String?
    public var message: String?
    public var origin: String?

    public init(provider: String, loggedAt: Date, eventName: String, raw: JSONObject,
                sessionID: String? = nil, turnID: String? = nil, agentID: String? = nil,
                cwd: String? = nil, toolName: String? = nil, message: String? = nil, origin: String? = nil) {
        self.provider = provider; self.loggedAt = loggedAt; self.eventName = eventName; self.raw = raw
        self.sessionID = sessionID; self.turnID = turnID; self.agentID = agentID; self.cwd = cwd
        self.toolName = toolName; self.message = message; self.origin = origin
    }

    public var statusKey: String {
        if let a = agentID, !a.isEmpty { return "\(provider):agent:\(a)" }
        if let s = sessionID, !s.isEmpty { return "\(provider):session:\(s)" }
        return "\(provider):unknown"
    }
}

public struct AgentStatus: Sendable, Equatable {
    public var provider: String
    /// The status key (see `HookEvent.statusKey`).
    public var agentID: String
    public var displayName: String
    public var mode: AgentMode
    public var updatedAt: Date
    public var eventName: String
    public var sessionID: String?
    public var cwd: String?
    public var toolName: String?
    public var message: String?
    public var origin: String?
    public var stale: Bool

    public init(provider: String, agentID: String, displayName: String, mode: AgentMode, updatedAt: Date,
                eventName: String, sessionID: String? = nil, cwd: String? = nil, toolName: String? = nil,
                message: String? = nil, origin: String? = nil, stale: Bool = false) {
        self.provider = provider; self.agentID = agentID; self.displayName = displayName; self.mode = mode
        self.updatedAt = updatedAt; self.eventName = eventName; self.sessionID = sessionID; self.cwd = cwd
        self.toolName = toolName; self.message = message; self.origin = origin; self.stale = stale
    }

    public func age(now: Date) -> TimeInterval { max(0, now.timeIntervalSince(updatedAt)) }

    public var isSubagent: Bool { PyText.startsWith(agentID, "\(provider):agent:") }

    /// Keys are set in Python's key order, which the ordered `JSONObject` preserves.
    public func toJSON(now: Date) -> JSONValue {
        var o = JSONObject()
        o["provider"] = .string(provider)
        o["agent_id"] = .string(agentID)
        o["display_name"] = .string(displayName)
        o["mode"] = .string(mode.rawValue)
        o["mode_label"] = .string(mode.label)
        o["priority"] = JSONValue(mode.priority)
        o["updated_at"] = .string(TimeFormat.pythonISO(updatedAt))
        o["age_seconds"] = JSONValue((age(now: now) * 1000).rounded() / 1000)
        o["event_name"] = .string(eventName)
        o["session_id"] = JSONValue(sessionID)
        o["cwd"] = JSONValue(cwd)
        o["tool_name"] = JSONValue(toolName)
        o["message"] = JSONValue(message)
        o["origin"] = JSONValue(origin)
        o["stale"] = .bool(stale)
        return .object(o)
    }

    /// Unlike Python, an unparseable `updated_at` rejects the entry instead of
    /// becoming "now", which would make a corrupt row look fresh.
    public static func fromJSON(_ value: JSONValue) -> AgentStatus? {
        guard let o = value.objectValue,
              let provider = o["provider"]?.stringValue,
              let agentID = o["agent_id"]?.stringValue,
              let displayName = o["display_name"]?.stringValue,
              let mode = o["mode"]?.stringValue.flatMap(AgentMode.init(rawValue:)),
              let updatedAt = o["updated_at"]?.stringValue.flatMap(TimeFormat.parse),
              let eventName = o["event_name"]?.stringValue
        else { return nil }
        return AgentStatus(provider: provider, agentID: agentID, displayName: displayName, mode: mode,
                           updatedAt: updatedAt, eventName: eventName,
                           sessionID: PyText.nonEmptyString(o["session_id"]),
                           cwd: PyText.nonEmptyString(o["cwd"]),
                           toolName: PyText.nonEmptyString(o["tool_name"]),
                           message: PyText.nonEmptyString(o["message"]),
                           origin: PyText.nonEmptyString(o["origin"]),
                           stale: PyText.truthy(o["stale"]))
    }
}

public struct AggregateStatus: Sendable, Equatable {
    public var mode: AgentMode
    public var activeCount: Int
    public var staleCount: Int
    public var representative: AgentStatus?

    public init(mode: AgentMode, activeCount: Int, staleCount: Int, representative: AgentStatus?) {
        self.mode = mode; self.activeCount = activeCount; self.staleCount = staleCount; self.representative = representative
    }

    public func toJSON(now: Date) -> JSONValue {
        var o = JSONObject()
        o["mode"] = .string(mode.rawValue)
        o["mode_label"] = .string(mode.label)
        o["active_count"] = JSONValue(activeCount)
        o["stale_count"] = JSONValue(staleCount)
        o["representative"] = representative?.toJSON(now: now) ?? .null
        return .object(o)
    }

    public static func fromJSON(_ value: JSONValue) -> AggregateStatus? {
        guard let o = value.objectValue,
              let mode = o["mode"]?.stringValue.flatMap(AgentMode.init(rawValue:)) else { return nil }
        return AggregateStatus(mode: mode,
                               activeCount: o["active_count"]?.intValue ?? 0,
                               staleCount: o["stale_count"]?.intValue ?? 0,
                               representative: o["representative"].flatMap(AgentStatus.fromJSON))
    }
}

public struct SourceInfo: Sendable, Equatable {
    public var provider: String
    public var path: String
    public init(provider: String, path: String) { self.provider = provider; self.path = path }
}

public struct MonitorSnapshot: Sendable, Equatable {
    public var collectedAt: Date
    public var sources: [SourceInfo]
    public var aggregate: AggregateStatus
    public var statuses: [AgentStatus]
    public var staleStatuses: [AgentStatus]

    public init(collectedAt: Date, sources: [SourceInfo], aggregate: AggregateStatus,
                statuses: [AgentStatus], staleStatuses: [AgentStatus]) {
        self.collectedAt = collectedAt; self.sources = sources; self.aggregate = aggregate
        self.statuses = statuses; self.staleStatuses = staleStatuses
    }

    public static func empty(now: Date = Date()) -> MonitorSnapshot {
        MonitorSnapshot(collectedAt: now, sources: [],
                        aggregate: AggregateStatus(mode: .idleReady, activeCount: 0, staleCount: 0, representative: nil),
                        statuses: [], staleStatuses: [])
    }

    public func toJSON() -> JSONValue {
        var o = JSONObject()
        o["collected_at"] = .string(TimeFormat.pythonISO(collectedAt))
        o["sources"] = .array(sources.map { .object(["provider": .string($0.provider), "path": .string($0.path)]) })
        o["aggregate"] = aggregate.toJSON(now: collectedAt)
        o["statuses"] = .array(statuses.map { $0.toJSON(now: collectedAt) })
        o["stale_statuses"] = .array(staleStatuses.map { $0.toJSON(now: collectedAt) })
        return .object(o)
    }

    public static func fromJSON(_ value: JSONValue) -> MonitorSnapshot? {
        guard let o = value.objectValue,
              let collectedAt = o["collected_at"]?.stringValue.flatMap(TimeFormat.parse),
              let aggregate = o["aggregate"].flatMap(AggregateStatus.fromJSON) else { return nil }
        let sources: [SourceInfo] = (o["sources"]?.arrayValue ?? []).compactMap { item in
            guard let provider = item["provider"]?.stringValue, let path = item["path"]?.stringValue else { return nil }
            return SourceInfo(provider: provider, path: path)
        }
        return MonitorSnapshot(collectedAt: collectedAt, sources: sources, aggregate: aggregate,
                               statuses: (o["statuses"]?.arrayValue ?? []).compactMap(AgentStatus.fromJSON),
                               staleStatuses: (o["stale_statuses"]?.arrayValue ?? []).compactMap(AgentStatus.fromJSON))
    }
}
