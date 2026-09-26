import Foundation

public enum TimeFormat {
    /// Accepts what Python `datetime.fromisoformat` does once a trailing `Z` becomes
    /// `+00:00`, treating naive times as UTC.
    public static func parse(_ string: String) -> Date? {
        var s = Array(string.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard !s.isEmpty else { return nil }
        if let last = s.last, last == UInt8(ascii: "Z") || last == UInt8(ascii: "z") {
            s.removeLast()
            s.append(contentsOf: Array("+00:00".utf8))
        }
        var i = 0
        func digits(_ n: Int) -> Int? {
            guard i + n <= s.count else { return nil }
            var v = 0
            for k in 0..<n {
                let c = s[i + k]
                guard c >= 48 && c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            i += n
            return v
        }
        func peek(_ c: Character) -> Bool { i < s.count && s[i] == c.asciiValue! }
        guard let year = digits(4) else { return nil }
        let month: Int, day: Int
        if peek("-") {
            i += 1
            guard let m = digits(2), peek("-") else { return nil }
            i += 1
            guard let d = digits(2) else { return nil }
            month = m; day = d
        } else {
            guard let m = digits(2), let d = digits(2) else { return nil }
            month = m; day = d
        }
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        var hour = 0, minute = 0, second = 0
        var fraction = 0.0
        var offsetSeconds = 0
        if i < s.count {
            guard peek("T") || peek("t") || peek(" ") else { return nil }
            i += 1
            guard let h = digits(2) else { return nil }
            hour = h
            if peek(":") { i += 1 }
            if let m = digits(2) {
                minute = m
                if peek(":") { i += 1 }
                if let sec = digits(2) {
                    second = sec
                    if peek(".") || peek(",") {
                        i += 1
                        var scale = 0.1
                        var any = false
                        while i < s.count, s[i] >= 48, s[i] <= 57 {
                            fraction += Double(s[i] - 48) * scale
                            scale /= 10
                            i += 1
                            any = true
                        }
                        guard any else { return nil }
                    }
                }
            }
            guard hour <= 24, minute <= 59, second <= 60 else { return nil }
            if i < s.count {
                guard peek("+") || peek("-") else { return nil }
                let sign = peek("-") ? -1 : 1
                i += 1
                guard let oh = digits(2) else { return nil }
                var om = 0, os = 0
                if peek(":") { i += 1 }
                if let m = digits(2) {
                    om = m
                    if peek(":") { i += 1 }
                    if let sec = digits(2) { os = sec }
                }
                offsetSeconds = sign * (oh * 3600 + om * 60 + os)
            }
            guard i == s.count else { return nil }
        }
        // days_from_civil (Howard Hinnant)
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        let epoch = Double(days * 86400 + hour * 3600 + minute * 60 + second - offsetSeconds) + fraction
        return Date(timeIntervalSince1970: epoch)
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
        // Replace the real file behind any symlink chain so dotfile links survive.
        let target = try ensureWritable(url)
        let tmp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).tmp.\(getpid()).\(UInt32.random(in: 0...UInt32.max))")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw posixError("open \(tmp.path)") }
        var ok = false
        defer { if !ok { unlink(tmp.path) } }
        var st = stat()
        if stat(target.path, &st) == 0 { fchmod(fd, st.st_mode & 0o7777) }
        let written = data.withUnsafeBytes { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, base + off, buf.count - off)
                if n < 0 { if errno == EINTR { continue }; return -1 }
                off += n
            }
            return off
        }
        if written != data.count { close(fd); throw posixError("write \(tmp.path)") }
        fsync(fd)
        close(fd)
        guard rename(tmp.path, target.path) == 0 else { throw posixError("rename \(target.path)") }
        ok = true
    }

    /// Refuses read-only files explicitly because rename(2) would bypass the protection;
    /// call it before taking a backup so a refused write leaves nothing behind.
    @discardableResult
    public static func ensureWritable(_ url: URL) throws -> URL {
        let target = try resolvedWriteTarget(url)
        if access(target.path, F_OK) == 0, access(target.path, W_OK) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES),
                          userInfo: [NSLocalizedDescriptionKey: "\(target.path) is read-only; make it writable and try again"])
        }
        return target
    }

    /// Follows dangling symlinks by hand because they point at the file a write should create.
    static func resolvedWriteTarget(_ url: URL) throws -> URL {
        if let real = realpath(url.path, nil) {
            defer { free(real) }
            return URL(fileURLWithPath: String(cString: real))
        }
        var current = url
        for _ in 0..<32 {
            let parent = current.deletingLastPathComponent()
            guard let realParent = realpath(parent.path, nil) else {
                // A missing directory means nothing exists to protect or follow yet;
                // atomicWrite creates it.
                if errno == ENOENT { return current }
                throw posixError("resolve \(parent.path)")
            }
            let dir = URL(fileURLWithPath: String(cString: realParent), isDirectory: true)
            free(realParent)
            let candidate = dir.appendingPathComponent(current.lastPathComponent)
            guard let link = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path) else {
                return candidate
            }
            current = link.hasPrefix("/") ? URL(fileURLWithPath: link) : dir.appendingPathComponent(link)
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ELOOP),
                      userInfo: [NSLocalizedDescriptionKey: "Too many symlinks resolving \(url.path)"])
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
        try fm.copyItem(at: url.resolvingSymlinksInPath(), to: dest)
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
