import Foundation

/// Event → mode rules (Python `mode_for_event` and helpers). Order matters; see
/// spec collector §4.
public enum ModeClassifier {
    /// 1. Interrupt → idleReady (before markers)
    /// 2. explicitMode(raw) → that mode (applies to every event)
    /// 3. PostToolUseFailure | PermissionDenied | StopFailure → blockedError
    /// 4. PermissionRequest → waitingForInput
    /// 5. Notification: completion → completed; needs input → waitingForInput; else working
    /// 6. PreToolUse → toolRunning
    /// 7. PostToolUse: failed tool response → blockedError, else working
    /// 8. UserPromptSubmit | PreCompact | PostCompact | SubagentStart → working
    /// 9. Stop | SubagentStop: asks question → waitingForInput, else completed
    /// 10. SessionEnd → completed
    /// 11. SessionStart → idleReady
    /// 12. else nil
    public static func mode(for event: HookEvent) -> AgentMode? {
        let raw = event.raw
        // An interrupted turn is inactive, but it has not completed its work.
        if event.eventName == "Interrupt" { return .idleReady }
        if let explicit = explicitMode(raw: raw) { return explicit }

        switch event.eventName {
        case "PostToolUseFailure", "PermissionDenied", "StopFailure":
            return .blockedError
        case "PermissionRequest":
            return .waitingForInput
        case "Notification":
            if notificationIsCompletion(raw: raw) { return .completed }
            if notificationNeedsInput(raw: raw) { return .waitingForInput }
            return .working
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

    /// `raw.sidepulse_status`, then `raw.sidepulse_mode` (strings, normalized via
    /// `normalizeMarkerValue`), then `markerMode(in: last_assistant_message || message)`.
    public static func explicitMode(raw: JSONObject) -> AgentMode? {
        for key in ["sidepulse_status", "sidepulse_mode"] {
            if let value = raw[key]?.stringValue, let mode = normalizeMarkerValue(value) { return mode }
        }
        guard let text = PyText.firstTruthy(raw["last_assistant_message"], raw["message"])?.stringValue else { return nil }
        return markerMode(in: text)
    }

    /// Whole-line marker syntaxes, tried in this order. Python compiles them with
    /// `(?im)`, where `^`/`$` only treat `\n` as a line break; ICU's
    /// `useUnixLineSeparators` gives the same anchors. `\s` is Python's Unicode
    /// whitespace, so a marker comment may span lines (as in Python).
    private static let markerPatterns: [TextRegex] = {
        let s = "[\(PyText.regexSpaceClass)]"
        let name = #"(?:sidepulse|agent[-_ ]monitor)"#
        let value = #"([a-z0-9_ -]+)"#
        return [
            "^\(s)*<!--\(s)*\(name)\(s)*:\(s)*\(value)\(s)*-->\(s)*$",
            "^\(s)*<!--\(s)*\(name)\(s)+(?:status|mode)\(s)*:\(s)*\(value)\(s)*-->\(s)*$",
            "^\(s)*\\[\(name)\(s)+(?:status|mode)\(s)*:\(s)*\(value)\\]\(s)*$",
        ].map { TextRegex($0, options: [.caseInsensitive, .anchorsMatchLines, .useUnixLineSeparators]) }
    }()

    /// Strips fenced ``` blocks, then tries the three whole-line marker patterns
    /// (case-insensitive, multiline) in pattern order, matches in document order;
    /// first value that maps to a mode wins.
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

    /// `re.sub('[^a-z0-9]+','_', v.strip().lower()).strip('_')` then the vocabulary map.
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

    private static let completionPhrases = [
        "turn complete", "turn completed", "task complete", "task completed",
        "completed successfully", "work complete", "work completed",
    ]

    private static let inputNeededPhrases = [
        "waiting for your input", "waiting for input", "needs your input", "needs input",
        "permission", "approval", "confirm",
    ]

    /// `"{type} {message}"` (each stripped + lowercased) contains a completion phrase,
    /// or type is `idle_prompt` with message done/complete/completed.
    public static func notificationIsCompletion(raw: JSONObject) -> Bool {
        let type = PyText.strip(PyText.str(raw["notification_type"])).lowercased()
        let message = PyText.strip(PyText.str(raw["message"])).lowercased()
        let text = PyText.strip("\(type) \(message)")
        if PyText.contains(text, anyOf: completionPhrases) { return true }
        return type == "idle_prompt" && ["done", "complete", "completed"].contains(message)
    }

    /// `"{type} {message}"` lowercased contains an input-needed phrase. These are
    /// plain substrings, so "confirmed" matches too (as in Python).
    public static func notificationNeedsInput(raw: JSONObject) -> Bool {
        let text = "\(PyText.str(raw["notification_type"])) \(PyText.str(raw["message"]))".lowercased()
        return PyText.contains(text, anyOf: inputNeededPhrases)
    }

    // MARK: Tool failures

    /// Object: interrupted == true, success == false, or exit_code not null/0
    /// (string "0" counts as failed). String: lowercased contains "exit code: 1" or
    /// "traceback". Also honours our hook record's precomputed
    /// `raw.tool_response_failed` bool when the caller passes the whole raw object
    /// through `toolFailed(raw:)`.
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

    /// `raw.tool_response_failed` (bool) if present, else
    /// `toolResponseLooksFailed(raw.tool_response)`.
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

    /// Python's trailing `\b` is spelled as "not followed by a Python word character"
    /// (`str.isalnum()` or `_`): ICU's `\w` also counts combining marks, so ICU's `\b`
    /// finds no boundary in "want me to\u{301}" where Python does. The character
    /// before the boundary is always an ASCII letter, so the lookahead is exact.
    private static let offerPattern = TextRegex(
        #"(?:^|[.!?][\#(PyText.regexSpaceClass)]+)(?:want me to|need me to|should i|should we|do you want me to)(?![\p{L}\p{N}_])"#)

    private static let requestPrefixes = [
        "please confirm", "please choose", "choose ", "need me to ", "want me to ",
        "should i ", "should we ", "do you want me to ",
    ]

    private static let questionPrefixes = [
        "which ", "what ", "where ", "when ", "who ", "why ", "how ", "can you ", "could you ",
    ] + requestPrefixes

    /// Question heuristic for Stop/SubagentStop (spec collector §4d).
    ///
    /// Code is removed first (fenced blocks, then inline spans). Of the non-empty
    /// lines (Python `splitlines`), the last 8 are checked from the end, skipping
    /// Claude status lines; true as soon as one line asks a concrete question.
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

    /// One line: not ending with `:`, not a casual closer, and either an offer
    /// ("Want me to push?") at the start or after a sentence end, or a line that
    /// starts with a question/request prefix (question words need a trailing `?`).
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
