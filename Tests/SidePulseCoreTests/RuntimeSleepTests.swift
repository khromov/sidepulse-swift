import Foundation
import XCTest
@testable import SidePulseCore

final class RuntimeSleepTests: XCTestCase {
    private var world: RuntimeWorld!
    private var watcher: FakeSleepWatcher!

    override func setUp() {
        super.setUp()
        world = RuntimeWorld()
        watcher = FakeSleepWatcher()
    }

    override func tearDown() {
        world.tearDown()
        super.tearDown()
    }

    private var off: String { RuntimePrograms.program("fade-off", ledCount: 2) }
    private var working: String { RuntimePrograms.expected(.working, ledCount: 2) }
    private var completed: String { RuntimePrograms.expected(.completed, ledCount: 2) }

    private func startWorkingRuntime(file: StaticString = #filePath, line: UInt = #line) throws -> SidePulseRuntime {
        world.addDevice("PulseDot")
        var options = world.options(serveSocket: false)
        options.watchSleep = true
        options.sleepWatcher = watcher
        let runtime = try world.startRuntime(options)
        runtime.ingest(provider: "claude", line: RuntimeRecords.prompt())
        waitForProgram(working, file: file, line: line)
        return runtime
    }

    private func waitForProgram(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let reached = runtimeWait { self.world.program("PulseDot") == expected }
        XCTAssertTrue(reached, "PulseDot shows \(world.program("PulseDot") ?? "nothing")", file: file, line: line)
    }

    /// Regression: a closed MacBook kept showing the status it had when it slept.
    func testClosedLidSleepTurnsLedsOffUntilTheMacIsInUse() throws {
        let runtime = try startWorkingRuntime()

        watcher.state = SleepState(lidClosed: true, lidClosedSleeps: true, graphics: true)
        watcher.send(.lidChanged)
        runtime.waitUntilIdle()
        XCTAssertEqual(world.program("PulseDot"), working, "closing the lid alone changes nothing")
        watcher.send(.willSleep)
        XCTAssertEqual(world.program("PulseDot"), off, "written before the Mac sleeps")

        // A dark wake with the lid still closed: new events and refreshes leave the LEDs off.
        watcher.state.graphics = false
        watcher.send(.didWake)
        runtime.ingest(provider: "claude", line: RuntimeRecords.stop())
        runtime.refresh()
        runtimeSpin(0.3)
        runtime.waitUntilIdle()
        XCTAssertEqual(world.program("PulseDot"), off)

        watcher.state = SleepState(lidClosed: false, lidClosedSleeps: true, graphics: false)
        watcher.send(.lidChanged)
        runtimeSpin(0.3)
        XCTAssertEqual(world.program("PulseDot"), off, "lid open, but the displays are not on yet")

        // The full wake sends no event, so the device poll notices it.
        watcher.state.graphics = true
        waitForProgram(completed)
    }

    func testOpenLidSleepLeavesLedsOnUnlessAnySleepIsOn() throws {
        let runtime = try startWorkingRuntime()

        watcher.send(.willSleep)
        runtime.waitUntilIdle()
        XCTAssertEqual(world.program("PulseDot"), working)

        world.updateSettings { $0.ledsOffOnAnySleep = true }
        runtime.reloadSettings()
        watcher.send(.willSleep)
        XCTAssertEqual(world.program("PulseDot"), off)
        // Until the Mac actually sleeps it still looks in use, and the device poll keeps running.
        runtimeSpin(0.3)
        runtime.waitUntilIdle()
        XCTAssertEqual(world.program("PulseDot"), off)
        watcher.send(.didWake)
        waitForProgram(working)
    }

    func testDesktopMacSleepFollowsTheAnySleepSetting() throws {
        watcher.state = SleepState(lidClosed: nil, lidClosedSleeps: nil, graphics: nil)
        let runtime = try startWorkingRuntime()

        watcher.send(.willSleep)
        runtime.waitUntilIdle()
        XCTAssertEqual(world.program("PulseDot"), working)

        world.updateSettings { $0.ledsOffOnAnySleep = true }
        runtime.reloadSettings()
        watcher.send(.willSleep)
        XCTAssertEqual(world.program("PulseDot"), off)
        watcher.send(.didWake)
        waitForProgram(working)
    }

    /// A closed MacBook running on an external display is in use, so its wake lights the LEDs.
    func testClosedLidOnAnExternalDisplayCountsAsInUse() throws {
        let runtime = try startWorkingRuntime()
        watcher.state = SleepState(lidClosed: true, lidClosedSleeps: false, graphics: true)
        watcher.send(.lidChanged)
        runtime.refresh()
        runtime.waitUntilIdle()
        XCTAssertEqual(world.program("PulseDot"), working)

        watcher.send(.willSleep)
        XCTAssertEqual(world.program("PulseDot"), off)
        watcher.send(.didWake)
        waitForProgram(working)
    }

    func testWatchesOnlyWhileRunning() throws {
        let runtime = try startWorkingRuntime()
        XCTAssertTrue(watcher.isWatching)
        runtime.stop()
        XCTAssertFalse(watcher.isWatching)

        try runtime.start()
        XCTAssertTrue(watcher.isWatching)
        runtime.stop()

        let unwatched = FakeSleepWatcher()
        var options = world.options(serveSocket: false)
        options.sleepWatcher = unwatched
        let other = try world.startRuntime(options)
        XCTAssertFalse(unwatched.isWatching, "watchSleep is off")
        other.stop()
    }

    /// Regression: stop() stopped the watcher after leaving the state queue, so a start() in between ran unwatched.
    func testStartRacingStopKeepsWatching() throws {
        let runtime = try startWorkingRuntime()
        watcher.stopDelay = 0.1
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            runtime.stop()
            stopped.signal()
        }
        XCTAssertTrue(runtimeWait { !runtime.isRunning })
        try runtime.start()
        XCTAssertEqual(stopped.wait(timeout: .now() + 3), .success)
        XCTAssertTrue(runtime.isRunning)
        XCTAssertTrue(watcher.isWatching)
    }

    func testRestartAfterStopWhileOffWritesTheStatusAgain() throws {
        let runtime = try startWorkingRuntime()
        watcher.state.lidClosed = true
        watcher.send(.willSleep)
        XCTAssertEqual(world.program("PulseDot"), off)
        runtime.stop()

        try runtime.start()
        waitForProgram(working)
    }
}
