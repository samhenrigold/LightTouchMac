import Cocoa

/// The drop-target cue (HIG p.294): an accent ring just inside a view while a
/// drag it will accept is over it. It never takes clicks or drags itself.
final class DropHighlight: NSView {
    /// Pinned over `view`, above its subviews, hidden until a drag is accepted.
    static func install(in view: NSView) -> DropHighlight {
        let ring = DropHighlight(frame: view.bounds)
        ring.autoresizingMask = [.width, .height]
        ring.isHidden = true
        view.addSubview(ring, positioned: .above, relativeTo: nil)
        return ring
    }

    /// Shows the ring for an accepted operation; returns it for the dragging method to hand back.
    @discardableResult
    func show(for operation: NSDragOperation) -> NSDragOperation {
        isHidden = operation.isEmpty
        if !isHidden, let parent = superview, parent.subviews.last !== self {
            parent.addSubview(self, positioned: .above, relativeTo: nil)   // stay above later subviews
        }
        return operation
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        ring.lineWidth = 3
        ring.stroke()
    }
}
