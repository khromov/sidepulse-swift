import AppKit
import SidePulseCore

/// Template images for the status item and the session-row glyphs: the state's SF
/// Symbol drawn aspect-fit at 15×15 in the centre of an 18×18 canvas, so static and
/// animated frames always have the same size. Each image is rendered once into
/// 1x and 2x bitmaps and cached (a state has at most `IconAnimation.frameCount`
/// frames); template images follow the menu bar's appearance by themselves.
@MainActor
enum IconRenderer {
    private static var cache: [String: NSImage] = [:]

    /// `frame` is an animation frame index (see `IconAnimation`); nil, or a state that
    /// does not animate, gives the static image.
    static func image(for state: DisplayState, frame: Int? = nil) -> NSImage {
        let index = StatusBarPresentation.animates(state) ? frame.map { $0 % IconAnimation.frameCount } : nil
        let key = "\(state.rawValue):\(index ?? -1)"
        if let cached = cache[key] { return cached }
        let transform = index.map { IconAnimation.frame(for: state, index: $0) } ?? .identity
        let image = render(state: state, transform: transform)
        cache[key] = image
        return image
    }

    private static func render(state: DisplayState, transform: IconFrame) -> NSImage {
        let side = IconAnimation.canvasSize
        let image = NSImage(size: NSSize(width: side, height: side))
        if let symbol = NSImage(systemSymbolName: state.symbolName, accessibilityDescription: state.label) {
            for scale in [1.0, 2.0] {
                if let bitmap = bitmap(symbol, transform: transform, side: side, scale: scale) {
                    image.addRepresentation(bitmap)
                }
            }
        }
        image.isTemplate = true
        image.accessibilityDescription = state.label
        return image
    }

    private static func bitmap(_ symbol: NSImage, transform: IconFrame, side: Double, scale: Double) -> NSBitmapImageRep? {
        let pixels = Int(side * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let affine = NSAffineTransform()
        affine.scale(by: scale)
        affine.translateX(by: side / 2, yBy: side / 2)
        affine.rotate(byDegrees: transform.rotationDegrees)
        affine.scale(by: transform.scale)
        affine.concat()
        let fit = aspectFit(symbol.size, into: IconAnimation.symbolSize)
        let rect = NSRect(x: -fit.width / 2, y: -fit.height / 2, width: fit.width, height: fit.height)
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: transform.opacity)
        return rep
    }

    private static func aspectFit(_ size: NSSize, into side: Double) -> NSSize {
        guard size.width > 0, size.height > 0 else { return NSSize(width: side, height: side) }
        let scale = side / max(size.width, size.height)
        return NSSize(width: size.width * scale, height: size.height * scale)
    }
}
