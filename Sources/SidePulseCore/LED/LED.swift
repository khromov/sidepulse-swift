import Foundation

public enum LedError: Error, LocalizedError, Equatable {
    case noDevice
    case multipleDevices([String])
    case invalidProgram(String)
    case writeFailed(String)
    /// open() was refused (EPERM/EACCES), typically by the macOS removable-volume privacy permission.
    case accessDenied(String)
    case unknownAnimation(String)

    public var errorDescription: String? {
        switch self {
        case .noDevice:
            return "No SidePulse Pro or SidePulse Dot device found. Mount the device, or pass --device /path/to/SidePulseDot."
        case .multipleDevices(let roots):
            return "Multiple possible devices found. Pass --device with one of:\n" + roots.map { "  \($0)" }.joined(separator: "\n")
        case .invalidProgram(let m), .writeFailed(let m), .accessDenied(let m): return m
        case .unknownAnimation(let id): return "Unknown animation: \(id)"
        }
    }
}

public enum LedText {
    public static let maxBytes = 512
    public static let maxLines = 20

    /// Decode exactly once at the input boundary; it scans Unicode scalars (like Python code
    /// points) so a backslash before a combining mark still counts.
    public static func decodeEscapes(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\\", index + 1 < scalars.count else {
                output.append(scalar)
                index += 1
                continue
            }
            switch scalars[index + 1] {
            case "n": output.append("\n"); index += 2
            case "r": output.append("\r"); index += 2
            case "t": output.append("\t"); index += 2
            case "\\": output.append("\\"); index += 2
            default: output.append(scalar); index += 1
            }
        }
        return String(output)
    }

    /// Matches Python `str.splitlines()` for the common separators (`\n`, `\r\n`, `\r`).
    public static func splitLines(_ text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        var lines: [String] = []
        var start = 0
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\n" || scalar == "\r" else {
                index += 1
                continue
            }
            lines.append(String(String.UnicodeScalarView(scalars[start..<index])))
            let isCRLF = scalar == "\r" && index + 1 < scalars.count && scalars[index + 1] == "\n"
            index += isCRLF ? 2 : 1
            start = index
        }
        if start < scalars.count {
            lines.append(String(String.UnicodeScalarView(scalars[start...])))
        }
        return lines
    }

    public static func lineCount(_ text: String) -> Int {
        splitLines(text).count
    }

    /// The host checks only size limits, never DSL syntax.
    public static func validate(_ program: String) throws {
        guard !program.isEmpty else {
            throw LedError.invalidProgram("LED program is empty.")
        }
        let byteCount = program.utf8.count
        guard byteCount <= maxBytes else {
            throw LedError.invalidProgram("LED program is \(byteCount) bytes; max is \(maxBytes).")
        }
        let lines = max(lineCount(program), 1)
        guard lines <= maxLines else {
            throw LedError.invalidProgram("LED program has \(lines) lines; max is \(maxLines).")
        }
    }
}

public struct DeviceCandidate: Sendable, Equatable, Hashable {
    public var root: URL
    public var target: URL
    public var reason: String

    public init(root: URL, target: URL, reason: String) {
        self.root = root; self.target = target; self.reason = reason
    }

    public var id: String { root.path }
    public var ledCount: Int { DeviceDiscovery.ledCount(forTarget: target) }
    public var displayName: String { DeviceDiscovery.displayName(forVolumeName: root.lastPathComponent) }
}

public enum DeviceDiscovery {
    public static let fileName = "LEDS.LED"
    public static let nameHints = ["sidepulsepro", "sidepulsedot", "pulsedot"]

    static let ignoredVolumeNames: Set<String> = [".timemachine", "Macintosh HD"]

    static let ledCountHints: [(hint: String, count: Int)] = [
        ("sidepulsedot", 2),
        ("pulsedot", 2),
        ("sidepulsepro", 8),
    ]

    public static func mountRoots(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        guard let configured = environment["SIDEPULSE_MOUNT_ROOTS"] else {
            return [URL(fileURLWithPath: "/Volumes", isDirectory: true)]
        }
        return configured
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { URL(fileURLWithPath: expandTilde($0, home: environment["HOME"]), isDirectory: true) }
    }

    /// Network mounts under a root are skipped unexamined because a stat on a dead one blocks until
    /// its client gives up.
    public static func discover(roots: [URL]? = nil, fileName: String = DeviceDiscovery.fileName) -> [DeviceCandidate] {
        discover(roots: roots, fileName: fileName, skipping: nonLocalMountPoints())
    }

    static func discover(roots: [URL]?, fileName: String, skipping skipped: Set<String>) -> [DeviceCandidate] {
        let fm = FileManager.default
        var seen = Set<String>()
        var candidates: [DeviceCandidate] = []
        for root in roots ?? mountRoots() {
            guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            let volumeNames = names
                .filter { name in
                    let child = root.appendingPathComponent(name, isDirectory: false)
                    return !ignoredVolumeNames.contains(name) && !skipped.contains(child.path) && isDirectory(child)
                }
                .sorted { ($0.lowercased(), $0) < ($1.lowercased(), $1) }
            for name in volumeNames {
                let volume = root.appendingPathComponent(name, isDirectory: true)
                guard seen.insert(volume.path).inserted else { continue }
                let target = self.target(forDevicePath: volume, fileName: fileName)
                if fm.fileExists(atPath: target.path) {
                    candidates.append(DeviceCandidate(root: volume, target: target,
                                                      reason: "contains \(target.lastPathComponent)"))
                } else if isDeviceName(name) {
                    candidates.append(DeviceCandidate(root: volume, target: target, reason: "name matches device"))
                }
            }
        }
        return candidates
    }

    /// `MNT_NOWAIT` reads the kernel's mount table without contacting the filesystems themselves.
    static func nonLocalMountPoints() -> Set<String> {
        let capacity = Int(getfsstat(nil, 0, MNT_NOWAIT)) + 8
        guard capacity > 8 else { return [] }
        let buffer = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: statfs(), count: capacity)
        let count = Int(getfsstat(buffer, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT))
        var points = Set<String>()
        for index in 0..<max(0, count) where buffer[index].f_flags & UInt32(MNT_LOCAL) == 0 {
            var name = buffer[index].f_mntonname
            points.insert(withUnsafeBytes(of: &name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) })
        }
        return points
    }

    public static func isDeviceName(_ name: String) -> Bool {
        let normalized = normalizedName(name)
        return nameHints.contains { contains(normalized, hint: $0) }
    }

    /// Filters Unicode scalars like Python's per-code-point `str.isalnum()`, so a combining mark is
    /// dropped instead of hiding the letter it is attached to.
    public static func normalizedName(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.lowercased().unicodeScalars where isAlphanumeric(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Compares UTF-8 bytes because `Character` comparison would let a trailing grapheme extender
    /// hide the hint's last letter.
    static func contains(_ normalized: String, hint: String) -> Bool {
        let haystack = Array(normalized.utf8)
        let needle = Array(hint.utf8)
        guard needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { start in
            haystack[start..<(start + needle.count)].elementsEqual(needle)
        }
    }

    /// Python `str.isalnum()` for one code point.
    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return scalar.properties.numericType != nil
        }
    }

    public static func ledCount(forTarget target: URL) -> Int {
        let name = normalizedName(target.deletingLastPathComponent().lastPathComponent)
        return ledCountHints.first { contains(name, hint: $0.hint) }?.count ?? 8
    }

    public static func displayName(forVolumeName name: String) -> String {
        let normalized = normalizedName(name)
        if contains(normalized, hint: "sidepulsedot") || contains(normalized, hint: "pulsedot") { return "SidePulse Dot" }
        if contains(normalized, hint: "sidepulsepro") { return "SidePulse Pro" }
        return name.isEmpty ? "SidePulse Device" : name
    }

    /// No existence check is made for an explicit path; the write reports it.
    public static func resolveTarget(devicePath: String?, fileName: String = DeviceDiscovery.fileName,
                                     roots: [URL]? = nil) throws -> URL {
        if let devicePath {
            return target(forDevicePath: URL(fileURLWithPath: expandTilde(devicePath)), fileName: fileName)
        }
        let candidates = discover(roots: roots, fileName: fileName)
        guard !candidates.isEmpty else { throw LedError.noDevice }
        guard candidates.count == 1 else { throw LedError.multipleDevices(candidates.map(\.root.path)) }
        return candidates[0].target
    }

    public static func target(forDevicePath path: URL, fileName: String = DeviceDiscovery.fileName) -> URL {
        if path.lastPathComponent.uppercased() == DeviceDiscovery.fileName.uppercased() {
            return path
        }
        return path.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Follows symlinks, like Python `Path.is_dir()`.
    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func expandTilde(_ path: String, home: String? = nil) -> String {
        if let home, !home.isEmpty, path == "~" || path.hasPrefix("~/") {
            return home + path.dropFirst()
        }
        return (path as NSString).expandingTildeInPath
    }
}

/// Writes in place, not atomically, because the firmware watches the LEDS.LED directory entry, and
/// never creates the parent directory so a missing volume fails.
public enum LedWriter {
    /// `shouldWrite` is asked after open() and before truncating, because open() can block on a
    /// macOS permission prompt or a slow card and the caller may no longer want the write.
    @discardableResult
    public static func write(_ program: String, to target: URL, shouldWrite: () -> Bool = { true }) throws -> Bool {
        try LedText.validate(program)
        let path = target.path
        let isNew = !FileManager.default.fileExists(atPath: path)

        // No O_TRUNC: the file is truncated only after `shouldWrite` agreed.
        let fd = open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            if errno == EPERM || errno == EACCES { throw LedError.accessDenied(posixMessage("Could not open", path)) }
            throw posixFailure("Could not open", path)
        }
        guard shouldWrite() else {
            close(fd)
            return false
        }
        // An empty file (or a FIFO) has nothing to truncate.
        var info = stat()
        if fstat(fd, &info) != 0 || info.st_size > 0, ftruncate(fd, 0) != 0 {
            let failure = posixFailure("Could not truncate", path)
            close(fd)
            throw failure
        }

        let bytes = Array(program.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                let failure = posixFailure("Could not write", path)
                close(fd)
                throw failure
            }
            if written == 0 {
                // Bail out instead of spinning on a misbehaving mount that accepts zero bytes.
                close(fd)
                throw LedError.writeFailed("Could not write \(path): no bytes were written")
            }
            offset += written
        }
        // The bytes are with the OS once the file is closed, so a filesystem that refuses to sync
        // must not fail the write.
        _ = fsync(fd)
        if close(fd) != 0 && errno != EINTR {
            throw posixFailure("Could not write", path)
        }
        if isNew {
            syncDirectory(target.deletingLastPathComponent())
        }
        return true
    }

    public static func read(_ target: URL) -> String? {
        FileUtil.readText(target)
    }

    private static func syncDirectory(_ directory: URL) {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }

    private static func posixFailure(_ action: String, _ path: String) -> LedError {
        .writeFailed(posixMessage(action, path))
    }

    private static func posixMessage(_ action: String, _ path: String) -> String {
        "\(action) \(path): \(String(cString: strerror(errno)))"
    }
}

/// Keeps a MacBook SD reader from powering off a SidePulse Pro after about three idle minutes.
/// Touches run in the background with at most one in flight per path, so a hung FAT mount neither
/// blocks the caller nor piles up threads.
public final class KeepaliveToucher: @unchecked Sendable {
    public static let fileName = "keepalive"
    /// Targets that sit at the volume root, so their sibling is touched.
    static let volumeFileNames: Set<String> = [DeviceDiscovery.fileName.uppercased(), "KEEPALIVE", "STATUS.TXT"]

    public let interval: TimeInterval
    private let touch: @Sendable (URL) throws -> Void
    private let lock = NSLock()
    private var lastTouch: [String: Date] = [:]
    /// Keepalive file → system uptime when its running touch was scheduled.
    private var inFlight: [String: TimeInterval] = [:]
    private var storedLastError: String?
    private let group = DispatchGroup()
    private let queue = DispatchQueue(label: "sidepulse.keepalive", qos: .utility, attributes: .concurrent)

    public convenience init(interval: TimeInterval = 60) {
        self.init(interval: interval, touch: { try KeepaliveToucher.touchFile($0) })
    }

    public init(interval: TimeInterval = 60, touch: @escaping @Sendable (URL) throws -> Void) {
        self.interval = interval
        self.touch = touch
    }

    public static func keepaliveFile(for target: URL) -> URL {
        if volumeFileNames.contains(target.lastPathComponent.uppercased()) {
            return target.deletingLastPathComponent().appendingPathComponent(fileName, isDirectory: false)
        }
        return target.appendingPathComponent(fileName, isDirectory: false)
    }

    /// The rate limit is recorded before the attempt so failures also wait `interval`, and a wall
    /// clock that moved back does not block.
    @discardableResult
    public func poke(targets: [URL], now: Date = Date()) -> [URL] {
        var scheduled: [URL] = []
        let started = ProcessInfo.processInfo.systemUptime
        lock.lock()
        for target in targets {
            let file = Self.keepaliveFile(for: target)
            let key = file.path
            if let last = lastTouch[key] {
                let elapsed = now.timeIntervalSince(last)
                if elapsed >= 0 && elapsed < interval { continue }
            }
            lastTouch[key] = now
            guard inFlight[key] == nil else { continue }
            inFlight[key] = started
            scheduled.append(file)
        }
        lock.unlock()

        for file in scheduled {
            queue.async(group: group) { [self] in
                var failure: String?
                do { try touch(file) } catch { failure = "\(file.path): \(error.localizedDescription)" }
                lock.lock()
                inFlight[file.path] = nil
                storedLastError = failure
                lock.unlock()
            }
        }
        return scheduled
    }

    public var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return storedLastError
    }

    func stalledFiles(after seconds: TimeInterval) -> Set<String> {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        return Set(inFlight.filter { now - $0.value > seconds }.keys)
    }

    @discardableResult
    public func waitForPendingTouches(timeout: TimeInterval = 5) -> Bool {
        group.wait(timeout: .now() + timeout) == .success
    }

    public static func touchFile(_ url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw FileUtil.posixError("touch \(url.path)") }
        defer { close(fd) }
        guard futimens(fd, nil) == 0 else { throw FileUtil.posixError("touch \(url.path)") }
    }
}
