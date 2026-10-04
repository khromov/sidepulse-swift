import XCTest
@testable import SidePulseCore

private func makeTempDirectory(_ testCase: XCTestCase) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sidepulse-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    testCase.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
}

private func settings(fromJSON text: String) throws -> SidePulseSettings {
    SidePulseSettings.fromJSON(try JSONValue.parse(text))
}

private func candidate(_ path: String) -> DeviceCandidate {
    let root = URL(fileURLWithPath: path)
    return DeviceCandidate(root: root, target: root.appendingPathComponent("LEDS.LED"), reason: "name matches device")
}

final class SettingsModelTests: XCTestCase {
    func testDefaults() {
        let settings = SidePulseSettings()
        XCTAssertEqual(settings.devices, [])
        XCTAssertEqual(settings.animations, [:])
        XCTAssertEqual(settings.idleTimeoutSeconds, 3600)
        XCTAssertEqual(settings.sessionRetentionSeconds, 172_800)
        XCTAssertEqual(settings.sleepPolicy, .agents)
        XCTAssertEqual(settings.minBatteryPercent, 20)
        XCTAssertTrue(settings.sdEjectGuard)
        XCTAssertFalse(settings.ledsOffOnAnySleep)
        XCTAssertEqual(settings.sleepAnimationID, "fade-off")
        XCTAssertEqual(settings.matchingProfile?.id, "profile:signal")
        XCTAssertEqual(LedDisplay.agent.label, "Agent Status")
        XCTAssertEqual(LedDisplay.manual.label, "Manual")
        XCTAssertEqual(SleepPolicy.allCases.map(\.label), ["Never", "When Agents Work", "Always"])
    }

    func testDefaultJSONLayout() {
        XCTAssertEqual(SidePulseSettings().toJSON().serialized(pretty: true), """
        {
          "agent_animations": {},
          "agent_list": {
            "idle_timeout_seconds": 3600,
            "recent_session_retention_seconds": 172800
          },
          "devices": [],
          "sd_eject_guard": {
            "enabled": true
          },
          "sleep_leds": {
            "animation": "fade-off",
            "off_on_any_sleep": false
          },
          "sleep_prevention": {
            "min_battery_percent": 20,
            "policy": "agents"
          }
        }
        """)
    }

    func testNonObjectRootsGiveDefaults() throws {
        for text in ["[]", "null", "3", "\"settings\""] {
            XCTAssertEqual(try settings(fromJSON: text), SidePulseSettings(), text)
        }
    }

    func testGarbageTypesFallBackFieldByField() throws {
        let loaded = try settings(fromJSON: """
        {"devices": "x", "default_display": 5, "agent_animations": [], "agent_list": "x",
         "sleep_prevention": {"policy": "sometimes", "min_battery_percent": "20"}, "sd_eject_guard": {"enabled": "no"},
         "sleep_leds": {"off_on_any_sleep": "yes", "animation": 3}}
        """)
        XCTAssertEqual(loaded, SidePulseSettings())

        let partial = try settings(fromJSON: #"{"agent_list": {"idle_timeout_seconds": 900}, "sleep_prevention": {"policy": "never"}}"#)
        XCTAssertEqual(partial.idleTimeoutSeconds, 900)
        XCTAssertEqual(partial.sessionRetentionSeconds, 172_800)
        XCTAssertEqual(partial.sleepPolicy, .never)
        XCTAssertEqual(partial.minBatteryPercent, 20)
    }

    func testNumbersAreClampedAndMustBeFinite() throws {
        let loaded = try settings(fromJSON: """
        {"agent_list": {"idle_timeout_seconds": -5, "recent_session_retention_seconds": 1e999},
         "sleep_prevention": {"min_battery_percent": 150}}
        """)
        XCTAssertEqual(loaded.idleTimeoutSeconds, 0)
        XCTAssertEqual(loaded.sessionRetentionSeconds, 172_800)
        XCTAssertEqual(loaded.minBatteryPercent, 100)
        XCTAssertEqual(try settings(fromJSON: #"{"sleep_prevention": {"min_battery_percent": -3}}"#).minBatteryPercent, 0)
        XCTAssertEqual(try settings(fromJSON: #"{"agent_list": {"idle_timeout_seconds": true}}"#).idleTimeoutSeconds, 3600)
    }

    func testDeviceDecodingRules() throws {
        let loaded = try settings(fromJSON: """
        {"devices": [
          "garbage", {"name": "no id"}, {"id": ""}, {"id": 7},
          {"id": "/Volumes/PulseDot", "name": "SidePulse Dot", "path": "/Volumes/PulseDot", "display": "agent", "brightness": 127.5},
          {"id": "/Volumes/PulseDot", "name": "Duplicate", "display": "manual"},
          {"id": "/Volumes/SidePulsePro", "display": "battery", "brightness": 300},
          {"id": "dev-3", "path": "/Volumes/Other Disk", "name": "", "brightness": "x"},
          {"id": "dev-4", "path": "/", "brightness": null},
          {"id": "dev-5", "brightness": true}
        ]}
        """)
        XCTAssertEqual(loaded.devices, [
            DeviceSettings(id: "/Volumes/PulseDot", name: "SidePulse Dot", path: "/Volumes/PulseDot", display: .agent, brightness: 128),
            DeviceSettings(id: "/Volumes/SidePulsePro", name: "SidePulsePro", path: "/Volumes/SidePulsePro", display: .agent, brightness: 255),
            DeviceSettings(id: "dev-3", name: "Other Disk", path: "/Volumes/Other Disk", display: .agent, brightness: 255),
            DeviceSettings(id: "dev-4", name: "/", path: "/", display: .agent, brightness: 255),
            DeviceSettings(id: "dev-5", name: "dev-5", path: "dev-5", display: .agent, brightness: 255),
        ])
    }

    func testDeviceNameFallsBackToTheLastPathComponent() throws {
        let loaded = try settings(fromJSON: #"{"devices": [{"id": "a"}, {"id": "b", "path": "/Volumes/PulseDot/"}]}"#)
        XCTAssertEqual(loaded.devices.map(\.name), ["a", "PulseDot"])
    }

    func testNonFiniteAndOutOfRangeNumbersAreSavedAsValidJSON() throws {
        var settings = SidePulseSettings()
        settings.idleTimeoutSeconds = .nan
        settings.sessionRetentionSeconds = -.infinity
        settings.minBatteryPercent = .infinity
        settings.devices = [DeviceSettings(id: "x", name: "x", path: "x", display: .agent, brightness: 900)]

        let text = settings.toJSON().serialized()

        let reloaded = SidePulseSettings.fromJSON(try JSONValue.parse(text))
        XCTAssertEqual(reloaded.idleTimeoutSeconds, 3600)
        XCTAssertEqual(reloaded.sessionRetentionSeconds, 172_800)
        XCTAssertEqual(reloaded.minBatteryPercent, 20)
        XCTAssertEqual(reloaded.devices.first?.brightness, 255)
        XCTAssertFalse(text.contains("nan") || text.contains("inf"), text)

        settings.idleTimeoutSeconds = -5
        settings.sessionRetentionSeconds = 90.5
        settings.minBatteryPercent = 140
        let clamped = SidePulseSettings.fromJSON(settings.toJSON())
        XCTAssertEqual(clamped.idleTimeoutSeconds, 0)
        XCTAssertEqual(clamped.sessionRetentionSeconds, 90.5)
        XCTAssertEqual(clamped.minBatteryPercent, 100)
        XCTAssertEqual(SidePulseSettings.fromJSON(clamped.toJSON()), clamped, "normalized values round-trip")
    }

    func testAnimationDecodingRules() throws {
        let working = try settings(fromJSON: #"{"agent_animations": {"tool_running": "kitt"}}"#)
        XCTAssertEqual(working.animations, ["working": "kitt", "tool_running": "kitt", "long_task_progress": "kitt"])

        // Python parity: the first working-group key wins even when its unknown id
        // has already become the default.
        let unknownFirst = try settings(fromJSON: #"{"agent_animations": {"working": "bogus", "tool_running": "kitt"}}"#)
        XCTAssertEqual(unknownFirst.animationID(for: .toolRunning), "ember-tide")

        let mixed = try settings(fromJSON: """
        {"agent_animations": {"completed": "solid-green", "lid_open": "lid-open", "idle_ready": 5,
                              "blocked_error": "default", "waiting_for_input": "lid-open"}}
        """)
        XCTAssertEqual(mixed.animations, ["completed": "solid-green", "blocked_error": "red-double-blink",
                                          "waiting_for_input": "solid-red"])
        XCTAssertEqual(mixed.animationID(for: .completed), "solid-green")
        XCTAssertEqual(mixed.animationID(for: .idleReady), "solid-blue")
    }

    func testSDEjectGuardCanBeTurnedOff() throws {
        let off = try settings(fromJSON: #"{"sd_eject_guard": {"enabled": false}}"#)
        XCTAssertFalse(off.sdEjectGuard)
        XCTAssertEqual(off.toJSON()["sd_eject_guard"]?.serialized(), #"{"enabled":false}"#)
        XCTAssertEqual(SidePulseSettings.fromJSON(off.toJSON()), off)
    }

    func testLedsOffOnAnySleepCanBeTurnedOn() throws {
        let on = try settings(fromJSON: #"{"sleep_leds": {"off_on_any_sleep": true}}"#)
        XCTAssertTrue(on.ledsOffOnAnySleep)
        XCTAssertEqual(on.toJSON()["sleep_leds"]?.serialized(), #"{"animation":"fade-off","off_on_any_sleep":true}"#)
        XCTAssertEqual(SidePulseSettings.fromJSON(on.toJSON()), on)
    }

    func testSleepAnimationMustEndDark() throws {
        let sweep = try settings(fromJSON: #"{"sleep_leds": {"animation": "lid-closed"}}"#)
        XCTAssertEqual(sweep.sleepAnimationID, "lid-closed")
        XCTAssertEqual(SidePulseSettings.fromJSON(sweep.toJSON()), sweep)
        for id in ["kitt", "nope", ""] {
            let loaded = try settings(fromJSON: #"{"sleep_leds": {"animation": "\#(id)"}}"#)
            XCTAssertEqual(loaded.sleepAnimationID, "fade-off", id)
        }
    }

    func testUnknownKeysAreDroppedOnSave() throws {
        let loaded = try settings(fromJSON: #"{"future": {"a": 1}, "default_display": "manual", "leds_enabled": false}"#)
        XCTAssertEqual(loaded, SidePulseSettings())
        XCTAssertEqual(loaded.toJSON().objectValue?.keys,
                       ["agent_animations", "agent_list", "devices", "sd_eject_guard", "sleep_leds", "sleep_prevention"])
    }

    func testJSONRoundTrip() {
        var original = SidePulseSettings()
        original.setAnimation("kitt", for: .working)
        original.setAnimation("solid-green", for: .completed)
        original.setDisplay(.agent, forDevice: "/Volumes/PulseDot", name: "SidePulse Dot", path: "/Volumes/PulseDot")
        original.setBrightness(25, forDevice: "/Volumes/PulseDot")
        original.setBrightness(128, forDevice: "/Volumes/SidePulsePro", name: "SidePulse Pro", path: "/Volumes/SidePulsePro")
        original.idleTimeoutSeconds = 900
        original.sessionRetentionSeconds = 1.5
        original.sleepPolicy = .always
        original.minBatteryPercent = 25

        let json = original.toJSON()

        XCTAssertEqual(SidePulseSettings.fromJSON(json), original)
        XCTAssertEqual(json["agent_list"]?.serialized(), #"{"idle_timeout_seconds":900,"recent_session_retention_seconds":1.5}"#)
        XCTAssertEqual(json["devices"]?.serialized(),
                       #"[{"brightness":25,"display":"agent","id":"/Volumes/PulseDot","name":"SidePulse Dot","path":"/Volumes/PulseDot"},"#
                       + #"{"brightness":128,"display":"agent","id":"/Volumes/SidePulsePro","name":"SidePulse Pro","path":"/Volumes/SidePulsePro"}]"#)
        XCTAssertEqual(json["agent_animations"]?.serialized(),
                       #"{"completed":"solid-green","long_task_progress":"kitt","tool_running":"kitt","working":"kitt"}"#)
    }

    func testWorkingGroupSharesOneSelection() {
        var settings = SidePulseSettings()
        settings.setAnimation("kitt", for: .toolRunning)
        XCTAssertEqual(Set(AgentMode.workingGroup.map { settings.animationID(for: $0) }), ["kitt"])
        XCTAssertEqual(settings.animations.count, 3)

        settings.setAnimation("ember-complete", for: .completed)
        XCTAssertEqual(settings.animationID(for: .completed), "ember-complete")
        XCTAssertEqual(settings.animationID(for: .working), "kitt")
        XCTAssertEqual(settings.animationID(for: .blockedError), "red-double-blink")

        settings.setAnimation("nope", for: .completed)
        settings.setAnimation("lid-open", for: .working)
        XCTAssertEqual(settings.animationID(for: .completed), "ember-complete")
        XCTAssertEqual(settings.animationID(for: .working), "kitt")
    }

    func testAnimationResolutionFallsBackToDefaults() {
        var settings = SidePulseSettings()
        XCTAssertEqual(settings.animationSelection.count, AgentMode.allCases.count)
        for mode in AgentMode.allCases {
            XCTAssertEqual(settings.animationID(for: mode), AnimationLibrary.defaultAnimationID(for: mode))
        }
        settings.animations = ["completed": "gone", "long_task_progress": "night-rider"]
        XCTAssertEqual(settings.animationID(for: .completed), "solid-green")
        XCTAssertEqual(settings.animationID(for: .working), "night-rider", "any stored working-group entry is shared")
    }

    func testApplyAndMatchProfiles() throws {
        var settings = SidePulseSettings()
        let purple = try XCTUnwrap(AnimationProfiles.profile(id: "profile:purple"))

        settings.apply(profile: purple)

        XCTAssertEqual(settings.matchingProfile?.id, "profile:purple")
        XCTAssertEqual(settings.animationID(for: .working), "purple-tide")
        XCTAssertEqual(settings.animations.count, AgentMode.allCases.count, "every mode is stored after a profile")

        settings.setAnimation("solid-green", for: .completed)
        XCTAssertNil(settings.matchingProfile, "a manual change leaves the profile (UI shows Current)")

        settings.apply(profile: try XCTUnwrap(AnimationProfiles.profile(id: "profile:cyan")))
        XCTAssertEqual(settings.matchingProfile?.id, "profile:cyan")
        XCTAssertEqual(settings.animationSelection, try XCTUnwrap(AnimationProfiles.profile(id: "profile:cyan")).animations)
    }

    func testApplyingAnInconsistentProfileNormalizesIt() {
        var settings = SidePulseSettings()
        settings.apply(profile: AnimationProfile(id: "profile:odd", name: "Odd", animations: [
            .working: "kitt", .toolRunning: "night-rider", .completed: "nope",
        ]))
        XCTAssertEqual(AgentMode.workingGroup.map { settings.animationID(for: $0) }, ["kitt", "kitt", "kitt"])
        XCTAssertEqual(settings.animationID(for: .completed), "solid-green")
        XCTAssertEqual(settings.animations["unknown"], "blue-double-blink")
    }

    func testDeviceLookupsFallBack() {
        var settings = SidePulseSettings()
        XCTAssertEqual(settings.display(forDevice: "/Volumes/PulseDot"), .agent)
        XCTAssertEqual(settings.brightness(forDevice: "/Volumes/PulseDot"), 255)
        settings.devices = [DeviceSettings(id: "x", name: "x", path: "x", display: .agent, brightness: 400)]
        XCTAssertEqual(settings.brightness(forDevice: "x"), 255)
        XCTAssertEqual(settings.display(forDevice: "x"), .agent)
    }

    func testSetDisplayAndBrightness() {
        var settings = SidePulseSettings()
        settings.setDisplay(.manual, forDevice: "/Volumes/PulseDot")
        XCTAssertEqual(settings.devices, [
            DeviceSettings(id: "/Volumes/PulseDot", name: "/Volumes/PulseDot", path: "/Volumes/PulseDot", display: .manual, brightness: 255),
        ])

        settings.setBrightness(96, forDevice: "/Volumes/PulseDot", name: "SidePulse Dot", path: "")
        settings.setDisplay(.agent, forDevice: "/Volumes/PulseDot", name: nil)
        XCTAssertEqual(settings.device(id: "/Volumes/PulseDot"),
                       DeviceSettings(id: "/Volumes/PulseDot", name: "SidePulse Dot", path: "/Volumes/PulseDot", display: .agent, brightness: 96))

        settings.setBrightness(300, forDevice: "/Volumes/SidePulsePro", name: "SidePulse Pro", path: "/Volumes/SidePulsePro")
        XCTAssertEqual(settings.device(id: "/Volumes/SidePulsePro")?.display, .agent)
        XCTAssertEqual(settings.brightness(forDevice: "/Volumes/SidePulsePro"), 255)
        settings.setBrightness(-1, forDevice: "/Volumes/SidePulsePro")
        XCTAssertEqual(settings.brightness(forDevice: "/Volumes/SidePulsePro"), 0)
        XCTAssertEqual(settings.devices.map(\.id), ["/Volumes/PulseDot", "/Volumes/SidePulsePro"])
    }

    func testRememberAddsANewDeviceOnce() {
        var settings = SidePulseSettings()
        XCTAssertTrue(settings.remember(candidate("/Volumes/PulseDot")))
        XCTAssertEqual(settings.devices, [
            DeviceSettings(id: "/Volumes/PulseDot", name: "SidePulse Dot", path: "/Volumes/PulseDot", display: .agent, brightness: 255),
        ])
        XCTAssertFalse(settings.remember(candidate("/Volumes/PulseDot")), "nothing changed")
    }

    func testRememberPreservesExistingChoices() {
        var settings = SidePulseSettings()
        settings.setDisplay(.manual, forDevice: "/Volumes/PulseDot", name: "Old Name", path: "/Volumes/PulseDot")
        settings.setBrightness(25, forDevice: "/Volumes/PulseDot")

        XCTAssertTrue(settings.remember(candidate("/Volumes/PulseDot")), "the name is refreshed")

        XCTAssertEqual(settings.device(id: "/Volumes/PulseDot"),
                       DeviceSettings(id: "/Volumes/PulseDot", name: "SidePulse Dot", path: "/Volumes/PulseDot", display: .manual, brightness: 25))
    }

    func testRemoveDevice() {
        var settings = SidePulseSettings()
        settings.setDisplay(.agent, forDevice: "/Volumes/SidePulsePro")
        settings.setDisplay(.manual, forDevice: "/Volumes/SidePulseDot")

        settings.removeDevice(id: "/Volumes/SidePulseDot")

        XCTAssertEqual(settings.devices.map(\.id), ["/Volumes/SidePulsePro"])
        XCTAssertEqual(settings.display(forDevice: "/Volumes/SidePulseDot"), .agent)
    }

    func testMonitorConfig() {
        var settings = SidePulseSettings()
        settings.idleTimeoutSeconds = 900
        settings.sessionRetentionSeconds = 36 * 3600

        let config = settings.monitorConfig

        XCTAssertEqual(config.staleAfter, 900)
        XCTAssertEqual(config.retention, 36 * 3600)
    }
}

final class SettingsStoreTests: XCTestCase {
    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func testMissingAndCorruptFilesLoadDefaults() throws {
        let dir = try makeTempDirectory(self)
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))
        XCTAssertEqual(store.load(), SidePulseSettings())

        for corrupt in ["{", "", "[1,2]", "{\"devices\": [}"] {
            try Data(corrupt.utf8).write(to: store.url)
            XCTAssertEqual(store.load(), SidePulseSettings(), corrupt)
        }
    }

    func testSaveWritesPrettySortedJSONAndCreatesDirectories() throws {
        let home = try makeTempDirectory(self)
        let root = try makeTempDirectory(self).appendingPathComponent("nested/SidePulse")
        let paths = SidePulsePaths(environment: ["SIDEPULSE_HOME": root.path, "HOME": home.path], home: home)
        let store = SettingsStore(url: paths.settingsFile)
        var settings = SidePulseSettings()
        settings.setAnimation("ember-tide", for: .working)

        try store.save(settings)

        let text = try String(contentsOf: paths.settingsFile, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("{\n  \"agent_animations\": {\n    \"long_task_progress\": \"ember-tide\","), text)
        XCTAssertTrue(text.hasSuffix("    \"policy\": \"agents\"\n  }\n}\n"), text)
        XCTAssertEqual(store.load(), settings)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.settingsFile.path + ".lock"))
        XCTAssertEqual(store.lockURL.path, paths.settingsFile.path + ".lock")
    }

    func testUnknownKeysAreDroppedByUpdates() throws {
        let dir = try makeTempDirectory(self)
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))
        try Data(#"{"show_menu_bar_icon": false, "future": [1, 2], "leds_enabled": true}"#.utf8).write(to: store.url)

        try store.update { $0.sleepPolicy = .never }

        let saved = try JSONValue.parse(try Data(contentsOf: store.url))
        XCTAssertNil(saved["show_menu_bar_icon"])
        XCTAssertNil(saved["future"])
        XCTAssertNil(saved["leds_enabled"])
        XCTAssertEqual(saved["sleep_prevention"]?["policy"], .string("never"))
    }

    func testUpdateReturnsSavedValueAndSkipsNoOpWrites() throws {
        let dir = try makeTempDirectory(self)
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))

        let created = try store.update { _ in }
        XCTAssertEqual(created, SidePulseSettings())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path), "a no-op update still creates the file")

        let old = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded(.down))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: store.url.path)
        try store.update { $0.setAnimation("nope", for: .completed) }
        XCTAssertEqual(modificationDate(store.url), old, "unchanged settings are not rewritten")

        let updated = try store.update { $0.sleepPolicy = .never }
        XCTAssertEqual(updated.sleepPolicy, .never)
        XCTAssertEqual(store.load().sleepPolicy, .never)
        XCTAssertNotEqual(modificationDate(store.url), old)
    }

    func testProfilesAndDevicesRoundTripThroughTheStore() throws {
        let dir = try makeTempDirectory(self)
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))
        let ember = try XCTUnwrap(AnimationProfiles.profile(id: "profile:ember"))

        try store.update {
            $0.apply(profile: ember)
            $0.remember(candidate("/Volumes/PulseDot"))
            $0.setBrightness(25, forDevice: "/Volumes/PulseDot")
        }

        let loaded = store.load()
        XCTAssertEqual(loaded.matchingProfile?.id, "profile:ember")
        XCTAssertEqual(loaded.brightness(forDevice: "/Volumes/PulseDot"), 25)
        XCTAssertEqual(loaded.device(id: "/Volumes/PulseDot")?.name, "SidePulse Dot")
    }

    func testConcurrentUpdatesNeverLoseWrites() throws {
        let dir = try makeTempDirectory(self)
        let url = dir.appendingPathComponent("settings.json")
        // Two stores, so the flock rather than the per-instance mutex must serialize them.
        let stores = [SettingsStore(url: url), SettingsStore(url: url)]
        let workers = 8
        let perWorker = 20
        final class Failures: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [String] = []
            func append(_ error: Error) { lock.lock(); items.append("\(error)"); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
        }
        let failures = Failures()

        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            for step in 0..<perWorker {
                do {
                    try stores[worker % 2].update { settings in
                        settings.idleTimeoutSeconds += 1
                        settings.setBrightness(step, forDevice: "dev-\(worker)-\(step)")
                    }
                } catch {
                    failures.append(error)
                }
            }
        }

        XCTAssertEqual(failures.all, [])
        let final = stores[0].load()
        XCTAssertEqual(final.devices.count, workers * perWorker)
        XCTAssertEqual(Set(final.devices.map(\.id)).count, workers * perWorker)
        XCTAssertEqual(final.idleTimeoutSeconds, 3600 + Double(workers * perWorker))
    }

    func testNonFiniteValuesNeverCorruptTheFile() throws {
        let dir = try makeTempDirectory(self)
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))
        try store.update { $0.setBrightness(25, forDevice: "/Volumes/PulseDot") }

        try store.update { $0.idleTimeoutSeconds = .infinity }

        let loaded = store.load()
        XCTAssertEqual(loaded.brightness(forDevice: "/Volumes/PulseDot"), 25, "the rest of the file survives")
        XCTAssertEqual(loaded.idleTimeoutSeconds, 3600)
    }

    private func backups(in dir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("settings.json.bak.") }
    }

    func testCorruptFileIsBackedUpBeforeItIsReplaced() throws {
        let dir = try makeTempDirectory(self)
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))
        let corrupt = #"{"devices": [{"id": "/Volumes/PulseDot", "brightness": 25},]}"#
        try Data(corrupt.utf8).write(to: store.url)

        try store.update { _ in }
        XCTAssertEqual(try backups(in: dir), [], "a no-op update leaves the corrupt file alone")
        XCTAssertEqual(try String(contentsOf: store.url, encoding: .utf8), corrupt)

        try store.update { $0.sleepPolicy = .never }

        let saved = try backups(in: dir)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(try String(contentsOf: saved[0], encoding: .utf8), corrupt)
        XCTAssertEqual(store.load().sleepPolicy, .never)

        try store.update { $0.sleepPolicy = .always }
        try store.save(SidePulseSettings())
        XCTAssertEqual(try backups(in: dir).count, 1, "valid files are replaced without a backup")

        try Data("[]".utf8).write(to: store.url)
        try store.save(SidePulseSettings())
        XCTAssertEqual(try backups(in: dir).count, 2, "a non-object root counts as corrupt")
    }

    func testUnreadableFileIsNotReplaced() throws {
        let dir = try makeTempDirectory(self)
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))
        try Data(#"{"sleep_prevention": {"policy": "always"}}"#.utf8).write(to: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.url.path) }
        guard (try? Data(contentsOf: store.url)) == nil else { throw XCTSkip("running with permission to read anything") }

        XCTAssertThrowsError(try store.update { $0.sleepPolicy = .never })

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.url.path)
        XCTAssertEqual(store.load().sleepPolicy, .always, "the original content is still there")
    }

    func testUpdateWaitsForALockHeldByAnotherProcess() throws {
        let dir = try makeTempDirectory(self)
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))
        // Another descriptor on the lock file behaves like another process.
        let fd = open(store.lockURL.path, O_RDWR | O_CREAT, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        let done = expectation(description: "update finished")
        DispatchQueue.global().async {
            _ = try? store.update { $0.sleepPolicy = .always }
            done.fulfill()
        }

        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path), "update must wait for the lock")
        flock(fd, LOCK_UN)
        close(fd)

        wait(for: [done], timeout: 5)
        XCTAssertEqual(store.load().sleepPolicy, .always)
    }

    func testUpdateFailsWhenTheDirectoryCannotBeCreated() throws {
        let dir = try makeTempDirectory(self)
        let blocker = dir.appendingPathComponent("file")
        try Data("x".utf8).write(to: blocker)
        let store = SettingsStore(url: blocker.appendingPathComponent("settings.json"))

        XCTAssertThrowsError(try store.update { $0.sleepPolicy = .never })
        XCTAssertThrowsError(try store.save(SidePulseSettings()))
        XCTAssertEqual(store.load(), SidePulseSettings())
    }
}
