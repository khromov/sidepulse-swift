import XCTest
@testable import SidePulseCLI

final class CLIArgumentParserTests: XCTestCase {
    private let spec = CommandSpec(
        name: "demo",
        synopsis: "[NAME]... [--flag] [--opt VALUE]",
        summary: "Demo command",
        positionals: PositionalSpec(name: "name", maxCount: 2),
        options: [
            OptionSpec("flag", short: "f", help: "a flag"),
            OptionSpec("other", short: "o", help: "another flag"),
            OptionSpec("opt", short: "p", value: "VALUE", help: "an option"),
            OptionSpec("interval", value: "SECONDS", help: "a number"),
        ]
    )

    private func parse(_ arguments: [String]) throws -> ParsedArguments {
        guard case .arguments(let parsed) = try ArgumentParser.parse(arguments, spec: spec) else {
            XCTFail("unexpected help")
            return ParsedArguments()
        }
        return parsed
    }

    private func assertUsageError(_ arguments: [String], _ message: String, file: StaticString = #filePath,
                                  line: UInt = #line) {
        XCTAssertThrowsError(try ArgumentParser.parse(arguments, spec: spec), file: file, line: line) { error in
            XCTAssertEqual((error as? UsageError)?.message, message, file: file, line: line)
        }
    }

    func testFlagsOptionsAndPositionals() throws {
        let parsed = try parse(["a", "--flag", "--opt", "x", "b"])
        XCTAssertEqual(parsed.positionals, ["a", "b"])
        XCTAssertTrue(parsed.has("flag"))
        XCTAssertFalse(parsed.has("other"))
        XCTAssertEqual(parsed.value("opt"), "x")
        XCTAssertNil(parsed.value("interval"))
    }

    func testInlineValueAndLastOccurrenceWins() throws {
        let parsed = try parse(["--opt=first", "--opt", "second"])
        XCTAssertEqual(parsed.value("opt"), "second")
        XCTAssertEqual(try parse(["--opt="]).value("opt"), "")
        XCTAssertEqual(try parse(["--opt=a=b"]).value("opt"), "a=b")
    }

    func testOptionValueMayStartWithDash() throws {
        XCTAssertEqual(try parse(["--opt", "-x"]).value("opt"), "-x")
        XCTAssertEqual(try parse(["--interval", "-1"]).value("interval"), "-1")
    }

    func testShortOptions() throws {
        let parsed = try parse(["-f", "-p", "v"])
        XCTAssertTrue(parsed.has("flag"))
        XCTAssertEqual(parsed.value("opt"), "v")
        XCTAssertEqual(try parse(["-pvalue"]).value("opt"), "value")
        let bundled = try parse(["-fo"])
        XCTAssertTrue(bundled.has("flag") && bundled.has("other"))
    }

    func testDoubleDashTerminatorAndLoneDash() throws {
        let parsed = try parse(["--", "--flag"])
        XCTAssertEqual(parsed.positionals, ["--flag"])
        XCTAssertFalse(parsed.has("flag"))
        XCTAssertEqual(try parse(["-"]).positionals, ["-"])
        XCTAssertEqual(try parse(["--", "-h"]).positionals, ["-h"])
    }

    func testHelp() throws {
        XCTAssertEqual(try ArgumentParser.parse(["-h"], spec: spec), .help)
        XCTAssertEqual(try ArgumentParser.parse(["a", "--help", "--bogus"], spec: spec), .help)
    }

    func testUsageErrors() {
        assertUsageError(["--bogus"], "unrecognized arguments: --bogus")
        assertUsageError(["-z"], "unrecognized arguments: -z")
        assertUsageError(["--opt"], "argument --opt: expected one argument")
        assertUsageError(["--flag=yes"], "argument --flag: ignored explicit argument 'yes'")
        assertUsageError(["a", "b", "c", "d"], "unrecognized arguments: c d")
    }

    func testPositionalChoices() throws {
        let choices = CommandSpec(name: "x", synopsis: "", summary: "",
                                  positionals: PositionalSpec(name: "provider", maxCount: 3, choices: ["claude", "codex", "all"]))
        guard case .arguments(let parsed) = try ArgumentParser.parse(["codex", "claude"], spec: choices) else {
            return XCTFail("expected arguments")
        }
        XCTAssertEqual(parsed.positionals, ["codex", "claude"])
        XCTAssertThrowsError(try ArgumentParser.parse(["cursor"], spec: choices)) { error in
            XCTAssertEqual((error as? UsageError)?.message,
                           "argument provider: invalid choice: 'cursor' (choose from 'claude', 'codex', 'all')")
        }
    }

    func testNumericOptions() throws {
        XCTAssertEqual(try parse(["--interval", "0.5"]).double("interval", default: 1), 0.5)
        XCTAssertEqual(try parse([]).double("interval", default: 1), 1)
        XCTAssertThrowsError(try parse(["--interval", "abc"]).double("interval", default: 1)) { error in
            XCTAssertEqual((error as? UsageError)?.message, "argument --interval: invalid float value: 'abc'")
        }
        XCTAssertThrowsError(try parse(["--interval", "nan"]).double("interval", default: 1))
        XCTAssertThrowsError(try parse(["--interval", "0"]).double("interval", default: 1, minimum: 0, exclusive: true)) {
            XCTAssertEqual(($0 as? UsageError)?.message, "argument --interval: must be greater than 0")
        }
        XCTAssertEqual(try parse(["--interval", "0"]).double("interval", default: 1, minimum: 0), 0)
        XCTAssertThrowsError(try parse(["--interval", "-1"]).double("interval", default: 1, minimum: 0)) {
            XCTAssertEqual(($0 as? UsageError)?.message, "argument --interval: must be at least 0")
        }
    }

    func testHelpTextListsOptions() {
        let text = spec.helpText
        XCTAssertTrue(text.hasPrefix("usage: sidepulse demo [NAME]... [--flag] [--opt VALUE]\n\nDemo command"))
        XCTAssertTrue(text.contains("  -f, --flag"))
        XCTAssertTrue(text.contains("  -p, --opt VALUE"))
        XCTAssertTrue(text.contains("  -h, --help"))
    }
}
