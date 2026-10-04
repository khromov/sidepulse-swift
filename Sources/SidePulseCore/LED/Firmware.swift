import Darwin
import Foundation

/// The device firmware generates `STATUS.TXT` afresh on every read of it.
public enum DeviceStatusFile {
    public static let fileName = "STATUS.TXT"
    public static let keepaliveReadLimit = 4096
    public static let statusReadLimit = 65_536
    static let blockSize = 512

    public static func url(forVolume root: URL) -> URL {
        root.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Reads past the page cache so every read reaches the card: a cached read neither keeps an SD
    /// reader awake nor shows firmware installed since the volume was mounted.
    public static func read(_ url: URL, limit: Int = keepaliveReadLimit) throws -> Data {
        guard let fd = try LedWriter.openRegularFile(url.path, flags: O_RDONLY) else {
            errno = ENOENT
            throw FileUtil.posixError("Could not open \(url.path)")
        }
        defer { close(fd) }
        guard fcntl(fd, F_NOCACHE, 1) != -1, fcntl(fd, F_RDAHEAD, 0) != -1 else {
            throw FileUtil.posixError("Could not bypass the cache for \(url.path)")
        }
        try invalidateCache(fd, path: url.path)

        // Despite F_NOCACHE, a read into an unaligned buffer goes through the cache.
        var allocated: UnsafeMutableRawPointer?
        let failure = posix_memalign(&allocated, Int(getpagesize()), Int(getpagesize()))
        guard failure == 0, let buffer = allocated else {
            errno = failure
            throw FileUtil.posixError("Could not read \(url.path)")
        }
        defer { free(buffer) }

        var data = Data()
        while data.count < limit {
            let count = pread(fd, buffer, blockSize, off_t(data.count))
            if count < 0 {
                if errno == EINTR { continue }
                throw FileUtil.posixError("Could not read \(url.path)")
            }
            data.append(buffer.assumingMemoryBound(to: UInt8.self), count: count)
            if count < blockSize { break }
        }
        return data
    }

    /// F_NOCACHE does not evict pages that an earlier cached read (Finder, `cat`) left behind.
    private static func invalidateCache(_ fd: Int32, path: String) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw FileUtil.posixError("Could not read \(path)") }
        let size = Int(info.st_size)
        guard size > 0 else { return }
        guard let mapping = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), mapping != MAP_FAILED else {
            throw FileUtil.posixError("Could not map \(path)")
        }
        defer { munmap(mapping, size) }
        // The mapping is never touched, which would read the pages back in.
        guard msync(mapping, size, MS_INVALIDATE) == 0 else {
            throw FileUtil.posixError("Could not drop the cached copy of \(path)")
        }
    }
}

public enum DeviceModel: String, Sendable, Equatable, CaseIterable {
    case dot, pro

    public var productName: String { self == .dot ? "SidePulse Dot" : "SidePulse Pro" }
}

public struct FirmwareError: Error, LocalizedError, Equatable {
    public var message: String

    public init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }
}

/// The model and firmware a device reports in `STATUS.TXT`.
public struct FirmwareInfo: Sendable, Equatable {
    public static let unknownVersion = "unknown"

    public var model: DeviceModel
    public var version: String
    public var serial: String

    public init(model: DeviceModel, version: String, serial: String) {
        self.model = model; self.version = version; self.serial = serial
    }

    /// Nil when the text names neither model or both; an older Pro that reports no release
    /// version gets `unknownVersion`.
    public init?(statusText data: Data) {
        var fields: [String: String] = [:]
        let text = String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let gap = trimmed.firstIndex(where: \.isWhitespace) else { continue }
            fields[String(trimmed[..<gap])] = trimmed[gap...].trimmingCharacters(in: .whitespaces)
        }
        let dot = fields["app_version"] != nil || (fields["app_build"] != nil && fields["fw_state"] != nil)
        let pro = fields["release_version"] != nil || (fields["firmware_version"] != nil && fields["firmware_slot"] != nil)
        guard dot != pro else { return nil }
        model = dot ? .dot : .pro
        version = fields[dot ? "app_version" : "release_version"] ?? Self.unknownVersion
        serial = fields["serial"] ?? "unassigned"
    }

    public static func read(volume root: URL) throws -> FirmwareInfo {
        let file = DeviceStatusFile.url(forVolume: root)
        let data = try DeviceStatusFile.read(file, limit: DeviceStatusFile.statusReadLimit)
        guard let info = FirmwareInfo(statusText: data) else {
            throw FirmwareError("Cannot identify a SidePulse Dot or Pro from \(file.path).")
        }
        return info
    }
}

public enum FirmwareWriter {
    public static let fileName = "FIRMWARE.BIN"

    /// Unlike a LEDS.LED write, a failed sync fails the transfer, because the device applies the image
    /// once it has landed.
    public static func write(_ payload: Data, toVolume root: URL) throws {
        let target = root.appendingPathComponent(fileName, isDirectory: false)
        let isNew = !FileManager.default.fileExists(atPath: target.path)
        guard let fd = try LedWriter.openRegularFile(target.path, flags: O_WRONLY | O_CREAT) else {
            throw FirmwareError("Could not open \(target.path)")
        }
        guard ftruncate(fd, 0) == 0, FileUtil.writeAll(fd, payload), fsync(fd) == 0 else {
            let failure = FileUtil.posixError("Could not write \(target.path)")
            close(fd)
            throw transferFailure(failure)
        }
        if close(fd) != 0 && errno != EINTR {
            throw transferFailure(FileUtil.posixError("Could not write \(target.path)"))
        }
        if isNew {
            let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if directory >= 0 {
                _ = fsync(directory)
                close(directory)
            }
        }
    }

    private static func transferFailure(_ error: NSError) -> FirmwareError {
        FirmwareError("Firmware transfer did not finish: \(error.localizedDescription). Keep the device connected "
            + "for at least 10 seconds, then reconnect it and check its version before retrying.")
    }
}
