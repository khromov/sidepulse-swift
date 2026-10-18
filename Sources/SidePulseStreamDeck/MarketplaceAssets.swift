import CoreGraphics
import CoreText
import Foundation
import SidePulseCore

/// The Marketplace listing's images (288 × 288 icon, 1920 × 960 thumbnail and gallery), drawn with the live
/// key renderer so the listing shows exactly what the keys show.
public enum MarketplaceAssets {
    public struct Image {
        public var name: String
        public var width: Int
        public var height: Int
        public var draw: (CGContext) -> Void
    }

    static let wide = CGSize(width: 1920, height: 960)

    public static let all: [Image] = [
        Image(name: "icon.png", width: 288, height: 288) { context in
            context.scaleBy(x: 2, y: 2)
            PluginAssets.drawPluginIcon(in: context)
        },
        Image(name: "thumbnail.png", width: 1920, height: 960, draw: drawThumbnail),
        Image(name: "gallery-1-states.png", width: 1920, height: 960, draw: drawStates),
        Image(name: "gallery-2-deck.png", width: 1920, height: 960, draw: drawDeck),
        Image(name: "gallery-3-agents.png", width: 1920, height: 960, draw: drawAgents),
    ]

    public static func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for image in all {
            let url = directory.appendingPathComponent(image.name)
            guard let png = TileRenderer.render(width: image.width, height: image.height, scale: 1, draw: image.draw) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            try png.write(to: url, options: .atomic)
        }
    }

    // MARK: Pieces

    static func tile(_ glyph: StreamDeckTile.Glyph, heading: String? = nil, active: Int = 0) -> StreamDeckTile {
        switch glyph {
        case .off:
            return StreamDeckTile(glyph: .off, heading: heading, label: StreamDeckTilePresentation.offLabel,
                                  detail: StreamDeckTilePresentation.offDetail)
        case .idle, .working, .done, .ask:
            let state: DisplayState = glyph == .ask ? .ask : glyph == .working ? .working : glyph == .done ? .done : .idle
            return StreamDeckTile(glyph: glyph, heading: heading, label: state.label,
                                  detail: active > 0 ? "\(active) active" : nil)
        }
    }

    static func drawBackground(in context: CGContext) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        if let gradient = CGGradient(colorsSpace: space,
                                     colors: [CGColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1),
                                              CGColor(srgbRed: 0.03, green: 0.035, blue: 0.045, alpha: 1)] as CFArray,
                                     locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: wide.height), end: .zero, options: [])
        }
        TileRenderer.drawGlow(at: CGPoint(x: wide.width / 2, y: wide.height * 0.35), radius: 900,
                              color: TileRenderer.pulse, alpha: 0.10, in: context)
    }

    /// `origin` is the key's bottom-left corner.
    static func drawKey(_ tile: StreamDeckTile, frame: Int = 0, at origin: CGPoint, size: CGFloat, in context: CGContext) {
        let side = TileRenderer.canvas
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: size / side, y: size / side)
        let shape = CGPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerWidth: 18,
                           cornerHeight: 18, transform: nil)
        context.setShadow(offset: CGSize(width: 0, height: -4), blur: 18, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.8))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.addPath(shape)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.addPath(shape)
        context.clip()
        TileRenderer.drawKey(tile, frame: tile.animates ? frame : 0, in: context)
        context.restoreGState()
    }

    static func drawBlankKey(at origin: CGPoint, size: CGFloat, in context: CGContext) {
        let shape = CGPath(roundedRect: CGRect(origin: origin, size: CGSize(width: size, height: size)),
                           cornerWidth: size * 0.125, cornerHeight: size * 0.125, transform: nil)
        context.setFillColor(CGColor(srgbRed: 0.055, green: 0.06, blue: 0.07, alpha: 1))
        context.addPath(shape)
        context.fillPath()
    }

    static func heading(_ title: String, subtitle: String?, in context: CGContext) {
        TileRenderer.drawText(title, size: 76, bold: true, color: TileRenderer.white.cg(), centerX: wide.width / 2,
                              baseline: wide.height - 150, maxWidth: wide.width - 160, in: context)
        if let subtitle {
            TileRenderer.drawText(subtitle, size: 38, bold: false, color: TileRenderer.secondaryText.cg(),
                                  centerX: wide.width / 2, baseline: wide.height - 220, maxWidth: wide.width - 160,
                                  in: context)
        }
    }

    // MARK: Images

    static func drawThumbnail(in context: CGContext) {
        drawBackground(in: context)
        let iconSize: CGFloat = 200
        context.saveGState()
        context.translateBy(x: (wide.width - iconSize) / 2, y: wide.height - 80 - iconSize)
        context.scaleBy(x: iconSize / TileRenderer.canvas, y: iconSize / TileRenderer.canvas)
        PluginAssets.drawPluginIcon(in: context)
        context.restoreGState()
        TileRenderer.drawText("SidePulse Swift", size: 84, bold: true, color: TileRenderer.white.cg(),
                              centerX: wide.width / 2, baseline: wide.height - 380, maxWidth: wide.width - 160,
                              in: context)
        TileRenderer.drawText("Your coding agents' status on a Stream Deck key", size: 40, bold: false,
                              color: TileRenderer.secondaryText.cg(), centerX: wide.width / 2,
                              baseline: wide.height - 450, maxWidth: wide.width - 160, in: context)
        let tiles = [tile(.ask, active: 2), tile(.working, active: 1), tile(.done), tile(.idle)]
        row(tiles, size: 250, gap: 60, bottom: 110, in: context)
    }

    static func drawStates(in context: CGContext) {
        drawBackground(in: context)
        heading("Every state at a glance", subtitle: "The key shows the agent that most needs you", in: context)
        let items: [(StreamDeckTile, String)] = [
            (tile(.ask, active: 1), "An agent needs you"),
            (tile(.working, active: 2), "Agents are working"),
            (tile(.done), "A task just finished"),
            (tile(.idle), "Nothing is running"),
            (tile(.off), "SidePulse isn't running"),
        ]
        let size: CGFloat = 250, gap: CGFloat = 70, bottom: CGFloat = 300
        let positions = row(items.map(\.0), size: size, gap: gap, bottom: bottom, in: context)
        for (x, item) in zip(positions, items) {
            TileRenderer.drawText(item.1, size: 30, bold: false, color: TileRenderer.secondaryText.cg(),
                                  centerX: x + size / 2, baseline: bottom - 70, maxWidth: size + gap - 10, in: context)
        }
    }

    static func drawDeck(in context: CGContext) {
        drawBackground(in: context)
        let key: CGFloat = 140, gap: CGFloat = 28, pad: CGFloat = 56
        let body = CGRect(x: 110, y: 170, width: 5 * key + 4 * gap + 2 * pad, height: 3 * key + 2 * gap + 2 * pad)
        context.setFillColor(CGColor(srgbRed: 0.13, green: 0.135, blue: 0.15, alpha: 1))
        context.addPath(CGPath(roundedRect: body, cornerWidth: 48, cornerHeight: 48, transform: nil))
        context.fillPath()
        let tiles: [Int: StreamDeckTile] = [
            0: tile(.ask, active: 2),
            1: tile(.ask, heading: HookProvider.claude.label, active: 1),
            2: tile(.working, heading: HookProvider.codex.label, active: 1),
            3: tile(.idle, heading: HookProvider.opencode.label),
        ]
        for index in 0..<15 {
            let column = CGFloat(index % 5), row = CGFloat(2 - index / 5)
            let origin = CGPoint(x: body.minX + pad + column * (key + gap), y: body.minY + pad + row * (key + gap))
            if let tile = tiles[index] {
                drawKey(tile, at: origin, size: key, in: context)
            } else {
                drawBlankKey(at: origin, size: key, in: context)
            }
        }
        let left = body.maxX + 90, width = wide.width - left - 90
        var baseline = wide.height - 300
        for (index, text) in ["Glanceable agent status", "Claude Code, Codex and OpenCode",
                              "Press the key to open SidePulse", "Needs the free SidePulse Swift app"].enumerated() {
            let size: CGFloat = index == 0 ? 64 : 38
            let color = index == 0 ? TileRenderer.white.cg() : TileRenderer.secondaryText.cg()
            leftText(text, size: size, bold: index == 0, color: color, x: left, baseline: baseline, maxWidth: width,
                     in: context)
            baseline -= index == 0 ? 110 : 70
        }
    }

    static func drawAgents(in context: CGContext) {
        drawBackground(in: context)
        heading("Follow one agent per key", subtitle: "Choose all agents or a single one in each key's settings",
                in: context)
        let tiles = [tile(.working, heading: HookProvider.claude.label, active: 1),
                     tile(.ask, heading: HookProvider.codex.label, active: 1),
                     tile(.done, heading: HookProvider.opencode.label)]
        row(tiles, size: 320, gap: 90, bottom: 170, in: context)
    }

    /// Centers the keys horizontally and returns each key's left edge.
    @discardableResult
    static func row(_ tiles: [StreamDeckTile], size: CGFloat, gap: CGFloat, bottom: CGFloat, in context: CGContext) -> [CGFloat] {
        let total = CGFloat(tiles.count) * size + CGFloat(max(0, tiles.count - 1)) * gap
        let start = (wide.width - total) / 2
        return tiles.enumerated().map { index, tile in
            let x = start + CGFloat(index) * (size + gap)
            drawKey(tile, at: CGPoint(x: x, y: bottom), size: size, in: context)
            return x
        }
    }

    static func leftText(_ text: String, size: CGFloat, bold: Bool, color: CGColor, x: CGFloat, baseline: CGFloat,
                         maxWidth: CGFloat, in context: CGContext) {
        let width = min(maxWidth, CGFloat(CTLineGetTypographicBounds(
            TileRenderer.line(text, font: TileRenderer.font(size: size, bold: bold), color: color), nil, nil, nil)))
        TileRenderer.drawText(text, size: size, bold: bold, color: color, centerX: x + width / 2, baseline: baseline,
                              maxWidth: maxWidth, in: context)
    }
}
