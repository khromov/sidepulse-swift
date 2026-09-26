import Foundation

/// Per-device display mode. "manual" = SidePulse never writes to the device.
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
    /// Volume root path, e.g. "/Volumes/PulseDot".
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

/// User settings. JSON schema (`settings.json`, pretty, sorted keys):
/// ```json
/// {
///   "agent_animations": {"working": "cyan-roll", ...},   // explicit selections only
///   "agent_list": {"idle_timeout_seconds": 3600, "recent_session_retention_seconds": 172800},
///   "default_display": "agent",                          // for never-seen devices
///   "devices": [{"id","name","path","display":"agent|manual","brightness":0-255}],
///   "leds_enabled": true,
///   "sleep_prevention": {"policy": "never|agents|always", "min_battery_percent": 20}
/// }
/// ```
/// Loading is tolerant: missing/invalid values fall back to defaults field by field;
/// unknown top-level keys are preserved on save (`extra`).
public struct SidePulseSettings: Sendable, Equatable {
    public var devices: [DeviceSettings] = []
    public var defaultDisplay: LedDisplay = .agent
    /// AgentMode raw value → animation id. Only explicit selections are stored.
    public var animations: [String: String] = [:]
    public var idleTimeoutSeconds: Double = 3600
    public var sessionRetentionSeconds: Double = 172_800
    public var sleepPolicy: SleepPolicy = .agents
    public var minBatteryPercent: Double = 20
    /// Global LED output switch ("Drive LEDs" in the menu).
    public var ledsEnabled: Bool = true
    /// Unknown top-level keys, preserved verbatim. Kept key-sorted (recursively),
    /// the order they are saved in, so equality does not depend on insertion order.
    public var extra: JSONObject = JSONObject() {
        didSet { extra = Self.canonical(extra) }
    }

    public init() {}

    /// Top-level keys owned by this model; everything else goes to `extra`.
    static let knownKeys: Set<String> = [
        "agent_animations", "agent_list", "default_display", "devices", "leds_enabled", "sleep_prevention",
    ]

    // MARK: JSON

    /// Field-by-field tolerant decode (Python `load_settings` rules):
    /// - a non-object root gives the defaults;
    /// - `devices`: entries that are not objects or lack a non-empty string `id` are
    ///   skipped; the first entry per id wins; a missing `path` becomes the id, a
    ///   missing `name` the path's last component (Python `Path(path).name`, so
    ///   `.` components are ignored) or else the id; an invalid `display`
    ///   becomes `default_display`; `brightness` is rounded half-even and clamped,
    ///   255 when missing or not a number;
    /// - `agent_animations`: keys must be agent modes and values strings; unknown
    ///   animation ids become that mode's default; the first working-group entry
    ///   present (working, tool_running, long_task_progress) is shared by all three;
    /// - timeouts: numbers are clamped to ≥ 0; the battery threshold to 0...100;
    ///   non-numbers and non-finite values keep the defaults;
    /// - `extra` keeps every other top-level key.
    public static func fromJSON(_ value: JSONValue) -> SidePulseSettings {
        var settings = SidePulseSettings()
        guard let root = value.objectValue else { return settings }

        if let display = root["default_display"]?.stringValue.flatMap(LedDisplay.init(rawValue:)) {
            settings.defaultDisplay = display
        }
        settings.devices = decodeDevices(root["devices"], defaultDisplay: settings.defaultDisplay)
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

        if let enabled = root["leds_enabled"]?.boolValue {
            settings.ledsEnabled = enabled
        }

        var extra = JSONObject()
        for (key, value) in root where !knownKeys.contains(key) {
            extra[key] = value
        }
        settings.extra = extra
        return settings
    }

    /// The schema above plus `extra`, keys sorted recursively. Integral numbers are
    /// written without a fraction.
    ///
    /// Numbers are written the way `fromJSON` would read them back (timeouts ≥ 0,
    /// battery threshold 0...100, brightness 0...255), and a NaN or infinite value
    /// is written as its default: JSON has no literal for those, and one invalid
    /// number would make the whole file unreadable (every setting lost).
    public func toJSON() -> JSONValue {
        let defaults = SidePulseSettings()
        func seconds(_ value: Double, _ fallback: Double) -> JSONValue {
            JSONValue(value.isFinite ? max(0, value) : fallback, integralAsInt: true)
        }
        var root = extra
        root["agent_animations"] = .object(JSONObject(animations.map { ($0.key, JSONValue.string($0.value)) }))
        root["agent_list"] = .object([
            "idle_timeout_seconds": seconds(idleTimeoutSeconds, defaults.idleTimeoutSeconds),
            "recent_session_retention_seconds": seconds(sessionRetentionSeconds, defaults.sessionRetentionSeconds),
        ])
        root["default_display"] = .string(defaultDisplay.rawValue)
        root["devices"] = .array(devices.map { device in
            .object([
                "brightness": JSONValue(LedProgram.clampBrightness(device.brightness)),
                "display": .string(device.display.rawValue),
                "id": .string(device.id),
                "name": .string(device.name),
                "path": .string(device.path),
            ])
        })
        root["leds_enabled"] = .bool(ledsEnabled)
        let percent = minBatteryPercent.isFinite ? min(100, max(0, minBatteryPercent)) : defaults.minBatteryPercent
        root["sleep_prevention"] = .object([
            "min_battery_percent": JSONValue(percent, integralAsInt: true),
            "policy": .string(sleepPolicy.rawValue),
        ])
        return JSONValue.object(root).sortedKeys()
    }

    private static func canonical(_ object: JSONObject) -> JSONObject {
        JSONValue.object(object).sortedKeys().objectValue ?? object
    }

    private static func finiteNumber(_ value: JSONValue?) -> Double? {
        guard let number = value?.doubleValue, number.isFinite else { return nil }
        return number
    }

    private static func nonEmptyString(_ value: JSONValue?) -> String? {
        guard let string = value?.stringValue, !string.isEmpty else { return nil }
        return string
    }

    private static func decodeDevices(_ value: JSONValue?, defaultDisplay: LedDisplay) -> [DeviceSettings] {
        guard let items = value?.arrayValue else { return [] }
        var devices: [DeviceSettings] = []
        var seen = Set<String>()
        for item in items {
            guard let entry = item.objectValue, let id = nonEmptyString(entry["id"]),
                  seen.insert(id).inserted else { continue }
            let path = nonEmptyString(entry["path"]) ?? id
            let name = nonEmptyString(entry["name"]) ?? pythonPathName(path) ?? id
            let display = entry["display"]?.stringValue.flatMap(LedDisplay.init(rawValue:)) ?? defaultDisplay
            let brightness = LedProgram.normalizeBrightness(entry["brightness"]?.doubleValue)
            devices.append(DeviceSettings(id: id, name: name, path: path, display: display, brightness: brightness))
        }
        return devices
    }

    /// Python `Path(path).name`, nil when empty: the last component once empty and
    /// `.` components are dropped ("/" and "." have no name; "a/." is "a").
    private static func pythonPathName(_ path: String) -> String? {
        path.split(separator: "/").last { $0 != "." }.map(String.init)
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

    /// Resolved animation id for `mode`: explicit selection if it is a known built-in,
    /// else `AnimationLibrary.defaultAnimationID(for:)`. The working group shares
    /// the `working` selection.
    ///
    /// For a working-group mode the first stored entry among working, tool_running
    /// and long_task_progress is used (normally they are identical).
    public func animationID(for mode: AgentMode) -> String {
        let keys = AgentMode.workingGroup.contains(mode) ? AgentMode.workingGroup : [mode]
        if let stored = keys.lazy.compactMap({ animations[$0.rawValue] }).first,
           AnimationLibrary.animation(id: stored) != nil {
            return stored
        }
        return AnimationLibrary.defaultAnimationID(for: mode)
    }

    /// Sets the selection (all three working-group modes when `mode` is in the group).
    /// Unknown ids are ignored.
    public mutating func setAnimation(_ id: String, for mode: AgentMode) {
        guard AnimationLibrary.animation(id: id) != nil else { return }
        let modes = AgentMode.workingGroup.contains(mode) ? AgentMode.workingGroup : [mode]
        for target in modes { animations[target.rawValue] = id }
    }

    /// Full resolved selection for every mode.
    public var animationSelection: [AgentMode: String] {
        Dictionary(uniqueKeysWithValues: AgentMode.allCases.map { ($0, animationID(for: $0)) })
    }

    /// Replaces every selection with the profile's (Python
    /// `with_applied_agent_animation_profile`): unknown ids fall back to the mode's
    /// default and the working group takes the profile's `working` value. All modes
    /// are stored explicitly afterwards.
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

    /// Built-in profile matching the current selection, nil = "Current".
    public var matchingProfile: AnimationProfile? { AnimationProfiles.matching(animationSelection) }

    // MARK: Devices

    public func device(id: String) -> DeviceSettings? { devices.first { $0.id == id } }

    /// Entry's display, else `defaultDisplay`.
    public func display(forDevice id: String) -> LedDisplay {
        device(id: id)?.display ?? defaultDisplay
    }

    /// Entry's brightness, else 255.
    public func brightness(forDevice id: String) -> Int {
        device(id: id).map { LedProgram.clampBrightness($0.brightness) } ?? 255
    }

    /// Updates the entry's display (and name/path when non-empty values are given),
    /// or appends a new entry (name/path default to the id, brightness 255).
    public mutating func setDisplay(_ display: LedDisplay, forDevice id: String, name: String? = nil, path: String? = nil) {
        upsertDevice(id: id, name: name, path: path) { $0.display = display }
    }

    /// Updates the entry's brightness (clamped to 0...255; name/path when non-empty),
    /// or appends a new entry whose display is `display(forDevice:)`.
    public mutating func setBrightness(_ brightness: Int, forDevice id: String, name: String? = nil, path: String? = nil) {
        let value = LedProgram.clampBrightness(brightness)
        upsertDevice(id: id, name: name, path: path) { $0.brightness = value }
    }

    /// Upserts name/path for a connected device (first sighting copies
    /// `defaultDisplay`, brightness 255). Returns true if anything changed.
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

    /// `MonitorConfig` derived from these settings (staleAfter = idle timeout,
    /// retention = session retention).
    public var monitorConfig: MonitorConfig {
        MonitorConfig(staleAfter: idleTimeoutSeconds, retention: sessionRetentionSeconds)
    }
}

/// Loads/saves settings.json. `update` does reload → mutate → atomic save under an
/// advisory lock (`flock` on `<settings>.lock`) so the CLI and app never clobber
/// each other. Thread-safe.
///
/// A settings file that exists but cannot be read or parsed is copied to
/// `settings.json.bak.<stamp>` before it is replaced, so a hand-editing mistake
/// never silently throws away the user's devices and choices.
public final class SettingsStore: @unchecked Sendable {
    public let url: URL
    /// Serializes this instance's writers; `flock` covers other instances and processes.
    private let mutex = NSLock()

    public init(url: URL) {
        self.url = url
    }

    /// `<settings>.lock` next to the settings file.
    public var lockURL: URL { URL(fileURLWithPath: url.path + ".lock") }

    /// Missing/corrupt → defaults (never throws).
    ///
    /// Reads take no lock: saves replace the file atomically, so a reader sees
    /// either the old or the new content.
    public func load() -> SidePulseSettings {
        read().settings
    }

    /// Writes `settings` atomically (pretty JSON, sorted keys, trailing newline)
    /// under the lock, creating the directory if needed.
    public func save(_ settings: SidePulseSettings) throws {
        try withLock {
            try write(settings, replacing: read())
        }
    }

    /// Reloads under the lock, applies `body` and saves. Returns the saved value.
    /// The write is skipped when `body` changed nothing and the file exists, so a
    /// no-op update does not bump the modification date.
    ///
    /// `body` runs while the lock is held: it must not call back into this store.
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

    /// File modification date (nil if missing) — used to detect external edits.
    public var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// What is on disk now.
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

    /// Saves `settings`, first backing up an existing file that could not be used
    /// (a failed backup fails the save rather than losing the file).
    private func write(_ settings: SidePulseSettings, replacing current: (settings: SidePulseSettings, state: FileState)) throws {
        if current.state == .unreadable {
            try FileUtil.backup(url)
        }
        try FileUtil.atomicWrite(settings.toJSON().serialized(pretty: true) + "\n", to: url)
    }

    /// How long `update`/`save` wait for another process's lock before failing.
    static let lockTimeout: TimeInterval = 5

    /// Runs `body` holding the in-process mutex and an exclusive `flock` on
    /// `lockURL` (released when the descriptor closes, even if `body` throws).
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        mutex.lock()
        defer { mutex.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw FileUtil.posixError("open \(lockURL.path)") }
        defer { close(fd) }
        // Bounded wait: a process stuck while holding the lock (e.g. a suspended
        // `sidepulse write --manual`) must not wedge the app forever.
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
