import AppKit
import SidePulseCore

/// Exits 0 when another instance already serves the event socket so the LaunchAgent does not restart us.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let paths = SidePulsePaths.current
    private var runtime: SidePulseRuntime?
    private var services: AppServices?
    private var statusController: StatusItemController?
    private var settingsController: SettingsWindowController?
    private var terminationSignals: [DispatchSourceSignal] = []
    private let ejectGuard = SDEjectGuard()
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
        ejectGuard.setEnabled(runtime.settings.sdEjectGuard)

        let services = AppServices(runtime: runtime, updater: AppUpdater.startIfConfigured())
        self.services = services
        settingsController = SettingsWindowController(model: SettingsModel(services: services))
        let statusController = StatusItemController(
            services: services,
            openSettings: { [weak self] in self?.showSettings() },
            quit: { [weak self] in self?.quit() })
        self.statusController = statusController
        installMainMenu()
        handleTerminationSignals()
        statusController.update(snapshot: runtime.snapshot())
    }

    /// A LaunchAgent start only logs because nobody is looking; a manual open asks the other instance to show
    /// Settings and alerts only when it is a headless runtime that cannot.
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopRuntime()
    }

    // MARK: Runtime events

    /// Hops a stray off-main callback to main instead of tripping `assumeIsolated`, since a crash would make
    /// launchd restart us.
    nonisolated private static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
    }

    /// Also follows the eject-guard setting, since every settings change publishes an update.
    private func runtimeDidUpdate(_ snapshot: MonitorSnapshot) {
        if let runtime { ejectGuard.setEnabled(runtime.settings.sdEjectGuard) }
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

    /// SIGTERM (`launchctl bootout`) and SIGINT terminate normally so the runtime flushes latest.json and
    /// releases the keep-awake assertion.
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
        ejectGuard.setEnabled(false)
        runtime.stop()
        DiagnosticsLog.shared.log("app: stopped")
        DiagnosticsLog.shared.flush()
    }

    /// Accessory apps have no visible main menu, but its key equivalents still work while a SidePulse window is key.
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
