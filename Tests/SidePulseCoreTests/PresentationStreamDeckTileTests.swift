import XCTest
@testable import SidePulseCore

final class PresentationStreamDeckTileTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let config = MonitorConfig()

    private func status(_ provider: String, _ id: String, _ mode: AgentMode, age: TimeInterval = 5) -> AgentStatus {
        AgentStatus(provider: provider, agentID: "\(provider):session:\(id)", displayName: id, mode: mode,
                    updatedAt: now.addingTimeInterval(-age), eventName: "PreToolUse", sessionID: id)
    }

    private func snapshot(_ statuses: [AgentStatus]) -> MonitorSnapshot {
        SnapshotBuilder.build(statuses: statuses, config: config, now: now, sources: [])
    }

    func testNoRuntimeShowsOff() {
        XCTAssertEqual(StreamDeckTilePresentation.tile(snapshot: nil, provider: nil, config: config),
                       StreamDeckTile(glyph: .off, label: "Off", detail: "Press to start"))
        XCTAssertEqual(StreamDeckTilePresentation.tile(snapshot: nil, provider: .codex, config: config).heading, "Codex")
    }

    func testAllAgentsFollowTheAggregate() {
        let tile = StreamDeckTilePresentation.tile(
            snapshot: snapshot([status("claude", "a", .waitingForInput), status("codex", "b", .toolRunning)]),
            provider: nil, config: config)
        XCTAssertEqual(tile, StreamDeckTile(glyph: .ask, label: "Ask", detail: "2 active"))
        XCTAssertTrue(tile.animates)
    }

    /// The key and the menu-bar icon must agree, and the icon shows Blocked / Error as Ask.
    func testBlockedErrorShowsAsAskLikeTheMenuBar() {
        let shared = snapshot([status("claude", "a", .working), status("codex", "b", .blockedError)])
        XCTAssertEqual(StatusBarPresentation.header(for: shared), "SidePulse \u{2014} Ask (2 active)")
        XCTAssertEqual(StreamDeckTilePresentation.tile(snapshot: shared, provider: nil, config: config),
                       StreamDeckTile(glyph: .ask, label: "Ask", detail: "2 active"))
        XCTAssertEqual(StreamDeckTilePresentation.tile(snapshot: shared, provider: .codex, config: config),
                       StreamDeckTile(glyph: .ask, heading: "Codex", label: "Ask", detail: "1 active"))
    }

    func testEmptySnapshotIsIdleWithoutDetail() {
        let tile = StreamDeckTilePresentation.tile(snapshot: .empty(now: now), provider: nil, config: config)
        XCTAssertEqual(tile, StreamDeckTile(glyph: .idle, label: "Idle"))
        XCTAssertFalse(tile.animates)
    }

    /// The global snapshot hides Codex's finished row while Claude works, but a Codex key still shows Done.
    func testProviderKeyRebuildsItsOwnAggregate() {
        let shared = snapshot([status("claude", "a", .working), status("codex", "b", .completed)])
        XCTAssertEqual(shared.statuses.map(\.provider), ["claude"])

        XCTAssertEqual(StreamDeckTilePresentation.tile(snapshot: shared, provider: .codex, config: config),
                       StreamDeckTile(glyph: .done, heading: "Codex", label: "Done"))
        XCTAssertEqual(StreamDeckTilePresentation.tile(snapshot: shared, provider: .claude, config: config),
                       StreamDeckTile(glyph: .working, heading: "Claude Code", label: "Working", detail: "1 active"))
        XCTAssertEqual(StreamDeckTilePresentation.tile(snapshot: shared, provider: .opencode, config: config),
                       StreamDeckTile(glyph: .idle, heading: "OpenCode", label: "Idle"))
    }

    func testProviderKeyUsesTheConfiguredStaleness() {
        let shared = snapshot([status("codex", "b", .working, age: 120)])
        let strict = MonitorConfig(staleAfter: 60)
        XCTAssertEqual(StreamDeckTilePresentation.tile(snapshot: shared, provider: .codex, config: strict).glyph, .idle)
        XCTAssertEqual(StreamDeckTilePresentation.tile(snapshot: shared, provider: .codex, config: config).glyph, .working)
    }

    func testProviderSetting() {
        XCTAssertEqual(StreamDeckTilePresentation.provider(fromSetting: "codex"), .codex)
        XCTAssertNil(StreamDeckTilePresentation.provider(fromSetting: "all"))
        XCTAssertNil(StreamDeckTilePresentation.provider(fromSetting: "cursor"))
        XCTAssertNil(StreamDeckTilePresentation.provider(fromSetting: nil))
    }
}
