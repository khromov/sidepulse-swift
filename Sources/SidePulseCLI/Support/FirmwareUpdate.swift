import CommonCrypto
import Foundation
import SidePulseCore

enum FirmwareVersion {
    /// "v1.1" and "1.1.0" are the same release.
    static func normalize(_ value: String) throws -> String {
        string(try key(value))
    }

    static func string(_ key: [Int]) -> String { key.map(String.init).joined(separator: ".") }

    static func key(_ value: String) throws -> [Int] {
        guard let match = value.wholeMatch(of: #/v?(\d+)\.(\d+)(?:\.(\d+))?/#.asciiOnlyDigits()),
              let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3 ?? "0") else {
            throw FirmwareError("Invalid firmware version: '\(value)'. Use a version such as 1.1.0.")
        }
        return [major, minor, patch]
    }
}

enum FirmwareChecksums {
    static func parse(_ data: Data) throws -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { throw FirmwareError("Invalid firmware checksums.") }
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.allSatisfy(\.isWhitespace) {
            guard let match = line.wholeMatch(of: #/([0-9a-fA-F]{64})  ([A-Za-z0-9_.-]+)/#),
                  result[String(match.2)] == nil else {
                throw FirmwareError("Invalid firmware checksums.")
            }
            result[String(match.2)] = match.1.lowercased()
        }
        return result
    }

    static func verify(_ data: Data, _ expected: String?, name: String) throws {
        guard let expected, sha256(data) == expected else { throw FirmwareError("Firmware checksum mismatch: \(name).") }
    }

    static func sha256(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG($0.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct FirmwarePackage: Equatable {
    static let maxBytes = 4 * 1024 * 1024
    static let files: Set<String> = [FirmwareWriter.fileName, "README.txt", "RELEASE_NOTES.txt", "SHA256SUMS.txt"]

    var model: DeviceModel
    var version: String
    var payload: Data

    static func fileName(model: DeviceModel, version: String) -> String {
        "sidepulse-\(model.rawValue)-\(version)-ota.zip"
    }

    /// The model and version come from the file name; the README's title and the package's own
    /// SHA256SUMS.txt must agree with it before the image is accepted.
    static func read(_ data: Data, fileName: String) throws -> FirmwarePackage {
        guard let match = fileName.wholeMatch(of: #/sidepulse-(dot|pro)-(\d+\.\d+\.\d+)-ota\.zip/#.asciiOnlyDigits()),
              let model = DeviceModel(rawValue: String(match.1)) else {
            throw FirmwareError("Use a customer OTA ZIP named sidepulse-dot-VERSION-ota.zip or sidepulse-pro-VERSION-ota.zip.")
        }
        let version = String(match.2)
        guard data.count <= maxBytes else { throw FirmwareError("Firmware package exceeds the size limit.") }

        var contents: [String: Data] = [:]
        do {
            let archive = try ZipArchive(data)
            let names = archive.entries.map(\.name)
            let prefix = Set(names) == files ? "" : String(fileName.dropLast(".zip".count)) + "/"
            guard names.count == files.count, Set(names) == Set(files.map { prefix + $0 }) else {
                throw FirmwareError("Unexpected files in firmware package.")
            }
            guard archive.entries.reduce(0, { $0 + $1.size }) <= maxBytes else {
                throw FirmwareError("Expanded firmware package exceeds the size limit.")
            }
            for entry in archive.entries {
                contents[String(entry.name.dropFirst(prefix.count))] = try archive.contents(of: entry)
            }
        } catch let error as ZipArchive.Malformed {
            throw FirmwareError("Invalid firmware ZIP: \(error.message).")
        }

        let checksums = try FirmwareChecksums.parse(contents["SHA256SUMS.txt"] ?? Data())
        guard Set(checksums.keys) == files.subtracting(["SHA256SUMS.txt"]) else {
            throw FirmwareError("Firmware package checksums are incomplete.")
        }
        for (name, digest) in checksums.sorted(by: { $0.key < $1.key }) {
            try FirmwareChecksums.verify(contents[name] ?? Data(), digest, name: name)
        }
        let title = Data("\(model.productName) firmware update - version \(version)".utf8)
        guard (contents["README.txt"] ?? Data()).prefix(while: { $0 != 0x0A && $0 != 0x0D }) == title else {
            throw FirmwareError("Firmware package model or version does not match its filename.")
        }
        guard let payload = contents[FirmwareWriter.fileName], !payload.isEmpty else {
            throw FirmwareError("Firmware image is empty.")
        }
        return FirmwarePackage(model: model, version: version, payload: payload)
    }
}

/// Releases are the `firmware/vX.Y.Z` folders of the upstream repository, each with a SHA256SUMS.txt
/// covering its ZIPs.
struct FirmwareReleases {
    static let listingURL = "https://api.github.com/repos/inteliwear/sidepulse/contents/firmware?ref=main"
    static let downloadRoot = "https://raw.githubusercontent.com/inteliwear/sidepulse/main/firmware"

    var download: (URL, Int) throws -> Data

    /// Newest first; a release whose SHA256SUMS.txt has no ZIP for `model` is skipped, unless `version`
    /// asked for exactly that release.
    func loadPackage(model: DeviceModel, version: String?, file: URL?) throws -> FirmwarePackage {
        if let file { return try FirmwarePackage.read(try Self.readLocal(file), fileName: file.lastPathComponent) }
        let releases = try version.map { [try FirmwareVersion.normalize($0)] } ?? publishedVersions()
        for release in releases {
            let name = FirmwarePackage.fileName(model: model, version: release)
            let base = "\(Self.downloadRoot)/v\(release)"
            let checksums = try FirmwareChecksums.parse(try fetch("\(base)/SHA256SUMS.txt", limit: 65_536))
            guard let digest = checksums[name] else { continue }
            let data = try fetch("\(base)/\(name)", limit: FirmwarePackage.maxBytes)
            try FirmwareChecksums.verify(data, digest, name: name)
            return try FirmwarePackage.read(data, fileName: name)
        }
        let requested = try version.map { " for \(try FirmwareVersion.normalize($0))" } ?? ""
        throw FirmwareError("No published \(model.productName) firmware package found\(requested).")
    }

    func publishedVersions() throws -> [String] {
        let data = try fetch(Self.listingURL, limit: 1024 * 1024)
        guard let entries = (try? JSONValue.parse(data))?.arrayValue else {
            throw FirmwareError("The firmware release listing is invalid.")
        }
        let keys = Set(entries.compactMap { entry -> [Int]? in
            guard entry["type"]?.stringValue == "dir", let name = entry["name"]?.stringValue,
                  name.wholeMatch(of: #/v\d+\.\d+\.\d+/#.asciiOnlyDigits()) != nil else { return nil }
            return try? FirmwareVersion.key(name)
        })
        guard !keys.isEmpty else { throw FirmwareError("No published firmware releases found.") }
        return keys.sorted { $1.lexicographicallyPrecedes($0) }.map(FirmwareVersion.string)
    }

    private func fetch(_ address: String, limit: Int) throws -> Data {
        guard let url = URL(string: address) else { throw FirmwareError("Invalid firmware URL: \(address)") }
        let data: Data
        do {
            data = try download(url, limit)
        } catch let error as FirmwareError {
            throw error
        } catch {
            var reason = ErrorText.describe(error)
            if reason.hasSuffix(".") { reason.removeLast() }
            throw FirmwareError("Could not download firmware release data: \(reason). "
                + "You can use --file with a local OTA ZIP.")
        }
        guard data.count <= limit else { throw FirmwareError("Firmware download exceeds the size limit.") }
        return data
    }

    private static func readLocal(_ file: URL) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            return try handle.read(upToCount: FirmwarePackage.maxBytes + 1) ?? Data()
        } catch {
            throw FirmwareError("Could not read \(file.path): \(ErrorText.describe(error))")
        }
    }
}
