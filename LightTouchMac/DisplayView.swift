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
// through); the content layer is a sublayer of the shell, parked at the screen
// cutout, so it rides the shell's scale+rotation transform and the two stay in
// lockstep by construction when the guest's orientation flips. Mouse events
// become single-finger touches, Option-drag a two-finger pinch, and when this
// view is first responder key events are forwarded to the guest.

import Cocoa

/// How big the device is drawn.
///
/// The steps are whole multiples of a display pixel per guest pixel, so the
/// 320×480 frame buffer always lands on pixel boundaries: at 100% one guest
/// pixel is one pixel of your display, at 200% it is a 2×2 block. Anything in
/// between resamples 320 pixels across a fractional number of them, which with
/// nearest-neighbour magnification means some guest pixels come out one wide
/// and their neighbours two — the shimmer that makes an emulator look cheap.
/// `.fit` and `.physical` are exempt — each is explicitly a size asked for in
/// something other than pixels, and neither pretends otherwise.
enum ZoomMode: Equatable {
    case fit
    /// The device drawn the size a real iPod touch measures in the hand. Not a
    /// step on the ladder and not usually near one: the original screen is 163
    /// pixels per inch and a Mac display is nothing like that, so life size
    /// lands wherever it lands.
    case physical
    case pixels(Int)

    static let steps = [1, 2, 3, 4, 6, 8]

    var percent: Int? {
        guard case .pixels(let n) = self else { return nil }
        return n * 100
    }
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
    private var lastRotation: Int?

    /// Set by the owner so key/drop events can reach the guest.
    weak var emulator: EmulatorController?
    /// Called when an .ipa is dropped on the screen.
    var onDropIPA: ((URL) -> Void)?
    /// Called when a Legacy Store row is dropped on the screen.
    var onDropCatalogApp: ((CatalogApp) -> Void)?

    /// Points of breathing room between the shell and the pane edge when
    /// zoomed. A flat inset, not a fraction of the pane: 0.85 of the pane threw
    /// away 15% of a 1400-point window — over 200 points of black — to leave the
    /// same visual margin an 8-point gap gives.
    ///
    /// Wide enough that the shell's shadow has somewhere to fall.
    static let zoomInset: CGFloat = 16
    /// How long the shell + screen take to swing between portrait and landscape.
    private static let rotationDuration = 0.4

    var zoom: ZoomMode = .fit {
        didSet {
            guard oldValue != zoom else { return }
            pendingAnimatedLayout = true
            needsLayout = true
        }
    }
    /// Set by the scaleMode toggle so the next layout animates even though
    /// orientation didn't change — mirrors how orientationChanged drives it.
    private var pendingAnimatedLayout = false

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
        // The shell stays at its native pixel size forever; layout() scales and
        // rotates it with a single transform. The content layer lives INSIDE it
        // at the cutout, so scale and rotation can never drift apart — they are
        // one matrix.
        shellLayer.bounds = CGRect(origin: .zero, size: Self.shellPixels)
        // Enough of a shadow to lift the device off the gradient, not enough to
        // notice as an effect. The radius is in the shell's own native pixels,
        // so the transform scales it with the device and the shadow stays
        // proportionate at every window size.
        //
        // Ambient — no offset — on purpose: the shadow belongs to the shell
        // layer, so it rides the same transform, and any offset that fell
        // downwards in portrait would fall sideways once the shell rotates.
        //
        // ponytail: no shadowPath, so Core Animation derives the shape from the
        // artwork's alpha — correct for a rounded, bevelled device by
        // construction. The layer's contents never change, so it renders once;
        // give it a rounded-rect path if it ever shows up in a profile.
        shellLayer.shadowColor = NSColor.black.cgColor
        shellLayer.shadowOpacity = 0.4
        shellLayer.shadowRadius = 40
        shellLayer.shadowOffset = .zero
        layer?.addSublayer(shellLayer)

        contentLayer.magnificationFilter = .nearest
        // The shell is opaque, so the LCD draws on top of it. Black backing
        // shows a powered-on device screen during boot, before the first frame.
        contentLayer.contentsGravity = .resize
        contentLayer.backgroundColor = NSColor.black.cgColor
        contentLayer.position = CGPoint(x: Self.screenCutout.midX, y: Self.screenCutout.midY)
        shellLayer.addSublayer(contentLayer)

        homeButton.target = self
        homeButton.action = #selector(homeTapped)
        addSubview(homeButton)

        registerForDraggedTypes([.fileURL, .ltmCatalogApp])
        setAccessibilityLabel("iPod touch screen")
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }          // y-down, matching the guest
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Leaving the window: stop the link. It retains self, and nothing ever
        // invalidated it — so the view (and the emulator through it) could never
        // deallocate and step() kept polling, deep-copying frames forever. Only
        // masked because closing the window usually quits the app.
        if window == nil {
            displayLink?.invalidate()
            displayLink = nil
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didChangeScreenNotification, object: nil)
            return
        }
        guard displayLink == nil else { return }
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

    /// The shell layer stays at its native pixel size and carries scale and
    /// rotation in a single transform; the content layer is its child, parked
    /// at the screen cutout in shell-native pixels. Locked-together geometry
    /// falls out of the layer tree — layout only picks the scale, the angle,
    /// and the home button's (view-space) frame.
    override func layout() {
        super.layout()
        // The pose comes from the emulator's tracked orientation, not the frame
        // buffer's aspect — 480×320 alone can't tell landscape-left from
        // landscape-right, and 180° doesn't change the dimensions at all.
        // (Layout is still *triggered* by the dims flipping in step(), which
        // every quarter turn does.)
        let rotation = emulator?.rotationDegrees ?? 0
        let orientationChanged = lastRotation.map { $0 != rotation } ?? false
        lastRotation = rotation
        let isLandscape = rotation == 90 || rotation == 270

        let cutoutSize = isLandscape
            ? CGSize(width: Self.screenCutout.height, height: Self.screenCutout.width)
            : Self.screenCutout.size
        // The shell's own on-screen bounding box once rotated — this, not just
        // the content, is what needs to fit inside the pane with margin.
        let shellOnScreenPixels = isLandscape
            ? CGSize(width: Self.shellPixels.height, height: Self.shellPixels.width)
            : Self.shellPixels

        let scale: CGFloat
        switch zoom {
        case .fit:
            scale = fitScale(shellOnScreenPixels)
        case .physical:
            scale = physicalContentSize().map { $0.width / cutoutSize.width }
                ?? fitScale(shellOnScreenPixels)
        case .pixels(let multiple):
            scale = shellScale(guestPixelsPerDisplayPixel: multiple, cutout: cutoutSize)
        }
        appliedScale = scale
        // Centre on the SAFE area, not the raw bounds: with .fullSizeContentView
        // the pane runs behind the toolbar, so centring on bounds would push the
        // device up under it. The gradient still fills the whole pane, which is
        // the point — only the device is inset.
        let usable = safeAreaRect
        let viewCenter = CGPoint(x: usable.midX, y: usable.midY)
        let shellCenter = CGPoint(x: Self.shellPixels.width / 2, y: Self.shellPixels.height / 2)
        let rest = Self.layerAngle(rotation)
        let angle = rest + tiltAngle

        // The home button is an NSView, so it can't ride the shell's transform;
        // project its shell-native centre through the same rotation by hand.
        // NOTE: in this flipped (y-down) view the standard rotation matrix
        // turns a point visually clockwise for a positive angle — the SAME
        // visual direction a positive angle gives the layer transform here
        // (AppKit's geometry flip inverts a layer transform's handedness too),
        // so `rest` feeds both unconverted. At rest+tilt the button is mid-drag
        // and invisible anyway, so only `rest` is projected.
        let buttonCenterNative = CGPoint(x: Self.shellPixels.width / 2,
                                         y: Self.shellPixels.height - Self.homeButtonBottomInset
                                            - Self.homeButtonDiameter / 2)
        let native = CGVector(dx: buttonCenterNative.x - shellCenter.x,
                              dy: buttonCenterNative.y - shellCenter.y)
        let buttonOffset = CGVector(dx: native.dx * cos(rest) - native.dy * sin(rest),
                                    dy: native.dx * sin(rest) + native.dy * cos(rest))
        let buttonDiameter = (Self.homeButtonDiameter * scale).rounded()
        let buttonRect = CGRect(
            x: (viewCenter.x + buttonOffset.dx * scale - buttonDiameter / 2).rounded(),
            y: (viewCenter.y + buttonOffset.dy * scale - buttonDiameter / 2).rounded(),
            width: buttonDiameter, height: buttonDiameter)

        let animate = orientationChanged || pendingAnimatedLayout
        pendingAnimatedLayout = false

        // The guest surface arrives pre-rotated (ipod_touch_lcd.c turns the
        // picture the same way the user turned the device), so at rest the
        // content sits at -angle inside the shell: net rotation zero, surface
        // shown as published. These are applied WITHOUT animation — the new
        // buffer drawn at the new pose is pixel-identical to the old frame at
        // the old pose, so there's no jump, and during the shell's animated
        // swing the content keeps its fixed offset and rides rigidly, rotating
        // with the chrome instead of squishing in place. Bounds, never frame:
        // setting .frame on a transformed layer is undefined (it was the
        // squished-screen bug).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.bounds = CGRect(origin: .zero, size: cutoutSize)
        contentLayer.transform = CATransform3DMakeRotation(-angle, 0, 0, 1)
        CATransaction.commit()

        // Scale and rotation live in ONE transform, and the content is a child
        // of the shell — the whole device swings as a unit.
        CATransaction.begin()
        if animate {
            CATransaction.setAnimationDuration(Self.rotationDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)   // no implicit fade on plain resize
        }
        shellLayer.position = viewCenter
        shellLayer.transform = CATransform3DScale(
            CATransform3DMakeRotation(angle, 0, 0, 1), scale, scale, 1)
        CATransaction.commit()

        homeButton.frame = buttonRect
    }

    /// The pane size that fits the device exactly at the current zoom, with the
    /// standard margin and nothing left over. `.fit` has no intrinsic size of
    /// its own (it fits whatever it is given), so it is measured at the nearest
    /// pixel step — the size Fit would settle on if the window matched it.
    var idealPaneSize: CGSize {
        let isLandscape = emulator?.isLandscape ?? false
        let shell = isLandscape
            ? CGSize(width: Self.shellPixels.height, height: Self.shellPixels.width)
            : Self.shellPixels
        let cutout = isLandscape
            ? CGSize(width: Self.screenCutout.height, height: Self.screenCutout.width)
            : Self.screenCutout.size
        let scale: CGFloat
        switch zoom {
        case .pixels(let n): scale = shellScale(guestPixelsPerDisplayPixel: n, cutout: cutout)
        case .physical:      scale = physicalContentSize().map { $0.width / cutout.width }
                                     ?? shellScale(guestPixelsPerDisplayPixel: nearestPixelStep, cutout: cutout)
        case .fit:           scale = shellScale(guestPixelsPerDisplayPixel: nearestPixelStep, cutout: cutout)
        }
        // Plus whatever the toolbar covers: the pane is full-height now, so the
        // content it has to hold is the device box AND the inset above it.
        let chrome = CGSize(width: bounds.width - safeAreaRect.width,
                            height: bounds.height - safeAreaRect.height)
        return CGSize(width: (shell.width * scale + 2 * Self.zoomInset + chrome.width).rounded(),
                      height: (shell.height * scale + 2 * Self.zoomInset + chrome.height).rounded())
    }

    /// The step on the ladder closest to the size on screen right now, so
    /// zooming in or out of Fit or Actual Size carries on from what is already
    /// there instead of jumping to the bottom of the ladder.
    var nearestPixelStep: Int {
        let isLandscape = framePixels.width > framePixels.height
        let cutout = isLandscape
            ? CGSize(width: Self.screenCutout.height, height: Self.screenCutout.width)
            : Self.screenCutout.size
        let backing = window?.backingScaleFactor ?? 2
        let multiple = appliedScale * cutout.width / framePixels.width * backing
        return ZoomMode.steps.min {
            abs(CGFloat($0) - multiple) < abs(CGFloat($1) - multiple)
        } ?? 1
    }

    /// The scale the last layout actually used, whichever mode picked it.
    private var appliedScale: CGFloat = 1

    /// The screen at its true physical size, in this view's points, using the
    /// current display's real pixel geometry. nil if the display is unknown.
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

    /// The shell transform that puts `multiple` display pixels on every guest
    /// pixel. The screen content is a child of the shell, resized to fill the
    /// cutout, so the shell's scale is what decides the pixel size: the cutout
    /// is 594 shell pixels across for a 320-pixel frame buffer, and everything
    /// else follows from making those 320 land on the pixel count asked for.
    private func shellScale(guestPixelsPerDisplayPixel multiple: Int, cutout: CGSize) -> CGFloat {
        let backing = window?.backingScaleFactor ?? 2
        let pointsPerGuestPixel = CGFloat(multiple) / backing
        return pointsPerGuestPixel * framePixels.width / cutout.width
    }

    /// The largest uniform scale that fits `nativeSize` in the pane inset on
    /// every side. `nativeSize` is the shell's bounding box in its current
    /// orientation, so portrait and landscape both land with the same margin
    /// without either needing its own number.
    private func fitScale(_ nativeSize: CGSize) -> CGFloat {
        let usable = safeAreaRect
        let maxWidth = max(usable.width - 2 * Self.zoomInset, 1)
        let maxHeight = max(usable.height - 2 * Self.zoomInset, 1)
        return min(maxWidth / nativeSize.width, maxHeight / nativeSize.height)
    }

    // MARK: - Frame polling

    @objc private func step() {
        var pixels: UnsafeRawPointer?
        var w: Int32 = 0
        var h: Int32 = 0
        guard qemu_ios_ui_frame(&pixels, &w, &h, &serial), let pixels else { return }
        // A true return means the serial advanced — the guest painted. This is
        // the liveness signal behind booting→running and the snapshot health
        // gate; a wedged guest stops here.
        emulator?.noteFrameAdvanced()

        let width = Int(w), height = Int(h)
        let newFramePixels = CGSize(width: width, height: height)
        if newFramePixels != framePixels {
            framePixels = newFramePixels
            needsLayout = true
        }
        // The dims flipping catches every quarter turn but not a half one:
        // 180° leaves 320×480 at 320×480, so an upside-down app (or two
        // auto-rotations run back to back) would leave the shell posed at the
        // old angle until something else happened to lay out. Ask the emulator
        // directly — it is the source of truth for the pose, and layout()
        // already compares against the same value to decide whether to animate.
        if emulator?.rotationDegrees != lastRotation { needsLayout = true }
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
        // Copy only when someone has asked. Doing it every frame was ~37 MB/s of
        // allocate-and-memcpy on the main thread — the thread that also has to
        // service every touch — for a command almost nobody runs. But the copy
        // has to happen HERE, next to the pixels being handed to the layer:
        // copying at Copy-Screen time instead read a ring slot the emulator had
        // recycled many frames ago (the display link stops while the window is
        // minimised, so "many" can be thousands).
        if wantsScreenCopy {
            wantsScreenCopy = false
            lastImage = Self.deepCopy(image, width: width, height: height,
                                      bitmapInfo: bitmapInfo, colorSpace: colorSpace)
        }
    }

    /// Set by screenImage; honoured by the next frame.
    private var wantsScreenCopy = false

    /// A CGImage over its own copy of `image`'s pixels — outlives the frame ring.
    private static func deepCopy(_ image: CGImage, width: Int, height: Int,
                                 bitmapInfo: CGBitmapInfo, colorSpace: CGColorSpace) -> CGImage? {
        guard let src = image.dataProvider?.data,
              let owned = CFDataCreateMutableCopy(nil, 0, src),
              let provider = CGDataProvider(data: owned) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// Current screen as an image, for Edit ▸ Copy Screen.
    ///
    /// Asks `step()` for a copy and waits briefly for it, because only `step()`
    /// runs at a moment when the ring's pixels are provably the ones on screen.
    /// Falls back to the previous copy if no frame arrives — a paused or dead
    /// guest paints nothing, and a slightly old screenshot beats none.
    var screenImage: NSImage? {
        get async {
            wantsScreenCopy = true
            for _ in 0..<20 where wantsScreenCopy {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard let cg = lastImage else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }

    // MARK: - Touch input

    /// Normalise a point to 0…1 over the panel content. The content layer sits
    /// inside the shell's scale+rotation transform, so convert through the
    /// layer tree rather than reading a frame. Returns nil for clicks outside
    /// it. (The emulator un-rotates touches itself — ipod_touch_lcd_map_touch —
    /// so coordinates over the surface as published are exactly what it wants.)
    private func normalized(_ event: NSEvent) -> (Double, Double)? {
        guard let rootLayer = layer else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let cp = contentLayer.convert(p, from: rootLayer)
        let b = contentLayer.bounds
        guard b.width > 0, b.height > 0, b.contains(cp) else { return nil }
        return (Double(cp.x / b.width), Double(cp.y / b.height))   // isFlipped → y-down
    }

    // MARK: - Trackpad gestures
    //
    // Where the cursor is decides who the gesture belongs to. Over the panel it
    // is the guest's — a pinch is a real two-finger pinch, a scroll is a finger
    // dragging the content, a two-finger double tap is a double tap. Off the
    // panel there is no touch to send, so the same gestures drive the host: the
    // window's zoom, and tilting the device for the accelerometer.
    //
    // All of it tracks continuously. A gesture is a stream of small deltas from
    // .began to .ended, and each one is forwarded as it arrives, so the guest
    // follows the fingers instead of receiving a canned event at the end.

    /// Where the guest touch(es) are right now, in 0…1 panel space.
    private var gestureAnchor = CGPoint.zero
    /// Half the current pinch separation, panel-relative.
    private var pinchSpread = 0.0
    private var pinchingGuest = false
    /// Live scroll-drag: the finger's current position, carried between events.
    private var scrollPoint: CGPoint?
    /// Tilt driven by a two-finger scroll off the panel.
    private var scrollTilt = 0.0

    /// The panel-space point under the cursor, clamped into the panel. Unlike
    /// `normalized` this does not fail when the cursor is just outside — a pinch
    /// that drifts off the edge mid-gesture should keep tracking, not stop dead.
    private func clampedPanelPoint(_ event: NSEvent) -> CGPoint? {
        guard let rootLayer = layer else { return nil }
        let cp = contentLayer.convert(convert(event.locationInWindow, from: nil), from: rootLayer)
        let b = contentLayer.bounds
        guard b.width > 0, b.height > 0 else { return nil }
        return CGPoint(x: min(max(cp.x / b.width, 0), 1), y: min(max(cp.y / b.height, 0), 1))
    }

    /// Is the cursor over the device's screen right now?
    private func cursorOverPanel(_ event: NSEvent) -> Bool { normalized(event) != nil }

    // MARK: Pinch

    /// A pinch is the guest's, always — a genuine two-finger pinch with both
    /// contacts tracking the magnification continuously around the point the
    /// fingers started on.
    ///
    /// It deliberately does NOT resize the device itself: pinching is what you
    /// do to the content on a phone, so having it also scale the phone made the
    /// same gesture mean two things depending on a few pixels of cursor
    /// position. The window's zoom lives on the toolbar, the View menu and ⌘+/−.
    override func magnify(with event: NSEvent) {
        guard pinchingGuest || (event.phase == .began && cursorOverPanel(event)) else { return }
        guestPinch(event)
    }

    private func guestPinch(_ event: NSEvent) {
        switch event.phase {
        case .began:
            guard let p = clampedPanelPoint(event) else { return }
            gestureAnchor = p
            pinchSpread = 0.12          // a comfortable starting separation
            pinchingGuest = true
            sendPinch(Int32(QEMU_IOS_TOUCH_BEGIN))
        case .changed:
            guard pinchingGuest else { return }
            // Track the fingers: the separation scales exactly as they do.
            pinchSpread = min(max(pinchSpread * (1 + event.magnification), 0.01), 0.6)
            sendPinch(Int32(QEMU_IOS_TOUCH_UPDATE))
        case .ended, .cancelled:
            guard pinchingGuest else { return }
            sendPinch(Int32(QEMU_IOS_TOUCH_END))
            pinchingGuest = false
        default:
            break
        }
    }

    /// Two contacts mirrored through the anchor, along the panel's x axis.
    private func sendPinch(_ phase: Int32) {
        let a = gestureAnchor
        let x1 = min(max(a.x - pinchSpread, 0), 1), x2 = min(max(a.x + pinchSpread, 0), 1)
        qemu_ios_ui_touch(0, phase, Double(x1), Double(a.y))
        qemu_ios_ui_touch2(phase, Double(x2), Double(a.y))
    }

    // MARK: Two-finger double tap

    /// macOS calls this for a two-finger double tap — the "smart zoom" gesture.
    /// Over the panel it becomes what it means on the device: a double tap,
    /// which is exactly how iOS zooms to fit.
    override func smartMagnify(with event: NSEvent) {
        guard let (nx, ny) = normalized(event) else {
            super.smartMagnify(with: event)
            return
        }
        Task { @MainActor in
            for _ in 0..<2 {
                qemu_ios_ui_touch(0, Int32(QEMU_IOS_TOUCH_BEGIN), nx, ny)
                try? await Task.sleep(for: .milliseconds(40))
                qemu_ios_ui_touch(0, Int32(QEMU_IOS_TOUCH_END), nx, ny)
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }

    // MARK: Scroll / swipe

    /// Over the panel, a two-finger scroll IS a finger dragging the content:
    /// begin a touch where the cursor is and move it with the fingers, through
    /// momentum too, so a flick keeps travelling and iOS's own inertia takes
    /// over naturally. A two-finger swipe is the same stream at speed, so it
    /// needs no separate case.
    ///
    /// Off the panel the gesture tilts the device instead: side-to-side runs
    /// the accelerometer, and letting go springs it back upright.
    override func scrollWheel(with event: NSEvent) {
        if scrollPoint == nil && scrollTilt == 0 && event.phase == .began && !cursorOverPanel(event) {
            beginScrollTilt()
        }
        if scrollTilt != 0 || (event.phase == .began && !cursorOverPanel(event)) {
            scrollTiltChanged(event)
            return
        }
        guestScrollDrag(event)
    }

    private func guestScrollDrag(_ event: NSEvent) {
        // A conventional wheel mouse reports NO phase at all: phase and
        // momentumPhase are both empty. Every branch below tests for a specific
        // phase, so those events fell through to `default`, found no
        // scrollPoint, and returned — scrolling the guest with anything other
        // than an Apple trackpad or Magic Mouse did nothing whatsoever, and
        // super.scrollWheel was never called either, so the event just vanished.
        // Treat one as a whole flick: press, move, lift, in this single call.
        if event.phase.isEmpty, event.momentumPhase.isEmpty {
            wheelFlick(event)
            return
        }
        // Use the deltas as AppKit reports them. It has ALREADY applied the
        // user's natural-scrolling preference, so consulting
        // isDirectionInvertedFromDevice and flipping the sign ourselves just
        // corrects a correction — which is what kept sending these gestures the
        // wrong way. That flag is for telling the user which way the hardware
        // went, not for undoing the system setting.
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let b = contentLayer.bounds
        guard b.width > 0, b.height > 0 else { return }

        switch event.phase {
        case .began:
            guard let p = clampedPanelPoint(event) else { return }
            scrollPoint = p
            qemu_ios_ui_touch(0, Int32(QEMU_IOS_TOUCH_BEGIN), Double(p.x), Double(p.y))
        case .changed:
            guard var p = scrollPoint else { return }
            let d = rotatedPanelDelta(dx, dy)
            p.x = min(max(p.x + d.dx / b.width, 0), 1)
            p.y = min(max(p.y + d.dy / b.height, 0), 1)
            scrollPoint = p
            qemu_ios_ui_touch(0, Int32(QEMU_IOS_TOUCH_UPDATE), Double(p.x), Double(p.y))
        case .ended, .cancelled:
            // Lift only if no momentum follows; otherwise ride it out below.
            if event.momentumPhase == [] { endScrollDrag() }
        default:
            // Momentum: keep the contact down and moving so the flick reads as
            // one continuous drag rather than a drag that stops and restarts.
            guard var p = scrollPoint else { return }
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                endScrollDrag()
                return
            }
            let d = rotatedPanelDelta(dx, dy)
            p.x = min(max(p.x + d.dx / b.width, 0), 1)
            p.y = min(max(p.y + d.dy / b.height, 0), 1)
            scrollPoint = p
            qemu_ios_ui_touch(0, Int32(QEMU_IOS_TOUCH_UPDATE), Double(p.x), Double(p.y))
        }
    }

    /// One phase-less wheel event as a complete short drag.
    private func wheelFlick(_ event: NSEvent) {
        let b = contentLayer.bounds
        guard b.width > 0, b.height > 0, var p = clampedPanelPoint(event) else { return }
        // scrollingDelta* is 0 for a legacy wheel; deltaY carries the clicks.
        let dx = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.deltaX * 10
        let dy = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY * 10
        let d = rotatedPanelDelta(dx, dy)
        qemu_ios_ui_touch(0, Int32(QEMU_IOS_TOUCH_BEGIN), Double(p.x), Double(p.y))
        p.x = min(max(p.x + d.dx / b.width, 0), 1)
        p.y = min(max(p.y + d.dy / b.height, 0), 1)
        qemu_ios_ui_touch(0, Int32(QEMU_IOS_TOUCH_UPDATE), Double(p.x), Double(p.y))
        qemu_ios_ui_touch(0, Int32(QEMU_IOS_TOUCH_END), Double(p.x), Double(p.y))
    }

    private func endScrollDrag() {
        guard let p = scrollPoint else { return }
        qemu_ios_ui_touch(0, Int32(QEMU_IOS_TOUCH_END), Double(p.x), Double(p.y))
        scrollPoint = nil
    }

    /// A movement in view points expressed in content-layer points, un-rotated
    /// so directions match what the user sees in any orientation.
    private func rotatedPanelDelta(_ dx: CGFloat, _ dy: CGFloat) -> CGVector {
        let a = -(Self.layerAngle(emulator?.rotationDegrees ?? 0) + tiltAngle)
        let s = max(appliedScale * (contentLayer.bounds.width / max(framePixels.width, 1)), 0.01)
        let ux = dx / s, uy = dy / s
        return CGVector(dx: ux * cos(a) - uy * sin(a), dy: ux * sin(a) + uy * cos(a))
    }

    // MARK: Tilt by scroll (cursor off the panel)

    private func beginScrollTilt() {
        shellLayer.removeAnimation(forKey: "tiltSnap")
    }

    private func scrollTiltChanged(_ event: NSEvent) {
        switch event.phase {
        case .began, .changed:
            // Sideways fingers roll the device. A full trackpad sweep is about
            // a quarter turn, which is as far as any tilt game needs.
            scrollTilt = min(max(scrollTilt + event.scrollingDeltaX * Self.scrollTiltGain,
                                 -.pi / 3), .pi / 3)
            tiltAngle = scrollTilt
            setShellAngle(restAngle + tiltAngle)
            emulator?.setTilt(angle: restAngle + tiltAngle)
        case .ended, .cancelled:
            scrollTilt = 0
            endTilt()          // springs the shell back and restores gravity
        default:
            break
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let grab = chassisGrabAngle(event) {
            shellLayer.removeAnimation(forKey: "tiltSnap")
            tilting = true
            grabAngle = grab
            return
        }
        pinching = event.modifierFlags.contains(.option)
        emit(event, Int32(QEMU_IOS_TOUCH_BEGIN))
    }

    override func mouseDragged(with event: NSEvent) {
        if tilting {
            // NOT negated. The polar angle in this flipped view and the layer
            // transform share a handedness, so the raw delta already turns the
            // shell with the hand. It was negated for a while on the theory
            // that explained an earlier "wrong direction, too fast" report —
            // but that report was the ungeared 1:1 rate reading as reversed,
            // and the gain below is what actually fixed it.
            //
            // Geared down by rotationGain. 1:1 is the textbook
            // answer for direct manipulation, but the useful arc here is a
            // wrist movement around a point on screen, and at 1:1 a quarter
            // turn costs almost none of it — fine for flipping to landscape,
            // useless for holding a few degrees of tilt in a game, which is
            // what this gesture is actually for.
            let delta = mouseAngle(event) - grabAngle
            tiltAngle = atan2(sin(delta), cos(delta)) * Self.rotationGain   // wrap, then gear down
            setShellAngle(restAngle + tiltAngle)
            emulator?.setTilt(angle: restAngle + tiltAngle)
            return
        }
        emit(event, Int32(QEMU_IOS_TOUCH_UPDATE))
    }

    override func mouseUp(with event: NSEvent) {
        if tilting { endTilt(); return }
        emit(event, Int32(QEMU_IOS_TOUCH_END))
        pinching = false
    }

    // MARK: - Tilt (drag the chassis to rotate; the accelerometer follows)
    //
    // Grabbing the shell anywhere outside the screen — bezel or corners — and
    // dragging rotates the whole device around its centre, Photoshop-style,
    // and feeds the guest the matching gravity vector, so tilt games play.
    // Release springs the shell back to rest and restores resting gravity.

    /// Degrees of device rotation per degree of drag around the shell's centre.
    /// The calibration knob for how fine the tilt is: 1.0 tracks the cursor
    /// exactly, lower trades that for precision. Tune here, not at the call site.
    private static let rotationGain: CGFloat = 0.4

    /// Radians of device tilt per point of two-finger swipe, when the cursor is
    /// off the panel. Much gentler than a drag: a swipe has no anchor to hold
    /// on to, so the same rate that feels direct under a finger feels wild here.
    /// A full trackpad sweep is a few degrees, which is the range tilt games use.
    private static let scrollTiltGain: CGFloat = 0.0015

    private var tilting = false
    private var grabAngle: CGFloat = 0   // mouse polar angle at grab
    private var tiltAngle: CGFloat = 0   // current drag delta from rest

    /// The shell layer's rest rotation for a guest orientation, signed so 270°
    /// comes in as a single quarter turn (-π/2), not three of them — the
    /// implicit animation interpolates the transform, and the sign is what
    /// makes the swing take the short way round.
    private static func layerAngle(_ degrees: Int) -> CGFloat {
        degrees == 270 ? -.pi / 2 : CGFloat(degrees) * .pi / 180
    }

    /// The shell's resting rotation for the guest's current orientation —
    /// the same angle layout() starts from.
    private var restAngle: CGFloat { Self.layerAngle(emulator?.rotationDegrees ?? 0) }

    /// If the press is on the chassis (inside the shell artwork, outside the
    /// screen cutout), the mouse's polar angle around the shell centre; nil
    /// otherwise, in which case the press is a guest touch. Converting through
    /// the layer accounts for the current scale and rotation.
    private func chassisGrabAngle(_ event: NSEvent) -> CGFloat? {
        guard let rootLayer = layer else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let sp = shellLayer.convert(p, from: rootLayer)
        guard shellLayer.bounds.contains(sp), !Self.screenCutout.contains(sp)
        else { return nil }
        return mouseAngle(event)
    }

    /// Polar angle of the mouse around the shell centre in view space. The
    /// view is flipped (y-down), so a positive angle is visually clockwise —
    /// the same handedness as a positive layer-transform rotation here, which
    /// is what lets the drag delta feed the transform unconverted.
    private func mouseAngle(_ event: NSEvent) -> CGFloat {
        let p = convert(event.locationInWindow, from: nil)
        return atan2(p.y - shellLayer.position.y, p.x - shellLayer.position.x)
    }

    /// The same transform layout() computes, at an arbitrary angle, applied
    /// without animation — this is the per-mouse-move path.
    private func setShellAngle(_ angle: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shellLayer.transform = CATransform3DScale(
            CATransform3DMakeRotation(angle, 0, 0, 1), appliedScale, appliedScale, 1)
        CATransaction.commit()
    }

    private func endTilt() {
        tilting = false
        let from = shellLayer.transform
        tiltAngle = 0
        setShellAngle(restAngle)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: from)
        spring.toValue = NSValue(caTransform3D: shellLayer.transform)
        spring.stiffness = 200
        spring.damping = 14
        spring.duration = spring.settlingDuration
        shellLayer.add(spring, forKey: "tiltSnap")
        // Gravity snaps straight to rest; the spring is only visual.
        // ponytail: sample the presentation layer from the display link if a
        // game ever needs to see the settle.
        emulator?.setTilt(angle: restAngle)
    }

    /// Is a mouse-driven touch currently down in the guest? The host and the
    /// guest each keep their own idea of that, and this is what keeps the two
    /// from drifting apart.
    private var touchDown = false

    /// Send a mouse event to the guest as a touch.
    ///
    /// This used to bail whenever the cursor was outside the screen — which
    /// silently dropped the TOUCH_END of any drag that ended off the panel, and
    /// a drag that runs past the edge is the most ordinary gesture there is.
    /// The guest then believed a finger was still down forever: scrolling
    /// stopped working, and `mtt_bh`'s tracked flag (which only clears on an
    /// END) desynced so no later pinch ever began. So:
    ///
    /// - a BEGIN outside the screen is not a touch, and is dropped — but then
    ///   nothing is in flight, so the matching END is dropped too;
    /// - once down, UPDATEs clamp to the panel edge rather than vanishing,
    ///   which is also what a real finger sliding onto the bezel does;
    /// - an END is delivered whenever a touch is down, wherever the cursor is.
    private func emit(_ event: NSEvent, _ phase: Int32) {
        if phase == Int32(QEMU_IOS_TOUCH_BEGIN) {
            guard let (nx, ny) = normalized(event) else { return }
            touchDown = true
            send(phase, nx, ny)
            return
        }
        guard touchDown, let p = clampedPanelPoint(event) else { return }
        if phase == Int32(QEMU_IOS_TOUCH_END) { touchDown = false }
        send(phase, Double(p.x), Double(p.y))
    }

    private func send(_ phase: Int32, _ nx: Double, _ ny: Double) {
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
        // Refuse at the drag system, not with an alert per file. During the boot
        // the menu and toolbar items for this same operation are correctly
        // greyed out, but the drop still showed the green copy badge, accepted,
        // and then queued one "The device isn't ready yet" sheet per .ipa to be
        // dismissed one at a time.
        guard emulator?.canReachDevice == true else { return [] }
        if !droppedCatalogApps(sender).isEmpty { return .copy }
        // Local drags carry .fileURL too (an installed row is draggable to
        // the Finder as its .ipa), but dropping one back on the device would
        // just reinstall what's already there — only OUTSIDE files install.
        guard sender.draggingSource == nil else { return [] }
        return droppedIPA(sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let catalog = droppedCatalogApps(sender)
        if !catalog.isEmpty {
            catalog.forEach { onDropCatalogApp?($0) }
            return true
        }
        guard sender.draggingSource == nil else { return false }
        let ipas = droppedIPAs(sender)
        guard !ipas.isEmpty else { return false }
        ipas.forEach { onDropIPA?($0) }   // AppInstaller queues them
        return true
    }

    private func droppedIPA(_ sender: NSDraggingInfo) -> URL? { droppedIPAs(sender).first }

    private func droppedIPAs(_ sender: NSDraggingInfo) -> [URL] {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self])
                as? [URL] else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == "ipa" }
    }

    /// Store rows dragged from the inspector: decode the private payload.
    private func droppedCatalogApps(_ sender: NSDraggingInfo) -> [CatalogApp] {
        (sender.draggingPasteboard.pasteboardItems ?? []).compactMap { item in
            item.data(forType: .ltmCatalogApp)
                .flatMap { try? JSONDecoder().decode(CatalogApp.self, from: $0) }
        }
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
