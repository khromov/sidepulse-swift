import Foundation
import Synchronization

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

public struct LogRecovery: Sendable {
    public var statuses: [AgentStatus]
    var pendingPermissions: [String: Set<String>]
}

public enum LogScanner {
    /// About 6,000 of today's 650-byte records, well past the 2,000-line recovery window.
    static let tailBytes: UInt64 = 4 << 20

    public static func readRecentLines(url: URL, maxLines: Int) -> [String] {
        readTail(url: url, maxLines: maxLines, tailBytes: tailBytes).lines
    }

    static func readRecentLines(url: URL, maxLines: Int, tailBytes: UInt64) -> [String] {
        readTail(url: url, maxLines: maxLines, tailBytes: tailBytes).lines
    }

    /// `reachedStart` means nothing before the returned lines was left out. A missing
    /// or non-regular file (opened non-blocking, so a FIFO can't hang) reads as empty.
    static func readTail(url: URL, maxLines: Int, tailBytes: UInt64) -> (lines: [String], reachedStart: Bool) {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return ([], true) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return ([], true) }
        guard maxLines > 0 else { return ([], info.st_size == 0) }
        let size = UInt64(max(0, info.st_size))
        let start = size > tailBytes ? size - tailBytes : 0
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return ([], false) }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        // A read that began mid-file starts with a partial line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        let reachedStart = start == 0 && lines.count <= maxLines
        return (lines.suffix(maxLines).map { String(decoding: $0, as: UTF8.self) }, reachedStart)
    }

    public static func scan(sources: [SourceInfo], maxLines: Int = SidePulseConstants.recoveryMaxLines,
                            config: MonitorConfig = MonitorConfig(),
                            codexTitle: ((String) -> String?)? = nil) -> [AgentStatus] {
        recover(sources: sources, maxLines: maxLines, config: config, codexTitle: codexTitle).statuses
    }

    public static func recover(sources: [SourceInfo], maxLines: Int = SidePulseConstants.recoveryMaxLines,
                               config: MonitorConfig = MonitorConfig(),
                               codexTitle: ((String) -> String?)? = nil) -> LogRecovery {
        let engine = StatusEngine(config: config, codexTitle: codexTitle)
        for event in orderedEvents(sources: sources, maxLines: maxLines) { engine.ingest(event) }
        let statuses = engine.statuses.values.sorted {
            $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.agentID < $1.agentID
        }
        return LogRecovery(statuses: statuses, pendingPermissions: engine.pendingPermissions)
    }

    /// A provider's sources (oldest first, like `defaultSources`) share one window read
    /// from the newest, so an older file is only read where it leaves no gap.
    /// Hook timestamps have millisecond resolution, so ties are common; `sorted` is
    /// stable, so source and line order break them.
    static func orderedEvents(sources: [SourceInfo], maxLines: Int, now: Date = Date()) -> [HookEvent] {
        var seen = Set<String>()
        var providers: [String] = []
        var paths: [String: [String]] = [:]
        for source in sources where seen.insert("\(source.provider)\u{0}\(source.path)").inserted {
            if paths[source.provider] == nil { providers.append(source.provider) }
            paths[source.provider, default: []].append(source.path)
        }
        var events: [HookEvent] = []
        for provider in providers {
            var budget = maxLines
            var newestFirst: [[String]] = []
            for path in paths[provider, default: []].reversed() {
                guard budget > 0 else { break }
                let tail = readTail(url: URL(fileURLWithPath: path), maxLines: budget, tailBytes: tailBytes)
                newestFirst.append(tail.lines)
                budget -= tail.lines.count
                if !tail.reachedStart { break }
            }
            for lines in newestFirst.reversed() {
                events += lines.compactMap { EventParser.parseLine(provider: provider, line: $0, now: now) }
            }
        }
        return events.sorted { $0.loggedAt < $1.loggedAt }
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

public final class CodexSessionIndex: Sendable {
    public static let maxLines = 5000

    public let url: URL
    private let state = Mutex(State())

    private struct State {
        var signature: FileSignature?
        var titles: [String: String] = [:]
    }

    public init(url: URL) {
        self.url = url
    }

    public convenience init(paths: SidePulsePaths) {
        self.init(url: paths.codexDir.appendingPathComponent("session_index.jsonl"))
    }

    public func title(forSession id: String) -> String? {
        guard !id.isEmpty else { return nil }
        return state.withLock { state in
            refreshIfNeeded(&state)
            guard let title = state.titles[id], !title.isEmpty else { return nil }
            return title
        }
    }

    private func refreshIfNeeded(_ state: inout State) {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            state = State()
            return
        }
        let current = FileSignature(size: Int64(info.st_size), seconds: info.st_mtimespec.tv_sec,
                                    nanoseconds: info.st_mtimespec.tv_nsec)
        guard current != state.signature else { return }
        state.signature = current
        var fresh: [String: String] = [:]
        for line in LogScanner.readRecentLines(url: url, maxLines: Self.maxLines) {
            guard let row = (try? JSONValue.parse(line))?.objectValue,
                  let id = PyText.nonEmptyString(row["id"]),
                  let name = PyText.nonEmptyString(row["thread_name"]) else { continue }
            // A blank name is stored as "" so it still replaces an earlier title, like Python.
            fresh[id] = DisplayNames.truncate(PyText.strip(name), DisplayNames.titleLimit)
        }
        state.titles = fresh
    }

    private struct FileSignature: Equatable {
        var size: Int64
        var seconds: Int
        var nanoseconds: Int
    }
}
