import Foundation

/// What a Stream Deck status key shows; the plugin renders it and the tests pin it.
public struct StreamDeckTile: Sendable, Equatable, Hashable {
    public enum Glyph: String, Sendable, Hashable {
        case idle, working, done, ask, error, off
    }

    public var glyph: Glyph
    /// Small text above the glyph, set only when the key follows one provider.
    public var heading: String?
    public var label: String
    public var detail: String?

    public init(glyph: Glyph, heading: String? = nil, label: String, detail: String? = nil) {
        self.glyph = glyph; self.heading = heading; self.label = label; self.detail = detail
    }

    public var animates: Bool { glyph == .working || glyph == .ask || glyph == .error }
}

public enum StreamDeckTilePresentation {
    public static let offLabel = "Off"
    public static let offDetail = "Press to start"
    public static let errorLabel = "Error"

    /// nil `provider` follows every agent, like the menu-bar icon.
    public static func tile(snapshot: MonitorSnapshot?, provider: HookProvider?, config: MonitorConfig) -> StreamDeckTile {
        let heading = provider?.label
        guard let snapshot else {
            return StreamDeckTile(glyph: .off, heading: heading, label: offLabel, detail: offDetail)
        }
        let aggregate = provider.map { aggregate(of: snapshot, provider: $0, config: config) } ?? snapshot.aggregate
        let detail = aggregate.activeCount > 0 ? "\(aggregate.activeCount) active" : nil
        // Unlike the menu-bar icon, a key tells a failure apart from a question.
        if aggregate.mode == .blockedError {
            return StreamDeckTile(glyph: .error, heading: heading, label: errorLabel, detail: detail)
        }
        let state = aggregate.mode.displayState
        return StreamDeckTile(glyph: glyph(for: state), heading: heading, label: state.label, detail: detail)
    }

    /// The snapshot moves a provider's finished rows to stale while another provider is active, so the
    /// aggregate is rebuilt from that provider's rows alone.
    public static func aggregate(of snapshot: MonitorSnapshot, provider: HookProvider, config: MonitorConfig) -> AggregateStatus {
        let rows = (snapshot.statuses + snapshot.staleStatuses).filter { $0.provider == provider.rawValue }
        return SnapshotBuilder.build(statuses: rows, config: config, now: snapshot.collectedAt, sources: []).aggregate
    }

    static func glyph(for state: DisplayState) -> StreamDeckTile.Glyph {
        switch state {
        case .idle: return .idle
        case .working: return .working
        case .done: return .done
        case .ask: return .ask
        }
    }

    /// Unknown values fall back to every agent, so a setting from a newer plugin version still shows something.
    public static func provider(fromSetting value: String?) -> HookProvider? {
        value.flatMap(HookProvider.init(rawValue:))
    }
}
