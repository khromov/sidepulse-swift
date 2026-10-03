import AppKit
import SidePulseCore

/// Core Animation plays the status icon's animation in the window server, so the app does no work per frame.
@MainActor
final class AnimatedIconView: NSView {
    private let iconLayer = CALayer()
    private let shapeLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shapeLayer.contentsGravity = .resizeAspect
        iconLayer.mask = shapeLayer
        layer?.addSublayer(iconLayer)
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The icon is a template image used as a mask, so its color has to follow the menu bar's appearance here.
    override func updateLayer() {
        withoutImplicitAnimations { iconLayer.backgroundColor = NSColor.labelColor.cgColor }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        shapeLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func layout() {
        super.layout()
        let side = IconAnimation.canvasSize
        let rect = backingAlignedRect(NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side),
                                      options: .alignAllEdgesNearest)
        withoutImplicitAnimations {
            iconLayer.bounds = CGRect(origin: .zero, size: rect.size)
            iconLayer.position = CGPoint(x: rect.midX, y: rect.midY)
            shapeLayer.frame = iconLayer.bounds
        }
    }

    func play(_ state: DisplayState) {
        guard let animation = Self.animation(for: state) else { return stop() }
        withoutImplicitAnimations { shapeLayer.contents = IconRenderer.image(for: state) }
        iconLayer.add(animation, forKey: "icon")
        isHidden = false
    }

    func stop() {
        iconLayer.removeAllAnimations()
        isHidden = true
    }

    private func withoutImplicitAnimations(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private static func animation(for state: DisplayState) -> CAAnimation? {
        switch state {
        case .working:
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = IconAnimation.cycleSeconds
            spin.repeatCount = .infinity
            return spin
        case .ask:
            let low = IconAnimation.frame(for: .ask, index: 1)
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.toValue = low.scale
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.toValue = low.opacity
            let pulse = CAAnimationGroup()
            pulse.animations = [scale, fade]
            pulse.duration = IconAnimation.cycleSeconds / 2
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return pulse
        case .idle, .done:
            return nil
        }
    }
}
