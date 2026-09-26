import Foundation

/// `latest.json` restart snapshot: `{"updated_at": pythonISO(now), "statuses": [AgentStatus.toJSON(now)...]}`
/// written pretty with sorted keys + trailing newline via `FileUtil.atomicWrite`.
public struct LatestStore: Sendable {
    public var url: URL
    public init(url: URL) { self.url = url }

    /// Invalid entries are skipped; missing/corrupt file → [].
    public func load() -> [AgentStatus] {
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONValue.parse(data),
              let entries = document["statuses"]?.arrayValue else { return [] }
        return entries.compactMap(AgentStatus.fromJSON)
    }

    /// Entries are written with `stale: false`, newest first (ties by key) so the
    /// file is deterministic.
    public func save(_ statuses: [AgentStatus], now: Date = Date()) throws {
        let ordered = statuses.sorted {
            $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.agentID < $1.agentID
        }
        let entries: [JSONValue] = ordered.map { status in
            var status = status
            status.stale = false
            return status.toJSON(now: now)
        }
        let document: JSONValue = .object(["updated_at": .string(TimeFormat.pythonISO(now)), "statuses": .array(entries)])
        try FileUtil.atomicWrite(document.sortedKeys().serialized(pretty: true) + "\n", to: url)
    }
}

/// Reading provider JSONL logs (recovery at app start, offline CLI status).
public enum LogScanner {
    static let chunkSize = 64 * 1024

    /// Last `maxLines` lines, reading backwards in 64 KiB chunks. Splits on "\n"
    /// only, drops empty lines; a partial first line is harmless (fails JSON parse).
    /// (Here it is dropped outright when the read stops before the start of the
    /// file.) Missing/unreadable file or not a regular file → [].
    public static func readRecentLines(url: URL, maxLines: Int) -> [String] {
        recentLineBytes(url: url, maxLines: maxLines).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Byte slices of the last `maxLines` non-empty lines (see `readRecentLines`).
    static func recentLineBytes(url: URL, maxLines: Int) -> [ArraySlice<UInt8>] {
        guard maxLines > 0 else { return [] }
        // O_NONBLOCK keeps a FIFO at the path from hanging the open; O_CLOEXEC keeps
        // the descriptor out of processes spawned meanwhile.
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return [] }

        var position = Int(info.st_size)
        var chunks: [[UInt8]] = []
        var newlines = 0
        while position > 0 && newlines <= maxLines {
            let size = min(chunkSize, position)
            position -= size
            var chunk = [UInt8](repeating: 0, count: size)
            let read = chunk.withUnsafeMutableBytes { pread(fd, $0.baseAddress, size, off_t(position)) }
            guard read == size else { return [] }
            newlines += newlineOffsets(in: chunk).count
            chunks.append(chunk)
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(chunks.reduce(0) { $0 + $1.count })
        for chunk in chunks.reversed() { bytes.append(contentsOf: chunk) }

        // Line boundaries: after each newline. When the read began mid-file, the
        // text before the first newline is a partial line and is skipped.
        var lines: [ArraySlice<UInt8>] = []
        var lineStart = 0
        var skipFirst = position > 0
        for offset in newlineOffsets(in: bytes) + [bytes.count] {
            if skipFirst {
                skipFirst = false
            } else if offset > lineStart {
                lines.append(bytes[lineStart..<offset])
            }
            lineStart = offset + 1
        }
        return Array(lines.suffix(maxLines))
    }

    /// Offsets of every `\n` byte (found with `memchr`).
    static func newlineOffsets(in bytes: [UInt8]) -> [Int] {
        bytes.withUnsafeBufferPointer { buffer -> [Int] in
            guard let base = buffer.baseAddress else { return [] }
            var offsets: [Int] = []
            var cursor = base
            let end = base + buffer.count
            while cursor < end, let hit = memchr(cursor, 0x0A, end - cursor) {
                let found = UnsafePointer<UInt8>(hit.assumingMemoryBound(to: UInt8.self))
                offsets.append(found - base)
                cursor = found + 1
            }
            return offsets
        }
    }

    public static func events(provider: String, url: URL, maxLines: Int) -> [HookEvent] {
        events(provider: provider, url: url, maxLines: maxLines, now: Date())
    }

    static func events(provider: String, url: URL, maxLines: Int, now: Date) -> [HookEvent] {
        recentLineBytes(url: url, maxLines: maxLines).compactMap { bytes in
            EventParser.parseLine(provider: provider, line: String(decoding: bytes, as: UTF8.self), now: now)
        }
    }

    /// Reads all sources, stable-sorts every event by (loggedAt, source order, line
    /// order) and runs them through a fresh `StatusEngine(config:)`. Returns the
    /// engine's resulting rows (newest first, ties by key). Duplicate
    /// (provider, path) sources are read once. Rows are not pruned.
    ///
    /// - Parameter codexTitle: Codex session-title lookup passed to the engine
    ///   (e.g. `CodexSessionIndex.title(forSession:)`), so Codex rows get the same
    ///   labels as in the live engine.
    public static func scan(sources: [SourceInfo], maxLines: Int = SidePulseConstants.recoveryMaxLines,
                            config: MonitorConfig = MonitorConfig(),
                            codexTitle: ((String) -> String?)? = nil) -> [AgentStatus] {
        let engine = StatusEngine(config: config, codexTitle: codexTitle)
        for event in orderedEvents(sources: sources, maxLines: maxLines) { engine.ingest(event) }
        return engine.statuses.values.sorted {
            $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.agentID < $1.agentID
        }
    }

    /// Every source's events, stable-sorted by (loggedAt, source order, line order).
    /// Hook timestamps have (milli)second resolution, so ties are common.
    static func orderedEvents(sources: [SourceInfo], maxLines: Int, now: Date = Date()) -> [HookEvent] {
        var seen = Set<String>()
        let unique = sources.filter { seen.insert("\($0.provider)\u{0}\($0.path)").inserted }
        var perSource = [[HookEvent]](repeating: [], count: unique.count)
        // Parsing dominates; sources are independent, so parse them concurrently.
        perSource.withUnsafeMutableBufferPointer { buffer in
            let results = buffer
            DispatchQueue.concurrentPerform(iterations: unique.count) { index in
                let source = unique[index]
                results[index] = events(provider: source.provider, url: URL(fileURLWithPath: source.path),
                                        maxLines: maxLines, now: now)
            }
        }
        let all = perSource.flatMap { $0 }
        return all.indices
            .sorted { all[$0].loggedAt != all[$1].loggedAt ? all[$0].loggedAt < all[$1].loggedAt : $0 < $1 }
            .map { all[$0] }
    }

    /// Default sources for the given paths: claude and codex logs (current file and
    /// the rotated `.1` file, older first so ordering by timestamp is stable).
    ///
    /// Order: codex before claude (Python's tie order). The current log is always
    /// listed (so callers can report it missing); the rotated `<log>.1` only when it
    /// exists.
    public static func defaultSources(paths: SidePulsePaths) -> [SourceInfo] {
        var sources: [SourceInfo] = []
        for provider in ["codex", "claude"] {
            let current = paths.logFile(for: provider)
            let rotated = current.appendingPathExtension("1")
            if FileManager.default.fileExists(atPath: rotated.path) {
                sources.append(SourceInfo(provider: provider, path: rotated.path))
            }
            sources.append(SourceInfo(provider: provider, path: current.path))
        }
        return sources
    }
}

/// Codex session titles from `~/.codex/session_index.jsonl`
/// (`{"id","thread_name","updated_at"}` rows; later rows win; titles truncated to
/// 72). Cached by mtime+size. Thread-safe.
public final class CodexSessionIndex: @unchecked Sendable {
    /// Rows read from the end of the index (Python `CODEX_SESSION_INDEX_MAX_LINES`).
    public static let maxLines = 5000

    public let url: URL
    private let lock = NSLock()
    private var signature: FileSignature?
    private var titles: [String: String] = [:]

    public init(url: URL) {
        self.url = url
    }

    /// The index for `paths.home` (`~/.codex/session_index.jsonl`).
    public convenience init(paths: SidePulsePaths) {
        self.init(url: paths.codexDir.appendingPathComponent("session_index.jsonl"))
    }

    public func title(forSession id: String) -> String? {
        guard !id.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        refreshIfNeeded()
        guard let title = titles[id], !title.isEmpty else { return nil }
        return title
    }

    /// Re-reads the index when its mtime or size changed; a missing file empties it.
    private func refreshIfNeeded() {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            signature = nil
            titles = [:]
            return
        }
        let current = FileSignature(size: Int64(info.st_size), seconds: info.st_mtimespec.tv_sec,
                                    nanoseconds: info.st_mtimespec.tv_nsec)
        guard current != signature else { return }
        signature = current
        var fresh: [String: String] = [:]
        for line in LogScanner.readRecentLines(url: url, maxLines: Self.maxLines) {
            guard let row = (try? JSONValue.parse(line))?.objectValue,
                  let id = PyText.nonEmptyString(row["id"]),
                  let name = PyText.nonEmptyString(row["thread_name"]) else { continue }
            // A blank (whitespace-only) name is stored as "" so it still replaces an
            // earlier title; lookups treat it as "no title", like Python.
            fresh[id] = DisplayNames.truncate(PyText.strip(name), DisplayNames.titleLimit)
        }
        titles = fresh
    }

    private struct FileSignature: Equatable {
        var size: Int64
        var seconds: Int
        var nanoseconds: Int
    }
}
