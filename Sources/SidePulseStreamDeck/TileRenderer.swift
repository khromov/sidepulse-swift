import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SidePulseCore

/// Draws on a 144-point canvas, Stream Deck's @2x key size. The glyphs are drawn here rather than taken from
/// SF Symbols, whose license excludes artwork such as the Marketplace listing's.
public enum TileRenderer {
    public static let canvas: CGFloat = 144
    public static let frameCount = 4
    /// Two frames a second, so a few animated keys stay under Elgato's guideline of 10 updates a second.
    public static let frameInterval: TimeInterval = 0.5

    struct Color {
        var red: CGFloat, green: CGFloat, blue: CGFloat

        init(hex: UInt32) {
            red = CGFloat((hex >> 16) & 0xFF) / 255
            green = CGFloat((hex >> 8) & 0xFF) / 255
            blue = CGFloat(hex & 0xFF) / 255
        }

        func cg(alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    }

    static let white = Color(hex: 0xFFFFFF)
    static let secondaryText = Color(hex: 0xA1A1A6)
    static let pulse = Color(hex: 0x22D3EE)

    static func color(for glyph: StreamDeckTile.Glyph) -> Color {
        switch glyph {
        case .ask: return Color(hex: 0xFF9F0A)
        case .working: return Color(hex: 0x0A84FF)
        case .done: return Color(hex: 0x30D158)
        case .idle: return Color(hex: 0x8E8E93)
        case .off: return Color(hex: 0x636366)
        }
    }

    // MARK: Keys

    public static func keyPNG(_ tile: StreamDeckTile, frame: Int = 0, pixels: Int = 144) -> Data? {
        render(pixels: pixels) { context in
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
            drawKey(tile, frame: tile.animates ? frame % frameCount : 0, in: context)
        }
    }

    static func drawKey(_ tile: StreamDeckTile, frame: Int, in context: CGContext) {
        let color = color(for: tile.glyph)
        let hasHeading = tile.heading != nil
        let radius: CGFloat = hasHeading ? 22 : 26
        // Top-down layout positions, converted because Core Graphics counts y from the bottom.
        let center = CGPoint(x: canvas / 2, y: canvas - (hasHeading ? 62 : 54))
        let motion = motion(for: tile.glyph, frame: frame)

        if tile.glyph != .idle, tile.glyph != .off {
            drawGlow(at: center, radius: radius * 2.1, color: color, alpha: 0.30 * motion.glow, in: context)
        }
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: motion.rotation)
        context.scaleBy(x: motion.scale, y: motion.scale)
        context.setAlpha(motion.opacity)
        drawGlyph(tile.glyph, radius: radius, color: color.cg(), in: context)
        context.restoreGState()

        if let heading = tile.heading {
            drawText(heading, size: 17, bold: false, color: secondaryText, baselineFromTop: 24, in: context)
        }
        drawText(tile.label, size: 26, bold: true, color: white, baselineFromTop: tile.detail == nil ? 118 : 110,
                 in: context)
        if let detail = tile.detail {
            drawText(detail, size: 19, bold: false, color: secondaryText, baselineFromTop: 134, in: context)
        }
    }

    struct Motion {
        var rotation: CGFloat = 0
        var scale: CGFloat = 1
        var opacity: CGFloat = 1
        var glow: CGFloat = 1
    }

    /// Working turns clockwise, a half turn per cycle because its two arrows look the same after one; Ask pulses.
    static func motion(for glyph: StreamDeckTile.Glyph, frame: Int) -> Motion {
        let phase = CGFloat(frame) / CGFloat(frameCount)
        switch glyph {
        case .working:
            return Motion(rotation: -phase * .pi)
        case .ask:
            let depth = (1 - cos(phase * 2 * .pi)) / 2
            return Motion(scale: 1 - 0.14 * depth, opacity: 1 - 0.5 * depth, glow: 1 - 0.7 * depth)
        case .idle, .done, .off:
            return Motion()
        }
    }

    // MARK: Glyphs

    static func drawGlyph(_ glyph: StreamDeckTile.Glyph, radius: CGFloat, color: CGColor, in context: CGContext) {
        let line = radius * 0.17
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(line)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch glyph {
        case .idle:
            context.strokeEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        case .done:
            context.strokeEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
            context.move(to: CGPoint(x: -0.42 * radius, y: 0.02 * radius))
            context.addLine(to: CGPoint(x: -0.12 * radius, y: -0.30 * radius))
            context.addLine(to: CGPoint(x: 0.44 * radius, y: 0.32 * radius))
            context.strokePath()
        case .ask:
            context.strokeEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
            drawCenteredGlyphText("?", size: radius * 1.25, color: color, in: context)
        case .working:
            drawCircularArrows(radius: radius, line: line, in: context)
        case .off:
            let gap: CGFloat = .pi / 5
            context.addArc(center: .zero, radius: radius, startAngle: .pi / 2 + gap, endAngle: .pi / 2 - gap + 2 * .pi,
                           clockwise: false)
            context.strokePath()
            context.move(to: CGPoint(x: 0, y: radius * 0.1))
            context.addLine(to: CGPoint(x: 0, y: radius * 1.05))
            context.strokePath()
        }
    }

    /// Two arcs whose heads point clockwise, the direction the Working key turns.
    static func drawCircularArrows(radius: CGFloat, line: CGFloat, in context: CGContext) {
        for half in 0..<2 {
            let head = CGFloat(half) * .pi + .pi / 6
            let tail = head + .pi * 0.62
            context.addArc(center: .zero, radius: radius, startAngle: tail, endAngle: head + 0.18, clockwise: true)
            context.strokePath()
            let tip = CGPoint(x: radius * cos(head), y: radius * sin(head))
            let along = CGPoint(x: sin(head), y: -cos(head))
            let out = CGPoint(x: cos(head), y: sin(head))
            let size = line * 2.1
            context.move(to: CGPoint(x: tip.x + along.x * size, y: tip.y + along.y * size))
            context.addLine(to: CGPoint(x: tip.x + out.x * size - along.x * size * 0.35,
                                        y: tip.y + out.y * size - along.y * size * 0.35))
            context.addLine(to: CGPoint(x: tip.x - out.x * size - along.x * size * 0.35,
                                        y: tip.y - out.y * size - along.y * size * 0.35))
            context.closePath()
            context.fillPath()
        }
    }

    static func drawGlow(at center: CGPoint, radius: CGFloat, color: Color, alpha: CGFloat, in context: CGContext) {
        guard alpha > 0,
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [color.cg(alpha: alpha), color.cg(alpha: 0)] as CFArray,
                                        locations: [0, 1]) else { return }
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                   endRadius: radius, options: [])
    }

    // MARK: Text

    static func font(size: CGFloat, bold: Bool) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    static func line(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
        return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes))
    }

    static func drawText(_ text: String, size: CGFloat, bold: Bool, color: Color, baselineFromTop: CGFloat,
                         in context: CGContext) {
        drawText(text, size: size, bold: bold, color: color.cg(), centerX: canvas / 2,
                 baseline: canvas - baselineFromTop, maxWidth: canvas - 12, in: context)
    }

    /// Shrinks the font when the text is wider than `maxWidth`.
    static func drawText(_ text: String, size: CGFloat, bold: Bool, color: CGColor, centerX: CGFloat, baseline: CGFloat,
                         maxWidth: CGFloat, in context: CGContext) {
        var current = line(text, font: font(size: size, bold: bold), color: color)
        var width = CGFloat(CTLineGetTypographicBounds(current, nil, nil, nil))
        if width > maxWidth {
            current = line(text, font: font(size: size * maxWidth / width, bold: bold), color: color)
            width = CGFloat(CTLineGetTypographicBounds(current, nil, nil, nil))
        }
        context.textPosition = CGPoint(x: centerX - width / 2, y: baseline)
        CTLineDraw(current, context)
    }

    /// Centers the ink, not the line box, so the mark sits in the middle of its ring.
    static func drawCenteredGlyphText(_ text: String, size: CGFloat, color: CGColor, in context: CGContext) {
        let current = line(text, font: font(size: size, bold: true), color: color)
        context.textPosition = .zero
        let bounds = CTLineGetImageBounds(current, context)
        context.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
        CTLineDraw(current, context)
    }

    // MARK: Bitmaps

    /// Draws on the 144-point canvas scaled to `pixels` square.
    static func render(pixels: Int, draw: (CGContext) -> Void) -> Data? {
        render(width: pixels, height: pixels, scale: CGFloat(pixels) / canvas, draw: draw)
    }

    static func render(width: Int, height: Int, scale: CGFloat, draw: (CGContext) -> Void) -> Data? {
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        draw(context)
        guard let image = context.makeImage() else { return nil }
        return pngData(image)
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    public static func dataURL(png: Data) -> String {
        "data:image/png;base64," + png.base64EncodedString()
    }
}
