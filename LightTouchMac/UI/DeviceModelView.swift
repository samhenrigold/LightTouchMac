import AppKit
import RealityKit
import Metal

/// The live LCD is a material on the asset, with input projected onto that same surface.
@MainActor
final class DeviceModelView: NSView {
  private let renderer = ARView(frame: .zero)
  private let chassis = Entity()
  private let camera = PerspectiveCamera()
  private let homeLighting = Entity()
  private let chassisShadow = CALayer()
  private var shellBounds = BoundingBox()
  private var targetPose: Transform?
  private var transition: (start: CFTimeInterval, from: Transform, to: Transform, spring: Bool)?
  private var basePose = Transform()
  private let display: Entity
  private let home: Entity
  private let displayBounds: BoundingBox
  /// The upright screen's width in shell pixels: pose and physical scale
  /// size the model's display to what the flat shell's cutout would be.
  private let screenWidth: Float
  /// A panel mounted a quarter-turn in the shell (the iPad's) keeps its
  /// surface mapping when the device turns; the iPod's pre-rotated surface
  /// follows the device. Either way the mapping is one of the four below.
  private let fixedSurfaceRotation: Int?
  enum Control: Equatable { case sleepWake, volumeUp, volumeDown }
  /// Side controls by node name (revision 7 names, then N72's own).
  private var controls: [(entity: Entity, isRocker: Bool)] = []
  private var screenMaterial: UnlitMaterial = {
    if #available(macOS 15, *) { return UnlitMaterial(applyPostProcessToneMap: false) }
    return UnlitMaterial()
  }()
  private var screenTexture: TextureResource?
  var viewportCenter: CGPoint? { didSet { updateViewport() } }
  private var rotation = 0
  private var screenOff = false
  private var shakeStarted: CFTimeInterval?

  @available(macOS 15, *)
  init(url: URL, profile: DeviceProfile) async throws {
    let loaded = try await Entity(contentsOf: url)
    func firstModel(_ entity: Entity) -> Entity? {
      if entity.components[ModelComponent.self] != nil { return entity }
      return entity.children.lazy.compactMap { firstModel($0) }.first
    }
    guard let surface = loaded.findEntity(named: "Display"), let display = firstModel(surface),
      let home = loaded.findEntity(named: "HomeButton")
    else {
      throw NSError(
        domain: "DeviceModel", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) is missing its display or Home button."])
    }
    self.display = display
    self.home = home
    displayBounds = display.visualBounds(relativeTo: display)
    screenWidth = Float(profile.screenCutout.width)
    // The clockwise panel quarter-turn is the iPod surface's 270° mapping.
    fixedSurfaceRotation = profile.panelRotation == 0 ? nil
      : (360 - Int((profile.panelRotation * 180 / .pi).rounded())) % 360
    for (names, isRocker) in [(["SleepWakeButton", "Sleep_wake___black_fitted_button"], false),
                              (["VolumeButton", "Volume___continuous_recessed_centre_rocker"], true)] {
      if let entity = names.lazy.compactMap({ loaded.findEntity(named: $0) }).first {
        controls.append((entity, isRocker))
      }
    }
    super.init(frame: .zero)
    addSubview(renderer)
    renderer.environment.background = .color(.clear)
    let anchor = AnchorEntity(world: .zero)
    chassis.addChild(loaded)
    shellBounds = loaded.visualBounds(relativeTo: chassis)
    anchor.addChild(chassis)
    anchor.addChild(camera)
    anchor.addChild(homeLighting)
    renderer.scene.addAnchor(anchor)
    camera.camera.near = 0.001
    camera.camera.far = 10
    camera.camera.fieldOfViewOrientation = .vertical
    // A black seat closes N72's gap, which otherwise exposes steel around Home.
    if profile == .iPodTouch2G {
      var rim = MeshDescriptor(name: "Home black gasket")
      var vertices: [SIMD3<Float>] = []
      var indices: [UInt32] = []
      for i in 0..<128 {
        let angle = Float(i) * 2 * .pi / 128
        for radius: Float in [0.00487, 0.00515] {
          vertices.append([cos(angle) * radius, sin(angle) * radius, 0])
        }
        let a = UInt32(i * 2)
        let b = UInt32(((i + 1) % 128) * 2)
        indices += [a, a + 1, b, b, a + 1, b + 1]
      }
      rim.positions = .init(vertices)
      rim.primitives = .triangles(indices)
      let seat = ModelEntity(
        mesh: try .generate(from: [rim]), materials: [UnlitMaterial(color: .black)])
      seat.position = [0, -0.0457, 0.004145]
      chassis.addChild(seat)
    }
    func tune(_ entity: Entity) {
      if var model = entity.components[ModelComponent.self] {
        model.materials = model.materials.map { material in
          guard var finish = material as? PhysicallyBasedMaterial else { return material }
          let name = finish.name ?? entity.name
          // N72's front glass, then revision 7's (K48, N45) and its LCD border under it.
          if name.contains("Black_glass") || name == "glass" || name.contains("inactive_LCD_perimeter") {
            finish.specular = .init(floatLiteral: 0)
            finish.baseColor = .init(tint: NSColor(white: 0.018, alpha: 1))
          }
          // Revision 7's Home glyph (K48, N45) is a dark steel that vanished on the black cap; a real
          // iPad's and iPod's square reads as a light grey ring. N72's ceramic glyph already does.
          if name == "glyph" {
            finish.baseColor = .init(tint: NSColor(white: 0.95, alpha: 1))
            finish.metallic = .init(floatLiteral: 0)
            finish.roughness = .init(floatLiteral: 0.5)
          }
          if name.contains("Concave") {
            finish.specular = .init(floatLiteral: 0.5)
            finish.roughness = .init(floatLiteral: 0.18)
          }
          return finish
        }
        entity.components.set(model)
      }
      for child in entity.children { tune(child) }
    }
    tune(loaded)
    let lighting = try await EnvironmentResource(named: "N72Studio", in: .main)
    renderer.environment.lighting.resource = lighting
    renderer.environment.lighting.intensityExponent = 2
    var homeLight = ImageBasedLightComponent(source: .single(lighting), intensityExponent: 2)
    homeLight.inheritsRotation = true
    homeLighting.components.set(homeLight)
    home.components.set(ImageBasedLightReceiverComponent(imageBasedLight: homeLighting))
    wantsLayer = true
    layer?.insertSublayer(chassisShadow, at: 0)
    chassisShadow.shadowColor = NSColor.black.cgColor
    chassisShadow.shadowOpacity = 0.4
    chassisShadow.shadowRadius = 24
    chassisShadow.shadowOffset = CGSize(width: 0, height: -6)
    chassisShadow.actions = ["shadowPath": NSNull(), "bounds": NSNull(), "position": NSNull()]
    screenMaterial.color = .init(tint: .black)
    updateScreenMaterial()
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { fatalError("not used") }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func layout() {
    super.layout()
    updateViewport()
  }
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    // AppKit can resize the backing view before its next layout pass. Update
    // the drawable and its projection together, including during live resize.
    updateViewport()
  }
  private func updateViewport() {
    renderer.frame = bounds
    if let center = viewportCenter {
      camera.position.x = -Float(center.x - bounds.midX) * camera.position.z / 3000
      camera.position.y = Float(center.y - bounds.midY) * camera.position.z / 3000
    }
    chassisShadow.frame = bounds
    camera.camera.fieldOfViewInDegrees = Float(
      2 * atan(Double(max(renderer.bounds.height, 1)) / 6000) * 180 / .pi)
  }

  /// Solve the resting front-face projection for a measured chassis height.
  func physicalScale(heightInPoints height: CGFloat) -> CGFloat {
    let projectedHeight = Float(height)
    let depth = displayBounds.max.z - shellBounds.max.z
    let units = projectedHeight * 0.3 / (3000 * shellBounds.extents.y - projectedHeight * depth)
    return CGFloat(units * displayBounds.extents.x * 10000 / screenWidth)
  }

  /// The model's upright outline in shell pixels (the flat shell's units), for fitting it.
  var shellPixels: CGSize {
    let pixels = screenWidth / displayBounds.extents.x
    return CGSize(width: CGFloat(shellBounds.extents.x * pixels), height: CGFloat(shellBounds.extents.y * pixels))
  }

  func pose(scale: CGFloat, rotation: Int, roll: CGFloat, pitch: CGFloat, yaw: CGFloat = 0, flat: Bool = false, animated: Bool, spring: Bool = false) {
    self.rotation = rotation
    let rest = Float(rotation == 270 ? -90 : rotation) * .pi / 180
    let units = Float(scale) * screenWidth / 10000 / displayBounds.extents.x
    let pose = Transform(
      scale: SIMD3(repeating: units),
      rotation: Self.orientation(rest: rest, roll: Float(roll), pitch: Float(pitch), yaw: Float(yaw), flat: flat), translation: .zero)
    // Layout may repeat while a transition is running; only a new target replaces it.
    if targetPose != pose {
      if animated && targetPose != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        transition = (CACurrentMediaTime(), basePose, pose, spring)
      } else {
        transition = nil
        basePose = pose
      }
      targetPose = pose
    }
    homeLighting.orientation = simd_quatf(angle: -rest, axis: [0, 0, 1])
    camera.position = [0, 0, 0.3 + units * displayBounds.max.z]
    updateViewport()
    let surface = surfaceRotation
    let offset: SIMD2<Float>
    switch surface {
    case 90: offset = [1, 0]
    case 180: offset = [1, 1]
    case 270: offset = [0, 1]
    default: offset = .zero
    }
    if #available(macOS 15, *) {
      screenMaterial.textureCoordinateTransform = .init(
        offset: offset, rotation: Float(surface == 270 ? -90 : surface) * .pi / 180)
    }
    updateScreenMaterial()
    advanceAnimations()
  }
  /// Match the accelerometer's gravity vector: upright games steer by roll,
  /// while flat games tilt the LCD about its horizontal and vertical axes.
  static func orientation(rest: Float, roll: Float, pitch: Float, yaw: Float = 0, flat: Bool = false) -> simd_quatf {
    let tilt = flat
      ? simd_quatf(angle: roll, axis: [0, 1, 0]) * simd_quatf(angle: -rest, axis: [0, 0, 1])
      : simd_quatf(angle: -roll-rest, axis: [0, 0, 1])
    return simd_quatf(angle: yaw, axis: [0, 1, 0])
      * simd_quatf(angle: -pitch, axis: [1, 0, 0]) * tilt
  }
  /// A snapshot is a rendering fence: asset loading alone does not mean
  /// RealityKit has prepared a drawable, lighting, and the first LCD texture.
  func prepareFirstFrame() async -> Bool {
    while !Task.isCancelled {
      // A view can finish loading before its window is attached or while the
      // window is minimized. Neither case means that the model failed.
      if window != nil, bounds.width > 0, bounds.height > 0,
        await requestFirstFrame() { return true }
      do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
    }
    return false
  }

  private final class FirstFrameRequest {
    var continuation: CheckedContinuation<Bool, Never>?
    func finish(_ ready: Bool) {
      let waiting = continuation
      continuation = nil
      waiting?.resume(returning: ready)
    }
  }

  private func requestFirstFrame() async -> Bool {
    let request = FirstFrameRequest()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        request.continuation = continuation
        guard !Task.isCancelled else { request.finish(false); return }
        renderer.snapshot(saveToHDR: false) { image in
          request.finish(image != nil)
        }
      }
    } onCancel: {
      // ARView has no snapshot cancellation API. Release our waiter when its
      // window closes; a later renderer callback becomes a harmless no-op.
      Task { @MainActor in request.finish(false) }
    }
  }
  func updateFrame(_ image: CGImage) {
    do {
      if let screenTexture {
        try screenTexture.replace(withImage: image, options: .init(semantic: .color))
      } else if #available(macOS 15, *) {
        screenTexture = try TextureResource(image: image, options: .init(semantic: .color))
      } else {
        screenTexture = try TextureResource.generate(from: image, options: .init(semantic: .color))
      }
      updateScreenMaterial()
    } catch { NSLog("Model framebuffer upload failed: %@", error.localizedDescription) }
  }
  private func updateScreenMaterial() {
    if let screenTexture, !screenOff {
      var sampler = MaterialParameters.Texture.Sampler()
      sampler.modify { descriptor in
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
      }
      screenMaterial.color = .init(tint: .white, texture: .init(screenTexture, sampler: sampler))
    } else {
      screenMaterial.color = .init(tint: .black)
    }
    guard var model = display.components[ModelComponent.self] else { return }
    model.materials = [screenMaterial]
    display.components.set(model)
  }
  func setScreenOff(_ off: Bool) {
    screenOff = off
    updateScreenMaterial()
  }
  private var surfaceRotation: Int { fixedSurfaceRotation ?? rotation }
  private func surfacePoint(_ p: CGPoint) -> CGPoint {
    switch surfaceRotation {
    case 90: return CGPoint(x: 1 - p.y, y: p.x)
    case 180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
    case 270: return CGPoint(x: p.y, y: 1 - p.x)
    default: return p
    }
  }
  private func portraitPoint(_ p: CGPoint) -> CGPoint {
    switch surfaceRotation {
    case 90: return CGPoint(x: p.y, y: 1 - p.x)
    case 180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
    case 270: return CGPoint(x: 1 - p.y, y: p.x)
    default: return p
    }
  }
  private func intersection(_ point: CGPoint, entity: Entity, z: Float) -> SIMD3<Float>? {
    guard let ray = renderer.ray(through: renderer.convert(point, from: self)) else { return nil }
    let near = entity.convert(position: ray.origin, from: nil)
    let direction = entity.convert(direction: ray.direction, from: nil)
    guard abs(direction.z) > 0.000001 else { return nil }
    let t = (z - near.z) / direction.z
    return t >= 0 ? near + direction * t : nil
  }
  func panelPoint(_ point: CGPoint, clamped: Bool = false) -> CGPoint? {
    guard let local = intersection(point, entity: display, z: displayBounds.max.z) else {
      return nil
    }
    let p = surfacePoint(
      CGPoint(
        x: CGFloat((local.x - displayBounds.min.x) / displayBounds.extents.x),
        y: CGFloat((displayBounds.max.y - local.y) / displayBounds.extents.y)))
    if clamped { return CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1)) }
    return CGRect(x: 0, y: 0, width: 1, height: 1).contains(p) ? p : nil
  }
  func projectedPoint(_ point: CGPoint) -> CGPoint {
    let p = portraitPoint(point)
    let local = SIMD3<Float>(
      displayBounds.min.x + Float(p.x) * displayBounds.extents.x,
      displayBounds.max.y - Float(p.y) * displayBounds.extents.y, displayBounds.max.z)
    guard let projected = renderer.project(display.convert(position: local, to: nil)) else {
      return .zero
    }
    return convert(projected, from: renderer)
  }
  var homeButtonRect: CGRect? {
    let b = home.visualBounds(relativeTo: home)
    let points = [(b.min.x, b.min.y), (b.max.x, b.min.y), (b.min.x, b.max.y), (b.max.x, b.max.y)]
      .compactMap { x, y in
        renderer.project(home.convert(position: [x, y, b.max.z], to: nil)).map {
          convert($0, from: renderer)
        }
      }
    guard points.count == 4 else { return nil }
    let xs = points.map(\.x)
    let ys = points.map(\.y)
    return CGRect(
      x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
  }
  /// The front outline as a rounded rectangle (N72's: 46 x 94 mm inside an 8 mm radius).
  private var cornerRadius: Float { min(shellBounds.extents.x, shellBounds.extents.y) * 0.13 }
  func isChassis(_ point: CGPoint) -> Bool {
    guard panelPoint(point) == nil, let p = intersection(point, entity: chassis, z: shellBounds.max.z) else {
      return false
    }
    let r = cornerRadius
    let x = max(abs(p.x - shellBounds.center.x) - (shellBounds.extents.x / 2 - r), 0)
    let y = max(abs(p.y - shellBounds.center.y) - (shellBounds.extents.y / 2 - r), 0)
    return x * x + y * y <= r * r
  }
  /// The side control under a point: a ray through each control's bounds, in
  /// the model's own axes, so it holds at any pose. A rocker's upper half is up.
  func control(at point: CGPoint) -> Control? {
    guard let ray = renderer.ray(through: renderer.convert(point, from: self)) else { return nil }
    let origin = chassis.convert(position: ray.origin, from: nil)
    let direction = chassis.convert(direction: ray.direction, from: nil)
    for (entity, isRocker) in controls {
      let b = entity.visualBounds(relativeTo: chassis)
      let t0 = (b.min - origin) / direction, t1 = (b.max - origin) / direction
      let near = simd_reduce_max(simd_min(t0, t1)), far = simd_reduce_min(simd_max(t0, t1))
      guard near <= far, far >= 0 else { continue }
      guard isRocker else { return .sleepWake }
      return (origin + direction * max(near, 0)).y > b.center.y ? .volumeUp : .volumeDown
    }
    return nil
  }
  func shake() {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
    shakeStarted = CACurrentMediaTime()
  }
  func advanceAnimations() {
    let now = CACurrentMediaTime()
    if let animation = transition {
      let t = now - animation.start
      let duration = animation.spring ? 1.1 : 0.4
      let fraction: Float
      if animation.spring {
        // Same unit-mass spring as the original CASpringAnimation: k=200, c=14.
        let frequency = sqrt(200.0 - 49.0)
        fraction = Float(1 - exp(-7 * t) * (cos(frequency * t) + 7 / frequency * sin(frequency * t)))
      } else {
        let x = min(t / duration, 1)
        fraction = Float(x * x * (3 - 2 * x))
      }
      basePose = Transform(scale: simd_mix(animation.from.scale, animation.to.scale, SIMD3(repeating: fraction)),
        rotation: simd_slerp(animation.from.rotation, animation.to.rotation, fraction), translation: .zero)
      if t >= duration { basePose = animation.to; transition = nil }
    }
    chassis.transform = basePose
    if let start = shakeStarted {
      let t = now - start
      if t >= 0.45 {
        shakeStarted = nil
      } else {
        let decay = Float(1 - t / 0.45)
        let wave = Float(sin(t * .pi * 16 / 0.45)) * decay
        let cross = Float(sin(t * .pi * 11 / 0.45)) * decay
        chassis.position = [wave * 0.00035, cross * 0.0001, cross * 0.00015]
        chassis.orientation = simd_quatf(angle: cross * 0.008, axis: [1, 0, 0])
          * simd_quatf(angle: wave * 0.012, axis: [0, 1, 0]) * basePose.rotation
      }
    }
    // Project the rounded chassis outline; never shadow the rectangular ARView.
    let path = CGMutablePath()
    let radius = cornerRadius
    for corner in 0..<4 {
      let right = corner == 0 || corner == 3
      let top = corner < 2
      let center = SIMD2<Float>(right ? shellBounds.max.x-radius : shellBounds.min.x+radius,
                                top ? shellBounds.max.y-radius : shellBounds.min.y+radius)
      for step in 0...8 {
        let angle = Float(corner) * .pi / 2 + Float(step) * .pi / 16
        let local = SIMD3<Float>(center.x + cos(angle)*radius, center.y + sin(angle)*radius, shellBounds.max.z)
        guard let point = renderer.project(chassis.convert(position: local, to: nil)) else { continue }
        if path.isEmpty { path.move(to: point) } else { path.addLine(to: point) }
      }
    }
    path.closeSubpath()
    chassisShadow.shadowPath = path
  }
}
