import Foundation

/// Codex runs a hook only once `[hooks.state."<key>"]` holds its current hash, which binds to the exact
/// command string, so we ask `codex app-server --stdio` for it (`hooks/list`, as of codex-cli 0.153.4).
public enum CodexTrust {
    /// Also searches the usual install directories because the app runs under launchd's minimal PATH.
    public static func findCodexBinary(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fm = FileManager.default
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        var candidates: [String] = []
        if let explicit = environment["CODEX_CLI_PATH"], !explicit.isEmpty {
            candidates.append(explicit.hasPrefix("~/") ? home + explicit.dropFirst(1) : explicit)
        }
        candidates += ["/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex"]
        let dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + commonBinDirectories(home: home)
        // Relative PATH entries are skipped: never run a `codex` from the cwd.
        candidates += dirs.filter { $0.hasPrefix("/") }.map { $0 + "/codex" }
        return candidates.first { path in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue && fm.isExecutableFile(atPath: path)
        }
    }

    /// Codex finds its home through `CODEX_HOME`/`HOME` in `environment`, so that must agree with `configFile`.
    public static func fetchHashes(codexPath: String, configFile: URL, timeout: TimeInterval = 8,
                                   environment: [String: String]? = nil) throws -> [String: String] {
        let result = try listHooks(codexPath: codexPath, configFile: configFile, timeout: timeout, environment: environment)
        return hashes(fromHooksList: result, configFile: configFile)
    }

    public static func listHooks(codexPath: String, configFile: URL, timeout: TimeInterval = 8,
                                 environment: [String: String]? = nil) throws -> JSONValue {
        let cwd = configFile.deletingLastPathComponent().deletingLastPathComponent()
        // Foundation autoreleases the pipes' file handles; the pool closes their
        // descriptors on return even on threads that never drain one.
        return try autoreleasepool {
            let session = try JSONRPCChild(executable: codexPath, arguments: ["app-server", "--stdio"],
                                           environment: environment, directory: cwd)
            defer { session.stop() }
            _ = try session.request(id: 1, method: "initialize", params: .object([
                "clientInfo": .object(["name": .string("sidepulse"), "version": .string(SidePulseConstants.version)]),
                "capabilities": .null,
            ]), timeout: timeout)
            try session.notify(method: "initialized")
            return try session.request(id: 2, method: "hooks/list", params: .object([
                "cwds": .array([.string(cwd.path)]),
            ]), timeout: timeout)
        }
    }

    static func commonBinDirectories(home: String) -> [String] {
        var dirs = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                    home + "/.bun/bin", home + "/.npm-global/bin", home + "/.volta/bin"]
        let nvm = home + "/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []
        if let newest = versions.filter({ $0.hasPrefix("v") }).max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) {
            dirs.append("\(nvm)/\(newest)/bin")
        }
        return dirs
    }

    static func hashes(fromHooksList result: JSONValue, configFile: URL) -> [String: String] {
        guard case .array(let entries)? = result["data"] else { return [:] }
        let wanted = canonicalPath(configFile.path)
        var out: [String: String] = [:]
        for entry in entries {
            for hook in entry["hooks"]?.arrayValue ?? [] {
                guard let key = hook["key"]?.stringValue,
                      let hash = hook["currentHash"]?.stringValue,
                      let command = hook["command"]?.stringValue,
                      let source = hook["sourcePath"]?.stringValue,
                      HookCommand.isCurrentStyleCommand(command),
                      source == configFile.path || canonicalPath(source) == wanted else { continue }
                out[key] = hash
            }
        }
        return out
    }

    public static func applyTrustedHashes(_ hashes: [String: String], to text: String) -> String {
        guard !hashes.isEmpty else { return text }
        var lines = TOMLLines(text).lines
        if !TOMLLines(lines: lines).kinds.contains(.header(path: ["hooks", "state"], isArray: false)) {
            if let last = lines.last, !TOMLLines.isBlank(last) { lines.append("") }
            lines.append("[hooks.state]")
        }
        for key in orderedKeys(hashes.keys) {
            let hashLine = "trusted_hash = \(TOMLString.basic(hashes[key]!))"
            let doc = TOMLLines(lines: lines)
            guard let header = lines.indices.first(where: { doc.kinds[$0] == .header(path: ["hooks", "state", key], isArray: false) }) else {
                if let last = lines.last, !TOMLLines.isBlank(last) { lines.append("") }
                lines += ["[hooks.state.\(TOMLString.basic(key))]", hashLine]
                continue
            }
            let end = doc.nextHeader(after: header)
            if let existing = (header + 1..<end).first(where: { doc.keyPath(at: $0) == ["trusted_hash"] }) {
                if doc.stringValue(at: existing, key: "trusted_hash") != hashes[key] { lines[existing] = hashLine }
            } else {
                lines.insert(hashLine, at: header + 1)
            }
        }
        let result = TOMLLines.join(lines)
        return result == text ? text : result
    }

    struct RefreshOutcome {
        var trusted: Int
        var changed: Bool
        var backup: URL?
    }

    /// A nil `backupAt` skips the backup because the caller already made one this run.
    static func refreshConfig(configFile: URL, codexPath: String, timeout: TimeInterval,
                              environment: [String: String]?, backupAt: Date?) throws -> RefreshOutcome {
        let hashes = try fetchHashes(codexPath: codexPath, configFile: configFile, timeout: timeout, environment: environment)
        guard !hashes.isEmpty else { return RefreshOutcome(trusted: 0, changed: false, backup: nil) }
        // Re-read: the file is ours to edit only as it is now.
        let current = try HookConfigFile.read(configFile) ?? ""
        let updated = applyTrustedHashes(hashes, to: current)
        guard updated != current else { return RefreshOutcome(trusted: hashes.count, changed: false, backup: nil) }
        try FileUtil.ensureWritable(configFile)
        let backup = try backupAt.flatMap { try FileUtil.backup(configFile, now: $0) }
        try FileUtil.atomicWrite(updated, to: configFile)
        return RefreshOutcome(trusted: hashes.count, changed: true, backup: backup)
    }

    /// An inherited `CODEX_HOME` is dropped so a scratch home never reaches the real `~/.codex`.
    /// `codexPath`'s directory goes first on PATH because an npm-installed `codex` runs `env node`,
    /// and node sits next to it, outside launchd's minimal PATH.
    public static func childEnvironment(for paths: SidePulsePaths, codexPath: String? = nil,
                                        base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        if paths.environment["CODEX_HOME"] == nil { env.removeValue(forKey: "CODEX_HOME") }
        for (k, v) in paths.environment { env[k] = v }
        env["HOME"] = paths.home.path
        if let codexPath {
            let url = URL(fileURLWithPath: codexPath)
            let dirs = [url, url.resolvingSymlinksInPath()].map { $0.deletingLastPathComponent().path }
            env["PATH"] = uniqued(dirs + (env["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        }
        return env
    }

    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func orderedKeys<S: Sequence>(_ keys: S) -> [String] where S.Element == String {
        let order = Dictionary(uniqueKeysWithValues: HookProvider.codex.events.enumerated().map {
            (CodexHookInstaller.snakeCase($0.element), $0.offset)
        })
        func rank(_ key: String) -> (Int, Int, Int) {
            let parts = key.split(separator: ":").suffix(3).map(String.init)
            guard parts.count == 3 else { return (Int.max, 0, 0) }
            return (order[parts[0]] ?? Int.max - 1, Int(parts[1]) ?? 0, Int(parts[2]) ?? 0)
        }
        return keys.sorted { a, b in
            let (ra, rb) = (rank(a), rank(b))
            return ra != rb ? ra < rb : a < b
        }
    }
}

public enum CodexTrustError: Error, Equatable, CustomStringConvertible {
    case launchFailed(String)
    case timedOut(method: String)
    case exited(method: String, detail: String)
    case rpcError(method: String, message: String)

    public var description: String {
        switch self {
        case .launchFailed(let message): return "could not start codex: \(message)"
        case .timedOut(let method): return "codex did not answer \(method) in time"
        case .exited(let method, let detail):
            return "codex exited before answering \(method)" + (detail.isEmpty ? "" : ": \(detail)")
        case .rpcError(let method, let message): return "codex rejected \(method): \(message)"
        }
    }
}

final class JSONRPCChild: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let condition = NSCondition()
    private var buffer = Data()
    private var lines: [String] = []
    private var outputClosed = false
    private var stderrTail = Data()
    private let exited = DispatchSemaphore(value: 0)

    init(executable: String, arguments: [String], environment: [String: String]?, directory: URL) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue {
            process.currentDirectoryURL = directory
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // Exit is observed through the handler rather than `waitUntilExit`, which
        // spins the caller's run loop (re-entrancy on the app's main thread).
        process.terminationHandler = { [exited] _ in exited.signal() }
        // A write to a child that already exited must fail, not kill us with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receiveError(handle.availableData)
        }
        do {
            try process.run()
        } catch {
            clearHandlers()
            throw CodexTrustError.launchFailed(error.localizedDescription)
        }
    }

    private func receive(_ data: Data) {
        condition.lock()
        defer { condition.broadcast(); condition.unlock() }
        guard !data.isEmpty else {
            outputClosed = true
            output.fileHandleForReading.readabilityHandler = nil
            return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer = Data(buffer[(newline + 1)...])
        }
    }

    private func receiveError(_ data: Data) {
        condition.lock()
        defer { condition.unlock() }
        guard !data.isEmpty else {
            errors.fileHandleForReading.readabilityHandler = nil
            return
        }
        stderrTail.append(data)
        if stderrTail.count > 4096 { stderrTail = Data(stderrTail.suffix(4096)) }
    }

    private func send(_ message: JSONValue) throws {
        let data = Data((message.serialized() + "\n").utf8)
        do {
            try input.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw CodexTrustError.exited(method: message["method"]?.stringValue ?? "?", detail: lastError())
        }
    }

    func notify(method: String) throws {
        try send(.object(["jsonrpc": .string("2.0"), "method": .string(method)]))
    }

    func request(id: Int, method: String, params: JSONValue, timeout: TimeInterval) throws -> JSONValue {
        try send(.object(["jsonrpc": .string("2.0"), "id": JSONValue(id), "method": .string(method), "params": params]))
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            guard let line = nextLine(deadline: deadline) else {
                condition.lock()
                let closed = outputClosed
                condition.unlock()
                if closed { throw CodexTrustError.exited(method: method, detail: lastError()) }
                throw CodexTrustError.timedOut(method: method)
            }
            guard let message = try? JSONValue.parse(line), case .object(let object) = message,
                  object["method"] == nil, object["id"]?.intValue == id else { continue }
            if let error = object["error"] {
                throw CodexTrustError.rpcError(method: method, message: error["message"]?.stringValue ?? error.serialized())
            }
            return object["result"] ?? .null
        }
    }

    private func nextLine(deadline: Date) -> String? {
        condition.lock()
        defer { condition.unlock() }
        while lines.isEmpty {
            if outputClosed { return nil }
            if !condition.wait(until: deadline) && lines.isEmpty { return nil }
        }
        return lines.removeFirst()
    }

    private func lastError() -> String {
        condition.lock()
        defer { condition.unlock() }
        let text = String(decoding: stderrTail, as: UTF8.self)
        return text.split(separator: "\n").suffix(3).joined(separator: " | ").trimmingCharacters(in: .whitespaces)
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        if !waitForExit(0.5) {
            process.terminate()
            if !waitForExit(1.0) {
                kill(process.processIdentifier, SIGKILL)
                _ = waitForExit(5)
            }
        }
        clearHandlers()
    }

    private func waitForExit(_ seconds: TimeInterval) -> Bool {
        guard exited.wait(timeout: .now() + seconds) == .success else { return false }
        exited.signal()   // stay signalled for any later wait
        return true
    }

    private func clearHandlers() {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
    }
}
