#!/usr/bin/env python3
"""Render a board's flat shell art (the prepare screen's picture, DisplayView's fallback) from its 3D model.

The iPod touch 2G's shell.png is a cut-out product photo; the 1G has no such photo without screen content, so
its art is the N45 model itself: DeviceModelView (materials tuned as in the app) rendered face-on, screen off,
headless with RealityRenderer (no window), cropped to the chassis. Prints the shell size, screen cutout and
Home button numbers that DeviceProfile+Display.swift needs for that art.

  scripts/render-shell-art.py N45 LightTouchMac/Assets.xcassets/shell-1g.imageset/shell-1g.png
"""
from pathlib import Path
import subprocess, sys, tempfile
root = Path(__file__).resolve().parents[1]
name, out = sys.argv[1], Path(sys.argv[2]).resolve()
source = r'''import AppKit
import RealityKit
import Metal
@main struct Render {
 @MainActor static func main() async throws {
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.prohibited)
  let profile: DeviceProfile = ["N72": .iPodTouch2G, "K48": .iPad1, "N45": .iPodTouch1G][CommandLine.arguments[2]]!
  let model = try await DeviceModelView(url: URL(fileURLWithPath: CommandLine.arguments[1]), profile: profile)
  let size = CGSize(width: 800, height: 1400)
  model.frame = NSRect(origin: .zero, size: size)
  // Scale 0.5 at 2x: one output pixel per shell pixel.
  model.pose(scale: 0.5, rotation: 0, roll: 0, pitch: 0, animated: false)
  // The 2G shell's palette (a product photo): near-black glass (8, 7, 8) and a dark blue-grey LCD
  // (14, 18, 22), so the two iPods read as siblings; the rim and Home keep the model's own lighting.
  let screen = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  screen.setFillColor(CGColor(srgbRed: 14 / 255, green: 18 / 255, blue: 22 / 255, alpha: 1))
  screen.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
  model.updateFrame(screen.makeImage()!)
  var glass = UnlitMaterial(applyPostProcessToneMap: false)
  glass.color = .init(tint: NSColor(srgbRed: 8 / 255, green: 7 / 255, blue: 8 / 255, alpha: 1))
  func paint(_ e: Entity) {
    if var m = e.components[ModelComponent.self] {
      if m.materials.contains(where: { ["glass", "Display5___inactive_LCD_perimeter"].contains(($0 as? PhysicallyBasedMaterial)?.name ?? "") }) {
        m.materials = m.materials.map { _ in glass }; e.components.set(m)
      }
    }
    e.children.forEach(paint)
  }
  paint((model.subviews[0] as! ARView).scene.anchors.first!)
  // Project before the anchors move to the offscreen renderer: ARView projects with its own scene's camera.
  let corners = [model.projectedPoint(CGPoint(x: 0, y: 0)), model.projectedPoint(CGPoint(x: 1, y: 1))]
  let home = model.homeButtonRect!
  let view = model.subviews[0] as! ARView
  let anchors = Array(view.scene.anchors)
  for anchor in anchors { view.scene.removeAnchor(anchor) }
  let renderer = try RealityRenderer()
  for anchor in anchors { renderer.entities.append(anchor) }
  func camera(_ e: Entity) -> Entity? { e is PerspectiveCamera ? e : e.children.lazy.compactMap(camera).first }
  renderer.activeCamera = anchors.lazy.compactMap(camera).first!
  renderer.lighting.resource = view.environment.lighting.resource
  renderer.lighting.intensityExponent = view.environment.lighting.intensityExponent
  renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0, alpha: 0))
  let w = Int(size.width) * 2, h = Int(size.height) * 2
  let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: w, height: h, mipmapped: false)
  descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
  let texture = MTLCreateSystemDefaultDevice()!.makeTexture(descriptor: descriptor)!
  let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
  for _ in 0..<3 {
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
      do { try renderer.updateAndRender(deltaTime: 1.0 / 60, cameraOutput: output, onComplete: { _ in done.resume() }) }
      catch { done.resume(throwing: error) }
    }
  }
  var bytes = [UInt8](repeating: 0, count: w * h * 4)
  texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
  // Crop to the chassis (alpha), then report the LCD and Home in the crop's top-left pixels.
  var minX = w, minY = h, maxX = 0, maxY = 0
  for y in 0..<h { for x in 0..<w where bytes[(y * w + x) * 4 + 3] > 8 {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
  } }
  func pixel(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * 2 - CGFloat(minX), y: (size.height - p.y) * 2 - CGFloat(minY)) }
  let a = pixel(corners[0]), b = pixel(corners[1])
  let homeBottom = pixel(CGPoint(x: home.midX, y: home.minY)).y
  let cw = maxX - minX + 1, ch = maxY - minY + 1
  print("shellPixels \(cw)x\(ch)  screenCutout x=\(a.x) y=\(a.y) w=\(b.x - a.x) h=\(b.y - a.y)  home diameter \(home.width * 2) bottom inset \(CGFloat(ch) - homeBottom)")
  let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
    space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  let crop = context.makeImage()!.cropping(to: CGRect(x: minX, y: minY, width: cw, height: ch))!
  try NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
 }
}
'''
with tempfile.TemporaryDirectory(prefix="ltm-shell-art-") as tmp:
    work = Path(tmp)
    app = work / "Render.app/Contents"
    (app / "MacOS").mkdir(parents=True)
    (app / "Resources").mkdir()
    (app / "Resources/N72Studio.realityenv").symlink_to(root / "LightTouchMac/N72Studio.realityenv")
    (app / "Resources/N45Rim.realityenv").symlink_to(root / "LightTouchMac/N45Rim.realityenv")
    (work / "render.swift").write_text(source)
    exe = app / "MacOS/render"
    src = root / "LightTouchMac"
    subprocess.run(["swiftc", "-module-cache-path", str(work / "modules"), "-default-isolation", "MainActor",
                    str(src / "UI/DeviceModelView.swift"), str(src / "Device/DeviceProfile.swift"),
                    str(src / "Device/DeviceProfile+Display.swift"), str(work / "render.swift"), "-o", str(exe)], check=True)
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(exe), str(src / f"{name}.usdz"), name, str(out)], check=True, timeout=120)
