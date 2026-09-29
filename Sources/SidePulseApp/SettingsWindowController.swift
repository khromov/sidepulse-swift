import AppKit
import SwiftUI
import SidePulseCore

@MainActor
final class SettingsWindowController {
    let model: SettingsModel
    private var window: NSWindow?

    init(model: SettingsModel) {
        self.model = model
    }

    /// A miniaturized window reports `isVisible == false` but must still be current when it is restored.
    private var isOpen: Bool { window.map { $0.isVisible || $0.isMiniaturized } ?? false }

    func show() {
        let window = self.window ?? makeWindow()
        model.reload(includeHooks: true)
        model.refreshCommandLine()
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

    func runtimeDidUpdate() {
        guard isOpen else { return }
        model.reload(includeHooks: false)
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
