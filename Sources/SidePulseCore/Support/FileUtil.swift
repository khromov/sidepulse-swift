import Foundation

public enum TimeFormat {
    private static let fractional = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle(timeZoneSeparator: .colon)

    /// Each style rejects the other's shape, so stamps with and without a fraction need both.
    public static func parse(_ string: String) -> Date? {
        (try? fractional.parse(string)) ?? (try? whole.parse(string))
    }

    public static func parseOrNow(_ value: JSONValue?, now: Date = Date()) -> Date {
        guard let s = value?.stringValue, let d = parse(s.trimmingCharacters(in: .whitespaces)) else { return now }
        return d
    }

    public static func iso8601Millis(_ date: Date) -> String {
        let (base, frac) = split(date)
        let ms = min(999, Int((frac * 1000).rounded(.down)))
        return components(base) + String(format: ".%03dZ", ms)
    }

    public static func iso8601Seconds(_ date: Date) -> String {
        components(split(date).0) + "Z"
    }

    /// Matches Python `datetime.isoformat()`, which omits the fraction entirely when
    /// microseconds are zero.
    public static func pythonISO(_ date: Date) -> String {
        var (base, frac) = split(date)
        var micros = Int((frac * 1_000_000).rounded())
        if micros >= 1_000_000 { base += 1; micros = 0 }
        let head = components(base)
        return micros == 0 ? head + "+00:00" : head + String(format: ".%06d+00:00", micros)
    }

    public static func backupStamp(_ date: Date) -> String {
        var t = time_t(split(date).0)
        var tmv = tm()
        gmtime_r(&t, &tmv)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", Int(tmv.tm_year) + 1900, Int(tmv.tm_mon) + 1,
                      Int(tmv.tm_mday), Int(tmv.tm_hour), Int(tmv.tm_min), Int(tmv.tm_sec))
    }

    private static func split(_ date: Date) -> (Int, Double) {
        let t = date.timeIntervalSince1970
        let base = t.rounded(.down)
        return (Int(base), t - base)
    }

    private static func components(_ seconds: Int) -> String {
        var t = time_t(seconds)
        var tmv = tm()
        gmtime_r(&t, &tmv)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d", Int(tmv.tm_year) + 1900, Int(tmv.tm_mon) + 1,
                      Int(tmv.tm_mday), Int(tmv.tm_hour), Int(tmv.tm_min), Int(tmv.tm_sec))
    }
}

public enum FileUtil {
    /// Never use this for LEDS.LED, which must be written in place (see LedWriter).
    public static func atomicWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: ensureWritable(url), options: .atomic)
    }

    /// Refuses read-only files explicitly because an atomic replace would bypass the protection;
    /// call it before taking a backup so a refused write leaves nothing behind.
    @discardableResult
    public static func ensureWritable(_ url: URL) throws -> URL {
        let target = writeTarget(url)
        if access(target.path, F_OK) == 0, access(target.path, W_OK) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES),
                          userInfo: [NSLocalizedDescriptionKey: "\(target.path) is read-only; make it writable and try again"])
        }
        return target
    }

    /// An atomic write replaces a symlink with a regular file, so dotfile links are resolved first;
    /// a dangling link is followed one hop because it names the file the write should create.
    static func writeTarget(_ url: URL) -> URL {
        if let real = realPath(url.path) { return URL(fileURLWithPath: real) }
        guard let link = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return url }
        // The kernel resolves a relative link from the link's real directory, not the path we were given.
        let dir = realPath(url.deletingLastPathComponent().path) ?? url.deletingLastPathComponent().path
        return URL(fileURLWithPath: link, relativeTo: URL(fileURLWithPath: dir, isDirectory: true)).standardizedFileURL
    }

    private static func realPath(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    static func posixError(_ what: String) -> NSError {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                       userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(code)))"])
    }

    public static func atomicWrite(_ string: String, to url: URL) throws {
        try atomicWrite(Data(string.utf8), to: url)
    }

    @discardableResult
    public static func backup(_ url: URL, now: Date = Date()) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let base = url.path + ".bak." + TimeFormat.backupStamp(now)
        var candidate = base
        var n = 2
        while fm.fileExists(atPath: candidate) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        let dest = URL(fileURLWithPath: candidate)
        try fm.copyItem(at: writeTarget(url), to: dest)
        return dest
    }

    public static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

public final class DiagnosticsLog: @unchecked Sendable {
    public static let shared = DiagnosticsLog()
    private let queue = DispatchQueue(label: "sidepulse.diagnostics")
    private let stateLock = NSLock()
    private var _url: URL?
    private var _echo = false

    public var url: URL? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _url }
        set { stateLock.lock(); _url = newValue; stateLock.unlock() }
    }

    /// Mirrors lines to stderr for foreground runs.
    public var echo: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _echo }
        set { stateLock.lock(); _echo = newValue; stateLock.unlock() }
    }

    public init(url: URL? = nil) { self._url = url }

    /// Call before exiting, since lines are written asynchronously.
    public func flush() {
        queue.sync {}
    }

    public func log(_ message: String) {
        let line = Data("\(TimeFormat.iso8601Seconds(Date())) \(message)\n".utf8)
        let echo = self.echo
        let url = self.url
        queue.async {
            // POSIX calls only: FileHandle's legacy write APIs raise uncatchable
            // ObjC exceptions on ENOSPC/EIO, which would crash-loop the app.
            if echo { Self.writeAll(STDERR_FILENO, line) }
            guard let url else { return }
            var info = stat()
            if stat(url.path, &info) == 0, info.st_size > 2 << 20 {
                let old = url.path + ".1"
                unlink(old)
                rename(url.path, old)
            }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
            guard fd >= 0 else { return }
            Self.writeAll(fd, line)
            close(fd)
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var offset = 0
            while offset < buf.count {
                let n = write(fd, base + offset, buf.count - offset)
                if n < 0 { if errno == EINTR { continue }; return }
                offset += n
            }
        }
    }
}
