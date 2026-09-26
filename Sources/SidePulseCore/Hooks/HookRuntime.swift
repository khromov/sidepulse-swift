import Darwin
import Foundation

/// Runs inside every agent hook, so it never throws, never blocks for long, always returns 0 and never
/// writes to stdout (Claude injects hook stdout into the model context).
public enum HookRuntime {
    public static func run(arguments: [String], stdin: Data, environment: [String: String],
                           paths: SidePulsePaths, now: Date = Date()) -> Int32 {
        guard let provider = providerArgument(arguments) else { return 0 }
        let record = makeRecord(provider: provider, payload: stdin, now: now,
                                origin: OriginDetector.detect(provider: provider, environment: environment))
        // A payload without an event name, such as a hand-run command with no input, carries no status.
        guard record["hook_event_name"] != nil else { return 0 }
        let line = JSONValue.object(record).serialized()

        // The log is the durable record, independent of the socket, so a dead runtime never loses the event.
        try? HookLogStore.append(line: line, to: paths.logFile(for: provider.rawValue))

        // Built by concatenation so the record is serialized only once.
        if !eventSocketDisabled(environment) {
            let message = "{\"provider\":" + JSONValue.string(provider.rawValue).serialized() + ",\"line\":" + line + "}"
            EventSocketClient.send(Data(message.utf8), socketPath: paths.socketPath,
                                   timeout: SidePulseConstants.hookSendTimeout)
        }
        return 0
    }

    public static func runFromProcess(arguments: [String]) -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        return run(arguments: arguments, stdin: readStandardInput(), environment: environment,
                   paths: SidePulsePaths(environment: environment))
    }

    /// Agents write the payload at once and close stdin, so this only stops a writer that never closes from
    /// hanging the hook.
    public static let standardInputTimeout: TimeInterval = 3

    public static let standardInputMaxBytes = 16 << 20

    /// Drains input past `maxBytes` so the agent never blocks on a full pipe, and returns empty data on a
    /// terminal so running the command by hand never waits for input.
    public static func readStandardInput(maxBytes: Int = standardInputMaxBytes,
                                         timeout: TimeInterval = standardInputTimeout) -> Data {
        guard isatty(STDIN_FILENO) == 0 else { return Data() }
        return readInput(fd: STDIN_FILENO, maxBytes: maxBytes, timeout: timeout)
    }

    /// Polls before every read so neither a silent writer nor `EAGAIN` from an inherited non-blocking pipe
    /// can lose data or stall past the deadline.
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

    /// Python-era hook commands also pass `--log PATH` / `--event E`, so every other argument is ignored.
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

    public static func eventSocketDisabled(_ environment: [String: String]) -> Bool {
        let value = (environment["SIDEPULSE_DISABLE_EVENT_SOCKET"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return ["1", "true", "yes"].contains(value)
    }

    public static let defaultFieldLimit = 1024

    /// Every field is length-capped so a hostile payload can never produce an oversized record; an origin in the
    /// payload, such as the OpenCode plugin's, wins over the detected one.
    public static func makeRecord(provider: HookProvider, payload: Data, now: Date, origin: String?) -> JSONObject {
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
        if provider == .codex, case .object(let inner)? = raw["event"], raw["hook_event_name"] == nil {
            raw = inner
        }

        func scalar(_ key: String, limit: Int = defaultFieldLimit) -> JSONValue? {
            switch raw[key] {
            case .string(let s)? where !s.isEmpty: return .string(truncated(s, to: limit))
            case .number(let n)? where n.utf8.count <= limit: return .number(n)
            default: return nil
            }
        }

        record["hook_event_name"] = scalar("hook_event_name")
        record["session_id"] = scalar("session_id")
        record["agent_id"] = scalar("agent_id")
        record["cwd"] = scalar("cwd")
        record["tool_name"] = scalar("tool_name")

        if case .string(let command)? = raw["tool_input"]?["command"] {
            record["tool_input"] = .object(["command": .string(truncated(command, to: 2000))])
        }

        if let response = raw["tool_response"], !response.isNull {
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
        if case .string(let text)? = raw["last_assistant_message"] {
            // Strip code before the cut, since a cut through a code block would pair the remaining fences
            // differently and expose code to the classifier.
            let prose = stripFencedCodeBlocks(text)
            if !prose.isEmpty { record["last_assistant_message"] = .string(headAndTail(prose)) }
        }
        record["message"] = scalar("message", limit: 2000)
        record["notification_type"] = scalar("notification_type")
        record["error_details"] = scalar("error_details", limit: 500)
        if let ids = backgroundTaskIDs(raw["background_tasks"]) {
            record["background_task_ids"] = .array(ids.map(JSONValue.string))
        }
        record["sidepulse_status"] = scalar("sidepulse_status")
        record["sidepulse_mode"] = scalar("sidepulse_mode")

        record["agent_origin"] = scalar("agent_origin") ?? origin.map(JSONValue.string)
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

    static let maxBackgroundTasks = 32
    static let maxBackgroundTaskIDLength = 128

    /// The engine closes subagent rows that a parent Stop does not list, so a list that cannot be kept whole
    /// counts as absent.
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

    static func bounded(_ value: JSONValue, limit: Int) -> JSONValue? {
        switch value {
        case .null, .bool: return value
        case .number(let literal): return literal.utf8.count <= limit ? value : nil
        case .string(let text): return .string(truncated(text, to: limit))
        case .array, .object: return nil
        }
    }

    /// Counts Unicode scalars to match Python's `len`.
    static func truncated(_ text: String, to limit: Int) -> String {
        let scalars = text.unicodeScalars
        guard let end = scalars.index(scalars.startIndex, offsetBy: limit, limitedBy: scalars.endIndex),
              end != scalars.endIndex else { return text }
        return String(scalars[..<end])
    }

    static func headAndTail(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let limitIndex = scalars.index(scalars.startIndex, offsetBy: 16000, limitedBy: scalars.endIndex),
              limitIndex != scalars.endIndex else { return text }
        let headEnd = scalars.index(scalars.startIndex, offsetBy: 4000)
        let tailStart = scalars.index(scalars.endIndex, offsetBy: -12000)
        return String(scalars[..<headEnd]) + "\n\u{2026}\n" + String(scalars[tailStart...])
    }
}

public enum HookLogStore {
    /// Concurrent hook processes rotate at most once because the rename happens under an `flock` on the old
    /// file and only if the path still names that file.
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
