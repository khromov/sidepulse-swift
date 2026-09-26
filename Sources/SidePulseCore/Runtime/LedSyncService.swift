import Darwin
import Foundation

/// Device I/O runs on the serial `ioQueue` while what the UI reads sits behind `lock`,
/// so readers never wait for a slow SD write (see docs/ARCHITECTURE.md, Runtime threading).
public final class LedSyncService: @unchecked Sendable {
    /// Shown for any stall past `stallNotice`, since that is almost always open()
    /// blocked on the macOS removable-volume prompt.
    static let waitingForPermissionMessage = "Waiting for macOS permission to access this device — check for a system prompt"
    static let accessDeniedMessage = "macOS denied access. Allow SidePulse in System Settings › Privacy & Security "
        + "› Files and Folders (Removable Volumes)"

    public let dryRun: Bool

    private let settingsProvider: @Sendable () -> SidePulseSettings
    private let roots: [URL]?
    private let log: @Sendable (String) -> Void
    private let keepalive: KeepaliveToucher
    private let clock: @Sendable () -> TimeInterval
    private let discover: @Sendable ([URL]?) -> [DeviceCandidate]
    /// Seconds after which a running write or keepalive touch counts as stuck.
    let stallNotice: TimeInterval

    let ioQueue = DispatchQueue(label: "sidepulse.leds.io", qos: .utility)
    private let writesInProgress = DispatchGroup()

    private let lock = NSLock()
    private var shared = Shared()

    private struct Shared {
        var devices: [DeviceCandidate] = []
        var signatures: [String: String] = [:]
        var resetAll = false
        var resetIDs: Set<String> = []
        var latestMode: AgentMode?
        var syncScheduled = false
        var previewToken = 0
        /// Cleared by the preview's restore rather than by comparing it with the clock.
        var previewUntil: TimeInterval?
        var errors: [String: String] = [:]
        var writesStarted: [String: TimeInterval] = [:]
        var reportedErrors: [String: String] = [:]
        var syncPasses = 0
        var keepaliveError: String?
    }

    // I/O-queue-only state.
    private var controllers: [String: AgentLedController] = [:]
    private var lastDisplay: [String: LedDisplay] = [:]

    public convenience init(settings: @escaping @Sendable () -> SidePulseSettings,
                            roots: [URL]? = nil,
                            dryRun: Bool = false,
                            log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(settings: settings, roots: roots, dryRun: dryRun, log: log, keepalive: KeepaliveToucher())
    }

    init(settings: @escaping @Sendable () -> SidePulseSettings,
         roots: [URL]?,
         dryRun: Bool,
         log: @escaping @Sendable (String) -> Void,
         keepalive: KeepaliveToucher,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         discover: @escaping @Sendable ([URL]?) -> [DeviceCandidate] = { DeviceDiscovery.discover(roots: $0) },
         stallNotice: TimeInterval = 2) {
        self.settingsProvider = settings
        self.roots = roots
        self.dryRun = dryRun
        self.log = log
        self.keepalive = keepalive
        self.clock = clock
        self.discover = discover
        self.stallNotice = stallNotice
    }

    private func locked<T>(_ body: (inout Shared) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&shared)
    }

    // MARK: Devices

    /// Runs discovery on the calling thread, which a hung mount can block.
    @discardableResult
    public func pollDevices() -> Bool {
        let found = discover(roots)
        var signatures: [String: String] = [:]
        for device in found { signatures[device.id] = Self.signature(of: device) }

        let (added, removed, changed) = locked { state -> ([DeviceCandidate], [String], Bool) in
            let previous = state.signatures
            state.devices = found
            guard previous != signatures else { return ([], [], false) }
            for (id, signature) in previous where signatures[id] != signature {
                state.resetIDs.insert(id)
            }
            let removed = previous.keys.filter { signatures[$0] == nil }.sorted()
            for id in removed { state.errors[id] = nil }
            state.signatures = signatures
            return (found.filter { previous[$0.id] == nil }, removed, true)
        }
        if !added.isEmpty {
            log("devices: connected " + added.map { "\($0.displayName) (\($0.root.path))" }.joined(separator: ", "))
        }
        if !removed.isEmpty {
            log("devices: disconnected " + removed.joined(separator: ", "))
        }
        return changed
    }

    public var connectedDevices: [DeviceCandidate] {
        locked { $0.devices }
    }

    /// Takes `settings` so the runtime can pass the UI's settings, including changes
    /// still being saved.
    public func deviceInfos(settings: SidePulseSettings) -> [DeviceInfo] {
        let (devices, errors) = shownErrors()
        var infos: [DeviceInfo] = []
        var seen = Set<String>()
        for device in devices where seen.insert(device.id).inserted {
            infos.append(DeviceInfo(id: device.id, name: device.displayName, root: device.root, target: device.target,
                                    connected: true, display: settings.display(forDevice: device.id),
                                    brightness: settings.brightness(forDevice: device.id),
                                    ledCount: device.ledCount, lastError: errors[device.id]))
        }
        for entry in settings.devices where seen.insert(entry.id).inserted {
            let root = URL(fileURLWithPath: DeviceDiscovery.expandTilde(entry.path), isDirectory: true)
            let target = DeviceDiscovery.target(forDevicePath: root)
            infos.append(DeviceInfo(id: entry.id, name: entry.name, root: root, target: target, connected: false,
                                    display: entry.display, brightness: LedProgram.clampBrightness(entry.brightness),
                                    ledCount: DeviceDiscovery.ledCount(forTarget: target)))
        }
        infos.sort { a, b in
            if a.connected != b.connected { return a.connected }
            let nameA = DeviceDiscovery.normalizedName(a.name)
            let nameB = DeviceDiscovery.normalizedName(b.name)
            if nameA != nameB { return nameA < nameB }
            return a.root.path < b.root.path
        }
        return Self.disambiguated(infos)
    }

    private func shownErrors() -> (devices: [DeviceCandidate], errors: [String: String]) {
        let stalledTouches = keepalive.stalledFiles(after: stallNotice)
        let now = clock()
        return locked { state in
            var errors = state.errors
            for device in state.devices {
                let writeStalled = state.writesStarted[device.id].map { now - $0 > stallNotice } ?? false
                if writeStalled || stalledTouches.contains(KeepaliveToucher.keepaliveFile(for: device.target).path) {
                    errors[device.id] = Self.waitingForPermissionMessage
                }
            }
            return (state.devices, errors)
        }
    }

    /// Returns true when a shown error changed since the last call, so an open menu
    /// can refresh.
    func checkDeviceStatus() -> Bool {
        let (devices, errors) = shownErrors()
        let previous = locked { state -> [String: String] in
            defer { state.reportedErrors = errors }
            return state.reportedErrors
        }
        for device in devices where errors[device.id] == Self.waitingForPermissionMessage
            && previous[device.id] != Self.waitingForPermissionMessage {
            log("leds: \(device.displayName) (\(device.root.path)) has not answered for over "
                + "\(Int(stallNotice.rounded())) s; waiting for macOS permission?")
        }
        return errors != previous
    }

    /// Expects `infos` in display order, because the first of each duplicate keeps the
    /// plain name.
    static func disambiguated(_ infos: [DeviceInfo]) -> [DeviceInfo] {
        var counts: [String: Int] = [:]
        for info in infos { counts[info.name, default: 0] += 1 }
        guard counts.values.contains(where: { $0 > 1 }) else { return infos }

        var used = Set(infos.map(\.name).filter { counts[$0] == 1 })
        return infos.map { info in
            guard counts[info.name, default: 0] > 1 else { return info }
            if used.insert(info.name).inserted { return info }
            var copy = info
            let rootName = info.root.lastPathComponent
            var candidate = "\(info.name) (\(rootName.isEmpty ? info.root.path : rootName))"
            if used.contains(candidate) { candidate = "\(info.name) (\(info.root.path))" }
            let base = candidate
            var number = 2
            while used.contains(candidate) {
                candidate = "\(base) \(number)"
                number += 1
            }
            used.insert(candidate)
            copy.name = candidate
            return copy
        }
    }

    /// Includes the volume root's dev:ino so a different card mounted under the same
    /// name counts as changed and gets its program rewritten.
    static func signature(of device: DeviceCandidate) -> String {
        var info = stat()
        let identity = stat(device.root.path, &info) == 0 ? "\(info.st_dev):\(info.st_ino)" : "missing"
        return "\(device.target.path)|\(identity)"
    }

    // MARK: Syncing

    /// Coalesced without ever dropping the latest mode, which the Python version could.
    public func requestSync(mode: AgentMode) {
        let schedule = locked { state -> Bool in
            state.latestMode = mode
            guard !state.syncScheduled else { return false }
            state.syncScheduled = true
            return true
        }
        if schedule {
            ioQueue.async { [self] in runScheduledSync() }
        }
    }

    /// Unlike `requestSync`, runs even while a preview plays.
    @discardableResult
    public func syncNow(mode: AgentMode) -> [String: LedSyncResult] {
        ioQueue.sync {
            locked { $0.latestMode = mode }
            return performSync(mode: mode)
        }
    }

    /// Normal syncs wait for the preview's restore, and a newer preview cancels the
    /// older restore.
    public func preview(animationID: String, seconds: TimeInterval = 3) {
        guard AnimationLibrary.animation(id: animationID) != nil else {
            log("leds: preview skipped, unknown animation \(animationID)")
            return
        }
        let duration = seconds.isFinite ? min(max(0, seconds), 600) : 3
        let token = locked { state -> Int in
            state.previewToken += 1
            state.previewUntil = clock() + duration
            return state.previewToken
        }
        ioQueue.async { [self] in
            guard locked({ $0.previewToken }) == token else { return }
            writePreview(animationID)
        }
        ioQueue.asyncAfter(deadline: .now() + duration) { [self] in
            restoreAfterPreview(token: token)
        }
    }

    /// `completion` runs on the I/O queue.
    func writeOnceAsync(program: String, deviceID: String, completion: @escaping @Sendable (Error?) -> Void) {
        ioQueue.async { [self] in
            do {
                try writeOnceOnQueue(program: program, deviceID: deviceID)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    /// Forces the next sync to rewrite; applied on the I/O queue right before that sync,
    /// so a reset never races a write.
    public func resetControllers(deviceID: String? = nil) {
        locked { state in
            if let deviceID {
                state.resetIDs.insert(deviceID)
            } else {
                state.resetAll = true
            }
        }
    }

    public func touchKeepalive(now: Date = Date()) {
        touchKeepalive(devices: connectedDevices, settings: settingsProvider(), now: now)
    }

    @discardableResult
    public func waitUntilIdle(timeout: TimeInterval = 5) -> Bool {
        let done = DispatchSemaphore(value: 0)
        ioQueue.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// Skips writes still blocked in open(), which re-check the settings once it returns.
    func waitForWrites(timeout: TimeInterval) -> Bool {
        writesInProgress.wait(timeout: .now() + timeout) == .success
    }

    @discardableResult
    func waitForKeepaliveTouches(timeout: TimeInterval) -> Bool {
        keepalive.waitForPendingTouches(timeout: timeout)
    }

    func finishPreviewNow() {
        ioQueue.async { [self] in
            let (active, mode) = locked { state -> (Bool, AgentMode?) in
                let active = state.previewUntil != nil
                state.previewToken += 1
                state.previewUntil = nil
                if active { state.resetAll = true }
                return (active, state.latestMode)
            }
            if active, let mode { _ = performSync(mode: mode) }
        }
    }

    var syncPassCount: Int { locked { $0.syncPasses } }

    var isPreviewing: Bool { locked { $0.previewUntil != nil } }

    // MARK: I/O queue

    private func runScheduledSync() {
        let (mode, previewing) = locked { state -> (AgentMode?, Bool) in
            state.syncScheduled = false
            return (state.latestMode, state.previewUntil != nil)
        }
        // A playing preview restores the latest mode itself when it ends.
        guard let mode, !previewing else { return }
        _ = performSync(mode: mode)
    }

    private func performSync(mode: AgentMode) -> [String: LedSyncResult] {
        let (devices, resetAll, resetIDs) = locked { state -> ([DeviceCandidate], Bool, Set<String>) in
            defer {
                state.resetAll = false
                state.resetIDs = []
                state.syncPasses += 1
            }
            return (state.devices, state.resetAll, state.resetIDs)
        }
        if resetAll { controllers.removeAll() }
        for id in resetIDs { controllers[id] = nil }
        // Forget devices that are gone (their controllers were reset by the poll).
        if lastDisplay.count > devices.count {
            let ids = Set(devices.map(\.id))
            lastDisplay = lastDisplay.filter { ids.contains($0.key) }
        }

        let settings = settingsProvider()
        let animationID = settings.animationID(for: mode)
        var results: [String: LedSyncResult] = [:]
        for device in devices {
            let display = settings.display(forDevice: device.id)
            if lastDisplay[device.id] != display {
                controllers[device.id] = nil
                lastDisplay[device.id] = display
            }
            guard display == .agent else {
                record(error: nil, for: device)
                continue
            }
            let controller = controller(for: device)
            controller.brightness = settings.brightness(forDevice: device.id)
            let result = controller.sync(mode: mode, animationID: animationID) { [self] program in
                try write(program, to: device, agentOnly: true)
            }
            results[device.id] = result
            if result.changed {
                log("leds: \(dryRun ? "would write" : "wrote") \(mode.displayState.label) (\(animationID)) "
                    + "to \(device.displayName) at \(device.target.path)")
            }
            record(error: result.error, for: device)
        }
        touchKeepalive(devices: devices, settings: settings, now: Date())
        return results
    }

    private func controller(for device: DeviceCandidate) -> AgentLedController {
        if let existing = controllers[device.id], existing.target == device.target { return existing }
        let controller = AgentLedController(target: device.target, dryRun: dryRun)
        controllers[device.id] = controller
        return controller
    }

    private func record(error: String?, for device: DeviceCandidate) {
        let previous = locked { state -> String? in
            let previous = state.errors[device.id]
            state.errors[device.id] = error
            return previous
        }
        guard error != previous else { return }
        if let error {
            log("leds: error \(device.displayName) (\(device.root.path)): \(error)")
        } else if previous != nil {
            log("leds: \(device.displayName) (\(device.root.path)) recovered")
        }
    }

    private func writePreview(_ animationID: String) {
        let settings = settingsProvider()
        for device in connectedDevices where settings.display(forDevice: device.id) == .agent {
            do {
                let program = try LedProgram.program(animationID: animationID, ledCount: device.ledCount,
                                                     brightness: settings.brightness(forDevice: device.id))
                if dryRun {
                    try LedText.validate(program)
                } else if try !write(program, to: device, agentOnly: true) {
                    continue
                }
                log("leds: preview \(animationID) on \(device.displayName) at \(device.target.path)")
            } catch {
                log("leds: preview error \(device.displayName): \(error.localizedDescription)")
            }
        }
    }

    private func restoreAfterPreview(token: Int) {
        let (current, mode) = locked { state -> (Bool, AgentMode?) in
            guard state.previewToken == token else { return (false, nil) }
            state.previewUntil = nil
            state.resetAll = true
            return (true, state.latestMode)
        }
        guard current, let mode else { return }
        _ = performSync(mode: mode)
    }

    private func writeOnceOnQueue(program: String, deviceID: String) throws {
        guard let device = connectedDevices.first(where: { $0.id == deviceID }) else {
            throw LedError.writeFailed("\(deviceID) is not connected.")
        }
        try LedText.validate(program)
        controllers[deviceID] = nil
        do {
            if !dryRun { _ = try write(program, to: device, agentOnly: false) }
            record(error: nil, for: device)
        } catch {
            record(error: error.localizedDescription, for: device)
            throw error
        }
    }

    /// An `agentOnly` write returns false without writing if the device left Agent mode
    /// while open() was blocked.
    private func write(_ program: String, to device: DeviceCandidate, agentOnly: Bool) throws -> Bool {
        locked { $0.writesStarted[device.id] = clock() }
        var entered = false
        defer {
            if entered { writesInProgress.leave() }
            locked { $0.writesStarted[device.id] = nil }
        }
        do {
            return try LedWriter.write(program, to: device.target) {
                // Entered before the check: a settings change made before
                // `waitForWrites` is either seen here or waited for there.
                writesInProgress.enter()
                entered = true
                guard agentOnly else { return true }
                let settings = settingsProvider()
                return settings.display(forDevice: device.id) == .agent
            }
        } catch LedError.accessDenied {
            throw LedError.writeFailed(Self.accessDeniedMessage)
        }
    }

    private func touchKeepalive(devices: [DeviceCandidate], settings: SidePulseSettings, now: Date) {
        // Only the MacBook SD reader powers down an idle card: Dots (USB) are skipped.
        let targets = devices.filter { $0.ledCount == 8 }.map(\.target)
        guard !dryRun, !targets.isEmpty else { return }
        keepalive.poke(targets: targets, now: now)
        let error = keepalive.lastError
        let previous = locked { state -> String? in
            let previous = state.keepaliveError
            state.keepaliveError = error
            return previous
        }
        if let error, error != previous { log("leds: keepalive error: \(error)") }
    }
}
