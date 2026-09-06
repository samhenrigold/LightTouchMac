import AppKit
import RealityKit

/// The live LCD is a material on the asset, with input projected onto that same surface.
@MainActor
final class DeviceModelView: NSView {
  private let renderer = ARView(frame: .zero)
  private let chassis = Entity()
  private let camera = PerspectiveCamera()
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
    anchor.addChild(chassis)
    anchor.addChild(camera)
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
    screenMaterial.color = .init(tint: .black)
    updateScreenMaterial()
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { fatalError("not used") }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func layout() {
    super.layout()
    renderer.frame = bounds
  }

  func pose(scale: CGFloat, rotation: Int, roll: CGFloat, pitch: CGFloat, animated: Bool) {
    self.rotation = rotation
    let rest = Float(rotation == 270 ? -90 : rotation) * .pi / 180
    let units = Float(scale * 594 / 0.0499 / 10000)
    let pose = Transform(
      scale: SIMD3(repeating: units),
      rotation: simd_quatf(angle: -rest, axis: [0, 0, 1])
        * simd_quatf(angle: Float(pitch), axis: [1, 0, 0])
        * simd_quatf(angle: Float(roll), axis: [0, 1, 0]), translation: .zero)
    if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      chassis.move(to: pose, relativeTo: chassis.parent, duration: 0.4, timingFunction: .easeInOut)
    } else {
      chassis.stopAllAnimations()
      chassis.transform = pose
    }
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
      screenMaterial.color = .init(tint: .white, texture: .init(screenTexture))
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
    guard let start = shakeStarted else { return }
    let t = CACurrentMediaTime() - start
    if t >= 0.45 {
      chassis.position.x = 0
      shakeStarted = nil
    } else {
      chassis.position.x = Float(sin(t * .pi * 16 / 0.45) * 0.0018 * (1 - t / 0.45))
    }
  }
}
