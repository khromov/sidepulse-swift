import Darwin
import Foundation
import XCTest
@testable import SidePulseCore

final class RuntimeSettingsTests: XCTestCase {
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

    // MARK: Manual mode

    func testSwitchingToManualWritesOffOnceThenLeavesTheDeviceAlone() throws {
        world.addDevice("PulseDot")
        world.addDevice("SidePulsePro")
        let dot = world.deviceID("PulseDot")
        let runtime = try world.startRuntime()
        runtime.ingest(provider: "claude", line: RuntimeRecords.prompt())
        waitForProgram("PulseDot", RuntimePrograms.expected(.working, ledCount: 2))

        runtime.setDeviceDisplay(.manual, deviceID: dot)
        XCTAssertEqual(runtime.settings.display(forDevice: dot), .manual, "visible at once")
        waitForProgram("PulseDot", "off")
        runtime.waitUntilIdle()
        XCTAssertEqual(world.settingsStore.load().display(forDevice: dot), .manual)
        XCTAssertEqual(runtime.deviceInfos().first { $0.id == dot }?.display, .manual)

        world.overwrite("PulseDot", with: "#FF00FF pulse")
        runtime.ingest(provider: "claude", line: RuntimeRecords.permission())
        waitForProgram("SidePulsePro", RuntimePrograms.expected(.waitingForInput, ledCount: 8))
        runtime.refresh()
        runtime.waitUntilIdle()
        XCTAssertEqual(world.program("PulseDot"), "#FF00FF pulse")

        // Choosing Manual again is not a switch: nothing is cleared.
        runtime.setDeviceDisplay(.manual, deviceID: dot)
        runtime.waitUntilIdle()
        XCTAssertEqual(world.program("PulseDot"), "#FF00FF pulse")

        runtime.setDeviceDisplay(.agent, deviceID: dot)
        waitForProgram("PulseDot", RuntimePrograms.expected(.waitingForInput, ledCount: 2))
    }

    func testManualForDisconnectedDeviceIsOnlySaved() throws {
        world.addDevice("PulseDot")
        let runtime = try world.startRuntime()
        waitForProgram("PulseDot", RuntimePrograms.expected(.idleReady, ledCount: 2))
        runtime.setDeviceDisplay(.manual, deviceID: "/Volumes/Elsewhere")
        runtime.waitUntilIdle()
        XCTAssertEqual(world.settingsStore.load().display(forDevice: "/Volumes/Elsewhere"), .manual)
    }

    /// Mirrors `sidepulse write --manual`, which flips the device to Manual, asks for reload-settings and
    /// then writes its own program.
    func testReloadSettingsAppliesBeforeReplyingAndNeverClearsTheDevice() throws {
        world.addDevice("PulseDot")
        let dot = world.deviceID("PulseDot")
        let runtime = try world.startRuntime()
        runtime.ingest(provider: "claude", line: RuntimeRecords.prompt())
        let working = RuntimePrograms.expected(.working, ledCount: 2)
        waitForProgram("PulseDot", working)

        world.updateSettings { $0.setDisplay(.manual, forDevice: dot, name: "SidePulse Dot", path: dot) }
        XCTAssertEqual(world.requestText("reload-settings"), "ok")
        XCTAssertEqual(runtime.settings.display(forDevice: dot), .manual)
        XCTAssertEqual(runtime.deviceInfos().first?.display, .manual)
        XCTAssertEqual(world.program("PulseDot"), working, "reload-settings never writes off")

        world.overwrite("PulseDot", with: "#00FF66 320ms cosine\nrepeat")
        runtime.ingest(provider: "claude", line: RuntimeRecords.stop())
        runtime.refresh()
        runtime.waitUntilIdle()
        XCTAssertEqual(world.program("PulseDot"), "#00FF66 320ms cosine\nrepeat")

        world.updateSettings { $0.setAnimation("solid-green", for: .completed) }
        XCTAssertEqual(runtime.handle(.command(name: "reload-settings", args: [:])), IPCReply.ok)
        XCTAssertEqual(runtime.settings.animationID(for: .completed), "solid-green")
    }

    /// Regression: the app's write waiting in open() on the macOS permission prompt
    /// showed nothing, and after `sidepulse write --manual` it landed on the
    /// Manual device once the prompt was answered.
    func testWriteWaitingForPermissionShowsAndNeverOverwritesADeviceMadeManual() throws {
        world.addDevice("PulseDot", content: nil)
        XCTAssertEqual(mkfifo(world.target("PulseDot").path, 0o644), 0) // open() blocks until a reader comes
        let dot = world.deviceID("PulseDot")
        let runtime = try world.startRuntime()
        let updates = RuntimeInbox<Bool>()
        runtime.onUpdate = { _ in updates.append(true) }

        // Nothing else triggers onUpdate here, so an update proves the notice itself refreshes the menu.
        XCTAssertTrue(runtimeWait(timeout: 5) {
            runtime.deviceInfos().first?.lastError == LedSyncService.waitingForPermissionMessage
        })
        XCTAssertTrue(runtimeWait { updates.count > 0 })

        // The reply comes at once because the stuck write has not started writing and will re-check.
        world.updateSettings { $0.setDisplay(.manual, forDevice: dot, name: "SidePulse Dot", path: dot) }
        let asked = Date()
        XCTAssertEqual(world.requestText("reload-settings"), "ok")
        XCTAssertLessThan(Date().timeIntervalSince(asked), 1)
        runtimeSpin(0.2)
        let notified = updates.count

        // Opening a reader stands in for answering the prompt.
        let reader = open(world.target("PulseDot").path, O_RDONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(reader, 0)
        defer { close(reader) }
        runtime.waitUntilIdle()
        var buffer = [UInt8](repeating: 0, count: 1024)
        XCTAssertEqual(read(reader, &buffer, buffer.count), 0, "nothing written to the Manual device")
        XCTAssertTrue(runtimeWait { runtime.deviceInfos().first?.lastError == nil })
        XCTAssertTrue(runtimeWait { updates.count > notified }, "the notice going away refreshes the menu too")
    }

    /// Regression: reload-settings replied ok while a write that had passed its settings check was still
    /// writing, so it landed on top of `sidepulse write --manual`'s program.
    func testReloadSettingsReportsAWriteThatIsStillWriting() throws {
        world.addDevice("PulseDot", content: nil)
        let target = world.target("PulseDot").path
        XCTAssertEqual(mkfifo(target, 0o644), 0)
        // A reader that does not read and a full pipe: the app's open() returns and
        // its write() blocks, like a card that stops answering mid-write.
        let reader = open(target, O_RDONLY | O_NONBLOCK)
        let filler = open(target, O_WRONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(reader, 0)
        XCTAssertGreaterThanOrEqual(filler, 0)
        var chunk = [UInt8](repeating: 0x20, count: 1024)
        while write(filler, &chunk, chunk.count) > 0 {}
        let dot = world.deviceID("PulseDot")
        let runtime = try world.startRuntime()
        func drain() -> Bool {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            return runtimeWait {
                _ = read(reader, &buffer, buffer.count)
                return runtime.leds.waitForWrites(timeout: 0)
            }
        }
        // The blocked write must finish before the reader goes away (SIGPIPE).
        defer { _ = drain(); close(filler); close(reader) }
        XCTAssertTrue(runtimeWait { !runtime.leds.waitForWrites(timeout: 0) }, "the write passed its check")

        world.updateSettings { $0.setDisplay(.manual, forDevice: dot, name: "SidePulse Dot", path: dot) }
        let asked = Date()
        let reply = try JSONValue.parse(XCTUnwrap(world.request("reload-settings")))
        XCTAssertEqual(reply["ok"], .bool(false))
        XCTAssertEqual(reply["error"]?.stringValue, "LED write in progress")
        XCTAssertGreaterThan(Date().timeIntervalSince(asked), 1.5, "waited for the write first")

        XCTAssertTrue(drain())
        runtime.waitUntilIdle()
        XCTAssertEqual(world.requestText("reload-settings"), "ok")
    }

    // MARK: Brightness and LED output

    func testBrightnessChangeRewritesTheDevice() throws {
        world.addDevice("PulseDot")
        world.addDevice("SidePulsePro")
        let pro = world.deviceID("SidePulsePro")
        let runtime = try world.startRuntime()
        runtime.ingest(provider: "claude", line: RuntimeRecords.prompt())
        waitForProgram("SidePulsePro", RuntimePrograms.expected(.working, ledCount: 8))
        let dotBefore = world.program("PulseDot")

        runtime.setDeviceBrightness(64, deviceID: pro)
        XCTAssertEqual(runtime.settings.brightness(forDevice: pro), 64)
        waitForProgram("SidePulsePro", RuntimePrograms.expected(.working, ledCount: 8, brightness: 64))
        runtime.setDeviceBrightness(999, deviceID: pro)
        waitForProgram("SidePulsePro", RuntimePrograms.expected(.working, ledCount: 8, brightness: 255))
        runtime.waitUntilIdle()
        XCTAssertEqual(world.settingsStore.load().brightness(forDevice: pro), 255)
        XCTAssertEqual(world.program("PulseDot"), dotBefore, "other devices are untouched")
    }

    // MARK: External edits

    func testExternalSettingsEditIsPickedUpOnRefresh() throws {
        world.addDevice("PulseDot")
        let runtime = try world.startRuntime()
        runtime.ingest(provider: "claude", line: RuntimeRecords.prompt())
        waitForProgram("PulseDot", RuntimePrograms.expected(.working, ledCount: 2))

        world.updateSettings {
            $0.setAnimation("ember-tide", for: .working)
            $0.setBrightness(100, forDevice: world.deviceID("PulseDot"))
        }
        runtime.refresh()
        waitForProgram("PulseDot", RuntimePrograms.program("ember-tide", ledCount: 2, brightness: 100))
        XCTAssertEqual(runtime.settings.animationID(for: .working), "ember-tide")
    }

    func testExternalSettingsEditIsPickedUpByTheRefreshTimer() throws {
        world.addDevice("PulseDot")
        var options = world.options()
        options.refreshInterval = 0.2
        let runtime = try world.startRuntime(options)
        waitForProgram("PulseDot", RuntimePrograms.expected(.idleReady, ledCount: 2))
        world.updateSettings { $0.setAnimation("purple-idle", for: .idleReady) }
        waitForProgram("PulseDot", RuntimePrograms.program("purple-idle", ledCount: 2))
        XCTAssertEqual(runtime.settings.animationID(for: .idleReady), "purple-idle")
    }

    /// Regression: the runtime read settings.json's date after releasing the store's lock, so an external
    /// save in between looked already known and was never loaded.
    func testExternalSaveRacingOurOwnSaveIsNotMissed() throws {
        world.addDevice("PulseDot")
        let runtime = try world.startRuntime(world.options(serveSocket: false))
        runtime.updateSettings { $0.sleepPolicy = .never }
        runtime.waitUntilIdle()
        let url = world.paths.settingsFile
        var info = stat()
        XCTAssertEqual(stat(url.path, &info), 0)
        let ownSaveDate = world.settingsStore.modificationDate

        // Giving the external save our own save's exact date reproduces that window.
        world.updateSettings { $0.setAnimation("ember-tide", for: .idleReady) }
        var times = [info.st_atimespec, info.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, url.path, &times, 0), 0)
        XCTAssertEqual(world.settingsStore.modificationDate, ownSaveDate, "the race is reproduced")

        runtime.refresh()
        waitForProgram("PulseDot", RuntimePrograms.program("ember-tide", ledCount: 2))
        XCTAssertEqual(runtime.settings.animationID(for: .idleReady), "ember-tide")
        XCTAssertEqual(runtime.settings.sleepPolicy, .never)
    }

    func testIdleTimeoutChangeAppliesToTheMonitor() throws {
        let runtime = try world.startRuntime(world.options(serveSocket: false))
        runtime.ingest(provider: "claude", line: RuntimeRecords.prompt(secondsAgo: 120))
        XCTAssertEqual(runtime.snapshot().aggregate.mode, .working)
        let updated = expectation(description: "onUpdate")
        updated.assertForOverFulfill = false
        runtime.onUpdate = { snapshot in
            if snapshot.aggregate.mode == .idleReady { updated.fulfill() }
        }
        runtime.updateSettings { $0.idleTimeoutSeconds = 60 }
        wait(for: [updated], timeout: 3)
        XCTAssertEqual(runtime.snapshot().aggregate.staleCount, 1)
    }

    // MARK: UI contract

    func testUpdatesAreVisibleAtOnceSavedAndAnnouncedOnMain() throws {
        world.addDevice("PulseDot")
        let dot = world.deviceID("PulseDot")
        world.updateSettings { $0.devices = [DeviceSettings(id: "/Volumes/Gone", name: "SidePulse Pro",
                                                              path: "/Volumes/Gone", display: .agent, brightness: 255)] }
        let runtime = try world.startRuntime(world.options(serveSocket: false))
        runtime.waitUntilIdle()
        runtimeSpin(0.05)

        let updates = RuntimeInbox<Bool>()
        runtime.onUpdate = { _ in updates.append(Thread.isMainThread) }
        func expectUpdate(_ action: () -> Void, file: StaticString = #filePath, line: UInt = #line) {
            let before = updates.count
            action()
            XCTAssertTrue(runtimeWait { updates.count > before }, "onUpdate fired", file: file, line: line)
        }

        expectUpdate { runtime.updateSettings { $0.sleepPolicy = .always } }
        XCTAssertEqual(runtime.settings.sleepPolicy, .always)
        expectUpdate { runtime.setDeviceDisplay(.manual, deviceID: dot) }
        expectUpdate { runtime.setDeviceBrightness(10, deviceID: dot) }
        XCTAssertEqual(runtime.settings.brightness(forDevice: dot), 10)
        expectUpdate { runtime.removeDevice(id: "/Volumes/Gone") }
        XCTAssertNil(runtime.settings.device(id: "/Volumes/Gone"))
        expectUpdate { runtime.refresh() }
        expectUpdate { runtime.ingest(provider: "claude", line: RuntimeRecords.prompt()) }
        XCTAssertTrue(updates.items.allSatisfy { $0 }, "always on the main queue")

        runtime.waitUntilIdle()
        let saved = world.settingsStore.load()
        XCTAssertEqual(saved.sleepPolicy, .always)
        XCTAssertEqual(saved.display(forDevice: dot), .manual)
        XCTAssertEqual(saved.brightness(forDevice: dot), 10)
        XCTAssertEqual(saved.devices.map(\.id), [dot])
        XCTAssertEqual(runtime.deviceInfos().map(\.id), [dot])
    }

    func testRapidUpdatesDoNotSnapBack() throws {
        let runtime = try world.startRuntime(world.options(serveSocket: false))
        for value in [0.0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50] {
            runtime.updateSettings { $0.minBatteryPercent = value }
            XCTAssertEqual(runtime.settings.minBatteryPercent, value)
        }
        runtime.waitUntilIdle()
        XCTAssertEqual(runtime.settings.minBatteryPercent, 50)
        XCTAssertEqual(world.settingsStore.load().minBatteryPercent, 50)
    }

    func testMainThreadReadsNeverBlock() throws {
        world.addDevice("PulseDot")
        let dot = world.deviceID("PulseDot")
        let runtime = try world.startRuntime()
        runtime.waitUntilIdle()

        let ledGate = DispatchSemaphore(value: 0)
        runtime.leds.ioQueue.async { ledGate.wait() }
        defer { ledGate.signal() }
        runtime.ingest(provider: "claude", line: RuntimeRecords.prompt())

        // Another process holds the settings lock, so the next save waits.
        let lockFD = open(world.settingsStore.lockURL.path, O_RDWR | O_CREAT, 0o644)
        XCTAssertGreaterThanOrEqual(lockFD, 0)
        XCTAssertEqual(flock(lockFD, LOCK_EX), 0)
        runtime.setDeviceBrightness(42, deviceID: dot)

        let start = Date()
        for _ in 0..<20 {
            XCTAssertEqual(runtime.snapshot().aggregate.mode, .working)
            XCTAssertEqual(runtime.settings.brightness(forDevice: dot), 42)
            XCTAssertEqual(runtime.deviceInfos().first?.brightness, 42)
            _ = runtime.keepAwakeActive
            runtime.updateSettings { $0.sleepPolicy = .never }
            runtime.refresh()
            runtime.preview(animationID: "kitt", seconds: 0.1)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)

        flock(lockFD, LOCK_UN)
        close(lockFD)
        ledGate.signal()
        runtime.waitUntilIdle()
        XCTAssertEqual(world.settingsStore.load().brightness(forDevice: dot), 42)
    }
}
