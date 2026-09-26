import Foundation

public enum LedError: Error, LocalizedError, Equatable {
    /// "No SidePulse Pro or SidePulse Dot device found. Mount the device, or pass --device /path/to/SidePulseDot."
    case noDevice
    /// "Multiple possible devices found. Pass --device with one of:\n  <root>\n  <root>"
    case multipleDevices([String])
    /// Validation message, e.g. "LED program is empty." /
    /// "LED program is 513 bytes; max is 512." / "LED program has 21 lines; max is 20."
    case invalidProgram(String)
    /// Underlying write/read failure description.
    case writeFailed(String)
    /// open() was refused (EPERM/EACCES), e.g. by the macOS privacy permission for
    /// removable volumes. Same text as `writeFailed`.
    case accessDenied(String)
    /// "Unknown animation: <id>"
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

/// Program text helpers (spec led-device §4-5).
public enum LedText {
    public static let maxBytes = 512
    public static let maxLines = 20

    /// `\n` `\r` `\t` `\\` → LF CR TAB backslash; any other backslash is kept literally.
    /// Decode exactly once at the input boundary (CLI arg / stdin).
    ///
    /// Works on Unicode scalars (like Python code points), so a backslash followed
    /// by a combining mark is still seen as a backslash. A lone trailing backslash
    /// is kept.
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

    /// Splits `text` into lines like Python `str.splitlines()` for the common
    /// separators (`\n`, `\r\n`, `\r`). Separators are not included, a trailing
    /// separator does not add an empty line, and "" gives [].
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

    /// Lines as Python `splitlines` for the common separators (\n, \r\n, \r); a
    /// trailing newline does not add a line; "" → 0.
    public static func lineCount(_ text: String) -> Int {
        splitLines(text).count
    }

    /// Throws `.invalidProgram` for "" (empty), > 512 UTF-8 bytes, or > 20 lines
    /// (`max(lineCount, 1)`). The host does not check DSL syntax.
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

/// A mounted SidePulse volume.
public struct DeviceCandidate: Sendable, Equatable, Hashable {
    /// Volume root, e.g. /Volumes/PulseDot.
    public var root: URL
    /// root/LEDS.LED
    public var target: URL
    /// "contains LEDS.LED" or "name matches device".
    public var reason: String

    public init(root: URL, target: URL, reason: String) {
        self.root = root; self.target = target; self.reason = reason
    }

    /// Stable device id = the root path (e.g. "/Volumes/PulseDot").
    public var id: String { root.path }
    /// 2 for Dot/PulseDot names, else 8.
    public var ledCount: Int { DeviceDiscovery.ledCount(forTarget: target) }
    /// "SidePulse Dot" / "SidePulse Pro" / raw volume name.
    public var displayName: String { DeviceDiscovery.displayName(forVolumeName: root.lastPathComponent) }
}

/// Device discovery (spec led-device §2-3, §7).
public enum DeviceDiscovery {
    public static let fileName = "LEDS.LED"
    public static let nameHints = ["sidepulsepro", "sidepulsedot", "pulsedot"]

    /// Volume children that are never devices (the boot volume link and Time Machine).
    static let ignoredVolumeNames: Set<String> = [".timemachine", "Macintosh HD"]

    /// Normalized-name hint → LED count, checked in order (Python `DEVICE_LED_COUNTS`).
    static let ledCountHints: [(hint: String, count: Int)] = [
        ("sidepulsedot", 2),
        ("pulsedot", 2),
        ("sidepulsepro", 8),
    ]

    /// `SIDEPULSE_MOUNT_ROOTS` (colon-separated; set-but-empty = no roots) else [/Volumes].
    ///
    /// Blank entries are skipped and `~` is expanded (using the environment's `HOME`
    /// when present).
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

    /// Children of each root (skip `.timemachine`, `Macintosh HD`, non-local
    /// mounts, non-directories, errors), sorted by lowercased name, deduped by path.
    /// Candidate if `<child>/LEDS.LED` exists or the name matches a hint.
    ///
    /// Directory checks follow symlinks. Unreadable roots count as empty. Network
    /// filesystems (SMB, AFP, NFS…) mounted under a root are skipped without being
    /// looked at: a stat on a dead one blocks until its client gives up.
    public static func discover(roots: [URL]? = nil, fileName: String = DeviceDiscovery.fileName) -> [DeviceCandidate] {
        discover(roots: roots, fileName: fileName, skipping: nonLocalMountPoints())
    }

    /// `discover` that skips the children whose path is in `skipped` (tests).
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

    /// Mount points of non-local filesystems, from the kernel's mount table
    /// (`getfsstat` with MNT_NOWAIT never contacts the filesystems themselves).
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

    /// Lowercase, keep alphanumerics, substring-match any hint.
    public static func isDeviceName(_ name: String) -> Bool {
        let normalized = normalizedName(name)
        return nameHints.contains { contains(normalized, hint: $0) }
    }

    /// Lowercased name with everything but letters and digits removed
    /// ("SidePulse Dot 1" → "sidepulsedot1"). Used for all name matching.
    ///
    /// Filters Unicode scalars like Python's per-code-point `str.isalnum()`
    /// (letters = categories L*, digits = any numeric type), so a combining mark is
    /// dropped instead of hiding the letter it is attached to ("Pulse Dot\u{301}"
    /// still matches).
    public static func normalizedName(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.lowercased().unicodeScalars where isAlphanumeric(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Python `hint in normalized`: a code-point substring test. Searching the
    /// UTF-8 bytes keeps it exact (an ASCII hint can never match inside a
    /// multi-byte sequence), unlike `Character` comparison, where a trailing
    /// grapheme extender would hide the hint's last letter.
    static func contains(_ normalized: String, hint: String) -> Bool {
        let haystack = Array(normalized.utf8)
        let needle = Array(hint.utf8)
        guard needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { start in
            haystack[start..<(start + needle.count)].elementsEqual(needle)
        }
    }

    /// Python `str.isalnum()` for one code point: `isalpha()` (general category
    /// Lu, Ll, Lt, Lm or Lo) or `isnumeric()` (any Unicode numeric type).
    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return scalar.properties.numericType != nil
        }
    }

    /// Normalized parent dir name: contains "sidepulsedot"/"pulsedot" → 2,
    /// "sidepulsepro" → 8, default 8.
    public static func ledCount(forTarget target: URL) -> Int {
        let name = normalizedName(target.deletingLastPathComponent().lastPathComponent)
        return ledCountHints.first { contains(name, hint: $0.hint) }?.count ?? 8
    }

    /// Normalized name containing sidepulsedot/pulsedot → "SidePulse Dot",
    /// sidepulsepro → "SidePulse Pro", else the raw name (or "SidePulse Device" if empty).
    public static func displayName(forVolumeName name: String) -> String {
        let normalized = normalizedName(name)
        if contains(normalized, hint: "sidepulsedot") || contains(normalized, hint: "pulsedot") { return "SidePulse Dot" }
        if contains(normalized, hint: "sidepulsepro") { return "SidePulse Pro" }
        return name.isEmpty ? "SidePulse Device" : name
    }

    /// Explicit `devicePath` (tilde-expanded): if its last component uppercased is
    /// LEDS.LED it is the target, else `path/fileName`. Otherwise discover: 0 →
    /// `.noDevice`, >1 → `.multipleDevices(roots)`, 1 → its target (with fileName).
    ///
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

    /// Python `target_from_device_path`: a path whose last component is `LEDS.LED`
    /// (any case) is already the target; anything else is a folder and gets
    /// `fileName` appended.
    public static func target(forDevicePath path: URL, fileName: String = DeviceDiscovery.fileName) -> URL {
        if path.lastPathComponent.uppercased() == DeviceDiscovery.fileName.uppercased() {
            return path
        }
        return path.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Follows symlinks, like Python `Path.is_dir()`; errors count as "not a directory".
    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// `~` / `~/x` expansion. Uses `home` when given, else Foundation's rules
    /// (which also handle `~user`).
    static func expandTilde(_ path: String, home: String? = nil) -> String {
        if let home, !home.isEmpty, path == "~" || path.hasPrefix("~/") {
            return home + path.dropFirst()
        }
        return (path as NSString).expandingTildeInPath
    }
}

/// Writes to the device (spec led-device §6). NOT atomic on purpose: the firmware
/// watches the LEDS.LED directory entry. open(O_WRONLY|O_CREAT) → truncate →
/// write → fsync (errors ignored) → close; fsync the parent dir when the file was
/// new. Never creates the parent directory (a missing volume must fail).
public enum LedWriter {
    /// Validates then writes the program exactly as given (no trailing newline added).
    ///
    /// `shouldWrite` is asked once the file is open, right before it is changed:
    /// open() can wait a long time (a macOS permission prompt, a slow card) and the
    /// caller may no longer want the write by then. If it says no, the file is
    /// closed untouched and false is returned. An open() refused with EPERM or
    /// EACCES throws `.accessDenied`.
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
                // A regular file never accepts zero bytes of a non-empty write;
                // bail out instead of spinning on a misbehaving mount.
                close(fd)
                throw LedError.writeFailed("Could not write \(path): no bytes were written")
            }
            offset += written
        }
        // Best effort: the bytes are with the OS once the file is closed, so a
        // filesystem that refuses to sync must not fail the write.
        _ = fsync(fd)
        if close(fd) != 0 && errno != EINTR {
            throw posixFailure("Could not write", path)
        }
        if isNew {
            syncDirectory(target.deletingLastPathComponent())
        }
        return true
    }

    /// Current content (UTF-8, lossy) or nil.
    public static func read(_ target: URL) -> String? {
        FileUtil.readText(target)
    }

    /// Flushes a new file's directory entry. Errors are ignored.
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

/// Touches `<volume>/keepalive` at most once per `interval` per path, on a
/// background queue (a hung FAT mount must not block the caller). Thread-safe.
///
/// This keeps a MacBook SD reader from powering off a SidePulse Pro after about
/// three idle minutes. At most one touch per path is in flight: a touch stuck on
/// a hung mount never piles up further threads for that path.
public final class KeepaliveToucher: @unchecked Sendable {
    /// Name of the file touched at the volume root.
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

    /// - Parameter touch: performs one touch (tests inject a recorder). Runs on a
    ///   background queue.
    public init(interval: TimeInterval = 60, touch: @escaping @Sendable (URL) throws -> Void) {
        self.interval = interval
        self.touch = touch
    }

    /// For LEDS.LED/KEEPALIVE/STATUS.TXT targets → sibling `keepalive`, else `target/keepalive`.
    public static func keepaliveFile(for target: URL) -> URL {
        if volumeFileNames.contains(target.lastPathComponent.uppercased()) {
            return target.deletingLastPathComponent().appendingPathComponent(fileName, isDirectory: false)
        }
        return target.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Returns the files whose touch was scheduled now (rate limit recorded before
    /// the attempt, so failures also wait `interval`).
    ///
    /// A `now` earlier than the last touch (wall clock moved back) does not block.
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

    /// Error of the most recently finished touch, nil after a success.
    public var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return storedLastError
    }

    /// Keepalive files whose touch has been running for more than `seconds` (a hung
    /// mount, or open() waiting on a macOS permission prompt).
    func stalledFiles(after seconds: TimeInterval) -> Set<String> {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        return Set(inFlight.filter { now - $0.value > seconds }.keys)
    }

    /// Blocks until scheduled touches finish or `timeout` passes. Returns false on timeout.
    @discardableResult
    public func waitForPendingTouches(timeout: TimeInterval = 5) -> Bool {
        group.wait(timeout: .now() + timeout) == .success
    }

    /// Like `/usr/bin/touch`: creates the file if missing and sets its access and
    /// modification times to now.
    public static func touchFile(_ url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw FileUtil.posixError("touch \(url.path)") }
        defer { close(fd) }
        guard futimens(fd, nil) == 0 else { throw FileUtil.posixError("touch \(url.path)") }
    }
}
