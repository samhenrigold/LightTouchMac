// Device shell and LCD share a transform. Fit uses the pane bounds; manual
// zoom uses display pixels per guest pixel, independent of orientation.

import Cocoa

/// Fit the whole device in the window, or use an integer display-pixel scale.
enum ZoomMode: Equatable {
    case fit
    case physical
    case pixels(Int)

    static let steps = [1, 2, 3, 4, 6, 8]

    var percent: Int? {
        guard case .pixels(let n) = self else { return nil }
        return n * 100
    }
}

final class DisplayView: NSView {

    /// The device this view shows, fixed at init.
    private let profile: DeviceProfile
    /// The panel at rest — iPod touch 2G: 320×480 at 163 ppi (3.5" panel).
    /// The live frame buffer swaps its sides on rotation.
    private let nativeScreenPixels: CGSize

    /// The shell art: its full pixel size, the screen cutout rect within
    /// it (top-left origin, matching this view's isFlipped space), and the
    /// home button circle — all in the shell image's own native (portrait,
    /// unrotated) pixel space.
    private let shellPixels: CGSize
    private let screenCutout: CGRect
    private let homeButtonDiameter: CGFloat
    private let homeButtonBottomInset: CGFloat

    /// Whatever the guest is actually sending right now — swaps on rotation.
    private var framePixels: CGSize
    /// nil until the first layout, so the initial appearance never "rotates in".
    private var lastRotation: Int?

    /// Set by the owner so key/drop events can reach the guest.
    weak var emulator: EmulatorController?
    /// Called when an .ipa is dropped on the screen.
    var onDropIPA: ((URL) -> Void)?
    /// An IPSW from outside: the library's, whatever this device is doing.
    var onDropIPSW: ((URL) -> Void)?
    var onDropMedia: ((URL) -> Void)?
    var onDropUnsupportedFiles: (([URL]) -> Void)?
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

    private var deviceLayoutRect: CGRect { safeAreaRect }
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
    var isCapturingCanvas = false { didSet { powerBadge?.isHidden = isCapturingCanvas } }

    func updatePowerPresentation() {
        guard let emulator else { return }
        let next: PowerPresentation = emulator.isPoweredOff ? .poweredOff
            : emulator.shuttingDown ? .shuttingDown : (emulator.isSleeping && !emulator.preparingDevice && !isShowingLiveText) ? .sleeping : .awake
        guard next != powerPresentation else { return }
        powerPresentation = next
        powerBadge?.removeFromSuperview()
        powerBadge = nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.3)
        shellLayer.opacity = next == .awake ? 1 : next == .sleeping ? 0.45 : 0.25
        contentLayer.isHidden = next == .poweredOff
        modelView?.alphaValue = CGFloat(shellLayer.opacity)
        modelView?.setScreenOff(next != .awake)
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
        let title = next == .sleeping ? "Sleeping" : next == .poweredOff ? "Powered off" : "Stopping…"
        let stack = NSStackView(views: [symbol])
        if next == .shuttingDown {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 15, weight: .medium)
            label.textColor = .white
            stack.addArrangedSubview(label)
        }
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
        stack.isHidden = isCapturingCanvas
        setAccessibilityValue(title)
    }

    @objc private func wakeDevice(_ sender: Any?) {
        guard let emulator else { return }
        if emulator.isPoweredOff { emulator.powerOn() } else { emulator.pressLock() }
    }

    private var modelView: DeviceModelView?
    private var pendingModelView: DeviceModelView?
    private var modelLoadTask: Task<Void, Never>?
    private var modelFallbackTask: Task<Void, Never>?
    private var modelPresentationFinished = false
    private var lastShakeGeneration: UInt64 = 0
    private let contentLayer = CALayer()
    private let shellLayer = CALayer()
    private let homeButton = HomeButton()
    private let attitudeIndicator = AttitudeIndicatorButton(frame: .zero)
    private var displayLink: CADisplayLink?
    /// The ring serial on screen, and its surface (captures read it).
    private var shownSerial: UInt64 = 0
    private var shownSurface: IOSurface?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var pinching = false

    init(frame: NSRect, profile: DeviceProfile) {
        self.profile = profile
        nativeScreenPixels = profile.uprightScreenPixels
        framePixels = nativeScreenPixels
        shellPixels = profile.shellPixels
        screenCutout = profile.screenCutout
        homeButtonDiameter = profile.homeButtonDiameter
        homeButtonBottomInset = profile.homeButtonBottomInset
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        shellLayer.contents = NSImage(named: profile.shellImageName)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
        shellLayer.contentsGravity = .resize
        // The shell stays at its native pixel size forever; layout() scales and
        // rotates it with a single transform. The content layer lives INSIDE it
        // at the cutout, so scale and rotation can never drift apart — they are
        // one matrix.
        shellLayer.bounds = CGRect(origin: .zero, size: shellPixels)
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
        keyboardPointerLayer.zPosition = 51
        keyboardPointerLayer.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
        keyboardPointerLayer.path = CGPath(ellipseIn: CGRect(x: 2, y: 2, width: 14, height: 14), transform: nil)
        keyboardPointerLayer.fillColor = NSColor.black.withAlphaComponent(0.25).cgColor
        keyboardPointerLayer.strokeColor = NSColor.white.cgColor
        keyboardPointerLayer.lineWidth = 2
        keyboardPointerLayer.shadowColor = NSColor.black.cgColor
        keyboardPointerLayer.shadowOpacity = 1
        keyboardPointerLayer.shadowRadius = 1
        keyboardPointerLayer.shadowOffset = .zero
        keyboardPointerLayer.isHidden = true
        layer?.addSublayer(keyboardPointerLayer)

        contentLayer.magnificationFilter = .nearest
        // The shell is opaque, so the LCD draws on top of it. Black backing
        // shows a powered-on device screen during boot, before the first frame.
        contentLayer.contentsGravity = .resize
        contentLayer.backgroundColor = NSColor.black.cgColor
        contentLayer.position = CGPoint(x: screenCutout.midX, y: screenCutout.midY)
        shellLayer.addSublayer(contentLayer)

        homeButton.target = self
        homeButton.action = #selector(homeTapped)
        addSubview(homeButton)
        // macOS 14 keeps the photo shell; RealityKit texture rotation requires 15.
        if #available(macOS 15, *), profile.hasDeviceModel,
           let url = Bundle.main.url(forResource: "N72", withExtension: "usdz") {
            // Give RealityKit one second to present the device itself. Slower
            // startup shows a temporary photo while the live model keeps
            // loading; a busy GPU must never permanently disable 3D.
            shellLayer.isHidden = true
            homeButton.isHidden = true
            modelFallbackTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.showStaticDevice()
            }
            modelLoadTask = Task { [weak self] in
                do {
                    let model = try await DeviceModelView(url: url)
                    try Task.checkCancellation()
                    guard self?.stageModelForPresentation(model) == true else { return }
                    let frameReady = await model.prepareFirstFrame()
                    try Task.checkCancellation()
                    // Do not retain the display across a renderer callback. A
                    // stalled snapshot must not keep a closed window alive.
                    guard frameReady else { return }
                    self?.presentModel(model)
                } catch is CancellationError {} catch {
                    NSLog("N72 model could not load: %@", error.localizedDescription)
                    self?.showStaticDevice()
                }
            }
        } else { modelPresentationFinished = true }
        attitudeIndicator.target = self
        attitudeIndicator.action = #selector(levelAttitude(_:))
        attitudeIndicator.isHidden = true
        attitudeIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(attitudeIndicator)
        NSLayoutConstraint.activate([
            attitudeIndicator.widthAnchor.constraint(equalToConstant: 40),
            attitudeIndicator.heightAnchor.constraint(equalToConstant: 40),
            attitudeIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            attitudeIndicator.topAnchor.constraint(equalTo: topAnchor, constant: 12),
        ])

        registerForDraggedTypes([.fileURL, .ltmCatalogApp])
        setAccessibilityLabel("\(profile.displayName) screen")
        setAccessibilityRole(.image)
        setAccessibilityHelp("Disable Keyboard Input in the Device menu to move a pointer with arrow keys. Hold Space to touch, or Shift-arrow to drag. Home is also available in the Device menu.")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func stageModelForPresentation(_ model: DeviceModelView) -> Bool {
        guard modelView == nil else { return false }
        addSubview(model, positioned: .below, relativeTo: homeButton)
        pendingModelView = model
        model.alphaValue = 0
        model.setScreenOff(powerPresentation != .awake)
        if let image = captureFrame(includeTouches: false) { model.updateFrame(image) }
        needsLayout = true
        layoutSubtreeIfNeeded()
        return true
    }

    private func showStaticDevice() {
        guard modelView == nil else { return }
        modelPresentationFinished = true
        modelFallbackTask?.cancel()
        shellLayer.isHidden = false
        needsLayout = true
    }

    private func presentModel(_ model: DeviceModelView) {
        guard modelView == nil else { return }
        modelPresentationFinished = true
        modelFallbackTask?.cancel()
        pendingModelView = nil
        modelView = model
        model.setScreenOff(powerPresentation != .awake)
        needsLayout = true
        layoutSubtreeIfNeeded()
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.0 : 0.2
        if !shellLayer.isHidden, duration > 0 {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = shellLayer.opacity
            fade.toValue = 0
            fade.duration = duration
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            shellLayer.add(fade, forKey: "modelPresentation")
        } else { shellLayer.isHidden = true }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            model.animator().alphaValue = CGFloat(shellLayer.opacity)
        } completionHandler: { [weak self] in
            self?.shellLayer.isHidden = true
            self?.shellLayer.removeAnimation(forKey: "modelPresentation")
        }
    }

    override var isFlipped: Bool { true }          // y-down, matching the guest
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Leaving the window: stop the link. It retains self, and nothing ever
        // invalidated it — so the view (and the emulator through it) could never
        // deallocate and step() kept polling, deep-copying frames forever. Only
        // masked because closing the window usually quits the app.
        if window == nil {
            modelLoadTask?.cancel()
            modelFallbackTask?.cancel()
            wheelTiltResetTask?.cancel()
            displayLink?.invalidate()
            displayLink = nil
            NotificationCenter.default.removeObserver(self)
            return
        }
        guard displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
        // Moving between displays can change the backing pixel scale.
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didMoveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: name, object: window)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    var onPhysicalSizeUnavailable: (() -> Void)?
    var physicalScale: CGFloat? {
        guard let window else { return nil }
        let center = window.convertPoint(toScreen: convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil))
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? window.screen
        return screen.flatMap { DisplayMeasurements.pointsPerMillimeter($0) }.map {
            let height = profile.physicalHeightMillimeters * $0
            return modelView?.physicalScale(heightInPoints: height) ?? height / shellPixels.height
        }
    }
    @objc private func screenChanged() {
        if zoom == .physical, physicalScale == nil { zoom = .fit; onPhysicalSizeUnavailable?() }
        needsLayout = true
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); screenChanged() }


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

        // A panel fixed to the shell (the iPad's) never swaps sides; the
        // iPod's pre-rotated surface does.
        let cutoutSize = profile.panelRotation != 0
            ? CGSize(width: screenCutout.height, height: screenCutout.width)
            : isLandscape
            ? CGSize(width: screenCutout.height, height: screenCutout.width)
            : screenCutout.size
        // The shell's own on-screen bounding box once rotated — this, not just
        // the content, is what needs to fit inside the pane with margin.
        let shellOnScreenPixels = isLandscape
            ? CGSize(width: shellPixels.height, height: shellPixels.width)
            : shellPixels

        let scale: CGFloat
        switch zoom {
        case .fit:
            scale = fitScale(shellOnScreenPixels)
        case .physical:
            scale = physicalScale ?? fitScale(shellOnScreenPixels)
        case .pixels(let multiple):
            scale = shellScale(guestPixelsPerDisplayPixel: multiple)
        }
        appliedScale = scale
        // Centre on the SAFE area, not the raw bounds: with .fullSizeContentView
        // the pane runs behind the toolbar, so centring on bounds would push the
        // device up under it. The gradient still fills the whole pane, which is
        // the point — only the device is inset.
        let usable = deviceLayoutRect
        let viewCenter = CGPoint(x: usable.midX, y: usable.midY)
        let shellCenter = CGPoint(x: shellPixels.width / 2, y: shellPixels.height / 2)
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
        let buttonCenterNative = CGPoint(x: shellPixels.width / 2,
                                         y: shellPixels.height - homeButtonBottomInset
                                            - homeButtonDiameter / 2)
        let native = CGVector(dx: buttonCenterNative.x - shellCenter.x,
                              dy: buttonCenterNative.y - shellCenter.y)
        let buttonOffset = CGVector(dx: native.dx * cos(rest) - native.dy * sin(rest),
                                    dy: native.dx * sin(rest) + native.dy * cos(rest))
        let buttonDiameter = (homeButtonDiameter * scale).rounded()
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
        if profile.panelRotation != 0 {
            // The iPad's guest turns its own UI inside a panel that turns with
            // the shell: only the fixed panel-to-upright quarter-turn applies.
            contentLayer.transform = CATransform3DRotate(CATransform3DIdentity, profile.panelRotation, 0, 0, 1)
        } else {
            contentLayer.transform = CATransform3DMakeRotation(-rest, 0, 0, 1)
        }
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
        homeButton.isHidden = !modelPresentationFinished || (modelView == nil && (tiltAngle != 0 || pitchAngle != 0))
        CATransaction.commit()

        modelView?.frame = bounds
        pendingModelView?.frame = bounds
        modelView?.viewportCenter = viewCenter
        pendingModelView?.viewportCenter = viewCenter
        updateModelPose(animated: animate)
        if let modelView, let rect = modelView.homeButtonRect {
            homeButton.frame = convert(rect, from: modelView)
        } else { homeButton.frame = buttonRect }
        if let liveTextView, let root = layer {
            if let modelView {
                let a = convert(modelView.projectedPoint(.zero), from: modelView)
                let b = convert(modelView.projectedPoint(CGPoint(x: 1, y: 1)), from: modelView)
                liveTextView.frame = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x-a.x), height: abs(b.y-a.y))
            } else { liveTextView.frame = contentLayer.convert(contentLayer.bounds, to: root) }
        }
    }

    /// Scale is independent of a framebuffer arriving before or after rotation.
    var pixelMultiple: CGFloat {
        appliedScale * screenCutout.width / nativeScreenPixels.width
            * (window?.backingScaleFactor ?? 2)
    }

    private var appliedScale: CGFloat = 1

    private func shellScale(guestPixelsPerDisplayPixel multiple: Int) -> CGFloat {
        CGFloat(multiple) / (window?.backingScaleFactor ?? 2)
            * nativeScreenPixels.width / screenCutout.width
    }

    /// The largest uniform scale that fits `nativeSize` in the pane inset on
    /// every side. `nativeSize` is the shell's bounding box in its current
    /// orientation, so portrait and landscape both land with the same margin
    /// without either needing its own number.
    private func fitScale(_ nativeSize: CGSize) -> CGFloat {
        let usable = deviceLayoutRect
        let maxWidth = max(usable.width - 2 * Self.zoomInset, 1)
        let maxHeight = max(usable.height - 2 * Self.zoomInset, 1)
        return min(maxWidth / nativeSize.width, maxHeight / nativeSize.height)
    }

    // MARK: - Frame polling

    /// Frames come from the helper's IOSurface ring: the layer shows the front
    /// surface itself (no copy), and only the 3D model, which needs a texture,
    /// gets a CGImage made from it. Liveness and status are EmulatorController's
    /// own poll, so a hidden device (no display link) keeps them.
    @objc private func step() {
        if let generation = emulator?.shakeGeneration, generation != lastShakeGeneration {
            lastShakeGeneration = generation
            modelView?.shake()
        }
        if let modelView, let rect = modelView.homeButtonRect {
            homeButton.frame = convert(rect, from: modelView)
        }
        modelView?.advanceAnimations()
        updateTouchOverlay()
        updateKeyboardPointer()
        _ = currentFrame()
    }

    /// The newest ring surface, shown if it is new. The ring reader belongs to
    /// one thread; the display link and captures are both on main.
    private func currentFrame() -> IOSurface? {
        guard let frame = emulator?.link?.frontSurface() else { return shownSurface }
        guard frame.serial != shownSerial || frame.surface !== shownSurface else { return frame.surface }
        shownSerial = frame.serial
        shownSurface = frame.surface
        let newFramePixels = CGSize(width: frame.surface.width, height: frame.surface.height)
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The helper forces the alpha byte opaque (FrameRingWriter.copy): iBoot
        // and the iPod's framebuffer leave it 0, which a layer would honour.
        contentLayer.contents = frame.surface
        if let model = modelView ?? pendingModelView, let image = Self.image(frame.surface, colorSpace: colorSpace) {
            model.updateFrame(image)
        }
        CATransaction.commit()
        return frame.surface
    }

    /// A copy of a ring surface, held in use while it is read so the helper
    /// never writes into it. noneSkipFirst, NOT premultipliedFirst: the panel
    /// is opaque (ui/cocoa.m ignores alpha for the same reason).
    private static func image(_ surface: IOSurface, colorSpace: CGColorSpace) -> CGImage? {
        surface.incrementUseCount()
        surface.lock(options: .readOnly, seed: nil)
        let data = Data(bytes: surface.baseAddress, count: surface.bytesPerRow * surface.height)
        surface.unlock(options: .readOnly, seed: nil)
        surface.decrementUseCount()
        let info: CGBitmapInfo = [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)]
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: surface.width, height: surface.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: surface.bytesPerRow, space: colorSpace, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private var liveTextView: InlineLiveTextView?
    var isShowingLiveText: Bool { liveTextView != nil }
    func toggleLiveText() {
        if liveTextView != nil { endLiveText(); return }
        guard let image = captureFrame(includeTouches: false) else { return }
        resetMotion()
        let view = InlineLiveTextView(image: image)
        view.onClose = { [weak self] in self?.endLiveText() }
        liveTextView = view
        updatePowerPresentation()
        addSubview(view)
        needsLayout = true
        window?.toolbar?.validateVisibleItems()
    }
    func endLiveText() {
        guard let liveTextView else { return }
        liveTextView.stop()
        self.liveTextView = nil
        updatePowerPresentation()
        window?.makeFirstResponder(self)
        window?.toolbar?.validateVisibleItems()
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

    private func sendVisualTouch(_ slot: Int32, _ phase: Int32, _ x: Double, _ y: Double, keyboard: Bool = false) {
        if !keyboard { endKeyboardTouch() }
        guard touchInteractionEnabled else {
            if phase == TouchPhase.end { emulator?.link?.send(.touch(slot: Int(slot), phase: Int(phase), x: x, y: y)) }
            clearTouchOverlay()
            return
        }
        noteTouch(slot: Int(slot), phase: phase, x: x, y: y)
        emulator?.link?.send(.touch(slot: Int(slot), phase: Int(phase), x: x, y: y))
    }
    private func sendVisualTouch2(_ phase: Int32, _ x: Double, _ y: Double) {
        guard touchInteractionEnabled else {
            if phase == TouchPhase.end { emulator?.link?.send(.touch2(phase: Int(phase), x: x, y: y)) }
            clearTouchOverlay()
            return
        }
        noteTouch(slot: 1, phase: phase, x: x, y: y)
        emulator?.link?.send(.touch2(phase: Int(phase), x: x, y: y))
    }
    private func noteTouch(slot: Int, phase: Int32, x: Double, y: Double) {
        visibleTouches[slot] = (CGPoint(x: x, y: y), phase == TouchPhase.end ? CACurrentMediaTime() + Self.touchFadeDuration : .infinity)
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
            dot.position = projectedPanelPoint(touch.point)
            dot.opacity = Float(touch.opacity)
            dot.shadowRadius = 5
            dot.shadowOffset = CGSize(width: 0, height: 2)
            dot.shadowPath = CGPath(ellipseIn: dot.bounds, transform: nil)
            dot.sublayers?.first?.frame = dot.bounds
            dot.sublayers?.first?.cornerRadius = diameter / 2
        }
        CATransaction.commit()
    }

    /// Reads the newest ring surface under a use count, so capture is current
    /// even when paused, hidden or minimized and never reads a recycled slot.
    func captureFrame(includeTouches: Bool = true) -> CGImage? {
        if let liveTextView { return liveTextView.capturedImage }
        guard let image = capturePanelFrame(includeTouches: includeTouches) else { return nil }
        guard profile.panelRotation != 0 else { return image }
        // Match the window: panel-to-upright plus the device's own quarter-turn.
        let turns = ((Int((profile.panelRotation * 2 / .pi).rounded()) + (emulator?.rotationDegrees ?? 0) / 90) % 4 + 4) % 4
        return Self.rotated(image, clockwiseQuarterTurns: turns) ?? image
    }

    private static func rotated(_ image: CGImage, clockwiseQuarterTurns turns: Int) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let size = turns % 2 == 0 ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
        guard turns != 0, let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                                  bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: image.bitmapInfo.rawValue) else { return image }
        // CG is y-up, so a visual clockwise turn is a negative angle.
        switch turns {
        case 1: context.translateBy(x: 0, y: w); context.rotate(by: -.pi / 2)
        case 2: context.translateBy(x: w, y: h); context.rotate(by: .pi)
        default: context.translateBy(x: h, y: 0); context.rotate(by: .pi / 2)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    private func capturePanelFrame(includeTouches: Bool) -> CGImage? {
        guard let surface = currentFrame(), let image = Self.image(surface, colorSpace: colorSpace) else { return nil }
        let width = image.width, height = image.height
        let info: CGBitmapInfo = [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)]
        let touches = includeTouches ? activeTouches : []
        guard !touches.isEmpty,
              let context = CGContext(data: nil, width: Int(width), height: Int(height),
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
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
        if let modelView {
            guard let p = modelView.panelPoint(modelView.convert(event.locationInWindow, from: nil)) else { return nil }
            return (Double(p.x), Double(p.y))
        }
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
    private var rotatingChassis = false
    private var wheelTiltResetTask: Task<Void, Never>?
    private var motionRestAngle: CGFloat?
    private var scrollTilt = 0.0
    private var scrollTilting = false

    /// The panel-space point under the cursor, clamped into the panel. Unlike
    /// `normalized` this does not fail when the cursor is just outside — a pinch
    /// that drifts off the edge mid-gesture should keep tracking, not stop dead.
    private func clampedPanelPoint(_ event: NSEvent) -> CGPoint? {
        if let modelView { return modelView.panelPoint(modelView.convert(event.locationInWindow, from: nil), clamped: true) }
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
            sendPinch(TouchPhase.begin)
        case .changed:
            guard pinchingGuest else { return }
            // Track the fingers: the separation scales exactly as they do.
            pinchSpread = min(max(pinchSpread * (1 + event.magnification), 0.01), 0.6)
            sendPinch(TouchPhase.update)
        case .ended, .cancelled:
            guard pinchingGuest else { return }
            sendPinch(TouchPhase.end)
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
                sendVisualTouch(0, TouchPhase.begin, nx, ny)
                try? await Task.sleep(for: .milliseconds(40))
                sendVisualTouch(0, TouchPhase.end, nx, ny)
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
    /// Off the panel, scrolls tilt the device's accelerometer. A two-finger
    /// twist also controls roll; letting go springs either gesture to rest.
    override func scrollWheel(with event: NSEvent) {
        guard !rotatingChassis && !tilting else { return }
        // Host tilt ends with the fingers. Momentum belongs to content
        // scrolling, and must not start a second model gesture at the cursor.
        if !scrollTilting && scrollPoint == nil && !event.momentumPhase.isEmpty { return }
        if scrollPoint == nil && !scrollTilting && (event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty))
            && (!cursorOverPanel(event) || event.modifierFlags.contains(.option)) {
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
            sendVisualTouch(0, TouchPhase.begin, Double(p.x), Double(p.y))
        case .changed:
            guard var p = scrollPoint else { return }
            let d = rotatedPanelDelta(dx, dy)
            p.x = min(max(p.x + d.dx / b.width, 0), 1)
            p.y = min(max(p.y + d.dy / b.height, 0), 1)
            scrollPoint = p
            sendVisualTouch(0, TouchPhase.update, Double(p.x), Double(p.y))
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
            sendVisualTouch(0, TouchPhase.update, Double(p.x), Double(p.y))
        }
    }

    /// One phase-less wheel event as a complete short drag.
    private func wheelFlick(_ event: NSEvent) {
        let b = contentLayer.bounds
        guard b.width > 0, b.height > 0, var p = clampedPanelPoint(event) else { return }
        let delta = Self.scrollMovement(event)
        let dx = delta.dx, dy = delta.dy
        let d = rotatedPanelDelta(dx, dy)
        sendVisualTouch(0, TouchPhase.begin, Double(p.x), Double(p.y))
        p.x = min(max(p.x + d.dx / b.width, 0), 1)
        p.y = min(max(p.y + d.dy / b.height, 0), 1)
        sendVisualTouch(0, TouchPhase.update, Double(p.x), Double(p.y))
        sendVisualTouch(0, TouchPhase.end, Double(p.x), Double(p.y))
    }

    private func endScrollDrag() {
        guard let p = scrollPoint else { return }
        sendVisualTouch(0, TouchPhase.end, Double(p.x), Double(p.y))
        scrollPoint = nil
    }

    /// A movement in view points expressed in content-layer points, un-rotated
    /// so directions match what the user sees in any orientation.
    private func rotatedPanelDelta(_ dx: CGFloat, _ dy: CGFloat) -> CGVector {
        let a = -(Self.layerAngle(emulator?.rotationDegrees ?? 0) + tiltAngle + profile.panelRotation)  // the iPad panel is mounted a quarter turn
        let s = max(appliedScale * (contentLayer.bounds.width / max(framePixels.width, 1)), 0.01)
        let ux = dx / s, uy = dy / s
        return CGVector(dx: ux * cos(a) - uy * sin(a), dy: ux * sin(a) + uy * cos(a))
    }

    // MARK: Tilt by scroll (cursor off the panel)

    private func beginScrollTilt() {
        guard touchInteractionEnabled else { return }
        wheelTiltResetTask?.cancel()
        motionRestAngle = Self.layerAngle(emulator?.rotationDegrees ?? 0)
        scrollTilt = tiltAngle
        scrollPitch = pitchAngle
        scrollTilting = true
        shellLayer.removeAnimation(forKey: "tiltSnap")
    }

    private func scrollTiltChanged(_ event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        switch event.phase {
        case .began, .changed, []:
            // AppKit already applied Natural Scrolling. Use the same content
            // movement convention as the LCD, without inverting it again.
            let delta = Self.scrollMovement(event)
            scrollTilt = min(max(scrollTilt + delta.dx * Self.scrollTiltGain,
                                 -.pi / 3), .pi / 3)
            scrollPitch = min(max(scrollPitch + delta.dy * Self.scrollTiltGain, -.pi / 3), .pi / 3)
            tiltAngle = scrollTilt
            pitchAngle = scrollPitch
            setShellAngle(restAngle + tiltAngle)
            sendAttitude()
            // Wheel mice have no ended event. End a burst after a short idle
            // interval so they cannot leave the device tilted indefinitely.
            if event.phase.isEmpty {
                wheelTiltResetTask?.cancel()
                wheelTiltResetTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                    self?.endTilt()
                }
            }
        case .ended, .cancelled:
            scrollTilt = 0
            endTilt()          // springs the shell back and restores gravity
        default:
            break
        }
    }

    /// Precise deltas are points; conventional wheels report lines. Preserve
    /// both signs because NSEvent has already honored the system preference.
    private static func scrollMovement(_ event: NSEvent) -> CGVector {
        let pointsPerUnit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        return CGVector(dx: event.scrollingDeltaX * pointsPerUnit,
                        dy: event.scrollingDeltaY * pointsPerUnit)
    }

    override func rotate(with event: NSEvent) {
        guard touchInteractionEnabled && !tilting && scrollPoint == nil && !pinchingGuest else { return }
        if event.phase == .began && (!cursorOverPanel(event) || event.modifierFlags.contains(.option)) {
            endTilt()
            motionRestAngle = Self.layerAngle(emulator?.rotationDegrees ?? 0)
            rotatingChassis = true
        }
        guard rotatingChassis else { return }
        if event.phase == .ended || event.phase == .cancelled { endTilt(); return }
        // NSEvent rotation is incremental counterclockwise degrees; this
        // flipped view's roll is clockwise radians. Scrolling preferences do
        // not affect a physical two-finger twist.
        tiltAngle = min(max(tiltAngle - CGFloat(event.rotation) * .pi / 180, -.pi / 3), .pi / 3)
        setShellAngle(restAngle + tiltAngle)
        sendAttitude()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard touchInteractionEnabled else { return }
        if isChassisEvent(event) {
            endTilt()
            motionRestAngle = Self.layerAngle(emulator?.rotationDegrees ?? 0)
            shellLayer.removeAnimation(forKey: "tiltSnap")
            tilting = true
            grabPoint = convert(event.locationInWindow, from: nil)
            return
        }
        pinching = event.modifierFlags.contains(.option)
        emit(event, TouchPhase.begin)
    }

    override func mouseDragged(with event: NSEvent) {
        if tilting {
            // Horizontal movement steers with accelerometer roll, not yaw
            // around gravity. Use fixed deltas from the grab point so a
            // diagonal has the same response anywhere on the frame. This
            // view is flipped: dragging up matches an upward gesture.
            let point = convert(event.locationInWindow, from: nil)
            tiltAngle = min(max((point.x - grabPoint.x) * 0.004, -.pi / 4), .pi / 4)
            pitchAngle = min(max((grabPoint.y - point.y) * 0.004, -.pi / 4), .pi / 4)
            setShellAngle(restAngle + tiltAngle)
            sendAttitude()
            return
        }
        emit(event, TouchPhase.update)
    }

    override func mouseUp(with event: NSEvent) {
        if tilting { endTilt(); return }
        emit(event, TouchPhase.end)
        pinching = false
    }

    // MARK: - Tilt (drag the chassis to rotate; the accelerometer follows)
    //
    // Grabbing the shell anywhere outside the screen — bezel or corners — and
    // dragging side to side steers tilt games; dragging up/down adds pitch.
    // Both axes change the gravity vector measured by the accelerometer.
    // Release springs the shell back to rest and restores resting gravity.

    /// Radians of device tilt per point of two-finger swipe, when the cursor is
    /// off the panel. Much gentler than a drag: a swipe has no anchor to hold
    /// on to, so the same rate that feels direct under a finger feels wild here.
    /// A full trackpad sweep is a few degrees, which is the range tilt games use.
    private static let scrollTiltGain: CGFloat = 0.0015

    private var tilting = false
    private var grabPoint = CGPoint.zero
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

    /// Keep direct manipulation on the chassis and guest touches on the LCD.
    private func isChassisEvent(_ event: NSEvent) -> Bool {
        if let modelView {
            return modelView.isChassis(modelView.convert(event.locationInWindow, from: nil))
        }
        guard modelPresentationFinished, let rootLayer = layer else { return false }
        let p = convert(event.locationInWindow, from: nil)
        let sp = shellLayer.convert(p, from: rootLayer)
        return shellLayer.bounds.contains(sp) && !screenCutout.contains(sp)
    }

    /// The same transform layout() computes, at an arbitrary angle, applied
    /// without animation — this is the per-mouse-move path.
    private func motionTransform(angle: CGFloat, scale: CGFloat) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = -1 / 1400
        let flat = emulator?.motionPose == .flat
        transform = CATransform3DRotate(transform, flat ? angle - tiltAngle : angle, 0, 0, 1)
        transform = CATransform3DRotate(transform, pitchAngle, 1, 0, 0)
        transform = CATransform3DRotate(transform, flat ? tiltAngle : 0, 0, 1, 0)
        return CATransform3DScale(transform, scale, scale, 1)
    }

    private func updateModelPose(animated: Bool = false, spring: Bool = false) {
        (modelView ?? pendingModelView)?.pose(scale: appliedScale, rotation: emulator?.rotationDegrees ?? 0,
                        roll: tiltAngle, pitch: pitchAngle,
                        flat: emulator?.motionPose == .flat, animated: animated, spring: spring)
    }

    private func projectedPanelPoint(_ point: CGPoint) -> CGPoint {
        if let modelView { return convert(modelView.projectedPoint(point), from: modelView) }
        return contentLayer.convert(CGPoint(x: point.x * contentLayer.bounds.width,
                                           y: point.y * contentLayer.bounds.height), to: layer)
    }

    @objc private func levelAttitude(_ sender: Any?) { resetMotion() }
    private func sendAttitude() {
        attitudeIndicator.update(pitch: pitchAngle, roll: tiltAngle)
        attitudeIndicator.isHidden = !touchInteractionEnabled || (abs(pitchAngle) < 0.001 && abs(tiltAngle) < 0.001)
        if emulator?.motionPose == .flat {
            // Flat gravity points into the display. Rotate its screen-relative
            // X/Y components into the sensor axes, including in landscape.
            let x = sin(tiltAngle) * cos(pitchAngle)
            let y = sin(pitchAngle)
            let z = -cos(tiltAngle) * cos(pitchAngle)
            let sensorX = cos(restAngle) * x - sin(restAngle) * y
            let sensorY = sin(restAngle) * x + cos(restAngle) * y
            emulator?.setTilt(angle: atan2(sensorX, -z),
                              pitch: atan2(sensorY, hypot(sensorX, z)))
        } else {
            emulator?.setTilt(angle: restAngle + tiltAngle, pitch: pitchAngle)
        }
    }

    func resetMotion() {
        endTilt()
    }

    private func setShellAngle(_ angle: CGFloat, animated: Bool = false) {
        updateModelPose(animated: animated, spring: animated)
        shellLayer.removeAnimation(forKey: "tiltSnap")
        shellLayer.removeAnimation(forKey: "transform")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shellLayer.transform = motionTransform(angle: angle, scale: appliedScale)
        homeButton.isHidden = !modelPresentationFinished || (modelView == nil && (tiltAngle != 0 || pitchAngle != 0))
        CATransaction.commit()
    }

    private func endTilt() {
        wheelTiltResetTask?.cancel()
        rotatingChassis = false
        tilting = false
        scrollTilting = false
        scrollTilt = 0
        scrollPitch = 0
        pitchAngle = 0
        motionRestAngle = nil
        let from = shellLayer.presentation()?.transform ?? shellLayer.transform
        tiltAngle = 0
        setShellAngle(restAngle, animated: true)
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
        if phase == TouchPhase.begin {
            guard let (nx, ny) = normalized(event) else { return }
            touchDown = true
            send(phase, nx, ny)
            return
        }
        guard touchDown, let p = clampedPanelPoint(event) else { return }
        if phase == TouchPhase.end { touchDown = false }
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

    // MARK: - Keyboard pointer (typing disabled)

    private let keyboardPointerLayer = CAShapeLayer()
    private var keyboardPoint = CGPoint(x: 0.5, y: 0.5)
    private var keyboardTouchKeys = Set<UInt16>()
    private var hasKeyboardPointer = false

    private func endKeyboardTouch() {
        guard !keyboardTouchKeys.isEmpty else { return }
        keyboardTouchKeys.removeAll()
        sendVisualTouch(0, TouchPhase.end, keyboardPoint.x, keyboardPoint.y, keyboard: true)
    }

    private func keyboardPointerKey(_ event: NSEvent, down: Bool) -> Bool {
        let code = event.keyCode
        guard [49, 123, 124, 125, 126].contains(code) else { return false }
        if !down, keyboardTouchKeys.contains(code) {
            if keyboardTouchKeys.count == 1 { endKeyboardTouch() }
            else { keyboardTouchKeys.remove(code) }
            return true
        }
        guard emulator?.keyboardInputEnabled == false,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        guard down, touchInteractionEnabled, !touchDown, !pinchingGuest, scrollPoint == nil else { return true }
        hasKeyboardPointer = true
        let touching = code == 49 || event.modifierFlags.contains(.shift)
        if touching, !keyboardTouchKeys.contains(code) {
            let began = keyboardTouchKeys.isEmpty
            keyboardTouchKeys.insert(code)
            if began { sendVisualTouch(0, TouchPhase.begin, keyboardPoint.x, keyboardPoint.y, keyboard: true) }
        }
        if code != 49 {
            let delta: CGFloat = 0.02
            switch code {
            case 123: keyboardPoint.x = max(0, keyboardPoint.x - delta)
            case 124: keyboardPoint.x = min(1, keyboardPoint.x + delta)
            case 125: keyboardPoint.y = min(1, keyboardPoint.y + delta)
            default: keyboardPoint.y = max(0, keyboardPoint.y - delta)
            }
            if !keyboardTouchKeys.isEmpty {
                sendVisualTouch(0, TouchPhase.update, keyboardPoint.x, keyboardPoint.y, keyboard: true)
            }
        }
        return true
    }

    private func updateKeyboardPointer() {
        let active = touchInteractionEnabled && emulator?.keyboardInputEnabled == false && window?.isKeyWindow == true && window?.firstResponder === self
        if !active { endKeyboardTouch() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        keyboardPointerLayer.isHidden = !active || !hasKeyboardPointer
        if active { keyboardPointerLayer.position = projectedPanelPoint(keyboardPoint) }
        CATransaction.commit()
    }

    // MARK: - Keyboard passthrough

    private var consumedWakeSpace = false
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           consumedWakeSpace || (emulator?.isSleeping == true && emulator?.acceptsInput == true) {
            if !consumedWakeSpace && !event.isARepeat { emulator?.pressLock() }
            consumedWakeSpace = true
            return
        }
        if isShowingLiveText {
            if event.keyCode == 53 { endLiveText() }
            else { super.keyDown(with: event) }
            return
        }
        // Command combinations belong to the menu bar; let them pass.
        if !event.modifierFlags.intersection([.command, .control]).isEmpty {
            super.keyDown(with: event)
            return
        }
        if keyboardPointerKey(event, down: true) { return }
        emulator?.sendKey(macKeyCode: event.keyCode, down: true)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 && consumedWakeSpace { consumedWakeSpace = false; return }
        if !keyboardTouchKeys.isEmpty, keyboardPointerKey(event, down: false) { return }
        if isShowingLiveText { return }
        if !event.modifierFlags.intersection([.command, .control]).isEmpty {
            super.keyUp(with: event)
            return
        }
        if keyboardPointerKey(event, down: false) { return }
        emulator?.sendKey(macKeyCode: event.keyCode, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        // Shift and Option only ever arrive here, never as keyDown, so the
        // guest keyboard missed them (no capitals, no "!"). Command and
        // Control stay with the menu bar. sendKey lets key-ups through while
        // input is off, so a modifier can't stick down.
        switch event.keyCode {
        case 56, 60: emulator?.sendKey(macKeyCode: event.keyCode, down: event.modifierFlags.contains(.shift))
        case 58, 61: emulator?.sendKey(macKeyCode: event.keyCode, down: event.modifierFlags.contains(.option))
        default: break
        }
        if !event.modifierFlags.contains(.shift), !keyboardTouchKeys.isDisjoint(with: [123, 124, 125, 126]) {
            endKeyboardTouch()
        }
        super.flagsChanged(with: event)
    }

    override func resignFirstResponder() -> Bool {
        endKeyboardTouch()
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
        // An IPSW is for the library, not this device: any time, from outside.
        if sender.draggingSource == nil, onDropIPSW != nil, !dropped(sender, .ipsw).isEmpty {
            sender.numberOfValidItemsForDrop = dropped(sender, .ipsw).count
            return .copy
        }
        guard emulator?.canQueueInstall == true else { return [] }
        let catalog = droppedCatalogApps(sender)
        if !catalog.isEmpty, onDropCatalogApp != nil {
            sender.numberOfValidItemsForDrop = catalog.count
            return .copy
        }
        // Local drags carry .fileURL too (an installed row is draggable to
        // the Finder as its .ipa), but dropping one back on the device would
        // just reinstall what's already there — only OUTSIDE files install.
        guard sender.draggingSource == nil else { return [] }
        let count = (onDropIPA == nil ? 0 : dropped(sender, .ipa).count)
            + (onDropMedia == nil ? 0 : dropped(sender, .media).count)
        guard count > 0 else { return [] }
        sender.numberOfValidItemsForDrop = count
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Readiness can change after the drag entered. Never animate a
        // successful drop when its owner will reject the import.
        guard draggingEntered(sender) == .copy else { return false }
        let ipsws = dropped(sender, .ipsw)
        if sender.draggingSource == nil, let onDropIPSW, !ipsws.isEmpty {
            ipsws.forEach(onDropIPSW)
            return true
        }
        let catalog = droppedCatalogApps(sender)
        if !catalog.isEmpty, let onDropCatalogApp {
            catalog.forEach(onDropCatalogApp)
            return true
        }
        guard sender.draggingSource == nil else { return false }
        let ipas = dropped(sender, .ipa)
        let media = dropped(sender, .media)
        guard !ipas.isEmpty || !media.isEmpty else { return false }
        ipas.forEach { onDropIPA?($0) }   // AppInstaller queues them
        media.forEach { onDropMedia?($0) }
        let omitted = dropped(sender, .unsupported)
        if !omitted.isEmpty { onDropUnsupportedFiles?(omitted) }
        return true
    }

    private func dropped(_ sender: NSDraggingInfo, _ kind: DroppedFiles) -> [URL] {
        DroppedFiles.files(sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [], kind)
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
/// The touch phases of qemu-ios-ui.h (LinkCommand.touch).
private enum TouchPhase {
    static let begin: Int32 = 0, update: Int32 = 1, end: Int32 = 2
}

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
