import Foundation

/// One device entry of the status menu's Devices section.
public struct DeviceMenuModel: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// Checkmark on the device item.
    public var connected: Bool
    /// Radio selection in the submenu (Agent Status / Manual).
    public var display: LedDisplay
    public var brightness: Int
    /// `Brightness N%`.
    public var brightnessLabel: String
    /// Last write error, shown as a disabled `Error: …` item.
    public var error: String?

    public init(_ device: DeviceInfo) {
        id = device.id
        title = device.name
        connected = device.connected
        display = device.display
        brightness = device.brightness
        brightnessLabel = DevicePresentation.brightnessLabel(device.brightness)
        let trimmed = device.lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        error = trimmed.isEmpty ? nil : trimmed
    }

    /// `Error: <error>` for the submenu's disabled error item, nil without an error.
    public var errorText: String? { error.map { "Error: \($0)" } }

    /// Disconnected (remembered) devices offer `Not connected` + `Remove`.
    public var showsRemove: Bool { !connected }

    /// Everything that changes the submenu's item list. Two models with the same
    /// shape can be updated in place (titles, states, slider value).
    public var shape: String { "\(id)\u{0}\(connected)\u{0}\(error != nil)" }
}

/// Everything the status menu shows, computed from plain values (no AppKit, no
/// runtime calls) so the menu contents are unit-testable. The app renders it and
/// diffs successive models to update an open menu in place.
///
/// Layout (spec status-bar §5, adapted):
/// ```
/// SidePulse — Working (2 active)   (disabled header)
/// ---
/// Agents                           (disabled)
/// <≤10 session rows> | No recent sessions
/// ---
/// Devices                          (disabled)
/// <device submenus> | No devices
/// ---
/// Keep Awake ▸ Never | When Agents Work | Always [--- Keeping Mac awake]
/// Hooks ▸ <one item per provider>
/// ---
/// Open Logs Folder
/// Settings...                      (⌘,)
/// Launch at Login                  (checkmark)
/// ---
/// Quit SidePulse                   (⌘Q)
/// ```
public struct StatusMenuModel: Sendable, Equatable {
    public var header: String
    public var displayState: DisplayState
    public var rows: [SessionRow]
    public var devices: [DeviceMenuModel]
    public var sleepPolicy: SleepPolicy
    public var keepAwakeActive: Bool
    public var hooks: [HookState]
    public var launchAtLogin: Bool

    /// - Parameters:
    ///   - snapshot: current monitor snapshot (rows use its `collectedAt` for the
    ///     retention cut-off).
    ///   - settings: reads `sessionRetentionSeconds`, `sleepPolicy`.
    ///   - now: reference time for row ages (default: the snapshot's time).
    public init(snapshot: MonitorSnapshot, settings: SidePulseSettings, devices: [DeviceInfo],
                keepAwakeActive: Bool, hooks: [HookState], launchAtLogin: Bool, now: Date? = nil,
                projectName: SessionRows.ProjectResolver = SessionRows.projectName(cwd:)) {
        header = StatusBarPresentation.header(for: snapshot)
        displayState = snapshot.aggregate.mode.displayState
        rows = SessionRows.rows(snapshot: snapshot, retention: settings.sessionRetentionSeconds,
                                now: now, projectName: projectName)
        self.devices = devices.map(DeviceMenuModel.init)
        sleepPolicy = settings.sleepPolicy
        self.keepAwakeActive = keepAwakeActive
        self.hooks = hooks
        self.launchAtLogin = launchAtLogin
    }

    /// Tooltip / accessibility label of the status item.
    public var tooltip: String { StatusBarPresentation.tooltip(for: displayState) }

    /// Row states that animate while the menu is open.
    public var rowStates: [DisplayState] { rows.map(\.displayState) }

    /// True when the Devices section keeps its item list (same devices in the same
    /// order with the same submenu shapes), so an open menu can update it in place.
    public func devicesHaveSameShape(as other: StatusMenuModel) -> Bool {
        devices.map(\.shape) == other.devices.map(\.shape)
    }
}
