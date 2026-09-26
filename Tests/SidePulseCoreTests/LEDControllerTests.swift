import XCTest
@testable import SidePulseCore

final class LEDControllerTests: XCTestCase {
    private final class FakeClock {
        var now: TimeInterval = 1000
    }

    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidepulse-led-controller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func device(_ name: String) throws -> URL {
        let root = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("LEDS.LED")
    }

    private func contents(_ target: URL) -> String? {
        FileManager.default.contents(atPath: target.path).map { String(decoding: $0, as: UTF8.self) }
    }

    func testSkipsUnchangedState() throws {
        let target = try device("SidePulsePro")
        let controller = AgentLedController(target: target)

        let first = controller.sync(mode: .completed, animationID: "solid-green")
        let second = controller.sync(mode: .completed, animationID: "solid-green")
        let third = controller.sync(mode: .waitingForInput, animationID: "amber-pulse")

        XCTAssertTrue(first.changed)
        XCTAssertEqual(first.program, "#00FF66 320ms cosine")
        XCTAssertEqual(first.target, target)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.program, "")
        XCTAssertNil(second.error)
        XCTAssertTrue(third.changed)
        XCTAssertTrue(contents(target)?.contains("#FF3A00 1.6s pulse") ?? false)
    }

    func testTracksDisplayStateAnimationAndBrightness() throws {
        let target = try device("SidePulsePro")
        let controller = AgentLedController(target: target)

        XCTAssertTrue(controller.sync(mode: .working, animationID: "cyan-roll").changed)
        XCTAssertFalse(controller.sync(mode: .toolRunning, animationID: "cyan-roll").changed, "same display state")
        XCTAssertTrue(controller.sync(mode: .working, animationID: "kitt").changed, "different animation")
        XCTAssertFalse(controller.sync(mode: .longTaskProgress, animationID: "kitt").changed)

        controller.brightness = 64
        let dimmed = controller.sync(mode: .working, animationID: "kitt")
        XCTAssertTrue(dimmed.changed)
        XCTAssertTrue(dimmed.program.hasPrefix("brightness 64\n"))
        XCTAssertEqual(contents(target), dimmed.program)

        controller.brightness = 900
        let full = controller.sync(mode: .working, animationID: "kitt")
        XCTAssertTrue(full.changed, "brightness is clamped to 255, which differs from 64")
        XCTAssertFalse(full.program.contains("brightness"))
    }

    func testRepairsExternallyChangedProgram() throws {
        let target = try device("SidePulsePro")
        let controller = AgentLedController(target: target, brightness: 211)
        let first = controller.sync(mode: .working, animationID: "purple-tide")
        XCTAssertTrue(first.program.hasPrefix("brightness 211\n"))

        try Data("off 2s\n3:#006060 4:#006060 2s ease\nrepeat".utf8).write(to: target)
        let repaired = controller.sync(mode: .working, animationID: "purple-tide")

        XCTAssertTrue(repaired.changed)
        XCTAssertEqual(contents(target), first.program)

        try FileManager.default.removeItem(at: target)
        XCTAssertTrue(controller.sync(mode: .working, animationID: "purple-tide").changed, "a deleted file is rewritten")
        XCTAssertEqual(contents(target), first.program)
        XCTAssertFalse(controller.sync(mode: .working, animationID: "purple-tide").changed)
    }

    func testPicksProgramForDotAndPro() throws {
        let dot = AgentLedController(target: try device("SidePulseDot"))
        let pulseDot = AgentLedController(target: try device("PulseDot"))
        let pro = AgentLedController(target: try device("SidePulsePro"))

        let dotProgram = dot.sync(mode: .working, animationID: "cyan-roll").program
        XCTAssertEqual(dotProgram, "off 320ms cosine\n0:#00E5FF 760ms pulse 0ms; 1:#00E5FF 760ms pulse 260ms\nrepeat")
        XCTAssertEqual(pulseDot.sync(mode: .working, animationID: "cyan-roll").program, dotProgram)
        XCTAssertEqual(pulseDot.sync(mode: .idleReady, animationID: "idle-pulse").program,
                       "off 2s\n0:#006060 1:#006060 2s ease\nrepeat")

        let proProgram = pro.sync(mode: .working, animationID: "cyan-roll").program
        let lines = LedText.splitLines(proProgram)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.first, "off 320ms cosine")
        XCTAssertTrue(lines[1].contains("0:#00E5FF 760ms pulse 0ms"))
        XCTAssertTrue(lines[1].contains("5:#00E5FF 760ms pulse 475ms"))
        XCTAssertTrue(lines[1].contains("7:#00E5FF 760ms pulse 665ms"))
        XCTAssertEqual(lines.last, "repeat")
        XCTAssertEqual(contents(pro.target), proProgram)

        let done = AgentLedController(target: try device("SidePulseDot 2"), brightness: 64)
        XCTAssertEqual(done.sync(mode: .completed, animationID: "solid-green").program, "brightness 64\n#00FF66 320ms cosine")
    }

    func testErrorsBackOffForTenSeconds() throws {
        let clock = FakeClock()
        let volume = base.appendingPathComponent("SidePulseDot", isDirectory: true)
        let target = volume.appendingPathComponent("LEDS.LED")
        let controller = AgentLedController(target: target, clock: { clock.now })

        let failed = controller.sync(mode: .working, animationID: "cyan-roll")
        XCTAssertFalse(failed.changed)
        XCTAssertTrue(failed.error?.contains(target.path) ?? false, failed.error ?? "")
        XCTAssertEqual(controller.lastError, failed.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: volume.path), "the volume folder is never created")

        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        clock.now += 5
        let held = controller.sync(mode: .toolRunning, animationID: "cyan-roll")
        XCTAssertFalse(held.changed)
        XCTAssertEqual(held.error, failed.error)
        XCTAssertNil(contents(target), "no attempt during the backoff")

        clock.now += 5.1
        let retried = controller.sync(mode: .working, animationID: "cyan-roll")
        XCTAssertTrue(retried.changed)
        XCTAssertNil(retried.error)
        XCTAssertNil(controller.lastError)
        XCTAssertEqual(contents(target), retried.program)
    }

    func testBackoffEndsExactlyAtTheRetryInterval() throws {
        let clock = FakeClock()
        let volume = base.appendingPathComponent("SidePulsePro", isDirectory: true)
        let controller = AgentLedController(target: volume.appendingPathComponent("LEDS.LED"), clock: { clock.now })
        XCTAssertNotNil(controller.sync(mode: .completed, animationID: "cyan-complete").error)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)

        clock.now += 9.999
        XCTAssertFalse(controller.sync(mode: .completed, animationID: "cyan-complete").changed)
        clock.now = 1010
        XCTAssertTrue(controller.sync(mode: .completed, animationID: "cyan-complete").changed,
                      "Python retries once now - last_attempt is no longer < 10 s")
    }

    func testFailedRetryRestartsTheBackoff() throws {
        let clock = FakeClock()
        let volume = base.appendingPathComponent("SidePulseDot", isDirectory: true)
        let controller = AgentLedController(target: volume.appendingPathComponent("LEDS.LED"), clock: { clock.now })
        XCTAssertNotNil(controller.sync(mode: .working, animationID: "cyan-roll").error)

        clock.now += 10
        XCTAssertNotNil(controller.sync(mode: .working, animationID: "cyan-roll").error, "retried and failed again")
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        clock.now += 5
        XCTAssertFalse(controller.sync(mode: .working, animationID: "cyan-roll").changed, "backoff restarted at the retry")
        clock.now += 5
        XCTAssertTrue(controller.sync(mode: .working, animationID: "cyan-roll").changed)
    }

    func testChangedRequestRetriesImmediatelyAfterAnError() throws {
        let clock = FakeClock()
        let target = try device("SidePulsePro")
        let controller = AgentLedController(target: target, clock: { clock.now })

        let unknown = controller.sync(mode: .working, animationID: "nope")
        XCTAssertEqual(unknown.error, "Unknown animation: nope")
        XCTAssertEqual(controller.sync(mode: .working, animationID: "nope").error, "Unknown animation: nope")

        let fixed = controller.sync(mode: .working, animationID: "kitt")
        XCTAssertTrue(fixed.changed, "a different animation is a new request, not a retry")
        XCTAssertEqual(contents(target), fixed.program)
    }

    func testDryRunNeverWrites() throws {
        let target = try device("SidePulseDot")
        let controller = AgentLedController(target: target, dryRun: true)

        let first = controller.sync(mode: .blockedError, animationID: "amber-pulse")
        XCTAssertTrue(first.changed)
        XCTAssertEqual(first.program, "off\n#FF3A00 1.6s pulse\nrepeat")
        XCTAssertFalse(controller.sync(mode: .waitingForInput, animationID: "amber-pulse").changed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    /// The sync service declines a write when the device became Manual while open() waited.
    func testDeclinedWriteIsNotRemembered() throws {
        let target = try device("SidePulseDot")
        let controller = AgentLedController(target: target)
        let declined = controller.sync(mode: .working, animationID: "cyan-roll") { _ in false }
        XCTAssertEqual(declined, LedSyncResult(changed: false, target: target))
        XCTAssertNil(controller.lastProgram)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        let written = RuntimeInbox<String>()
        let result = controller.sync(mode: .working, animationID: "cyan-roll") { program in
            written.append(program)
            return try LedWriter.write(program, to: target)
        }
        XCTAssertTrue(result.changed)
        XCTAssertEqual(written.items, [result.program])
        XCTAssertEqual(LedWriter.read(target), result.program)
    }

    func testResetForcesARewrite() throws {
        let target = try device("SidePulseDot")
        let controller = AgentLedController(target: target)
        XCTAssertTrue(controller.sync(mode: .idleReady, animationID: "idle-pulse").changed)
        XCTAssertEqual(controller.lastProgram, "off 2s\n0:#006060 1:#006060 2s ease\nrepeat")
        XCTAssertEqual(controller.lastState, .idle)

        controller.reset()

        XCTAssertNil(controller.lastProgram)
        XCTAssertNil(controller.lastState)
        XCTAssertTrue(controller.sync(mode: .idleReady, animationID: "idle-pulse").changed)
    }
}
