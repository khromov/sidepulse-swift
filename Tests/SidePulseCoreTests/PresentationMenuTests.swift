import XCTest
@testable import SidePulseCore

/// Menu-bar icon, header, menu model, settings choices and hook/device labels.
final class PresentationMenuTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(mode: AgentMode, active: Int, statuses: [AgentStatus] = []) -> MonitorSnapshot {
        MonitorSnapshot(collectedAt: now, sources: [],
                        aggregate: AggregateStatus(mode: mode, activeCount: active, staleCount: 0,
                                                   representative: statuses.first),
                        statuses: statuses, staleStatuses: [])
    }

    private func device(_ id: String, name: String, connected: Bool = true, display: LedDisplay = .agent,
                        brightness: Int = 255, error: String? = nil) -> DeviceInfo {
        let root = URL(fileURLWithPath: id)
        return DeviceInfo(id: id, name: name, root: root, target: root.appendingPathComponent("LEDS.LED"),
                          connected: connected, display: display, brightness: brightness, ledCount: 2,
                          lastError: error)
    }

    // MARK: Icon

    func testTooltipIsPinned() {
        XCTAssertEqual(StatusBarPresentation.tooltip(for: .idle), "SidePulse Agent Monitor: Idle")
        XCTAssertEqual(StatusBarPresentation.tooltip(for: .working), "SidePulse Agent Monitor: Working")
        XCTAssertEqual(StatusBarPresentation.tooltip(for: .done), "SidePulse Agent Monitor: Done")
        XCTAssertEqual(StatusBarPresentation.tooltip(for: .ask), "SidePulse Agent Monitor: Ask")
    }

    func testModeToIconState() {
        let expected: [AgentMode: DisplayState] = [
            .waitingForInput: .ask, .blockedError: .ask, .working: .working, .toolRunning: .working,
            .longTaskProgress: .working, .completed: .done, .idleReady: .idle, .unknown: .idle,
        ]
        for (mode, state) in expected { XCTAssertEqual(mode.displayState, state, mode.rawValue) }
    }

    func testHeader() {
        XCTAssertEqual(StatusBarPresentation.header(mode: .working, activeCount: 2), "SidePulse \u{2014} Working (2 active)")
        XCTAssertEqual(StatusBarPresentation.header(mode: .toolRunning, activeCount: 1), "SidePulse \u{2014} Working (1 active)")
        XCTAssertEqual(StatusBarPresentation.header(mode: .waitingForInput, activeCount: 1), "SidePulse \u{2014} Ask (1 active)")
        XCTAssertEqual(StatusBarPresentation.header(mode: .completed, activeCount: 0), "SidePulse \u{2014} Done")
        XCTAssertEqual(StatusBarPresentation.header(for: .empty(now: now)), "SidePulse \u{2014} Idle")
    }

    func testShouldAnimate() {
        XCTAssertTrue(StatusBarPresentation.shouldAnimate(iconState: .working, reduceMotion: false))
        XCTAssertTrue(StatusBarPresentation.shouldAnimate(iconState: .ask, reduceMotion: false))
        XCTAssertFalse(StatusBarPresentation.shouldAnimate(iconState: .working, reduceMotion: true))
        XCTAssertFalse(StatusBarPresentation.shouldAnimate(iconState: .idle, reduceMotion: false))
        XCTAssertFalse(StatusBarPresentation.shouldAnimate(iconState: .done, openMenuRowStates: [.done, .idle],
                                                           reduceMotion: false))
        XCTAssertTrue(StatusBarPresentation.shouldAnimate(iconState: .done, openMenuRowStates: [.done, .ask],
                                                          reduceMotion: false))
        XCTAssertFalse(StatusBarPresentation.shouldAnimate(iconState: .working, iconVisible: false, reduceMotion: false))
        XCTAssertFalse(StatusBarPresentation.shouldAnimate(iconState: .idle, openMenuRowStates: [.working],
                                                           reduceMotion: true))
    }

    /// Regression: the icon kept redrawing while the displays slept or another user
    /// session was in front.
    func testAnimationPausesWhenNobodyCanSeeIt() {
        XCTAssertFalse(StatusBarPresentation.shouldAnimate(iconState: .working, reduceMotion: false, paused: true))
        XCTAssertFalse(StatusBarPresentation.shouldAnimate(iconState: .done, openMenuRowStates: [.ask],
                                                           reduceMotion: false, paused: true))
    }

    /// Regression: 30 fps redraws of the status item cost 6-7 % CPU (4 displays)
    /// while an agent worked; the stepped animation keeps the 1.5 s cycle.
    func testIconAnimationIsSteppedAndSlow() {
        XCTAssertLessThanOrEqual(IconAnimation.framesPerSecond, 8)
        XCTAssertEqual(IconAnimation.frameCount, 12)
        XCTAssertEqual(Double(IconAnimation.frameCount) / IconAnimation.framesPerSecond, 1.5, accuracy: 1e-9)
    }

    func testIconAnimationFrames() {
        XCTAssertEqual(IconAnimation.frame(for: .working, index: 0).rotationDegrees, 0, accuracy: 1e-9)
        XCTAssertEqual(IconAnimation.frame(for: .working, index: 3).rotationDegrees, -90, accuracy: 1e-9)
        XCTAssertEqual(IconAnimation.frame(for: .working, index: 15), IconAnimation.frame(for: .working, index: 3))
        XCTAssertEqual(IconAnimation.frame(for: .working, index: 3).scale, 1)
        XCTAssertEqual(IconAnimation.frame(for: .working, index: 3).opacity, 1)

        let full = IconAnimation.frame(for: .ask, index: 0)
        XCTAssertEqual(full.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(full.opacity, 1, accuracy: 1e-9)
        XCTAssertEqual(full.rotationDegrees, 0)
        let low = IconAnimation.frame(for: .ask, index: 6)
        XCTAssertEqual(low.scale, 0.82, accuracy: 1e-9)
        XCTAssertEqual(low.opacity, 0.45, accuracy: 1e-9)
        let quarter = IconAnimation.frame(for: .ask, index: 3)
        XCTAssertEqual(quarter.scale, 0.91, accuracy: 1e-9)
        XCTAssertEqual(quarter.opacity, 0.725, accuracy: 1e-9)
        XCTAssertEqual(IconAnimation.frame(for: .ask, index: -1), IconAnimation.frame(for: .ask, index: 11))

        XCTAssertEqual(IconAnimation.frame(for: .idle, index: 7), .identity)
        XCTAssertEqual(IconAnimation.frame(for: .done, index: 30), .identity)
    }

    // MARK: Menu model

    func testMenuModelForEmptyState() {
        var settings = SidePulseSettings()
        settings.sleepPolicy = .always
        let model = StatusMenuModel(snapshot: .empty(now: now), settings: settings, devices: [],
                                    keepAwakeActive: true, hooks: [], launchAtLogin: true)
        XCTAssertEqual(model.header, "SidePulse \u{2014} Idle")
        XCTAssertEqual(model.displayState, .idle)
        XCTAssertEqual(model.tooltip, "SidePulse Agent Monitor: Idle")
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.devices.isEmpty)
        XCTAssertEqual(model.sleepPolicy, .always)
        XCTAssertTrue(model.keepAwakeActive)
        XCTAssertTrue(model.launchAtLogin)
    }

    func testMenuModelRowsDevicesAndRetention() {
        let working = AgentStatus(provider: "codex", agentID: "codex:session:w", displayName: "repo: Build it (w)",
                                  mode: .toolRunning, updatedAt: now.addingTimeInterval(-10), eventName: "PreToolUse",
                                  sessionID: "w", cwd: "/x/repo", toolName: "Bash")
        let oldDone = AgentStatus(provider: "claude", agentID: "claude:session:d", displayName: "Old",
                                  mode: .completed, updatedAt: now.addingTimeInterval(-13 * 3600), eventName: "Stop",
                                  sessionID: "d", stale: true)
        var snap = snapshot(mode: .toolRunning, active: 1, statuses: [working])
        snap.staleStatuses = [oldDone]
        var settings = SidePulseSettings()
        settings.sessionRetentionSeconds = 12 * 3600
        let devices = [device("/Volumes/PulseDot", name: "SidePulse Dot", brightness: 128),
                       device("/Volumes/OldPro", name: "SidePulse Pro", connected: false, display: .manual,
                              error: "  write failed ")]
        let model = StatusMenuModel(snapshot: snap, settings: settings, devices: devices, keepAwakeActive: false,
                                    hooks: [], launchAtLogin: false, now: now.addingTimeInterval(120),
                                    projectName: { cwd in cwd.map { ($0 as NSString).lastPathComponent } })
        XCTAssertEqual(model.header, "SidePulse \u{2014} Working (1 active)")
        XCTAssertEqual(model.rows.map(\.menuTitle), ["Build it  repo"])
        XCTAssertEqual(model.rows.first?.detail, "Working · PreToolUse · Bash · 2m ago · Codex")
        XCTAssertEqual(model.rowStates, [.working])

        settings.sessionRetentionSeconds = 24 * 3600
        let longer = StatusMenuModel(snapshot: snap, settings: settings, devices: devices, keepAwakeActive: false,
                                     hooks: [], launchAtLogin: false,
                                     projectName: { cwd in cwd.map { ($0 as NSString).lastPathComponent } })
        XCTAssertEqual(longer.rows.map(\.title), ["Build it", "Old"])

        XCTAssertEqual(model.devices.map(\.title), ["SidePulse Dot", "SidePulse Pro"])
        XCTAssertEqual(model.devices[0].brightnessLabel, "Brightness 50%")
        XCTAssertFalse(model.devices[0].showsRemove)
        XCTAssertNil(model.devices[0].error)
        XCTAssertTrue(model.devices[1].showsRemove)
        XCTAssertEqual(model.devices[1].display, .manual)
        XCTAssertEqual(model.devices[1].error, "write failed")
    }

    func testDeviceShapeDrivesInPlaceUpdates() {
        func model(_ devices: [DeviceInfo]) -> StatusMenuModel {
            StatusMenuModel(snapshot: .empty(now: now), settings: SidePulseSettings(), devices: devices,
                            keepAwakeActive: false, hooks: [], launchAtLogin: false)
        }
        let base = model([device("/Volumes/A", name: "A", brightness: 10)])
        XCTAssertTrue(base.devicesHaveSameShape(as: model([device("/Volumes/A", name: "A (1)", display: .manual, brightness: 200)])))
        XCTAssertFalse(base.devicesHaveSameShape(as: model([device("/Volumes/A", name: "A", connected: false)])))
        XCTAssertFalse(base.devicesHaveSameShape(as: model([device("/Volumes/A", name: "A", error: "boom")])))
        XCTAssertFalse(base.devicesHaveSameShape(as: model([])))
        XCTAssertFalse(base.devicesHaveSameShape(as: model([device("/Volumes/B", name: "A")])))

        // A changed error message keeps the shape, so the open menu must update the
        // existing `Error: …` item's text in place.
        let failing = model([device("/Volumes/A", name: "A", error: "disk full")])
        let failingAgain = model([device("/Volumes/A", name: "A", error: " read-only ")])
        XCTAssertTrue(failing.devicesHaveSameShape(as: failingAgain))
        XCTAssertEqual(failing.devices[0].errorText, "Error: disk full")
        XCTAssertEqual(failingAgain.devices[0].errorText, "Error: read-only")
        XCTAssertNil(base.devices[0].errorText)
        XCTAssertNil(model([device("/Volumes/A", name: "A", error: "  ")]).devices[0].errorText)
    }

    func testMenuTextIsPinned() {
        XCTAssertEqual(MenuText.settings, "Settings...")
        XCTAssertEqual(MenuText.noRecentSessions, "No recent sessions")
        XCTAssertEqual(MenuText.noDevices, "No devices")
        XCTAssertEqual(MenuText.alreadyRunning, "SidePulse is already running")
        XCTAssertEqual(SleepPolicy.allCases.map(\.label), ["Never", "When Agents Work", "Always"])
        XCTAssertEqual(LedDisplay.allCases.map(\.label), ["Agent Status", "Manual"])
    }

    // MARK: Animations

    func testAnimationStateRows() {
        XCTAssertEqual(AnimationStateRow.allCases.map(\.label),
                       ["Idle / Ready", "Working / Tool / Long Task", "Waiting for Input", "Blocked / Error",
                        "Completed", "Unknown"])
        XCTAssertEqual(AnimationStateRow.allCases.map(\.mode),
                       [.idleReady, .working, .waitingForInput, .blockedError, .completed, .unknown])
        XCTAssertEqual(AnimationStateRow.working.modes, [.working, .toolRunning, .longTaskProgress])
        XCTAssertEqual(AnimationStateRow.blocked.modes, [.blockedError])
        for mode in AgentMode.allCases {
            XCTAssertTrue(AnimationStateRow(mode: mode).modes.contains(mode), mode.rawValue)
        }
        XCTAssertEqual(Set(AnimationStateRow.allCases.flatMap(\.modes)), Set(AgentMode.allCases))
    }

    // MARK: Settings choices

    func testDurationChoices() {
        XCTAssertEqual(SettingsChoices.durationChoices(presets: SettingsChoices.idleTimeoutPresets, current: 3600).map(\.label),
                       ["15 min", "30 min", "1 hour", "2 hours", "4 hours"])
        XCTAssertEqual(SettingsChoices.durationChoices(presets: SettingsChoices.retentionPresets, current: 172_800).map(\.label),
                       ["12 hours", "24 hours", "48 hours", "7 days"])

        let custom = SettingsChoices.durationChoices(presets: SettingsChoices.idleTimeoutPresets, current: 2700)
        XCTAssertEqual(custom.map(\.label), ["15 min", "30 min", "45 min", "1 hour", "2 hours", "4 hours"])
        XCTAssertEqual(custom.filter(\.isCustom).map(\.seconds), [2700])
        XCTAssertEqual(SettingsChoices.selectedSeconds(in: custom, current: 2700), 2700)

        let nearPreset = SettingsChoices.durationChoices(presets: SettingsChoices.idleTimeoutPresets, current: 3600.2)
        XCTAssertEqual(nearPreset.count, 5)
        XCTAssertEqual(SettingsChoices.selectedSeconds(in: nearPreset, current: 3600.2), 3600)
        XCTAssertEqual(SettingsChoices.durationChoices(presets: [900], current: 0).count, 1)
        XCTAssertEqual(SettingsChoices.durationChoices(presets: [900], current: .nan).count, 1)
    }

    func testDurationLabels() {
        let cases: [(TimeInterval, String)] = [
            (60, "1 min"), (90, "1.5 min"), (900, "15 min"), (3600, "1 hour"), (5400, "1.5 hours"),
            (86_400, "24 hours"), (90_000, "25 hours"), (172_800, "48 hours"), (259_200, "3 days"),
            (262_800, "73 hours"), (604_800, "7 days"), (0, "0 min"), (-5, "0 min"),
        ]
        for (seconds, label) in cases {
            XCTAssertEqual(SettingsChoices.durationLabel(seconds), label, "\(seconds)")
        }
    }

    func testBatteryThreshold() {
        XCTAssertEqual(SettingsChoices.batteryThresholdLabel(0), "Off")
        XCTAssertEqual(SettingsChoices.batteryThresholdLabel(-3), "Off")
        XCTAssertEqual(SettingsChoices.batteryThresholdLabel(20), "20%")
        XCTAssertEqual(SettingsChoices.batteryThresholdLabel(19.6), "20%")
        XCTAssertEqual(SettingsChoices.snapBatteryPercent(22), 20)
        XCTAssertEqual(SettingsChoices.snapBatteryPercent(23), 25)
        XCTAssertEqual(SettingsChoices.snapBatteryPercent(140), 100)
        XCTAssertEqual(SettingsChoices.snapBatteryPercent(-10), 0)
        XCTAssertEqual(SettingsChoices.snapBatteryPercent(.nan), 0)
    }

    // MARK: Devices

    func testDeviceLabels() {
        XCTAssertEqual(DevicePresentation.brightnessPercent(0), 0)
        XCTAssertEqual(DevicePresentation.brightnessPercent(25), 10)
        XCTAssertEqual(DevicePresentation.brightnessPercent(128), 50)
        XCTAssertEqual(DevicePresentation.brightnessPercent(255), 100)
        XCTAssertEqual(DevicePresentation.brightnessPercent(999), 100)
        XCTAssertEqual(DevicePresentation.brightnessPercent(-4), 0)
        XCTAssertEqual(DevicePresentation.brightnessLabel(128), "Brightness 50%")
        XCTAssertEqual(DevicePresentation.brightness(fromSlider: 127.5), 128)
        XCTAssertEqual(DevicePresentation.brightness(fromSlider: 300), 255)
        XCTAssertEqual(DevicePresentation.brightness(fromSlider: -1), 0)
        XCTAssertEqual(DevicePresentation.ledCountLabel(2), "2 LEDs")
        XCTAssertEqual(DevicePresentation.ledCountLabel(1), "1 LED")
        XCTAssertEqual(DevicePresentation.subtitle(device("/Volumes/PulseDot", name: "Dot")),
                       "Connected · 2 LEDs · /Volumes/PulseDot")
        XCTAssertEqual(DevicePresentation.subtitle(device("/Volumes/PulseDot", name: "Dot", connected: false)),
                       "Not connected · /Volumes/PulseDot")
    }

    // MARK: Hooks

    private func hook(_ provider: HookProvider = .claude, exists: Bool = true, detected: Bool = true,
                      enabled: Bool = true, installed: Int, missing: Int, legacy: Int = 0, error: String? = nil,
                      cliProblems: [String] = [], untrusted: [String] = []) -> HookState {
        HookState(provider: provider, configPath: URL(fileURLWithPath: "/tmp/home/.claude/settings.json"),
                  configExists: exists, agentDetected: detected, hooksEnabled: enabled,
                  installedEvents: Array(provider.events.prefix(installed)),
                  missingEvents: Array(provider.events.suffix(missing)), legacyHooks: legacy,
                  logPath: URL(fileURLWithPath: "/tmp/root/logs/claude.jsonl"), logExists: false, error: error,
                  hookCLIPaths: installed > 0 ? ["/x/sidepulse"] : [], hookCLIProblems: cliProblems,
                  untrustedEvents: untrusted)
    }

    func testHookStatusText() {
        let full = hook(installed: 12, missing: 0)
        XCTAssertTrue(full.fullyInstalled)
        XCTAssertEqual(full.statusText, "Installed (12 events)")
        XCTAssertEqual(full.shortStatus, "Installed")
        XCTAssertEqual(full.menuTitle, "Claude Code \u{2014} Installed")
        XCTAssertEqual(full.toggleAction, .uninstall)
        XCTAssertEqual(full.id, "claude")

        XCTAssertEqual(hook(installed: 1, missing: 0).statusText, "Installed (1 event)")

        let partial = hook(installed: 5, missing: 7)
        XCTAssertFalse(partial.fullyInstalled)
        XCTAssertEqual(partial.statusText, "Partial (5/12 events)")
        XCTAssertEqual(partial.shortStatus, "Partial")
        XCTAssertEqual(partial.toggleAction, .install)

        let disabled = hook(.codex, enabled: false, installed: 11, missing: 0)
        XCTAssertEqual(disabled.statusText, "Installed, but Codex hooks are disabled")
        XCTAssertEqual(disabled.menuTitle, "Codex \u{2014} Disabled")
        XCTAssertEqual(disabled.toggleAction, .install)

        let missingConfig = hook(exists: false, installed: 0, missing: 12)
        XCTAssertEqual(missingConfig.statusText, "Not installed \u{2014} config created on install")
        XCTAssertEqual(missingConfig.shortStatus, "Not installed")
        XCTAssertEqual(hook(installed: 0, missing: 12).statusText, "Not installed")

        let broken = hook(installed: 12, missing: 0, error: "invalid JSON")
        XCTAssertFalse(broken.fullyInstalled)
        XCTAssertEqual(broken.statusText, "Error: invalid JSON")
        XCTAssertEqual(broken.shortStatus, "Error")
        XCTAssertEqual(broken.toggleAction, .install)
    }

    /// Regression: hooks calling a missing CLI (the app was moved, the link dangles)
    /// read "Installed", and clicking offered to uninstall them.
    func testHooksCallingAMissingCLINeedRepair() {
        let state = hook(installed: 12, missing: 0, cliProblems: ["/gone/sidepulse (missing)"])
        XCTAssertFalse(state.fullyInstalled)
        XCTAssertEqual(state.statusText, "Needs repair: the hooks call /gone/sidepulse (missing)")
        XCTAssertEqual(state.menuTitle, "Claude Code \u{2014} Needs repair")
        XCTAssertEqual(state.toggleAction, .install)
    }

    /// Regression: Codex hooks without trust entries (Codex skips them) read "Installed".
    func testUntrustedCodexHooksAreReported() {
        let state = hook(.codex, installed: 11, missing: 0, untrusted: ["Stop"])
        XCTAssertFalse(state.fullyInstalled)
        XCTAssertEqual(state.shortStatus, "Installed, not trusted")
        XCTAssertTrue(state.statusText.contains("/hooks in Codex"))
        XCTAssertTrue(state.statusText.contains("sidepulse install codex"))
        XCTAssertEqual(state.toggleAction, .install)
    }

    /// Regression: the menu offered a one-click install that created ~/.codex for a
    /// user without Codex.
    func testUndetectedAgentIsNotOfferedInTheMenu() {
        let state = hook(.codex, exists: false, detected: false, installed: 0, missing: 11)
        XCTAssertEqual(state.menuTitle, "Codex \u{2014} Not detected")
        XCTAssertFalse(state.menuEnabled)
        XCTAssertEqual(state.statusText, "Not detected \u{2014} config created on install")
        XCTAssertTrue(hook(.codex, exists: false, installed: 0, missing: 11).menuEnabled)
    }

    func testHookStateIsTheDoctorInfo() {
        var info = hook(.codex, enabled: false, installed: 4, missing: 7, legacy: 2)
        XCTAssertFalse(info.fullyInstalled)
        XCTAssertEqual(info.statusText, "Installed, but Codex hooks are disabled")
        XCTAssertEqual(info.legacyText, "2 legacy Python hooks (removed on install)")
        info.hooksEnabled = true
        info.installedEvents = HookProvider.codex.events
        info.missingEvents = []
        XCTAssertTrue(info.fullyInstalled)
        XCTAssertEqual(info.menuTitle, "Codex \u{2014} Installed")
        info.error = "invalid TOML"
        XCTAssertFalse(info.fullyInstalled)
    }

    func testHookLegacyAndMessages() {
        XCTAssertNil(hook(installed: 0, missing: 12).legacyText)
        XCTAssertEqual(hook(installed: 0, missing: 12, legacy: 1).legacyText, "1 legacy Python hook (removed on install)")
        XCTAssertEqual(hook(installed: 0, missing: 12, legacy: 12).legacyText, "12 legacy Python hooks (removed on install)")
        XCTAssertEqual(hook(.codex, installed: 0, missing: 11).expectedCount, 11)

        XCTAssertEqual(HookPresentation.resultMessage(provider: .codex, action: .install, changed: true), "Codex hooks installed.")
        XCTAssertEqual(HookPresentation.resultMessage(provider: .codex, action: .install, changed: false), "Codex hooks already installed.")
        XCTAssertEqual(HookPresentation.resultMessage(provider: .claude, action: .uninstall, changed: true), "Claude Code hooks removed.")
        XCTAssertEqual(HookPresentation.resultMessage(provider: .claude, action: .uninstall, changed: false), "Claude Code hooks already removed.")
        XCTAssertEqual(HookPresentation.failureMessage(provider: .claude, error: "boom"), "Claude Code hooks failed: boom")
        XCTAssertEqual(HookPresentation.detailLines(notes: ["trusted 11 Codex hooks", ""], backupPath: "/c.bak", configPath: "/c"),
                       ["trusted 11 Codex hooks", "Backup: /c.bak", "Config: /c"])
        XCTAssertEqual(HookAction.install.label, "Install")
        XCTAssertEqual(HookAction.uninstall.label, "Uninstall")
    }
}
