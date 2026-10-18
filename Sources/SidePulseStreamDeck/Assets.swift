import CoreGraphics
import Foundation
import SidePulseCore

/// The manifest's images, generated at build time by the same renderer as the live keys, in the sizes and
/// colors Elgato's manifest schema requires.
public enum PluginAssets {
    public struct Asset {
        /// Manifest path, with no extension.
        public var path: String
        public var points: Int
        public var draw: (CGContext) -> Void
    }

    public static let all: [Asset] = [
        Asset(path: "imgs/plugin/icon", points: 256, draw: drawPluginIcon),
        Asset(path: "imgs/plugin/category", points: 28) { drawPulse(in: $0, color: TileRenderer.white.cg(), width: 13) },
        Asset(path: "imgs/actions/status/icon", points: 20, draw: drawActionIcon),
        Asset(path: "imgs/actions/status/key", points: 72) { context in
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: TileRenderer.canvas, height: TileRenderer.canvas))
            TileRenderer.drawKey(defaultKey, frame: 0, in: context)
        },
    ]

    public static let defaultKey = StreamDeckTile(glyph: .idle, label: DisplayState.idle.label)

    /// Writes `<path>.png` and `<path>@2x.png` for every asset.
    public static func write(to directory: URL) throws {
        for asset in all {
            for (suffix, scale) in [("", 1), ("@2x", 2)] {
                let url = directory.appendingPathComponent(asset.path + suffix + ".png")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard let png = TileRenderer.render(pixels: asset.points * scale, draw: asset.draw) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
                }
                try png.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: Drawings (on the 144-point canvas)

    static let pulsePoints: [CGPoint] = [
        CGPoint(x: 14, y: 72), CGPoint(x: 46, y: 72), CGPoint(x: 58, y: 100), CGPoint(x: 76, y: 36),
        CGPoint(x: 90, y: 88), CGPoint(x: 98, y: 72), CGPoint(x: 130, y: 72),
    ]

    static func drawPulse(in context: CGContext, color: CGColor, width: CGFloat) {
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addLines(between: pulsePoints)
        context.strokePath()
    }

    static func drawPluginIcon(in context: CGContext) {
        let side = TileRenderer.canvas
        let shape = CGPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerWidth: side * 0.22,
                           cornerHeight: side * 0.22, transform: nil)
        context.saveGState()
        context.addPath(shape)
        context.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [CGColor(srgbRed: 0.13, green: 0.15, blue: 0.19, alpha: 1),
                                              CGColor(srgbRed: 0.03, green: 0.04, blue: 0.06, alpha: 1)] as CFArray,
                                     locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: side), end: CGPoint(x: 0, y: 0), options: [])
        }
        context.setShadow(offset: .zero, blur: 14, color: TileRenderer.pulse.cg(alpha: 0.9))
        drawPulse(in: context, color: TileRenderer.pulse.cg(), width: 9)
        context.restoreGState()
    }

    static func drawActionIcon(in context: CGContext) {
        let center = TileRenderer.canvas / 2
        context.setStrokeColor(TileRenderer.white.cg())
        context.setFillColor(TileRenderer.white.cg())
        context.setLineWidth(16)
        context.strokeEllipse(in: CGRect(x: 14, y: 14, width: 116, height: 116))
        context.fillEllipse(in: CGRect(x: center - 26, y: center - 26, width: 52, height: 52))
    }
}
