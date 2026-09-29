import SwiftUI
import SidePulseCore

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 8) {
            TabView {
                GeneralTab(model: model)
                    .tabItem { Label("General", systemImage: "gearshape") }
                AnimationsTab(model: model)
                    .tabItem { Label("Animations", systemImage: "sparkles") }
                DevicesTab(model: model)
                    .tabItem { Label("Devices", systemImage: "lightbulb") }
                HooksTab(model: model)
                    .tabItem { Label("Hooks", systemImage: "link") }
            }
            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 600, height: 520)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Agents") {
                DurationPicker(title: "Idle timeout", presets: SettingsChoices.idleTimeoutPresets,
                               value: model.settings.idleTimeoutSeconds) { seconds in
                    model.update { $0.idleTimeoutSeconds = seconds }
                }
                DurationPicker(title: "Keep recent sessions for", presets: SettingsChoices.retentionPresets,
                               value: model.settings.sessionRetentionSeconds) { seconds in
                    model.update { $0.sessionRetentionSeconds = seconds }
                }
            }
            Section("Keep Awake") {
                Picker("Keep Mac awake", selection: Binding(
                    get: { model.settings.sleepPolicy },
                    set: { policy in model.update { $0.sleepPolicy = policy } })) {
                    ForEach(SleepPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                LabeledContent("Let Mac sleep on battery below") {
                    CommitSlider(value: model.settings.minBatteryPercent, range: SettingsChoices.batteryPercentRange,
                                 step: SettingsChoices.batteryPercentStep,
                                 label: SettingsChoices.batteryThresholdLabel) { percent in
                        let snapped = SettingsChoices.snapBatteryPercent(percent)
                        model.update { $0.minBatteryPercent = snapped }
                    }
                    .frame(width: 220)
                }
                if model.keepAwakeActive {
                    Label(MenuText.keepingAwake, systemImage: "cup.and.saucer")
                        .foregroundStyle(.secondary)
                }
            }
            Section("SD Card Reader") {
                Toggle(isOn: Binding(
                    get: { model.settings.sdEjectGuard },
                    set: { enabled in model.update { $0.sdEjectGuard = enabled } })) {
                    Text(MenuText.ejectPrevention)
                    Text(MenuText.ejectPreventionHelp)
                }
            }
            Section("General") {
                Toggle(MenuText.launchAtLogin, isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                LabeledContent("Logs") {
                    Button(MenuText.openLogsFolder) { model.services.openLogsFolder() }
                }
            }
            Section("Command Line") {
                CommandLineRows(model: model)
            }
            Section("Updates") {
                if let updates = model.updates {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updates.automaticallyChecks },
                        set: { model.setAutomaticallyChecksForUpdates($0) }))
                    Toggle("Download and install updates automatically", isOn: Binding(
                        get: { updates.automaticallyDownloads },
                        set: { model.setAutomaticallyDownloadsUpdates($0) }))
                        .disabled(!updates.automaticallyChecks)
                    LabeledContent("Version \(SidePulseConstants.version)") {
                        Button("Check Now") { model.checkForUpdates() }
                    }
                } else {
                    LabeledContent("Version", value: SidePulseConstants.version)
                    Text("Builds made from source don't update themselves. Reinstall with scripts/install.sh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CommandLineRows: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let paths = model.services.paths
        let summary = CLILinkPresentation.summary(model.cliLink, link: paths.defaultCLILink, home: paths.home)
        LabeledContent {
            HStack {
                Text(summary.status).foregroundStyle(.secondary)
                if summary.canInstall {
                    Button(HookAction.install.label) { model.installCLI() }
                }
            }
        } label: {
            Text(CLILinkPresentation.title)
            Text(summary.detail).textSelection(.enabled)
        }
        if model.cliLink == .installed {
            let note = CLILinkPresentation.pathNote(model.cliPathCheck, profile: model.shellProfile, home: paths.home)
            HStack {
                Text(note.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                if note.offersFix {
                    Button(CLILinkPresentation.addToPath) { model.addLocalBinToPATH() }
                }
            }
        }
    }
}

private struct DurationPicker: View {
    let title: String
    let presets: [TimeInterval]
    let value: TimeInterval
    let onChange: (TimeInterval) -> Void

    var body: some View {
        let choices = SettingsChoices.durationChoices(presets: presets, current: value)
        Picker(title, selection: Binding(
            get: { SettingsChoices.selectedSeconds(in: choices, current: value) },
            set: { seconds in if seconds != value { onChange(seconds) } })) {
            ForEach(choices) { Text($0.label).tag($0.seconds) }
        }
    }
}

/// Commits only on release or a keyboard step so dragging does not write settings.json on every tick.
private struct CommitSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let label: (Double) -> String
    let commit: (Double) -> Void

    @State private var draft: Double?
    @State private var editing = false

    var body: some View {
        HStack {
            slider
            Text(label(draft ?? value))
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
        }
    }

    @ViewBuilder private var slider: some View {
        if let step {
            Slider(value: binding, in: range, step: step, onEditingChanged: editingChanged)
        } else {
            Slider(value: binding, in: range, onEditingChanged: editingChanged)
        }
    }

    private var binding: Binding<Double> {
        Binding(get: { draft ?? value }, set: { newValue in
            draft = newValue
            if !editing { finish() }
        })
    }

    private func editingChanged(_ isEditing: Bool) {
        editing = isEditing
        if !isEditing { finish() }
    }

    private func finish() {
        if let draft { commit(draft) }
        draft = nil
    }
}

// MARK: - Animations

private struct AnimationsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Profile", selection: Binding(
                    get: { model.profileSelection },
                    set: { model.applyProfile(id: $0) })) {
                    if model.profileSelection.isEmpty { Text("Current").tag("") }
                    ForEach(model.profiles) { Text($0.name).tag($0.id) }
                }
            } footer: {
                Text("A profile sets every state at once. Changing a single state switches the profile to Current.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("States") {
                ForEach(AnimationStateRow.allCases) { row in
                    HStack {
                        Picker(row.label, selection: Binding(
                            get: { model.animationID(for: row) },
                            set: { model.setAnimation($0, for: row) })) {
                            ForEach(model.animations) { Text($0.name).tag($0.id) }
                        }
                        Button("Show") { model.preview(row) }
                            .accessibilityLabel("Show \(row.label) animation on devices")
                            .disabled(!model.canPreview)
                            .help(model.canPreview
                                  ? "Play this animation on connected devices for 3 seconds."
                                  : "Connect a device in Agent Status mode to preview.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Devices

private struct DevicesTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            if model.devices.isEmpty {
                Section {
                    Text("No devices. Connect a SidePulse Pro or SidePulse Dot; it appears here automatically.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.devices) { device in
                Section {
                    DeviceSettingsRow(model: model, device: device)
                } header: {
                    Text(device.name)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DeviceSettingsRow: View {
    @ObservedObject var model: SettingsModel
    let device: DeviceInfo

    var body: some View {
        Text(DevicePresentation.subtitle(device))
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        Picker("Display", selection: Binding(
            get: { device.display },
            set: { model.setDisplay($0, for: device) })) {
            ForEach(LedDisplay.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        LabeledContent("Brightness") {
            CommitSlider(value: Double(device.brightness), range: 0...255,
                         label: { "\(DevicePresentation.brightnessPercent(DevicePresentation.brightness(fromSlider: $0)))%" }) {
                model.setBrightness(DevicePresentation.brightness(fromSlider: $0), for: device)
            }
            .frame(width: 260)
        }
        if let error = device.lastError, !error.isEmpty {
            Text("Error: \(error)")
                .font(.caption)
                .foregroundStyle(.red)
        }
        if !device.connected {
            HStack {
                Text(MenuText.notConnected).foregroundStyle(.secondary)
                Spacer()
                Button(MenuText.remove) { model.remove(device) }
            }
        }
    }
}

// MARK: - Hooks

private struct HooksTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            ForEach(model.hooks) { hook in
                Section(hook.provider.label) {
                    HookSettingsRow(model: model, hook: hook)
                }
            }
            Section {
                LabeledContent("Install writes") {
                    if let cliPath = model.services.hookCLIPath {
                        Text("\(cliPath) hook-log --provider <name> ; true")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    } else {
                        Text(HookCLIPath.unresolvedMessage())
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.trailing)
                    }
                }
                HStack {
                    Spacer()
                    Button("Refresh") { model.refreshHooks() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct HookSettingsRow: View {
    @ObservedObject var model: SettingsModel
    let hook: HookState

    var body: some View {
        let busy = model.busyProviders.contains(hook.provider)
        LabeledContent("Status", value: hook.statusText)
        LabeledContent("Config") {
            Text(hook.configPath.path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
        if !hook.hookCLIPaths.isEmpty {
            LabeledContent("Hooks call") {
                Text(hook.hookCLIPaths.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        ForEach(model.hookNotes[hook.provider] ?? [], id: \.self) { note in
            Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        HStack {
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button(HookAction.install.label) { model.perform(.install, provider: hook.provider) }
                .disabled(busy)
            Button(HookAction.uninstall.label) { model.perform(.uninstall, provider: hook.provider) }
                .disabled(busy || hook.installedEvents.isEmpty)
        }
    }
}
