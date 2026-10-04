import Compression
import Foundation

/// Reads the small, single-disk archives firmware ships in; ZIP64, encrypted entries and methods
/// other than stored and deflate are refused.
struct ZipArchive {
    struct Entry: Equatable {
        var name: String
        var method: Int
        var compressedSize: Int
        var size: Int
        var localHeaderOffset: Int
    }

    struct Malformed: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    let entries: [Entry]
    private let bytes: [UInt8]
    private let directoryOffset: Int

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        self.bytes = bytes
        guard let end = Self.endRecord(bytes) else { throw Malformed(message: "no end of central directory") }
        guard Self.u16(bytes, end + 4) == 0, Self.u16(bytes, end + 6) == 0,
              Self.u16(bytes, end + 8) == Self.u16(bytes, end + 10) else {
            throw Malformed(message: "multi-disk archives are not supported")
        }
        let count = Self.u16(bytes, end + 10)
        let directorySize = Self.u32(bytes, end + 12)
        let directoryOffset = Self.u32(bytes, end + 16)
        guard count != 0xFFFF, directoryOffset != 0xFFFF_FFFF, directoryOffset + directorySize <= end else {
            throw Malformed(message: "bad central directory")
        }
        self.directoryOffset = directoryOffset

        var entries: [Entry] = []
        var offset = directoryOffset
        for _ in 0..<count {
            guard offset + 46 <= end, Self.u32(bytes, offset) == 0x0201_4B50 else {
                throw Malformed(message: "bad central directory entry")
            }
            let nameLength = Self.u16(bytes, offset + 28)
            let next = offset + 46 + nameLength + Self.u16(bytes, offset + 30) + Self.u16(bytes, offset + 32)
            guard next <= end, let name = String(bytes: bytes[(offset + 46)..<(offset + 46 + nameLength)], encoding: .utf8) else {
                throw Malformed(message: "bad entry name")
            }
            guard Self.u16(bytes, offset + 8) & 1 == 0 else { throw Malformed(message: "encrypted entries are not supported") }
            entries.append(Entry(name: name, method: Self.u16(bytes, offset + 10),
                                 compressedSize: Self.u32(bytes, offset + 20), size: Self.u32(bytes, offset + 24),
                                 localHeaderOffset: Self.u32(bytes, offset + 42)))
            offset = next
        }
        self.entries = entries
    }

    func contents(of entry: Entry) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + 30 <= directoryOffset, Self.u32(bytes, header) == 0x0403_4B50 else {
            throw Malformed(message: "bad local header for \(entry.name)")
        }
        let start = header + 30 + Self.u16(bytes, header + 26) + Self.u16(bytes, header + 28)
        let end = start + entry.compressedSize
        guard end <= directoryOffset else { throw Malformed(message: "\(entry.name) runs past the archive") }
        let stored = bytes[start..<end]
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.size else { throw Malformed(message: "bad size for \(entry.name)") }
            return Data(stored)
        case 8:
            return try Self.inflate(Array(stored), size: entry.size, name: entry.name)
        default:
            throw Malformed(message: "unsupported compression method \(entry.method) for \(entry.name)")
        }
    }

    /// One byte of spare room tells a stream longer than its declared size from an exact one, so a lying
    /// header can never expand past `size`.
    private static func inflate(_ input: [UInt8], size: Int, name: String) throws -> Data {
        var output = [UInt8](repeating: 0, count: size + 1)
        let written = input.withUnsafeBufferPointer { source -> Int in
            guard let base = source.baseAddress else { return 0 }
            return compression_decode_buffer(&output, output.count, base, source.count, nil, COMPRESSION_ZLIB)
        }
        guard written == size else { throw Malformed(message: "bad compressed data for \(name)") }
        return Data(output.prefix(size))
    }

    /// The record sits in the last 22 bytes plus at most a 64 KiB comment.
    private static func endRecord(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        for offset in stride(from: bytes.count - 22, through: lowest, by: -1)
        where u32(bytes, offset) == 0x0605_4B50 && offset + 22 + u16(bytes, offset + 20) <= bytes.count {
            return offset
        }
        return nil
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> Int {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> Int {
        u16(bytes, offset) | u16(bytes, offset + 2) << 16
    }
}
