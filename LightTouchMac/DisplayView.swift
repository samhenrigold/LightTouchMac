// Created by Sam on 2026-08-05.
//
// The device screen: a dedicated content sublayer shows the emulator's
// published frame buffer (no copy — the frame ring keeps each buffer alive for
// several frames). A display link polls for new frames; the serial check makes
// idle ticks free. The frame is laid out either scaled to fit the pane, or at
// the original device's true physical size — sizing is driven by the screen
// content alone (consistent margins in both orientations), and the shell
// chrome is locked to the same scale and may spill past the pane edges. The
// shell image is opaque (no cutout transparency — a 1px seam would flicker
// through), so the content layer draws on top of it and rotates in lockstep,
// animated, whenever the guest's frame buffer orientation flips. Mouse events
// become single-finger touches, Option-drag a two-finger pinch, and when this
// view is first responder key events are forwarded to the guest.

import Cocoa

enum ScaleMode {
    case actual   // the original device's real-world physical dimensions
    case zoomed   // enlarged to a comfortable fraction of the pane height
}

final class DisplayView: NSView {

    /// The original hardware: iPod touch 2G, 320×480 at 163 ppi (3.5" panel).
    /// The live frame buffer swaps to 480×320 on rotation.
    private static let nativeScreenPixels = CGSize(width: 320, height: 480)
    private static let devicePPI = 163.0

    /// The shell.png asset: its full pixel size, the screen cutout rect within
    /// it (top-left origin, matching this view's isFlipped space), and the
    /// home button circle — all in the shell image's own native (portrait,
    /// unrotated) pixel space.
    private static let shellPixels = CGSize(width: 737, height: 1318)
    private static let screenCutout = CGRect(x: 74, y: 213, width: 594, height: 891)
    private static let homeButtonDiameter: CGFloat = 122
    private static let homeButtonBottomInset: CGFloat = 54

    /// Whatever the guest is actually sending right now — swaps on rotation.
    private var framePixels = nativeScreenPixels
    /// nil until the first layout, so the initial appearance never "rotates in".
    private var lastIsLandscape: Bool?

    /// Set by the owner so key/drop events can reach the guest.
    weak var emulator: EmulatorController?
    /// Called when an .ipa is dropped on the screen.
    var onDropIPA: ((URL) -> Void)?

    /// Fraction of the pane (whichever axis binds) the shell fills when zoomed
    /// — ~15% margin all round.
    private static let zoomMarginFraction = 0.85
    /// How long the shell + screen take to swing between portrait and landscape.
    private static let rotationDuration = 0.35

    var scaleMode: ScaleMode = .zoomed {
        didSet { needsLayout = true }
    }

    private let contentLayer = CALayer()
    private let shellLayer = CALayer()
    private let homeButton = HomeButton()
    private var displayLink: CADisplayLink?
    private var serial: UInt64 = 0
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var lastImage: CGImage?
    private var pinching = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The pane background is the gradient asset, scaled to fill; the shell
        // and screen content sit centred on top of it.
        if let gradient = NSImage(named: "gradient")?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) {
            layer?.contents = gradient
            layer?.contentsGravity = .resizeAspectFill
        } else {
            layer?.backgroundColor = NSColor.black.cgColor
        }
        layer?.masksToBounds = true

        shellLayer.contents = NSImage(named: "shell")?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
        shellLayer.contentsGravity = .resize
        layer?.addSublayer(shellLayer)

        contentLayer.magnificationFilter = .nearest
        // The shell is opaque now, so the LCD draws on top of it, sized in
        // layout() to exactly the visible screen rect. Black backing shows a
        // powered-on device screen during boot, before the first guest frame.
        contentLayer.contentsGravity = .resize
        contentLayer.backgroundColor = NSColor.black.cgColor
        contentLayer.anchorPoint = .zero
        layer?.addSublayer(contentLayer)

        homeButton.target = self
        homeButton.action = #selector(homeTapped)
        addSubview(homeButton)

        registerForDraggedTypes([.fileURL])
        setAccessibilityLabel("iPod touch screen")
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }          // y-down, matching the guest
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
        // A move to a screen with a different physical PPI changes the accurate size.
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSWindow.didChangeScreenNotification,
                                               object: window)
    }

    @objc private func screenChanged() { needsLayout = true }

    @objc private func homeTapped() { emulator?.pressHome() }

    // MARK: - Layout

    /// Everything below is worked out relative to the shell's own centre, in
    /// its native (portrait, unrotated) pixel space, then rotated as a unit
    /// into view space — that's what keeps the screen cutout and home button
    /// locked to the shell as it swings between orientations.
    override func layout() {
        super.layout()
        let isLandscape = framePixels.width > framePixels.height
        let orientationChanged = lastIsLandscape.map { $0 != isLandscape } ?? false
        lastIsLandscape = isLandscape

        let cutoutSize = isLandscape
            ? CGSize(width: Self.screenCutout.height, height: Self.screenCutout.width)
            : Self.screenCutout.size
        // The shell's own on-screen bounding box once rotated — this, not just
        // the content, is what needs to fit inside the pane with margin.
        let shellOnScreenPixels = isLandscape
            ? CGSize(width: Self.shellPixels.height, height: Self.shellPixels.width)
            : Self.shellPixels

        let scale: CGFloat
        switch scaleMode {
        case .actual:
            scale = physicalContentSize().map { $0.width / cutoutSize.width } ?? fitScale(shellOnScreenPixels)
        case .zoomed:
            scale = fitScale(shellOnScreenPixels)
        }
        let content = CGSize(width: (cutoutSize.width * scale).rounded(), height: (cutoutSize.height * scale).rounded())

        let viewCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        let shellCenter = CGPoint(x: Self.shellPixels.width / 2, y: Self.shellPixels.height / 2)

        // A vector from the shell's centre, in its native space, rotated (if
        // landscape) the same -90° (counter-clockwise) the shell itself is
        // about to be transformed by — this is what keeps the cutout/button
        // locked to the artwork as it swings.
        func rotatedOffset(from point: CGPoint) -> CGVector {
            let native = CGVector(dx: point.x - shellCenter.x, dy: point.y - shellCenter.y)
            return isLandscape ? CGVector(dx: -native.dy, dy: native.dx) : native
        }

        let cutoutCenter = CGPoint(x: Self.screenCutout.midX, y: Self.screenCutout.midY)
        let contentOffset = rotatedOffset(from: cutoutCenter)
        let contentRect = CGRect(
            x: viewCenter.x + contentOffset.dx * scale - content.width / 2,
            y: viewCenter.y + contentOffset.dy * scale - content.height / 2,
            width: content.width, height: content.height)

        let buttonCenterNative = CGPoint(x: Self.shellPixels.width / 2,
                                         y: Self.shellPixels.height - Self.homeButtonBottomInset
                                            - Self.homeButtonDiameter / 2)
        let buttonOffset = rotatedOffset(from: buttonCenterNative)
        let buttonDiameter = (Self.homeButtonDiameter * scale).rounded()
        let buttonRect = CGRect(
            x: (viewCenter.x + buttonOffset.dx * scale - buttonDiameter / 2).rounded(),
            y: (viewCenter.y + buttonOffset.dy * scale - buttonDiameter / 2).rounded(),
            width: buttonDiameter, height: buttonDiameter)

        let shellSize = CGSize(width: Self.shellPixels.width * scale, height: Self.shellPixels.height * scale)

        CATransaction.begin()
        if orientationChanged {
            CATransaction.setAnimationDuration(Self.rotationDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)   // no implicit fade on plain resize
        }
        shellLayer.bounds = CGRect(origin: .zero, size: shellSize)
        shellLayer.position = viewCenter
        shellLayer.transform = CATransform3DMakeRotation(isLandscape ? -.pi / 2 : 0, 0, 0, 1)
        contentLayer.frame = contentRect
        CATransaction.commit()

        homeButton.frame = buttonRect
    }

    /// The screen at its true physical size, in this view's points, using the
    /// current screen's real pixel geometry. nil if the screen is unknown.
    private func physicalContentSize() -> CGSize? {
        guard let screen = window?.screen,
              let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber
        else { return nil }
        let display = CGDirectDisplayID(number.uint32Value)
        let mm = CGDisplayScreenSize(display)               // physical, millimetres
        guard mm.width > 0 else { return nil }
        // Points that span one physical inch on this display.
        let pointsPerInch = Double(screen.frame.width) / (Double(mm.width) / 25.4)
        return CGSize(width: Double(framePixels.width) / Self.devicePPI * pointsPerInch,
                      height: Double(framePixels.height) / Self.devicePPI * pointsPerInch)
    }

    /// The largest uniform scale that fits `nativeSize` within ~85% of the
    /// pane on whichever axis is binding — a consistent ~15% margin all round,
    /// whichever way the shell is currently oriented.
    private func fitScale(_ nativeSize: CGSize) -> CGFloat {
        let maxWidth = bounds.width * Self.zoomMarginFraction
        let maxHeight = bounds.height * Self.zoomMarginFraction
        return min(maxWidth / nativeSize.width, maxHeight / nativeSize.height)
    }

    // MARK: - Frame polling

    @objc private func step() {
        var pixels: UnsafeRawPointer?
        var w: Int32 = 0
        var h: Int32 = 0
        guard qemu_ios_ui_frame(&pixels, &w, &h, &serial), let pixels else { return }

        let width = Int(w), height = Int(h)
        let newFramePixels = CGSize(width: width, height: height)
        if newFramePixels != framePixels {
            framePixels = newFramePixels
            needsLayout = true
        }
        let bytes = width * height * 4
        guard let provider = CGDataProvider(dataInfo: nil, data: pixels, size: bytes,
                                            releaseData: { _, _, _ in }) else { return }
        // noneSkipFirst, NOT premultipliedFirst: the panel is opaque and the
        // alpha byte is whatever last wrote the framebuffer. iBoot draws the
        // boot logo without setting alpha at all, so honouring it rendered the
        // logo fully transparent — a black screen until SpringBoard (which does
        // write alpha) took over. ui/cocoa.m ignores alpha for the same reason.
        let bitmapInfo: CGBitmapInfo = [.byteOrder32Little,
                                        CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)]
        guard let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4,
                                  space: colorSpace, bitmapInfo: bitmapInfo,
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contents = image
        CATransaction.commit()
        lastImage = image
    }


    /// Current screen as an image, for Edit ▸ Copy Screen.
    var screenImage: NSImage? {
        guard let cg = lastImage else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: - Touch input

    /// Normalise a point to 0…1 over the panel content, whichever sub-rect the
    /// content currently occupies. Returns nil for clicks outside it.
    private func normalized(_ event: NSEvent) -> (Double, Double)? {
        let p = convert(event.locationInWindow, from: nil)
        let f = contentLayer.frame
        guard f.width > 0, f.height > 0, f.contains(p) else { return nil }
        let nx = (p.x - f.minX) / f.width
        let ny = (p.y - f.minY) / f.height     // isFlipped → y-down
        return (Double(nx), Double(ny))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pinching = event.modifierFlags.contains(.option)
        emit(event, Int32(QEMU_IOS_TOUCH_BEGIN))
    }

    override func mouseDragged(with event: NSEvent) { emit(event, Int32(QEMU_IOS_TOUCH_UPDATE)) }

    override func mouseUp(with event: NSEvent) {
        emit(event, Int32(QEMU_IOS_TOUCH_END))
        pinching = false
    }

    private func emit(_ event: NSEvent, _ phase: Int32) {
        guard let (nx, ny) = normalized(event) else { return }
        qemu_ios_ui_touch(0, phase, nx, ny)
        if pinching {
            // Second finger mirrored through the panel centre — an Option-drag
            // reads as a symmetric pinch, the geometry cocoa.m uses.
            qemu_ios_ui_touch2(phase, 1.0 - nx, 1.0 - ny)
        }
    }

    // MARK: - Keyboard passthrough

    override func keyDown(with event: NSEvent) {
        // Command combinations belong to the menu bar; let them pass.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        emulator?.sendKey(macKeyCode: event.keyCode, down: true)
    }

    override func keyUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.keyUp(with: event)
            return
        }
        emulator?.sendKey(macKeyCode: event.keyCode, down: false)
    }

    // MARK: - Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedIPA(sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedIPA(sender) else { return false }
        onDropIPA?(url)
        return true
    }

    private func droppedIPA(_ sender: NSDraggingInfo) -> URL? {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self])
                as? [URL] else { return nil }
        return urls.first { $0.pathExtension.lowercased() == "ipa" }
    }
}

/// The shell's home button: invisible until pressed, then a soft black circle
/// — drawn directly rather than via a bezel/image since it sits on shell
/// artwork with a shape (and press state) no stock NSButton style covers.
private final class HomeButton: NSButton {
    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        setAccessibilityLabel("Home")
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(isHighlighted ? 0.5 : 0).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
