import XCTest
import SidePulseCore
@testable import SidePulseStreamDeck

/// `streamdeck validate` checks the built folder; these pin what the Swift code and the manifest must agree on.
final class ManifestTests: XCTestCase {
    private let pluginDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("StreamDeck/io.sidepulse.swift.streamdeck.sdPlugin", isDirectory: true)

    private func manifest() throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: pluginDir.appendingPathComponent("manifest.json")))
    }

    func testIdentifiers() throws {
        let manifest = try manifest()
        let uuid = try XCTUnwrap(manifest["UUID"]?.stringValue)
        XCTAssertEqual(uuid, pluginDir.deletingPathExtension().lastPathComponent)
        let actions = try XCTUnwrap(manifest["Actions"]?.arrayValue)
        XCTAssertEqual(actions.compactMap { $0["UUID"]?.stringValue }, [StatusPlugin.actionUUID])
        XCTAssertTrue(StatusPlugin.actionUUID.hasPrefix(uuid + "."))
    }

    /// The Marketplace takes new plugins and updates only with SDK 3 and Stream Deck 6.9 or later.
    func testMarketplaceRequirements() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest["SDKVersion"]?.intValue, 3)
        let minimum = try XCTUnwrap(manifest["Software"]?["MinimumVersion"]?.stringValue)
        XCTAssertTrue(minimum.compare("6.9", options: .numeric) != .orderedAscending, minimum)
        let version = try XCTUnwrap(manifest["Version"]?.stringValue)
        XCTAssertNotNil(version.range(of: #"^(0|[1-9]\d*)(\.(0|[1-9]\d*)){3}$"#, options: .regularExpression), version)
        XCTAssertEqual(manifest["Category"], manifest["Name"])
        XCTAssertEqual(manifest["OS"]?.arrayValue?.compactMap { $0["Platform"]?.stringValue }, ["mac"])
    }

    func testImagesAreTheGeneratedAssets() throws {
        let manifest = try manifest()
        let action = try XCTUnwrap(manifest["Actions"]?.arrayValue?.first)
        let referenced = [manifest["Icon"], manifest["CategoryIcon"], action["Icon"]] + (action["States"]?.arrayValue ?? []).map { $0["Image"] }
        XCTAssertEqual(Set(referenced.compactMap { $0?.stringValue }), Set(PluginAssets.all.map(\.path)))
    }

    func testCodePathAndPropertyInspector() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest["CodePath"], .string("bin/sidepulse-streamdeck"))
        let action = try XCTUnwrap(manifest["Actions"]?.arrayValue?.first)
        let inspector = try XCTUnwrap(action["PropertyInspectorPath"]?.stringValue)
        let html = try String(contentsOf: pluginDir.appendingPathComponent(inspector), encoding: .utf8)
        XCTAssertTrue(html.contains("connectElgatoStreamDeckSocket"))
        for key in [KeySettings.providerKey, KeySettings.animateKey] {
            XCTAssertTrue(html.contains("settings.\(key)"), key)
        }
        for provider in HookProvider.allCases {
            XCTAssertTrue(html.contains("value=\"\(provider.rawValue)\""), provider.rawValue)
        }
        XCTAssertTrue(html.contains(StatusPlugin.downloadURL))
    }
}
