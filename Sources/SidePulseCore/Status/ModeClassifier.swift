import Foundation

public enum ModeClassifier {
    public static func mode(for event: HookEvent) -> AgentMode? {
        let raw = event.raw
        // An interrupted turn is inactive, but it has not completed its work.
        if event.eventName == "Interrupt" { return .idleReady }

        switch event.eventName {
        case "PostToolUseFailure", "StopFailure":
            return .blockedError
        case "PermissionRequest":
            return .waitingForInput
        case "Notification":
            return notificationMode(raw: raw)
        case "PreToolUse":
            return .toolRunning
        case "PostToolUse":
            return toolFailed(raw: raw) ? .blockedError : .working
        case "UserPromptSubmit", "PreCompact", "PostCompact", "SubagentStart":
            return .working
        case "Stop", "SubagentStop", "SessionEnd":
            return .completed
        case "SessionStart":
            return .idleReady
        default:
            return nil
        }
    }

    // MARK: Notifications

    /// Only the type counts, never the message text. `idle_prompt` means the agent sits at its
    /// input prompt; other types, such as `auth_success`, are informational and ignored.
    private static let inputNotificationTypes: Set<String> = [
        "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input", "idle_prompt",
    ]

    public static func notificationMode(raw: JSONObject) -> AgentMode? {
        let type = PyText.strip(raw["notification_type"]?.stringValue ?? "").lowercased()
        return inputNotificationTypes.contains(type) ? .waitingForInput : nil
    }

    // MARK: Tool failures

    /// A string `exit_code`, even "0", counts as failed, as in Python.
    public static func toolResponseLooksFailed(_ value: JSONValue?) -> Bool {
        switch value {
        case .object(let response)?:
            if response["interrupted"] == .bool(true) { return true }
            if response["success"] == .bool(false) { return true }
            switch response["exit_code"] {
            case nil, .null?, .bool(false)?:
                // Python: `exit_code not in (None, 0)`, and False == 0.
                return false
            case .number(let literal)?:
                return Double(literal).map { $0 != 0 } ?? true
            default:
                return true
            }
        case .string(let text)?:
            let lowered = text.lowercased()
            return PyText.contains(lowered, "exit code: 1") || PyText.contains(lowered, "traceback")
        default:
            return false
        }
    }

    public static func toolFailed(raw: JSONObject) -> Bool {
        if let precomputed = raw["tool_response_failed"]?.boolValue { return precomputed }
        return toolResponseLooksFailed(raw["tool_response"])
    }
}
