import Foundation

public enum ModeClassifier {
    public static func mode(for event: HookEvent) -> AgentMode? {
        let raw = event.raw
        // An interrupted turn is inactive, but it has not completed its work.
        if event.eventName == "Interrupt" { return .idleReady }
        if let explicit = explicitMode(raw: raw) { return explicit }

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
        case "Stop", "SubagentStop":
            return assistantMessageAsksQuestion(raw["last_assistant_message"]?.stringValue) ? .waitingForInput : .completed
        case "SessionEnd":
            return .completed
        case "SessionStart":
            return .idleReady
        default:
            return nil
        }
    }

    // MARK: Explicit markers

    public static func explicitMode(raw: JSONObject) -> AgentMode? {
        for key in ["sidepulse_status", "sidepulse_mode"] {
            if let value = raw[key]?.stringValue, let mode = normalizeMarkerValue(value) { return mode }
        }
        // OpenCode puts a whole permission command in `message`, and a marker line in it must not hide the Ask.
        guard let text = raw["last_assistant_message"]?.stringValue else { return nil }
        return markerMode(in: text)
    }

    /// `useUnixLineSeparators` makes `^`/`$` treat only `\n` as a line break, like
    /// Python's `(?im)`. Possessive quantifiers, a value that starts and ends with a
    /// non-space, and no `\n` outside the marker keep a long unclosed marker linear.
    private static let markerPatterns: [TextRegex] = {
        let s = "[\(PyText.regexSpaceClass)]"
        let h = "[\(PyText.regexLineSpaceClass)]"
        let name = #"(?:sidepulse|agent[-_ ]monitor)"#
        let value = #"([a-z0-9_-](?:[a-z0-9_ -]*[a-z0-9_-])?)"#
        return [
            "^\(h)*+<!--\(s)*\(name)\(s)*+:\(s)*+\(value)\(s)*+-->\(h)*+$",
            "^\(h)*+<!--\(s)*\(name)\(s)+(?:status|mode)\(s)*+:\(s)*+\(value)\(s)*+-->\(h)*+$",
            "^\(h)*+\\[\(name)\(s)+(?:status|mode)\(s)*+:\(s)*+\(value) *+\\]\(h)*+$",
        ].map { TextRegex($0, options: [.caseInsensitive, .anchorsMatchLines, .useUnixLineSeparators]) }
    }()

    public static func markerMode(in text: String) -> AgentMode? {
        let stripped = stripFencedCodeBlocks(text)
        // Cheap pre-check: every syntax contains one of these words.
        let lowered = stripped.lowercased()
        guard PyText.contains(lowered, "sidepulse") || PyText.contains(lowered, "monitor") else { return nil }
        for pattern in markerPatterns {
            for value in pattern.allGroups(1, in: stripped) {
                if let mode = normalizeMarkerValue(value) { return mode }
            }
        }
        return nil
    }

    private static let markerVocabulary: [String: AgentMode] = [
        "ask": .waitingForInput, "question": .waitingForInput, "waiting": .waitingForInput,
        "waiting_for_input": .waitingForInput, "input": .waitingForInput,
        "blocked": .blockedError, "error": .blockedError, "blocked_error": .blockedError,
        "working": .working,
        "tool_running": .toolRunning,
        "progress": .longTaskProgress, "long_task_progress": .longTaskProgress,
        "done": .completed, "complete": .completed, "completed": .completed,
        "idle": .idleReady, "ready": .idleReady, "idle_ready": .idleReady,
    ]

    public static func normalizeMarkerValue(_ value: String) -> AgentMode? {
        var out: [UInt8] = []
        var previousWasSeparator = false
        for byte in PyText.strip(value).lowercased().utf8 {
            if (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) {
                out.append(byte)
                previousWasSeparator = false
            } else {
                if !previousWasSeparator { out.append(0x5F) }
                previousWasSeparator = true
            }
        }
        while out.first == 0x5F { out.removeFirst() }
        while out.last == 0x5F { out.removeLast() }
        return markerVocabulary[String(decoding: out, as: UTF8.self)]
    }

    // MARK: Notifications

    private static let inputNotificationTypes: Set<String> = [
        "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input",
    ]

    /// Other types, such as `auth_success` or `agent_completed`, are informational and
    /// would otherwise become a Working row that never settles.
    public static func notificationMode(raw: JSONObject) -> AgentMode? {
        let type = PyText.strip(raw["notification_type"]?.stringValue ?? "").lowercased()
        if inputNotificationTypes.contains(type) { return .waitingForInput }
        guard type.isEmpty || type == "idle_prompt" else { return nil }
        if notificationIsCompletion(raw: raw) { return .completed }
        if notificationNeedsInput(raw: raw) { return .waitingForInput }
        return .working
    }

    private static let completionPhrases = [
        "turn complete", "turn completed", "task complete", "task completed",
        "completed successfully", "work complete", "work completed",
    ]

    private static let inputNeededPhrases = [
        "waiting for your input", "waiting for input", "needs your input", "needs input",
        "permission", "approval", "confirm",
    ]

    public static func notificationIsCompletion(raw: JSONObject) -> Bool {
        let type = PyText.strip(PyText.str(raw["notification_type"])).lowercased()
        let message = PyText.strip(PyText.str(raw["message"])).lowercased()
        let text = PyText.strip("\(type) \(message)")
        if PyText.contains(text, anyOf: completionPhrases) { return true }
        return type == "idle_prompt" && ["done", "complete", "completed"].contains(message)
    }

    /// The phrases are plain substrings, so "confirmed" matches too, as in Python.
    public static func notificationNeedsInput(raw: JSONObject) -> Bool {
        let text = "\(PyText.str(raw["notification_type"])) \(PyText.str(raw["message"]))".lowercased()
        return PyText.contains(text, anyOf: inputNeededPhrases)
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

    // MARK: Question heuristic

    private static let statusLinePrefixes = ["* cogitated ", "* recap:", "\u{203B} recap:", "recap:"]

    private static let casualClosingPrefixes = [
        "anything else", "any other", "all good", "need anything else", "want anything else",
        "anything you want", "anything you'd like", "anything else you want", "anything else you'd like",
    ]

    /// Python's trailing `\b` is spelled as a lookahead because ICU's `\w` also counts
    /// combining marks, so ICU's `\b` finds no boundary in "want me to\u{301}".
    private static let offerPattern = TextRegex(
        #"(?:^|[.!?][\#(PyText.regexSpaceClass)]+)(?:want me to|need me to|should i|should we|do you want me to)(?![\p{L}\p{N}_])"#)

    private static let requestPrefixes = [
        "please confirm", "please choose", "choose ", "need me to ", "want me to ",
        "should i ", "should we ", "do you want me to ",
    ]

    private static let questionPrefixes = [
        "which ", "what ", "where ", "when ", "who ", "why ", "how ", "can you ", "could you ",
    ] + requestPrefixes

    public static func assistantMessageAsksQuestion(_ text: String?) -> Bool {
        guard let text else { return false }
        let lines = PyText.splitLines(stripInlineCode(stripFencedCodeBlocks(text)))
            .map(PyText.strip)
            .filter { !$0.isEmpty }
        for line in lines.suffix(8).reversed() {
            if PyText.startsWith(line.lowercased(), anyOf: statusLinePrefixes) { continue }
            if lineAsksQuestion(line) { return true }
        }
        return false
    }

    static func lineAsksQuestion(_ line: String) -> Bool {
        let text = PyText.strip(line)
        guard !text.isEmpty else { return false }
        let lowered = text.lowercased()
        if PyText.endsWith(text, ":") { return false }
        if PyText.startsWith(lowered, anyOf: casualClosingPrefixes) { return false }
        if offerPattern.matches(lowered) { return true }
        if PyText.endsWith(text, "?") { return PyText.startsWith(lowered, anyOf: questionPrefixes) }
        return PyText.startsWith(lowered, anyOf: requestPrefixes)
    }
}
