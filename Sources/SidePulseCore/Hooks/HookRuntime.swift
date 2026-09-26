import Darwin
import Foundation

/// `sidepulse hook-log --provider <claude|codex>`: runs inside every agent hook.
///
/// Contract: ALWAYS returns 0, NEVER writes to stdout (Claude injects hook stdout
/// into the model context), never blocks for long, never throws. Bad/missing
/// arguments → return 0 silently.
///
/// Steps: read stdin → `makeRecord` → append one compact JSON line to
/// `paths.logFile(for:)` (rotating at `SidePulseConstants.logRotateBytes`) → unless
/// `SIDEPULSE_DISABLE_EVENT_SOCKET` is 1/true/yes, send
/// `{"provider":P,"line":RECORD}` to `paths.socketPath` with a 0.2 s timeout. Each
/// step is independent: a dead socket never loses the log line.
public enum HookRuntime {
    public static func run(arguments: [String], stdin: Data, environment: [String: String],
                           paths: SidePulsePaths, now: Date = Date()) -> Int32 {
        guard let provider = providerArgument(arguments) else { return 0 }
        let record = makeRecord(provider: provider, payload: stdin, now: now) {
            OriginDetector.detect(provider: provider, environment: environment)
        }
        let line = JSONValue.object(record).serialized()

        // Step 1: the durable record. Failure (read-only dir, full disk) is ignored.
        try? HookLogStore.append(line: line, to: paths.logFile(for: provider.rawValue))

        // Step 2: live delivery. Built by concatenation so the record is serialized once.
        if !eventSocketDisabled(environment) {
            let message = "{\"provider\":" + JSONValue.string(provider.rawValue).serialized() + ",\"line\":" + line + "}"
            EventSocketClient.send(Data(message.utf8), socketPath: paths.socketPath,
                                   timeout: SidePulseConstants.hookSendTimeout)
        }
        return 0
    }

    /// The `hook-log` entry point of the `sidepulse` executable: reads stdin
    /// (`readStandardInput`, bounded by `standardInputTimeout` and
    /// `standardInputMaxBytes`) and uses the process environment and default paths.
    /// Prints nothing and returns 0, like `run`.
    public static func runFromProcess(arguments: [String]) -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        return run(arguments: arguments, stdin: readStandardInput(), environment: environment,
                   paths: SidePulsePaths(environment: environment))
    }

    /// Longest time `readStandardInput` waits for the agent to finish writing and
    /// close stdin. Agents write the payload at once and close, so this only matters
    /// for a writer that never closes (or never stops), which must not hang the hook.
    public static let standardInputTimeout: TimeInterval = 3

    /// Payload bytes `readStandardInput` keeps (16 MiB); the rest is drained.
    public static let standardInputMaxBytes = 16 << 20

    /// Reads fd 0 to EOF, keeping at most `maxBytes` (the rest is drained and
    /// discarded so the agent never blocks on a full pipe). Returns empty data when
    /// stdin is a terminal, so running the command by hand never waits for input.
    /// Stops at `timeout` with whatever has arrived; works whether or not the
    /// inherited descriptor is non-blocking.
    public static func readStandardInput(maxBytes: Int = standardInputMaxBytes,
                                         timeout: TimeInterval = standardInputTimeout) -> Data {
        guard isatty(STDIN_FILENO) == 0 else { return Data() }
        return readInput(fd: STDIN_FILENO, maxBytes: maxBytes, timeout: timeout)
    }

    /// Testable core of `readStandardInput`: waits for readability with `poll`
    /// before every read, so neither a silent writer nor `EAGAIN` from a
    /// non-blocking pipe can lose data or stall past the deadline.
    static func readInput(fd: Int32, maxBytes: Int, timeout: TimeInterval) -> Data {
        let deadline = SocketDeadline(after: timeout)
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while UnixSocket.wait(fd, for: POLLIN, deadline: deadline) {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                let keep = min(count, maxBytes - data.count)
                if keep > 0 { data.append(contentsOf: chunk[0..<keep]) }
            } else if count == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                return data
            }
        }
        return data
    }

    /// `--provider X` or `--provider=X` (case-insensitive); everything else,
    /// including legacy `--log PATH` / `--event E`, is ignored. nil when missing,
    /// valueless or not a supported provider.
    public static func providerArgument(_ arguments: [String]) -> HookProvider? {
        var value: String?
        var remaining = arguments.makeIterator()
        while let argument = remaining.next() {
            if argument == "--provider" {
                value = remaining.next()
            } else if argument.hasPrefix("--provider=") {
                value = String(argument.dropFirst("--provider=".count))
            }
        }
        guard let value else { return nil }
        return HookProvider(rawValue: value.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// `SIDEPULSE_DISABLE_EVENT_SOCKET` is `1`, `true` or `yes` (case-insensitive).
    public static func eventSocketDisabled(_ environment: [String: String]) -> Bool {
        let value = (environment["SIDEPULSE_DISABLE_EVENT_SOCKET"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return ["1", "true", "yes"].contains(value)
    }

    /// Builds the trimmed record we log and send. Flat object, keys in this order
    /// (absent values omitted):
    /// `logged_at` (TimeFormat.iso8601Millis), `hook_event_name` (from
    /// hook_event_name/hookEventName, raw), `session_id`, `turn_id`, `agent_id`,
    /// `agent_type`, `cwd`, `tool_name`, `tool_input` ({"command": ≤2000 chars} only
    /// when tool_input.command is a string), `tool_response` (object: only
    /// interrupted/success/exit_code keys; string: first 500 chars),
    /// `tool_response_failed` (bool, `ModeClassifier.toolResponseLooksFailed` on the
    /// FULL response), `prompt` (≤4000 chars), `last_assistant_message` (fenced
    /// code blocks removed with the classifier's rule, then ≤16000 chars: if longer
    /// keep the first 4000 + "\n…\n" + last 12000; omitted when nothing is left),
    /// `message` (≤2000), `notification_type`, `error` (string ≤500),
    /// `error_details` (≤500), `source`, `reason`, `background_task_ids` (see
    /// `backgroundTaskIDs`), `sidepulse_status`,
    /// `sidepulse_mode`, then origin: `agent_origin`, `agent_origin_kind`,
    /// `agent_origin_source`, `agent_origin_confidence` (skipped if the payload
    /// already has agent_origin). Invalid JSON →
    /// `{"logged_at":…,"hook_event_name":"ParseError","parse_error":"…"}`.
    /// A Codex payload wrapped as `{"event":{...}}` is unwrapped first.
    ///
    /// Details: scalar fields accept strings and numbers (other types are omitted)
    /// and camelCase spellings (`sessionId`, `toolName`, …) as fallbacks. Fields
    /// without a listed limit are capped at `defaultFieldLimit`. Lengths count
    /// Unicode scalars (Python `len`). A number cannot be truncated, so one whose
    /// literal is longer than the field's limit counts as absent. The kept
    /// `tool_response` keys go through `bounded` (containers are dropped; the
    /// failure flag is still computed on the full value), so a hostile payload can
    /// never produce an oversized record. Empty input counts as `{}`; valid JSON
    /// that is not an object becomes a ParseError record. When the payload carries
    /// its own non-empty `agent_origin`/`agentOrigin`, its four origin fields are
    /// copied instead of `origin`.
    public static func makeRecord(provider: HookProvider, payload: Data, now: Date, origin: AgentOrigin?) -> JSONObject {
        makeRecord(provider: provider, payload: payload, now: now) { origin }
    }

    /// Cap for fields the record contract gives no explicit limit (ids, cwd, …).
    public static let defaultFieldLimit = 1024

    /// Same as the public variant, but only asks for the origin when the payload
    /// does not carry one (detection walks the process tree).
    static func makeRecord(provider: HookProvider, payload: Data, now: Date,
                           detectOrigin: () -> AgentOrigin?) -> JSONObject {
        var record = JSONObject()
        record["logged_at"] = .string(TimeFormat.iso8601Millis(now))

        let parsed: JSONValue
        if payload.isEmpty {
            parsed = .object(JSONObject())
        } else {
            do {
                parsed = try JSONValue.parse(payload)
            } catch {
                return parseErrorRecord(record, message: String(describing: error))
            }
        }
        guard case .object(var raw) = parsed else {
            return parseErrorRecord(record, message: "Expected a JSON object, got \(typeName(parsed))")
        }
        if provider == .codex, case .object(let inner)? = raw["event"],
           raw["hook_event_name"] == nil, raw["hookEventName"] == nil {
            raw = inner
        }

        func scalar(_ keys: String..., limit: Int = defaultFieldLimit) -> JSONValue? {
            for key in keys {
                switch raw[key] {
                case .string(let s)? where !s.isEmpty: return .string(truncated(s, to: limit))
                case .number(let n)? where n.utf8.count <= limit: return .number(n)
                default: continue
                }
            }
            return nil
        }

        record["hook_event_name"] = scalar("hook_event_name", "hookEventName")
        record["session_id"] = scalar("session_id", "sessionId")
        record["turn_id"] = scalar("turn_id", "turnId")
        record["agent_id"] = scalar("agent_id", "agentId")
        record["agent_type"] = scalar("agent_type", "agentType")
        record["cwd"] = scalar("cwd")
        record["tool_name"] = scalar("tool_name", "toolName")

        if case .string(let command)? = (raw["tool_input"] ?? raw["toolInput"])?["command"] {
            record["tool_input"] = .object(["command": .string(truncated(command, to: 2000))])
        }

        if let response = raw["tool_response"] ?? raw["toolResponse"], !response.isNull {
            switch response {
            case .object(let object):
                var kept = JSONObject()
                for key in ["interrupted", "success", "exit_code"] {
                    if let value = object[key].flatMap({ bounded($0, limit: defaultFieldLimit) }) { kept[key] = value }
                }
                if !kept.isEmpty { record["tool_response"] = .object(kept) }
            case .string(let text):
                record["tool_response"] = .string(truncated(text, to: 500))
            default:
                break
            }
            record["tool_response_failed"] = .bool(ModeClassifier.toolResponseLooksFailed(response))
        }

        record["prompt"] = scalar("prompt", limit: 4000)
        if case .string(let text)? = raw["last_assistant_message"] ?? raw["lastAssistantMessage"] {
            // Code goes before the cut, so markers and questions are judged on the
            // same prose as the full message: a cut through a code block would pair
            // the remaining fences differently and expose code to the classifier.
            let prose = stripFencedCodeBlocks(text)
            if !prose.isEmpty { record["last_assistant_message"] = .string(headAndTail(prose)) }
        }
        record["message"] = scalar("message", limit: 2000)
        record["notification_type"] = scalar("notification_type", "notificationType")
        record["error"] = scalar("error", limit: 500)
        record["error_details"] = scalar("error_details", limit: 500)
        record["source"] = scalar("source")
        record["reason"] = scalar("reason")
        if let ids = backgroundTaskIDs(raw["background_tasks"] ?? raw["backgroundTasks"]) {
            record["background_task_ids"] = .array(ids.map(JSONValue.string))
        }
        record["sidepulse_status"] = scalar("sidepulse_status")
        record["sidepulse_mode"] = scalar("sidepulse_mode")

        if let own = scalar("agent_origin", "agentOrigin") {
            record["agent_origin"] = own
            record["agent_origin_kind"] = scalar("agent_origin_kind", "agentOriginKind")
            record["agent_origin_source"] = scalar("agent_origin_source", "agentOriginSource")
            record["agent_origin_confidence"] = scalar("agent_origin_confidence", "agentOriginConfidence")
        } else if let origin = detectOrigin() {
            record["agent_origin"] = .string(origin.label)
            record["agent_origin_kind"] = .string(origin.kind)
            record["agent_origin_source"] = .string(origin.source)
            record["agent_origin_confidence"] = .string(origin.confidence)
        }
        return record
    }

    private static func parseErrorRecord(_ base: JSONObject, message: String) -> JSONObject {
        var record = base
        record["hook_event_name"] = .string("ParseError")
        record["parse_error"] = .string(truncated(message, to: 500))
        return record
    }

    private static func typeName(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "a boolean"
        case .number: return "a number"
        case .string: return "a string"
        case .array: return "an array"
        case .object: return "an object"
        }
    }

    /// Most `background_tasks` entries kept, and the longest id.
    static let maxBackgroundTasks = 32
    static let maxBackgroundTaskIDLength = 128

    /// The ids of Claude's `background_tasks` (`[{"id","type":"subagent"|"shell",
    /// "status":"running",…}]` on Stop and SubagentStop: the tasks still running),
    /// in order. The engine closes a session's subagent rows that a parent Stop does
    /// not list, so a list that cannot be kept whole counts as absent (nil): not an
    /// array, more than `maxBackgroundTasks` entries, or an entry without a
    /// non-empty string id of at most `maxBackgroundTaskIDLength` scalars.
    static func backgroundTaskIDs(_ value: JSONValue?) -> [String]? {
        guard case .array(let tasks)? = value, tasks.count <= maxBackgroundTasks else { return nil }
        var ids: [String] = []
        for task in tasks {
            guard case .string(let id)? = task["id"], !id.isEmpty,
                  id.unicodeScalars.count <= maxBackgroundTaskIDLength else { return nil }
            ids.append(id)
        }
        return ids
    }

    /// `value` if it is small enough to log: null and booleans as they are, numbers
    /// whose literal fits in `limit` characters, strings truncated to `limit`
    /// scalars. Arrays, objects and longer numbers → nil.
    static func bounded(_ value: JSONValue, limit: Int) -> JSONValue? {
        switch value {
        case .null, .bool: return value
        case .number(let literal): return literal.utf8.count <= limit ? value : nil
        case .string(let text): return .string(truncated(text, to: limit))
        case .array, .object: return nil
        }
    }

    /// Keeps the first `limit` Unicode scalars.
    static func truncated(_ text: String, to limit: Int) -> String {
        let scalars = text.unicodeScalars
        guard let end = scalars.index(scalars.startIndex, offsetBy: limit, limitedBy: scalars.endIndex),
              end != scalars.endIndex else { return text }
        return String(scalars[..<end])
    }

    /// ≤16000 scalars unchanged; longer → first 4000 + "\n…\n" + last 12000.
    static func headAndTail(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let limitIndex = scalars.index(scalars.startIndex, offsetBy: 16000, limitedBy: scalars.endIndex),
              limitIndex != scalars.endIndex else { return text }
        let headEnd = scalars.index(scalars.startIndex, offsetBy: 4000)
        let tailStart = scalars.index(scalars.endIndex, offsetBy: -12000)
        return String(scalars[..<headEnd]) + "\n\u{2026}\n" + String(scalars[tailStart...])
    }
}

/// Append-only JSONL files with size-based rotation.
public enum HookLogStore {
    /// Appends `line + "\n"` with a single O_APPEND write (creates dirs/file, mode
    /// 0600). If the file is larger than `rotateAt` before writing, renames it to
    /// `<name>.1` (replacing any previous `.1`) first.
    ///
    /// Missing directories are created with mode 0700 (records contain prompts).
    /// Concurrent hook processes rotate at most once: the rename happens under an
    /// `flock` on the old file and only if the path still names that file.
    public static func append(line: String, to url: URL, rotateAt: Int = SidePulseConstants.logRotateBytes) throws {
        let path = url.path
        var fd = try openForAppend(path)
        var info = stat()
        if rotateAt > 0, fstat(fd, &info) == 0, Int(info.st_size) > rotateAt {
            flock(fd, LOCK_EX)
            var current = stat()
            if stat(path, &current) == 0, current.st_dev == info.st_dev, current.st_ino == info.st_ino {
                rename(path, path + ".1")
            }
            flock(fd, LOCK_UN)
            close(fd)
            fd = try openForAppend(path)
        }
        defer { close(fd) }

        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.write(fd, base + offset, buffer.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                throw FileUtil.posixError("write \(path)")
            }
        }
    }

    private static func openForAppend(_ path: String) throws -> Int32 {
        let flags = O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC
        var fd = open(path, flags, 0o600)
        if fd < 0 && errno == ENOENT {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            fd = open(path, flags, 0o600)
        }
        guard fd >= 0 else { throw FileUtil.posixError("open \(path)") }
        return fd
    }
}
