import XCTest
import SidePulseCore
@testable import SidePulseStreamDeck

final class CapturedOutput: StreamDeckOutput {
    var messages: [JSONObject] = []

    func send(_ message: JSONObject) { messages.append(message) }

    var events: [String] { messages.compactMap { $0["event"]?.stringValue } }

    /// The images sent to `context`, in order.
    func images(for context: String) -> [String] {
        messages.filter { $0["event"] == .string("setImage") && $0["context"] == .string(context) }
            .compactMap { $0["payload"]?["image"]?.stringValue }
    }
}

final class StatusPluginTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var output = CapturedOutput()
    private var current: MonitorSnapshot?
    private var loads = 0
    private var outcome = SidePulseOpener.Outcome.opened
    private var opens = 0

    private func snapshot(_ modes: [(String, AgentMode)]) -> MonitorSnapshot {
        let statuses = modes.enumerated().map { index, item in
            AgentStatus(provider: item.0, agentID: "\(item.0):session:\(index)", displayName: "s\(index)", mode: item.1,
                        updatedAt: now.addingTimeInterval(-5), eventName: "PreToolUse")
        }
        return SnapshotBuilder.build(statuses: statuses, config: MonitorConfig(), now: now, sources: [])
    }

    private func makePlugin() -> StatusPlugin {
        let source = StatusSource(load: { [unowned self] in loads += 1; return current },
                                  monitorConfig: { MonitorConfig() })
        let opener = SidePulseOpener(requestSettings: { [unowned self] in opens += 1; return outcome == .opened },
                                     isRunning: { [unowned self] in outcome == .headless },
                                     launchApp: { false })
        return StatusPlugin(output: output, source: source, opener: opener, background: nil, usesTimers: false)
    }

    private func event(_ name: String, context: String = "key1", settings: JSONObject = JSONObject(),
                       action: String = StatusPlugin.actionUUID) -> StreamDeckEvent {
        StreamDeckEvent(event: name, action: action, context: context, payload: ["settings": .object(settings)])
    }

    private func expectedImage(_ tile: StreamDeckTile, frame: Int = 0) throws -> String {
        TileRenderer.dataURL(png: try XCTUnwrap(TileRenderer.keyPNG(tile, frame: frame)))
    }

    func testWillAppearLoadsStatusAndDrawsTheKey() throws {
        current = snapshot([("claude", .waitingForInput)])
        let plugin = makePlugin()
        plugin.handle(event("willAppear"))
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(output.images(for: "key1"),
                       [try expectedImage(StreamDeckTile(glyph: .ask, label: "Ask", detail: "1 active"))])
    }

    func testNoRuntimeDrawsOff() throws {
        let plugin = makePlugin()
        plugin.handle(event("willAppear"))
        XCTAssertEqual(output.images(for: "key1"),
                       [try expectedImage(StreamDeckTile(glyph: .off, label: "Off", detail: "Press to start"))])
    }

    func testUnchangedStatusSendsNoNewImage() {
        current = snapshot([("codex", .completed)])
        let plugin = makePlugin()
        plugin.handle(event("willAppear"))
        plugin.refresh()
        plugin.refresh()
        XCTAssertEqual(loads, 3)
        XCTAssertEqual(output.images(for: "key1").count, 1)

        current = snapshot([("codex", .working)])
        plugin.refresh()
        XCTAssertEqual(output.images(for: "key1").count, 2)
    }

    func testReappearingKeyIsDrawnAgain() {
        current = snapshot([("codex", .completed)])
        let plugin = makePlugin()
        plugin.handle(event("willAppear"))
        plugin.handle(event("willDisappear"))
        XCTAssertTrue(plugin.keys.isEmpty)
        plugin.refresh()
        XCTAssertEqual(loads, 1, "no visible key, so no polling")
        plugin.handle(event("willAppear"))
        XCTAssertEqual(output.images(for: "key1").count, 2)
    }

    func testSettingsChoosesTheProvider() throws {
        current = snapshot([("claude", .working), ("codex", .completed)])
        let plugin = makePlugin()
        plugin.handle(event("willAppear"))
        plugin.handle(event("didReceiveSettings", settings: ["provider": .string("codex")]))
        XCTAssertEqual(output.images(for: "key1").last,
                       try expectedImage(StreamDeckTile(glyph: .done, heading: "Codex", label: "Done")))
        XCTAssertEqual(plugin.keys["key1"], KeySettings(provider: .codex))
    }

    func testSettingsForAnUnknownKeyAreIgnored() {
        let plugin = makePlugin()
        plugin.handle(event("didReceiveSettings", context: "other", settings: ["provider": .string("codex")]))
        XCTAssertTrue(plugin.keys.isEmpty)
        XCTAssertTrue(output.messages.isEmpty)
    }

    func testOtherActionsAreIgnored() {
        let plugin = makePlugin()
        plugin.handle(event("willAppear", action: "com.example.other"))
        XCTAssertTrue(plugin.keys.isEmpty)
        XCTAssertEqual(loads, 0)
    }

    func testAnimationRedrawsOnlyAnimatingKeys() throws {
        current = snapshot([("claude", .working), ("codex", .completed)])
        let plugin = makePlugin()
        plugin.handle(event("willAppear", context: "all"))
        plugin.handle(event("willAppear", context: "codex", settings: ["provider": .string("codex")]))
        plugin.handle(event("willAppear", context: "still", settings: ["animate": .bool(false)]))
        plugin.advanceAnimation()
        plugin.advanceAnimation()

        let working = StreamDeckTile(glyph: .working, label: "Working", detail: "1 active")
        XCTAssertEqual(output.images(for: "all"),
                       [try expectedImage(working), try expectedImage(working, frame: 1), try expectedImage(working, frame: 2)])
        XCTAssertEqual(output.images(for: "codex").count, 1)
        XCTAssertEqual(output.images(for: "still"), [try expectedImage(working)])
    }

    func testKeyPressOpensSidePulse() {
        let plugin = makePlugin()
        plugin.handle(event("willAppear"))
        output.messages.removeAll()
        plugin.handle(event("keyDown"))
        XCTAssertEqual(opens, 1)
        XCTAssertFalse(output.events.contains("showAlert"))
    }

    func testFailedPressShowsAnAlertAndLogs() {
        outcome = .headless
        let plugin = makePlugin()
        plugin.handle(event("keyDown"))
        XCTAssertEqual(output.events, ["logMessage", "showAlert"])
        XCTAssertEqual(output.messages.last?["context"], .string("key1"))
    }

    func testPressWithoutTheAppOpensTheDownloadPage() {
        outcome = .appNotFound
        let plugin = makePlugin()
        plugin.handle(event("keyDown"))
        XCTAssertEqual(output.events, ["logMessage", "openUrl"])
        XCTAssertEqual(output.messages.last?["payload"]?["url"], .string(StatusPlugin.downloadURL))
    }
}
