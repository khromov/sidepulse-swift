import XCTest
@testable import SidePulseCore

private func makeTempDirectory(_ testCase: XCTestCase) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sidepulse-led-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    testCase.addTeardownBlock {
        // Restore permissions changed by a test so cleanup can recurse.
        if let items = FileManager.default.enumerator(atPath: url.path) {
            for case let item as String in items {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: url.appendingPathComponent(item).path)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }
    return url
}

@discardableResult
private func makeDirectory(_ parent: URL, _ name: String) throws -> URL {
    let url = parent.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeFile(_ url: URL, _ text: String) throws {
    try Data(text.utf8).write(to: url)
}

private func readFile(_ url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

final class LEDDiscoveryTests: XCTestCase {
    func testEmptyDotFolderIsFoundByName() throws {
        let root = try makeTempDirectory(self)
        let device = try makeDirectory(root, "SidePulseDot")

        let candidates = DeviceDiscovery.discover(roots: [root])

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.root.path, device.path)
        XCTAssertEqual(candidates.first?.target.path, device.appendingPathComponent("LEDS.LED").path)
        XCTAssertEqual(candidates.first?.reason, "name matches device")
    }

    func testDiscoversDotAcrossSeveralRoots() throws {
        let base = try makeTempDirectory(self)
        let first = try makeDirectory(base, "media")
        let second = try makeDirectory(base, "run-media")
        try makeDirectory(first, "Photos")
        let device = try makeDirectory(second, "SidePulseDot")

        let candidates = DeviceDiscovery.discover(roots: [first, second])

        XCTAssertEqual(candidates.map(\.root.path), [device.path])
    }

    func testVolumeContainingLedFileIsFoundWhateverItsName() throws {
        let root = try makeTempDirectory(self)
        let pro = try makeDirectory(root, "SidePulsePro")
        try writeFile(pro.appendingPathComponent("LEDS.LED"), "off")
        let other = try makeDirectory(root, "Backup")
        try writeFile(other.appendingPathComponent("LEDS.LED"), "off")

        let candidates = DeviceDiscovery.discover(roots: [root])

        XCTAssertEqual(candidates.map(\.root.lastPathComponent), ["Backup", "SidePulsePro"])
        XCTAssertEqual(candidates.map(\.reason), ["contains LEDS.LED", "contains LEDS.LED"])
        XCTAssertEqual(candidates.last?.target.path, pro.appendingPathComponent("LEDS.LED").path)
    }

    func testOldLedsTxtOnUnnamedVolumeIsNotADevice() throws {
        let root = try makeTempDirectory(self)
        let usb = try makeDirectory(root, "USB Drive")
        try writeFile(usb.appendingPathComponent("LEDS.TXT"), "off")

        XCTAssertEqual(DeviceDiscovery.discover(roots: [root]), [])
    }

    func testSkipsTimeMachineMacintoshHDAndPlainFiles() throws {
        let root = try makeTempDirectory(self)
        for name in [".timemachine", "Macintosh HD"] {
            let dir = try makeDirectory(root, name)
            try writeFile(dir.appendingPathComponent("LEDS.LED"), "off")
        }
        try writeFile(root.appendingPathComponent("SidePulseDot"), "not a directory")
        let real = try makeDirectory(root, "PulseDot")

        XCTAssertEqual(DeviceDiscovery.discover(roots: [root]).map(\.root.path), [real.path])
    }

    func testFollowsSymlinksAndSkipsBrokenOnes() throws {
        let base = try makeTempDirectory(self)
        let root = try makeDirectory(base, "Volumes")
        let elsewhere = try makeDirectory(base, "real-volume")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("PulseDot"),
                                                   withDestinationURL: elsewhere)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("SidePulsePro"),
                                                   withDestinationURL: base.appendingPathComponent("missing"))

        let candidates = DeviceDiscovery.discover(roots: [root])

        XCTAssertEqual(candidates.map(\.root.lastPathComponent), ["PulseDot"])
        XCTAssertEqual(candidates.first?.root.path, root.appendingPathComponent("PulseDot").path)
    }

    func testSortsByLowercasedNameAndDedupesRoots() throws {
        let root = try makeTempDirectory(self)
        for name in ["c-volume", "b-SidePulseDot", "A-SidePulsePro"] {
            let dir = try makeDirectory(root, name)
            try writeFile(dir.appendingPathComponent("LEDS.LED"), "off")
        }

        let candidates = DeviceDiscovery.discover(roots: [root, root])

        XCTAssertEqual(candidates.map(\.root.lastPathComponent), ["A-SidePulsePro", "b-SidePulseDot", "c-volume"])
    }

    func testMissingAndUnreadableRootsAreEmpty() throws {
        let base = try makeTempDirectory(self)
        let file = base.appendingPathComponent("file-root")
        try writeFile(file, "x")
        let locked = try makeDirectory(base, "locked")
        try makeDirectory(locked, "SidePulseDot")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let good = try makeDirectory(base, "good")
        let dot = try makeDirectory(good, "SidePulseDot")

        let candidates = DeviceDiscovery.discover(roots: [base.appendingPathComponent("missing"), file, locked, good])

        XCTAssertEqual(candidates.map(\.root.path), [dot.path])
    }

    func testUnreadableVolumeFallsBackToNameMatching() throws {
        let root = try makeTempDirectory(self)
        let dot = try makeDirectory(root, "SidePulseDot")
        let other = try makeDirectory(root, "Offline")
        for dir in [dot, other] {
            try writeFile(dir.appendingPathComponent("LEDS.LED"), "off")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        }

        let candidates = DeviceDiscovery.discover(roots: [root])

        XCTAssertEqual(candidates.map(\.root.lastPathComponent), ["SidePulseDot"])
        XCTAssertEqual(candidates.first?.reason, "name matches device")
    }

    func testMountRootsFromEnvironment() {
        XCTAssertEqual(DeviceDiscovery.mountRoots(environment: [:]).map(\.path), ["/Volumes"])
        XCTAssertEqual(DeviceDiscovery.mountRoots(environment: ["SIDEPULSE_MOUNT_ROOTS": ""]), [])
        XCTAssertEqual(DeviceDiscovery.mountRoots(environment: ["SIDEPULSE_MOUNT_ROOTS": " : "]), [])
        XCTAssertEqual(DeviceDiscovery.mountRoots(environment: ["SIDEPULSE_MOUNT_ROOTS": "::/tmp/a::/tmp/b:"]).map(\.path),
                       ["/tmp/a", "/tmp/b"])
        XCTAssertEqual(DeviceDiscovery.mountRoots(environment: ["SIDEPULSE_MOUNT_ROOTS": "~/mnt:~",
                                                                "HOME": "/Users/alice"]).map(\.path),
                       ["/Users/alice/mnt", "/Users/alice"])
    }

    func testDiscoveryAndResolutionUseMountRootsVariable() throws {
        let root = try makeTempDirectory(self)
        let dot = try makeDirectory(root, "PulseDot")
        let previous = ProcessInfo.processInfo.environment["SIDEPULSE_MOUNT_ROOTS"]
        setenv("SIDEPULSE_MOUNT_ROOTS", root.path, 1)
        defer {
            if let previous { setenv("SIDEPULSE_MOUNT_ROOTS", previous, 1) } else { unsetenv("SIDEPULSE_MOUNT_ROOTS") }
        }

        XCTAssertEqual(DeviceDiscovery.discover().map(\.root.path), [dot.path])
        XCTAssertEqual(try DeviceDiscovery.resolveTarget(devicePath: nil).path, dot.appendingPathComponent("LEDS.LED").path)

        setenv("SIDEPULSE_MOUNT_ROOTS", "", 1)
        XCTAssertEqual(DeviceDiscovery.discover(), [])
    }

    func testDeviceNameHints() {
        for name in ["SidePulse Pro", "sidepulse_dot 2", "Pulse Dot", "SIDEPULSEPRO1", "PulseDot", "SidePulseDot 1"] {
            XCTAssertTrue(DeviceDiscovery.isDeviceName(name), name)
        }
        for name in ["USB", "Untitled", "Pulse", "SidePulse", "Dot", ""] {
            XCTAssertFalse(DeviceDiscovery.isDeviceName(name), name)
        }
        XCTAssertEqual(DeviceDiscovery.normalizedName("SidePulse Dot 1"), "sidepulsedot1")
        XCTAssertEqual(DeviceDiscovery.normalizedName("Pulse_Dot-\u{C9}"), "pulsedot")
    }

    /// The device verdicts match the Python implementation's.
    func testNormalizedNameKeepsASCIILettersAndDigits() {
        let vectors: [(String, Bool, String)] = [
            ("Pulse Dot\u{301}", true, "pulsedot"),
            ("PulseDo\u{301}t", true, "pulsedot"),
            ("Side\u{AD}Pulse Dot", true, "sidepulsedot"),
            ("SIDEPULSEPRO\u{B2}", true, "sidepulsepro"),
            ("SidePulse\u{2167}", false, "sidepulse"),
            ("\u{130}", false, "i"),
            ("PulseDot\u{FF9E}", true, "pulsedot"),
        ]
        for (name, isDevice, normalized) in vectors {
            XCTAssertEqual(DeviceDiscovery.normalizedName(name), normalized, name.debugDescription)
            XCTAssertEqual(DeviceDiscovery.isDeviceName(name), isDevice, name.debugDescription)
        }
        XCTAssertEqual(DeviceDiscovery.displayName(forVolumeName: "Pulse Dot\u{301}"), "SidePulse Dot")
        XCTAssertEqual(DeviceDiscovery.ledCount(forTarget: URL(fileURLWithPath: "/Volumes/PulseDo\u{301}t/LEDS.LED")), 2)
        XCTAssertEqual(DeviceDiscovery.displayName(forVolumeName: "PulseDot\u{FF9E}"), "SidePulse Dot")
        XCTAssertEqual(DeviceDiscovery.ledCount(forTarget: URL(fileURLWithPath: "/Volumes/PulseDot\u{FF9E}/LEDS.LED")), 2)
    }

    func testLedCountFromVolumeName() {
        let vectors: [(String, Int)] = [
            ("/Volumes/SidePulseDot/LEDS.LED", 2),
            ("/Volumes/PulseDot/LEDS.LED", 2),
            ("/Volumes/Pulse Dot 1/LEDS.LED", 2),
            ("/Volumes/SidePulsePro/LEDS.LED", 8),
            ("/Volumes/USB/LEDS.LED", 8),
        ]
        for (path, count) in vectors {
            XCTAssertEqual(DeviceDiscovery.ledCount(forTarget: URL(fileURLWithPath: path)), count, path)
        }
        let dot = DeviceCandidate(root: URL(fileURLWithPath: "/Volumes/PulseDot"),
                                  target: URL(fileURLWithPath: "/Volumes/PulseDot/LEDS.LED"), reason: "")
        XCTAssertEqual(dot.ledCount, 2)
        XCTAssertEqual(dot.id, "/Volumes/PulseDot")
        XCTAssertEqual(dot.displayName, "SidePulse Dot")
    }

    func testDisplayNames() {
        XCTAssertEqual(DeviceDiscovery.displayName(forVolumeName: "PulseDot"), "SidePulse Dot")
        XCTAssertEqual(DeviceDiscovery.displayName(forVolumeName: "SidePulseDot 1"), "SidePulse Dot")
        XCTAssertEqual(DeviceDiscovery.displayName(forVolumeName: "SidePulsePro"), "SidePulse Pro")
        XCTAssertEqual(DeviceDiscovery.displayName(forVolumeName: "USB Stick"), "USB Stick")
        XCTAssertEqual(DeviceDiscovery.displayName(forVolumeName: ""), "SidePulse Device")
    }

    /// Regression: discovery stat'ed every child of /Volumes, so one dead network mount stalled
    /// hot-plug detection, and any local volume with a `LEDS.LED` (a disk image, say) was written.
    func testOnlyLocalFATMountPointsAreLookedAt() throws {
        let root = try makeTempDirectory(self)
        var mounts: [String: DeviceDiscovery.Mount] = [:]
        for (name, local, fileSystem) in [("NAS SidePulseDot", false, "smbfs"), ("Some Installer", true, "apfs"),
                                          ("PulseDot", true, "msdos"), ("Stick", true, "exfat")] {
            let volume = try makeDirectory(root, name)
            try writeFile(volume.appendingPathComponent("LEDS.LED"), "off")
            mounts[volume.path] = DeviceDiscovery.Mount(local: local, fileSystem: fileSystem)
        }
        let plain = try makeDirectory(root, "Plain")
        try writeFile(plain.appendingPathComponent("LEDS.LED"), "off")

        let found = DeviceDiscovery.discover(roots: [root], fileName: DeviceDiscovery.fileName, mounts: mounts)

        XCTAssertEqual(found.map(\.root.lastPathComponent), ["Plain", "PulseDot", "Stick"],
                       "folders that are not mount points are scanned, as under a test root")
        XCTAssertEqual(DeviceDiscovery.discover(roots: [root]).count, 5, "none of them is a real mount point")
    }

    func testMountTableComesFromTheKernel() {
        let mounts = DeviceDiscovery.mountTable()
        XCTAssertEqual(mounts["/"]?.local, true, "the boot volume is local")
        XCTAssertFalse(mounts["/"]?.fileSystem.isEmpty ?? true)
        XCTAssertFalse(DeviceDiscovery.deviceFileSystems.contains(mounts["/"]?.fileSystem ?? ""))
    }

    /// Regression: a volume holding `LEDS.LED -> ~/.zshrc` was discovered, and the user's file was then
    /// truncated and overwritten.
    func testVolumeWhoseLedFileIsNotARegularFileIsNotDiscovered() throws {
        let base = try makeTempDirectory(self)
        let root = try makeDirectory(base, "Volumes")
        let victim = base.appendingPathComponent("victim")
        try writeFile(victim, "secret")
        let linked = try makeDirectory(root, "Some Installer")
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("LEDS.LED"), withDestinationURL: victim)
        let piped = try makeDirectory(root, "Pipe")
        XCTAssertEqual(mkfifo(piped.appendingPathComponent("LEDS.LED").path, 0o644), 0)
        let nested = try makeDirectory(root, "Nested")
        try makeDirectory(nested, "LEDS.LED")

        XCTAssertEqual(DeviceDiscovery.discover(roots: [root]), [])
    }

    func testCandidateForVolumeMatchesACaseVariantOrSymlinkedPath() throws {
        let base = try makeTempDirectory(self)
        let root = try makeDirectory(base, "Volumes")
        let dot = try makeDirectory(root, "PulseDot")
        let link = base.appendingPathComponent("dot-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dot)
        let candidates = DeviceDiscovery.discover(roots: [root])
        XCTAssertEqual(candidates.map(\.root.path), [dot.path])

        XCTAssertEqual(DeviceDiscovery.candidate(forVolume: dot, among: candidates)?.id, dot.path)
        XCTAssertEqual(DeviceDiscovery.candidate(forVolume: link, among: candidates)?.id, dot.path)
        let variant = root.appendingPathComponent("pulsedot")
        if FileManager.default.fileExists(atPath: variant.path) {
            XCTAssertEqual(DeviceDiscovery.candidate(forVolume: variant, among: candidates)?.id, dot.path)
        }
        XCTAssertNil(DeviceDiscovery.candidate(forVolume: root, among: candidates))
        XCTAssertNil(DeviceDiscovery.candidate(forVolume: base.appendingPathComponent("missing"), among: candidates))
    }

    func testResolveExplicitDevicePath() throws {
        XCTAssertEqual(try DeviceDiscovery.resolveTarget(devicePath: "/tmp/x/SidePulseDot").path,
                       "/tmp/x/SidePulseDot/LEDS.LED")
        XCTAssertEqual(try DeviceDiscovery.resolveTarget(devicePath: "/tmp/x/SidePulseDot/leds.led").path,
                       "/tmp/x/SidePulseDot/leds.led")
        XCTAssertEqual(try DeviceDiscovery.resolveTarget(devicePath: "/tmp/x/Dot", fileName: "OTHER.LED").path,
                       "/tmp/x/Dot/OTHER.LED")
        XCTAssertEqual(try DeviceDiscovery.resolveTarget(devicePath: "/tmp/x/Dot/LEDS.LED", fileName: "OTHER.LED").path,
                       "/tmp/x/Dot/LEDS.LED")
        XCTAssertEqual(try DeviceDiscovery.resolveTarget(devicePath: "~/SidePulseDot").path,
                       (NSHomeDirectory() as NSString).appendingPathComponent("SidePulseDot/LEDS.LED"))
    }

    func testResolveByDiscoveryErrors() throws {
        let empty = try makeTempDirectory(self)
        XCTAssertThrowsError(try DeviceDiscovery.resolveTarget(devicePath: nil, roots: [empty])) { error in
            XCTAssertEqual(error as? LedError, .noDevice)
        }

        let root = try makeTempDirectory(self)
        let pro = try makeDirectory(root, "SidePulsePro")
        let dot = try makeDirectory(root, "SidePulseDot")
        XCTAssertThrowsError(try DeviceDiscovery.resolveTarget(devicePath: nil, roots: [root])) { error in
            XCTAssertEqual(error as? LedError, .multipleDevices([dot.path, pro.path]))
            XCTAssertEqual(error.localizedDescription,
                           "Multiple possible devices found. Pass --device with one of:\n  \(dot.path)\n  \(pro.path)")
        }

        let single = try makeTempDirectory(self)
        let only = try makeDirectory(single, "PulseDot")
        XCTAssertEqual(try DeviceDiscovery.resolveTarget(devicePath: nil, roots: [single]).path,
                       only.appendingPathComponent("LEDS.LED").path)
        XCTAssertEqual(try DeviceDiscovery.resolveTarget(devicePath: nil, fileName: "TEST.LED", roots: [single]).path,
                       only.appendingPathComponent("TEST.LED").path)
    }
}

final class LEDWriterTests: XCTestCase {
    func testWritesProgramExactlyWithoutTrailingNewline() throws {
        let device = try makeDirectory(try makeTempDirectory(self), "SidePulsePro")
        let target = try DeviceDiscovery.resolveTarget(devicePath: device.path)

        try LedWriter.write(LedText.decodeEscapes(#"off\n#FF00FF pulse"#), to: target)

        XCTAssertEqual(target.path, device.appendingPathComponent("LEDS.LED").path)
        XCTAssertEqual(try readFile(target), "off\n#FF00FF pulse")
        XCTAssertEqual(LedWriter.read(target), "off\n#FF00FF pulse")
    }

    func testTruncatesLongerPreviousContent() throws {
        let device = try makeDirectory(try makeTempDirectory(self), "SidePulseDot")
        let target = device.appendingPathComponent("LEDS.LED")
        try LedWriter.write(String(repeating: "#FF0000 1s pulse\n", count: 10), to: target)

        try LedWriter.write("off", to: target)

        XCTAssertEqual(try readFile(target), "off")
    }

    func testRewritesTheSameFileInPlace() throws {
        let device = try makeDirectory(try makeTempDirectory(self), "SidePulseDot")
        let target = device.appendingPathComponent("LEDS.LED")
        try LedWriter.write("off", to: target)
        let before = try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? Int

        try LedWriter.write("#00FF66 320ms cosine", to: target)

        let after = try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? Int
        XCTAssertNotNil(before)
        XCTAssertEqual(before, after, "LEDS.LED must not be replaced by rename (the firmware watches the entry)")
    }

    func testNeverCreatesTheParentDirectory() throws {
        let base = try makeTempDirectory(self)
        let missing = base.appendingPathComponent("SidePulseDot")

        XCTAssertThrowsError(try LedWriter.write("off", to: missing.appendingPathComponent("LEDS.LED"))) { error in
            guard case .writeFailed(let message)? = error as? LedError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(message.contains(missing.path), message)
            XCTAssertTrue(message.contains("No such file or directory"), message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testValidatesBeforeTouchingTheFile() throws {
        let device = try makeDirectory(try makeTempDirectory(self), "SidePulseDot")
        let target = device.appendingPathComponent("LEDS.LED")
        try writeFile(target, "keep")

        XCTAssertThrowsError(try LedWriter.write(String(repeating: "x", count: 513), to: target)) { error in
            XCTAssertEqual(error as? LedError, .invalidProgram("LED program is 513 bytes; max is 512."))
        }
        XCTAssertThrowsError(try LedWriter.write("", to: target))
        XCTAssertEqual(try readFile(target), "keep")
    }

    func testLeavesLegacyLedsTxtAlone() throws {
        let device = try makeDirectory(try makeTempDirectory(self), "SidePulseDot")
        try writeFile(device.appendingPathComponent("LEDS.TXT"), "off")
        let target = try DeviceDiscovery.resolveTarget(devicePath: device.path)

        try LedWriter.write(LedText.decodeEscapes(#"off\n#FF00FF pulse"#), to: target)

        XCTAssertEqual(target.lastPathComponent, "LEDS.LED")
        XCTAssertEqual(try readFile(target), "off\n#FF00FF pulse")
        XCTAssertEqual(try readFile(device.appendingPathComponent("LEDS.TXT")), "off")
    }

    /// Regression: a write that waited in open() (macOS permission prompt) went on
    /// to truncate and overwrite a device the user had meanwhile switched to Manual.
    func testDeclinedWriteLeavesTheFileUntouched() throws {
        let device = try makeDirectory(try makeTempDirectory(self), "SidePulseDot")
        let target = device.appendingPathComponent("LEDS.LED")
        try writeFile(target, "#FF00FF pulse")

        XCTAssertFalse(try LedWriter.write("off", to: target, shouldWrite: { false }))
        XCTAssertEqual(try readFile(target), "#FF00FF pulse", "not even truncated")
        XCTAssertTrue(try LedWriter.write("off", to: target, shouldWrite: { true }))
        XCTAssertEqual(try readFile(target), "off")
    }

    /// Regression: EACCES from a read-only file was reported as the macOS privacy refusal.
    func testReadOnlyFileIsAPlainWriteFailure() throws {
        let device = try makeDirectory(try makeTempDirectory(self), "SidePulseDot")
        let target = device.appendingPathComponent("LEDS.LED")
        try writeFile(target, "keep")
        chmod(target.path, 0o444)
        defer { chmod(target.path, 0o644) }

        XCTAssertThrowsError(try LedWriter.write("off", to: target)) { error in
            XCTAssertEqual(error as? LedError, .writeFailed("Could not open \(target.path): Permission denied"))
        }
        XCTAssertEqual(try readFile(target), "keep")
    }

    func testFinderLockedFileIsReportedAsLocked() throws {
        let device = try makeDirectory(try makeTempDirectory(self), "SidePulseDot")
        let target = device.appendingPathComponent("LEDS.LED")
        try writeFile(target, "keep")
        XCTAssertEqual(chflags(target.path, UInt32(UF_IMMUTABLE)), 0)
        defer { chflags(target.path, 0) }

        XCTAssertThrowsError(try LedWriter.write("off", to: target)) { error in
            XCTAssertEqual(error as? LedError, .writeFailed("\(target.path) is locked"))
        }
        XCTAssertEqual(try readFile(target), "keep")
    }

    func testOpenErrorClassification() {
        func info(_ type: mode_t, flags: Int32 = 0) -> stat {
            var info = stat()
            info.st_mode = type | 0o644
            info.st_flags = UInt32(flags)
            return info
        }
        let path = "/Volumes/PulseDot/LEDS.LED"
        XCTAssertEqual(LedWriter.openError(path: path, code: EPERM, info: info(S_IFREG)),
                       .accessDenied("Could not open \(path): Operation not permitted"))
        XCTAssertEqual(LedWriter.openError(path: path, code: EPERM, info: nil),
                       .accessDenied("Could not open \(path): Operation not permitted"))
        XCTAssertEqual(LedWriter.openError(path: path, code: EPERM, info: info(S_IFREG, flags: UF_IMMUTABLE)),
                       .writeFailed("\(path) is locked"))
        XCTAssertEqual(LedWriter.openError(path: path, code: EPERM, info: info(S_IFREG, flags: SF_IMMUTABLE)),
                       .writeFailed("\(path) is locked"))
        XCTAssertEqual(LedWriter.openError(path: path, code: EACCES, info: info(S_IFREG)),
                       .writeFailed("Could not open \(path): Permission denied"))
        XCTAssertEqual(LedWriter.openError(path: path, code: ELOOP, info: info(S_IFLNK)),
                       .writeFailed("\(path) is not a regular file"))
        XCTAssertEqual(LedWriter.openError(path: path, code: ENOENT, info: nil),
                       .writeFailed("Could not open \(path): No such file or directory"))
    }

    /// Regression: `LEDS.LED` was opened through a symlink (truncating its target) and a FIFO blocked
    /// open() forever.
    func testRefusesASymlinkFIFOOrDirectoryAsTheTarget() throws {
        let base = try makeTempDirectory(self)
        let device = try makeDirectory(base, "SidePulseDot")
        let target = device.appendingPathComponent("LEDS.LED")
        let refused = LedError.writeFailed("\(target.path) is not a regular file")
        var checked = false

        let victim = base.appendingPathComponent("victim")
        try writeFile(victim, "secret")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: victim)
        XCTAssertThrowsError(try LedWriter.write("off", to: target, shouldWrite: { checked = true; return true })) { error in
            XCTAssertEqual(error as? LedError, refused)
        }
        XCTAssertEqual(try readFile(victim), "secret")
        try FileManager.default.removeItem(at: target)
        let missing = base.appendingPathComponent("created-through-link")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: missing)
        XCTAssertThrowsError(try LedWriter.write("off", to: target)) { XCTAssertEqual($0 as? LedError, refused) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        try FileManager.default.removeItem(at: target)

        XCTAssertEqual(mkfifo(target.path, 0o644), 0)
        let started = Date()
        XCTAssertThrowsError(try LedWriter.write("off", to: target)) { XCTAssertEqual($0 as? LedError, refused) }
        let reader = open(target.path, O_RDONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(reader, 0)
        defer { close(reader) }
        XCTAssertThrowsError(try LedWriter.write("off", to: target)) { XCTAssertEqual($0 as? LedError, refused) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "never waits for a reader")
        try FileManager.default.removeItem(at: target)

        try makeDirectory(device, "LEDS.LED")
        XCTAssertThrowsError(try LedWriter.write("off", to: target)) { XCTAssertEqual($0 as? LedError, refused) }
        XCTAssertFalse(checked, "refused before the caller's check")
    }

    func testSymlinkedVolumeFolderStillWorks() throws {
        let base = try makeTempDirectory(self)
        let device = try makeDirectory(base, "SidePulseDot")
        let link = base.appendingPathComponent("linked-dot")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: device)

        try LedWriter.write("off", to: link.appendingPathComponent("LEDS.LED"))

        XCTAssertEqual(try readFile(device.appendingPathComponent("LEDS.LED")), "off")
    }

    func testIfHoldingWritesOnlyOverTheExpectedProgram() throws {
        let device = try makeDirectory(try makeTempDirectory(self), "SidePulseDot")
        let target = device.appendingPathComponent("LEDS.LED")
        XCTAssertFalse(try LedWriter.write("off", to: target, ifHolding: "idle"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "a missing file is not created")

        try writeFile(target, "#FF00FF pulse")
        XCTAssertFalse(try LedWriter.write("off", to: target, ifHolding: "#FF00FF"))
        XCTAssertFalse(try LedWriter.write("off", to: target, ifHolding: "#FF00FF pulse\n"))
        XCTAssertEqual(try readFile(target), "#FF00FF pulse")
        XCTAssertFalse(try LedWriter.write("off", to: target, ifHolding: "#FF00FF pulse", shouldWrite: { false }))
        XCTAssertEqual(try readFile(target), "#FF00FF pulse")
        XCTAssertTrue(try LedWriter.write("off", to: target, ifHolding: "#FF00FF pulse"))
        XCTAssertEqual(try readFile(target), "off")
    }

    func testReadIsLossyAndNilWhenMissing() throws {
        let dir = try makeTempDirectory(self)
        let target = dir.appendingPathComponent("LEDS.LED")
        XCTAssertNil(LedWriter.read(target))

        try Data([0x6F, 0x66, 0x66, 0xFF]).write(to: target)

        XCTAssertEqual(LedWriter.read(target), "off\u{FFFD}")
        try Data().write(to: target)
        XCTAssertEqual(LedWriter.read(target), "")
    }

    /// The read-back runs on the LED queue, so a FIFO must not block it.
    func testReadRefusesASymlinkOrFIFO() throws {
        let dir = try makeTempDirectory(self)
        let victim = dir.appendingPathComponent("victim")
        try writeFile(victim, "secret")
        let linked = dir.appendingPathComponent("LEDS.LED")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: victim)
        XCTAssertNil(LedWriter.read(linked))

        let pipe = dir.appendingPathComponent("PIPE.LED")
        XCTAssertEqual(mkfifo(pipe.path, 0o644), 0)
        let started = Date()
        XCTAssertNil(LedWriter.read(pipe))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }
}

final class LEDKeepaliveTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [URL] = []
        func append(_ url: URL) { lock.lock(); items.append(url); lock.unlock() }
        var touched: [URL] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private struct TouchFailure: Error, LocalizedError {
        var errorDescription: String? { "offline" }
    }

    func testKeepaliveFileLocation() {
        let device = URL(fileURLWithPath: "/Volumes/SidePulsePro")
        let expected = "/Volumes/SidePulsePro/keepalive"
        for target in ["LEDS.LED", "leds.led", "STATUS.TXT", "keepalive", "KEEPALIVE"] {
            XCTAssertEqual(KeepaliveToucher.keepaliveFile(for: device.appendingPathComponent(target)).path, expected, target)
        }
        XCTAssertEqual(KeepaliveToucher.keepaliveFile(for: device).path, expected)
        XCTAssertEqual(KeepaliveToucher.keepaliveFile(for: device.appendingPathComponent("OTHER.LED")).path,
                       "/Volumes/SidePulsePro/OTHER.LED/keepalive")
    }

    func testTouchesOncePerInterval() {
        let recorder = Recorder()
        let toucher = KeepaliveToucher(interval: 60) { recorder.append($0) }
        let target = URL(fileURLWithPath: "/Volumes/SidePulsePro/LEDS.LED")
        let keepalive = URL(fileURLWithPath: "/Volumes/SidePulsePro/keepalive")
        let start = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertEqual(toucher.poke(targets: [target], now: start), [keepalive])
        XCTAssertTrue(toucher.waitForPendingTouches())
        XCTAssertEqual(toucher.poke(targets: [target], now: start + 30), [])
        XCTAssertEqual(toucher.poke(targets: [target], now: start + 61), [keepalive])
        XCTAssertTrue(toucher.waitForPendingTouches())

        XCTAssertEqual(recorder.touched, [keepalive, keepalive])
    }

    func testFailuresAlsoWaitTheInterval() {
        let toucher = KeepaliveToucher(interval: 60) { _ in throw TouchFailure() }
        let target = URL(fileURLWithPath: "/Volumes/SidePulseDot/LEDS.LED")
        let start = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertEqual(toucher.poke(targets: [target], now: start).count, 1)
        XCTAssertTrue(toucher.waitForPendingTouches())
        XCTAssertEqual(toucher.lastError, "/Volumes/SidePulseDot/keepalive: offline")
        XCTAssertEqual(toucher.poke(targets: [target], now: start + 59), [])
        XCTAssertEqual(toucher.poke(targets: [target], now: start + 60).count, 1)
        XCTAssertTrue(toucher.waitForPendingTouches())
    }

    func testRateLimitIsPerPath() {
        let recorder = Recorder()
        let toucher = KeepaliveToucher(interval: 60) { recorder.append($0) }
        let pro = URL(fileURLWithPath: "/Volumes/SidePulsePro")
        let dot = URL(fileURLWithPath: "/Volumes/PulseDot")
        let now = Date(timeIntervalSinceReferenceDate: 0)

        let scheduled = toucher.poke(targets: [pro.appendingPathComponent("LEDS.LED"), pro,
                                               dot.appendingPathComponent("LEDS.LED")], now: now)
        XCTAssertTrue(toucher.waitForPendingTouches())

        XCTAssertEqual(scheduled.map(\.path), ["/Volumes/SidePulsePro/keepalive", "/Volumes/PulseDot/keepalive"])
        XCTAssertEqual(Set(recorder.touched.map(\.path)), Set(scheduled.map(\.path)))
    }

    func testAtMostOneTouchInFlightPerPath() {
        let release = DispatchSemaphore(value: 0)
        let recorder = Recorder()
        let toucher = KeepaliveToucher(interval: 60) { url in
            recorder.append(url)
            release.wait()
        }
        let target = URL(fileURLWithPath: "/Volumes/SidePulsePro/LEDS.LED")
        let start = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertEqual(toucher.poke(targets: [target], now: start).count, 1)
        XCTAssertEqual(toucher.poke(targets: [target], now: start + 100), [], "a hung touch must not pile up")
        release.signal()
        XCTAssertTrue(toucher.waitForPendingTouches())
        XCTAssertEqual(toucher.poke(targets: [target], now: start + 200).count, 1)
        release.signal()
        XCTAssertTrue(toucher.waitForPendingTouches())
        XCTAssertEqual(recorder.touched.count, 2)
    }

    func testStalledFilesListsTouchesRunningTooLong() {
        let release = DispatchSemaphore(value: 0)
        let toucher = KeepaliveToucher(interval: 60) { _ in release.wait() }
        let target = URL(fileURLWithPath: "/Volumes/SidePulsePro/LEDS.LED")

        toucher.poke(targets: [target])
        XCTAssertEqual(toucher.stalledFiles(after: 10), [])
        XCTAssertTrue(IPCTestSupport.waitUntil { toucher.stalledFiles(after: 0.1) == ["/Volumes/SidePulsePro/keepalive"] })
        release.signal()
        XCTAssertTrue(toucher.waitForPendingTouches())
        XCTAssertEqual(toucher.stalledFiles(after: 0), [])
    }

    func testClockMovingBackwardsDoesNotBlock() {
        let toucher = KeepaliveToucher(interval: 60) { _ in }
        let target = URL(fileURLWithPath: "/Volumes/SidePulsePro/LEDS.LED")
        let start = Date(timeIntervalSinceReferenceDate: 1000)

        XCTAssertEqual(toucher.poke(targets: [target], now: start).count, 1)
        XCTAssertTrue(toucher.waitForPendingTouches())
        XCTAssertEqual(toucher.poke(targets: [target], now: start - 500).count, 1)
        XCTAssertTrue(toucher.waitForPendingTouches())
    }

    func testRealTouchCreatesAndRefreshesTheFile() throws {
        let device = try makeDirectory(try makeTempDirectory(self), "SidePulsePro")
        let keepalive = device.appendingPathComponent("keepalive")
        let toucher = KeepaliveToucher()

        XCTAssertEqual(toucher.poke(targets: [device.appendingPathComponent("LEDS.LED")]).map(\.path), [keepalive.path])
        XCTAssertTrue(toucher.waitForPendingTouches())
        XCTAssertTrue(FileManager.default.fileExists(atPath: keepalive.path))
        XCTAssertNil(toucher.lastError)

        let old = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: keepalive.path)
        toucher.poke(targets: [device], now: Date().addingTimeInterval(120))
        XCTAssertTrue(toucher.waitForPendingTouches())
        let modified = try FileManager.default.attributesOfItem(atPath: keepalive.path)[.modificationDate] as? Date
        XCTAssertGreaterThan(modified ?? old, old.addingTimeInterval(1800))
        XCTAssertEqual(try Data(contentsOf: keepalive).count, 0)
    }

    func testTouchFileFailsForMissingVolume() {
        XCTAssertThrowsError(try KeepaliveToucher.touchFile(
            URL(fileURLWithPath: "/nonexistent-sidepulse-volume/keepalive")))
    }

    /// Regression: a `keepalive` symlink got its target created or touched.
    func testTouchRefusesASymlinkFIFOOrDirectory() throws {
        let base = try makeTempDirectory(self)
        let device = try makeDirectory(base, "SidePulsePro")
        let keepalive = device.appendingPathComponent("keepalive")
        let refused = LedError.writeFailed("\(keepalive.path) is not a regular file")

        let victim = base.appendingPathComponent("victim")
        try writeFile(victim, "secret")
        let old = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: victim.path)
        try FileManager.default.createSymbolicLink(at: keepalive, withDestinationURL: victim)
        XCTAssertThrowsError(try KeepaliveToucher.touchFile(keepalive)) { XCTAssertEqual($0 as? LedError, refused) }
        let modified = try FileManager.default.attributesOfItem(atPath: victim.path)[.modificationDate] as? Date
        XCTAssertEqual(modified?.timeIntervalSince1970 ?? 0, old.timeIntervalSince1970, accuracy: 1)
        try FileManager.default.removeItem(at: keepalive)

        let missing = base.appendingPathComponent("created-through-link")
        try FileManager.default.createSymbolicLink(at: keepalive, withDestinationURL: missing)
        XCTAssertThrowsError(try KeepaliveToucher.touchFile(keepalive)) { XCTAssertEqual($0 as? LedError, refused) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        try FileManager.default.removeItem(at: keepalive)

        XCTAssertEqual(mkfifo(keepalive.path, 0o644), 0)
        XCTAssertThrowsError(try KeepaliveToucher.touchFile(keepalive)) { XCTAssertEqual($0 as? LedError, refused) }
        try FileManager.default.removeItem(at: keepalive)

        try makeDirectory(device, "keepalive")
        XCTAssertThrowsError(try KeepaliveToucher.touchFile(keepalive)) { XCTAssertEqual($0 as? LedError, refused) }
    }
}
