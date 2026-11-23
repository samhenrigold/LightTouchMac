import Cocoa
import DeviceRuntime
import HostRuntime
import LightTouchCore

extension DisplayView {
    /// Frames come from the helper's IOSurface ring: the layer shows the front
    /// surface itself (no copy), and only the 3D model, which needs a texture,
    /// gets a CGImage made from it. Liveness and status are EmulatorController's
    /// own poll, so a hidden device (no display link) keeps them.
    @objc func step() {
        if let generation = emulator?.shakeGeneration, generation != lastShakeGeneration {
            lastShakeGeneration = generation
            modelView?.shake()
        }
        if let modelView, modelView.advanceAnimations(), let rect = modelView.homeButtonRect {
            homeButton.frame = convert(rect, from: modelView)
        }
        updateTouchOverlay()
        updateKeyboardPointer()
        updateTremble()
        _ = currentFrame()
        // The guest's orientation can change after its turned picture arrived (the A4 boards' SpringBoard query
        // answers later): with a static screen no new frame would lay it out.
        if emulator?.rotationDegrees != lastRotation { needsLayout = true }
    }

    /// While the guest runs its vibration motor the whole device trembles a point either way (not with Reduce Motion).
    private func updateTremble() {
        guard let layer else { return }
        let trembling =
            emulator?.vibrating == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard trembling != (layer.animation(forKey: "tremble") != nil) else { return }
        guard trembling else { return layer.removeAnimation(forKey: "tremble") }
        let tremble = CABasicAnimation(keyPath: "sublayerTransform.translation.x")
        tremble.fromValue = -1
        tremble.toValue = 1
        tremble.duration = 0.03
        tremble.autoreverses = true
        tremble.repeatCount = .infinity
        layer.add(tremble, forKey: "tremble")
    }

    /// The newest ring surface, shown if it is new. The ring reader belongs to
    /// one thread; the display link and captures are both on main.
    func currentFrame() -> IOSurface? {
        guard let frame = emulator?.link?.frontSurface() else { return shownSurface }
        guard frame.serial != shownSerial || frame.surface !== shownSurface else { return frame.surface }
        shownSerial = frame.serial
        shownSurface = frame.surface
        let newFramePixels = CGSize(width: frame.surface.width, height: frame.surface.height)
        let geometryChanged = newFramePixels != framePixels
        if geometryChanged {
            framePixels = newFramePixels
            needsLayout = true
        }
        // A turn leaves the panel's scan as it is, so the frame's size can't tell of it. Ask the emulator directly:
        // it is the source of truth for the pose, and layout() compares against the same value to decide whether to
        // animate.
        if emulator?.rotationDegrees != lastRotation { needsLayout = true }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The frame is opaque (the emulator's from C API 2.6, else FrameRingWriter.copy forces it): iBoot
        // and the iPod's framebuffer leave the alpha byte 0, which a layer would honor.
        contentLayer.contents = frame.surface
        // The frame and its geometry go up in one transaction (layout would put the bounds and turn up a pass later).
        if geometryChanged { layoutContent() }
        if showsHandoff {
            // The new boot's first frame: the hand-off and its "Restarting at…" are over (state audit C-4).
            showsHandoff = false
            restartTitle = nil
            needsLayout = true
        }
        if let model = modelView ?? pendingModelView, let image = Self.image(frame.surface, colorSpace: colorSpace) {
            model.updateFrame(image)
        }
        CATransaction.commit()
        return frame.surface
    }

    /// A copy of a ring surface, held in use while it is read so the helper
    /// never writes into it. noneSkipFirst, NOT premultipliedFirst: the panel
    /// is opaque (ui/cocoa.m ignores alpha for the same reason).
    static func image(_ surface: IOSurface, colorSpace: CGColorSpace) -> CGImage? {
        surface.incrementUseCount()
        surface.lock(options: .readOnly, seed: nil)
        let data = Data(bytes: surface.baseAddress, count: surface.bytesPerRow * surface.height)
        surface.unlock(options: .readOnly, seed: nil)
        surface.decrementUseCount()
        let info: CGBitmapInfo = [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)]
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: surface.width,
            height: surface.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: surface.bytesPerRow,
            space: colorSpace,
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    var isShowingLiveText: Bool { liveTextView != nil }
    func toggleLiveText() {
        if liveTextView != nil {
            endLiveText()
            return
        }
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

    private static let touchFadeDuration = 0.16

    func sendVisualTouch(_ slot: Int32, _ phase: Int32, _ x: Double, _ y: Double, keyboard: Bool = false) {
        if !keyboard { endKeyboardTouch() }
        guard touchInteractionEnabled else {
            if phase == TouchPhase.end { emulator?.link?.send(.touch(slot: Int(slot), phase: Int(phase), x: x, y: y)) }
            clearTouchOverlay()
            return
        }
        noteTouch(slot: Int(slot), phase: phase, x: x, y: y)
        emulator?.link?.send(.touch(slot: Int(slot), phase: Int(phase), x: x, y: y))
    }
    func sendVisualTouch2(_ phase: Int32, _ x: Double, _ y: Double) {
        guard touchInteractionEnabled else {
            if phase == TouchPhase.end { emulator?.link?.send(.touch2(phase: Int(phase), x: x, y: y)) }
            clearTouchOverlay()
            return
        }
        noteTouch(slot: 1, phase: phase, x: x, y: y)
        emulator?.link?.send(.touch2(phase: Int(phase), x: x, y: y))
    }
    private func noteTouch(slot: Int, phase: Int32, x: Double, y: Double) {
        visibleTouches[slot] = (
            CGPoint(x: x, y: y), phase == TouchPhase.end ? CACurrentMediaTime() + Self.touchFadeDuration : .infinity
        )
        updateTouchOverlay()
    }
    var touchInteractionEnabled: Bool {
        emulator?.acceptsInput == true && emulator?.isSleeping != true && !isShowingLiveText
    }
    private func clearTouchOverlay() {
        visibleTouches.removeAll()
        for layer in touchLayers.values { layer.removeFromSuperlayer() }
        touchLayers.removeAll()
    }
    private var activeTouches: [(slot: Int, point: CGPoint, opacity: CGFloat)] {
        guard touchInteractionEnabled else {
            clearTouchOverlay()
            return []
        }
        let now = CACurrentMediaTime()
        visibleTouches = visibleTouches.filter { $0.value.expires > now }
        guard showsTouches else { return [] }
        return visibleTouches.map { slot, value in
            (slot, value.point, CGFloat(min(1, (value.expires - now) / Self.touchFadeDuration)))
        }
    }
    func updateTouchOverlay() {
        let touches = activeTouches
        let liveSlots = Set(touches.map(\.slot))
        for slot in Array(touchLayers.keys) where !liveSlots.contains(slot) {
            touchLayers.removeValue(forKey: slot)?.removeFromSuperlayer()
        }
        // This overlay uses view coordinates, independent of the scaled shell.
        let diameter: CGFloat = 44
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Called with every frame: set only what changed, so a still overlay sends Core Animation nothing.
        let overlay = layer?.bounds ?? bounds
        if touchOverlayLayer.frame != overlay { touchOverlayLayer.frame = overlay }
        for touch in touches {
            let dot: CALayer
            if let existing = touchLayers[touch.slot] {
                dot = existing
            } else {
                dot = CALayer()
                dot.actions = ["opacity": NSNull(), "position": NSNull()]
                dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
                let gradient = CAGradientLayer()
                gradient.colors = [
                    NSColor.white.withAlphaComponent(0.95).cgColor,
                    NSColor(white: 0.94, alpha: 0.9).cgColor
                ]
                gradient.startPoint = CGPoint(x: 0.5, y: 0)
                gradient.endPoint = CGPoint(x: 0.5, y: 1)
                gradient.masksToBounds = true
                gradient.frame = dot.bounds
                gradient.cornerRadius = diameter / 2
                dot.addSublayer(gradient)
                dot.shadowColor = NSColor.black.cgColor
                dot.shadowOpacity = 0.22
                dot.shadowRadius = 5
                dot.shadowOffset = CGSize(width: 0, height: 2)
                // Made once: a new path each frame would have the shadow rendered again each frame.
                dot.shadowPath = CGPath(ellipseIn: dot.bounds, transform: nil)
                touchOverlayLayer.addSublayer(dot)
                touchLayers[touch.slot] = dot
            }
            dot.position = projectedPanelPoint(touch.point)
            dot.opacity = Float(touch.opacity)
        }
        CATransaction.commit()
    }

    /// Reads the newest ring surface under a use count, so capture is current
    /// even when paused, hidden or minimized and never reads a recycled slot.
    func captureFrame(includeTouches: Bool = true) -> CGImage? {
        if let liveTextView { return liveTextView.capturedImage }
        guard let image = capturePanelFrame(includeTouches: includeTouches) else { return nil }
        // Match the window: scan-to-upright plus the device's own quarter-turn.
        let turns = PanelCapture.quarterTurns(guestTurn: guestTurn, deviceDegrees: emulator?.rotationDegrees ?? 0)
        guard turns != 0 else { return image }
        return PanelCapture.rotated(image, clockwiseQuarterTurns: turns) ?? image
    }

    private func capturePanelFrame(includeTouches: Bool) -> CGImage? {
        guard let surface = currentFrame(), let image = Self.image(surface, colorSpace: colorSpace) else { return nil }
        let width = image.width
        let height = image.height
        let info: CGBitmapInfo = [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)]
        let touches = includeTouches ? activeTouches : []
        guard !touches.isEmpty,
            let context = CGContext(
                data: nil,
                width: Int(width),
                height: Int(height),
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: info.rawValue
            )
        else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: Int(width), height: Int(height)))
        let pixelScale = CGFloat(width) / max(contentLayer.bounds.width * appliedScale, 1)
        let diameter = 44 * pixelScale
        let colors =
            [
                NSColor.white.withAlphaComponent(0.95).cgColor,
                NSColor(white: 0.94, alpha: 0.9).cgColor
            ] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else {
            return image
        }
        for touch in touches {
            let rect = CGRect(
                x: touch.point.x * CGFloat(width) - diameter / 2,
                y: (1 - touch.point.y) * CGFloat(height) - diameter / 2,
                width: diameter,
                height: diameter
            )
            context.saveGState()
            context.setAlpha(touch.opacity)
            context.setShadow(
                offset: CGSize(width: 0, height: -2 * pixelScale),
                blur: 5 * pixelScale,
                color: NSColor.black.withAlphaComponent(0.22).cgColor
            )
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: rect)
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.addEllipse(in: rect)
            context.clip()
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: rect.maxY),
                end: CGPoint(x: rect.midX, y: rect.minY),
                options: []
            )
            context.restoreGState()
        }
        return context.makeImage()
    }
    /// The screen's pixels as captured now, turned as the window shows them: a screen-only recording's frame.
    var capturedScreenSize: CGSize {
        captureFrame(includeTouches: false).map { CGSize(width: $0.width, height: $0.height) } ?? nativeScreenPixels
    }
    var screenImage: NSImage? {
        get async {
            guard let cg = captureFrame() else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }
}
