import Foundation
import XCTest
@testable import SidePulseCLI
import SidePulseCore

/// Writes the subset of ZIP that `ZipArchive` reads: no CRCs, since the package checksums cover the contents.
enum TestZip {
    static func make(_ files: [(name: String, data: Data)], deflate: Bool = true) -> Data {
        var out = Data()
        var directory = Data()
        let method = deflate ? 8 : 0
        for (name, data) in files {
            let stored = deflate ? (try! (data as NSData).compressed(using: .zlib) as Data) : data
            let nameBytes = Data(name.utf8)
            let offset = out.count
            append(&out, u32: 0x0403_4B50, u16s: [20, 0, method, 0, 0])
            append(&out, u32s: [0, stored.count, data.count], u16s: [nameBytes.count, 0])
            out.append(nameBytes)
            out.append(stored)
            append(&directory, u32: 0x0201_4B50, u16s: [20, 20, 0, method, 0, 0])
            append(&directory, u32s: [0, stored.count, data.count], u16s: [nameBytes.count, 0, 0, 0, 0])
            append(&directory, u32s: [0, offset], u16s: [])
            directory.append(nameBytes)
        }
        let directoryOffset = out.count
        out.append(directory)
        append(&out, u32: 0x0605_4B50, u16s: [0, 0, files.count, files.count])
        append(&out, u32s: [directory.count, directoryOffset], u16s: [0])
        return out
    }

    private static func append(_ data: inout Data, u32: Int, u16s: [Int]) {
        append(&data, u32s: [u32], u16s: u16s)
    }

    private static func append(_ data: inout Data, u32s: [Int], u16s: [Int]) {
        for value in u32s { data.append(contentsOf: [0, 8, 16, 24].map { UInt8(value >> $0 & 0xFF) }) }
        for value in u16s { data.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]) }
    }
}

final class CLIFirmwareTests: XCTestCase {
    private var harness: CLIHarness!
    private var mounts: URL!
    private var pro: URL!

    override func setUp() {
        super.setUp()
        mounts = CLIHarness.makeShortTempDir()
        harness = CLIHarness(variables: ["SIDEPULSE_MOUNT_ROOTS": mounts.path])
        pro = makeDevice("SidePulse", .pro)
    }

    override func tearDown() {
        harness = nil
        try? FileManager.default.removeItem(at: mounts)
        super.tearDown()
    }

    @discardableResult
    private func makeDevice(_ name: String, _ model: DeviceModel, version: String = "1.0.5") -> URL {
        let device = mounts.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        let field = model == .dot ? "app_version" : "release_version"
        try? (Data("\(field) \(version)\nserial SP-123\n".utf8) + Data(repeating: 0, count: 100))
            .write(to: device.appendingPathComponent("STATUS.TXT"))
        return device
    }

    static func packageFiles(_ model: DeviceModel = .pro, _ version: String = "1.1.0",
                             tamper: Bool = false) -> [(name: String, data: Data)] {
        var files: [(name: String, data: Data)] = [
            ("FIRMWARE.BIN", Data("encrypted firmware payload".utf8)),
            ("README.txt", Data("\(model.productName) firmware update - version \(version)\nFor this model only.\n".utf8)),
            ("RELEASE_NOTES.txt", Data("# \(model.productName) \(version)\n".utf8)),
        ]
        let sums = files.map { "\(FirmwareChecksums.sha256($0.data))  \($0.name)\n" }.joined()
        files.append(("SHA256SUMS.txt", Data(sums.utf8)))
        if tamper { files[0].data = Data("corrupt firmware".utf8) }
        return files
    }

    static func package(_ model: DeviceModel = .pro, _ version: String = "1.1.0", nested: Bool = true,
                        tamper: Bool = false, extra: [(name: String, data: Data)] = []) -> Data {
        let prefix = nested ? "sidepulse-\(model.rawValue)-\(version)-ota/" : ""
        let files = packageFiles(model, version, tamper: tamper).map { (name: prefix + $0.name, data: $0.data) }
        return TestZip.make(files + extra)
    }

    private func writePackage(_ model: DeviceModel = .pro, _ version: String = "1.1.0", tamper: Bool = false) -> URL {
        let url = harness.root.appendingPathComponent(FirmwarePackage.fileName(model: model, version: version))
        try? Self.package(model, version, tamper: tamper).write(to: url)
        return url
    }

    @discardableResult
    private func upgrade(_ package: URL, _ extra: String...) -> Int32 {
        harness.run(["firmware", "upgrade", "--device", pro.path, "--file", package.path] + extra)
    }

    private var image: URL { pro.appendingPathComponent("FIRMWARE.BIN") }

    // MARK: version

    func testVersionListsEveryDeviceAsTextAndJSON() throws {
        makeDevice("PulseDot", .dot, version: "1.1.0")
        XCTAssertEqual(harness.run(["firmware", "version"]), ExitCode.ok)
        XCTAssertEqual(harness.stdout.text, "SidePulse Dot: 1.1.0  (\(mounts.path)/PulseDot, serial SP-123)\n"
            + "SidePulse Pro: 1.0.5  (\(mounts.path)/SidePulse, serial SP-123)\n")

        let json = CLIHarness(variables: ["SIDEPULSE_MOUNT_ROOTS": mounts.path])
        XCTAssertEqual(json.run(["firmware", "version", "--json"]), ExitCode.ok)
        let rows = try XCTUnwrap(JSONValue.parse(json.stdout.text).arrayValue)
        XCTAssertEqual(rows.map { [$0["model"]?.stringValue, $0["version"]?.stringValue] },
                       [["SidePulse Dot", "1.1.0"], ["SidePulse Pro", "1.0.5"]])
        XCTAssertEqual(rows.first?["serial"]?.stringValue, "SP-123")
        XCTAssertEqual(rows.first?["device"]?.stringValue, mounts.appendingPathComponent("PulseDot").path)
    }

    func testExplicitDeviceUsesStatusNotTheVolumeName() {
        let renamed = makeDevice("Untitled", .pro, version: "1.0.7")
        XCTAssertEqual(harness.run(["firmware", "version", "--device", renamed.appendingPathComponent("LEDS.LED").path]),
                       ExitCode.ok)
        XCTAssertEqual(harness.stdout.text, "SidePulse Pro: 1.0.7  (\(renamed.path), serial SP-123)\n")
    }

    func testVolumesThatAreNotSidePulseDevicesAreSkipped() throws {
        try FileManager.default.createDirectory(at: mounts.appendingPathComponent("Camera"), withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: mounts.appendingPathComponent("Camera/STATUS.TXT"))
        XCTAssertEqual(harness.run(["firmware", "version"]), ExitCode.ok)
        XCTAssertEqual(harness.stdout.text.split(separator: "\n").count, 1)

        let explicit = CLIHarness()
        XCTAssertEqual(explicit.run(["firmware", "version", "--device", mounts.appendingPathComponent("Camera").path]),
                       ExitCode.failure)
        XCTAssertTrue(explicit.stderr.text.contains("Cannot identify a SidePulse Dot or Pro"), explicit.stderr.text)
    }

    func testUsageErrors() {
        for arguments in [["firmware"], ["firmware", "flash"], ["firmware", "upgrade", "--json"],
                          ["firmware", "version", "--dry-run"], ["firmware", "version", "--file", "x.zip"],
                          ["firmware", "upgrade", "--version", "1.1.0", "--file", "x.zip"]] {
            let fresh = CLIHarness(variables: ["SIDEPULSE_MOUNT_ROOTS": mounts.path])
            XCTAssertEqual(fresh.run(arguments), ExitCode.usage, "\(arguments)")
            XCTAssertTrue(fresh.stderr.text.hasPrefix("usage: sidepulse firmware"), fresh.stderr.text)
        }
    }

    // MARK: upgrade: device selection

    func testMissingDeviceFailsWithoutDownloading() {
        let empty = CLIHarness(variables: ["SIDEPULSE_MOUNT_ROOTS": harness.root.appendingPathComponent("missing").path])
        XCTAssertEqual(empty.run(["firmware", "upgrade"]), ExitCode.failure)
        XCTAssertTrue(empty.stderr.text.contains("No mounted SidePulse device found"), empty.stderr.text)
    }

    func testMultipleDevicesNeedSelectionBeforeDownloading() {
        makeDevice("PulseDot", .dot)
        XCTAssertEqual(harness.run(["firmware", "upgrade"]), ExitCode.failure)
        XCTAssertTrue(harness.stderr.text.contains("Select one with --device:\n  \(mounts.path)/PulseDot"), harness.stderr.text)
        XCTAssertFalse(harness.stderr.text.contains("unexpected download"))
    }

    // MARK: upgrade: local packages

    func testUpgradeWritesTheImageAndKeepsPrograms() throws {
        for name in ["LEDS.LED", "INIT.LED"] {
            try Data("existing program".utf8).write(to: pro.appendingPathComponent(name))
        }
        try Data(String(repeating: "old firmware with a longer payload", count: 100).utf8).write(to: image)
        XCTAssertEqual(upgrade(writePackage()), ExitCode.ok, harness.stderr.text)
        XCTAssertEqual(try Data(contentsOf: image), Data("encrypted firmware payload".utf8))
        for name in ["LEDS.LED", "INIT.LED"] {
            XCTAssertEqual(try Data(contentsOf: pro.appendingPathComponent(name)), Data("existing program".utf8))
        }
        XCTAssertEqual(harness.stdout.text.split(separator: "\n").first, "SidePulse Pro: firmware 1.0.5 (\(pro.path))")
        XCTAssertTrue(harness.stdout.text.contains("Firmware 1.1.0 transferred."), harness.stdout.text)
        XCTAssertTrue(harness.stdout.text.contains("sidepulse firmware version"), harness.stdout.text)
    }

    func testDryRunVerifiesWithoutWriting() {
        XCTAssertEqual(upgrade(writePackage(), "--dry-run"), ExitCode.ok, harness.stderr.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
        XCTAssertTrue(harness.stdout.text.contains("Would upgrade SidePulse Pro from 1.0.5 to 1.1.0. Package verified"))
    }

    func testWrongModelOrCorruptPackageNeverWrites() {
        XCTAssertEqual(upgrade(writePackage(.dot)), ExitCode.failure)
        XCTAssertTrue(harness.stderr.text.contains("This ZIP is for SidePulse Dot, but the device is SidePulse Pro."))
        XCTAssertEqual(upgrade(writePackage(tamper: true)), ExitCode.failure)
        XCTAssertTrue(harness.stderr.text.contains("Firmware checksum mismatch: FIRMWARE.BIN."), harness.stderr.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
    }

    func testSameVersionIsANoOpAndDowngradeIsRefused() {
        XCTAssertEqual(upgrade(writePackage(.pro, "1.0.5")), ExitCode.ok)
        XCTAssertTrue(harness.stdout.text.contains("SidePulse Pro is already on firmware 1.0.5."))
        XCTAssertEqual(upgrade(writePackage(.pro, "1.0.4")), ExitCode.failure)
        XCTAssertTrue(harness.stderr.text.contains("older than installed version 1.0.5; downgrade refused"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
    }

    func testUnknownInstalledVersionCanBeUpgraded() throws {
        try Data("firmware_version 12345\nfirmware_slot A\n".utf8).write(to: pro.appendingPathComponent("STATUS.TXT"))
        XCTAssertEqual(upgrade(writePackage(), "--dry-run"), ExitCode.ok, harness.stderr.text)
        XCTAssertTrue(harness.stdout.text.contains("from unknown to 1.1.0"))
    }

    func testDeviceIsCheckedAgainAfterTheDownload() throws {
        let data = Self.package()
        let sums = "\(FirmwareChecksums.sha256(data))  sidepulse-pro-1.1.0-ota.zip\n"
        let status = pro.appendingPathComponent("STATUS.TXT")
        harness.env.download = { url, _ in
            if url.lastPathComponent == "SHA256SUMS.txt" { return Data(sums.utf8) }
            try Data("release_version 1.0.5\nserial DIFFERENT\n".utf8).write(to: status)
            return data
        }
        XCTAssertEqual(harness.run(["firmware", "upgrade", "--device", pro.path, "--version", "1.1.0"]), ExitCode.failure)
        XCTAssertTrue(harness.stderr.text.contains("The connected device changed."), harness.stderr.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
    }

    func testSymlinkedImageIsRefused() throws {
        let outside = harness.root.appendingPathComponent("unrelated")
        try Data("keep me".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: image, withDestinationURL: outside)
        XCTAssertEqual(upgrade(writePackage()), ExitCode.failure)
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep me".utf8))
        XCTAssertFalse(harness.stdout.text.contains("transferred"))
    }

    // MARK: Package verification

    func testFlatNestedStoredAndDeflatedPackagesAreAccepted() throws {
        for nested in [true, false] {
            let package = try FirmwarePackage.read(Self.package(nested: nested), fileName: "sidepulse-pro-1.1.0-ota.zip")
            XCTAssertEqual(package, FirmwarePackage(model: .pro, version: "1.1.0", payload: Data("encrypted firmware payload".utf8)))
        }
        let stored = TestZip.make(Self.packageFiles(), deflate: false)
        XCTAssertEqual(try FirmwarePackage.read(stored, fileName: "sidepulse-pro-1.1.0-ota.zip").version, "1.1.0")
    }

    func testExtraTraversalAndDuplicateEntriesAreRefused() {
        let unwanted = Data("unwanted".utf8)
        for extra in ["../outside", "sidepulse-pro-1.1.0-ota/extra.txt", "sidepulse-pro-1.1.0-ota/README.txt"] {
            XCTAssertThrowsError(try FirmwarePackage.read(Self.package(extra: [(extra, unwanted)]),
                                                          fileName: "sidepulse-pro-1.1.0-ota.zip"), extra) {
                XCTAssertEqual($0 as? FirmwareError, FirmwareError("Unexpected files in firmware package."))
            }
        }
    }

    func testRenamedModelOrVersionIsRefused() {
        for name in ["sidepulse-dot-1.1.0-ota.zip", "sidepulse-pro-2.0.0-ota.zip"] {
            XCTAssertThrowsError(try FirmwarePackage.read(Self.package(nested: false), fileName: name), name) {
                XCTAssertEqual($0 as? FirmwareError,
                               FirmwareError("Firmware package model or version does not match its filename."))
            }
        }
        XCTAssertThrowsError(try FirmwarePackage.read(Self.package(), fileName: "firmware.zip"))
    }

    func testMalformedArchivesHaveFriendlyErrors() {
        for data in [Data("not a zip".utf8), Data(), Self.package().prefix(200)] {
            XCTAssertThrowsError(try FirmwarePackage.read(data, fileName: "sidepulse-pro-1.1.0-ota.zip")) {
                XCTAssertEqual(($0 as? FirmwareError)?.message.hasPrefix("Invalid firmware ZIP:"), true, "\($0)")
            }
        }
    }

    /// A header that understates its entry's size must not inflate past it.
    func testInflationStopsAtTheDeclaredSize() throws {
        var data = TestZip.make([("FIRMWARE.BIN", Data(repeating: 0x41, count: 4096))])
        let range = try XCTUnwrap(data.range(of: Data([0x50, 0x4B, 0x01, 0x02])))
        data[range.lowerBound + 24] = 16
        data[range.lowerBound + 25] = 0
        let archive = try ZipArchive(data)
        XCTAssertEqual(archive.entries.first?.size, 16)
        XCTAssertThrowsError(try archive.contents(of: archive.entries[0]))
    }

    // MARK: Releases

    func testLatestReleaseIsSortedNumerically() throws {
        let listing = ["v1.9.0", "v1.10.0", "v2.0.0-beta", "README.md", "v1.1.14"]
            .map { #"{"name":"\#($0)","type":"\#($0.hasSuffix(".md") ? "file" : "dir")"}"# }
        let releases = FirmwareReleases(download: { _, _ in Data("[\(listing.joined(separator: ","))]".utf8) })
        XCTAssertEqual(try releases.publishedVersions(), ["1.10.0", "1.9.0", "1.1.14"])
        XCTAssertThrowsError(try FirmwareReleases(download: { _, _ in Data("{}".utf8) }).publishedVersions())
    }

    func testNewestReleaseWithAPackageForTheModelIsChosen() throws {
        let data = Self.package(.dot)
        var requested: [String] = []
        let releases = FirmwareReleases(download: { url, _ in
            requested.append(url.absoluteString)
            if url.host == "api.github.com" { return Data(#"[{"name":"v1.2.0","type":"dir"},{"name":"v1.1.0","type":"dir"}]"#.utf8) }
            if url.path.hasSuffix("/v1.2.0/SHA256SUMS.txt") { return Data("\(String(repeating: "0", count: 64))  sidepulse-pro-1.2.0-ota.zip\n".utf8) }
            if url.path.hasSuffix("/v1.1.0/SHA256SUMS.txt") { return Data("\(FirmwareChecksums.sha256(data))  sidepulse-dot-1.1.0-ota.zip\n".utf8) }
            return data
        })
        XCTAssertEqual(try releases.loadPackage(model: .dot, version: nil, file: nil).version, "1.1.0")
        XCTAssertEqual(requested.last, "\(FirmwareReleases.downloadRoot)/v1.1.0/sidepulse-dot-1.1.0-ota.zip")
    }

    func testRequestedVersionNeverFallsBackToAnotherRelease() {
        var downloads = 0
        let releases = FirmwareReleases(download: { _, _ in downloads += 1; return Data() })
        XCTAssertThrowsError(try releases.loadPackage(model: .dot, version: "1.2", file: nil)) {
            XCTAssertEqual($0 as? FirmwareError, FirmwareError("No published SidePulse Dot firmware package found for 1.2.0."))
        }
        XCTAssertEqual(downloads, 1)
    }

    func testRemotePackageMustMatchTheReleaseChecksum() throws {
        let data = Self.package()
        let sums = Data("\(FirmwareChecksums.sha256(data))  sidepulse-pro-1.1.0-ota.zip\n".utf8)
        var urls: [URL] = []
        let good = FirmwareReleases(download: { url, _ in urls.append(url); return url.lastPathComponent == "SHA256SUMS.txt" ? sums : data })
        XCTAssertEqual(try good.loadPackage(model: .pro, version: "v1.1", file: nil).version, "1.1.0")
        XCTAssertEqual(urls.first?.absoluteString, "\(FirmwareReleases.downloadRoot)/v1.1.0/SHA256SUMS.txt")

        let corrupt = FirmwareReleases(download: { url, _ in url.lastPathComponent == "SHA256SUMS.txt" ? sums : data + Data([0]) })
        XCTAssertThrowsError(try corrupt.loadPackage(model: .pro, version: "1.1.0", file: nil)) {
            XCTAssertEqual($0 as? FirmwareError, FirmwareError("Firmware checksum mismatch: sidepulse-pro-1.1.0-ota.zip."))
        }
    }

    func testNetworkFailuresSuggestALocalFile() {
        harness.env.download = { _, _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(harness.run(["firmware", "upgrade", "--device", pro.path]), ExitCode.failure)
        XCTAssertTrue(harness.stderr.text.contains("Could not download firmware release data:"), harness.stderr.text)
        XCTAssertTrue(harness.stderr.text.contains("You can use --file with a local OTA ZIP."), harness.stderr.text)
        XCTAssertFalse(harness.stderr.text.contains(".."), harness.stderr.text)
    }

    func testOversizedDownloadsAndInvalidVersionsAreRefused() {
        let releases = FirmwareReleases(download: { _, limit in Data(count: limit + 1) })
        XCTAssertThrowsError(try releases.loadPackage(model: .pro, version: "1.1.0", file: nil)) {
            XCTAssertEqual($0 as? FirmwareError, FirmwareError("Firmware download exceeds the size limit."))
        }
        let untouched = FirmwareReleases(download: { url, _ in XCTFail("downloaded \(url)"); return Data() })
        for version in ["../other", "1", "1.2.3.4", "１.２.３"] {
            XCTAssertThrowsError(try untouched.loadPackage(model: .pro, version: version, file: nil), version)
        }
    }
}
