import XCTest
import SidePulseCore
@testable import SidePulseStreamDeck

final class ProtocolTests: XCTestCase {
    func testParsesStreamDeckLaunchArguments() {
        let info = #"{"plugin":{"uuid":"io.sidepulse.swift.streamdeck","version":"1.0.0.0"}}"#
        let parsed = StreamDeckArguments.parse(["-port", "28196", "-pluginUUID", "abc", "-registerEvent", "registerPlugin",
                                                "-info", info])
        XCTAssertEqual(parsed?.port, 28196)
        XCTAssertEqual(parsed?.pluginUUID, "abc")
        XCTAssertEqual(parsed?.registerEvent, "registerPlugin")
        XCTAssertEqual(parsed?.info?["plugin"]?["version"], .string("1.0.0.0"))
    }

    func testRejectsIncompleteArguments() {
        XCTAssertNil(StreamDeckArguments.parse([]))
        XCTAssertNil(StreamDeckArguments.parse(["-port", "28196", "-pluginUUID", "abc"]))
        XCTAssertNil(StreamDeckArguments.parse(["-port", "0", "-pluginUUID", "abc", "-registerEvent", "r"]))
        XCTAssertNil(StreamDeckArguments.parse(["-port", "x", "-pluginUUID", "abc", "-registerEvent", "r"]))
        XCTAssertNil(StreamDeckArguments.parse(["-port", "1", "-pluginUUID", "abc", "-registerEvent"]))
    }

    func testUnparseableInfoIsIgnored() {
        let parsed = StreamDeckArguments.parse(["-port", "1", "-pluginUUID", "u", "-registerEvent", "r", "-info", "{"])
        XCTAssertNotNil(parsed)
        XCTAssertNil(parsed?.info)
    }

    func testParsesEvents() {
        let text = #"""
        {"action":"io.sidepulse.swift.streamdeck.status","event":"willAppear","context":"ctx","device":"dev",
         "payload":{"settings":{"provider":"codex"},"coordinates":{"column":1,"row":0},"controller":"Keypad"}}
        """#
        let event = StreamDeckEvent.parse(text)
        XCTAssertEqual(event?.event, "willAppear")
        XCTAssertEqual(event?.action, StatusPlugin.actionUUID)
        XCTAssertEqual(event?.context, "ctx")
        XCTAssertEqual(event?.device, "dev")
        XCTAssertEqual(event?.settings["provider"], .string("codex"))

        XCTAssertEqual(StreamDeckEvent.parse(#"{"event":"systemDidWakeUp"}"#)?.settings, JSONObject())
        XCTAssertNil(StreamDeckEvent.parse(#"{"context":"ctx"}"#))
        XCTAssertNil(StreamDeckEvent.parse("not json"))
    }

    func testCommandsMatchTheSDKShapes() {
        XCTAssertEqual(JSONValue.object(StreamDeckCommand.register(event: "registerPlugin", uuid: "u")).serialized(),
                       #"{"event":"registerPlugin","uuid":"u"}"#)
        XCTAssertEqual(JSONValue.object(StreamDeckCommand.setImage(context: "c", image: "data:x")).serialized(),
                       #"{"event":"setImage","context":"c","payload":{"image":"data:x","target":0}}"#)
        XCTAssertEqual(JSONValue.object(StreamDeckCommand.showAlert(context: "c")).serialized(),
                       #"{"event":"showAlert","context":"c"}"#)
        XCTAssertEqual(JSONValue.object(StreamDeckCommand.openURL("https://x")).serialized(),
                       #"{"event":"openUrl","payload":{"url":"https://x"}}"#)
        XCTAssertEqual(JSONValue.object(StreamDeckCommand.logMessage("m")).serialized(),
                       #"{"event":"logMessage","payload":{"message":"m"}}"#)
    }

    func testKeySettingsDefaults() {
        XCTAssertEqual(KeySettings(JSONObject()), KeySettings(provider: nil, animate: true))
        XCTAssertEqual(KeySettings(["provider": .string("opencode"), "animate": .bool(false)]),
                       KeySettings(provider: .opencode, animate: false))
        XCTAssertEqual(KeySettings(["provider": .string("all")]).provider, nil)
    }
}
