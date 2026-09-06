#!/usr/bin/env python3
"""Native N72 rendering and production DisplayView input. Uses a disposable app, no QEMU."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
model_source = r'''import AppKit
import RealityKit
@main struct Check {
 @MainActor static func main() async throws {
  _ = NSApplication.shared
  let model = try await DeviceModelView(url: URL(fileURLWithPath: CommandLine.arguments[1]))
  model.frame = NSRect(x: 0, y: 0, width: 800, height: 800)
  let window = NSWindow(contentRect: model.frame, styleMask: [.titled], backing: .buffered, defer: false)
  window.contentView = model; window.orderFront(nil)
  let colors: [NSColor] = [.red, .green, .blue, .yellow]
  let points = [CGPoint(x: 0.25,y: 0.25), CGPoint(x: 0.75,y: 0.25), CGPoint(x: 0.25,y: 0.75), CGPoint(x: 0.75,y: 0.75)]
  var homeLevels: [CGFloat] = []
  for rotation in [0,90,180,270] {
   let w = rotation % 180 == 0 ? 320 : 480, h = rotation % 180 == 0 ? 480 : 320
   let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
   for i in 0..<4 { context.setFillColor(colors[i].cgColor); context.fill(CGRect(x: i%2*w/2, y: i/2*h/2, width: w/2, height: h/2)) }
   model.updateFrame(context.makeImage()!)
   for tilt in [0.0,0.35] {
    model.pose(scale: 0.5, rotation: rotation, roll: tilt, pitch: tilt, animated: false)
    try await Task.sleep(for: .seconds(0.15))
    // HDR avoids the SDR snapshot tone mapper altering saturated test colors.
    let rendered: NSImage? = await withCheckedContinuation { continuation in
      (model.subviews[0] as! ARView).snapshot(saveToHDR: true) { continuation.resume(returning: $0) }
    }
    let snapshot = NSBitmapImageRep(data: rendered!.tiffRepresentation!)!
    for p in points {
     let screen = model.projectedPoint(p)
     let hit = model.panelPoint(screen)!
     precondition(hypot(hit.x-p.x, hit.y-p.y) < 0.0001)
     let pixel = snapshot.colorAt(x: Int(screen.x/800*CGFloat(snapshot.pixelsWide)), y: Int((1-screen.y/800)*CGFloat(snapshot.pixelsHigh)))!.usingColorSpace(.sRGB)!
     let reference = NSBitmapImageRep(cgImage: context.makeImage()!).colorAt(x: Int(p.x*CGFloat(w)), y: Int(p.y*CGFloat(h)))!.usingColorSpace(.sRGB)!
     precondition(abs(pixel.redComponent-reference.redComponent)<0.22 && abs(pixel.greenComponent-reference.greenComponent)<0.22 && abs(pixel.blueComponent-reference.blueComponent)<0.22, "Frame orientation mismatch rotation=\(rotation) tilt=\(tilt) point=\(p) pixel=\(pixel) reference=\(reference)")
    }
    if tilt == 0, let rect = model.homeButtonRect {
      let p = CGPoint(x: rect.midX + rect.width * 0.3, y: rect.midY)
      let color = snapshot.colorAt(x: Int(p.x/800*CGFloat(snapshot.pixelsWide)), y: Int((1-p.y/800)*CGFloat(snapshot.pixelsHigh)))!.usingColorSpace(.sRGB)!
      homeLevels.append(color.redComponent)
      precondition(color.redComponent < 0.35, "Home button washed out: \(rotation) \(color)")
      try snapshot.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/n72-orientation-\(rotation).png"))
    }
    if rotation == 0 && tilt != 0 {
      try snapshot.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/n72-tilted.png"))
    }
   }
  }
  precondition(homeLevels.max()! - homeLevels.min()! < 0.12, "Home lighting changes with orientation: \(homeLevels)")
  if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
    model.pose(scale: 0.5, rotation: 0, roll: 0, pitch: 0, animated: false)
    let rest = model.projectedPoint(CGPoint(x: 0.5, y: 0))
    model.pose(scale: 0.5, rotation: 0, roll: 0.4, pitch: 0, animated: false)
    let tilted = model.projectedPoint(CGPoint(x: 0.5, y: 0))
    model.pose(scale: 0.5, rotation: 0, roll: 0, pitch: 0, animated: true, spring: true)
    // A second layout with the same target must not cancel the spring.
    model.pose(scale: 0.5, rotation: 0, roll: 0, pitch: 0, animated: false)
    precondition(abs(model.projectedPoint(CGPoint(x: 0.5, y: 0)).x-tilted.x)<1)
    try await Task.sleep(for: .seconds(0.3)); model.advanceAnimations()
    let overshoot = model.projectedPoint(CGPoint(x: 0.5, y: 0))
    precondition((overshoot.x-rest.x)*(tilted.x-rest.x)<0, "Spring must cross the resting pose")
    try await Task.sleep(for: .seconds(0.9)); model.advanceAnimations()
    precondition(abs(model.projectedPoint(CGPoint(x: 0.5, y: 0)).x-rest.x)<0.01)
    model.pose(scale: 0.8, rotation: 90, roll: 0, pitch: 0, animated: true)
    try await Task.sleep(for: .seconds(0.16)); model.advanceAnimations()
    let midway = model.projectedPoint(CGPoint(x: 0.2, y: 0.3))
    try await Task.sleep(for: .seconds(0.3)); model.advanceAnimations()
    let end = model.projectedPoint(CGPoint(x: 0.2, y: 0.3))
    precondition(hypot(midway.x-end.x,midway.y-end.y)>10, "Rotation/scale must interpolate")
  }
  model.pose(scale: 0.4, rotation: 0, roll: 0, pitch: 0, animated: false)
  try await Task.sleep(for: .seconds(0.1))
  let small = model.projectedPoint(CGPoint(x:1,y:0.5)).x-model.projectedPoint(CGPoint(x:0,y:0.5)).x
  model.pose(scale: 0.8, rotation: 0, roll: 0, pitch: 0, animated: false)
  try await Task.sleep(for: .seconds(0.1))
  let large = model.projectedPoint(CGPoint(x:1,y:0.5)).x-model.projectedPoint(CGPoint(x:0,y:0.5)).x
  precondition(abs(large/small-2)<0.001)
  let centre = model.projectedPoint(CGPoint(x:0.5,y:0.5))
  let beforeShakeWidth = model.projectedPoint(CGPoint(x: 1, y: 0.5)).x-model.projectedPoint(CGPoint(x: 0, y: 0.5)).x
  model.shake()
  try await Task.sleep(for: .seconds(0.07))
  model.advanceAnimations()
  if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
    precondition(abs(model.projectedPoint(CGPoint(x:0.5,y:0.5)).x-centre.x)>1)
    let shakenWidth = model.projectedPoint(CGPoint(x: 1, y: 0.5)).x-model.projectedPoint(CGPoint(x: 0, y: 0.5)).x
    precondition(abs(shakenWidth-beforeShakeWidth)>0.01, "Shake must change 3D perspective, not only position")
  }
  try await Task.sleep(for: .seconds(0.5))
  model.advanceAnimations()
  precondition(abs(model.projectedPoint(CGPoint(x:0.5,y:0.5)).x-centre.x)<0.01)
  model.setScreenOff(true)
  try await Task.sleep(for: .seconds(0.1))
  let rendered: NSImage? = await withCheckedContinuation { continuation in
    (model.subviews[0] as! ARView).snapshot(saveToHDR: true) { continuation.resume(returning: $0) }
  }
  let bitmap = NSBitmapImageRep(data: rendered!.tiffRepresentation!)!
  let dark = bitmap.colorAt(x:bitmap.pixelsWide/2,y:bitmap.pixelsHigh/2)!.usingColorSpace(.sRGB)!
  precondition(dark.redComponent<0.05 && dark.greenComponent<0.05 && dark.blueComponent<0.05)
  print("PASS: rendered frame colors, projected touches, four orientations, two tilt axes, pixel sizing, shake and screen off")
  window.orderOut(nil)
 }
}
'''
display_source = r'''import AppKit
import RealityKit
let QEMU_IOS_TOUCH_BEGIN=0, QEMU_IOS_TOUCH_UPDATE=1, QEMU_IOS_TOUCH_END=2
@MainActor var touches: [(Double,Double)] = []
@MainActor var frameData = [UInt32](repeating: 0xff2080c0, count: 480*480)
@MainActor var frameWidth: Int32 = 320, frameHeight: Int32 = 480
@MainActor func qemu_ios_ui_frame(_ p: inout UnsafeRawPointer?, _ w: inout Int32, _ h: inout Int32, _ serial: inout UInt64) -> Bool {
 p = frameData.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress!) }; w=frameWidth; h=frameHeight; serial &+= 1; return true
}
@MainActor func qemu_ios_ui_copy_frame(_ p: UnsafeMutableRawPointer?, _ capacity: Int, _ w: inout Int32, _ h: inout Int32) -> Bool {
 w=frameWidth; h=frameHeight
 frameData.withUnsafeBytes { p!.copyMemory(from: $0.baseAddress!, byteCount: Int(w*h)*4) }; return true
}
@MainActor func qemu_ios_ui_touch(_ slot: Int32,_ phase: Int32,_ x: Double,_ y: Double) { touches.append((x,y)) }
@MainActor func qemu_ios_ui_touch2(_ phase: Int32,_ x: Double,_ y: Double) {}
struct CatalogApp: Decodable {}
extension NSPasteboard.PasteboardType { static let ltmCatalogApp=Self("test.catalog") }
enum PreparedMedia { static let extensions: Set<String> = [] }
@MainActor final class SleepingAnimationView: NSView {}
@MainActor final class EmulatorController {
 enum Pose { case flat, upright }
 var motionPose=Pose.upright, rotationDegrees=0, acceptsInput=true, canQueueInstall=true
 var keyboardInputEnabled=true, keyboardTiltRate=90.0, isSleeping=false, isPoweredOff=false, shuttingDown=false
 var shakeGeneration: UInt64=0, homeCount=0
 func pollStorageFailure() {} ;func noteFrameAdvanced() {};func pressLock() {};func powerOn() {}
 func shake() { shakeGeneration &+= 1 };func setTilt(angle:CGFloat,pitch:CGFloat) {}
 func pressHome() {homeCount += 1};func sendKey(macKeyCode:UInt16,down:Bool) {}
}
@main struct Check {
 @MainActor static func main() async throws {
  _=NSApplication.shared
  let e=EmulatorController(), display=DisplayView(frame:NSRect(x:0,y:0,width:800,height:800))
  display.emulator=e
  let window=NSWindow(contentRect:display.frame,styleMask:[.titled,.resizable],backing:.buffered,defer:false)
  window.contentView=display;window.makeKeyAndOrderFront(nil)
  func settle() async throws {display.needsLayout=true;display.layoutSubtreeIfNeeded();try await Task.sleep(for: .seconds(0.5))}
  try await settle()
  for _ in 0..<20 where !display.subviews.contains(where: { $0 is DeviceModelView }) { try await settle() }
  let model=display.subviews.compactMap{$0 as? DeviceModelView}.first!
  for rotation in [0,90,180,270] {
   e.rotationDegrees=rotation; frameWidth=rotation%180==0 ? 320:480;frameHeight=rotation%180==0 ? 480:320;try await settle()
   for p in [CGPoint(x:0.2,y:0.3),CGPoint(x:0.8,y:0.7)] {
    let local=model.projectedPoint(p)
    let windowPoint=model.convert(local,to:nil)
    let event=NSEvent.mouseEvent(with:.leftMouseDown,location:windowPoint,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
    touches.removeAll();display.mouseDown(with:event);display.mouseUp(with:event)
    precondition(!touches.isEmpty && abs(touches[0].0-p.x)<0.001 && abs(touches[0].1-p.y)<0.001)
   }
  }
  e.rotationDegrees=0;frameWidth=320;frameHeight=480;try await settle()
  let grab = model.projectedPoint(CGPoint(x: 0.5, y: -0.15))
  precondition(model.isChassis(grab))
  let rest = model.projectedPoint(CGPoint(x: 0.5, y: 0))
  func dragEvent(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: model.convert(point, to: nil), modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  }
  display.mouseDown(with: dragEvent(.leftMouseDown, grab))
  display.mouseDragged(with: dragEvent(.leftMouseDragged, CGPoint(x: grab.x+100, y: grab.y)))
  let tilted = model.projectedPoint(CGPoint(x: 0.5, y: 0))
  let top = model.projectedPoint(CGPoint(x: 0.5, y: 0.1))
  let bottom = model.projectedPoint(CGPoint(x: 0.5, y: 0.9))
  precondition(abs(top.x-bottom.x)<0.1, "Horizontal drag must yaw, not spin around gravity")
  precondition(abs(tilted.x-rest.x)>1)
  display.mouseUp(with: dragEvent(.leftMouseUp, grab))
  try await Task.sleep(for: .seconds(1.2))
  precondition(abs(model.projectedPoint(CGPoint(x: 0.5, y: 0)).x-rest.x)<0.1)
  precondition(model.layer!.sublayers!.contains { $0.shadowPath != nil && $0.shadowOpacity > 0 })
  e.isSleeping=true;display.updatePowerPresentation();touches.removeAll()
  let event=NSEvent.mouseEvent(with:.leftMouseDown,location:model.convert(model.projectedPoint(CGPoint(x:0.5,y:0.5)),to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
  display.mouseDown(with:event);precondition(touches.isEmpty)
  window.orderOut(nil);window.contentView=nil
  print("PASS: integrated 3D screen input in all orientations; sleeping touch suppression")
 }
}
'''
with tempfile.TemporaryDirectory(prefix="ltm-model-") as tmp:
    work=Path(tmp)
    app=work/"Check.app/Contents"
    (app/"MacOS").mkdir(parents=True)
    (app/"Resources").mkdir()
    asset=root/"LightTouchMac/N72.usdz"
    (app/"Resources/N72.usdz").symlink_to(asset)
    (app/"Resources/N72Studio.realityenv").symlink_to(root/"LightTouchMac/N72Studio.realityenv")
    sources=root/"LightTouchMac"
    for name,source,extra in [
        ("model",model_source,[]),
        ("display",display_source,["DisplayView", "GameControllerInput", "AttitudeIndicatorButton", "InlineLiveTextView"])
    ]:
        swift=work/(name+".swift");swift.write_text(source)
        exe=app/"MacOS"/name
        subprocess.run(["swiftc","-module-cache-path",str(work/"modules"),"-default-isolation","MainActor",str(sources/"DeviceModelView.swift"),*[str(sources/(x+".swift")) for x in extra],str(swift),"-o",str(exe)],check=True)
        subprocess.run([str(exe),str(asset)],check=True,timeout=45)
