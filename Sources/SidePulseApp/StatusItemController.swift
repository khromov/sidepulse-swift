import AppKit
import SidePulseCore

/// The animation timer runs only while someone can see it animate, because each frame makes AppKit redraw the
/// item on every display.
@MainActor
final class StatusItemController: NSObject {
    let menuController: StatusMenuController

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var state: DisplayState = .idle
    private var animationTimer: Timer?
    private var frame = 0
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var screensAsleep = false
    private var sessionInactive = false

    init(services: AppServices, openSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        menuController = StatusMenuController(services: services, openSettings: openSettings, quit: quit)
        super.init()
        statusItem.menu = menuController.menu
        statusItem.button?.title = ""
        menuController.onAnimationStateChange = { [weak self] in self?.updateAnimation() }
        let center = NSWorkspace.shared.notificationCenter
        let observed: [(Notification.Name, Selector)] = [
            (NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, #selector(accessibilityOptionsChanged(_:))),
            (NSWorkspace.screensDidSleepNotification, #selector(visibilityChanged(_:))),
            (NSWorkspace.screensDidWakeNotification, #selector(visibilityChanged(_:))),
            (NSWorkspace.sessionDidResignActiveNotification, #selector(visibilityChanged(_:))),
            (NSWorkspace.sessionDidBecomeActiveNotification, #selector(visibilityChanged(_:))),
        ]
        for (name, selector) in observed { center.addObserver(self, selector: selector, name: name, object: nil) }
        showIcon(frame: nil)
    }

    func update(snapshot: MonitorSnapshot) {
        let newState = snapshot.aggregate.mode.displayState
        if newState != state {
            state = newState
            DiagnosticsLog.shared.log("state=\(newState.label)")
        }
        if animationTimer == nil { showIcon(frame: nil) }
        menuController.update(snapshot: snapshot)
        updateAnimation()
    }

    // MARK: Icon

    private func showIcon(frame: Int?) {
        guard let button = statusItem.button else { return }
        let tooltip = StatusBarPresentation.tooltip(for: state)
        let image = IconRenderer.image(for: state, frame: frame)
        if button.image !== image { button.image = image }
        if button.toolTip != tooltip {
            button.toolTip = tooltip
            button.setAccessibilityLabel(tooltip)
        }
    }

    // MARK: Animation

    private func updateAnimation() {
        let needed = StatusBarPresentation.shouldAnimate(
            iconState: state, iconVisible: statusItem.isVisible,
            openMenuRowStates: menuController.isOpen ? menuController.rowStates : [],
            reduceMotion: reduceMotion, paused: screensAsleep || sessionInactive)
        if needed, animationTimer == nil {
            let timer = Timer(timeInterval: 1.0 / IconAnimation.framesPerSecond, target: self,
                              selector: #selector(tick(_:)), userInfo: nil, repeats: true)
            timer.tolerance = 0.25 / IconAnimation.framesPerSecond
            // .common includes the event-tracking mode, so frames keep coming while the menu is open.
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        } else if !needed, let timer = animationTimer {
            timer.invalidate()
            animationTimer = nil
            showIcon(frame: nil)
            menuController.showStaticRowImages()
        }
    }

    @objc private func tick(_ timer: Timer) {
        frame = (frame + 1) % IconAnimation.frameCount
        showIcon(frame: frame)
        if menuController.isOpen { menuController.animateRows(frame: frame) }
    }

    @objc private func accessibilityOptionsChanged(_ notification: Notification) {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        updateAnimation()
    }

    @objc private func visibilityChanged(_ notification: Notification) {
        switch notification.name {
        case NSWorkspace.screensDidSleepNotification: screensAsleep = true
        case NSWorkspace.screensDidWakeNotification: screensAsleep = false
        case NSWorkspace.sessionDidResignActiveNotification: sessionInactive = true
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionInactive = false
        default: break
        }
        updateAnimation()
    }
}
