import Foundation

/// Turns a provider log line / socket `line` object into a `HookEvent`
/// (Python `providers.parse_log_line`). Accepts both our trimmed records and
/// Python-era shapes (the Codex `{"logged_at","event":{...}}` wrapper, camelCase keys).
///
/// The provider string is passed through unchanged. Python's Grok sniffing
/// (a `claude` line that looks like Grok became provider `grok`) is not ported.
public enum EventParser {
    /// Ordered union of the Codex, Claude, Grok and Junie event lists.
    public static let knownEvents: [String] = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
        "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "Stop", "Interrupt",
        "PostToolUseFailure", "Notification", "SessionEnd", "PermissionDenied", "StopFailure",
    ]

    private static let knownEventSet = Set(knownEvents)

    /// snake_case form of every known event, plus the `subagent_end` alias.
    private static let snakeAliases: [String: String] = {
        var aliases: [String: String] = [:]
        for event in knownEvents { aliases[snakeCase(event)] = event }
        aliases["subagent_end"] = "SubagentStop"
        return aliases
    }()

    /// camelCase keys copied to their snake_case names when the snake key is absent
    /// (Python `normalize_event_payload`).
    static let camelAliases: [(camel: String, snake: String)] = [
        ("sessionId", "session_id"), ("turnId", "turn_id"), ("agentId", "agent_id"),
        ("workspaceRoot", "cwd"), ("toolName", "tool_name"), ("toolInput", "tool_input"),
        ("toolResponse", "tool_response"), ("lastAssistantMessage", "last_assistant_message"),
        ("notificationType", "notification_type"), ("agentOrigin", "agent_origin"),
        ("agentOriginKind", "agent_origin_kind"), ("sidepulseOrigin", "sidepulse_origin"),
    ]

    /// Keys that may carry the event name, in lookup order.
    static let eventNameKeys = ["hook_event_name", "hookEventName", "event_name", "eventName"]

    /// Exact match returns as-is. Otherwise snake-normalize (non-alnum runs → `_`,
    /// split camelCase `([a-z0-9])([A-Z])` → `\1_\2`, trim `_`, lowercase) and compare
    /// with the snake form of each known event. Alias: `subagent_end` → SubagentStop.
    /// Unknown → nil.
    public static func canonicalEventName(_ name: String) -> String? {
        let text = PyText.strip(name)
        guard !text.isEmpty else { return nil }
        if knownEventSet.contains(text) { return text }
        return snakeAliases[snakeCase(text)]
    }

    /// Python: `re.sub('[^a-zA-Z0-9]+','_')`, `re.sub('([a-z0-9])([A-Z])', r'\1_\2')`,
    /// `strip('_')`, `lower()`. Only ASCII letters and digits survive.
    static func snakeCase(_ text: String) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count + 4)
        var previousLowerOrDigit = false
        var previousWasSeparator = false
        for byte in text.utf8 {
            let isUpper = byte >= 0x41 && byte <= 0x5A
            let isLower = byte >= 0x61 && byte <= 0x7A
            let isDigit = byte >= 0x30 && byte <= 0x39
            if isUpper || isLower || isDigit {
                if isUpper && previousLowerOrDigit { out.append(0x5F) }
                out.append(isUpper ? byte + 0x20 : byte)
                previousLowerOrDigit = !isUpper
                previousWasSeparator = false
            } else {
                // Multi-byte UTF-8 sequences are non-alphanumeric too; the whole run
                // collapses into one underscore.
                if !previousWasSeparator { out.append(0x5F) }
                previousWasSeparator = true
                previousLowerOrDigit = false
            }
        }
        while out.first == 0x5F { out.removeFirst() }
        while out.last == 0x5F { out.removeLast() }
        return String(decoding: out, as: UTF8.self)
    }

    /// Parses one JSONL line. Empty / invalid JSON / non-object → nil.
    public static func parseLine(provider: String, line: String) -> HookEvent? {
        parseLine(provider: provider, line: line, now: Date())
    }

    /// `parseLine` with an explicit fallback time for records without a usable
    /// `logged_at` (lets a scan use one consistent "now").
    static func parseLine(provider: String, line: String, now: Date) -> HookEvent? {
        let text = PyText.strip(line)
        guard !text.isEmpty,
              let value = try? JSONValue.parse(text),
              let object = value.objectValue else { return nil }
        return parseRecord(provider: provider, object: object, now: now)
    }

    /// Steps (see spec collector §3):
    /// 1. If `object.event` is an object (Codex/Python wrapper): raw = event,
    ///    logged_at = object.logged_at || raw.logged_at. Else raw = object,
    ///    logged_at = raw.logged_at || raw.timestamp.
    /// 2. Event name = first of hook_event_name, hookEventName, event_name, eventName →
    ///    canonicalEventName; nil → drop.
    /// 3. Normalize: set hook_event_name/logged_at if absent; copy camelCase keys to
    ///    snake_case when the snake key is absent (sessionId, turnId, agentId,
    ///    workspaceRoot→cwd, toolName, toolInput, toolResponse, lastAssistantMessage,
    ///    notificationType, agentOrigin, agentOriginKind, sidepulseOrigin).
    /// 4. Fields: first non-empty (non-strings stringified with `pythonString`):
    ///    session_id, turn_id, agent_id, cwd, tool_name; message ← message |
    ///    last_assistant_message | error_details; origin ← `originLabel(raw)`.
    ///    The camelCase spellings are consulted as a fallback for each field, as in
    ///    Python.
    /// `now` is used when logged_at is missing/unparseable.
    ///
    /// Python only unwraps `event` for the codex provider. Here any provider's
    /// wrapper is unwrapped, but only when the outer object carries no event name of
    /// its own, so a flat record that happens to have an `event` object stays flat.
    public static func parseRecord(provider: String, object: JSONObject, now: Date = Date()) -> HookEvent? {
        let raw: JSONObject
        let loggedAtValue: JSONValue?
        if let wrapped = object["event"]?.objectValue, !eventNameKeys.contains(where: { object[$0] != nil }) {
            raw = wrapped
            loggedAtValue = PyText.firstTruthy(object["logged_at"], wrapped["logged_at"])
        } else {
            raw = object
            loggedAtValue = PyText.firstTruthy(raw["logged_at"], raw["timestamp"])
        }

        let nameValue = PyText.firstTruthy(raw["hook_event_name"], raw["hookEventName"], raw["event_name"], raw["eventName"])
        guard let eventName = nameValue?.stringValue.flatMap(canonicalEventName) else { return nil }

        var normalized = raw
        if normalized["hook_event_name"] == nil { normalized["hook_event_name"] = .string(eventName) }
        if let loggedAtValue, !loggedAtValue.isNull, normalized["logged_at"] == nil {
            normalized["logged_at"] = loggedAtValue
        }
        for (camel, snake) in camelAliases where normalized[snake] == nil {
            if let value = normalized[camel] { normalized[snake] = value }
        }

        return HookEvent(
            provider: provider,
            loggedAt: TimeFormat.parseOrNow(loggedAtValue, now: now),
            eventName: eventName,
            raw: normalized,
            sessionID: firstString(normalized, "session_id", "sessionId"),
            turnID: firstString(normalized, "turn_id", "turnId"),
            agentID: firstString(normalized, "agent_id", "agentId"),
            cwd: firstString(normalized, "cwd", "workspaceRoot"),
            toolName: firstString(normalized, "tool_name", "toolName"),
            message: firstString(normalized, "message", "last_assistant_message", "lastAssistantMessage", "error_details"),
            origin: originLabel(normalized)
        )
    }

    /// First match: clean label (collapsed whitespace) of agent_origin, agentOrigin,
    /// agent_origin_label, origin_label; then sidepulse_origin (string, or object's
    /// label/name/origin); else nil.
    public static func originLabel(_ raw: JSONObject) -> String? {
        for key in ["agent_origin", "agentOrigin", "agent_origin_label", "origin_label"] {
            if let label = cleanLabel(raw[key]) { return label }
        }
        switch PyText.firstTruthy(raw["sidepulse_origin"], raw["sidepulseOrigin"]) {
        case .object(let structured)?:
            for key in ["label", "name", "origin"] {
                if let label = cleanLabel(structured[key]) { return label }
            }
            return nil
        case let value?:
            return cleanLabel(value)
        case nil:
            return nil
        }
    }

    /// Python `clean_label`: strings only, whitespace collapsed, empty → nil.
    static func cleanLabel(_ value: JSONValue?) -> String? {
        guard let s = value?.stringValue else { return nil }
        let label = PyText.collapseWhitespace(s)
        return label.isEmpty ? nil : label
    }

    /// Python `_first_string`: the first key whose value is present, non-null and
    /// non-empty once stringified.
    static func firstString(_ raw: JSONObject, _ keys: String...) -> String? {
        for key in keys {
            guard let value = raw[key], !value.isNull else { continue }
            let text = value.pythonString
            if !text.isEmpty { return text }
        }
        return nil
    }
}
