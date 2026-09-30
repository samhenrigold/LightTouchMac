#!/usr/bin/env python3
"""Every board's 3D model, rendered headless, and production DisplayView input. Uses a disposable app, no QEMU."""
from pathlib import Path
import os, subprocess, sys, tempfile
root=Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root/"scripts"))
import sources as pins  # the pinned checkouts (build-support/sources.json)
model_source = r'''import AppKit
import RealityKit
import Metal
func - (a:CGPoint,b:CGPoint)->CGPoint { CGPoint(x:a.x-b.x,y:a.y-b.y) }
let profiles: [String: DeviceProfile] = ["N72": .iPodTouch2G, "K48": .iPad1, "N45": .iPodTouch1G]
/// Renders the model's own scene headless: RealityRenderer draws the same
/// entities and camera into a texture, so no window is ever shown and the
/// check runs with the display asleep. Pixel (x, y) is the view's y-up point.
@MainActor func render(_ model: DeviceModelView) async throws -> CGImage {
  let view = model.subviews[0] as! ARView
  let anchors = Array(view.scene.anchors)
  for anchor in anchors { view.scene.removeAnchor(anchor) }
  defer { for anchor in anchors { view.scene.addAnchor(anchor) } }
  let renderer = try RealityRenderer()
  for anchor in anchors { renderer.entities.append(anchor) }
  func camera(_ e: Entity) -> Entity? { e is PerspectiveCamera ? e : e.children.lazy.compactMap(camera).first }
  renderer.activeCamera = anchors.lazy.compactMap(camera).first!
  renderer.lighting.resource = view.environment.lighting.resource
  renderer.lighting.intensityExponent = view.environment.lighting.intensityExponent
  renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0.5, alpha: 1))
  let w = Int(model.bounds.width) * 2, h = Int(model.bounds.height) * 2
  let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: w, height: h, mipmapped: false)
  descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
  let texture = MTLCreateSystemDefaultDevice()!.makeTexture(descriptor: descriptor)!
  let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
  // Twice: the first pass can precede material and texture uploads.
  for _ in 0..<2 {
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
      do { try renderer.updateAndRender(deltaTime: 1.0 / 60, cameraOutput: output, onComplete: { _ in done.resume() }) }
      catch { done.resume(throwing: error) }
    }
  }
  var bytes = [UInt8](repeating: 0, count: w * h * 4)
  texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
  let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
    space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  return context.makeImage()!
}
/// RealityKit writes Display P3: compare raw P3 components with P3 references.
func color(_ image: CGImage, _ p: CGPoint, in size: CGSize) -> NSColor {
  let rep = NSBitmapImageRep(cgImage: image)
  var pixel = [Int](repeating: 0, count: 4)
  rep.getPixel(&pixel, atX: Int(p.x / size.width * CGFloat(rep.pixelsWide)), y: Int((1 - p.y / size.height) * CGFloat(rep.pixelsHigh)))
  return NSColor(displayP3Red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
}
func save(_ image: CGImage, _ path: String) throws {
  try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
/// Upright quadrants (red, green / blue, yellow), a centre circle and TOP, then
/// turned into the panel's own scan-out orientation (the iPad's is landscape).
func pattern(_ profile: DeviceProfile, rotation: Int) -> CGImage {
  let turnsBack = profile.panelRotation != 0 ? 1 : rotation / 90
  let upright = profile.uprightScreenPixels
  let size = turnsBack % 2 == 0 ? upright : CGSize(width: upright.height, height: upright.width)
  let w = Int(size.width), h = Int(size.height)
  let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  // Draw in the upright frame: turn the context so its y-up upright picture lands turned back.
  context.translateBy(x: size.width / 2, y: size.height / 2)
  context.rotate(by: CGFloat(turnsBack) * .pi / 2)
  context.translateBy(x: -upright.width / 2, y: -upright.height / 2)
  let colors: [NSColor] = [.red, .green, .blue, .yellow]
  for i in 0..<4 {
    context.setFillColor(colors[i].cgColor)
    context.fill(CGRect(x: CGFloat(i % 2) * upright.width / 2, y: CGFloat(1 - i / 2) * upright.height / 2, width: upright.width / 2, height: upright.height / 2))
  }
  let d = upright.width * 0.6
  context.setStrokeColor(.white); context.setLineWidth(upright.width * 0.02)
  context.strokeEllipse(in: CGRect(x: (upright.width - d) / 2, y: (upright.height - d) / 2, width: d, height: d))
  let text = NSAttributedString(string: "TOP", attributes: [.font: NSFont.boldSystemFont(ofSize: upright.width * 0.12), .foregroundColor: NSColor.white])
  let line = CTLineCreateWithAttributedString(text)
  let bounds = CTLineGetBoundsWithOptions(line, [])
  context.textPosition = CGPoint(x: (upright.width - bounds.width) / 2, y: upright.height * 0.9)
  CTLineDraw(line, context)
  return context.makeImage()!
}
@main struct Check {
 @MainActor static func main() async throws {
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.prohibited)
  let name = CommandLine.arguments[3], profile = profiles[name]!
  let lower = name.lowercased(), out = CommandLine.arguments[2]
  let model = try await DeviceModelView(url: URL(fileURLWithPath: CommandLine.arguments[1]), profile: profile)
  model.frame = NSRect(x: 0, y: 0, width: 800, height: 800)
  let cutout = profile.screenCutout.size
  /// The upright LCD's on-screen box: the four panel corners' projections.
  func lcdBox() -> CGRect {
    let points = [CGPoint(x:0,y:0), CGPoint(x:1,y:0), CGPoint(x:0,y:1), CGPoint(x:1,y:1)].map(model.projectedPoint)
    let xs = points.map(\.x), ys = points.map(\.y)
    return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
  }
  // Resize the actual ARView synchronously: the projection must keep the
  // LCD's physical aspect and size before an asynchronous layout catches up.
  for size in [CGSize(width:400,height:1000), CGSize(width:1200,height:450), CGSize(width:800,height:800)] {
    model.setFrameSize(size)
    model.pose(scale: 0.3, rotation: 0, roll: 0, pitch: 0, animated: false)
    let renderer = model.subviews[0] as! ARView
    precondition(renderer.bounds.size == size)
    let box = lcdBox()
    precondition(abs(box.width / box.height - cutout.width / cutout.height) < 0.003,
      "LCD stretched during resize to \(size): \(box.size)")
    precondition(abs(box.width - 0.3 * cutout.width) < 0.1, "Display scale changed with viewport aspect: \(box.width)")
  }
  // The panel's own axes on the upright model: the iPad's landscape panel is
  // mounted a quarter-turn clockwise, so its left edge (portrait SpringBoard's
  // status bar) is the device's top; the iPod's panel top is the top.
  let top = profile.panelRotation != 0 ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 0.5, y: 0)
  let bottom = CGPoint(x: 1 - top.x, y: 1 - top.y)
  let (t, b) = (model.projectedPoint(top), model.projectedPoint(bottom))
  precondition(t.y - b.y > 0.99 * lcdBox().height && abs(t.x - b.x) < 0.01, "Panel mounted the wrong way: top \(t) bottom \(b)")
  let shell = model.shellPixels
  print("\(name): display \(lcdBox().size) at scale 0.3; model outline \(shell) shell pixels (flat art \(profile.shellPixels))")
  precondition(shell.width > cutout.width && shell.height > cutout.height)
  // Transform world gravity into the actual model's axes and compare with
  // the production QEMU LIS302DL conversion, including compound landscape tilt.
  for flat in [false,true] {
   for rest: Float in [0, .pi/2, .pi, -.pi/2] {
    for roll: Float in [-0.6, 0, 0.4] {
     for pitch: Float in [-0.5, 0, 0.3] {
      let orientation = DeviceModelView.orientation(rest:rest,roll:roll,pitch:pitch,flat:flat)
      let visual = orientation.inverse.act(flat ? SIMD3<Float>(0,0,-1):SIMD3<Float>(0,-1,0))
      var sensorRoll = rest + roll, sensorPitch = pitch
      if flat {
       let x=sin(roll)*cos(pitch), y=sin(pitch), z = -cos(roll)*cos(pitch)
       let sx=cos(rest)*x-sin(rest)*y, sy=sin(rest)*x+cos(rest)*y
       sensorRoll=atan2(sx,-z);sensorPitch=atan2(sy,hypot(sx,z))
      }
      // EmulatorController reverses mounted roll and normalizes the seam.
      let degrees = -atan2(sin(sensorRoll),cos(sensorRoll))*180 / .pi
      var sensor=[Int8](repeating:0,count:3)
      precondition(ipod_attitude_vector(Double(sensorPitch*180 / .pi),Double(degrees),flat,&sensor))
      let backend=SIMD3<Float>(Float(sensor[0]),Float(sensor[1]),Float(sensor[2]))/64
      precondition(simd_length(visual-backend)<0.014,
        "Rendered tilt contradicts guest gravity flat=\(flat) rest=\(rest) roll=\(roll) pitch=\(pitch): \(visual) vs \(backend)")
     }
    }
   }
  }
  let points = [CGPoint(x: 0.25,y: 0.25), CGPoint(x: 0.75,y: 0.25), CGPoint(x: 0.25,y: 0.75), CGPoint(x: 0.75,y: 0.75)]
  var homeLevels: [CGFloat] = []
  // The iPod's surface arrives pre-rotated; the iPad's panel never turns.
  for rotation in [0,90,180,270] {
   let frame = pattern(profile, rotation: rotation)
   let reference = NSBitmapImageRep(cgImage: frame)
   model.updateFrame(frame)
   for tilt in [0.0,0.35] {
    model.pose(scale: 0.5, rotation: rotation, roll: tilt, pitch: tilt, animated: false)
    let snapshot = try await render(model)
    if tilt == 0 { try save(snapshot, out+"/\(lower)-orientation-\(rotation).png") }
    if rotation == 0 && tilt != 0 { try save(snapshot, out+"/\(lower)-tilted.png") }
    for p in points {
     let screen = model.projectedPoint(p)
     let hit = model.panelPoint(screen)!
     precondition(hypot(hit.x-p.x, hit.y-p.y) < 0.0001)
     let pixel = color(snapshot, screen, in: model.bounds.size)
     let expected = reference.colorAt(x: Int(p.x*CGFloat(frame.width)), y: Int(p.y*CGFloat(frame.height)))!.usingColorSpace(.displayP3)!
     precondition(abs(pixel.redComponent-expected.redComponent)<0.22 && abs(pixel.greenComponent-expected.greenComponent)<0.22 && abs(pixel.blueComponent-expected.blueComponent)<0.22, "Frame orientation mismatch rotation=\(rotation) tilt=\(tilt) point=\(p) pixel=\(pixel) reference=\(expected)")
    }
    if tilt == 0 {
      let rect = model.homeButtonRect!
      // Home sits below the LCD on the upright device, whichever way it is turned.
      let rest = CGFloat(rotation == 270 ? -90 : rotation) * .pi / 180
      let down = CGVector(dx: -sin(rest), dy: -cos(rest))   // y-up view; turns are clockwise
      let lcd = lcdBox()
      let offset = CGVector(dx: rect.midX - lcd.midX, dy: rect.midY - lcd.midY)
      precondition(offset.dx * down.dx + offset.dy * down.dy > 0.5 * max(lcd.width, lcd.height), "Home is not below the LCD at \(rotation): \(rect) vs \(lcd)")
      // The same spot on the cap in every orientation (the device's right of centre).
      let p = CGPoint(x: rect.midX + rect.width * 0.3 * cos(rest), y: rect.midY - rect.width * 0.3 * sin(rest))
      let level = color(snapshot, p, in: model.bounds.size)
      homeLevels.append(level.redComponent)
      precondition(level.redComponent < 0.35, "Home button washed out: \(rotation) \(level)")
      // The glyph's rounded square reads as a light ring on the black cap (K48's and N45's steel glyph vanished).
      if rotation == 0 {
        let rep = NSBitmapImageRep(cgImage: snapshot)
        var levels: [CGFloat] = []
        for i in 0..<40 { for j in 0..<40 {
          let q = CGPoint(x: rect.minX + rect.width * (CGFloat(i) + 0.5) / 40, y: rect.minY + rect.height * (CGFloat(j) + 0.5) / 40)
          guard hypot(q.x - rect.midX, q.y - rect.midY) < rect.width * 0.4 else { continue }
          var px = [Int](repeating: 0, count: 4)
          rep.getPixel(&px, atX: Int(q.x / model.bounds.width * CGFloat(rep.pixelsWide)), y: Int((1 - q.y / model.bounds.height) * CGFloat(rep.pixelsHigh)))
          levels.append((0.2126 * CGFloat(px[0]) + 0.7152 * CGFloat(px[1]) + 0.0722 * CGFloat(px[2])) / 255)
        } }
        levels.sort()
        let cap = levels[levels.count / 2], glyph = levels.last!
        print("\(name): Home glyph \(glyph) on cap \(cap)")
        precondition(glyph - cap > 0.25, "Home glyph barely visible: \(glyph) on \(cap)")
      }
    }
   }
  }
  precondition(homeLevels.max()! - homeLevels.min()! < 0.12, "Home lighting changes with orientation: \(homeLevels)")
  // Hardware controls: each named side control answers where it is drawn, and
  // the LCD and bezel are not controls.
  model.updateFrame(pattern(profile, rotation: 0))
  model.pose(scale: 0.5, rotation: 0, roll: 0, pitch: 0, animated: false)
  let view = model.subviews[0] as! ARView
  func projected(_ entity: Entity, _ fraction: SIMD3<Float>) -> CGPoint {
    let b = entity.visualBounds(relativeTo: nil)
    return model.convert(view.project(b.min + (b.max - b.min) * fraction)!, from: view)
  }
  var found: [String] = []
  for (names, expected) in [(["SleepWakeButton", "Sleep_wake___black_fitted_button"], [DeviceModelView.Control.sleepWake]),
                            (["VolumeButton", "Volume___continuous_recessed_centre_rocker"], [.volumeUp, .volumeDown])] {
    guard let entity = names.lazy.compactMap({ view.scene.findEntity(named: $0) }).first else { continue }
    found.append(entity.name)
    if expected.count == 1 {
      precondition(model.control(at: projected(entity, [0.5, 0.5, 0.5])) == expected[0], "\(entity.name) does not press")
    } else {
      precondition(model.control(at: projected(entity, [0.5, 0.8, 0.5])) == .volumeUp, "\(entity.name) upper half is not volume up")
      precondition(model.control(at: projected(entity, [0.5, 0.2, 0.5])) == .volumeDown, "\(entity.name) lower half is not volume down")
    }
  }
  precondition(model.control(at: model.projectedPoint(CGPoint(x: 0.5, y: 0.5))) == nil)
  let bezel = model.projectedPoint(CGPoint(x: bottom.x + (bottom.x - 0.5) * 0.12, y: bottom.y + (bottom.y - 0.5) * 0.12))
  precondition(model.isChassis(bezel) && model.control(at: bezel) == nil, "The bezel below the LCD must grab the chassis")
  print("\(name): controls \(found)")
  if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
    model.pose(scale: 0.5, rotation: 0, roll: 0, pitch: 0, animated: false)
    let rest = model.projectedPoint(top)
    model.pose(scale: 0.5, rotation: 0, roll: 0.4, pitch: 0, animated: false)
    let tilted = model.projectedPoint(top)
    model.pose(scale: 0.5, rotation: 0, roll: 0, pitch: 0, animated: true, spring: true)
    // A second layout with the same target must not cancel the spring.
    model.pose(scale: 0.5, rotation: 0, roll: 0, pitch: 0, animated: false)
    precondition(abs(model.projectedPoint(top).x-tilted.x)<1)
    // The overshoot lasts only ~0.17-0.43 s: sample the spring rather than one instant.
    // Past the rest pose, as a fraction of the release distance (the spring peaks near 0.17).
    var overshoot: CGFloat = 0
    let released = CACurrentMediaTime()
    while CACurrentMediaTime() - released < 0.6 {
      try await Task.sleep(for: .seconds(0.01)); model.advanceAnimations()
      overshoot = max(overshoot, (rest.x-model.projectedPoint(top).x)/(tilted.x-rest.x))
    }
    precondition(overshoot>0.05, "Spring must cross the resting pose: \(overshoot)")
    try await Task.sleep(for: .seconds(0.6)); model.advanceAnimations()
    precondition(abs(model.projectedPoint(top).x-rest.x)<0.01)
    // Some sample must sit well away from both the start and the end of the 0.4 s transition.
    let corner = CGPoint(x: 0.2, y: 0.3)
    let start = model.projectedPoint(corner)
    model.pose(scale: 0.8, rotation: 90, roll: 0, pitch: 0, animated: true)
    var path: [CGPoint] = []
    let turned = CACurrentMediaTime()
    while CACurrentMediaTime() - turned < 0.5 {
      try await Task.sleep(for: .seconds(0.01)); model.advanceAnimations()
      path.append(model.projectedPoint(corner))
    }
    let end = path.last!
    let between = path.map { min(hypot($0.x-start.x,$0.y-start.y), hypot($0.x-end.x,$0.y-end.y)) }.max()!
    precondition(between>10, "Rotation/scale must interpolate: \(between)")
  }
  model.pose(scale: 0.4, rotation: 0, roll: 0, pitch: 0, animated: false)
  try await Task.sleep(for: .seconds(0.1))
  let small = lcdBox().width
  model.pose(scale: 0.8, rotation: 0, roll: 0, pitch: 0, animated: false)
  try await Task.sleep(for: .seconds(0.1))
  let large = lcdBox().width
  precondition(abs(large/small-2)<0.001)
  let centre = model.projectedPoint(CGPoint(x:0.5,y:0.5))
  /// Opposite LCD edges' length differences: a translation (even in depth)
  /// keeps the face-on panel a rectangle, only a tilt makes it a trapezoid.
  /// (The box width is no measure: a tilt widens it, backing away narrows it,
  /// and mid-shake the two cancel.)
  func skew() -> CGPoint {
    let p = [CGPoint(x:0,y:0), CGPoint(x:1,y:0), CGPoint(x:0,y:1), CGPoint(x:1,y:1)].map(model.projectedPoint)
    func length(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x-b.x, a.y-b.y) }
    return CGPoint(x: length(p[0],p[1])-length(p[2],p[3]), y: length(p[0],p[2])-length(p[1],p[3]))
  }
  let restSkew = skew()
  // The wobble crosses its rest pose many times: sample it rather than one instant.
  var moved: CGFloat = 0, tilted: CGFloat = 0
  let shaken = CACurrentMediaTime()
  model.shake()
  while CACurrentMediaTime() - shaken < 0.25 {
    try await Task.sleep(for: .seconds(0.01))
    model.advanceAnimations()
    moved = max(moved, abs(model.projectedPoint(CGPoint(x:0.5,y:0.5)).x-centre.x))
    tilted = max(tilted, abs(skew().x-restSkew.x) + abs(skew().y-restSkew.y))
  }
  if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
    precondition(moved>1, "Shake must move the model: \(moved)")
    precondition(tilted>0.2, "Shake must change 3D perspective, not only position: \(tilted)")
  }
  try await Task.sleep(for: .seconds(0.5))
  model.advanceAnimations()
  precondition(abs(model.projectedPoint(CGPoint(x:0.5,y:0.5)).x-centre.x)<0.01)
  model.pose(scale: 0.5, rotation: 0, roll: 0, pitch: 0, animated: false)
  let face = try await render(model)
  try save(face, out+"/\(lower)-pattern.png")
  // N45 against Apple's product shot (touch_topsongs.jpg, colour-managed from its CMYK): a brushed graphite
  // frame lit from the upper left, sRGB ~150-175 there falling to ~85-100 at the lower right (the asset's
  // near-black frameDark alone gives ~0.03 everywhere; flat grey paint gives no gradient), and blue-black
  // glass, ~25, with a faint sheen (~43) to the upper right of a diagonal (N45Rim).
  if profile == .iPodTouch1G {
    func level(_ p: CGPoint) -> CGFloat {
      let c = color(face, model.projectedPoint(p), in: model.bounds.size)
      return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
    let lit = [CGPoint(x: -0.095, y: 0.2), CGPoint(x: 0.5, y: -0.217)].map(level)
    let shade = [CGPoint(x: 1.095, y: 0.8), CGPoint(x: 0.5, y: 1.217)].map(level)
    let sheen = level(CGPoint(x: 0.85, y: -0.1)), glass = [CGPoint(x: 0.05, y: -0.2), CGPoint(x: 0.15, y: 1.1)].map(level)
    print("N45: graphite frame lit \(lit) shaded \(shade); glass \(glass) sheen \(sheen)")
    precondition(lit.allSatisfy { $0 > 0.5 && $0 < 0.75 }, "N45 frame's upper left is not a light graphite: \(lit)")
    precondition(shade.allSatisfy { $0 > 0.28 && $0 < 0.45 }, "N45 frame's lower right is not a darker graphite: \(shade)")
    precondition(glass.allSatisfy { $0 > 0.06 && $0 < 0.15 } && sheen - glass.max()! > 0.05, "N45 glass is not blue-black with a sheen: \(glass) \(sheen)")
  }
  // Nearest-neighbour upscaling: a 4x6 black/white checker blown up to ~600 px must keep hard edges.
  // A linear mag filter ramps across each ~150 px cell, leaving a third or more of a scan mid-grey.
  do {
    let cw = 4, ch = 6
    let checker = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    for y in 0..<ch { for x in 0..<cw where (x + y) % 2 == 0 {
      checker.setFillColor(.white); checker.fill(CGRect(x: x, y: y, width: 1, height: 1))
    } }
    model.updateFrame(checker.makeImage()!)
    let shot = try await render(model)
    var mid = 0, total = 0
    for i in 0..<400 {
      let q = model.projectedPoint(CGPoint(x: 0.02 + 0.96 * Double(i) / 399, y: 0.25))
      let c = color(shot, q, in: model.bounds.size)
      if c.greenComponent > 0.15 && c.greenComponent < 0.85 { mid += 1 }
      total += 1
    }
    print("\(name): \(mid)/\(total) mid-grey samples across the upscaled checker")
    precondition(mid * 100 < total * 3, "LCD upscaling is not nearest-neighbour: \(mid)/\(total) blurred samples")
    model.updateFrame(pattern(profile, rotation: 0))
  }
  model.setScreenOff(true)
  let dark = color(try await render(model), model.projectedPoint(CGPoint(x: 0.5, y: 0.5)), in: model.bounds.size)
  precondition(dark.redComponent<0.05 && dark.greenComponent<0.05 && dark.blueComponent<0.05)
  print("PASS \(name): headless render of frame colors, projected touches, four orientations, two tilt axes, pixel sizing, controls, shake and screen off")
 }
}
'''
display_source = r'''import AppKit
import RealityKit
import IOSurface
@MainActor var touches: [(Double,Double)] = []
@MainActor var frameWidth: Int32 = 320, frameHeight: Int32 = 480
@MainActor var frameColor: UInt32 = 0xff2080c0
/// The helper's link: a fresh ring surface per frame, and touch commands.
@MainActor final class FakeLink {
 var serial: UInt64 = 0
 var surfaces: [String: IOSurface] = [:]
 func frontSurface() -> (surface: IOSurface, serial: UInt64, isNew: Bool)? {
  serial += 1
  let key = "\(frameWidth)x\(frameHeight)x\(frameColor)"
  let surface = surfaces[key] ?? {
   let s = IOSurface(properties: [.width: Int(frameWidth), .height: Int(frameHeight), .bytesPerElement: 4, .pixelFormat: 0x42475241])!
   s.lock(options: [], seed: nil)
   for y in 0..<Int(frameHeight) { for x in 0..<Int(frameWidth) { s.baseAddress.storeBytes(of: frameColor, toByteOffset: y * s.bytesPerRow + x * 4, as: UInt32.self) } }
   s.unlock(options: [], seed: nil)
   return s
  }()
  surfaces[key] = surface
  return (surface, serial, true)
 }
 func send(_ command: LinkCommand) { if case let .touch(_, _, x, y) = command { touches.append((x, y)) } }
}
struct CatalogApp: Decodable {}
extension NSPasteboard.PasteboardType { static let ltmCatalogApp=Self("test.catalog") }
enum PreparedMedia { nonisolated static let extensions: Set<String> = [] }
@MainActor final class SleepingAnimationView: NSView {}
@MainActor final class EmulatorController {
 enum Pose { case flat, upright }
 var motionPose=Pose.upright, rotationDegrees=0, acceptsInput=true, canQueueInstall=true
 var keyboardInputEnabled=true, keyboardTiltRate=90.0, isSleeping=false, isPoweredOff=false, shuttingDown=false
 var preparingDevice=false
 var shakeGeneration: UInt64=0, homeCount=0, lockCount=0, volume=0
 let link: FakeLink? = FakeLink()
 func pressLock() { lockCount += 1 };func powerOn() {}
 func pressVolumeUp() { volume += 1 };func pressVolumeDown() { volume -= 1 }
 var attitude = (angle: CGFloat.zero, pitch: CGFloat.zero)
 func shake() { shakeGeneration &+= 1 };func setTilt(angle:CGFloat,pitch:CGFloat) { attitude = (angle, pitch) }
 func pressHome() {homeCount += 1};func sendKey(macKeyCode:UInt16,down:Bool) {}
}
@main struct Check {
 @MainActor static func main() async throws {
  _=NSApplication.shared
  let profile: DeviceProfile = ["N72": .iPodTouch2G, "K48": .iPad1, "N45": .iPodTouch1G][CommandLine.arguments[3]]!
  let panel = profile.screenPixels, mounted = profile.panelRotation != 0
  frameWidth = Int32(panel.width); frameHeight = Int32(panel.height)
  let e=EmulatorController(), display=DisplayView(frame:NSRect(x:0,y:0,width:800,height:800),profile:profile)
  display.emulator=e
  let window=NSWindow(contentRect:display.frame,styleMask:[.titled,.resizable],backing:.buffered,defer:false)
  window.contentView=display;window.makeKeyAndOrderFront(nil)
  func settle() async throws {display.needsLayout=true;display.layoutSubtreeIfNeeded();try await Task.sleep(for: .seconds(0.5))}
  try await settle()
  for _ in 0..<20 where !display.subviews.contains(where: { ($0 as? DeviceModelView).map { !$0.isHidden && $0.alphaValue > 0.99 } ?? false }) { try await settle() }
  let model=display.subviews.compactMap{$0 as? DeviceModelView}.first!
  precondition(!model.isHidden && model.alphaValue > 0.99, "The live model must actually be visible")
  for rotation in [0,90,180,270] {
   // The iPod's surface turns with the device; the iPad's mounted panel does not.
   e.rotationDegrees=rotation
   if !mounted { frameWidth=Int32(rotation%180==0 ? panel.width:panel.height);frameHeight=Int32(rotation%180==0 ? panel.height:panel.width) }
   try await settle()
   for p in [CGPoint(x:0.2,y:0.3),CGPoint(x:0.8,y:0.7)] {
    let local=model.projectedPoint(p)
    let windowPoint=model.convert(local,to:nil)
    let event=NSEvent.mouseEvent(with:.leftMouseDown,location:windowPoint,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
    touches.removeAll();display.mouseDown(with:event);display.mouseUp(with:event)
    precondition(!touches.isEmpty && abs(touches[0].0-p.x)<0.001 && abs(touches[0].1-p.y)<0.001)
   }
  }
  e.rotationDegrees=0;frameWidth=Int32(panel.width);frameHeight=Int32(panel.height);try await settle()
  // Upright top and bottom in panel space (the iPad panel's left edge is the top).
  let (up, down) = mounted ? (CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)) : (CGPoint(x: 0.5, y: 0.1), CGPoint(x: 0.5, y: 0.9))
  let grab = model.projectedPoint(mounted ? CGPoint(x: -0.1, y: 0.5) : CGPoint(x: 0.5, y: -0.15))
  precondition(model.isChassis(grab))
  let rest = model.projectedPoint(CGPoint(x: 0.5, y: 0))
  func dragEvent(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: model.convert(point, to: nil), modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  }
  display.mouseDown(with: dragEvent(.leftMouseDown, grab))
  display.mouseDragged(with: dragEvent(.leftMouseDragged, CGPoint(x: grab.x+100, y: grab.y)))
  let tilted = model.projectedPoint(CGPoint(x: 0.5, y: 0))
  let top = model.projectedPoint(up)
  let bottom = model.projectedPoint(down)
  precondition(top.x-bottom.x > 10, "Upright horizontal drag must visibly roll for accelerometer steering")
  precondition(abs(e.attitude.angle - 0.4) < 0.0001 && abs(e.attitude.pitch) < 0.0001, "Visible steering must reach the accelerometer")
  precondition(abs(tilted.x-rest.x)>1)
  display.mouseUp(with: dragEvent(.leftMouseUp, grab))
  try await Task.sleep(for: .seconds(1.2))
  precondition(abs(model.projectedPoint(CGPoint(x: 0.5, y: 0)).x-rest.x)<0.1)
  precondition(model.layer!.sublayers!.contains { $0.shadowPath != nil && $0.shadowOpacity > 0 })
  // A click on a side control presses that button, not a touch or a tilt.
  let view = model.subviews[0] as! ARView
  if let sleep = ["SleepWakeButton", "Sleep_wake___black_fitted_button"].lazy.compactMap({ view.scene.findEntity(named: $0) }).first {
    let b = sleep.visualBounds(relativeTo: nil)
    let at = model.convert(view.project((b.min + b.max) / 2)!, from: view)
    touches.removeAll()
    display.mouseDown(with: dragEvent(.leftMouseDown, at)); display.mouseUp(with: dragEvent(.leftMouseUp, at))
    precondition(e.lockCount == 1 && touches.isEmpty, "The model's sleep/wake button must press power")
    e.lockCount = 0
  }
  e.isSleeping=true;display.updatePowerPresentation();touches.removeAll()
  let sleepBadge = display.subviews.compactMap { $0 as? NSStackView }.first!
  precondition(sleepBadge.arrangedSubviews.count == 2)
  precondition((sleepBadge.arrangedSubviews.last as? NSButton)?.title == "Wake Up")
  e.isPoweredOff=true;display.updatePowerPresentation()
  let offBadge = display.subviews.compactMap { $0 as? NSStackView }.first!
  precondition(offBadge.arrangedSubviews.count == 2)
  precondition((offBadge.arrangedSubviews.last as? NSButton)?.title == "Power On")
  e.isPoweredOff=false;display.updatePowerPresentation()
  let event=NSEvent.mouseEvent(with:.leftMouseDown,location:model.convert(model.projectedPoint(CGPoint(x:0.5,y:0.5)),to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
  display.mouseDown(with:event);precondition(touches.isEmpty)
  let space=NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
    windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
  display.keyDown(with: space); display.keyDown(with: space)
  precondition(e.lockCount==1, "Space wakes once without toggling back to sleep")
  e.preparingDevice=true; display.updatePowerPresentation()
  func labels(_ view: NSView) -> [String] {
    (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { labels($0) }
  }
  precondition(!labels(display).contains("Finishing device setup…"))
  precondition(!display.subviews.contains { $0 is NSStackView }, "Setup must leave the boot screen visible")
  e.preparingDevice=false;e.isSleeping=false;display.updatePowerPresentation()
  precondition(!labels(display).contains("Finishing device setup…"))
  window.orderOut(nil);window.contentView=nil
  print("PASS: integrated 3D screen input in all orientations; sleeping touch suppression")
 }
}
'''
# DisplayView's flat LCD layer, built without a window: its framebuffer upscales nearest-neighbour too.
layer_source = display_source.split('@main')[0] + r'''@main struct Check {
 @MainActor static func main() {
  let profile: DeviceProfile = ["N72": .iPodTouch2G, "K48": .iPad1, "N45": .iPodTouch1G][CommandLine.arguments[3]]!
  let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 800, height: 800), profile: profile)
  func all(_ l: CALayer) -> [CALayer] { [l] + (l.sublayers ?? []).flatMap(all) }
  // The LCD layer: black-backed, stretched to the cutout (it takes each frame's IOSurface as contents).
  let lcds = all(display.layer!).filter { $0.backgroundColor == NSColor.black.cgColor && $0.contentsGravity == .resize }
  precondition(lcds.count == 1, "expected one LCD layer, found \(lcds.count)")
  let lcd = lcds[0]
  precondition(lcd.magnificationFilter == .nearest, "DisplayView's LCD upscales with \(lcd.magnificationFilter.rawValue)")
  precondition(lcd.minificationFilter != .nearest, "DisplayView's LCD minification should filter")
  print("PASS: DisplayView LCD layer magnifies nearest, minifies \(lcd.minificationFilter.rawValue)")
 }
}
'''
# The model half renders headless (RealityRenderer, no window) for every board.
# The DisplayView half needs a presented ARView, which renders only in a visible
# window: it runs with LTM_DISPLAY_CHECKS=1. `check-model.py DIR` keeps the renders.
MODELS = ["N72", "K48", "N45"]
windowed = os.environ.get("LTM_DISPLAY_CHECKS") == "1"
with tempfile.TemporaryDirectory(prefix="ltm-model-") as tmp:
    work=Path(tmp)
    renders=Path(sys.argv[1]) if len(sys.argv) > 1 else work
    renders.mkdir(parents=True, exist_ok=True)
    app=work/"Check.app/Contents"
    (app/"MacOS").mkdir(parents=True)
    (app/"Resources").mkdir()
    for model in MODELS:
        (app/f"Resources/{model}.usdz").symlink_to(root/f"LightTouchMac/{model}.usdz")
    (app/"Resources/N72Studio.realityenv").symlink_to(root/"LightTouchMac/N72Studio.realityenv")
    (app/"Resources/N45Rim.realityenv").symlink_to(root/"LightTouchMac/N45Rim.realityenv")
    sources=root/"LightTouchMac"
    qemu=Path(os.environ["QEMU_SRC"]) if os.environ.get("QEMU_SRC") else pins.path("qemu-ios")
    attitude_header=qemu/"include/hw/arm/ipod-attitude.h"
    if not attitude_header.is_file():
        raise SystemExit("Set QEMU_SRC to the QEMU source tree for the production accelerometer comparison")
    profile=["Device/DeviceProfile", "Device/DeviceProfile+Display"]
    for name,source,extra in [
        ("model",model_source,profile),
        ("layer",layer_source,["UI/DisplayView", *profile, "UI/DisplayMeasurements", "UI/AttitudeIndicatorButton", "UI/InlineLiveTextView", "UI/DroppedFiles", "../Shared/DeviceLinkProtocol"]),
        *([("display",display_source,["UI/DisplayView", *profile, "UI/DisplayMeasurements", "UI/AttitudeIndicatorButton", "UI/InlineLiveTextView", "UI/DroppedFiles", "../Shared/DeviceLinkProtocol"])] if windowed else [])
    ]:
        swift=work/(name+".swift");swift.write_text(source)
        exe=app/"MacOS"/name
        bridge=["-import-objc-header",str(attitude_header)] if name == "model" else []
        subprocess.run(["swiftc","-module-cache-path",str(work/"modules"),"-default-isolation","MainActor",*bridge,str(sources/"UI/DeviceModelView.swift"),*[str(sources/(x+".swift")) for x in extra],str(swift),"-o",str(exe)],check=True)
        for model in MODELS:
            subprocess.run([str(exe),str(root/f"LightTouchMac/{model}.usdz"),str(renders),model],check=True,timeout=90)
    if not windowed:
        print("SKIP: DisplayView input with the presented model (a visible window); LTM_DISPLAY_CHECKS=1 runs it")
