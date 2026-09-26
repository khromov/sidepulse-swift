import AppKit
import SidePulseCore

/// Owns the runtime and the UI. Startup: create `SidePulseRuntime(paths: .current)`
/// and start it; if another instance already serves the event socket, hand over to
/// it (`handOver`) and exit 0 (so the LaunchAgent does not restart us). Then show
/// the status item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let paths = SidePulsePaths.current
    private var runtime: SidePulseRuntime?
    private var services: AppServices?
    private var statusController: StatusItemController?
    private var settingsController: SettingsWindowController?
    private var terminationSignals: [DispatchSourceSignal] = []
    private var stopped = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? paths.ensureDirectories()
        DiagnosticsLog.shared.url = paths.appLogFile

        let runtime = SidePulseRuntime(paths: paths)
        runtime.onUpdate = { [weak self] snapshot in
            Self.onMain { self?.runtimeDidUpdate(snapshot) }
        }
        runtime.onOpenSettings = { [weak self] in
            Self.onMain { self?.showSettings() }
        }
        do {
            try runtime.start()
        } catch EventSocketError.alreadyRunning(let socketPath) {
            handOver(socketPath: socketPath)
            DiagnosticsLog.shared.flush()
            exit(0)
        } catch {
            let text = ErrorText.describe(error)
            DiagnosticsLog.shared.log("app: start failed: \(text)")
            DiagnosticsLog.shared.flush()
            AppServices.showAlert(title: "SidePulse could not start", message: text, style: .critical)
            exit(0)
        }
        self.runtime = runtime
        DiagnosticsLog.shared.log("app: started version=\(SidePulseConstants.version) pid=\(getpid())")

        let services = AppServices(runtime: runtime)
        self.services = services
        settingsController = SettingsWindowController(model: SettingsModel(services: services))
        services.onStateChange = { [weak self] in self?.settingsController?.servicesDidChange() }
        let statusController = StatusItemController(
            services: services,
            openSettings: { [weak self] in self?.showSettings() },
            quit: { [weak self] in self?.quit() })
        self.statusController = statusController
        installMainMenu()
        handleTerminationSignals()
        statusController.update(snapshot: runtime.snapshot())
    }

    /// Another instance owns the socket. Started by the LaunchAgent (nobody is
    /// looking), only log it. Opened by hand, ask the other instance to show its
    /// Settings, like a Finder re-open; only a headless runtime (`sidepulse run`)
    /// cannot, and that is worth an alert.
    private func handOver(socketPath: String) {
        DiagnosticsLog.shared.log("app: another instance serves \(socketPath); exiting")
        guard ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != SidePulseConstants.launchAgentLabel else { return }
        let reply = EventSocketClient.request("open-settings", socketPath: socketPath, timeout: 1)
        guard reply.map({ String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }) != "ok" else {
            return
        }
        AppServices.showAlert(title: MenuText.alreadyRunning,
                              message: "A headless SidePulse runtime ('sidepulse run' or 'sidepulse leds') is using "
                                + "\(socketPath). Stop it, then open SidePulse again.")
    }

    /// Finder re-open (double-clicking the app while it runs) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopRuntime()
    }

    // MARK: Runtime events

    /// Runs `body` on the main actor. The runtime promises main-queue callbacks, so
    /// this is normally inline; a callback from another queue is hopped to main
    /// instead of tripping `assumeIsolated` (a crash would make launchd restart us).
    nonisolated private static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
    }

    private func runtimeDidUpdate(_ snapshot: MonitorSnapshot) {
        statusController?.update(snapshot: snapshot)
        settingsController?.runtimeDidUpdate()
    }

    private func showSettings() {
        settingsController?.show()
    }

    // MARK: Quit

    @objc private func quit() {
        stopRuntime()
        NSApp.terminate(nil)
    }

    @objc private func showSettingsFromMenu(_ sender: Any?) {
        showSettings()
    }

    /// `launchctl bootout` (install/upgrade, `sidepulse app stop`) sends SIGTERM and
    /// `sidepulse app start --foreground` forwards Ctrl-C as SIGINT; terminate normally
    /// so the runtime flushes latest.json and releases the keep-awake assertion.
    private func handleTerminationSignals() {
        terminationSignals = [SIGTERM, SIGINT].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            source.resume()
            return source
        }
    }

    private func stopRuntime() {
        guard !stopped, let runtime else { return }
        stopped = true
        runtime.stop()
        DiagnosticsLog.shared.log("app: stopped")
        DiagnosticsLog.shared.flush()
    }

    /// Accessory apps have no visible main menu, but its key equivalents still work
    /// while a SidePulse window is key (⌘, ⌘W ⌘Q, and copy in the settings window).
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: MenuText.appName)
        let settingsItem = NSMenuItem(title: MenuText.settings, action: #selector(showSettingsFromMenu(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let quitItem = NSMenuItem(title: MenuText.quit, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }
}
