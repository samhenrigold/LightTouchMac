#!/usr/bin/env python3
"""Capture only our own colored canvas, checking chrome exclusion and resize."""
from pathlib import Path
import subprocess,tempfile
DEVICE_PROFILE = str(Path(__file__).resolve().parents[1] / 'LightTouchMac/DeviceProfile.swift')
root=Path(__file__).resolve().parents[1]
fixture=r'''import AppKit
nonisolated enum CaptureError: LocalizedError {case failed(String);var errorDescription:String? {if case let .failed(s)=self {s}else{nil}}}
@main struct Check {
 @MainActor static func main() async throws {
  _ = NSApplication.shared
  let window=NSWindow(contentRect:CGRect(x:100,y:100,width:500,height:400),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
  window.title="Canvas capture fixture"
  let content=window.contentView!;content.wantsLayer=true;content.layer!.backgroundColor=NSColor.red.cgColor
  let canvas=NSView(frame:CGRect(x:40,y:60,width:320,height:240))
  canvas.wantsLayer=true;canvas.layer!.backgroundColor=NSColor.green.cgColor
  content.addSubview(canvas);window.makeKeyAndOrderFront(nil)
  try await Task.sleep(for:.milliseconds(300))
  let capture=CanvasCapture(view:canvas)
  func check(_ image:CGImage, width:Int,height:Int) throws {
   precondition(image.width==width && image.height==height)
   let bitmap=NSBitmapImageRep(cgImage:image)
   for x in [0,image.width/2,image.width-1] { for y in [0,image.height/2,image.height-1] {
    let c=bitmap.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
    precondition(c.greenComponent > 0.8 && c.redComponent < 0.2,"Captured chrome or incorrect crop at \(x),\(y): \(c)")
   }}
  }
  let scale=window.backingScaleFactor
  try check(await capture.screenshot(),width:Int(320*scale),height:Int(240*scale))
  let child=NSPanel(contentRect:window.convertToScreen(CGRect(x:100,y:100,width:100,height:80)),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
  child.contentView!.wantsLayer=true;child.contentView!.layer!.backgroundColor=NSColor.blue.cgColor
  window.addChildWindow(child,ordered:.above);child.orderFront(nil)
  try check(await capture.screenshot(),width:Int(320*scale),height:Int(240*scale))
  try await capture.start()
  try check(capture.frame()!,width:Int(320*scale),height:Int(240*scale))
  canvas.frame=CGRect(x:80,y:90,width:280,height:180)
  _ = try capture.frame()
  try await Task.sleep(for:.milliseconds(300))
  try check(capture.frame()!,width:Int(280*scale),height:Int(180*scale))
  await capture.stop();window.removeChildWindow(child);child.orderOut(nil);window.close()
  print("PASS: own-process screenshot and stream, exact crop edges, resized crop without window chrome")
 }
}'''
with tempfile.TemporaryDirectory(prefix='ltm-canvas-') as directory:
 work=Path(directory);(work/'check.swift').write_text(fixture)
 subprocess.run(['swiftc', DEVICE_PROFILE,'-swift-version','6','-default-isolation','MainActor','-module-cache-path',str(work/'modules'),str(root/'LightTouchMac/CanvasCapture.swift'),str(work/'check.swift'),'-o',str(work/'check')],check=True)
 subprocess.run([str(work/'check')],check=True,timeout=30)
