import XCTest
@testable import SidePulseCLI
import SidePulseCore

final class CLIDispatchTests: XCTestCase {
    func testNoArgumentsPrintsHelp() {
        let harness = CLIHarness()
        XCTAssertEqual(harness.run([]), 0)
        XCTAssertTrue(harness.stdout.text.hasPrefix("usage: sidepulse <command> [options]"))
        for name in ["setup", "status", "live", "write", "leds", "run", "install", "uninstall", "doctor", "app",
                     "settings", "version"] {
            XCTAssertTrue(harness.stdout.text.contains("\n  \(name) "), "help should list \(name)")
        }
        XCTAssertEqual(harness.stderr.text, "")
    }

    func testHelpFlagsAndHelpCommand() {
        for arguments in [["-h"], ["--help"], ["help"]] {
            let harness = CLIHarness()
            XCTAssertEqual(harness.run(arguments), 0)
            XCTAssertTrue(harness.stdout.text.hasPrefix("usage: sidepulse <command>"), "\(arguments)")
        }
        let harness = CLIHarness()
        XCTAssertEqual(harness.run(["help", "write"]), 0)
        XCTAssertTrue(harness.stdout.text.hasPrefix("usage: sidepulse write [PROGRAM|-]"))
        XCTAssertEqual(CLIHarness().run(["help", "nope"]), 2)
    }

    func testVersion() {
        for arguments in [["version"], ["--version"], ["-V"], ["agent-monitor", "version"]] {
            let harness = CLIHarness()
            XCTAssertEqual(harness.run(arguments), 0)
            XCTAssertEqual(harness.stdout.text, "sidepulse \(SidePulseConstants.version)\n", "\(arguments)")
        }
    }

    func testPerCommandHelp() {
        for name in ["setup", "status", "live", "watch", "write", "leds", "run", "install", "uninstall", "doctor",
                     "app", "status-bar", "settings", "version"] {
            let harness = CLIHarness()
            XCTAssertEqual(harness.run([name, "--help"]), 0, name)
            XCTAssertTrue(harness.stdout.text.hasPrefix("usage: sidepulse "), name)
            XCTAssertTrue(harness.stdout.text.contains("-h, --help"), name)
        }
    }

    func testUnknownCommandIsUsageError() {
        let harness = CLIHarness()
        XCTAssertEqual(harness.run(["frobnicate"]), 2)
        XCTAssertEqual(harness.stdout.text, "")
        XCTAssertTrue(harness.stderr.text.contains("sidepulse: error: unknown command 'frobnicate'"))
    }

    func testUnknownOptionIsUsageError() {
        let harness = CLIHarness()
        XCTAssertEqual(harness.run(["status", "--bogus"]), 2)
        XCTAssertEqual(harness.stderr.text,
                       "usage: sidepulse status [--json] [--all] [--offline]\n"
                           + "sidepulse status: error: unrecognized arguments: --bogus\n")
    }

    func testBareLegacyPrefixIsUsageError() {
        let harness = CLIHarness()
        XCTAssertEqual(harness.run(["agent-monitor"]), 2)
        XCTAssertTrue(harness.stderr.text.contains("the following arguments are required: command"))
    }

    func testLegacyPrefixIsIgnored() {
        let harness = CLIHarness()
        XCTAssertEqual(harness.run(["agent-monitor", "status"]), 0)
        XCTAssertTrue(harness.stdout.text.hasPrefix("Source: hook logs (app not running)\nAggregate: Idle / Ready"))
    }

    func testAliases() {
        XCTAssertTrue(SidePulseCLI.command(named: "status-bar") == AppCommand.self)
        XCTAssertTrue(SidePulseCLI.command(named: "watch") == LiveCommand.self)
        XCTAssertTrue(SidePulseCLI.command(named: "run") == RunCommand.self)
        XCTAssertNil(SidePulseCLI.command(named: "push"))
        // `run` is leds without --once.
        let harness = CLIHarness()
        XCTAssertEqual(harness.run(["run", "--once"]), 2)
        XCTAssertTrue(harness.stderr.text.contains("unrecognized arguments: --once"))
    }

    func testHookLogArgumentsAreDispatchedFirst() {
        XCTAssertEqual(SidePulseCLI.hookLogArguments(["hook-log", "--provider", "claude"]), ["--provider", "claude"])
        XCTAssertEqual(SidePulseCLI.hookLogArguments(["agent-monitor", "hook-log", "--provider", "codex", "--log", "/x"]),
                       ["--provider", "codex", "--log", "/x"])
        XCTAssertEqual(SidePulseCLI.hookLogArguments(["hook-log"]), [])
        XCTAssertNil(SidePulseCLI.hookLogArguments(["status", "hook-log"]))
        XCTAssertNil(SidePulseCLI.hookLogArguments([]))
    }

    func testCommandFailureAndUsageFromCommands() {
        // write with nothing to write: exit 2 before touching any device code.
        let harness = CLIHarness()
        XCTAssertEqual(harness.run(["write"]), 2)
        XCTAssertEqual(harness.stderr.text, "sidepulse write: Provide an LED program (as an argument, '-' or on stdin).\n")
        // leds --device without --once.
        let leds = CLIHarness()
        XCTAssertEqual(leds.run(["leds", "--device", "/Volumes/PulseDot"]), 2)
        XCTAssertTrue(leds.stderr.text.hasPrefix("usage: sidepulse leds"))
        XCTAssertTrue(leds.stderr.text.contains("--device requires --once"))
        // live with a bad interval.
        let live = CLIHarness()
        XCTAssertEqual(live.run(["live", "--interval", "0"]), 2)
        XCTAssertTrue(live.stderr.text.contains("argument --interval: must be greater than 0"))
        // app --foreground with a non-start action.
        let app = CLIHarness()
        XCTAssertEqual(app.run(["app", "stop", "--foreground"]), 2)
        XCTAssertTrue(app.stderr.text.contains("--foreground can only be combined with start"))
    }

    func testDescribeErrors() {
        XCTAssertEqual(ErrorText.describe(CommandFailure(message: "boom")), "boom")
        XCTAssertEqual(ErrorText.describe(JSONError("Unexpected end", offset: 3)), "Invalid JSON at byte 3: Unexpected end")
        XCTAssertEqual(ErrorText.describe(LedError.unknownAnimation("zap")), "Unknown animation: zap")
        let nsError = NSError(domain: NSPOSIXErrorDomain, code: 2, userInfo: [NSLocalizedDescriptionKey: "no such file"])
        XCTAssertEqual(ErrorText.describe(nsError), "no such file")
    }
}
