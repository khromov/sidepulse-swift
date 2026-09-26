import Foundation

public struct DeviceMenuModel: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var connected: Bool
    public var display: LedDisplay
    public var brightness: Int
    public var brightnessLabel: String
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

    public var errorText: String? { error.map { "Error: \($0)" } }

    public var showsRemove: Bool { !connected }

    /// Models with the same shape can update an open submenu in place instead of rebuilding it.
    public var shape: String { "\(id)\u{0}\(connected)\u{0}\(error != nil)" }
}

/// Built from plain values, with no AppKit or runtime calls, so the menu contents are unit-testable.
public struct StatusMenuModel: Sendable, Equatable {
    public var header: String
    public var displayState: DisplayState
    public var rows: [SessionRow]
    public var devices: [DeviceMenuModel]
    public var sleepPolicy: SleepPolicy
    public var keepAwakeActive: Bool

    public init(snapshot: MonitorSnapshot, settings: SidePulseSettings, devices: [DeviceInfo],
                keepAwakeActive: Bool, now: Date? = nil,
                projectName: SessionRows.ProjectResolver = SessionRows.projectName(cwd:)) {
        header = StatusBarPresentation.header(for: snapshot)
        displayState = snapshot.aggregate.mode.displayState
        rows = SessionRows.rows(snapshot: snapshot, retention: settings.sessionRetentionSeconds,
                                now: now, projectName: projectName)
        self.devices = devices.map(DeviceMenuModel.init)
        sleepPolicy = settings.sleepPolicy
        self.keepAwakeActive = keepAwakeActive
    }

    public var tooltip: String { StatusBarPresentation.tooltip(for: displayState) }

    public var rowStates: [DisplayState] { rows.map(\.displayState) }

    public func devicesHaveSameShape(as other: StatusMenuModel) -> Bool {
        devices.map(\.shape) == other.devices.map(\.shape)
    }
}
