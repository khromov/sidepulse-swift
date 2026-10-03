import AppKit
import SidePulseCore

/// Animations run only while someone can see them. Core Animation animates the icon, and a timer swaps the open
/// menu's row images.
@MainActor
final class StatusItemController: NSObject {
    let menuController: StatusMenuController

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let animatedIcon = AnimatedIconView()
    private var state: DisplayState = .idle
    private var animatingState: DisplayState?
    private var rowTimer: Timer?
    private var frame = 0
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var screensAsleep = false
    private var sessionInactive = false

    init(services: AppServices, openSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        menuController = StatusMenuController(services: services, openSettings: openSettings, quit: quit)
        super.init()
        statusItem.menu = menuController.menu
        if let button = statusItem.button {
            button.title = ""
            animatedIcon.frame = button.bounds
            animatedIcon.autoresizingMask = [.width, .height]
            button.addSubview(animatedIcon)
        }
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
        showIcon()
    }

    func update(snapshot: MonitorSnapshot) {
        let newState = snapshot.aggregate.mode.displayState
        if newState != state {
            state = newState
            DiagnosticsLog.shared.log("state=\(newState.label)")
        }
        menuController.update(snapshot: snapshot)
        updateAnimation()
    }

    // MARK: Icon

    /// The button shows no image while the animated layer stands in for it.
    private func showIcon() {
        guard let button = statusItem.button else { return }
        let tooltip = StatusBarPresentation.tooltip(for: state)
        let image = animatingState == nil ? IconRenderer.image(for: state) : nil
        if button.image !== image { button.image = image }
        if button.toolTip != tooltip {
            button.toolTip = tooltip
            button.setAccessibilityLabel(tooltip)
        }
    }

    // MARK: Animation

    private func updateAnimation() {
        let paused = screensAsleep || sessionInactive
        let iconAnimates = StatusBarPresentation.shouldAnimate(iconState: state, iconVisible: statusItem.isVisible,
                                                               reduceMotion: reduceMotion, paused: paused)
        let target = iconAnimates ? state : nil
        if target != animatingState {
            animatingState = target
            if let target { animatedIcon.play(target) } else { animatedIcon.stop() }
            // Other displays' menu bars show a snapshot that AppKit retakes only when the button redraws, and going
            // from Working to Ask leaves the button's image unchanged.
            statusItem.button?.needsDisplay = true
        }
        showIcon()

        let rowsAnimate = menuController.isOpen && StatusBarPresentation.shouldAnimateMenuRows(
            menuController.rowStates, reduceMotion: reduceMotion, paused: paused)
        if rowsAnimate, rowTimer == nil {
            let timer = Timer(timeInterval: 1.0 / IconAnimation.framesPerSecond, target: self,
                              selector: #selector(tick(_:)), userInfo: nil, repeats: true)
            timer.tolerance = 0.25 / IconAnimation.framesPerSecond
            // .common includes the event-tracking mode, so frames keep coming while the menu is open.
            RunLoop.main.add(timer, forMode: .common)
            rowTimer = timer
        } else if !rowsAnimate, let timer = rowTimer {
            timer.invalidate()
            rowTimer = nil
            menuController.showStaticRowImages()
        }
    }

    @objc private func tick(_ timer: Timer) {
        frame = (frame + 1) % IconAnimation.frameCount
        menuController.animateRows(frame: frame)
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
