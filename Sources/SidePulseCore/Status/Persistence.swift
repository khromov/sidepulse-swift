import Foundation

public struct LatestStore: Sendable {
    public var url: URL
    public init(url: URL) { self.url = url }

    public func load() -> [AgentStatus] {
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONValue.parse(data),
              let entries = document["statuses"]?.arrayValue else { return [] }
        return entries.compactMap(AgentStatus.fromJSON)
    }

    /// Ties are broken by key so the file is deterministic.
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

public enum LogScanner {
    /// About 6,000 of today's 650-byte records, well past the 2,000-line recovery window.
    static let tailBytes: UInt64 = 4 << 20

    public static func readRecentLines(url: URL, maxLines: Int) -> [String] {
        readRecentLines(url: url, maxLines: maxLines, tailBytes: tailBytes)
    }

    static func readRecentLines(url: URL, maxLines: Int, tailBytes: UInt64) -> [String] {
        guard maxLines > 0, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > tailBytes ? size - tailBytes : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return [] }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        // A read that began mid-file starts with a partial line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.suffix(maxLines).map { String(decoding: $0, as: UTF8.self) }
    }

    public static func events(provider: String, url: URL, maxLines: Int) -> [HookEvent] {
        events(provider: provider, url: url, maxLines: maxLines, now: Date())
    }

    static func events(provider: String, url: URL, maxLines: Int, now: Date) -> [HookEvent] {
        readRecentLines(url: url, maxLines: maxLines).compactMap { EventParser.parseLine(provider: provider, line: $0, now: now) }
    }

    public static func scan(sources: [SourceInfo], maxLines: Int = SidePulseConstants.recoveryMaxLines,
                            config: MonitorConfig = MonitorConfig(),
                            codexTitle: ((String) -> String?)? = nil) -> [AgentStatus] {
        let engine = StatusEngine(config: config, codexTitle: codexTitle)
        for event in orderedEvents(sources: sources, maxLines: maxLines) { engine.ingest(event) }
        return engine.statuses.values.sorted {
            $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.agentID < $1.agentID
        }
    }

    /// Hook timestamps have millisecond resolution, so ties are common; `sorted` is stable, so source and
    /// line order break them.
    static func orderedEvents(sources: [SourceInfo], maxLines: Int, now: Date = Date()) -> [HookEvent] {
        var seen = Set<String>()
        return sources.filter { seen.insert("\($0.provider)\u{0}\($0.path)").inserted }
            .flatMap { events(provider: $0.provider, url: URL(fileURLWithPath: $0.path), maxLines: maxLines, now: now) }
            .sorted { $0.loggedAt < $1.loggedAt }
    }

    /// Codex precedes Claude (Python's tie order) and each rotated `.1` log precedes
    /// its current one, which is always listed so callers can report it missing.
    public static func defaultSources(paths: SidePulsePaths) -> [SourceInfo] {
        var sources: [SourceInfo] = []
        for provider in ["codex", "claude", "opencode"] {
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

public final class CodexSessionIndex: @unchecked Sendable {
    public static let maxLines = 5000

    public let url: URL
    private let lock = NSLock()
    private var signature: FileSignature?
    private var titles: [String: String] = [:]

    public init(url: URL) {
        self.url = url
    }

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
            // A blank name is stored as "" so it still replaces an earlier title, like Python.
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
