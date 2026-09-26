import Foundation
import Synchronization

/// In "manual" mode SidePulse never writes to the device.
public enum LedDisplay: String, Sendable, CaseIterable {
    case agent
    case manual

    public var label: String { self == .agent ? "Agent Status" : "Manual" }
}

public enum SleepPolicy: String, Sendable, CaseIterable {
    case never, agents, always

    public var label: String {
        switch self {
        case .never: return "Never"
        case .agents: return "When Agents Work"
        case .always: return "Always"
        }
    }
}

public struct DeviceSettings: Sendable, Equatable {
    /// The volume root path.
    public var id: String
    public var name: String
    public var path: String
    public var display: LedDisplay
    /// 0...255
    public var brightness: Int

    public init(id: String, name: String, path: String, display: LedDisplay, brightness: Int) {
        self.id = id; self.name = name; self.path = path; self.display = display; self.brightness = brightness
    }
}

public struct SidePulseSettings: Sendable, Equatable {
    public var devices: [DeviceSettings] = []
    /// Only explicit selections are stored, keyed by AgentMode raw value.
    public var animations: [String: String] = [:]
    public var idleTimeoutSeconds: Double = 3600
    public var sessionRetentionSeconds: Double = 172_800
    public var sleepPolicy: SleepPolicy = .agents
    public var minBatteryPercent: Double = 20
    public var sdEjectGuard = true

    public init() {}

    // MARK: JSON

    /// Like Python `load_settings`, each missing or invalid field falls back to its
    /// default on its own, so one bad value never discards the rest of the file.
    public static func fromJSON(_ value: JSONValue) -> SidePulseSettings {
        var settings = SidePulseSettings()
        guard let root = value.objectValue else { return settings }

        settings.devices = decodeDevices(root["devices"])
        settings.animations = decodeAnimations(root["agent_animations"])

        let agentList = root["agent_list"]?.objectValue ?? JSONObject()
        if let seconds = finiteNumber(agentList["idle_timeout_seconds"]) {
            settings.idleTimeoutSeconds = max(0, seconds)
        }
        if let seconds = finiteNumber(agentList["recent_session_retention_seconds"]) {
            settings.sessionRetentionSeconds = max(0, seconds)
        }

        let sleep = root["sleep_prevention"]?.objectValue ?? JSONObject()
        if let policy = sleep["policy"]?.stringValue.flatMap(SleepPolicy.init(rawValue:)) {
            settings.sleepPolicy = policy
        }
        if let percent = finiteNumber(sleep["min_battery_percent"]) {
            settings.minBatteryPercent = min(100, max(0, percent))
        }
        if let enabled = root["sd_eject_guard"]?.objectValue?["enabled"]?.boolValue {
            settings.sdEjectGuard = enabled
        }
        return settings
    }

    /// Non-finite numbers are written as their defaults because JSON has no literal
    /// for them and one would make the whole file unreadable.
    public func toJSON() -> JSONValue {
        let defaults = SidePulseSettings()
        func seconds(_ value: Double, _ fallback: Double) -> JSONValue {
            JSONValue(value.isFinite ? max(0, value) : fallback, integralAsInt: true)
        }
        var root = JSONObject()
        root["agent_animations"] = .object(JSONObject(animations.map { ($0.key, JSONValue.string($0.value)) }))
        root["agent_list"] = .object([
            "idle_timeout_seconds": seconds(idleTimeoutSeconds, defaults.idleTimeoutSeconds),
            "recent_session_retention_seconds": seconds(sessionRetentionSeconds, defaults.sessionRetentionSeconds),
        ])
        root["devices"] = .array(devices.map { device in
            .object([
                "brightness": JSONValue(LedProgram.clampBrightness(device.brightness)),
                "display": .string(device.display.rawValue),
                "id": .string(device.id),
                "name": .string(device.name),
                "path": .string(device.path),
            ])
        })
        let percent = minBatteryPercent.isFinite ? min(100, max(0, minBatteryPercent)) : defaults.minBatteryPercent
        root["sleep_prevention"] = .object([
            "min_battery_percent": JSONValue(percent, integralAsInt: true),
            "policy": .string(sleepPolicy.rawValue),
        ])
        root["sd_eject_guard"] = .object(["enabled": .bool(sdEjectGuard)])
        return JSONValue.object(root).sortedKeys()
    }

    private static func finiteNumber(_ value: JSONValue?) -> Double? {
        guard let number = value?.doubleValue, number.isFinite else { return nil }
        return number
    }

    private static func nonEmptyString(_ value: JSONValue?) -> String? {
        guard let string = value?.stringValue, !string.isEmpty else { return nil }
        return string
    }

    private static func decodeDevices(_ value: JSONValue?) -> [DeviceSettings] {
        guard let items = value?.arrayValue else { return [] }
        var devices: [DeviceSettings] = []
        var seen = Set<String>()
        for item in items {
            guard let entry = item.objectValue, let id = nonEmptyString(entry["id"]),
                  seen.insert(id).inserted else { continue }
            let path = nonEmptyString(entry["path"]) ?? id
            let name = nonEmptyString(entry["name"]) ?? URL(fileURLWithPath: path).lastPathComponent
            let display = entry["display"]?.stringValue.flatMap(LedDisplay.init(rawValue:)) ?? .agent
            let brightness = LedProgram.normalizeBrightness(entry["brightness"]?.doubleValue)
            devices.append(DeviceSettings(id: id, name: name, path: path, display: display, brightness: brightness))
        }
        return devices
    }

    private static func decodeAnimations(_ value: JSONValue?) -> [String: String] {
        guard let object = value?.objectValue else { return [:] }
        var animations: [String: String] = [:]
        for (key, value) in object {
            guard let mode = AgentMode(rawValue: key), let id = value.stringValue else { continue }
            animations[key] = AnimationLibrary.animation(id: id) != nil ? id : AnimationLibrary.defaultAnimationID(for: mode)
        }
        if let shared = AgentMode.workingGroup.lazy.compactMap({ animations[$0.rawValue] }).first {
            for mode in AgentMode.workingGroup { animations[mode.rawValue] = shared }
        }
        return animations
    }

    // MARK: Animations

    /// The working group shares one selection, so the first stored entry in the group wins.
    public func animationID(for mode: AgentMode) -> String {
        let keys = AgentMode.workingGroup.contains(mode) ? AgentMode.workingGroup : [mode]
        if let stored = keys.lazy.compactMap({ animations[$0.rawValue] }).first,
           AnimationLibrary.animation(id: stored) != nil {
            return stored
        }
        return AnimationLibrary.defaultAnimationID(for: mode)
    }

    public mutating func setAnimation(_ id: String, for mode: AgentMode) {
        guard AnimationLibrary.animation(id: id) != nil else { return }
        let modes = AgentMode.workingGroup.contains(mode) ? AgentMode.workingGroup : [mode]
        for target in modes { animations[target.rawValue] = id }
    }

    public var animationSelection: [AgentMode: String] {
        Dictionary(uniqueKeysWithValues: AgentMode.allCases.map { ($0, animationID(for: $0)) })
    }

    /// Stores every mode explicitly, unlike `setAnimation`, as Python
    /// `with_applied_agent_animation_profile` does.
    public mutating func apply(profile: AnimationProfile) {
        func resolved(_ mode: AgentMode) -> String {
            if let id = profile.animations[mode], AnimationLibrary.animation(id: id) != nil { return id }
            return AnimationLibrary.defaultAnimationID(for: mode)
        }
        let working = resolved(.working)
        animations = Dictionary(uniqueKeysWithValues: AgentMode.allCases.map { mode in
            (mode.rawValue, AgentMode.workingGroup.contains(mode) ? working : resolved(mode))
        })
    }

    public var matchingProfile: AnimationProfile? { AnimationProfiles.matching(animationSelection) }

    // MARK: Devices

    public func device(id: String) -> DeviceSettings? { devices.first { $0.id == id } }

    public func display(forDevice id: String) -> LedDisplay {
        device(id: id)?.display ?? .agent
    }

    public func brightness(forDevice id: String) -> Int {
        device(id: id).map { LedProgram.clampBrightness($0.brightness) } ?? 255
    }

    public mutating func setDisplay(_ display: LedDisplay, forDevice id: String, name: String? = nil, path: String? = nil) {
        upsertDevice(id: id, name: name, path: path) { $0.display = display }
    }

    public mutating func setBrightness(_ brightness: Int, forDevice id: String, name: String? = nil, path: String? = nil) {
        let value = LedProgram.clampBrightness(brightness)
        upsertDevice(id: id, name: name, path: path) { $0.brightness = value }
    }

    @discardableResult
    public mutating func remember(_ device: DeviceCandidate) -> Bool {
        let before = devices
        setDisplay(display(forDevice: device.id), forDevice: device.id, name: device.displayName, path: device.root.path)
        return devices != before
    }

    public mutating func removeDevice(id: String) {
        devices.removeAll { $0.id == id }
    }

    private mutating func upsertDevice(id: String, name: String?, path: String?, _ change: (inout DeviceSettings) -> Void) {
        let name = name.flatMap { $0.isEmpty ? nil : $0 }
        let path = path.flatMap { $0.isEmpty ? nil : $0 }
        if let index = devices.firstIndex(where: { $0.id == id }) {
            if let name { devices[index].name = name }
            if let path { devices[index].path = path }
            change(&devices[index])
        } else {
            var entry = DeviceSettings(id: id, name: name ?? id, path: path ?? id,
                                       display: display(forDevice: id), brightness: brightness(forDevice: id))
            change(&entry)
            devices.append(entry)
        }
    }

    public var monitorConfig: MonitorConfig {
        MonitorConfig(staleAfter: idleTimeoutSeconds, retention: sessionRetentionSeconds)
    }
}

/// Writes hold a `flock` on `<settings>.lock` so the CLI and app never clobber each other's changes.
public final class SettingsStore: Sendable {
    public let url: URL
    /// Serializes this instance's writers; `flock` covers other instances and processes.
    private let writers = Mutex(())

    public init(url: URL) {
        self.url = url
    }

    public var lockURL: URL { URL(fileURLWithPath: url.path + ".lock") }

    /// Reads take no lock because saves replace the file atomically.
    public func load() -> SidePulseSettings {
        read().settings
    }

    public func save(_ settings: SidePulseSettings) throws {
        try withLock {
            try write(settings, replacing: read())
        }
    }

    /// `body` runs while the lock is held, so it must not call back into this store.
    /// A no-op update skips the write so it does not bump the modification date.
    @discardableResult
    public func update(_ body: (inout SidePulseSettings) -> Void) throws -> SidePulseSettings {
        try withLock {
            let current = read()
            var updated = current.settings
            body(&updated)
            if updated != current.settings || current.state == .missing {
                try write(updated, replacing: current)
            }
            return updated
        }
    }

    private enum FileState { case missing, valid, unreadable }

    private func read() -> (settings: SidePulseSettings, state: FileState) {
        guard let data = try? Data(contentsOf: url) else {
            let exists = FileManager.default.fileExists(atPath: url.path)
            return (SidePulseSettings(), exists ? .unreadable : .missing)
        }
        guard let json = try? JSONValue.parse(data), json.objectValue != nil else {
            return (SidePulseSettings(), .unreadable)
        }
        return (SidePulseSettings.fromJSON(json), .valid)
    }

    /// An unreadable file is backed up first (a failed backup fails the save) so a
    /// hand-editing mistake never silently loses the user's settings.
    private func write(_ settings: SidePulseSettings, replacing current: (settings: SidePulseSettings, state: FileState)) throws {
        if current.state == .unreadable {
            try FileUtil.backup(url)
        }
        try FileUtil.atomicWrite(settings.toJSON().serialized(pretty: true) + "\n", to: url)
    }

    static let lockTimeout: TimeInterval = 5

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try writers.withLock { _ in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw FileUtil.posixError("open \(lockURL.path)") }
            defer { close(fd) }
            // Bounded wait so a process stuck holding the lock (e.g. a suspended
            // `sidepulse write --manual`) cannot wedge the app forever.
            let deadline = Date().addingTimeInterval(Self.lockTimeout)
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EINTR else { throw FileUtil.posixError("lock \(lockURL.path)") }
                guard Date() < deadline else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT),
                                  userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(lockURL.path)"])
                }
                usleep(20_000)
            }
            return try body()
        }
    }
}
