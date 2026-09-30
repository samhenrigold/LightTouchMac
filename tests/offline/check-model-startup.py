#!/usr/bin/env python3
"""Bounded placeholder, eventual live 3D, renderer readiness, and closed-window lifetime.

The stubbed-renderer half never shows its windows (attached, never ordered in). The actual-renderer half needs
ARView to present in a visible window, which RealityKit only draws in: it runs with LTM_DISPLAY_CHECKS=1."""
import ast
from pathlib import Path
import os, subprocess, tempfile
root = Path(__file__).resolve().parents[2]
node = ast.parse((root/'tests/offline/check-model.py').read_text())
fixture = next(ast.literal_eval(n.value) for n in node.body if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'display_source' for t in n.targets))
prefix = fixture[:fixture.index('@main struct Check')]
stub_source = prefix + r'''
@MainActor final class DeviceModelView:NSView {
 func physicalScale(heightInPoints height: CGFloat) -> CGFloat { height / 1318 }
 var viewportCenter: CGPoint?
 static var loadingDelay:Duration = .zero
 static var preparationDelay:Duration = .milliseconds(50)
 static var framesPrepared=0
 let delay:Duration
 var shellPixels: CGSize { CGSize(width:737,height:1318) }
 enum Control { case sleepWake, volumeUp, volumeDown }
 func control(at p:CGPoint)->Control?{nil}
 init(url:URL,profile:DeviceProfile) async throws {
  delay=Self.preparationDelay
  try await Task.sleep(for:Self.loadingDelay)
  super.init(frame:.zero)
 }
 required init?(coder:NSCoder){fatalError()}
 func prepareFirstFrame() async -> Bool {
  // Deliberately ignore cancellation to reproduce a late renderer callback.
  await withCheckedContinuation { continuation in
   Task { try? await Task.sleep(for:delay);continuation.resume() }
  }
  Self.framesPrepared+=1
  return true
 }
 func pose(scale:CGFloat,rotation:Int,roll:CGFloat,pitch:CGFloat,yaw:CGFloat=0,flat:Bool=false,animated:Bool,spring:Bool=false){}
 func updateFrame(_ image:CGImage){}
 func setScreenOff(_ off:Bool){}
 var homeButtonRect:CGRect? {nil}
 func projectedPoint(_ p:CGPoint)->CGPoint{.zero}
 func panelPoint(_ p:CGPoint,clamped:Bool=false)->CGPoint?{nil}
 func isChassis(_ p:CGPoint)->Bool{false}
 func advanceAnimations(){}
 func shake(){}
}
@main struct Check {
 @MainActor static func main() async throws {
  _=NSApplication.shared
  for scenario in ["fast", "slow asset", "slow frame"] {
   DeviceModelView.loadingDelay = scenario == "slow asset" ? .milliseconds(1400):.zero
   DeviceModelView.preparationDelay = scenario == "slow frame" ? .milliseconds(1400):.milliseconds(50)
   DeviceModelView.framesPrepared=0
   let started=ContinuousClock.now
   let display=DisplayView(frame:NSRect(x:0,y:0,width:500,height:800),profile:.iPodTouch2G)
   let e=EmulatorController();display.emulator=e
   let window=NSWindow(contentRect:display.frame,styleMask:[.titled],backing:.buffered,defer:false)
   window.contentView=display
   display.needsLayout=true;display.layoutSubtreeIfNeeded()
   let shell=display.layer!.sublayers!.first { $0.bounds.size==CGSize(width:737,height:1318) }!
   // Sample every 10 ms rather than at fixed instants: a late wake-up must not
   // skip the placeholder's 1.0-1.4 s window or read the model mid-fade.
   var placeholderShown=false
   func live()->Bool { let m=display.subviews.compactMap{$0 as? DeviceModelView}; return DeviceModelView.framesPrepared>0 && m.count==1 && m[0].alphaValue>0.99 && shell.isHidden }
   while !live() && ContinuousClock.now-started < .seconds(5) {
    if !shell.isHidden {
     precondition(ContinuousClock.now-started >= .seconds(1),"Do not flash the photo before the model gets its first chance to render")
     let pending=display.subviews.compactMap{$0 as? DeviceModelView}
     if DeviceModelView.framesPrepared==0 { precondition(pending.allSatisfy{$0.alphaValue == 0},"Unprepared models must stay invisible") }
     placeholderShown=true
    }
    try await Task.sleep(for:.milliseconds(10))
   }
   if scenario != "fast" { precondition(placeholderShown,"Slow startup must show its placeholder within one second") }
   precondition(live(),"\(scenario): a ready first frame must eventually present live 3D, including after the placeholder")
   window.orderOut(nil);window.contentView=nil
  }
  DeviceModelView.loadingDelay = .zero
  DeviceModelView.preparationDelay = .seconds(5)
  var closingDisplay:DisplayView? = DisplayView(frame:NSRect(x:0,y:0,width:500,height:800),profile:.iPodTouch2G)
  weak let releasedDisplay = closingDisplay
  let closingWindow=NSWindow(contentRect:closingDisplay!.frame,styleMask:[.titled],backing:.buffered,defer:false)
  closingWindow.contentView=closingDisplay
  try await Task.sleep(for:.milliseconds(100))
  closingWindow.orderOut(nil);closingWindow.contentView=nil;closingDisplay=nil
  try await Task.sleep(for:.milliseconds(100))
  precondition(releasedDisplay==nil,"A stalled renderer callback must not retain the closed display")
  print("PASS: fast frame, slow asset, and slow frame reach live 3D; bounded photo placeholder and weak closed-window lifetime")
 }
}
'''
real_source = prefix + r'''
@main struct Check {
 @MainActor static func main() async throws {
  _=NSApplication.shared
  frameColor = 0xff00ff00
  let display=DisplayView(frame:NSRect(x:0,y:0,width:500,height:800),profile:.iPodTouch2G)
  let e=EmulatorController();display.emulator=e
  // Loading can precede window attachment. Deliberately cross the old one-
  // second cutoff, then require production RealityKit to become visible.
  try await Task.sleep(for:.milliseconds(1200))
  let shell=display.layer!.sublayers!.first { $0.bounds.size==CGSize(width:737,height:1318) }!
  precondition(!shell.isHidden,"Waiting for a window must show the bounded placeholder")
  let window=NSWindow(contentRect:display.frame,styleMask:[.titled],backing:.buffered,defer:false)
  window.contentView=display;window.orderFront(nil)
  let deadline=ContinuousClock.now.advanced(by:.seconds(10))
  var ready:DeviceModelView?
  while ContinuousClock.now < deadline {
   display.needsLayout=true;display.layoutSubtreeIfNeeded()
   if let model=display.subviews.compactMap({$0 as? DeviceModelView}).first,
      model.alphaValue>0.99, shell.isHidden {ready=model;break}
   try await Task.sleep(for:.milliseconds(50))
  }
  guard let model=ready else {fatalError("Actual renderer never presented live 3D after the placeholder")}
  let firstFrameReady=await model.prepareFirstFrame()
  precondition(firstFrameReady,"Actual renderer failed to produce its first frame")
  let renderer=model.subviews[0] as! ARView
  let rendered:NSImage?=await withCheckedContinuation { continuation in
   renderer.snapshot(saveToHDR:true) {continuation.resume(returning:$0)}
  }
  let bitmap=NSBitmapImageRep(data:rendered!.tiffRepresentation!)!
  let center=model.projectedPoint(CGPoint(x:0.5,y:0.5))
  let pixel=bitmap.colorAt(x:Int(center.x/model.bounds.width*CGFloat(bitmap.pixelsWide)),
    y:Int((1-center.y/model.bounds.height)*CGFloat(bitmap.pixelsHigh)))!.usingColorSpace(.sRGB)!
  precondition(pixel.redComponent<0.1 && pixel.greenComponent>0.8 && pixel.blueComponent<0.1,
    "Visible model did not render the green guest LCD: \(pixel)")
  window.orderOut(nil);window.contentView=nil
  // A first-frame waiter with no drawable must still cancel promptly.
  let unattached=try await DeviceModelView(url:Bundle.main.url(forResource:"N72",withExtension:"usdz")!,profile:.iPodTouch2G)
  let waiter=Task { await unattached.prepareFirstFrame() }
  waiter.cancel()
  let cancelledResult=await waiter.value
  precondition(!cancelledResult)
  print("PASS: real window/RealityKit becomes visibly 3D after delayed attachment, renders the LCD, and cancels unattached readiness")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-model-startup-') as tmp:
    work=Path(tmp);app=work/'Check.app/Contents';(app/'MacOS').mkdir(parents=True);(app/'Resources').mkdir()
    for name in ['N72.usdz', 'N72Studio.realityenv']:
        (app/'Resources'/name).symlink_to(root/'LightTouchMac'/name)
    windowed = os.environ.get('LTM_DISPLAY_CHECKS') == '1'
    for name, source, actual_model in [('stub', stub_source, False), *([('renderer', real_source, True)] if windowed else [])]:
        swift=work/f'{name}.swift';swift.write_text(source);exe=app/'MacOS'/name
        sources=['UI/DisplayView','Device/DeviceProfile','Device/DeviceProfile+Display','UI/DisplayMeasurements','UI/AttitudeIndicatorButton','UI/InlineLiveTextView','UI/DroppedFiles']
        if actual_model: sources.append('UI/DeviceModelView')
        subprocess.run(['swiftc','-module-cache-path',str(work/'modules'),'-default-isolation','MainActor',
                        *[str(root/'LightTouchMac'/f'{item}.swift') for item in sources],
                        str(root/'Shared/DeviceLinkProtocol.swift'),str(swift),'-o',str(exe)],check=True)
        subprocess.run([str(exe)],check=True,timeout=30)
    if not windowed:
        print('SKIP: the actual renderer in a visible window; LTM_DISPLAY_CHECKS=1 runs it')
