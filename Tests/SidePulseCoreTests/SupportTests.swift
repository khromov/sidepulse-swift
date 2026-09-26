import XCTest
@testable import SidePulseCore

final class JSONTests: XCTestCase {
    func testRoundTripPreservesOrderAndNumbers() throws {
        let text = #"{"z":1,"a":[true,false,null],"m":{"k":"v","n":3600.0,"e":-1.5e3},"s":"é \"q\" \\ / \n"}"#
        let v = try JSONValue.parse(text)
        XCTAssertEqual(v.objectValue?.keys, ["z", "a", "m", "s"])
        XCTAssertEqual(v["m"]?["n"], .number("3600.0"))
        XCTAssertEqual(v.serialized(), #"{"z":1,"a":[true,false,null],"m":{"k":"v","n":3600.0,"e":-1.5e3},"s":"é \"q\" \\ / \n"}"#)
    }

    func testPrettyMatchesPythonLayout() throws {
        let v = try JSONValue.parse(#"{"a":{"b":[1,2],"c":{}},"d":[]}"#)
        XCTAssertEqual(v.serialized(pretty: true), "{\n  \"a\": {\n    \"b\": [\n      1,\n      2\n    ],\n    \"c\": {}\n  },\n  \"d\": []\n}")
    }

    func testUnicodeEscapesAndSurrogates() throws {
        let input = "[\"\\u00e9\\ud83d\\ude00\", \"\\u2028\"]"
        let v = try JSONValue.parse(input)
        XCTAssertEqual(v.arrayValue?.first?.stringValue, "\u{E9}\u{1F600}")
        XCTAssertEqual(v.arrayValue?.last?.stringValue, "\u{2028}")
        XCTAssertEqual(v.serialized(), "[\"\u{E9}\u{1F600}\",\"\\u2028\"]")
    }

    func testControlCharactersEscaped() {
        XCTAssertEqual(JSONValue.string("a\u{01}b\tc").serialized(), #""a\u0001b\tc""#)
    }

    func testInvalidJSONThrows() {
        for bad in ["", "{", "[1,]", "{\"a\" 1}", "tru", "01", "1.", "\"abc", "{} x"] {
            XCTAssertThrowsError(try JSONValue.parse(bad), bad)
        }
    }

    func testDuplicateKeysLastWinsFirstPosition() throws {
        let v = try JSONValue.parse(#"{"a":1,"b":2,"a":3}"#)
        XCTAssertEqual(v.serialized(), #"{"a":3,"b":2}"#)
    }

    func testSortedKeysAndObjectMutation() throws {
        var o: JSONObject = ["b": .number("1"), "a": .string("x")]
        o["c"] = .null
        o["b"] = .bool(true)
        XCTAssertEqual(o.keys, ["b", "a", "c"])
        o["a"] = nil
        XCTAssertEqual(JSONValue.object(o).sortedKeys().serialized(), #"{"b":true,"c":null}"#)
    }

    func testAccessors() {
        XCTAssertEqual(JSONValue.number("3600.0").intValue, 3600)
        XCTAssertEqual(JSONValue.number("1.5").intValue, nil)
        XCTAssertEqual(JSONValue.null.pythonString, "None")
        XCTAssertEqual(JSONValue.bool(true).pythonString, "True")
        XCTAssertEqual(JSONValue(3.0, integralAsInt: true), .number("3"))
    }

    func testNestingIsCappedAt128Containers() throws {
        func arrays(_ depth: Int) -> String { String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth) }
        func objects(_ depth: Int) -> String { String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth) }
        for text in [arrays(128), objects(128), "[" + objects(127) + "]"] {
            XCTAssertNoThrow(try JSONValue.parse(text))
        }
        for text in [arrays(129), objects(129), "[" + objects(128) + "]"] {
            XCTAssertThrowsError(try JSONValue.parse(text)) { error in
                XCTAssertEqual((error as? JSONError)?.message, "Nesting too deep")
            }
        }
    }
}

final class PathsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    private func paths(root: String) -> SidePulsePaths {
        SidePulsePaths(environment: ["SIDEPULSE_HOME": root, "HOME": home.path], home: home)
    }

    /// Regression: every long data root used to share `/tmp/sidepulse-<uid>/events.sock`, so one root's
    /// runtime received another root's hooks.
    func testEachLongRootGetsItsOwnFallbackSocket() {
        let long = "/Volumes/Data/" + String(repeating: "d", count: 100)
        let first = paths(root: long + "/one").socketPath
        let second = paths(root: long + "/two").socketPath
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, paths(root: long + "/one").socketPath)
        XCTAssertEqual(first, "/tmp/sidepulse-\(getuid())/events-\(SidePulsePaths.fnv1a64Hex(long + "/one")).sock")
        XCTAssertLessThanOrEqual(first.utf8.count, UnixSocket.maxPathBytes)
        XCTAssertTrue(SidePulsePaths.isFallbackSocket(first))

        XCTAssertEqual(paths(root: "/tmp/sp").socketPath, "/tmp/sp/events.sock")
        XCTAssertFalse(SidePulsePaths.isFallbackSocket("/tmp/sp/events.sock"))
        XCTAssertFalse(SidePulsePaths.isFallbackSocket("/tmp/sidepulse-\(getuid())/events.sock"))
    }

    /// Swift's `Hasher` is seeded per process, so the name must come from a fixed hash (FNV-1a, 64-bit).
    func testFallbackNameHashIsDeterministic() {
        XCTAssertEqual(SidePulsePaths.fnv1a64Hex(""), "cbf29ce484222325")
        XCTAssertEqual(SidePulsePaths.fnv1a64Hex("a"), "af63dc4c8601ec8c")
        XCTAssertEqual(SidePulsePaths.fnv1a64Hex("foobar"), "85944171f73967e8")
    }

    /// Regression: hooks run in each project's directory, so a relative `SIDEPULSE_HOME` gave every project
    /// its own data root.
    func testRelativeRootResolvesAgainstHomeNotTheWorkingDirectory() {
        let fm = FileManager.default
        let original = fm.currentDirectoryPath
        defer { fm.changeCurrentDirectoryPath(original) }
        let roots = ["/", "/usr"].map { directory -> String in
            XCTAssertTrue(fm.changeCurrentDirectoryPath(directory))
            return paths(root: "sp/data").root.path
        }
        XCTAssertEqual(roots, ["/Users/tester/sp/data", "/Users/tester/sp/data"])
        XCTAssertEqual(paths(root: "./sp/../sp").root.path, "/Users/tester/sp")
        XCTAssertEqual(paths(root: "/abs/root").root.path, "/abs/root")
    }
}

final class TimeFormatTests: XCTestCase {
    func testParseVariants() {
        let base = Date(timeIntervalSince1970: 1_758_130_963) // 2025-09-17T17:42:43Z
        XCTAssertEqual(TimeFormat.parse("2025-09-17T17:42:43Z"), base)
        XCTAssertEqual(TimeFormat.parse("2025-09-17T17:42:43+00:00"), base)
        XCTAssertEqual(TimeFormat.parse("2025-09-17T19:42:43+02:00"), base)
        XCTAssertEqual(TimeFormat.parse("2025-09-17T17:42:43.5Z")!.timeIntervalSince1970, 1_758_130_963.5, accuracy: 1e-6)
        XCTAssertEqual(TimeFormat.parse("2025-09-17T17:42:43.131369+00:00")!.timeIntervalSince1970, 1_758_130_963.131369, accuracy: 1e-6)
        XCTAssertEqual(TimeFormat.parse("2025-09-17T17:42:43.123Z")!.timeIntervalSince1970, 1_758_130_963.123, accuracy: 1e-6)
        XCTAssertNil(TimeFormat.parse("garbage"))
        XCTAssertNil(TimeFormat.parse(""))
        XCTAssertNil(TimeFormat.parse("2025-13-01T00:00:00Z"))
    }

    func testFormatting() {
        let d = Date(timeIntervalSince1970: 1_758_130_963.131369)
        XCTAssertEqual(TimeFormat.iso8601Seconds(d), "2025-09-17T17:42:43Z")
        XCTAssertEqual(TimeFormat.iso8601Millis(d), "2025-09-17T17:42:43.131Z")
        XCTAssertEqual(TimeFormat.pythonISO(d), "2025-09-17T17:42:43.131369+00:00")
        XCTAssertEqual(TimeFormat.pythonISO(Date(timeIntervalSince1970: 1_758_130_963)), "2025-09-17T17:42:43+00:00")
        XCTAssertEqual(TimeFormat.backupStamp(d), "20250917T174243Z")
    }

    func testParseOrNow() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(TimeFormat.parseOrNow(.string("bad"), now: now), now)
        XCTAssertEqual(TimeFormat.parseOrNow(nil, now: now), now)
    }
}

final class FileUtilTests: XCTestCase {
    func testAtomicWriteAndBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sp-fileutil-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sub/config.json")
        try FileUtil.atomicWrite("one", to: file)
        XCTAssertEqual(FileUtil.readText(file), "one")
        chmod(file.path, 0o600)
        let now = Date(timeIntervalSince1970: 1_758_130_963)
        let b1 = try FileUtil.backup(file, now: now)
        let b2 = try FileUtil.backup(file, now: now)
        XCTAssertEqual(b1?.lastPathComponent, "config.json.bak.20250917T174243Z")
        XCTAssertEqual(b2?.lastPathComponent, "config.json.bak.20250917T174243Z-2")
        try FileUtil.atomicWrite("two", to: file)
        XCTAssertEqual(FileUtil.readText(file), "two")
        var st = stat()
        stat(file.path, &st)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertNil(try FileUtil.backup(dir.appendingPathComponent("missing")))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).filter { $0.contains(".tmp.") }
        XCTAssertEqual(leftovers, [])
    }

    func testBackupsKeepTheNewestThreeOfOurs() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.toml")
        try FileUtil.atomicWrite("x", to: file)
        for foreign in ["config.toml.bak", "config.toml.bak.old", "other.toml.bak.20250101T000000Z"] {
            try FileUtil.atomicWrite("keep", to: dir.appendingPathComponent(foreign))
        }
        for day in 1...4 { try FileUtil.backup(file, now: Date(timeIntervalSince1970: 1_758_130_963 + Double(day) * 86_400)) }
        let now = Date(timeIntervalSince1970: 1_758_130_963 + 5 * 86_400)
        for _ in 0..<10 { try FileUtil.backup(file, now: now) }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, ["config.toml", "config.toml.bak", "config.toml.bak.20250922T174243Z-10",
                               "config.toml.bak.20250922T174243Z-8", "config.toml.bak.20250922T174243Z-9",
                               "config.toml.bak.old", "other.toml.bak.20250101T000000Z"])
    }

    private func makeDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sp-fileutil-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath()
    }

    func testAtomicWriteFollowsTwoLevelSymlinkChain() throws {
        let root = makeDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("home/.claude"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("dotfiles/claude"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("dotfiles2"), withIntermediateDirectories: true)
        let real = root.appendingPathComponent("dotfiles2/settings.json")
        try "old".write(to: real, atomically: false, encoding: .utf8)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("dotfiles/claude/settings.json").path,
                                  withDestinationPath: "../../dotfiles2/settings.json")
        let link = root.appendingPathComponent("home/.claude/settings.json")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../../dotfiles/claude/settings.json")
        try FileUtil.atomicWrite("new", to: link)
        XCTAssertEqual(FileUtil.readText(real), "new")
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: root.appendingPathComponent("dotfiles/claude/settings.json").path))
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: link.path))
    }

    func testAtomicWriteResolvesRelativeLinkInsideSymlinkedDirectory() throws {
        let root = makeDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("real/claudedir"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("real/shared"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("home/.claude").path,
                                  withDestinationPath: root.appendingPathComponent("real/claudedir").path)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("real/claudedir/settings.json").path,
                                  withDestinationPath: "../shared/settings.json")
        try FileUtil.atomicWrite("x", to: root.appendingPathComponent("home/.claude/settings.json"))
        XCTAssertEqual(FileUtil.readText(root.appendingPathComponent("real/shared/settings.json")), "x")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("home/shared/settings.json").path))
    }

    func testAtomicWriteCreatesTargetOfDanglingLink() throws {
        let root = makeDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("config.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "store/config.json")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("store"), withIntermediateDirectories: true)
        try FileUtil.atomicWrite("created", to: link)
        XCTAssertEqual(FileUtil.readText(root.appendingPathComponent("store/config.json")), "created")
    }

    func testAtomicWriteRefusesReadOnlyFile() throws {
        let root = makeDir()
        defer {
            chmod(root.appendingPathComponent("ro.json").path, 0o644)
            try? FileManager.default.removeItem(at: root)
        }
        let file = root.appendingPathComponent("ro.json")
        try FileUtil.atomicWrite("keep", to: file)
        chmod(file.path, 0o444)
        XCTAssertThrowsError(try FileUtil.atomicWrite("clobber", to: file)) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("read-only"))
        }
        XCTAssertEqual(FileUtil.readText(file), "keep")
        XCTAssertThrowsError(try FileUtil.ensureWritable(file))
        XCTAssertNoThrow(try FileUtil.ensureWritable(root.appendingPathComponent("new.json")))
    }
}
