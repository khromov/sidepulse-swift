import Foundation

/// A connected (or remembered) device as shown in the UI.
public struct DeviceInfo: Sendable, Equatable, Identifiable {
    public var id: String
    /// Disambiguated display name ("SidePulse Dot", "SidePulse Dot (PulseDot 1)").
    public var name: String
    public var root: URL
    public var target: URL
    public var connected: Bool
    public var display: LedDisplay
    public var brightness: Int
    public var ledCount: Int
    /// Last write error for this device, if any, or a notice that its I/O is stuck
    /// waiting for macOS permission (`LedSyncService.waitingForPermissionMessage`).
    public var lastError: String?

    public init(id: String, name: String, root: URL, target: URL, connected: Bool, display: LedDisplay,
                brightness: Int, ledCount: Int, lastError: String? = nil) {
        self.id = id; self.name = name; self.root = root; self.target = target; self.connected = connected
        self.display = display; self.brightness = brightness; self.ledCount = ledCount; self.lastError = lastError
    }
}

/// Something that can hold the Mac awake (`KeepAwakeAssertion`; tests inject fakes).
public protocol KeepAwakeHolding: AnyObject, Sendable {
    var isHeld: Bool { get }
    /// Why the last attempt to hold failed, nil after a success.
    var lastError: String? { get }
    func setHeld(_ held: Bool)
}

extension KeepAwakeAssertion: KeepAwakeHolding {}

public struct RuntimeOptions: Sendable {
    /// Bind the event socket (false for tests).
    public var serveSocket = true
    /// Run keep-awake logic (a power assertion).
    public var keepAwake = true
    /// Validate/print but never write LEDs.
    public var dryRun = false
    /// Override mount roots (tests).
    public var mountRoots: [URL]? = nil
    /// Status refresh period. Clamped to 0.05 s ... 1 day (Dispatch traps on
    /// intervals of centuries, and `--interval` accepts any positive number).
    public var refreshInterval: TimeInterval = 15
    /// Device discovery period, clamped like `refreshInterval`.
    public var devicePollInterval: TimeInterval = 2

    /// Battery reader for the keep-awake low-battery safeguard. nil = IOKit
    /// (`BatteryState.read`). Only called while `keepAwake` is on.
    public var batteryReader: (@Sendable () -> BatteryState)? = nil
    /// How long a battery reading is reused.
    public var batteryCacheInterval: TimeInterval = 30
    /// What holds the Mac awake. nil = a `KeepAwakeAssertion` (only created when
    /// `keepAwake` is on).
    public var keepAwakeHolder: (any KeepAwakeHolding)? = nil
    /// Grace after agents complete / ask during which keep-awake keeps holding.
    public var keepAwakeGrace: TimeInterval = 300
    /// latest.json writes are coalesced: the first change schedules a save this
    /// long after it (changes in between ride along). `stop()` flushes. Clamped to
    /// 0 ... 1 hour.
    public var latestSaveDelay: TimeInterval = 1

    /// Device discovery (nil = `DeviceDiscovery.discover`). Tests inject slow ones.
    var deviceDiscovery: (@Sendable ([URL]?) -> [DeviceCandidate])? = nil
    /// One keepalive touch (nil = `KeepaliveToucher.touchFile`). Tests inject slow ones.
    var keepaliveTouch: (@Sendable (URL) throws -> Void)? = nil
    /// Called by `start()` right after the socket is bound, before rows are loaded
    /// (tests hold start-up there).
    var afterBind: (@Sendable () -> Void)? = nil
    /// How long `start()` waits for the first device discovery before carrying on
    /// in the background (a hung volume under /Volumes must not stall app launch).
    var startupDiscoveryTimeout: TimeInterval = 2

    public init() {}

    /// `value` clamped to `range`; +infinity gives the upper bound, NaN `fallback`.
    static func clamped(_ value: TimeInterval, to range: ClosedRange<TimeInterval>,
                        fallback: TimeInterval) -> TimeInterval {
        if value.isNaN { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

/// The app's brain, shared by the menu-bar app and headless `sidepulse run`:
/// event socket server → StatusEngine → debounced latest.json, LED sync,
/// keep-awake, device polling, settings reloads. No AppKit.
///
/// Threading: engine state lives on an internal serial queue; `onUpdate` and
/// `onOpenSettings` are invoked on the main queue.
///
/// - Reads the UI makes on the main thread (`snapshot()`, `settings`,
///   `deviceInfos()`, `keepAwakeActive`) come from lock-protected caches and never
///   wait for the state queue, device I/O or a settings write.
/// - `updateSettings`, `setDeviceDisplay`, `setDeviceBrightness`, `removeDevice`
///   and `refresh` return at once: `settings` reflects the change immediately, the
///   save and its effects happen on the state queue, then `onUpdate` fires.
/// - `ingest`, `reloadSettings` and `start`/`stop` run synchronously on the state
///   queue (they are called from the socket handler, tests and startup).
/// - LED writes run on `LedSyncService`'s queue, latest.json writes on their own
///   queue.
public final class SidePulseRuntime: @unchecked Sendable {
    public let paths: SidePulsePaths
    public let options: RuntimeOptions
    public let settingsStore: SettingsStore
    public let leds: LedSyncService

    /// Called on the main queue after every accepted event / refresh / settings change.
    ///
    /// Notifications are coalesced: while one is waiting for the main queue, later
    /// changes ride along and it delivers the snapshot current at delivery time.
    public var onUpdate: ((MonitorSnapshot) -> Void)? {
        get { shared.read { $0.onUpdate } }
        set { shared.write { $0.onUpdate = newValue } }
    }

    /// Called on the main queue for the `open-settings` socket command. Without a
    /// handler (headless runtime) that command is refused, so the CLI can tell
    /// there is no settings window.
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
    /// Settings the engine and LEDs currently run with.
    private var applied: SidePulseSettings
    /// settings.json's modification date when it was last loaded or saved here.
    private var settingsModified: Date?
    /// Re-read settings.json on the next refresh even if its date looks unchanged:
    /// set after our own saves, whose date is taken after the store's lock is
    /// released, so another process's save in between would otherwise be missed.
    private var settingsRecheck = false
    /// Bumped by every `start()`, so the second half of a start that raced with
    /// `stop()` (and maybe another `start()`) never runs twice.
    private var startGeneration = 0
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
    private let readBattery: @Sendable () -> BatteryState
    /// Last keep-awake error logged.
    private var loggedHolderError: String?
    /// The last latest.json save failed (persist queue only).
    private var latestSaveFailing = false
    /// Guards `outputsOpen`: previews check it and enqueue their write under this
    /// lock, and `stop()` closes it before draining the LED queue, so nothing is
    /// written after `stop()` returns.
    private let outputLock = NSLock()
    private var outputsOpen = false
    /// Events passed to `ingest` (accepted or not), for tests and diagnostics.
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
                                   discover: options.deviceDiscovery ?? { DeviceDiscovery.discover(roots: $0) })
        let index = CodexSessionIndex(paths: paths)
        self.codexIndex = index
        self.engine = StatusEngine(config: settings.monitorConfig, codexTitle: { index.title(forSession: $0) })
        self.applied = settings
        self.sources = HookProvider.allCases.map {
            SourceInfo(provider: $0.rawValue, path: paths.logFile(for: $0.rawValue).path)
        }
        self.policy = KeepAwakePolicy(grace: options.keepAwakeGrace)
        self.keepAwakeHolder = options.keepAwake ? (options.keepAwakeHolder ?? KeepAwakeAssertion()) : nil
        self.readBattery = options.batteryReader ?? { BatteryState.read() }
        stateQueue.setSpecific(key: stateQueueKey, value: true)
    }

    deinit {
        refreshTimer?.cancel()
        deviceTimer?.cancel()
        server?.stop()
    }

    // MARK: Lifecycle

    /// Loads settings + latest.json, reconciles with the provider logs
    /// (LogScanner.scan over LogScanner.defaultSources), binds the socket (throws
    /// `EventSocketError.alreadyRunning` if another instance serves it), starts the
    /// refresh (15 s) and device-poll (2 s) timers, and syncs LEDs.
    ///
    /// The socket is bound before anything is written (settings, latest.json,
    /// LEDs), so a second instance fails without side effects. Calling `start()`
    /// on a running runtime does nothing.
    ///
    /// The first device discovery is waited for (so the first sync reaches every
    /// mounted volume) for at most a couple of seconds; a hung volume finishes in
    /// the background and its devices are synced when it does.
    public func start() throws {
        let generation: Int? = try onState {
            guard !running else { return nil }
            // The socket serves before the rows below are loaded: until this block
            // ends, `status` waits for it instead of answering with an empty
            // "live" snapshot.
            shared.write { $0.starting = true }
            defer { shared.write { $0.starting = false } }
            // Date first: an edit landing between the two reads is picked up later.
            settingsModified = settingsStore.modificationDate
            settingsRecheck = false
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
            // Like reconcile: a restored row never replaces a newer one this engine
            // already has (a restart after stop(), which may still have taken one
            // last event that latest.json does not hold).
            let current = engine.statuses
            engine.load(LatestStore(url: paths.latestFile).load().filter { row in
                current[row.agentID].map { $0.updatedAt < row.updatedAt } ?? true
            })
            let index = codexIndex
            let recovered = LogScanner.scan(sources: LogScanner.defaultSources(paths: paths),
                                            config: settings.monitorConfig,
                                            codexTitle: { index.title(forSession: $0) })
            let reconciled = engine.reconcile(with: recovered)
            engine.prune(now: now)
            policy = KeepAwakePolicy(grace: options.keepAwakeGrace)
            battery = nil
            safeguardActive = false
            running = true
            startGeneration += 1
            setOutputsOpen(true)
            publishStatuses(now: now)
            saveLatest(now: now)
            DiagnosticsLog.shared.log("runtime: started (\(engine.statuses.count) statuses"
                + "\(reconciled ? ", recovered from logs" : "")\(options.serveSocket ? ", socket \(paths.socketPath)" : "")"
                + "\(options.dryRun ? ", dry run" : ""))")
            return startGeneration
        }
        guard let generation else { return }
        pollDevicesAtStart(generation: generation)
        onState {
            // A stop() (and maybe another start()) got in between: that one owns the timers.
            guard running, startGeneration == generation else { return }
            rememberConnectedDevices()
            startTimers()
            refreshLocked(now: Date(), checkSettings: false)
        }
    }

    /// Runs the first discovery on the device queue and waits for it at most
    /// `options.startupDiscoveryTimeout`. If it takes longer, it finishes in the
    /// background and then remembers and syncs what it found.
    private func pollDevicesAtStart(generation: Int) {
        let poll = StartupPoll()
        deviceQueue.async { [weak self] in
            guard let self else { return }
            self.leds.pollDevices()
            guard poll.finish() else { return }
            // start() gave up waiting: finish its job now.
            self.stateQueue.async { [weak self] in
                guard let self, self.running, self.startGeneration == generation else { return }
                DiagnosticsLog.shared.log("devices: first discovery finished")
                self.rememberConnectedDevices()
                self.refreshLocked(now: Date(), checkSettings: false)
            }
        }
        let timeout = RuntimeOptions.clamped(options.startupDiscoveryTimeout, to: 0...60, fallback: 2)
        if !poll.wait(timeout: timeout) {
            DiagnosticsLog.shared.log("devices: discovery is slow (a hung volume?); continuing in the background")
        }
    }

    /// Stops timers and the socket, flushes latest.json, releases keep-awake.
    /// LEDs keep their last program.
    ///
    /// A preview that is still playing is ended and live status restored first.
    /// Waits (bounded) for queued LED work and keepalive touches, so nothing is
    /// written after `stop()` returns; later previews and Manual switches write
    /// nothing. Safe to call before `start()` and more than once.
    public func stop() {
        let stopped: Bool = onState {
            guard running else { return false }
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
            return true
        }
        guard stopped else { return }
        persistQueue.sync {}
        leds.finishPreviewNow()
        leds.waitUntilIdle(timeout: 2)
        leds.waitForKeepaliveTouches(timeout: 1)
        DiagnosticsLog.shared.log("runtime: stopped")
    }

    // MARK: Non-blocking reads

    /// Current snapshot (thread-safe).
    public func snapshot(now: Date = Date()) -> MonitorSnapshot {
        let (statuses, config) = shared.read { ($0.statuses, $0.config) }
        return SnapshotBuilder.build(statuses: statuses, config: config, now: now, sources: sources)
    }

    /// Current settings (thread-safe copy).
    ///
    /// Includes changes made through this runtime that are still being saved.
    public var settings: SidePulseSettings {
        shared.read { $0.uiSettings }
    }

    public func deviceInfos() -> [DeviceInfo] {
        leds.deviceInfos(settings: settings)
    }

    /// Whether the Mac is currently held awake.
    public var keepAwakeActive: Bool {
        shared.read { $0.keepAwakeActive }
    }

    // MARK: Settings

    /// Reload-modify-save through `settingsStore.update`, then apply (monitor config,
    /// LED resync, keep-awake) and fire `onUpdate`.
    ///
    /// Returns immediately: `settings` shows the change at once, the save runs on
    /// the state queue. If the save fails the change still applies in memory.
    public func updateSettings(_ body: @escaping (inout SidePulseSettings) -> Void) {
        mutateSettings(body) { _, _ in }
    }

    /// Re-read settings.json (socket `reload-settings`, or external edit detected on
    /// refresh via mtime).
    ///
    /// Synchronous: the new settings are applied (and LEDs resynced) when it
    /// returns. A device that became Manual this way is only left alone, never
    /// cleared (`sidepulse write --manual` writes its own program right after).
    public func reloadSettings() {
        onState {
            reloadSettingsLocked()
            refreshLocked(now: Date(), checkSettings: false)
        }
    }

    /// Switching to Manual writes "off" once to a connected device.
    ///
    /// Only an actual switch (from Agent) of a connected device clears it, and only
    /// while LED output is enabled and the runtime is running.
    public func setDeviceDisplay(_ display: LedDisplay, deviceID: String) {
        let device = leds.connectedDevices.first { $0.id == deviceID }
        let name = device?.displayName
        let path = device?.root.path
        // applySettings resets the device's controller (its display changed).
        mutateSettings({ $0.setDisplay(display, forDevice: deviceID, name: name, path: path) }) { [self] old, _ in
            let label = device?.displayName ?? deviceID
            DiagnosticsLog.shared.log("devices: \(label) set to \(display.label)")
            // `running` is read on the state queue, so this write is queued before
            // stop() drains the LED queue, or not at all.
            guard running, display == .manual, old.display(forDevice: deviceID) != .manual,
                  leds.connectedDevices.contains(where: { $0.id == deviceID }) else { return }
            leds.writeOnceAsync(program: "off", deviceID: deviceID) { error in
                if let error {
                    DiagnosticsLog.shared.log("devices: \(label): Manual, clear failed: \(error.localizedDescription)")
                } else {
                    DiagnosticsLog.shared.log("devices: \(label): Manual, LEDs cleared")
                }
            }
        }
    }

    public func setDeviceBrightness(_ brightness: Int, deviceID: String) {
        let value = LedProgram.clampBrightness(brightness)
        let device = leds.connectedDevices.first { $0.id == deviceID }
        let name = device?.displayName
        let path = device?.root.path
        // applySettings resets the device's controller (its brightness changed).
        mutateSettings({ $0.setBrightness(value, forDevice: deviceID, name: name, path: path) }) { _, _ in }
    }

    public func removeDevice(id: String) {
        mutateSettings({ $0.removeDevice(id: id) }) { _, _ in
            DiagnosticsLog.shared.log("devices: forgot \(id)")
        }
    }

    // MARK: Events and refresh

    /// Feed an event directly (used by the socket handler and tests).
    ///
    /// Synchronous: the snapshot (and `status` replies) include the event when it
    /// returns. Dropped/ignored events change nothing.
    public func ingest(provider: String, line: JSONObject) {
        onState {
            ingestCount += 1
            guard engine.ingest(provider: provider, line: line) != nil else { return }
            if running { markLatestDirty() }
            let now = Date()
            let snapshot = publishStatuses(now: now)
            driveOutputs(mode: snapshot.aggregate.mode, now: now)
            scheduleNotify()
        }
    }

    /// Recompute snapshot, sync LEDs, update keep-awake, fire onUpdate.
    ///
    /// Also picks up an external settings.json edit. Asynchronous unless called on
    /// the state queue, so the main thread never waits.
    public func refresh() {
        if isOnStateQueue {
            refreshLocked(now: Date(), checkSettings: true)
        } else {
            stateQueue.async { [self] in refreshLocked(now: Date(), checkSettings: true) }
        }
    }

    /// Plays `animationID` on the connected Agent-mode devices, then restores live
    /// status (`LedSyncService.preview`). Ignored unless the runtime is running.
    public func preview(animationID: String, seconds: TimeInterval = 3) {
        outputLock.lock()
        defer { outputLock.unlock() }
        guard outputsOpen else { return }
        // Queued while holding the lock, so stop() (which closes it first) drains it.
        leds.preview(animationID: animationID, seconds: seconds)
    }

    private func setOutputsOpen(_ open: Bool) {
        outputLock.lock()
        outputsOpen = open
        outputLock.unlock()
    }

    // MARK: Socket

    /// Handles one socket message (exposed for tests).
    public func handle(_ message: IPCMessage) -> Data? {
        switch message {
        case .event(let provider, let line):
            ingest(provider: provider, line: line)
            return nil
        case .command(let name, _):
            switch name {
            case "ping":
                return IPCReply.ping()
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
                // Writes still in open() re-check the new settings and skip a device
                // that became Manual; one already writing may still land, so wait for
                // it before `sidepulse write --manual` writes its own program.
                guard leds.waitForWrites(timeout: 2) else { return IPCReply.error("LED write in progress") }
                return IPCReply.ok
            default:
                return IPCReply.unknownCommand
            }
        }
    }

    // MARK: Test support

    /// Waits until work queued so far (state, LEDs, latest.json) is done.
    func waitUntilIdle(timeout: TimeInterval = 5) {
        onState {}
        leds.waitUntilIdle(timeout: timeout)
        persistQueue.sync {}
    }

    /// Whether the runtime is between `start()` and `stop()`.
    var isRunning: Bool { onState { running } }

    /// Events passed to `ingest` so far (accepted or not).
    var ingestedEventCount: Int { onState { ingestCount } }

    // MARK: - State queue internals

    private var isOnStateQueue: Bool {
        DispatchQueue.getSpecific(key: stateQueueKey) == true
    }

    private func onState<T>(_ body: () throws -> T) rethrows -> T {
        if isOnStateQueue { return try body() }
        return try stateQueue.sync(execute: body)
    }

    /// Applies `body` to the cached settings at once (so the UI sees it), then saves
    /// and applies it on the state queue, runs `after(old, saved)`, refreshes and
    /// fires `onUpdate`.
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
                noteOwnSettingsSave()
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

    /// Makes `new` the running settings: monitor config, controller resets for
    /// changed devices / animations / LED output, and the caches. Returns true if
    /// anything changed.
    @discardableResult
    private func applySettings(_ new: SidePulseSettings) -> Bool {
        let old = applied
        applied = new
        if new != old {
            engine.config = new.monitorConfig
            // Flag resets before the LEDs can see the new settings.
            if new.animationSelection != old.animationSelection {
                leds.resetControllers()
            } else {
                var ids = Set(new.devices.map(\.id)).union(old.devices.map(\.id))
                ids.formUnion(leds.connectedDevices.map(\.id))
                for id in ids.sorted() where old.display(forDevice: id) != new.display(forDevice: id)
                    || old.brightness(forDevice: id) != new.brightness(forDevice: id) {
                    leds.resetControllers(deviceID: id)
                }
            }
        }
        let config = engine.config
        shared.write { cache in
            cache.ledSettings = new
            cache.config = config
            if cache.pendingUIUpdates == 0 { cache.uiSettings = new }
        }
        return new != old
    }

    @discardableResult
    private func reloadSettingsLocked() -> Bool {
        // Date first: an edit landing between the two reads changes the date again,
        // so the next refresh reloads instead of missing it.
        settingsModified = settingsStore.modificationDate
        settingsRecheck = false
        let loaded = settingsStore.load()
        let changed = applySettings(loaded)
        if changed { DiagnosticsLog.shared.log("settings: reloaded \(paths.settingsFile.path)") }
        return changed
    }

    /// Upserts every connected device into settings.json (written only when
    /// something changed).
    private func rememberConnectedDevices() {
        let connected = leds.connectedDevices
        guard !connected.isEmpty else { return }
        do {
            // The closure runs under the store's lock: it must not call back into it.
            let saved = try settingsStore.update { settings in
                for device in connected { settings.remember(device) }
            }
            noteOwnSettingsSave()
            applySettings(saved)
        } catch {
            DiagnosticsLog.shared.log("settings: could not remember devices: \(error.localizedDescription)")
        }
    }

    /// After `settingsStore.update` succeeded: remember the file's date, and make
    /// the next refresh re-read the file once anyway. The date is taken after the
    /// store released its lock, so it may already belong to another process's
    /// save; the extra read (a no-op when nothing changed) makes sure that save
    /// is not missed.
    private func noteOwnSettingsSave() {
        settingsModified = settingsStore.modificationDate
        settingsRecheck = true
    }

    private func refreshLocked(now: Date, checkSettings: Bool) {
        if checkSettings, settingsRecheck || settingsStore.modificationDate != settingsModified {
            reloadSettingsLocked()
        }
        let before = engine.statuses.count
        engine.prune(now: now)
        if running, engine.statuses.count != before { markLatestDirty() }
        let snapshot = publishStatuses(now: now)
        driveOutputs(mode: snapshot.aggregate.mode, now: now)
        scheduleNotify()
    }

    /// Copies the engine's rows into the cache; returns the snapshot at `now`.
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

    /// LEDs, keepalive and keep-awake for the aggregate `mode` (only while running).
    private func driveOutputs(mode: AgentMode, now: Date) {
        guard running else { return }
        leds.requestSync(mode: mode)
        leds.touchKeepalive(now: now)
        updateKeepAwake(mode: mode, now: now)
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

    /// Device queue: discovery off the state queue (a hung mount must not stall
    /// events); on a change remember new devices and resync at once. A device
    /// whose error or stuck-I/O notice changed refreshes the UI.
    private func pollDevicesTick() {
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

    /// Writes the engine's rows on the persist queue. A failure is logged when
    /// saving starts failing and when it works again, not on every save (errors
    /// name a random temp file, so they differ each time).
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
        // Called every time, so a failed hold is retried.
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
        let error = hold && !held ? holder.lastError : nil
        if error != loggedHolderError {
            loggedHolderError = error
            if let error { DiagnosticsLog.shared.log("keep-awake: error: \(error)") }
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

/// Hand-off between `start()` and its first device discovery: `start()` waits a
/// bounded time; if it gives up, the discovery learns so when it finishes.
private final class StartupPoll: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var finished = false
    private var abandoned = false

    /// Called by the discovery when it is done. Returns true when the waiter had
    /// already given up (so the discovery must finish the start-up work itself).
    func finish() -> Bool {
        lock.lock()
        finished = true
        let abandoned = self.abandoned
        lock.unlock()
        done.signal()
        return abandoned
    }

    /// Returns true when the discovery finished within `timeout`.
    func wait(timeout: TimeInterval) -> Bool {
        if done.wait(timeout: .now() + timeout) == .success { return true }
        lock.lock()
        defer { lock.unlock() }
        if finished { return true }
        abandoned = true
        return false
    }
}

/// Lock-protected values shared between the state queue and readers on any
/// thread (the UI reads them on the main thread).
private final class RuntimeCache: @unchecked Sendable {
    struct Values {
        /// What `SidePulseRuntime.settings` returns (includes unsaved UI changes).
        var uiSettings: SidePulseSettings
        /// What the LEDs run with (applied on the state queue).
        var ledSettings: SidePulseSettings
        /// UI changes queued for saving; while > 0 `uiSettings` is not overwritten.
        var pendingUIUpdates = 0
        var statuses: [AgentStatus] = []
        var config: MonitorConfig
        var keepAwakeActive = false
        /// `start()` is loading rows (the socket may already serve).
        var starting = false
        var notifyScheduled = false
        var onUpdate: ((MonitorSnapshot) -> Void)?
        var onOpenSettings: (() -> Void)?
    }

    private let lock = NSLock()
    private var values: Values

    init(settings: SidePulseSettings) {
        values = Values(uiSettings: settings, ledSettings: settings, config: settings.monitorConfig)
    }

    func read<T>(_ body: (Values) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(values)
    }

    func write<T>(_ body: (inout Values) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&values)
    }
}
