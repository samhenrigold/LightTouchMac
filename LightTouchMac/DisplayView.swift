// Device shell and LCD share a transform. Fit uses the pane bounds; manual
// zoom uses display pixels per guest pixel, independent of orientation.

import Cocoa

/// Fit the whole device in the window, or use an integer display-pixel scale.
enum ZoomMode: Equatable {
    case fit
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
    var onDropMedia: ((URL) -> Void)?
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

    private enum PowerPresentation: Equatable { case awake, sleeping, poweredOff, shuttingDown }
    private var powerPresentation: PowerPresentation = .awake
    private var powerBadge: NSStackView?

    func updatePowerPresentation() {
        guard let emulator else { return }
        let next: PowerPresentation = emulator.isPoweredOff ? .poweredOff
            : emulator.shuttingDown ? .shuttingDown : (emulator.isSleeping && !isShowingLiveText) ? .sleeping : .awake
        guard next != powerPresentation else { return }
        powerPresentation = next
        powerBadge?.removeFromSuperview()
        powerBadge = nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.3)
        shellLayer.opacity = next == .awake ? 1 : next == .sleeping ? 0.45 : 0.25
        contentLayer.isHidden = next == .poweredOff
        CATransaction.commit()
        guard next != .awake else {
            setAccessibilityValue("Device awake")
            return
        }
        let symbol: NSView
        if next == .sleeping {
            let container = NSView(frame: CGRect(x: 0, y: 0, width: 160, height: 128))
            let sleeping = SleepingAnimationView()
            sleeping.frame = container.bounds
            sleeping.autoresizingMask = [.width, .height]
            container.addSubview(sleeping)
            container.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                container.widthAnchor.constraint(equalToConstant: 160),
                container.heightAnchor.constraint(equalToConstant: 128)
            ])
            symbol = container
        } else {
            let power = NSTextField(labelWithString: "⏻")
            power.font = .systemFont(ofSize: 30, weight: .light)
            power.textColor = .white
            symbol = power
        }
        let title = next == .sleeping ? "Sleeping" : next == .poweredOff ? "Powered Off" : "Powering off…"
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        let stack = NSStackView(views: [symbol, label])
        stack.appearance = NSAppearance(named: .darkAqua)
        stack.orientation = .vertical
        stack.spacing = 10
        if next != .shuttingDown {
            let button = NSButton(title: next == .poweredOff ? "Power On" : "Wake Up", target: self, action: #selector(wakeDevice(_:)))
            button.bezelStyle = .rounded
            stack.addArrangedSubview(button)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.centerYAnchor)
        ])
        powerBadge = stack
        setAccessibilityValue(title)
    }

    @objc private func wakeDevice(_ sender: Any?) {
        guard let emulator else { return }
        if emulator.isPoweredOff { emulator.powerOn() } else { emulator.pressLock() }
    }

    private let contentLayer = CALayer()
    private let shellLayer = CALayer()
    private let homeButton = HomeButton()
    private var displayLink: CADisplayLink?
    private var serial: UInt64 = 0
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
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
        touchOverlayLayer.zPosition = 50
        touchOverlayLayer.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull()]
        layer?.addSublayer(touchOverlayLayer)

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
        // Moving between displays can change the backing pixel scale.
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSWindow.didChangeScreenNotification,
                                               object: window)
    }

    @objc private func screenChanged() { needsLayout = true }

    @objc private func homeTapped() { endLiveText(); emulator?.pressHome() }

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
        if let lastRotation, lastRotation != rotation { endLiveText() }
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
        case .pixels(let multiple):
            scale = shellScale(guestPixelsPerDisplayPixel: multiple)
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
        let angle = (motionRestAngle ?? rest) + tiltAngle

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
        // Counter only the guest's quarter-turn, never the temporary tilt.
        // A layout during a gesture must not leave the panel crooked after release.
        contentLayer.transform = CATransform3DMakeRotation(-rest, 0, 0, 1)
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
        shellLayer.transform = motionTransform(angle: angle, scale: scale)
        homeButton.isHidden = tiltAngle != 0 || pitchAngle != 0
        CATransaction.commit()

        homeButton.frame = buttonRect
        if let liveTextView, let root = layer {
            liveTextView.frame = contentLayer.convert(contentLayer.bounds, to: root)
        }
    }

    /// Scale is independent of a framebuffer arriving before or after rotation.
    var pixelMultiple: CGFloat {
        appliedScale * Self.screenCutout.width / Self.nativeScreenPixels.width
            * (window?.backingScaleFactor ?? 2)
    }

    private var appliedScale: CGFloat = 1

    private func shellScale(guestPixelsPerDisplayPixel multiple: Int) -> CGFloat {
        CGFloat(multiple) / (window?.backingScaleFactor ?? 2)
            * Self.nativeScreenPixels.width / Self.screenCutout.width
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
        emulator?.pollStorageFailure()
        updateTouchOverlay()
        updateKeyboardTilt()
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
    }

    private var liveTextView: InlineLiveTextView?
    var isShowingLiveText: Bool { liveTextView != nil }
    func toggleLiveText() {
        if liveTextView != nil { endLiveText(); return }
        guard let image = captureFrame(includeTouches: false) else { return }
        let view = InlineLiveTextView(image: image)
        view.onClose = { [weak self] in self?.endLiveText() }
        liveTextView = view
        updatePowerPresentation()
        addSubview(view)
        needsLayout = true
    }
    func endLiveText() {
        guard let liveTextView else { return }
        liveTextView.stop()
        self.liveTextView = nil
        updatePowerPresentation()
        window?.makeFirstResponder(self)
    }

    var showsTouches = UserDefaults.standard.bool(forKey: "showsTouches") {
        didSet {
            UserDefaults.standard.set(showsTouches, forKey: "showsTouches")
            updateTouchOverlay()
        }
    }
    // A sibling of the device shell, never a child of the framebuffer layer.
    // Fading/shadow compositing must not involve the guest screen's contents.
    private let touchOverlayLayer = CALayer()
    private var touchLayers: [Int: CALayer] = [:]
    private static let touchFadeDuration = 0.16
    private var visibleTouches: [Int: (point: CGPoint, expires: CFTimeInterval)] = [:]

    private func sendVisualTouch(_ slot: Int32, _ phase: Int32, _ x: Double, _ y: Double) {
        guard touchInteractionEnabled else {
            if phase == Int32(QEMU_IOS_TOUCH_END) { qemu_ios_ui_touch(slot, phase, x, y) }
            clearTouchOverlay()
            return
        }
        noteTouch(slot: Int(slot), phase: phase, x: x, y: y)
        qemu_ios_ui_touch(slot, phase, x, y)
    }
    private func sendVisualTouch2(_ phase: Int32, _ x: Double, _ y: Double) {
        guard touchInteractionEnabled else {
            if phase == Int32(QEMU_IOS_TOUCH_END) { qemu_ios_ui_touch2(phase, x, y) }
            clearTouchOverlay()
            return
        }
        noteTouch(slot: 1, phase: phase, x: x, y: y)
        qemu_ios_ui_touch2(phase, x, y)
    }
    private func noteTouch(slot: Int, phase: Int32, x: Double, y: Double) {
        visibleTouches[slot] = (CGPoint(x: x, y: y), phase == Int32(QEMU_IOS_TOUCH_END) ? CACurrentMediaTime() + Self.touchFadeDuration : .infinity)
        updateTouchOverlay()
    }
    private var touchInteractionEnabled: Bool {
        emulator?.acceptsInput == true && emulator?.isSleeping != true && !isShowingLiveText
    }
    private func clearTouchOverlay() {
        visibleTouches.removeAll()
        for layer in touchLayers.values { layer.removeFromSuperlayer() }
        touchLayers.removeAll()
    }
    private var activeTouches: [(slot: Int, point: CGPoint, opacity: CGFloat)] {
        guard touchInteractionEnabled else { clearTouchOverlay(); return [] }
        let now = CACurrentMediaTime()
        visibleTouches = visibleTouches.filter { $0.value.expires > now }
        guard showsTouches else { return [] }
        return visibleTouches.map { slot, value in
            (slot, value.point, CGFloat(min(1, (value.expires - now) / Self.touchFadeDuration)))
        }
    }
    private func updateTouchOverlay() {
        let touches = activeTouches
        let liveSlots = Set(touches.map(\.slot))
        for slot in Array(touchLayers.keys) where !liveSlots.contains(slot) {
            touchLayers.removeValue(forKey: slot)?.removeFromSuperlayer()
        }
        // This overlay uses view coordinates, independent of the scaled shell.
        let diameter: CGFloat = 44
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        touchOverlayLayer.frame = layer?.bounds ?? bounds
        for touch in touches {
            let dot: CALayer
            if let existing = touchLayers[touch.slot] { dot = existing }
            else {
                dot = CALayer()
                dot.actions = ["opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "shadowPath": NSNull()]
                let gradient = CAGradientLayer()
                gradient.colors = [NSColor.white.withAlphaComponent(0.95).cgColor,
                                   NSColor(white: 0.94, alpha: 0.9).cgColor]
                gradient.startPoint = CGPoint(x: 0.5, y: 0)
                gradient.endPoint = CGPoint(x: 0.5, y: 1)
                gradient.masksToBounds = true
                dot.addSublayer(gradient)
                dot.shadowColor = NSColor.black.cgColor
                dot.shadowOpacity = 0.22
                touchOverlayLayer.addSublayer(dot)
                touchLayers[touch.slot] = dot
            }
            dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            dot.position = contentLayer.convert(
                CGPoint(x: touch.point.x * contentLayer.bounds.width,
                        y: touch.point.y * contentLayer.bounds.height), to: touchOverlayLayer)
            dot.opacity = Float(touch.opacity)
            dot.shadowRadius = 5
            dot.shadowOffset = CGSize(width: 0, height: 2)
            dot.shadowPath = CGPath(ellipseIn: dot.bounds, transform: nil)
            dot.sublayers?.first?.frame = dot.bounds
            dot.sublayers?.first?.cornerRadius = diameter / 2
        }
        CATransaction.commit()
    }

    /// The bridge copies while holding its publication lock, so capture is
    /// current even when paused/minimized and never retains a recycled slot.
    func captureFrame(includeTouches: Bool = true) -> CGImage? {
        if let liveTextView { return liveTextView.capturedImage }
        var data = Data(count: 480 * 480 * 4)
        var width: Int32 = 0, height: Int32 = 0
        let copied = data.withUnsafeMutableBytes {
            qemu_ios_ui_copy_frame($0.baseAddress, $0.count, &width, &height)
        }
        guard copied, width > 0, height > 0 else { return nil }
        data.count = Int(width * height * 4)
        let info: CGBitmapInfo = [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)]
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: Int(width) * 4, space: colorSpace,
                                  bitmapInfo: info, provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let touches = includeTouches ? activeTouches : []
        guard !touches.isEmpty,
              let context = CGContext(data: nil, width: Int(width), height: Int(height),
                                      bitsPerComponent: 8, bytesPerRow: Int(width) * 4,
                                      space: colorSpace, bitmapInfo: info.rawValue) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: Int(width), height: Int(height)))
        let pixelScale = CGFloat(width) / max(contentLayer.bounds.width * appliedScale, 1)
        let diameter = 44 * pixelScale
        let colors = [NSColor.white.withAlphaComponent(0.95).cgColor,
                      NSColor(white: 0.94, alpha: 0.9).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else { return image }
        for touch in touches {
            let rect = CGRect(x: touch.point.x * CGFloat(width) - diameter / 2,
                              y: (1 - touch.point.y) * CGFloat(height) - diameter / 2,
                              width: diameter, height: diameter)
            context.saveGState()
            context.setAlpha(touch.opacity)
            context.setShadow(offset: CGSize(width: 0, height: -2 * pixelScale), blur: 5 * pixelScale,
                              color: NSColor.black.withAlphaComponent(0.22).cgColor)
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: rect)
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.addEllipse(in: rect)
            context.clip()
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY),
                                       end: CGPoint(x: rect.midX, y: rect.minY), options: [])
            context.restoreGState()
        }
        return context.makeImage()
    }
    var screenImage: NSImage? {
        get async {
            guard let cg = captureFrame() else { return nil }
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
    private var scrollPitch = 0.0
    private var pitchAngle: CGFloat = 0
    private var motionRestAngle: CGFloat?
    private var tiltKeys = Set<UInt16>()
    private var consumedTiltKeys = Set<UInt16>()
    private var lastTiltTick = CACurrentMediaTime()
    private var motionWasEnabled = false
    private var scrollTilt = 0.0
    private var scrollTilting = false

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
        sendVisualTouch(0, phase, Double(x1), Double(a.y))
        sendVisualTouch2(phase, Double(x2), Double(a.y))
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
                sendVisualTouch(0, Int32(QEMU_IOS_TOUCH_BEGIN), nx, ny)
                try? await Task.sleep(for: .milliseconds(40))
                sendVisualTouch(0, Int32(QEMU_IOS_TOUCH_END), nx, ny)
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
        if scrollPoint == nil && !scrollTilting && event.phase == .began && !cursorOverPanel(event) {
            beginScrollTilt()
        }
        if scrollTilting {
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
            sendVisualTouch(0, Int32(QEMU_IOS_TOUCH_BEGIN), Double(p.x), Double(p.y))
        case .changed:
            guard var p = scrollPoint else { return }
            let d = rotatedPanelDelta(dx, dy)
            p.x = min(max(p.x + d.dx / b.width, 0), 1)
            p.y = min(max(p.y + d.dy / b.height, 0), 1)
            scrollPoint = p
            sendVisualTouch(0, Int32(QEMU_IOS_TOUCH_UPDATE), Double(p.x), Double(p.y))
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
            sendVisualTouch(0, Int32(QEMU_IOS_TOUCH_UPDATE), Double(p.x), Double(p.y))
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
        sendVisualTouch(0, Int32(QEMU_IOS_TOUCH_BEGIN), Double(p.x), Double(p.y))
        p.x = min(max(p.x + d.dx / b.width, 0), 1)
        p.y = min(max(p.y + d.dy / b.height, 0), 1)
        sendVisualTouch(0, Int32(QEMU_IOS_TOUCH_UPDATE), Double(p.x), Double(p.y))
        sendVisualTouch(0, Int32(QEMU_IOS_TOUCH_END), Double(p.x), Double(p.y))
    }

    private func endScrollDrag() {
        guard let p = scrollPoint else { return }
        sendVisualTouch(0, Int32(QEMU_IOS_TOUCH_END), Double(p.x), Double(p.y))
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
        guard touchInteractionEnabled else { return }
        motionRestAngle = Self.layerAngle(emulator?.rotationDegrees ?? 0)
        scrollTilting = true
        shellLayer.removeAnimation(forKey: "tiltSnap")
    }

    private func scrollTiltChanged(_ event: NSEvent) {
        switch event.phase {
        case .began, .changed:
            // Sideways fingers roll the device. A full trackpad sweep is about
            // a quarter turn, which is as far as any tilt game needs.
            scrollTilt = min(max(scrollTilt + event.scrollingDeltaX * Self.scrollTiltGain,
                                 -.pi / 3), .pi / 3)
            scrollPitch = min(max(scrollPitch + event.scrollingDeltaY * Self.scrollTiltGain, -.pi / 3), .pi / 3)
            tiltAngle = scrollTilt
            pitchAngle = scrollPitch
            setShellAngle(restAngle + tiltAngle)
            sendAttitude()
        case .ended, .cancelled:
            scrollTilt = 0
            endTilt()          // springs the shell back and restores gravity
        default:
            break
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard touchInteractionEnabled else { return }
        if let grab = chassisGrabAngle(event) {
            motionRestAngle = Self.layerAngle(emulator?.rotationDegrees ?? 0)
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
            sendAttitude()
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
    private var restAngle: CGFloat { motionRestAngle ?? Self.layerAngle(emulator?.rotationDegrees ?? 0) }

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
    private func motionTransform(angle: CGFloat, scale: CGFloat) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = -1 / 1400
        transform = CATransform3DRotate(transform, angle, 0, 0, 1)
        transform = CATransform3DRotate(transform, -pitchAngle, 1, 0, 0)
        return CATransform3DScale(transform, scale, scale, 1)
    }

    private func sendAttitude() {
        let roll = emulator?.motionPose == .flat ? tiltAngle : restAngle + tiltAngle
        emulator?.setTilt(angle: roll, pitch: pitchAngle)
    }

    func resetMotion() {
        tiltKeys.removeAll()
        endTilt()
    }

    private func updateKeyboardTilt() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTiltTick, 0), 0.05)
        lastTiltTick = now
        let enabled = touchInteractionEnabled && window?.isKeyWindow == true
        if !enabled {
            if motionWasEnabled { resetMotion() }
            motionWasEnabled = false
            return
        }
        if !motionWasEnabled { sendAttitude() }
        motionWasEnabled = true
        guard !tiltKeys.isEmpty else { return }
        let delta = CGFloat((emulator?.keyboardTiltRate ?? 90) * .pi / 180 * dt)
        let roll = (tiltKeys.contains(124) ? 1.0 : 0) - (tiltKeys.contains(123) ? 1.0 : 0)
        let pitch = (tiltKeys.contains(126) ? 1.0 : 0) - (tiltKeys.contains(125) ? 1.0 : 0)
        tiltAngle = min(max(tiltAngle + roll * delta, -.pi / 4), .pi / 4)
        pitchAngle = min(max(pitchAngle + pitch * delta, -.pi / 4), .pi / 4)
        setShellAngle(restAngle + tiltAngle)
        sendAttitude()
    }

    private func setShellAngle(_ angle: CGFloat) {
        shellLayer.removeAnimation(forKey: "tiltSnap")
        shellLayer.removeAnimation(forKey: "transform")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shellLayer.transform = motionTransform(angle: angle, scale: appliedScale)
        homeButton.isHidden = tiltAngle != 0 || pitchAngle != 0
        CATransaction.commit()
    }

    private func endTilt() {
        tilting = false
        scrollTilting = false
        scrollTilt = 0
        scrollPitch = 0
        pitchAngle = 0
        motionRestAngle = nil
        let from = shellLayer.presentation()?.transform ?? shellLayer.transform
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
        sendAttitude()
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
        sendVisualTouch(0, phase, nx, ny)
        if pinching {
            // Second finger mirrored through the panel centre — an Option-drag
            // reads as a symmetric pinch, the geometry cocoa.m uses.
            sendVisualTouch2(phase, 1.0 - nx, 1.0 - ny)
        }
    }

    // MARK: - Keyboard passthrough

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option), !event.modifierFlags.contains(.command),
           [123, 124, 125, 126, 49].contains(event.keyCode), !isShowingLiveText {
            consumedTiltKeys.insert(event.keyCode)
            guard touchInteractionEnabled else { return }
            if event.keyCode == 49 {
                if !event.isARepeat { emulator?.shake() }
            } else {
                if tiltKeys.isEmpty { motionRestAngle = Self.layerAngle(emulator?.rotationDegrees ?? 0) }
                tiltKeys.insert(event.keyCode)
            }
            return
        }
        if isShowingLiveText {
            if event.keyCode == 53 { endLiveText() }
            else { super.keyDown(with: event) }
            return
        }
        // Command combinations belong to the menu bar; let them pass.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        emulator?.sendKey(macKeyCode: event.keyCode, down: true)
    }

    override func keyUp(with event: NSEvent) {
        if consumedTiltKeys.remove(event.keyCode) != nil {
            tiltKeys.remove(event.keyCode)
            if tiltKeys.isEmpty { endTilt() }
            return
        }
        if isShowingLiveText { return }
        if event.modifierFlags.contains(.command) {
            super.keyUp(with: event)
            return
        }
        emulator?.sendKey(macKeyCode: event.keyCode, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        if !event.modifierFlags.contains(.option), !tiltKeys.isEmpty { resetMotion() }
        super.flagsChanged(with: event)
    }

    override func resignFirstResponder() -> Bool {
        resetMotion()
        return super.resignFirstResponder()
    }

    // MARK: - Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Refuse at the drag system, not with an alert per file. During the boot
        // the menu and toolbar items for this same operation are correctly
        // greyed out, but the drop still showed the green copy badge, accepted,
        // and then queued one "The device isn't ready yet" sheet per .ipa to be
        // dismissed one at a time.
        guard emulator?.canQueueInstall == true else { return [] }
        if !droppedCatalogApps(sender).isEmpty { return .copy }
        // Local drags carry .fileURL too (an installed row is draggable to
        // the Finder as its .ipa), but dropping one back on the device would
        // just reinstall what's already there — only OUTSIDE files install.
        guard sender.draggingSource == nil else { return [] }
        return droppedIPA(sender) != nil || !droppedMedia(sender).isEmpty ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let catalog = droppedCatalogApps(sender)
        if !catalog.isEmpty {
            catalog.forEach { onDropCatalogApp?($0) }
            return true
        }
        guard sender.draggingSource == nil else { return false }
        let ipas = droppedIPAs(sender)
        let media = droppedMedia(sender)
        guard !ipas.isEmpty || !media.isEmpty else { return false }
        ipas.forEach { onDropIPA?($0) }   // AppInstaller queues them
        media.forEach { onDropMedia?($0) }
        return true
    }

    private func droppedIPA(_ sender: NSDraggingInfo) -> URL? { droppedIPAs(sender).first }

    private func droppedIPAs(_ sender: NSDraggingInfo) -> [URL] {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self])
                as? [URL] else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == "ipa" }
    }

    private func droppedMedia(_ sender: NSDraggingInfo) -> [URL] {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else { return [] }
        return urls.filter { MediaSong.extensions.contains($0.pathExtension.lowercased()) }
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
