import Cocoa

/// A fixed-size horizon and an accessible Level action, outside captured pixels.
final class AttitudeIndicatorButton: NSButton {
    private var pitch = 0.0, roll = 0.0
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        isBordered = false
        setAccessibilityLabel("Level device")
        toolTip = "Current pitch and roll. Click to level the device."
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    func update(pitch: Double, roll: Double) {
        guard pitch != self.pitch || roll != self.roll else { return }
        self.pitch = pitch; self.roll = roll
        setAccessibilityValue(String(format: "Pitch %.0f°, roll %.0f°", pitch * 180 / .pi, roll * 180 / .pi))
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        NSColor(white: isHighlighted ? 0.25 : 0.12, alpha: 0.9).setFill()
        circle.fill(); circle.addClip()
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.midX, yBy: bounds.midY)
        transform.rotate(byRadians: -roll)
        transform.translateX(by: 0, yBy: min(max(pitch / (.pi / 4), -1), 1) * 12)
        transform.concat()
        NSColor(white: 0.35, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: -40, y: -40, width: 80, height: 40)).fill()
        NSColor.white.setStroke()
        let horizon = NSBezierPath()
        horizon.move(to: NSPoint(x: -40, y: 0)); horizon.line(to: NSPoint(x: 40, y: 0))
        horizon.lineWidth = 1.5; horizon.stroke()
        transform.invert(); transform.concat()
        let reference = NSBezierPath()
        reference.move(to: NSPoint(x: 9, y: bounds.midY)); reference.line(to: NSPoint(x: 15, y: bounds.midY))
        reference.move(to: NSPoint(x: 25, y: bounds.midY)); reference.line(to: NSPoint(x: 31, y: bounds.midY))
        reference.lineWidth = 3; reference.stroke()
    }
}
