import Foundation
import SidePulseCore

/// State and actions behind the SwiftUI settings window. Reads from the runtime
/// (settings, devices, keep-awake) and writes through `runtime.updateSettings` /
/// `setDeviceDisplay` / `setDeviceBrightness`, applying each change locally first so
/// controls do not snap back while the runtime catches up.
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var settings: SidePulseSettings
    @Published private(set) var devices: [DeviceInfo] = []
    @Published private(set) var hooks: [HookState] = []
    @Published private(set) var launchAtLogin = false
    @Published private(set) var keepAwakeActive = false
    @Published private(set) var busyProviders: Set<HookProvider> = []
    /// Detail lines from the last install/uninstall per provider.
    @Published private(set) var hookNotes: [HookProvider: [String]] = [:]
    /// Last action result or error, shown at the bottom of the window.
    @Published var message: String?

    let services: AppServices
    /// Built-in animation catalog (picker entries).
    let animations = AnimationLibrary.all
    let profiles = AnimationProfiles.builtIn

    private var runtime: SidePulseRuntime { services.runtime }

    init(services: AppServices) {
        self.services = services
        settings = services.runtime.settings
    }

    /// Re-reads runtime state; hooks only when asked (they read agent config files).
    func reload(includeHooks: Bool) {
        assignIfChanged(\.settings, runtime.settings)
        assignIfChanged(\.devices, runtime.deviceInfos())
        assignIfChanged(\.keepAwakeActive, runtime.keepAwakeActive)
        assignIfChanged(\.launchAtLogin, services.launchAtLoginEnabled)
        if includeHooks { assignIfChanged(\.hooks, services.hookStates()) }
    }

    /// Avoids republishing (and re-rendering) unchanged values on every runtime update.
    private func assignIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<SettingsModel, Value>,
                                                   _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    // MARK: Settings

    /// Applies `body` locally, then saves it through the runtime (reload-modify-save).
    func update(_ body: @escaping (inout SidePulseSettings) -> Void) {
        body(&settings)
        runtime.updateSettings(body)
    }

    // MARK: Animations

    func animationID(for row: AnimationStateRow) -> String {
        settings.animationID(for: row.mode)
    }

    func setAnimation(_ id: String, for row: AnimationStateRow) {
        guard id != animationID(for: row) else { return }
        update { $0.setAnimation(id, for: row.mode) }
    }

    /// Matching built-in profile id, or "" for "Current".
    var profileSelection: String { settings.matchingProfile?.id ?? "" }

    func applyProfile(id: String) {
        guard id != profileSelection, let profile = profiles.first(where: { $0.id == id }) else { return }
        update { $0.apply(profile: profile) }
    }

    /// Previews are possible when LEDs are on and a connected device shows agent status.
    var canPreview: Bool {
        settings.ledsEnabled && devices.contains { $0.connected && $0.display == .agent }
    }

    func preview(_ row: AnimationStateRow) {
        runtime.preview(animationID: animationID(for: row), seconds: 3)
    }

    // MARK: Devices

    func setDisplay(_ display: LedDisplay, for device: DeviceInfo) {
        guard display != device.display else { return }
        modifyDevice(device.id) { $0.display = display }
        runtime.setDeviceDisplay(display, deviceID: device.id)
    }

    func setBrightness(_ brightness: Int, for device: DeviceInfo) {
        guard brightness != device.brightness else { return }
        modifyDevice(device.id) { $0.brightness = brightness }
        runtime.setDeviceBrightness(brightness, deviceID: device.id)
    }

    func remove(_ device: DeviceInfo) {
        devices.removeAll { $0.id == device.id }
        runtime.removeDevice(id: device.id)
    }

    private func modifyDevice(_ id: String, _ body: (inout DeviceInfo) -> Void) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        body(&devices[index])
    }

    // MARK: Hooks

    func perform(_ action: HookAction, provider: HookProvider) {
        guard !busyProviders.contains(provider) else { return }
        busyProviders.insert(provider)
        message = nil
        services.performHook(action, provider: provider) { [weak self] outcome in
            guard let self else { return }
            self.busyProviders.remove(provider)
            self.hookNotes[provider] = outcome.details
            self.message = outcome.message
            self.hooks = self.services.hookStates()
        }
    }

    func refreshHooks() {
        hooks = services.hookStates()
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try services.setLaunchAtLogin(enabled)
            message = nil
        } catch {
            message = "Could not change Launch at Login: \(ErrorText.describe(error))"
        }
        launchAtLogin = services.launchAtLoginEnabled
    }
}
