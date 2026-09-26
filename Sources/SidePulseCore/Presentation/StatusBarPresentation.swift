import Foundation

/// Fixed menu and alert strings. Titles use three ASCII dots, never "…"
/// (Python pins "Settings...").
public enum MenuText {
    public static let appName = "SidePulse"
    public static let agents = "Agents"
    public static let noRecentSessions = "No recent sessions"
    public static let devices = "Devices"
    public static let noDevices = "No devices"
    public static let notConnected = "Not connected"
    public static let remove = "Remove"
    public static let keepAwake = "Keep Awake"
    public static let keepingAwake = "Keeping Mac awake"
    public static let hooks = "Hooks"
    public static let openLogsFolder = "Open Logs Folder"
    public static let settings = "Settings..."
    public static let launchAtLogin = "Launch at Login"
    public static let quit = "Quit SidePulse"
    public static let alreadyRunning = "SidePulse is already running"
    public static let settingsWindowTitle = "SidePulse Settings"
}

/// Menu-bar icon, tooltip and header text (spec status-bar §4-5).
public enum StatusBarPresentation {
    /// Tooltip and accessibility label, exactly `SidePulse Agent Monitor: <Label>`
    /// (pinned by the Python tests).
    public static func tooltip(for state: DisplayState) -> String {
        "SidePulse Agent Monitor: \(state.label)"
    }

    /// Menu header: `SidePulse — <state>` plus ` (N active)` when agents are active,
    /// e.g. `SidePulse — Working (2 active)`, `SidePulse — Idle`.
    public static func header(mode: AgentMode, activeCount: Int) -> String {
        let base = "\(MenuText.appName) \u{2014} \(mode.displayState.label)"
        return activeCount > 0 ? "\(base) (\(activeCount) active)" : base
    }

    /// `header(mode:activeCount:)` for a snapshot's aggregate.
    public static func header(for snapshot: MonitorSnapshot) -> String {
        header(mode: snapshot.aggregate.mode, activeCount: snapshot.aggregate.activeCount)
    }

    /// Only Working (rotate) and Ask (pulse) animate.
    public static func animates(_ state: DisplayState) -> Bool {
        state == .working || state == .ask
    }

    /// The animation timer runs only when Reduce Motion is off, nothing is `paused`
    /// (displays asleep, or the login session switched away, so nobody can see it),
    /// and either the visible icon animates or an open menu shows an animating row.
    public static func shouldAnimate(iconState: DisplayState, iconVisible: Bool = true,
                                     openMenuRowStates: [DisplayState] = [], reduceMotion: Bool,
                                     paused: Bool = false) -> Bool {
        guard !reduceMotion, !paused else { return false }
        return (iconVisible && animates(iconState)) || openMenuRowStates.contains(where: animates)
    }
}

/// One frame of the icon animation, applied around the icon centre.
public struct IconFrame: Sendable, Equatable {
    /// Degrees, counter-clockwise positive (Working uses negative = clockwise).
    public var rotationDegrees: Double
    public var scale: Double
    /// 0...1 draw fraction.
    public var opacity: Double

    public init(rotationDegrees: Double, scale: Double, opacity: Double) {
        self.rotationDegrees = rotationDegrees; self.scale = scale; self.opacity = opacity
    }

    public static let identity = IconFrame(rotationDegrees: 0, scale: 1, opacity: 1)
}

/// Icon animation math, after Python `animated_status_icon` (48 frames at 30 fps)
/// but stepped: 12 frames at 8 fps, the same 1.5 s cycle. Every new image makes
/// AppKit redraw the status item on each display, so the frame rate is the cost.
/// The 18×18 canvas draws the symbol at 15×15, centred.
public enum IconAnimation {
    public static let framesPerSecond: Double = 8
    public static let frameCount = 12
    public static let canvasSize: Double = 18
    public static let symbolSize: Double = 15

    /// `phase = index / frameCount`. Working: rotate `-360·phase`. Ask: `pulse = (1 + cos 2π·phase) / 2`, scale
    /// `0.82 + 0.18·pulse`, opacity `0.45 + 0.55·pulse`. Others: identity.
    public static func frame(for state: DisplayState, index: Int) -> IconFrame {
        let wrapped = ((index % frameCount) + frameCount) % frameCount
        let phase = Double(wrapped) / Double(frameCount)
        switch state {
        case .working:
            return IconFrame(rotationDegrees: -360 * phase, scale: 1, opacity: 1)
        case .ask:
            let pulse = (1 + cos(2 * Double.pi * phase)) / 2
            return IconFrame(rotationDegrees: 0, scale: 0.82 + 0.18 * pulse, opacity: 0.45 + 0.55 * pulse)
        case .idle, .done:
            return .identity
        }
    }
}
