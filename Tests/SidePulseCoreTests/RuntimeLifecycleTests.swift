import Foundation
import XCTest
@testable import SidePulseCore

/// Startup (latest.json + log recovery), single instance, hot-plug, keep-awake and
/// shutdown.
final class RuntimeLifecycleTests: XCTestCase {
    private var world: RuntimeWorld!

    override func setUp() {
        super.setUp()
        world = RuntimeWorld()
    }

    override func tearDown() {
        world.tearDown()
        super.tearDown()
    }

    private func waitForProgram(_ device: String, _ expected: String, timeout: TimeInterval = 3,
                                file: StaticString = #filePath, line: UInt = #line) {
        let reached = runtimeWait(timeout: timeout) { self.world.program(device) == expected }
        XCTAssertTrue(reached, "\(device) shows \(world.program(device) ?? "nil"), expected \(expected)", file: file, line: line)
    }

    private func latestAgentIDs() -> [String] {
        LatestStore(url: world.paths.latestFile).load().map(\.agentID)
    }

    // MARK: latest.json

    func testLatestIsSavedDebouncedAndRestoredOnRestart() throws {
        var options = world.options(serveSocket: false)
        options.latestSaveDelay = 0.5
        let runtime = try world.startRuntime(options)
        runtime.waitUntilIdle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.paths.latestFile.path), "saved at startup")
        XCTAssertEqual(latestAgentIDs(), [])

        let start = Date()
        for index in 0..<20 { runtime.ingest(provider: "claude", line: RuntimeRecords.prompt("s\(index)")) }
        runtime.ingest(provider: "codex", line: RuntimeRecords.permission("cx"))
        XCTAssertEqual(latestAgentIDs(), [], "not written on every event")
        XCTAssertTrue(runtimeWait(timeout: 3) { self.latestAgentIDs().count == 21 })
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.4, "coalesced for ~latestSaveDelay")
        runtime.stop()

        // A new instance (no hook logs) restores the rows from latest.json.
        let restarted = try world.startRuntime(options)
        let snapshot = restarted.snapshot()
        XCTAssertEqual(snapshot.statuses.count, 21)
        XCTAssertEqual(snapshot.aggregate.mode, .waitingForInput)
        XCTAssertEqual(snapshot.aggregate.representative?.agentID, "codex:session:cx")
    }

    func testStopFlushesPendingLatestChanges() throws {
        var options = world.options(serveSocket: false)
        options.latestSaveDelay = 60
        let runtime = try world.startRuntime(options)
        runtime.ingest(provider: "claude", line: RuntimeRecords.stop("flush-me"))
        runtime.waitUntilIdle()
        XCTAssertEqual(latestAgentIDs(), [])
        runtime.stop()
        XCTAssertEqual(latestAgentIDs(), ["claude:session:flush-me"])
        XCTAssertFalse(runtime.isRunning)
        runtime.stop() // idempotent
    }

    func testRefreshPrunesRowsOlderThanTheRetention() throws {
        // Retention is max(idle timeout, retention setting).
        world.updateSettings {
            $0.idleTimeoutSeconds = 10
            $0.sessionRetentionSeconds = 20
        }
        let old = AgentStatus(provider: "claude", agentID: "claude:session:old", displayName: "old", mode: .completed,
                              updatedAt: Date().addingTimeInterval(-3600), eventName: "Stop", sessionID: "old")
        try LatestStore(url: world.paths.latestFile).save([old])
        var options = world.options(serveSocket: false)
        options.latestSaveDelay = 0.1
        let runtime = try world.startRuntime(options)
        runtime.waitUntilIdle()
        XCTAssertEqual(runtime.snapshot().staleStatuses, [], "pruned at startup")
        XCTAssertEqual(latestAgentIDs(), [])

        runtime.ingest(provider: "claude", line: RuntimeRecords.prompt("recent", secondsAgo: 15))
        XCTAssertEqual(runtime.snapshot().staleStatuses.map(\.agentID), ["claude:session:recent"])
        runtime.ingest(provider: "claude", line: RuntimeRecords.prompt("ancient", secondsAgo: 25))
        runtime.refresh()
        runtime.waitUntilIdle()
        XCTAssertEqual(runtime.snapshot().staleStatuses.map(\.agentID), ["claude:session:recent"])
        XCTAssertTrue(runtimeWait { self.latestAgentIDs() == ["claude:session:recent"] })
    }

    // MARK: Recovery

    func testMissedStopInTheLogsIsAppliedAtStart() throws {
        world.addDevice("PulseDot")
        // latest.json still says Working (the app was not running when Stop fired)…
        let stale = AgentStatus(provider: "claude", agentID: "claude:session:r1", displayName: "project-r1 (r1)",
                                mode: .working, updatedAt: Date().addingTimeInterval(-60), eventName: "UserPromptSubmit",
                                sessionID: "r1", cwd: "/tmp/project-r1")
        try LatestStore(url: world.paths.latestFile).save([stale])
        // …but the hook log has the Stop.
        try world.writeLog(provider: "claude", records: [
            RuntimeRecords.prompt("r1", secondsAgo: 60),
            RuntimeRecords.stop("r1", secondsAgo: 30),
        ])
        try world.writeLog(provider: "codex", records: [RuntimeRecords.event("UserPromptSubmit", session: "c9", secondsAgo: 5)])

        let runtime = try world.startRuntime()
        let snapshot = runtime.snapshot()
        // (A Completed row is listed with the stale ones while another agent works.)
        let rows = snapshot.statuses + snapshot.staleStatuses
        XCTAssertEqual(rows.first { $0.agentID == "claude:session:r1" }?.mode, .completed)
        XCTAssertEqual(snapshot.statuses.first { $0.agentID == "codex:session:c9" }?.mode, .working)
        XCTAssertEqual(snapshot.aggregate.mode, .working)
        waitForProgram("PulseDot", RuntimePrograms.expected(.working, ledCount: 2))
        runtime.waitUntilIdle()
        // The reconciled rows were written back.
        let saved = LatestStore(url: world.paths.latestFile).load()
        XCTAssertEqual(saved.first { $0.agentID == "claude:session:r1" }?.mode, .completed)
    }

    func testCodexTitlesComeFromTheSessionIndex() throws {
        try FileManager.default.createDirectory(at: world.paths.codexDir, withIntermediateDirectories: true)
        try #"{"id":"cx-1","thread_name":"Port the runtime","updated_at":"2026-09-26T00:00:00Z"}"#
            .write(to: world.paths.codexDir.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
        try world.writeLog(provider: "codex", records: [RuntimeRecords.event("UserPromptSubmit", session: "cx-1", secondsAgo: 5)])
        let runtime = try world.startRuntime(world.options(serveSocket: false))
        XCTAssertTrue(runtime.snapshot().statuses.first?.displayName.contains("Port the runtime") == true,
                      runtime.snapshot().statuses.first?.displayName ?? "none")
    }

    // MARK: Single instance

    func testSecondInstanceThrowsAlreadyRunningWithoutTouchingAnything() throws {
        world.addDevice("PulseDot")
        world.addDevice("SidePulsePro")
        // The first instance sees no devices, so the device stays untouched by it.
        var firstOptions = world.options()
        firstOptions.mountRoots = [world.root.appendingPathComponent("no-devices")]
        let first = try world.startRuntime(firstOptions)
        first.waitUntilIdle()
        let latestBefore = try Data(contentsOf: world.paths.latestFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.paths.settingsFile.path))

        let second = world.makeRuntime()
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? EventSocketError, .alreadyRunning(world.paths.socketPath))
        }
        XCTAssertFalse(second.isRunning)
        runtimeSpin(0.3)
        XCTAssertEqual(world.program("PulseDot"), "boot")
        XCTAssertEqual(world.program("SidePulsePro"), "boot")
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.mounts.appendingPathComponent("SidePulsePro/keepalive").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.paths.settingsFile.path))
        XCTAssertEqual(try Data(contentsOf: world.paths.latestFile), latestBefore)
        second.stop()

        // The first instance still serves.
        XCTAssertTrue(EventSocketClient.isServerRunning(socketPath: world.paths.socketPath))
        first.ingest(provider: "claude", line: RuntimeRecords.prompt())
        let reply = try XCTUnwrap(world.request("status"))
        XCTAssertEqual(MonitorSnapshot.fromJSON(try JSONValue.parse(reply))?.aggregate.mode, .working)
    }

    func testStartReplacesAStaleSocketAndCanRestart() throws {
        try FileManager.default.createDirectory(at: world.state, withIntermediateDirectories: true)
        IPCTestSupport.makeStaleSocket(at: world.paths.socketPath)
        let runtime = try world.startRuntime()
        XCTAssertTrue(EventSocketClient.isServerRunning(socketPath: world.paths.socketPath))
        runtime.stop()
        XCTAssertFalse(EventSocketClient.isServerRunning(socketPath: world.paths.socketPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.paths.socketPath))
        try runtime.start()
        XCTAssertTrue(EventSocketClient.isServerRunning(socketPath: world.paths.socketPath))
    }

    // MARK: Devices

    func testHotPlugWritesNewDevicesAndDropsRemovedOnes() throws {
        world.addDevice("PulseDot")
        let runtime = try world.startRuntime()
        runtime.ingest(provider: "claude", line: RuntimeRecords.permission())
        waitForProgram("PulseDot", RuntimePrograms.expected(.waitingForInput, ledCount: 2))
        XCTAssertEqual(runtime.leds.connectedDevices.map(\.id), [world.deviceID("PulseDot")])

        // Mount a Pro mid-run: it gets the current program within a poll or two.
        world.addDevice("SidePulsePro")
        waitForProgram("SidePulsePro", RuntimePrograms.expected(.waitingForInput, ledCount: 8), timeout: 2)
        XCTAssertEqual(Set(runtime.leds.connectedDevices.map(\.id)), [world.deviceID("PulseDot"), world.deviceID("SidePulsePro")])
        XCTAssertTrue(runtimeWait {
            self.world.settingsStore.load().device(id: self.world.deviceID("SidePulsePro"))?.name == "SidePulse Pro"
        }, "new devices are remembered")
        XCTAssertEqual(runtime.deviceInfos().filter(\.connected).count, 2)

        // Unmount it: dropped from the connected set, still remembered.
        world.removeDevice("SidePulsePro")
        XCTAssertTrue(runtimeWait(timeout: 2) { runtime.leds.connectedDevices.count == 1 })
        let infos = runtime.deviceInfos()
        XCTAssertEqual(infos.map(\.name), ["SidePulse Dot", "SidePulse Pro"])
        XCTAssertEqual(infos.map(\.connected), [true, false])

        // Plugged back in: written again even though nothing else changed.
        world.addDevice("SidePulsePro")
        waitForProgram("SidePulsePro", RuntimePrograms.expected(.waitingForInput, ledCount: 8), timeout: 2)
    }

    func testConnectedDevicesAreRememberedAtStartWithTheirNames() throws {
        world.addDevice("PulseDot")
        world.addDevice("SidePulsePro")
        world.updateSettings { $0.defaultDisplay = .manual }
        let runtime = try world.startRuntime()
        runtime.waitUntilIdle()
        let saved = world.settingsStore.load()
        XCTAssertEqual(saved.devices.map(\.name).sorted(), ["SidePulse Dot", "SidePulse Pro"])
        XCTAssertEqual(saved.devices.map(\.display), [.manual, .manual], "first sighting copies default_display")
        XCTAssertEqual(world.program("PulseDot"), "boot", "Manual by default: never written")
        XCTAssertEqual(runtime.deviceInfos().map(\.display), [.manual, .manual])
    }

    // MARK: Keep-awake

    func testKeepAwakeFollowsAgentsWithGraceAndBatterySafeguard() throws {
        let holder = FakeKeepAwake()
        let battery = FakeBattery()
        var options = world.options(serveSocket: false)
        options.keepAwake = true
        options.keepAwakeHolder = holder
        options.batteryReader = { battery.read() }
        options.batteryCacheInterval = 0
        options.keepAwakeGrace = 0.4
        let runtime = try world.startRuntime(options)
        runtime.waitUntilIdle()
        XCTAssertFalse(runtime.keepAwakeActive, "idle: not held")
        XCTAssertEqual(holder.calls.last, false)

        runtime.ingest(provider: "claude", line: RuntimeRecords.prompt())
        runtime.waitUntilIdle()
        XCTAssertTrue(holder.isHeld)
        XCTAssertTrue(runtime.keepAwakeActive)

        // Done: held through the grace period, released after it.
        runtime.ingest(provider: "claude", line: RuntimeRecords.stop())
        runtime.waitUntilIdle()
        XCTAssertTrue(runtime.keepAwakeActive)
        runtimeSpin(0.5)
        runtime.refresh()
        runtime.waitUntilIdle()
        XCTAssertFalse(runtime.keepAwakeActive)
        XCTAssertFalse(holder.isHeld)

        // Low battery on battery power: never held.
        battery.state = BatteryState(present: true, percent: 10, onACPower: false, charging: false)
        runtime.ingest(provider: "claude", line: RuntimeRecords.prompt())
        runtime.waitUntilIdle()
        XCTAssertFalse(runtime.keepAwakeActive)
        battery.state = BatteryState(present: true, percent: 10, onACPower: true, charging: true)
        runtime.refresh()
        runtime.waitUntilIdle()
        XCTAssertTrue(runtime.keepAwakeActive)

        // Policy changes apply at once.
        runtime.updateSettings { $0.sleepPolicy = .never }
        runtime.waitUntilIdle()
        XCTAssertFalse(runtime.keepAwakeActive)
        runtime.ingest(provider: "claude", line: RuntimeRecords.stop())
        runtime.updateSettings { $0.sleepPolicy = .always }
        runtime.waitUntilIdle()
        XCTAssertTrue(runtime.keepAwakeActive, "Always holds even when idle")

        runtime.stop()
        XCTAssertFalse(runtime.keepAwakeActive)
        XCTAssertFalse(holder.isHeld)
        XCTAssertEqual(holder.calls.last, false)
    }

    func testBatteryReadingsAreCached() throws {
        let battery = FakeBattery()
        var options = world.options(serveSocket: false)
        options.keepAwake = true
        options.keepAwakeHolder = FakeKeepAwake()
        options.batteryReader = { battery.read() }
        let runtime = try world.startRuntime(options)
        for _ in 0..<10 { runtime.ingest(provider: "claude", line: RuntimeRecords.prompt()) }
        runtime.refresh()
        runtime.waitUntilIdle()
        XCTAssertEqual(battery.reads, 1)
    }

    func testKeepAwakeOffNeverHoldsOrReadsTheBattery() throws {
        let holder = FakeKeepAwake()
        let battery = FakeBattery()
        var options = world.options(serveSocket: false)
        options.keepAwake = false
        options.keepAwakeHolder = holder
        options.batteryReader = { battery.read() }
        let runtime = try world.startRuntime(options)
        runtime.updateSettings { $0.sleepPolicy = .always }
        runtime.ingest(provider: "claude", line: RuntimeRecords.prompt())
        runtime.waitUntilIdle()
        XCTAssertFalse(runtime.keepAwakeActive)
        XCTAssertEqual(holder.calls, [])
        XCTAssertEqual(battery.reads, 0)
    }

    func testKeepAwakeReportsWhatIsActuallyHeld() throws {
        let holder = FakeKeepAwake()
        holder.failToHold = true
        var options = world.options(serveSocket: false)
        options.keepAwake = true
        options.keepAwakeHolder = holder
        options.batteryReader = { .unknown }
        let runtime = try world.startRuntime(options)
        runtime.updateSettings { $0.sleepPolicy = .always }
        runtime.waitUntilIdle()
        XCTAssertEqual(holder.calls.last, true)
        XCTAssertFalse(runtime.keepAwakeActive, "spawn failed: not held")
    }

    // MARK: Shutdown

    func testStopReleasesEverything() throws {
        world.addDevice("PulseDot")
        let holder = FakeKeepAwake()
        var options = world.options()
        options.keepAwake = true
        options.keepAwakeHolder = holder
        options.batteryReader = { .unknown }
        options.latestSaveDelay = 60
        let runtime = try world.startRuntime(options)
        runtime.ingest(provider: "claude", line: RuntimeRecords.prompt("bye"))
        waitForProgram("PulseDot", RuntimePrograms.expected(.working, ledCount: 2))
        runtime.waitUntilIdle()
        XCTAssertTrue(runtime.keepAwakeActive)
        runtime.preview(animationID: "kitt", seconds: 30)
        waitForProgram("PulseDot", RuntimePrograms.program("kitt", ledCount: 2))

        runtime.stop()
        XCTAssertFalse(EventSocketClient.isServerRunning(socketPath: world.paths.socketPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.paths.socketPath))
        XCTAssertEqual(latestAgentIDs(), ["claude:session:bye"], "flushed")
        XCTAssertFalse(holder.isHeld)
        XCTAssertFalse(runtime.keepAwakeActive)
        XCTAssertEqual(world.program("PulseDot"), RuntimePrograms.expected(.working, ledCount: 2),
                       "a playing preview is ended; LEDs keep live status")

        // Timers are gone: a newly mounted device is not written.
        world.addDevice("SidePulsePro")
        runtimeSpin(0.4)
        XCTAssertEqual(world.program("SidePulsePro"), "boot")
        // Events after stop change the snapshot but drive nothing.
        runtime.ingest(provider: "claude", line: RuntimeRecords.stop("bye"))
        runtime.waitUntilIdle()
        XCTAssertEqual(world.program("PulseDot"), RuntimePrograms.expected(.working, ledCount: 2))
        XCTAssertEqual(latestAgentIDs(), ["claude:session:bye"])
        XCTAssertEqual(LatestStore(url: world.paths.latestFile).load().first?.mode, .working)
    }

    /// Regression: previews and Manual switches after stop() used to write to the
    /// device (a preview, then "off").
    func testNothingIsWrittenAfterStop() throws {
        world.addDevice("PulseDot")
        let dot = world.deviceID("PulseDot")
        let runtime = try world.startRuntime()
        runtime.ingest(provider: "claude", line: RuntimeRecords.prompt())
        let working = RuntimePrograms.expected(.working, ledCount: 2)
        waitForProgram("PulseDot", working)
        runtime.waitUntilIdle()
        runtime.stop()

        runtime.preview(animationID: "kitt", seconds: 0.1)
        runtime.setDeviceDisplay(.manual, deviceID: dot)
        runtime.reloadSettings()
        runtime.refresh()
        runtime.ingest(provider: "claude", line: RuntimeRecords.permission())
        runtimeSpin(0.3)
        runtime.waitUntilIdle()
        XCTAssertEqual(world.program("PulseDot"), working)
        XCTAssertEqual(world.settingsStore.load().display(forDevice: dot), .manual, "the setting itself is still saved")

        // Started again (the device is Manual now): back to Agent, previews work.
        // The event taken while stopped survives the restart (latest.json has the
        // older Working row).
        try runtime.start()
        XCTAssertEqual(runtime.snapshot().aggregate.mode, .waitingForInput)
        runtime.setDeviceDisplay(.agent, deviceID: dot)
        waitForProgram("PulseDot", RuntimePrograms.expected(.waitingForInput, ledCount: 2))
        runtime.preview(animationID: "kitt", seconds: 30)
        waitForProgram("PulseDot", RuntimePrograms.program("kitt", ledCount: 2))
    }

    /// A preview racing stop() from another thread is either drained by stop() or
    /// refused: the device ends on live status either way.
    func testPreviewRacingStopNeverOutlivesIt() throws {
        world.addDevice("PulseDot")
        let live = RuntimePrograms.expected(.working, ledCount: 2)
        for _ in 0..<10 {
            let runtime = try world.startRuntime()
            runtime.ingest(provider: "claude", line: RuntimeRecords.prompt())
            waitForProgram("PulseDot", live)
            let spam = DispatchGroup()
            DispatchQueue.global().async(group: spam) {
                for index in 0..<200 { runtime.preview(animationID: index % 2 == 0 ? "kitt" : "ember-tide", seconds: 5) }
            }
            runtime.stop()
            XCTAssertEqual(spam.wait(timeout: .now() + 5), .success)
            runtime.leds.waitUntilIdle()
            XCTAssertEqual(world.program("PulseDot"), live)
            XCTAssertFalse(runtime.leds.isPreviewing)
        }
    }

    /// Regression: stop() returned while keepalive touches were still running.
    func testStopWaitsForKeepaliveTouchesInFlight() throws {
        world.addDevice("SidePulsePro")
        let finished = RuntimeInbox<String>()
        var options = world.options(serveSocket: false)
        options.keepaliveTouch = { url in
            usleep(300_000)
            finished.append(url.path)
        }
        let runtime = try world.startRuntime(options)
        runtime.ingest(provider: "claude", line: RuntimeRecords.prompt())
        runtime.stop()
        XCTAssertEqual(finished.items, [world.mounts.appendingPathComponent("SidePulsePro/keepalive").path])
    }

    /// Regression: `sidepulse run --interval 1e12` trapped in Dispatch (intervals
    /// are now clamped; NaN falls back to the default).
    func testExtremeIntervalsAreClampedInsteadOfCrashing() throws {
        world.addDevice("PulseDot")
        var options = world.options()
        options.refreshInterval = 1e12
        options.devicePollInterval = .infinity
        options.latestSaveDelay = .nan
        let runtime = try world.startRuntime(options)
        runtime.ingest(provider: "claude", line: RuntimeRecords.stop("far"))
        waitForProgram("PulseDot", RuntimePrograms.expected(.completed, ledCount: 2))
        runtime.stop()
        XCTAssertEqual(latestAgentIDs(), ["claude:session:far"])

        options.latestSaveDelay = 1e15
        options.refreshInterval = -.infinity
        options.devicePollInterval = .nan
        let other = try world.startRuntime(options)
        other.ingest(provider: "claude", line: RuntimeRecords.prompt("near"))
        other.stop()
        XCTAssertEqual(Set(latestAgentIDs()), ["claude:session:far", "claude:session:near"])
        XCTAssertEqual(RuntimeOptions.clamped(.nan, to: 1...2, fallback: 1.5), 1.5)
        XCTAssertEqual(RuntimeOptions.clamped(.infinity, to: 1...2, fallback: 1.5), 2)
        XCTAssertEqual(RuntimeOptions.clamped(-.infinity, to: 1...2, fallback: 1.5), 1)
    }

    /// Regression: start() discovered devices on the caller's thread (the app's
    /// main thread), so a hung volume under /Volumes stalled app launch.
    func testSlowFirstDiscoveryDoesNotHoldUpStart() throws {
        world.addDevice("PulseDot")
        let release = DispatchSemaphore(value: 0)
        let calls = RuntimeInbox<Bool>()
        let mounts = world.mounts
        var options = world.options()
        options.startupDiscoveryTimeout = 0.2
        options.deviceDiscovery = { roots in
            calls.append(true)
            if calls.count == 1 { release.wait() } // the first discovery hangs
            return DeviceDiscovery.discover(roots: roots ?? [mounts])
        }
        defer { release.signal() }
        let started = Date()
        let runtime = try world.startRuntime(options)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "start() did not wait for the hung discovery")
        runtime.ingest(provider: "claude", line: RuntimeRecords.permission())
        XCTAssertEqual(runtime.snapshot().aggregate.mode, .waitingForInput, "events flow meanwhile")
        XCTAssertEqual(world.program("PulseDot"), "boot")

        release.signal()
        waitForProgram("PulseDot", RuntimePrograms.expected(.waitingForInput, ledCount: 2))
        XCTAssertTrue(runtimeWait { self.world.settingsStore.load().device(id: self.world.deviceID("PulseDot")) != nil },
                      "remembered once found")
    }

    /// Regression: the socket serves before start-up has loaded latest.json and
    /// the logs; a `status` request in that window answered "Idle, no sessions".
    func testStatusDuringStartUpWaitsForTheRestoredRows() throws {
        let row = AgentStatus(provider: "claude", agentID: "claude:session:boot", displayName: "boot", mode: .working,
                              updatedAt: Date().addingTimeInterval(-5), eventName: "UserPromptSubmit", sessionID: "boot")
        try LatestStore(url: world.paths.latestFile).save([row])
        let bound = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var options = world.options()
        options.afterBind = {
            bound.signal()
            release.wait()
        }
        let runtime = world.makeRuntime(options)
        let startedUp = expectation(description: "started")
        DispatchQueue.global().async {
            do { try runtime.start() } catch { XCTFail("start failed: \(error)") }
            startedUp.fulfill()
        }
        XCTAssertEqual(bound.wait(timeout: .now() + 3), .success)
        let replies = RuntimeInbox<Data?>()
        let world = self.world!
        DispatchQueue.global().async { replies.append(world.request("status")) }
        runtimeSpin(0.3)
        XCTAssertEqual(replies.count, 0, "no answer before the rows are loaded")
        release.signal()
        wait(for: [startedUp], timeout: 5)
        XCTAssertTrue(runtimeWait { replies.count == 1 })
        let snapshot = try MonitorSnapshot.fromJSON(JSONValue.parse(XCTUnwrap(replies.items.first ?? nil)))
        XCTAssertEqual(snapshot?.statuses.map(\.agentID), ["claude:session:boot"])
        let reply = try XCTUnwrap(world.request("status"))
        XCTAssertEqual(MonitorSnapshot.fromJSON(try JSONValue.parse(reply))?.aggregate.mode, .working)
    }

    /// Regression: a latest.json that cannot be written was logged on every save
    /// (about once a second while agents work).
    func testLatestSaveFailuresAreLoggedOnceAndRecoveryToo() throws {
        let logURL = world.root.appendingPathComponent("diag.log")
        let previousURL = DiagnosticsLog.shared.url
        DiagnosticsLog.shared.url = logURL
        defer {
            DiagnosticsLog.shared.flush()
            DiagnosticsLog.shared.url = previousURL
        }
        // A non-empty directory where latest.json should be: every save fails.
        try FileManager.default.createDirectory(at: world.paths.latestFile, withIntermediateDirectories: true)
        try "x".write(to: world.paths.latestFile.appendingPathComponent("keep"), atomically: true, encoding: .utf8)
        var options = world.options(serveSocket: false)
        options.latestSaveDelay = 0.02
        let runtime = try world.startRuntime(options)
        for index in 0..<5 {
            runtime.ingest(provider: "claude", line: RuntimeRecords.prompt("s\(index)"))
            runtimeSpin(0.05)
        }
        runtime.waitUntilIdle()
        try FileManager.default.removeItem(at: world.paths.latestFile)
        runtime.ingest(provider: "claude", line: RuntimeRecords.stop("s0"))
        XCTAssertTrue(runtimeWait { self.latestAgentIDs().count == 5 })
        runtime.stop()
        DiagnosticsLog.shared.flush()
        let lines = (try? String(contentsOf: logURL, encoding: .utf8))?.split(separator: "\n") ?? []
        XCTAssertEqual(lines.filter { $0.contains("could not save") }.count, 1, lines.joined(separator: "\n"))
        XCTAssertEqual(lines.filter { $0.contains("works again") }.count, 1, lines.joined(separator: "\n"))
    }

    /// start()/stop() cycles and concurrent stop() calls while hooks, `status` and
    /// `ping` hit the socket: no crash or deadlock, and the runtime still works.
    func testStartStopCyclesUnderSocketTraffic() throws {
        world.addDevice("PulseDot")
        let runtime = world.makeRuntime()
        let done = RuntimeInbox<Bool>()
        let world = self.world!
        let traffic = DispatchGroup()
        for worker in 0..<3 {
            DispatchQueue.global().async(group: traffic) {
                var index = 0
                while done.count == 0 {
                    index += 1
                    switch (index + worker) % 4 {
                    case 0: world.send(RuntimeRecords.prompt("w\(worker)"))
                    case 1: _ = world.request("status")
                    case 2: _ = world.request("ping")
                    default: world.send(RuntimeRecords.stop("w\(worker)"))
                    }
                }
            }
        }
        for cycle in 0..<12 {
            try runtime.start()
            runtimeSpin(0.02)
            if cycle % 3 == 0 {
                let stops = DispatchGroup()
                for _ in 0..<3 { DispatchQueue.global().async(group: stops) { runtime.stop() } }
                XCTAssertEqual(stops.wait(timeout: .now() + 10), .success)
            } else {
                runtime.stop()
            }
            XCTAssertFalse(runtime.isRunning)
        }
        done.append(true)
        XCTAssertEqual(traffic.wait(timeout: .now() + 10), .success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.paths.socketPath))

        try runtime.start()
        runtime.ingest(provider: "claude", line: RuntimeRecords.permission("final"))
        waitForProgram("PulseDot", RuntimePrograms.expected(.waitingForInput, ledCount: 2))
    }

    func testDryRunRuntimeNeverWrites() throws {
        world.addDevice("PulseDot")
        world.addDevice("SidePulsePro")
        var options = world.options(serveSocket: false)
        options.dryRun = true
        let runtime = try world.startRuntime(options)
        runtime.ingest(provider: "claude", line: RuntimeRecords.prompt())
        runtime.setDeviceDisplay(.manual, deviceID: world.deviceID("PulseDot"))
        runtime.waitUntilIdle()
        XCTAssertEqual(world.program("PulseDot"), "boot")
        XCTAssertEqual(world.program("SidePulsePro"), "boot")
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.mounts.appendingPathComponent("SidePulsePro/keepalive").path))
    }
}
