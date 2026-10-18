import Foundation
import SidePulseCore

/// Where the keys' status comes from: the running SidePulse runtime, polled over its socket.
public struct StatusSource {
    /// nil when no SidePulse runtime answers.
    public var load: () -> MonitorSnapshot?
    public var monitorConfig: () -> MonitorConfig

    public init(load: @escaping () -> MonitorSnapshot?, monitorConfig: @escaping () -> MonitorConfig) {
        self.load = load; self.monitorConfig = monitorConfig
    }

    public static func live(paths: SidePulsePaths) -> StatusSource {
        let socket = paths.socketPath
        let settings = SettingsStore(url: paths.settingsFile)
        return StatusSource(
            load: {
                guard let reply = EventSocketClient.request("status", socketPath: socket, timeout: 1),
                      let json = try? JSONValue.parse(reply) else { return nil }
                return MonitorSnapshot.fromJSON(json)
            },
            monitorConfig: { settings.load().monitorConfig })
    }
}

/// The settings the property inspector stores on each key.
public struct KeySettings: Sendable, Equatable {
    public static let providerKey = "provider"
    public static let animateKey = "animate"

    public var provider: HookProvider?
    public var animate: Bool

    public init(provider: HookProvider? = nil, animate: Bool = true) {
        self.provider = provider; self.animate = animate
    }

    public init(_ settings: JSONObject) {
        self.init(provider: StreamDeckTilePresentation.provider(fromSetting: settings[Self.providerKey]?.stringValue),
                  animate: settings[Self.animateKey]?.boolValue ?? true)
    }
}

/// Runs entirely on `queue`; only the socket requests and the app launch run on the background queue.
public final class StatusPlugin {
    public static let actionUUID = "io.sidepulse.swift.streamdeck.status"
    public static let downloadURL = "https://github.com/khromov/sidepulse-swift/releases/latest"
    public static let pollInterval: TimeInterval = 1
    static let imageCacheLimit = 128

    private let output: StreamDeckOutput
    private let source: StatusSource
    private let opener: SidePulseOpener
    private let queue: DispatchQueue
    /// nil runs background work inline, which only tests do.
    private let background: DispatchQueue?
    private let usesTimers: Bool

    private(set) var keys: [String: KeySettings] = [:]
    private var sentImages: [String: String] = [:]
    private var images: [ImageKey: String] = [:]
    private var snapshot: MonitorSnapshot?
    private var config = MonitorConfig()
    private var loaded = false
    private var loading = false
    private(set) var frame = 0
    private var pollTimer: DispatchSourceTimer?
    private var animationTimer: DispatchSourceTimer?

    private struct ImageKey: Hashable {
        var tile: StreamDeckTile
        var frame: Int
    }

    public init(output: StreamDeckOutput, source: StatusSource, opener: SidePulseOpener, queue: DispatchQueue = .main,
                background: DispatchQueue? = DispatchQueue(label: "sidepulse.streamdeck.background", qos: .utility),
                usesTimers: Bool = true) {
        self.output = output; self.source = source; self.opener = opener; self.queue = queue
        self.background = background; self.usesTimers = usesTimers
    }

    public func handle(_ event: StreamDeckEvent) {
        guard event.action == nil || event.action == Self.actionUUID else { return }
        switch event.event {
        case "willAppear":
            guard let context = event.context else { return }
            keys[context] = KeySettings(event.settings)
            // Stream Deck shows the manifest image again after a page or profile switch.
            sentImages[context] = nil
            if loaded { render(context) }
            refresh()
            updateTimers()
        case "willDisappear":
            guard let context = event.context else { return }
            keys[context] = nil
            sentImages[context] = nil
            updateTimers()
        case "didReceiveSettings":
            guard let context = event.context, keys[context] != nil else { return }
            keys[context] = KeySettings(event.settings)
            if loaded { render(context) }
            updateTimers()
        case "keyDown":
            guard let context = event.context else { return }
            openSidePulse(from: context)
        case "systemDidWakeUp":
            refresh()
        default:
            break
        }
    }

    // MARK: Status

    func refresh() {
        guard !loading, !keys.isEmpty else { return }
        loading = true
        let needsConfig = keys.values.contains { $0.provider != nil }
        let source = self.source
        perform({ () -> (MonitorSnapshot?, MonitorConfig?) in
            let snapshot = source.load()
            return (snapshot, needsConfig && snapshot != nil ? source.monitorConfig() : nil)
        }, then: { [weak self] in self?.statusLoaded($0.0, config: $0.1) })
    }

    func statusLoaded(_ snapshot: MonitorSnapshot?, config: MonitorConfig?) {
        loading = false
        loaded = true
        self.snapshot = snapshot
        if let config { self.config = config }
        for context in keys.keys { render(context) }
        updateTimers()
    }

    func tile(for settings: KeySettings) -> StreamDeckTile {
        StreamDeckTilePresentation.tile(snapshot: snapshot, provider: settings.provider, config: config)
    }

    // MARK: Images

    func advanceAnimation() {
        frame = (frame + 1) % TileRenderer.frameCount
        for (context, settings) in keys where settings.animate && tile(for: settings).animates { render(context) }
    }

    private func render(_ context: String) {
        guard let settings = keys[context] else { return }
        let tile = tile(for: settings)
        let key = ImageKey(tile: tile, frame: settings.animate && tile.animates ? frame : 0)
        let image: String
        if let cached = images[key] {
            image = cached
        } else {
            guard let png = TileRenderer.keyPNG(tile, frame: key.frame) else { return }
            if images.count >= Self.imageCacheLimit { images.removeAll() }
            image = TileRenderer.dataURL(png: png)
            images[key] = image
        }
        guard sentImages[context] != image else { return }
        sentImages[context] = image
        output.send(StreamDeckCommand.setImage(context: context, image: image))
    }

    // MARK: Key press

    private func openSidePulse(from context: String) {
        let opener = self.opener
        perform({ opener.open() }, then: { [weak self] in self?.opened($0, from: context) })
    }

    /// Without the app installed the key leads to its download page, since a Marketplace user may not have it yet.
    private func opened(_ outcome: SidePulseOpener.Outcome, from context: String) {
        refresh()
        guard let message = Self.failureMessage(outcome) else { return }
        output.send(StreamDeckCommand.logMessage(message))
        if outcome == .appNotFound {
            output.send(StreamDeckCommand.openURL(Self.downloadURL))
        } else {
            output.send(StreamDeckCommand.showAlert(context: context))
        }
    }

    static func failureMessage(_ outcome: SidePulseOpener.Outcome) -> String? {
        switch outcome {
        case .opened:
            return nil
        case .headless:
            return "SidePulse: a headless 'sidepulse run' or 'sidepulse leds' is running, and it has no settings window."
        case .appNotFound:
            return "SidePulse: SidePulse.app (\(SidePulseConstants.bundleIdentifier)) is not installed."
        case .timedOut:
            return "SidePulse: the app did not answer within \(Int(SidePulseOpener.startupTimeout)) s of starting."
        }
    }

    // MARK: Timers

    private func perform<T>(_ work: @escaping () -> T, then finish: @escaping (T) -> Void) {
        guard let background else { return finish(work()) }
        let queue = self.queue
        background.async {
            let result = work()
            queue.async { finish(result) }
        }
    }

    private func updateTimers() {
        guard usesTimers else { return }
        if keys.isEmpty {
            pollTimer?.cancel()
            pollTimer = nil
        } else if pollTimer == nil {
            pollTimer = makeTimer(interval: Self.pollInterval) { [weak self] in self?.refresh() }
        }
        let animating = loaded && keys.values.contains { $0.animate && tile(for: $0).animates }
        if !animating {
            animationTimer?.cancel()
            animationTimer = nil
        } else if animationTimer == nil {
            animationTimer = makeTimer(interval: TileRenderer.frameInterval) { [weak self] in self?.advanceAnimation() }
        }
    }

    private func makeTimer(interval: TimeInterval, _ handler: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }
}
