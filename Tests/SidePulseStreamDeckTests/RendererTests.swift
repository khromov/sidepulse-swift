import ImageIO
import XCTest
import SidePulseCore
@testable import SidePulseStreamDeck

final class RendererTests: XCTestCase {
    private func size(of png: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    private let tiles: [StreamDeckTile] = [
        StreamDeckTile(glyph: .error, label: "Error", detail: "1 active"),
        StreamDeckTile(glyph: .ask, label: "Ask", detail: "2 active"),
        StreamDeckTile(glyph: .working, heading: "Claude Code", label: "Working", detail: "1 active"),
        StreamDeckTile(glyph: .done, heading: "Codex", label: "Done"),
        StreamDeckTile(glyph: .idle, label: "Idle"),
        StreamDeckTile(glyph: .off, label: "Off", detail: "Press to start"),
    ]

    func testEveryTileRendersAtKeySize() throws {
        for tile in tiles {
            let png = try XCTUnwrap(TileRenderer.keyPNG(tile), tile.label)
            XCTAssertEqual(size(of: png), CGSize(width: 144, height: 144), tile.label)
        }
        XCTAssertEqual(size(of: try XCTUnwrap(TileRenderer.keyPNG(tiles[0], pixels: 72))), CGSize(width: 72, height: 72))
    }

    func testOnlyAnimatingTilesChangeBetweenFrames() {
        for tile in tiles {
            let frames = Set((0..<TileRenderer.frameCount).compactMap { TileRenderer.keyPNG(tile, frame: $0) })
            // Ask pulses symmetrically, so its way in and way out share frames.
            if tile.animates { XCTAssertGreaterThan(frames.count, 1, tile.label) } else { XCTAssertEqual(frames.count, 1, tile.label) }
        }
    }

    /// The top-left pixel as 8-bit RGB.
    private func corner(of png: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 1 - image.height, width: image.width, height: image.height))
        guard let data = context.data else { return nil }
        let pixel = data.bindMemory(to: UInt8.self, capacity: 4)
        return [pixel[0], pixel[1], pixel[2]]
    }

    func testOnlyAskAndErrorFillTheKey() throws {
        let fills: [StreamDeckTile.Glyph: [UInt8]] = [.ask: [0xFF, 0x9F, 0x0A], .error: [0xFF, 0x45, 0x3A]]
        for tile in tiles {
            let pixel = try XCTUnwrap(corner(of: try XCTUnwrap(TileRenderer.keyPNG(tile))), tile.label)
            XCTAssertEqual(pixel, fills[tile.glyph] ?? [0, 0, 0], tile.label)
        }
    }

    func testAnimationStaysUnderElgatosUpdateGuideline() {
        XCTAssertLessThanOrEqual(1 / TileRenderer.frameInterval, 2)
    }

    func testDataURL() {
        XCTAssertEqual(TileRenderer.dataURL(png: Data([1, 2, 3])), "data:image/png;base64,AQID")
    }

    func testPluginAssetsHaveTheManifestSizes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try PluginAssets.write(to: directory)
        let expected = ["imgs/plugin/icon": 256, "imgs/plugin/category": 28, "imgs/actions/status/icon": 20,
                        "imgs/actions/status/key": 72]
        XCTAssertEqual(Set(PluginAssets.all.map(\.path)), Set(expected.keys))
        for (path, points) in expected {
            for (suffix, scale) in [("", 1), ("@2x", 2)] {
                let png = try Data(contentsOf: directory.appendingPathComponent(path + suffix + ".png"))
                XCTAssertEqual(size(of: png), CGSize(width: points * scale, height: points * scale), path + suffix)
            }
        }
    }

    func testMarketplaceImagesHaveTheListingSizes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try MarketplaceAssets.write(to: directory)
        XCTAssertEqual(size(of: try Data(contentsOf: directory.appendingPathComponent("icon.png"))),
                       CGSize(width: 288, height: 288))
        let wide = MarketplaceAssets.all.filter { $0.name != "icon.png" }
        XCTAssertGreaterThanOrEqual(wide.count, 4, "a thumbnail and at least three gallery images")
        for image in wide {
            XCTAssertEqual(size(of: try Data(contentsOf: directory.appendingPathComponent(image.name))),
                           CGSize(width: 1920, height: 960), image.name)
        }
    }
}
