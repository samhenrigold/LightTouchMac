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
  private var screenMaterial: UnlitMaterial = {
    if #available(macOS 15, *) { return UnlitMaterial(applyPostProcessToneMap: false) }
    return UnlitMaterial()
  }()
  private var screenTexture: TextureResource?
  private var rotation = 0
  private var screenOff = false
  private var shakeStarted: CFTimeInterval?

  @available(macOS 15, *)
  init(url: URL) async throws {
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
        userInfo: [NSLocalizedDescriptionKey: "N72 is missing its display or Home button."])
    }
    self.display = display
    self.home = home
    displayBounds = display.visualBounds(relativeTo: display)
    super.init(frame: .zero)
    renderer.autoresizingMask = [.width, .height]
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
    // A black seat closes the asset's gap, which otherwise exposes steel around Home.
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
    func tune(_ entity: Entity) {
      if var model = entity.components[ModelComponent.self] {
        model.materials = model.materials.map { material in
          guard var finish = material as? PhysicallyBasedMaterial else { return material }
          let name = finish.name ?? entity.name
          if name.contains("Black_glass") {
            finish.specular = .init(floatLiteral: 0)
            finish.baseColor = .init(tint: NSColor(white: 0.018, alpha: 1))
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
    renderer.frame = bounds
    chassisShadow.frame = bounds
  }

  func pose(scale: CGFloat, rotation: Int, roll: CGFloat, pitch: CGFloat, animated: Bool, spring: Bool = false) {
    self.rotation = rotation
    let rest = Float(rotation == 270 ? -90 : rotation) * .pi / 180
    let units = Float(scale * 594 / 0.0499 / 10000)
    let pose = Transform(
      scale: SIMD3(repeating: units),
      rotation: simd_quatf(angle: Float(pitch), axis: [1, 0, 0])
        * simd_quatf(angle: Float(roll), axis: [0, 1, 0])
        * simd_quatf(angle: -rest, axis: [0, 0, 1]), translation: .zero)
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
    camera.camera.fieldOfViewInDegrees = Float(
      2 * atan(Double(max(bounds.height, 1)) / 6000) * 180 / .pi)
    let offset: SIMD2<Float>
    switch rotation {
    case 90: offset = [1, 0]
    case 180: offset = [1, 1]
    case 270: offset = [0, 1]
    default: offset = .zero
    }
    if #available(macOS 15, *) {
      screenMaterial.textureCoordinateTransform = .init(offset: offset, rotation: rest)
    }
    updateScreenMaterial()
    advanceAnimations()
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
    } catch { NSLog("N72 framebuffer upload failed: %@", error.localizedDescription) }
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
  private func surfacePoint(_ p: CGPoint) -> CGPoint {
    switch rotation {
    case 90: return CGPoint(x: 1 - p.y, y: p.x)
    case 180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
    case 270: return CGPoint(x: p.y, y: 1 - p.x)
    default: return p
    }
  }
  private func portraitPoint(_ p: CGPoint) -> CGPoint {
    switch rotation {
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
  func isChassis(_ point: CGPoint) -> Bool {
    guard panelPoint(point) == nil, let p = intersection(point, entity: chassis, z: 0.004) else {
      return false
    }
    let x = max(abs(p.x) - 0.023, 0)
    let y = max(abs(p.y) - 0.047, 0)
    return x * x + y * y <= 0.008 * 0.008
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
        chassis.position = [wave * 0.0018, cross * 0.0005, cross * 0.0008]
        chassis.orientation = simd_quatf(angle: cross * 0.035, axis: [1, 0, 0])
          * simd_quatf(angle: wave * 0.06, axis: [0, 1, 0]) * basePose.rotation
      }
    }
    // Project the rounded chassis outline; never shadow the rectangular ARView.
    let path = CGMutablePath()
    let radius = min(shellBounds.extents.x, shellBounds.extents.y) * 0.12
    for corner in 0..<4 {
      let right = corner == 0 || corner == 3
      let top = corner < 2
      let center = SIMD2<Float>(right ? shellBounds.max.x-radius : shellBounds.min.x+radius,
                                top ? shellBounds.max.y-radius : shellBounds.min.y+radius)
      for step in 0...8 {
        let angle = Float(corner) * .pi / 2 + Float(step) * .pi / 16
        let local = SIMD3<Float>(center.x + cos(angle)*radius, center.y + sin(angle)*radius, 0.004)
        guard let point = renderer.project(chassis.convert(position: local, to: nil)) else { continue }
        if path.isEmpty { path.move(to: point) } else { path.addLine(to: point) }
      }
    }
    path.closeSubpath()
    chassisShadow.shadowPath = path
  }
}
