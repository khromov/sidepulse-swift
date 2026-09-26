import AppKit
import SidePulseCore

/// Updates the open menu in place instead of rebuilding it so open device submenus and sliders survive live refreshes.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    var onAnimationStateChange: (() -> Void)?

    private let services: AppServices
    private let openSettings: () -> Void
    private let quit: () -> Void
    private var runtime: SidePulseRuntime { services.runtime }

    private(set) var isOpen = false
    private var model: StatusMenuModel?
    private var hooks: [HookState] = []

    // Items kept for in-place updates while the menu is open.
    private var headerItem: NSMenuItem?
    private var rowItems: [NSMenuItem] = []
    private var deviceItems: [NSMenuItem] = []
    private var deviceControls: [String: DeviceControls] = [:]
    private var policyItems: [SleepPolicy: NSMenuItem] = [:]
    private var keepingAwakeItems: [NSMenuItem] = []
    private var launchAtLoginItem: NSMenuItem?

    private struct DeviceControls {
        let item: NSMenuItem
        let agent: NSMenuItem
        let manual: NSMenuItem
        let brightnessLabel: NSMenuItem
        let slider: NSSlider
        /// Fixed at build time because whether there is an error is part of the device's shape.
        let errorLabel: NSMenuItem?
    }

    private struct DisplayChoice {
        let deviceID: String
        let display: LedDisplay
    }

    init(services: AppServices, openSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.services = services
        self.openSettings = openSettings
        self.quit = quit
        super.init()
        menu.delegate = self
    }

    var rowStates: [DisplayState] { model?.rowStates ?? [] }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        hooks = services.hookStates()
        rebuild(snapshot: runtime.snapshot())
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        isOpen = true
        onAnimationStateChange?()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        isOpen = false
        onAnimationStateChange?()
    }

    // MARK: Updates

    /// Ignored while closed because the menu is rebuilt on open anyway.
    func update(snapshot: MonitorSnapshot) {
        guard isOpen, let old = model else { return }
        let new = makeModel(snapshot: snapshot)
        model = new
        headerItem?.title = new.header

        if new.rows.count == old.rows.count, !new.rows.isEmpty {
            zip(rowItems, new.rows).forEach { configureRow($0, $1) }
        } else {
            rowItems = replace(rowItems, with: makeRowItems(new.rows))
        }

        if new.devicesHaveSameShape(as: old) {
            new.devices.forEach(updateDeviceInPlace)
        } else {
            deviceItems = replace(deviceItems, with: makeDeviceItems(new.devices))
        }

        applyToggles(new)
        onAnimationStateChange?()
    }

    func animateRows(frame: Int) {
        guard let rows = model?.rows, rows.count == rowItems.count else { return }
        for (item, row) in zip(rowItems, rows) where StatusBarPresentation.animates(row.displayState) {
            item.image = IconRenderer.image(for: row.displayState, frame: frame)
        }
    }

    func showStaticRowImages() {
        guard let rows = model?.rows, rows.count == rowItems.count else { return }
        for (item, row) in zip(rowItems, rows) {
            item.image = IconRenderer.image(for: row.displayState)
        }
    }

    // MARK: Building

    private func makeModel(snapshot: MonitorSnapshot) -> StatusMenuModel {
        StatusMenuModel(snapshot: snapshot, settings: runtime.settings, devices: runtime.deviceInfos(),
                        keepAwakeActive: runtime.keepAwakeActive, hooks: hooks,
                        launchAtLogin: services.launchAtLoginEnabled, now: Date())
    }

    private func rebuild(snapshot: MonitorSnapshot) {
        let model = makeModel(snapshot: snapshot)
        self.model = model
        menu.removeAllItems()
        deviceControls.removeAll()
        policyItems.removeAll()

        let header = label(model.header)
        headerItem = header
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(label(MenuText.agents))
        rowItems = makeRowItems(model.rows)
        rowItems.forEach(menu.addItem)
        menu.addItem(.separator())

        menu.addItem(label(MenuText.devices))
        deviceItems = makeDeviceItems(model.devices)
        deviceItems.forEach(menu.addItem)
        menu.addItem(.separator())

        menu.addItem(makeKeepAwakeItem())
        menu.addItem(makeHooksItem(model.hooks))
        menu.addItem(.separator())

        menu.addItem(action(MenuText.openLogsFolder, #selector(openLogsFolder(_:))))
        menu.addItem(action(MenuText.settings, #selector(showSettings(_:)), key: ","))
        let launch = action(MenuText.launchAtLogin, #selector(toggleLaunchAtLogin(_:)))
        launchAtLoginItem = launch
        menu.addItem(launch)
        menu.addItem(.separator())
        menu.addItem(action(MenuText.quit, #selector(quitApp(_:)), key: "q"))

        applyToggles(model)
    }

    private func makeRowItems(_ rows: [SessionRow]) -> [NSMenuItem] {
        guard !rows.isEmpty else { return [label(MenuText.noRecentSessions)] }
        return rows.map { row in
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            configureRow(item, row)
            return item
        }
    }

    private func configureRow(_ item: NSMenuItem, _ row: SessionRow) {
        item.title = row.menuTitle
        item.toolTip = row.detail
        item.image = IconRenderer.image(for: row.displayState)
        if let cwd = row.status.cwd, !cwd.isEmpty {
            item.target = self
            item.action = #selector(revealSessionFolder(_:))
            item.representedObject = cwd
        } else {
            item.target = nil
            item.action = nil
            item.representedObject = nil
        }
    }

    private func makeDeviceItems(_ devices: [DeviceMenuModel]) -> [NSMenuItem] {
        deviceControls.removeAll()
        guard !devices.isEmpty else { return [label(MenuText.noDevices)] }
        return devices.map(makeDeviceItem)
    }

    private func makeDeviceItem(_ device: DeviceMenuModel) -> NSMenuItem {
        let item = NSMenuItem(title: device.title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let agent = action(LedDisplay.agent.label, #selector(setDeviceDisplay(_:)))
        agent.representedObject = DisplayChoice(deviceID: device.id, display: .agent)
        let manual = action(LedDisplay.manual.label, #selector(setDeviceDisplay(_:)))
        manual.representedObject = DisplayChoice(deviceID: device.id, display: .manual)
        submenu.addItem(agent)
        submenu.addItem(manual)

        submenu.addItem(.separator())
        let brightnessLabel = label(device.brightnessLabel)
        submenu.addItem(brightnessLabel)
        let (sliderItem, slider) = makeBrightnessSlider(deviceID: device.id, brightness: device.brightness)
        submenu.addItem(sliderItem)

        var errorLabel: NSMenuItem?
        if let error = device.errorText {
            let errorItem = label(error)
            submenu.addItem(.separator())
            submenu.addItem(errorItem)
            errorLabel = errorItem
        }
        if device.showsRemove {
            submenu.addItem(.separator())
            submenu.addItem(label(MenuText.notConnected))
            let remove = action(MenuText.remove, #selector(removeDevice(_:)))
            remove.representedObject = device.id
            submenu.addItem(remove)
        }
        item.submenu = submenu

        let controls = DeviceControls(item: item, agent: agent, manual: manual,
                                      brightnessLabel: brightnessLabel, slider: slider, errorLabel: errorLabel)
        deviceControls[device.id] = controls
        applyDevice(device, to: controls)
        return item
    }

    /// The 230×34 layout matches the Python app.
    private func makeBrightnessSlider(deviceID: String, brightness: Int) -> (NSMenuItem, NSSlider) {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 34))
        let slider = NSSlider(frame: NSRect(x: 14, y: 6, width: 202, height: 22))
        slider.minValue = 0
        slider.maxValue = 255
        slider.doubleValue = Double(brightness)
        slider.isContinuous = false
        slider.target = self
        slider.action = #selector(brightnessChanged(_:))
        slider.identifier = NSUserInterfaceItemIdentifier(deviceID)
        slider.setAccessibilityLabel("Brightness")
        view.addSubview(slider)
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = view
        return (item, slider)
    }

    private func updateDeviceInPlace(_ device: DeviceMenuModel) {
        guard let controls = deviceControls[device.id] else { return }
        applyDevice(device, to: controls)
    }

    private func applyDevice(_ device: DeviceMenuModel, to controls: DeviceControls) {
        controls.item.title = device.title
        controls.item.state = device.connected ? .on : .off
        controls.agent.state = device.display == .agent ? .on : .off
        controls.manual.state = device.display == .manual ? .on : .off
        controls.brightnessLabel.title = device.brightnessLabel
        if let errorLabel = controls.errorLabel, let text = device.errorText { errorLabel.title = text }
        // Never move the knob under the user's cursor.
        if NSEvent.pressedMouseButtons == 0, Int(controls.slider.doubleValue.rounded()) != device.brightness {
            controls.slider.doubleValue = Double(device.brightness)
        }
    }

    private func makeKeepAwakeItem() -> NSMenuItem {
        let item = NSMenuItem(title: MenuText.keepAwake, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for policy in SleepPolicy.allCases {
            let choice = action(policy.label, #selector(setSleepPolicy(_:)))
            choice.representedObject = policy.rawValue
            policyItems[policy] = choice
            submenu.addItem(choice)
        }
        let separator = NSMenuItem.separator()
        let active = label(MenuText.keepingAwake)
        keepingAwakeItems = [separator, active]
        keepingAwakeItems.forEach(submenu.addItem)
        item.submenu = submenu
        return item
    }

    private func makeHooksItem(_ hooks: [HookState]) -> NSMenuItem {
        let item = NSMenuItem(title: MenuText.hooks, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for hook in hooks {
            let entry = hook.menuEnabled ? action(hook.menuTitle, #selector(toggleHook(_:))) : label(hook.menuTitle)
            entry.state = hook.fullyInstalled ? .on : .off
            entry.representedObject = hook.provider.rawValue
            entry.toolTip = ([hook.statusText, hook.legacyText, hook.configPath.path].compactMap { $0 }).joined(separator: "\n")
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    private func applyToggles(_ model: StatusMenuModel) {
        for (policy, item) in policyItems { item.state = policy == model.sleepPolicy ? .on : .off }
        keepingAwakeItems.forEach { $0.isHidden = !model.keepAwakeActive }
        launchAtLoginItem?.state = model.launchAtLogin ? .on : .off
    }

    /// `old` must be a contiguous run of menu items.
    private func replace(_ old: [NSMenuItem], with new: [NSMenuItem]) -> [NSMenuItem] {
        guard let first = old.first else { return old }
        var index = menu.index(of: first)
        guard index >= 0 else { return old }
        old.forEach(menu.removeItem)
        for item in new {
            menu.insertItem(item, at: index)
            index += 1
        }
        return new
    }

    private func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: Actions

    @objc private func revealSessionFolder(_ sender: NSMenuItem) {
        guard let cwd = sender.representedObject as? String else { return }
        let url = URL(fileURLWithPath: cwd, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
    }

    @objc private func setDeviceDisplay(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? DisplayChoice else { return }
        runtime.setDeviceDisplay(choice.display, deviceID: choice.deviceID)
    }

    @objc private func brightnessChanged(_ sender: NSSlider) {
        guard let deviceID = sender.identifier?.rawValue else { return }
        let brightness = DevicePresentation.brightness(fromSlider: sender.doubleValue)
        deviceControls[deviceID]?.brightnessLabel.title = DevicePresentation.brightnessLabel(brightness)
        runtime.setDeviceBrightness(brightness, deviceID: deviceID)
    }

    @objc private func removeDevice(_ sender: NSMenuItem) {
        guard let deviceID = sender.representedObject as? String else { return }
        runtime.removeDevice(id: deviceID)
    }

    @objc private func setSleepPolicy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let policy = SleepPolicy(rawValue: raw) else { return }
        runtime.updateSettings { $0.sleepPolicy = policy }
    }

    @objc private func toggleHook(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let provider = HookProvider(rawValue: raw),
              let hook = hooks.first(where: { $0.provider == provider }) else { return }
        let action = hook.toggleAction
        if action == .uninstall {
            let confirmed = AppServices.confirm(
                title: "Uninstall \(provider.label) hooks?",
                message: HookPresentation.uninstallConfirmation(provider: provider, configPath: hook.configPath.path),
                confirmTitle: HookAction.uninstall.label)
            guard confirmed else { return }
        }
        services.performHook(action, provider: provider) { [services] outcome in
            services.showHookOutcome(outcome)
        }
    }

    @objc private func openLogsFolder(_ sender: NSMenuItem) {
        services.openLogsFolder()
    }

    @objc private func showSettings(_ sender: NSMenuItem) {
        openSettings()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let enable = !services.launchAtLoginEnabled
        do {
            try services.setLaunchAtLogin(enable)
        } catch {
            AppServices.showAlert(title: "Could not change Launch at Login", message: ErrorText.describe(error),
                                  style: .warning)
        }
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        quit()
    }
}
