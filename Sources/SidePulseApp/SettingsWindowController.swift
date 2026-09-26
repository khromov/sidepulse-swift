import AppKit
import SwiftUI
import SidePulseCore

/// Hosts `SettingsView` in a regular window ("SidePulse Settings"). The window is
/// created lazily, kept when closed, and brought to the front on every `show()`.
@MainActor
final class SettingsWindowController {
    let model: SettingsModel
    private var window: NSWindow?

    init(model: SettingsModel) {
        self.model = model
    }

    /// On screen or in the Dock (a miniaturized window reports `isVisible == false`
    /// but must still be current when it is restored).
    private var isOpen: Bool { window.map { $0.isVisible || $0.isMiniaturized } ?? false }

    /// Shows the window and activates the app (accessory apps are not active by default).
    func show() {
        let window = self.window ?? makeWindow()
        model.reload(includeHooks: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        } else if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // Activation is cooperative since macOS 14; make sure the window is visible anyway.
        window.orderFrontRegardless()
    }

    /// Keeps the open window in sync with the runtime (hooks are re-read only on show
    /// and after hook actions).
    func runtimeDidUpdate() {
        guard isOpen else { return }
        model.reload(includeHooks: false)
    }

    /// Hooks or Launch at Login changed (possibly from the status menu).
    func servicesDidChange() {
        guard isOpen else { return }
        model.reload(includeHooks: true)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = MenuText.settingsWindowTitle
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        self.window = window
        return window
    }
}
