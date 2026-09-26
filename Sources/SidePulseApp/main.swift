import AppKit

// SidePulse menu-bar app. An accessory app (no Dock icon; LSUIElement in the
// bundle's Info.plist); everything else happens in AppDelegate.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // `NSApplication.delegate` is weak; keep the delegate alive for the process lifetime.
    withExtendedLifetime(delegate) {
        app.run()
    }
}
