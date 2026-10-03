import Darwin
import Foundation
import XCTest
@testable import SidePulseCore

private final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SidePulseSettings
    /// Runs outside the lock so a test can stall a sync mid-flight.
    var onRead: (@Sendable () -> Void)?

    init(_ settings: SidePulseSettings = SidePulseSettings()) { current = settings }

    var value: SidePulseSettings {
        get {
            onRead?()
            lock.lock(); defer { lock.unlock() }
            return current
        }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    func update(_ body: (inout SidePulseSettings) -> Void) {
        lock.lock(); body(&current); lock.unlock()
    }
}

final class RuntimeLedSyncServiceTests: XCTestCase {
    private var world: RuntimeWorld!
    private var box: SettingsBox!
    private var logs: RuntimeInbox<String>!

    override func setUp() {
        super.setUp()
        world = RuntimeWorld()
        box = SettingsBox()
        logs = RuntimeInbox()
    }

    override func tearDown() {
        world.tearDown()
        super.tearDown()
    }

    private func makeService(dryRun: Bool = false, keepalive: KeepaliveToucher = KeepaliveToucher(),
                             writer: @escaping LedSyncService.FileWriter = LedSyncService.fileWriter,
                             stallNotice: TimeInterval = 2) -> LedSyncService {
        let box = self.box!
        let logs = self.logs!
        return LedSyncService(settings: { box.value }, roots: [world.mounts], dryRun: dryRun,
                              log: { logs.append($0) }, keepalive: keepalive, writeFile: writer, stallNotice: stallNotice)
    }

    /// Returns whether the Manual clear wrote.
    private func clear(_ service: LedSyncService, _ deviceID: String) throws -> Bool {
        let outcome = RuntimeInbox<Result<Bool, Error>>()
        service.clearManualDevice(deviceID: deviceID) { outcome.append($0) }
        XCTAssertTrue(service.waitUntilIdle())
        return try XCTUnwrap(outcome.items.first).get()
    }

    private func deviceInfos(_ service: LedSyncService) -> [DeviceInfo] {
        service.deviceInfos(settings: box.value)
    }

    // MARK: syncNow

    func testSyncNowWritesPerDeviceProgramsWithLedCountAndBrightness() throws {
        world.addDevice("PulseDot")
        world.addDevice("SidePulsePro")
        box.update { $0.setBrightness(128, forDevice: world.deviceID("SidePulsePro")) }
        let service = makeService()
        XCTAssertTrue(service.pollDevices())
        XCTAssertEqual(service.connectedDevices.map(\.id).sorted(),
                       [world.deviceID("PulseDot"), world.deviceID("SidePulsePro")])

        let results = service.syncNow(mode: .working)
        XCTAssertEqual(Set(results.keys), [world.deviceID("PulseDot"), world.deviceID("SidePulsePro")])
        let dot = RuntimePrograms.expected(.working, ledCount: 2)
        let pro = RuntimePrograms.expected(.working, ledCount: 8, brightness: 128)
        XCTAssertNotEqual(dot, RuntimePrograms.expected(.working, ledCount: 8), "Dot and Pro use different variants")
        XCTAssertTrue(pro.hasPrefix("brightness 128\n"), pro)
        XCTAssertEqual(world.program("PulseDot"), dot)
        XCTAssertEqual(world.program("SidePulsePro"), pro)
        XCTAssertEqual(results[world.deviceID("PulseDot")], LedSyncResult(changed: true, program: dot, target: world.target("PulseDot")))

        // Tool Running shows the same program as Working, so the write is deduped.
        let again = service.syncNow(mode: .toolRunning)
        XCTAssertEqual(again[world.deviceID("PulseDot")]?.changed, false)
        world.overwrite("PulseDot", with: "off")
        XCTAssertEqual(service.syncNow(mode: .working)[world.deviceID("PulseDot")]?.changed, true)
        XCTAssertEqual(world.program("PulseDot"), dot)

        service.syncNow(mode: .waitingForInput)
        XCTAssertEqual(world.program("PulseDot"), RuntimePrograms.expected(.waitingForInput, ledCount: 2))
        service.syncNow(mode: .completed)
        XCTAssertEqual(world.program("SidePulsePro"), RuntimePrograms.expected(.completed, ledCount: 8, brightness: 128))
    }

    func testSyncNowSkipsManualDevices() {
        world.addDevice("PulseDot")
        world.addDevice("SidePulsePro")
        box.update { $0.setDisplay(.manual, forDevice: world.deviceID("PulseDot")) }
        let service = makeService()
        service.pollDevices()

        let results = service.syncNow(mode: .working)
        XCTAssertEqual(Array(results.keys), [world.deviceID("SidePulsePro")])
        XCTAssertEqual(world.program("PulseDot"), "boot", "Manual devices are never written")

        box.update { $0.setDisplay(.agent, forDevice: world.deviceID("PulseDot")) }
        service.syncNow(mode: .completed)
        XCTAssertEqual(world.program("PulseDot"), RuntimePrograms.expected(.completed, ledCount: 2))
    }

    func testDryRunNeverWritesOrTouchesKeepalive() {
        world.addDevice("PulseDot")
        let service = makeService(dryRun: true)
        service.pollDevices()
        let result = service.syncNow(mode: .working)[world.deviceID("PulseDot")]
        XCTAssertEqual(result?.changed, true)
        XCTAssertEqual(result?.program, RuntimePrograms.expected(.working, ledCount: 2))
        box.update { $0.setDisplay(.manual, forDevice: world.deviceID("PulseDot")) }
        XCTAssertEqual(try clear(service, world.deviceID("PulseDot")), false)
        box.update { $0.setDisplay(.agent, forDevice: world.deviceID("PulseDot")) }
        service.preview(animationID: "kitt", seconds: 0)
        service.waitUntilIdle()
        XCTAssertEqual(world.program("PulseDot"), "boot")
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.mounts.appendingPathComponent("PulseDot/keepalive").path))
    }

    /// Regression: the USB Dot got a keepalive write every minute it does not need.
    func testKeepaliveIsTouchedForConnectedEightLedDevices() {
        world.addDevice("PulseDot")
        world.addDevice("SidePulsePro")
        world.addDevice("NO NAME")
        box.update { $0.setDisplay(.manual, forDevice: world.deviceID("SidePulsePro")) }
        let touched = RuntimeInbox<String>()
        let toucher = KeepaliveToucher(interval: 60) { touched.append($0.path) }
        let service = makeService(keepalive: toucher)
        service.pollDevices()
        service.syncNow(mode: .working)
        XCTAssertTrue(toucher.waitForPendingTouches())
        // Manual Pros are kept awake too (the SD reader powers down any idle card);
        // Dots sit on USB and are left alone.
        XCTAssertEqual(Set(touched.items), [world.mounts.appendingPathComponent("NO NAME/keepalive").path,
                                            world.mounts.appendingPathComponent("SidePulsePro/keepalive").path])
        service.touchKeepalive()
        XCTAssertTrue(toucher.waitForPendingTouches())
        XCTAssertEqual(touched.count, 2, "rate limited to once a minute")

        let real = makeService()
        real.pollDevices()
        real.touchKeepalive()
        XCTAssertTrue(runtimeWait {
            FileManager.default.fileExists(atPath: self.world.mounts.appendingPathComponent("SidePulsePro/keepalive").path)
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.mounts.appendingPathComponent("PulseDot/keepalive").path))
    }

    // MARK: Coalescing

    func testRequestSyncCoalescesToTheLatestMode() {
        world.addDevice("PulseDot")
        let service = makeService()
        service.pollDevices()
        let gate = DispatchSemaphore(value: 0)
        service.ioQueue.async { gate.wait() }
        let modes: [AgentMode] = [.working, .waitingForInput, .toolRunning, .idleReady]
        for index in 0..<199 { service.requestSync(mode: modes[index % modes.count]) }
        service.requestSync(mode: .completed)
        gate.signal()
        XCTAssertTrue(service.waitUntilIdle())
        XCTAssertEqual(service.syncPassCount, 1)
        XCTAssertEqual(world.program("PulseDot"), RuntimePrograms.expected(.completed, ledCount: 2))
    }

    /// Deliberate deviation from Python, which dropped a request made while a sync was in flight.
    func testRequestDuringInFlightSyncRunsAgain() {
        world.addDevice("PulseDot")
        let service = makeService()
        service.pollDevices()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let stalled = RuntimeInbox<Bool>()
        box.onRead = {
            // Stall only the first sync pass, which runs on the I/O queue.
            guard stalled.count == 0, !Thread.isMainThread else { return }
            stalled.append(true)
            entered.signal()
            release.wait()
        }
        service.requestSync(mode: .working)
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        service.requestSync(mode: .waitingForInput)
        service.requestSync(mode: .completed)
        release.signal()
        XCTAssertTrue(runtimeWait { self.world.program("PulseDot") == RuntimePrograms.expected(.completed, ledCount: 2) })
        service.waitUntilIdle()
        XCTAssertEqual(service.syncPassCount, 2)
        XCTAssertEqual(world.program("PulseDot"), RuntimePrograms.expected(.completed, ledCount: 2))
    }

    // MARK: Devices

    func testPollDevicesReportsChangesAndResetsChangedDevices() {
        let service = makeService()
        XCTAssertFalse(service.pollDevices(), "nothing connected, nothing changed")
        world.addDevice("PulseDot")
        XCTAssertTrue(service.pollDevices())
        XCTAssertFalse(service.pollDevices())
        service.syncNow(mode: .working)
        let program = RuntimePrograms.expected(.working, ledCount: 2)
        XCTAssertEqual(world.program("PulseDot"), program)
        XCTAssertTrue(logs.items.contains { $0.hasPrefix("devices: connected SidePulse Dot") }, "\(logs.items)")

        // A replugged card's controller was reset, so it is written again even if it holds the same program.
        world.removeDevice("PulseDot")
        XCTAssertTrue(service.pollDevices())
        XCTAssertEqual(service.connectedDevices, [])
        XCTAssertTrue(logs.items.contains("devices: disconnected \(world.deviceID("PulseDot"))"), "\(logs.items)")
        world.addDevice("PulseDot", content: program)
        XCTAssertTrue(service.pollDevices())
        XCTAssertEqual(service.syncNow(mode: .working)[world.deviceID("PulseDot")]?.changed, true)

        // A name-matched folder without LEDS.LED is a device too.
        world.addDevice("SidePulsePro", content: nil)
        XCTAssertTrue(service.pollDevices())
        service.syncNow(mode: .working)
        XCTAssertEqual(world.program("SidePulsePro"), RuntimePrograms.expected(.working, ledCount: 8))
    }

    func testDeviceInfosMergeRememberedAndConnectedWithDistinctNames() {
        world.addDevice("PulseDot")
        world.addDevice("SidePulsePro")
        let dotID = world.deviceID("PulseDot")
        box.update { settings in
            settings.devices = [
                DeviceSettings(id: "/Volumes/PulseDot 1", name: "SidePulse Dot", path: "/Volumes/PulseDot 1",
                               display: .manual, brightness: 40),
                DeviceSettings(id: dotID, name: "SidePulse Dot", path: dotID, display: .agent, brightness: 25),
                DeviceSettings(id: "/Volumes/Old Pro", name: "SidePulse Pro", path: "/Volumes/Old Pro",
                               display: .agent, brightness: 300),
                DeviceSettings(id: "/Volumes/Another", name: "Another", path: "/Volumes/Another",
                               display: .agent, brightness: 255),
            ]
        }
        let service = makeService()
        service.pollDevices()
        let infos = deviceInfos(service)
        XCTAssertEqual(infos.map(\.name), ["SidePulse Dot", "SidePulse Pro", "Another", "SidePulse Dot (PulseDot 1)",
                                           "SidePulse Pro (Old Pro)"])
        XCTAssertEqual(infos.map(\.connected), [true, true, false, false, false])
        XCTAssertEqual(infos[0].id, dotID)
        XCTAssertEqual(infos[0].brightness, 25)
        XCTAssertEqual(infos[0].ledCount, 2)
        XCTAssertEqual(infos[0].target, world.target("PulseDot"))
        XCTAssertEqual(infos[1].ledCount, 8)
        XCTAssertEqual(infos[1].brightness, 255, "never-seen devices default to full brightness")
        XCTAssertEqual(infos[3].display, .manual)
        XCTAssertEqual(infos[3].ledCount, 2)
        XCTAssertEqual(infos[3].target.path, "/Volumes/PulseDot 1/LEDS.LED")
        XCTAssertEqual(infos[4].brightness, 255, "clamped")
        XCTAssertEqual(Set(infos.map(\.name)).count, infos.count)

        world.addDevice("PulseDot 1")
        service.pollDevices()
        let names = deviceInfos(service).filter(\.connected).map(\.name)
        XCTAssertEqual(names, ["SidePulse Dot", "SidePulse Dot (PulseDot 1)", "SidePulse Pro"])
    }

    func testDisambiguationFallsBackToThePath() {
        func info(_ name: String, _ root: String) -> DeviceInfo {
            DeviceInfo(id: root, name: name, root: URL(fileURLWithPath: root), target: URL(fileURLWithPath: root + "/LEDS.LED"),
                       connected: true, display: .agent, brightness: 255, ledCount: 2)
        }
        let names = LedSyncService.disambiguated([
            info("SidePulse Dot", "/a/PulseDot"), info("SidePulse Dot", "/b/PulseDot"), info("SidePulse Dot", "/c/PulseDot"),
        ]).map(\.name)
        XCTAssertEqual(names, ["SidePulse Dot", "SidePulse Dot (PulseDot)", "SidePulse Dot (/c/PulseDot)"])
    }

    func testDeviceErrorsAreReportedAndLoggedOnce() throws {
        world.addDevice("PulseDot")
        let service = makeService()
        service.pollDevices()
        // Make the target unwritable: a directory named LEDS.LED.
        try FileManager.default.removeItem(at: world.target("PulseDot"))
        try FileManager.default.createDirectory(at: world.target("PulseDot"), withIntermediateDirectories: false)
        let result = service.syncNow(mode: .working)[world.deviceID("PulseDot")]
        XCTAssertNotNil(result?.error)
        XCTAssertEqual(deviceInfos(service).first?.lastError, result?.error)
        service.syncNow(mode: .working)
        XCTAssertEqual(logs.items.filter { $0.hasPrefix("leds: error") }.count, 1, "\(logs.items)")

        XCTAssertThrowsError(try clear(service, "/nope"))
    }

    /// Regression: a denied macOS permission showed only a raw EPERM.
    func testRefusedOpenNamesTheMacOSPrivacySettingAndLogsTheOriginalError() throws {
        world.addDevice("PulseDot")
        let refusal = "Could not open \(world.target("PulseDot").path): Operation not permitted"
        let service = makeService(writer: { _, _, _, _ in throw LedError.accessDenied(refusal) })
        service.pollDevices()

        let result = service.syncNow(mode: .working)[world.deviceID("PulseDot")]
        XCTAssertEqual(result?.error, LedSyncService.accessDeniedMessage)
        XCTAssertEqual(deviceInfos(service).first?.lastError, LedSyncService.accessDeniedMessage)
        service.syncNow(mode: .completed)
        XCTAssertEqual(logs.items.filter { $0.hasSuffix(refusal) }.count, 1, "\(logs.items)")
        XCTAssertEqual(world.program("PulseDot"), "boot")
    }

    /// Regression: a plain EACCES (a read-only file) also sent the user to the Privacy settings.
    func testReadOnlyFileIsAPlainWriteError() throws {
        world.addDevice("PulseDot")
        chmod(world.target("PulseDot").path, 0o444)
        defer { chmod(world.target("PulseDot").path, 0o644) }
        let service = makeService()
        service.pollDevices()

        let result = service.syncNow(mode: .working)[world.deviceID("PulseDot")]
        XCTAssertEqual(result?.error, "Could not open \(world.target("PulseDot").path): Permission denied")
        XCTAssertEqual(deviceInfos(service).first?.lastError, result?.error)
        XCTAssertEqual(world.program("PulseDot"), "boot")
    }

    /// Regression: while open() waited on the macOS permission prompt nothing
    /// showed, and the stale write then overwrote a device switched to Manual.
    func testWriteWaitingInOpenShowsAsWaitingAndSkipsADeviceThatBecameManual() {
        world.addDevice("PulseDot")
        let dot = world.deviceID("PulseDot")
        let gate = LedWriteGate()
        let service = makeService(writer: gate.writer, stallNotice: 0.2)
        service.pollDevices()
        XCTAssertFalse(service.checkDeviceStatus())

        gate.arm(.inOpen)
        service.requestSync(mode: .working)
        XCTAssertTrue(gate.waitForHeldWrite())
        XCTAssertTrue(runtimeWait { self.deviceInfos(service).first?.lastError == LedSyncService.waitingForPermissionMessage })
        XCTAssertTrue(service.checkDeviceStatus(), "the UI is told once")
        XCTAssertFalse(service.checkDeviceStatus())
        XCTAssertEqual(logs.items.filter { $0.contains("waiting for macOS permission?") }.count, 1, "\(logs.items)")

        // A write still blocked in open() is not waited for; it re-checks the settings once open() returns.
        box.update { $0.setDisplay(.manual, forDevice: dot) }
        XCTAssertTrue(service.waitForWrites(timeout: 0.1))
        gate.release()
        XCTAssertTrue(service.waitUntilIdle())
        XCTAssertEqual(world.program("PulseDot"), "boot")
        XCTAssertNil(deviceInfos(service).first?.lastError)
        XCTAssertTrue(service.checkDeviceStatus(), "the notice goes away")

        // Back to Agent: the declined write was not remembered, so it is written now.
        box.update { $0.setDisplay(.agent, forDevice: dot) }
        service.requestSync(mode: .working)
        XCTAssertTrue(service.waitUntilIdle())
        XCTAssertEqual(world.program("PulseDot"), RuntimePrograms.expected(.working, ledCount: 2))
    }

    /// Regression: `reload-settings` for one device waited for a slow write to any other.
    func testWaitForWritesOnlyWaitsForTheNamedDevice() {
        world.addDevice("PulseDot")
        world.addDevice("SidePulsePro")
        let gate = LedWriteGate()
        let service = makeService(writer: gate.writer)
        service.pollDevices()
        gate.arm(.afterCheck)
        service.requestSync(mode: .working)
        XCTAssertTrue(gate.waitForHeldWrite())
        defer { gate.release() }

        // Devices are synced in name order, so the Dot's write is the one held.
        XCTAssertFalse(service.waitForWrites(deviceID: world.deviceID("PulseDot"), timeout: 0.2))
        XCTAssertFalse(service.waitForWrites(timeout: 0.2), "no device named: every device")
        let started = Date()
        XCTAssertTrue(service.waitForWrites(deviceID: world.deviceID("SidePulsePro"), timeout: 2))
        XCTAssertTrue(service.waitForWrites(deviceID: "/Volumes/Never Seen", timeout: 2))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    /// Regression: the Manual clear was written unconditionally, so once a stuck open() returned it
    /// could overwrite a program the user wrote meanwhile.
    func testManualClearWritesOffOnlyOverWhatSidePulseLastWrote() throws {
        world.addDevice("PulseDot")
        let dot = world.deviceID("PulseDot")
        let service = makeService()
        service.pollDevices()

        box.update { $0.setDisplay(.manual, forDevice: dot) }
        XCTAssertEqual(try clear(service, dot), false, "SidePulse never wrote to it")
        XCTAssertEqual(world.program("PulseDot"), "boot")

        box.update { $0.setDisplay(.agent, forDevice: dot) }
        service.syncNow(mode: .working)
        let working = RuntimePrograms.expected(.working, ledCount: 2)
        XCTAssertEqual(try clear(service, dot), false, "not Manual")
        XCTAssertEqual(world.program("PulseDot"), working)

        box.update { $0.setDisplay(.manual, forDevice: dot) }
        XCTAssertEqual(try clear(service, dot), true)
        XCTAssertEqual(world.program("PulseDot"), "off")

        box.update { $0.setDisplay(.agent, forDevice: dot) }
        XCTAssertEqual(service.syncNow(mode: .working)[dot]?.changed, true)
        XCTAssertEqual(world.program("PulseDot"), working)
        box.update { $0.setDisplay(.manual, forDevice: dot) }
        world.overwrite("PulseDot", with: "#FF00FF pulse")
        XCTAssertEqual(try clear(service, dot), false)
        XCTAssertEqual(world.program("PulseDot"), "#FF00FF pulse")
    }

    /// Regression: after a bounded stop() gave up, a write stuck in open() and the syncs queued behind it
    /// landed once open() returned.
    func testClosedServiceDropsQueuedAndBlockedWritesUntilReopened() {
        world.addDevice("PulseDot")
        let gate = LedWriteGate()
        let service = makeService(writer: gate.writer)
        service.pollDevices()
        service.syncNow(mode: .idleReady)
        let idle = RuntimePrograms.expected(.idleReady, ledCount: 2)

        gate.arm(.inOpen)
        service.requestSync(mode: .working)
        XCTAssertTrue(gate.waitForHeldWrite())
        service.requestSync(mode: .waitingForInput)
        service.preview(animationID: "kitt", seconds: 0)
        service.close(generation: service.currentGeneration)
        gate.release()
        XCTAssertTrue(service.waitUntilIdle())
        runtimeSpin(0.1)
        XCTAssertTrue(service.waitUntilIdle())
        XCTAssertEqual(world.program("PulseDot"), idle)

        service.reopen()
        service.requestSync(mode: .completed)
        XCTAssertTrue(service.waitUntilIdle())
        XCTAssertEqual(world.program("PulseDot"), RuntimePrograms.expected(.completed, ledCount: 2))
    }

    func testWaitForWritesWaitsForAWriteThatPassedItsCheck() {
        world.addDevice("PulseDot")
        let service = makeService()
        service.pollDevices()
        let checking = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let reads = RuntimeInbox<Bool>()
        box.onRead = {
            // The pass reads the settings once, then the write checks them once the file is open.
            guard !Thread.isMainThread else { return }
            reads.append(true)
            guard reads.count == 2 else { return }
            checking.signal()
            release.wait()
        }
        service.requestSync(mode: .working)
        XCTAssertEqual(checking.wait(timeout: .now() + 3), .success)
        XCTAssertFalse(service.waitForWrites(timeout: 0.2))
        release.signal()
        XCTAssertTrue(service.waitForWrites(timeout: 3))
        XCTAssertEqual(world.program("PulseDot"), RuntimePrograms.expected(.working, ledCount: 2))
    }

    func testStalledKeepaliveTouchShowsAsWaiting() {
        world.addDevice("SidePulsePro")
        box.update { $0.setDisplay(.manual, forDevice: world.deviceID("SidePulsePro")) }
        let release = DispatchSemaphore(value: 0)
        let toucher = KeepaliveToucher(interval: 60) { _ in release.wait() }
        let service = makeService(keepalive: toucher, stallNotice: 0.2)
        service.pollDevices()
        service.touchKeepalive()
        XCTAssertTrue(runtimeWait { self.deviceInfos(service).first?.lastError == LedSyncService.waitingForPermissionMessage })
        release.signal()
        XCTAssertTrue(toucher.waitForPendingTouches())
        XCTAssertNil(deviceInfos(service).first?.lastError)
    }

    // MARK: Previews

    func testPreviewPlaysThenRestoresLiveStatus() {
        world.addDevice("PulseDot")
        world.addDevice("SidePulsePro")
        box.update {
            $0.setBrightness(51, forDevice: world.deviceID("SidePulsePro"))
            $0.setDisplay(.manual, forDevice: world.deviceID("PulseDot"))
        }
        let service = makeService()
        service.pollDevices()
        service.syncNow(mode: .working)
        let live = RuntimePrograms.expected(.working, ledCount: 8, brightness: 51)
        XCTAssertEqual(world.program("SidePulsePro"), live)

        service.preview(animationID: "kitt", seconds: 0.5)
        let kitt = RuntimePrograms.program("kitt", ledCount: 8, brightness: 51)
        XCTAssertTrue(runtimeWait { self.world.program("SidePulsePro") == kitt })
        XCTAssertEqual(world.program("PulseDot"), "boot", "Manual devices are not previewed")
        XCTAssertTrue(service.isPreviewing)

        // Live updates during the preview are deferred, then applied on restore.
        service.requestSync(mode: .completed)
        service.waitUntilIdle()
        XCTAssertEqual(world.program("SidePulsePro"), kitt)
        XCTAssertTrue(runtimeWait { self.world.program("SidePulsePro") != kitt })
        XCTAssertEqual(world.program("SidePulsePro"), RuntimePrograms.expected(.completed, ledCount: 8, brightness: 51))
        XCTAssertFalse(service.isPreviewing)
    }

    func testNewerPreviewCancelsTheOlderRestore() {
        world.addDevice("PulseDot")
        let service = makeService()
        service.pollDevices()
        service.syncNow(mode: .working)
        let start = Date()
        service.preview(animationID: "kitt", seconds: 0.3)
        XCTAssertTrue(runtimeWait { self.world.program("PulseDot") == RuntimePrograms.program("kitt", ledCount: 2) })
        service.preview(animationID: "purple-idle", seconds: 1.2)
        let purple = RuntimePrograms.program("purple-idle", ledCount: 2)
        XCTAssertTrue(runtimeWait { self.world.program("PulseDot") == purple })
        // Well past the first preview's end: still showing the second one.
        runtimeSpin(max(0, 0.8 - Date().timeIntervalSince(start)))
        XCTAssertEqual(world.program("PulseDot"), purple)
        XCTAssertTrue(runtimeWait(timeout: 4) { self.world.program("PulseDot") == RuntimePrograms.expected(.working, ledCount: 2) })
    }

    func testPreviewIgnoresUnknownAnimationsAndManualDevices() {
        world.addDevice("PulseDot")
        let service = makeService()
        service.pollDevices()
        service.preview(animationID: "no-such-animation", seconds: 0.1)
        XCTAssertFalse(service.isPreviewing)
        box.update { $0.setDisplay(.manual, forDevice: world.deviceID("PulseDot")) }
        service.preview(animationID: "kitt", seconds: 0.1)
        runtimeSpin(0.3)
        service.waitUntilIdle()
        XCTAssertEqual(world.program("PulseDot"), "boot")
    }

    // MARK: Sleep

    func testOffForSleepHoldsBackEveryWriteUntilTurnedOn() {
        world.addDevice("PulseDot")
        world.addDevice("SidePulsePro")
        box.update { $0.setDisplay(.manual, forDevice: world.deviceID("SidePulsePro")) }
        let service = makeService()
        service.pollDevices()
        service.syncNow(mode: .working)

        XCTAssertTrue(service.turnOffForSleep(timeout: 2))
        XCTAssertTrue(service.isOffForSleep)
        XCTAssertEqual(world.program("PulseDot"), LedSyncService.sleepProgram)
        XCTAssertEqual(world.program("SidePulsePro"), "boot", "Manual devices are left alone")

        service.requestSync(mode: .completed)
        XCTAssertEqual(service.syncNow(mode: .completed), [:])
        service.preview(animationID: "kitt", seconds: 0)
        runtimeSpin(0.1)
        XCTAssertTrue(service.waitUntilIdle())
        XCTAssertEqual(world.program("PulseDot"), LedSyncService.sleepProgram)

        XCTAssertTrue(service.turnOnAfterSleep())
        XCTAssertFalse(service.turnOnAfterSleep())
        XCTAssertTrue(service.waitUntilIdle())
        XCTAssertEqual(world.program("PulseDot"), RuntimePrograms.expected(.completed, ledCount: 2))
        XCTAssertEqual(logs.items.filter { $0.contains("for sleep") }.count, 1, "\(logs.items)")
    }

    /// Regression: a program without `brightness N` plays at 255, so a dimmed device flashed bright as it faded.
    func testOffForSleepKeepsTheDeviceBrightness() {
        world.addDevice("PulseDot")
        box.update { $0.setBrightness(15, forDevice: world.deviceID("PulseDot")) }
        let service = makeService()
        service.pollDevices()
        service.syncNow(mode: .working)

        service.turnOffForSleep(timeout: 2)
        XCTAssertEqual(world.program("PulseDot"), "brightness 15\n" + LedSyncService.sleepProgram)
        service.turnOnAfterSleep()
        XCTAssertTrue(service.waitUntilIdle())
        XCTAssertEqual(world.program("PulseDot"), RuntimePrograms.expected(.working, ledCount: 2, brightness: 15))
    }

    func testSleepEndsAPreviewWithoutItsRestore() {
        world.addDevice("PulseDot")
        let service = makeService()
        service.pollDevices()
        service.syncNow(mode: .working)
        service.preview(animationID: "kitt", seconds: 0.2)
        XCTAssertTrue(runtimeWait { self.world.program("PulseDot") == RuntimePrograms.program("kitt", ledCount: 2) })

        service.turnOffForSleep(timeout: 2)
        XCTAssertFalse(service.isPreviewing)
        runtimeSpin(0.4)
        XCTAssertTrue(service.waitUntilIdle())
        XCTAssertEqual(world.program("PulseDot"), LedSyncService.sleepProgram)

        service.turnOnAfterSleep()
        XCTAssertTrue(service.waitUntilIdle())
        XCTAssertEqual(world.program("PulseDot"), RuntimePrograms.expected(.working, ledCount: 2))
    }

    /// A status write stuck in open() when the Mac sleeps must not light the LEDs once it returns.
    func testStatusWriteBlockedAtSleepIsSkipped() {
        world.addDevice("PulseDot")
        let gate = LedWriteGate()
        let service = makeService(writer: gate.writer)
        service.pollDevices()
        gate.arm(.inOpen)
        service.requestSync(mode: .working)
        XCTAssertTrue(gate.waitForHeldWrite())

        XCTAssertFalse(service.turnOffForSleep(timeout: 0.1), "the sleep write waits behind the stuck one")
        gate.release()
        XCTAssertTrue(service.waitUntilIdle())
        XCTAssertEqual(world.program("PulseDot"), LedSyncService.sleepProgram)
    }

    /// A sleep write that only gets its turn after the wake must not turn the LEDs off.
    func testLateSleepWriteAfterWakeIsSkipped() {
        world.addDevice("PulseDot")
        let gate = LedWriteGate()
        let service = makeService(writer: gate.writer)
        service.pollDevices()
        service.syncNow(mode: .idleReady)
        gate.arm(.inOpen)
        service.requestSync(mode: .working)
        XCTAssertTrue(gate.waitForHeldWrite())

        XCTAssertFalse(service.turnOffForSleep(timeout: 0.1))
        XCTAssertTrue(service.turnOnAfterSleep())
        gate.release()
        XCTAssertTrue(service.waitUntilIdle())
        XCTAssertEqual(world.program("PulseDot"), RuntimePrograms.expected(.working, ledCount: 2))
    }

    func testDryRunNeverWritesForSleep() {
        world.addDevice("PulseDot")
        let service = makeService(dryRun: true)
        service.pollDevices()
        service.syncNow(mode: .working)
        XCTAssertTrue(service.turnOffForSleep(timeout: 2))
        XCTAssertEqual(world.program("PulseDot"), "boot")
        XCTAssertTrue(logs.items.contains { $0.contains("would turn off") }, "\(logs.items)")
    }

    func testReopenEndsSleep() {
        world.addDevice("PulseDot")
        let service = makeService()
        service.pollDevices()
        service.turnOffForSleep(timeout: 2)
        service.close(generation: service.currentGeneration)
        service.reopen()
        XCTAssertFalse(service.isOffForSleep)
        service.syncNow(mode: .working)
        XCTAssertEqual(world.program("PulseDot"), RuntimePrograms.expected(.working, ledCount: 2))
    }

    func testFinishPreviewNowRestoresImmediately() {
        world.addDevice("PulseDot")
        let service = makeService()
        service.pollDevices()
        service.syncNow(mode: .idleReady)
        service.preview(animationID: "kitt", seconds: 30)
        XCTAssertTrue(runtimeWait { self.world.program("PulseDot") == RuntimePrograms.program("kitt", ledCount: 2) })
        service.finishPreviewNow()
        service.waitUntilIdle()
        XCTAssertEqual(world.program("PulseDot"), RuntimePrograms.expected(.idleReady, ledCount: 2))
        XCTAssertFalse(service.isPreviewing)
    }

}
