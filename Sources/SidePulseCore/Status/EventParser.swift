import Foundation

/// Reads the records `HookRuntime.makeRecord` writes.
public enum EventParser {
    public static let knownEvents: [String] = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
        "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "Stop", "Interrupt",
        "PostToolUseFailure", "Notification", "SessionEnd", "PermissionDenied", "StopFailure",
    ]

    private static let knownEventsByLowercase = Dictionary(uniqueKeysWithValues: knownEvents.map { ($0.lowercased(), $0) })

    public static func canonicalEventName(_ name: String) -> String? {
        knownEventsByLowercase[name.lowercased()]
    }

    public static func parseLine(provider: String, line: String) -> HookEvent? {
        parseLine(provider: provider, line: line, now: Date())
    }

    /// Lets a scan give every record without a usable `logged_at` the same "now".
    static func parseLine(provider: String, line: String, now: Date) -> HookEvent? {
        guard let object = (try? JSONValue.parse(line))?.objectValue else { return nil }
        return parseRecord(provider: provider, object: object, now: now)
    }

    public static func parseRecord(provider: String, object raw: JSONObject, now: Date = Date()) -> HookEvent? {
        guard let eventName = raw["hook_event_name"]?.stringValue.flatMap(canonicalEventName) else { return nil }
        return HookEvent(
            provider: provider,
            loggedAt: TimeFormat.parseOrNow(raw["logged_at"], now: now),
            eventName: eventName,
            raw: raw,
            sessionID: text(raw["session_id"]),
            agentID: text(raw["agent_id"]),
            cwd: text(raw["cwd"]),
            toolName: text(raw["tool_name"]),
            message: text(raw["message"]) ?? text(raw["last_assistant_message"]) ?? text(raw["error_details"]),
            origin: OriginDetector.cleanLabel(raw["agent_origin"]?.stringValue)
        )
    }

    /// `makeRecord` keeps numeric ids as numbers.
    static func text(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let s)? where !s.isEmpty: return s
        case .number(let n)?: return n
        default: return nil
        }
    }
}
