import Darwin
import Foundation
import XCTest
@testable import SidePulseCore

/// Mutable settings for a `LedSyncService` under test.
private final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SidePulseSettings
    /// Called (outside the lock) on every read; lets a test stall a sync mid-flight.
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

/// LedSyncService against fake device folders in a temp mount root.
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
                             stallNotice: TimeInterval = 2) -> LedSyncService {
        let box = self.box!
        let logs = self.logs!
        return LedSyncService(settings: { box.value }, roots: [world.mounts], dryRun: dryRun,
                              log: { logs.append($0) }, keepalive: keepalive, stallNotice: stallNotice)
    }

    /// `writeOnceAsync`, waited for.
    private func writeOnce(_ service: LedSyncService, _ program: String, to deviceID: String) throws {
        let failure = RuntimeInbox<Error?>()
        service.writeOnceAsync(program: program, deviceID: deviceID) { failure.append($0) }
        XCTAssertTrue(service.waitUntilIdle())
        if let error = failure.items.first ?? nil { throw error }
    }

    private func deviceInfos(_ service: LedSyncService) -> [DeviceInfo] {
        service.deviceInfos(settings: box.value)
    }

    /// Makes `<device>/LEDS.LED` a FIFO: opening it for writing blocks until a
    /// reader shows up, like open() waiting on the macOS permission prompt.
    private func makeBlockingTarget(_ name: String) {
        world.addDevice(name, content: nil)
        XCTAssertEqual(mkfifo(world.target(name).path, 0o644), 0)
    }

    /// Lets a write blocked on the FIFO through and returns what it wrote.
    private func unblock(_ name: String, _ service: LedSyncService) -> String {
        let fd = open(world.target(name).path, O_RDONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertTrue(service.waitUntilIdle())
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        return String(decoding: buffer.prefix(max(0, count)), as: UTF8.self)
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

        // Same mode again: deduped, nothing rewritten.
        let again = service.syncNow(mode: .toolRunning)
        XCTAssertEqual(again[world.deviceID("PulseDot")]?.changed, false)
        // An external overwrite is repaired on the next sync.
        world.overwrite("PulseDot", with: "off")
        XCTAssertEqual(service.syncNow(mode: .working)[world.deviceID("PulseDot")]?.changed, true)
        XCTAssertEqual(world.program("PulseDot"), dot)

        // Each state has its own program.
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

        // Back to Agent: the device is written on the next sync.
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
        XCTAssertNoThrow(try writeOnce(service, "off", to: world.deviceID("PulseDot")))
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

        // The real toucher creates the file.
        let real = makeService()
        real.pollDevices()
        real.touchKeepalive()
        XCTAssertTrue(runtimeWait {
            FileManager.default.fileExists(atPath: self.world.mounts.appendingPathComponent("SidePulsePro/keepalive").path)
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.mounts.appendingPathComponent("PulseDot/keepalive").path))
    }

    // MARK: Coalescing

    /// 200 requests queued behind a busy I/O queue collapse into one pass that
    /// writes the last mode.
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

    /// A request made while a sync is in flight is never dropped (the Python bug):
    /// the sync runs once more with the newest mode.
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

        // Unplug; replug a "different card" that happens to hold the same program:
        // the controller was reset, so the device is written again.
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

        // Two connected volumes with the same display name.
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

        XCTAssertThrowsError(try writeOnce(service, "off", to: "/nope"))
        XCTAssertThrowsError(try writeOnce(service, "", to: world.deviceID("PulseDot")))
    }

    /// Regression: a denied macOS permission showed only a raw EPERM.
    func testRefusedOpenNamesTheMacOSPrivacySetting() throws {
        world.addDevice("PulseDot")
        chmod(world.target("PulseDot").path, 0o444)
        defer { chmod(world.target("PulseDot").path, 0o644) }
        let service = makeService()
        service.pollDevices()

        let result = service.syncNow(mode: .working)[world.deviceID("PulseDot")]
        XCTAssertEqual(result?.error, LedSyncService.accessDeniedMessage)
        XCTAssertEqual(deviceInfos(service).first?.lastError, LedSyncService.accessDeniedMessage)
        XCTAssertThrowsError(try writeOnce(service, "off", to: world.deviceID("PulseDot"))) { error in
            XCTAssertEqual(error.localizedDescription, LedSyncService.accessDeniedMessage)
        }
        XCTAssertEqual(world.program("PulseDot"), "boot")
    }

    /// Regression: while open() waited on the macOS permission prompt nothing
    /// showed, and the stale write then overwrote a device switched to Manual.
    func testWriteWaitingInOpenShowsAsWaitingAndSkipsADeviceThatBecameManual() {
        makeBlockingTarget("PulseDot")
        let dot = world.deviceID("PulseDot")
        let service = makeService(stallNotice: 0.2)
        service.pollDevices()
        XCTAssertFalse(service.checkDeviceStatus())

        service.requestSync(mode: .working)
        XCTAssertTrue(runtimeWait { self.deviceInfos(service).first?.lastError == LedSyncService.waitingForPermissionMessage })
        XCTAssertTrue(service.checkDeviceStatus(), "the UI is told once")
        XCTAssertFalse(service.checkDeviceStatus())
        XCTAssertEqual(logs.items.filter { $0.contains("waiting for macOS permission?") }.count, 1, "\(logs.items)")

        // `sidepulse write --manual` meanwhile: a write still in open() is not waited for...
        box.update { $0.setDisplay(.manual, forDevice: dot) }
        XCTAssertTrue(service.waitForWrites(timeout: 0.1))
        // ...and once open() returns it sees Manual and writes nothing.
        XCTAssertEqual(unblock("PulseDot", service), "")
        XCTAssertNil(deviceInfos(service).first?.lastError)
        XCTAssertTrue(service.checkDeviceStatus(), "the notice goes away")

        // Back to Agent: the declined write was not remembered, so it is written now.
        box.update { $0.setDisplay(.agent, forDevice: dot) }
        service.requestSync(mode: .working)
        XCTAssertEqual(unblock("PulseDot", service), RuntimePrograms.expected(.working, ledCount: 2))
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

    func testWriteOnceWritesToAConnectedDevice() throws {
        world.addDevice("PulseDot")
        let service = makeService()
        service.pollDevices()
        service.syncNow(mode: .working)
        try writeOnce(service, "off", to: world.deviceID("PulseDot"))
        XCTAssertEqual(world.program("PulseDot"), "off")
        // The controller was reset, so the next Agent sync rewrites.
        XCTAssertEqual(service.syncNow(mode: .working)[world.deviceID("PulseDot")]?.changed, true)
    }
}
