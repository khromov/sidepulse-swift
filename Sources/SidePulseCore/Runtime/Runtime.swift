import Foundation
import Synchronization

public struct DeviceInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var root: URL
    public var target: URL
    public var connected: Bool
    public var display: LedDisplay
    public var brightness: Int
    public var ledCount: Int
    /// Also carries the stuck-I/O notice (`LedSyncService.waitingForPermissionMessage`),
    /// not only write errors.
    public var lastError: String?

    public init(id: String, name: String, root: URL, target: URL, connected: Bool, display: LedDisplay,
                brightness: Int, ledCount: Int, lastError: String? = nil) {
        self.id = id; self.name = name; self.root = root; self.target = target; self.connected = connected
        self.display = display; self.brightness = brightness; self.ledCount = ledCount; self.lastError = lastError
    }
}

public protocol KeepAwakeHolding: AnyObject, Sendable {
    var isHeld: Bool { get }
    func setHeld(_ held: Bool)
}

extension KeepAwakeAssertion: KeepAwakeHolding {}

public struct RuntimeOptions: Sendable {
    public var serveSocket = true
    public var keepAwake = true
    public var dryRun = false
    public var mountRoots: [URL]? = nil
    /// Clamped to 0.05 s ... 1 day because Dispatch traps on huge intervals and
    /// `--interval` accepts any positive number.
    public var refreshInterval: TimeInterval = 15
    public var devicePollInterval: TimeInterval = 2

    public var batteryReader: (@Sendable () -> BatteryState)? = nil
    public var batteryCacheInterval: TimeInterval = 30
    public var keepAwakeHolder: (any KeepAwakeHolding)? = nil
    public var keepAwakeGrace: TimeInterval = 300
    /// Turns the LEDs off while the Mac sleeps.
    public var watchSleep = true
    public var sleepWatcher: (any SleepWatching)? = nil
    /// Counted from the first unsaved change, so later changes ride along instead
    /// of postponing the save.
    public var latestSaveDelay: TimeInterval = 1

    var deviceDiscovery: (@Sendable ([URL]?) -> [DeviceCandidate])? = nil
    var keepaliveTouch: (@Sendable (URL) throws -> Void)? = nil
    var ledWriter: LedSyncService.FileWriter? = nil
    var afterBind: (@Sendable () -> Void)? = nil

    public init() {}

    static func clamped(_ value: TimeInterval, to range: ClosedRange<TimeInterval>,
                        fallback: TimeInterval) -> TimeInterval {
        if value.isNaN { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

/// Shared by the menu-bar app and headless `sidepulse run`; its threading contract is
/// in docs/ARCHITECTURE.md (Runtime threading).
public final class SidePulseRuntime: @unchecked Sendable {
    public let paths: SidePulsePaths
    public let options: RuntimeOptions
    public let settingsStore: SettingsStore
    public let leds: LedSyncService

    /// Coalesced on the main queue: changes made while a delivery is pending ride along.
    public var onUpdate: ((MonitorSnapshot) -> Void)? {
        get { shared.read { $0.onUpdate } }
        set { shared.write { $0.onUpdate = newValue } }
    }

    /// Left nil by the headless runtime, which makes `open-settings` fail and `ping` answer
    /// `"kind":"headless"` so the CLI knows there is no settings window.
    public var onOpenSettings: (() -> Void)? {
        get { shared.read { $0.onOpenSettings } }
        set { shared.write { $0.onOpenSettings = newValue } }
    }

    // MARK: Queues and shared caches

    private let stateQueue = DispatchQueue(label: "sidepulse.runtime.state", qos: .userInitiated)
    private let stateQueueKey = DispatchSpecificKey<Bool>()
    private let persistQueue = DispatchQueue(label: "sidepulse.runtime.latest", qos: .utility)
    private let deviceQueue = DispatchQueue(label: "sidepulse.runtime.devices", qos: .utility)
    private let shared: RuntimeCache

    // MARK: State-queue-only state

    private let codexIndex: CodexSessionIndex
    private let engine: StatusEngine
    private let sources: [SourceInfo]
    private var applied: SidePulseSettings
    private var policy: KeepAwakePolicy
    private var battery: (state: BatteryState, readAt: Date)?
    private var safeguardActive = false
    private var latestDirty = false
    private var latestSave: DispatchWorkItem?
    private var running = false
    private var server: EventSocketServer?
    private var refreshTimer: DispatchSourceTimer?
    private var deviceTimer: DispatchSourceTimer?
    private let keepAwakeHolder: (any KeepAwakeHolding)?
    private let sleepWatcher: (any SleepWatching)?
    private let readBattery: @Sendable () -> BatteryState
    /// Only touched on the persist queue.
    private var latestSaveFailing = false
    /// Mirrors `running` so `preview` can check it without waiting for the state queue.
    private let outputsOpen = Mutex(false)
    /// The Mac still looks in use between `.willSleep` and the actual sleep, so the LEDs wait for a wake.
    private let waitingForWake = Mutex(false)
    private var ingestCount = 0

    public init(paths: SidePulsePaths, options: RuntimeOptions = RuntimeOptions()) {
        self.paths = paths
        self.options = options
        self.settingsStore = SettingsStore(url: paths.settingsFile)
        let settings = settingsStore.load()
        let shared = RuntimeCache(settings: settings)
        self.shared = shared
        self.leds = LedSyncService(settings: { shared.read { $0.ledSettings } }, roots: options.mountRoots,
                                   dryRun: options.dryRun, log: { DiagnosticsLog.shared.log($0) },
                                   keepalive: options.keepaliveTouch.map { KeepaliveToucher(touch: $0) } ?? KeepaliveToucher(),
                                   discover: options.deviceDiscovery ?? { DeviceDiscovery.discover(roots: $0) },
                                   writeFile: options.ledWriter ?? LedSyncService.fileWriter)
        let index = CodexSessionIndex(paths: paths)
        self.codexIndex = index
        self.engine = StatusEngine(config: settings.monitorConfig, codexTitle: { index.title(forSession: $0) })
        self.applied = settings
        self.sources = HookProvider.allCases.map {
            SourceInfo(provider: $0.rawValue, path: paths.logFile(for: $0.rawValue).path)
        }
        self.policy = KeepAwakePolicy(grace: options.keepAwakeGrace)
        self.keepAwakeHolder = options.keepAwake ? (options.keepAwakeHolder ?? KeepAwakeAssertion()) : nil
        self.sleepWatcher = options.watchSleep ? (options.sleepWatcher ?? SystemSleepWatcher()) : nil
        self.readBattery = options.batteryReader ?? { BatteryState.read() }
        stateQueue.setSpecific(key: stateQueueKey, value: true)
    }

    deinit {
        refreshTimer?.cancel()
        deviceTimer?.cancel()
        server?.stop()
        sleepWatcher?.stop()
    }

    // MARK: Lifecycle

    /// Binds the socket before writing anything (settings, latest.json, LEDs), so a
    /// second instance fails with `EventSocketError.alreadyRunning` without side effects.
    public func start() throws {
        let started: Bool = try onState {
            guard !running else { return false }
            // The socket already serves, so `status` must wait for the rows below
            // instead of answering with an empty snapshot.
            shared.write { $0.starting = true }
            defer { shared.write { $0.starting = false } }
            let settings = settingsStore.load()
            if options.serveSocket {
                let server = EventSocketServer(path: paths.socketPath) { [weak self] message in
                    self?.handle(message)
                }
                do {
                    try server.start()
                } catch {
                    DiagnosticsLog.shared.log("runtime: event socket: \(error.localizedDescription)")
                    throw error
                }
                self.server = server
            }
            options.afterBind?()
            try? paths.ensureDirectories()
            applySettings(settings)

            let now = Date()
            // Like reconcile, a restored row never replaces a newer one, which the
            // engine can already hold when restarted after stop().
            let current = engine.statuses
            engine.load(LatestStore(url: paths.latestFile).load().filter { row in
                current[row.agentID].map { $0.updatedAt < row.updatedAt } ?? true
            })
            let index = codexIndex
            let recovered = LogScanner.recover(sources: LogScanner.defaultSources(paths: paths),
                                               config: settings.monitorConfig,
                                               codexTitle: { index.title(forSession: $0) })
            let reconciled = engine.reconcile(with: recovered)
            engine.prune(now: now)
            policy = KeepAwakePolicy(grace: options.keepAwakeGrace)
            battery = nil
            safeguardActive = false
            leds.reopen()
            waitingForWake.withLock { $0 = false }
            running = true
            setOutputsOpen(true)
            saveLatest(now: now)
            startTimers()
            refreshLocked(now: now, checkSettings: false)
            DiagnosticsLog.shared.log("runtime: started (\(engine.statuses.count) statuses"
                + "\(reconciled ? ", recovered from logs" : "")\(options.serveSocket ? ", socket \(paths.socketPath)" : "")"
                + "\(options.dryRun ? ", dry run" : ""))")
            return true
        }
        guard started else { return }
        if let sleepWatcher, !sleepWatcher.start({ [weak self] in self?.handleSleepEvent($0) }) {
            DiagnosticsLog.shared.log("sleep: cannot watch for sleep, so the LEDs stay on while the Mac sleeps")
        }
        // Discovery can hang on a dead mount, so the first LED write follows it instead of holding up start().
        deviceQueue.async { [weak self] in self?.pollDevicesTick() }
    }

    /// Waits (bounded) for queued LED work and keepalive touches, then drops whatever LED work is
    /// still queued or blocked, so no LED write lands after it returns.
    public func stop() {
        let generation: Int? = onState {
            guard running else { return nil }
            running = false
            setOutputsOpen(false)
            refreshTimer?.cancel()
            refreshTimer = nil
            deviceTimer?.cancel()
            deviceTimer = nil
            server?.stop()
            server = nil
            latestSave?.cancel()
            latestSave = nil
            latestDirty = false
            saveLatest(now: Date())
            keepAwakeHolder?.setHeld(false)
            let wasHeld = shared.write { cache -> Bool in
                defer { cache.keepAwakeActive = false }
                return cache.keepAwakeActive
            }
            if wasHeld { DiagnosticsLog.shared.log("keep-awake: released") }
            return leds.currentGeneration
        }
        guard let generation else { return }
        sleepWatcher?.stop()
        persistQueue.sync {}
        leds.finishPreviewNow()
        leds.waitUntilIdle(timeout: 2)
        // Closed only now so the preview's restore above still writes; a start() since then keeps its own generation.
        leds.close(generation: generation)
        leds.waitForKeepaliveTouches(timeout: 1)
        DiagnosticsLog.shared.log("runtime: stopped")
    }

    // MARK: Non-blocking reads

    public func snapshot(now: Date = Date()) -> MonitorSnapshot {
        let (statuses, config) = shared.read { ($0.statuses, $0.config) }
        return SnapshotBuilder.build(statuses: statuses, config: config, now: now, sources: sources)
    }

    /// Includes changes made through this runtime that are still being saved.
    public var settings: SidePulseSettings {
        shared.read { $0.uiSettings }
    }

    public func deviceInfos() -> [DeviceInfo] {
        leds.deviceInfos(settings: settings)
    }

    public var keepAwakeActive: Bool {
        shared.read { $0.keepAwakeActive }
    }

    // MARK: Settings

    /// If the save fails the change still applies in memory.
    public func updateSettings(_ body: @escaping (inout SidePulseSettings) -> Void) {
        mutateSettings(body) { _, _ in }
    }

    /// A device switched to Manual this way is left alone rather than cleared, because
    /// `sidepulse write --manual` writes its own program right after.
    public func reloadSettings() {
        onState {
            reloadSettingsLocked()
            refreshLocked(now: Date(), checkSettings: false)
        }
    }

    public func setDeviceDisplay(_ display: LedDisplay, deviceID: String) {
        let device = leds.connectedDevices.first { $0.id == deviceID }
        let name = device?.displayName
        let path = device?.root.path
        mutateSettings({ $0.setDisplay(display, forDevice: deviceID, name: name, path: path) }) { [self] old, _ in
            let label = device?.displayName ?? deviceID
            DiagnosticsLog.shared.log("devices: \(label) set to \(display.label)")
            // `running` is read on the state queue, so this write is queued before
            // stop() drains the LED queue, or not at all.
            guard running, display == .manual, old.display(forDevice: deviceID) != .manual,
                  leds.connectedDevices.contains(where: { $0.id == deviceID }) else { return }
            leds.clearManualDevice(deviceID: deviceID) { result in
                switch result {
                case .success(true):
                    DiagnosticsLog.shared.log("devices: \(label): Manual, LEDs cleared")
                case .success(false):
                    DiagnosticsLog.shared.log("devices: \(label): Manual, LEDs left as they are")
                case .failure(let error):
                    DiagnosticsLog.shared.log("devices: \(label): Manual, clear failed: \(error.localizedDescription)")
                }
            }
        }
    }

    public func setDeviceBrightness(_ brightness: Int, deviceID: String) {
        let value = LedProgram.clampBrightness(brightness)
        let device = leds.connectedDevices.first { $0.id == deviceID }
        let name = device?.displayName
        let path = device?.root.path
        mutateSettings({ $0.setBrightness(value, forDevice: deviceID, name: name, path: path) }) { _, _ in }
    }

    public func removeDevice(id: String) {
        mutateSettings({ $0.removeDevice(id: id) }) { _, _ in
            DiagnosticsLog.shared.log("devices: forgot \(id)")
        }
    }

    // MARK: Events and refresh

    /// Synchronous, so `status` replies include the event once it returns.
    public func ingest(provider: String, line: JSONObject) {
        onState {
            ingestCount += 1
            guard engine.ingest(provider: provider, line: line) != nil else { return }
            if running { markLatestDirty() }
            let now = Date()
            let snapshot = publishStatuses(now: now)
            driveOutputs(snapshot, now: now)
            scheduleNotify()
        }
    }

    /// Asynchronous unless already on the state queue, so the main thread never waits.
    public func refresh() {
        if isOnStateQueue {
            refreshLocked(now: Date(), checkSettings: true)
        } else {
            stateQueue.async { [self] in refreshLocked(now: Date(), checkSettings: true) }
        }
    }

    public func preview(animationID: String, seconds: TimeInterval = 3) {
        outputsOpen.withLock { open in
            // Queued while holding the lock, so stop() (which closes it first) drains it.
            if open { leds.preview(animationID: animationID, seconds: seconds) }
        }
    }

    private func setOutputsOpen(_ open: Bool) {
        outputsOpen.withLock { $0 = open }
    }

    // MARK: Socket

    public func handle(_ message: IPCMessage) -> Data? {
        switch message {
        case .event(let provider, let line):
            ingest(provider: provider, line: line)
            return nil
        case .command(let name, let args):
            switch name {
            case "ping":
                return IPCReply.ping(kind: onOpenSettings == nil ? .headless : .app)
            case "status":
                // Only during start-up: otherwise never wait for the state queue.
                if shared.read({ $0.starting }) { onState {} }
                return Data(snapshot().toJSON().serialized().utf8)
            case "open-settings":
                guard onOpenSettings != nil else {
                    return IPCReply.error("this SidePulse instance has no settings window")
                }
                DispatchQueue.main.async { [weak self] in self?.onOpenSettings?() }
                return IPCReply.ok
            case "reload-settings":
                reloadSettings()
                // A write already past its settings check may still land, so wait for it before
                // `sidepulse write --manual` writes its own program; older CLIs name no device.
                let device = args["device"]?.stringValue
                guard leds.waitForWrites(deviceID: device, timeout: 2) else { return IPCReply.error("LED write in progress") }
                return IPCReply.ok
            default:
                return IPCReply.unknownCommand
            }
        }
    }

    // MARK: Test support

    /// Includes the first device discovery, which `start()` leaves running.
    func waitUntilIdle(timeout: TimeInterval = 5) {
        deviceQueue.sync {}
        onState {}
        leds.waitUntilIdle(timeout: timeout)
        persistQueue.sync {}
    }

    var isRunning: Bool { onState { running } }

    /// Includes events the engine dropped or ignored.
    var ingestedEventCount: Int { onState { ingestCount } }

    // MARK: - State queue internals

    private var isOnStateQueue: Bool {
        DispatchQueue.getSpecific(key: stateQueueKey) == true
    }

    private func onState<T>(_ body: () throws -> T) rethrows -> T {
        if isOnStateQueue { return try body() }
        return try stateQueue.sync(execute: body)
    }

    private func mutateSettings(_ body: @escaping (inout SidePulseSettings) -> Void,
                                after: @escaping (_ old: SidePulseSettings, _ saved: SidePulseSettings) -> Void) {
        var optimistic = settings
        body(&optimistic)
        shared.write { cache in
            cache.pendingUIUpdates += 1
            cache.uiSettings = optimistic
        }
        stateQueue.async { [self] in
            let old = applied
            var saved: SidePulseSettings
            do {
                saved = try settingsStore.update(body)
            } catch {
                DiagnosticsLog.shared.log("settings: save failed: \(error.localizedDescription)")
                saved = old
                body(&saved)
            }
            shared.write { $0.pendingUIUpdates -= 1 }
            applySettings(saved)
            after(old, saved)
            refreshLocked(now: Date(), checkSettings: false)
        }
    }

    @discardableResult
    private func applySettings(_ new: SidePulseSettings) -> Bool {
        let old = applied
        applied = new
        // The LED controllers notice brightness and animation changes themselves.
        if new != old { engine.config = new.monitorConfig }
        let config = engine.config
        shared.write { cache in
            cache.ledSettings = new
            cache.config = config
            if cache.pendingUIUpdates == 0 { cache.uiSettings = new }
        }
        return new != old
    }

    private func reloadSettingsLocked() {
        if applySettings(settingsStore.load()) { DiagnosticsLog.shared.log("settings: reloaded \(paths.settingsFile.path)") }
    }

    private func rememberConnectedDevices() {
        let connected = leds.connectedDevices
        guard !connected.isEmpty else { return }
        do {
            // The closure runs under the store's lock: it must not call back into it.
            let saved = try settingsStore.update { settings in
                for device in connected { settings.remember(device) }
            }
            applySettings(saved)
        } catch {
            DiagnosticsLog.shared.log("settings: could not remember devices: \(error.localizedDescription)")
        }
    }

    /// `checkSettings` re-reads the file (about 1 KB) outright, which picks up hand edits without tracking its date.
    private func refreshLocked(now: Date, checkSettings: Bool) {
        if checkSettings { reloadSettingsLocked() }
        let before = engine.statuses.count
        engine.prune(now: now)
        if running, engine.statuses.count != before { markLatestDirty() }
        let snapshot = publishStatuses(now: now)
        driveOutputs(snapshot, now: now)
        scheduleNotify()
    }

    @discardableResult
    private func publishStatuses(now: Date) -> MonitorSnapshot {
        let statuses = Array(engine.statuses.values)
        let config = engine.config
        shared.write { cache in
            cache.statuses = statuses
            cache.config = config
        }
        return SnapshotBuilder.build(statuses: statuses, config: config, now: now, sources: sources)
    }

    private func driveOutputs(_ snapshot: MonitorSnapshot, now: Date) {
        guard running else { return }
        leds.requestSync(mode: snapshot.aggregate.mode)
        leds.touchKeepalive(now: now)
        // Waiting and Blocked outrank Working in the aggregate, yet one agent still working must keep the Mac awake.
        let working = snapshot.statuses.contains { AgentMode.workingGroup.contains($0.mode) }
        updateKeepAwake(mode: working ? .working : snapshot.aggregate.mode, now: now)
    }

    private func startTimers() {
        refreshTimer?.cancel()
        deviceTimer?.cancel()
        let refreshInterval = RuntimeOptions.clamped(options.refreshInterval, to: 0.05...86_400, fallback: 15)
        let refresh = DispatchSource.makeTimerSource(queue: stateQueue)
        refresh.schedule(deadline: .now() + refreshInterval, repeating: refreshInterval,
                         leeway: .milliseconds(Int(min(1000, refreshInterval * 100))))
        refresh.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            self.refreshLocked(now: Date(), checkSettings: true)
        }
        refresh.resume()
        refreshTimer = refresh

        let pollInterval = RuntimeOptions.clamped(options.devicePollInterval, to: 0.05...86_400, fallback: 2)
        let poll = DispatchSource.makeTimerSource(queue: deviceQueue)
        poll.schedule(deadline: .now() + pollInterval, repeating: pollInterval,
                      leeway: .milliseconds(Int(min(500, pollInterval * 100))))
        poll.setEventHandler { [weak self] in self?.pollDevicesTick() }
        poll.resume()
        deviceTimer = poll
    }

    /// Runs on the device queue so a hung mount never stalls event handling.
    private func pollDevicesTick() {
        // A dark wake that turns into a full wake sends no event.
        turnLedsOnIfInUse()
        let changed = leds.pollDevices()
        let errorsChanged = leds.checkDeviceStatus()
        if changed {
            stateQueue.async { [weak self] in
                guard let self, self.running else { return }
                self.rememberConnectedDevices()
                self.refreshLocked(now: Date(), checkSettings: false)
            }
        } else if errorsChanged {
            scheduleNotify()
        }
    }

    // MARK: latest.json

    private func markLatestDirty() {
        latestDirty = true
        guard latestSave == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.flushLatest() }
        latestSave = work
        let delay = RuntimeOptions.clamped(options.latestSaveDelay, to: 0...3600, fallback: 1)
        stateQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func flushLatest() {
        latestSave = nil
        guard latestDirty, running else { return }
        latestDirty = false
        saveLatest(now: Date())
    }

    /// Logs only when saving starts failing or works again, because each error names a
    /// different random temp file.
    private func saveLatest(now: Date) {
        let statuses = Array(engine.statuses.values)
        let store = LatestStore(url: paths.latestFile)
        persistQueue.async { [weak self] in
            var failure: String?
            do {
                try store.save(statuses, now: now)
            } catch {
                failure = error.localizedDescription
            }
            guard let self, (failure != nil) != self.latestSaveFailing else { return }
            self.latestSaveFailing = failure != nil
            if let failure {
                DiagnosticsLog.shared.log("runtime: could not save \(store.url.path): \(failure)")
            } else {
                DiagnosticsLog.shared.log("runtime: saving \(store.url.path) works again")
            }
        }
    }

    // MARK: Sleep

    static let sleepWriteTimeout: TimeInterval = 2

    /// Runs on the watcher's queue, so it never waits for the state queue.
    private func handleSleepEvent(_ event: SleepEvent) {
        guard let sleepWatcher, outputsOpen.withLock({ $0 }) else { return }
        switch event {
        case .willSleep:
            let lidClosed = sleepWatcher.state.lidClosed == true
            guard lidClosed || shared.read({ $0.ledSettings.ledsOffOnAnySleep }) else {
                DiagnosticsLog.shared.log("sleep: Mac sleeping, LEDs left on")
                return
            }
            waitingForWake.withLock { $0 = true }
            let done = leds.turnOffForSleep(timeout: Self.sleepWriteTimeout)
            DiagnosticsLog.shared.log("sleep: Mac sleeping\(lidClosed ? " (lid closed)" : ""), LEDs off"
                + (done ? "" : "; a write is still pending"))
        case .didWake:
            waitingForWake.withLock { $0 = false }
            turnLedsOnIfInUse()
        case .lidChanged:
            turnLedsOnIfInUse()
        }
    }

    private func turnLedsOnIfInUse() {
        guard leds.isOffForSleep, !waitingForWake.withLock({ $0 }), let sleepWatcher, sleepWatcher.state.inUse,
              leds.turnOnAfterSleep() else { return }
        DiagnosticsLog.shared.log("sleep: Mac in use again, LEDs back on")
    }

    // MARK: Keep-awake

    private func updateKeepAwake(mode: AgentMode, now: Date) {
        guard let holder = keepAwakeHolder else { return }
        let agentsActive = policy.agentsActive(mode: mode, now: now)
        let battery = currentBattery(now: now)
        let safeguard = KeepAwakePolicy.safeguardActive(battery: battery, minBatteryPercent: applied.minBatteryPercent)
        if safeguard != safeguardActive {
            safeguardActive = safeguard
            let percent = battery.percent.map { "\(Int($0.rounded()))%" } ?? "unknown"
            DiagnosticsLog.shared.log("keep-awake: battery safeguard \(safeguard ? "active" : "released") "
                + "(battery \(percent), threshold \(Int(applied.minBatteryPercent))%)")
        }
        let hold = KeepAwakePolicy.shouldHold(policy: applied.sleepPolicy, agentsActive: agentsActive,
                                              battery: battery, minBatteryPercent: applied.minBatteryPercent)
        holder.setHeld(hold)
        let held = holder.isHeld
        let previous = shared.write { cache -> Bool in
            defer { cache.keepAwakeActive = held }
            return cache.keepAwakeActive
        }
        if previous != held {
            DiagnosticsLog.shared.log("keep-awake: \(held ? "active" : "released") (policy \(applied.sleepPolicy.rawValue))")
            scheduleNotify()
        }
    }

    private func currentBattery(now: Date) -> BatteryState {
        if let battery {
            let age = now.timeIntervalSince(battery.readAt)
            if age >= 0 && age < options.batteryCacheInterval { return battery.state }
        }
        let state = readBattery()
        battery = (state, now)
        return state
    }

    // MARK: Notifications

    private func scheduleNotify() {
        let schedule = shared.write { cache -> Bool in
            guard cache.onUpdate != nil, !cache.notifyScheduled else { return false }
            cache.notifyScheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let callback = self.shared.write { cache -> ((MonitorSnapshot) -> Void)? in
                cache.notifyScheduled = false
                return cache.onUpdate
            }
            callback?(self.snapshot())
        }
    }
}

private final class RuntimeCache: Sendable {
    struct Values {
        /// Includes UI changes that are still being saved, unlike `ledSettings`.
        var uiSettings: SidePulseSettings
        var ledSettings: SidePulseSettings
        /// While > 0 `uiSettings` is not overwritten, so an earlier save cannot undo a
        /// later unsaved change.
        var pendingUIUpdates = 0
        var statuses: [AgentStatus] = []
        var config: MonitorConfig
        var keepAwakeActive = false
        var starting = false
        var notifyScheduled = false
        var onUpdate: ((MonitorSnapshot) -> Void)?
        var onOpenSettings: (() -> Void)?
    }

    private let values: Mutex<Values>

    init(settings: SidePulseSettings) {
        values = Mutex(Values(uiSettings: settings, ledSettings: settings, config: settings.monitorConfig))
    }

    func read<T>(_ body: (Values) -> T) -> T {
        values.withLock { body($0) }
    }

    func write<T>(_ body: (inout Values) -> T) -> T {
        values.withLock { body(&$0) }
    }
}
