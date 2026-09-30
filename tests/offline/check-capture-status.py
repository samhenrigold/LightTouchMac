#!/usr/bin/env python3
"""Transient capture feedback preserves the full canvas and tracks saved files."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
fixture=r'''import Cocoa
final class DisplayView:NSView {}
@main struct Check {
 @MainActor static func main() throws {
  _=NSApplication.shared
  let screen=DisplayView(frame:CGRect(x:0,y:0,width:500,height:500))
  let content=DeviceContentView(screen:screen)
  let window=NSWindow(contentRect:screen.frame,styleMask:[.titled,.miniaturizable],backing:.buffered,defer:false)
  window.contentView=content
  let status=CaptureStatusView();status.isHidden=true;content.addStatus(status)
  window.orderFront(nil);content.layoutSubtreeIfNeeded()
  precondition(screen.frame == content.bounds)
  precondition(window.childWindows?.isEmpty ?? true,"Idle canvas must have no floating controls")
  status.update(title:"Starting iOS…",busy:true)
  content.updateStatusVisibility();content.layoutSubtreeIfNeeded()
  let panel=window.childWindows!.first!
  precondition(!panel.canBecomeKey && panel.isExcludedFromWindowsMenu)
  func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
  for width in [360.0,500.0,720.0] {
   window.setContentSize(CGSize(width:width,height:500))
   for title in ["Starting iOS…", "Saving recording…", "Recording saved", "Recording needs attention"] {
    status.update(title:title,busy:title.contains("…"),primary:"Open",secondary:"Reveal",dismissible:true)
    content.updateStatusVisibility();content.layoutSubtreeIfNeeded()
    precondition(screen.frame == content.bounds,"Feedback must not clip the scene above the platter")
    precondition(status.frame.width >= 260 && status.frame.height == 48,"Status layout collapsed")
    let canvasFrame=window.convertToScreen(screen.convert(screen.bounds,to:nil))
    precondition(canvasFrame.contains(panel.frame),"Overlay clipped at \(width): \(panel.frame)")
    precondition(abs(panel.frame.minY-canvasFrame.minY-4)<1)
    for control in descendants(panel.contentView!).compactMap({$0 as? NSControl}) where !control.isHiddenOrHasHiddenAncestor {
     let rect=control.superview!.convert(control.alignmentRect(forFrame: control.frame),to:panel.contentView!)
     precondition(panel.contentView!.bounds.insetBy(dx:-1,dy:-1).contains(rect),"Control clipped: \(control) \(rect)")
    }
   }
  }
  // Pump the main run loop until the condition holds; the deadline only guards a hang (host load must not decide the verdict).
  func until(_ what:String,_ ok:()->Bool) {
   let guardline=Date().addingTimeInterval(30)
   while !ok() { precondition(Date()<guardline,what); RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
  }
  // Finder moves a file to Trash instead of unlinking it. Both must dismiss the banner. The 5 s auto-dismissal
  // is held off meanwhile, so only the file's own removal can hide it, however slow the host.
  CaptureStatusView.autoDismissal = .seconds(3600)
  let temporary=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:temporary)}
  for (extensionName,move) in [("png",false),("png",true),("mov",false),("mov",true)] {
   let saved=temporary.appendingPathComponent("Capture.\(extensionName)")
   try Data([0]).write(to:saved)
   status.showCapture(title:"Screenshot saved",image:NSImage(size:NSSize(width:320,height:480)),fileURL:saved)
   if move {try FileManager.default.moveItem(at:saved,to:temporary.appendingPathComponent("Trashed.\(extensionName)"))}
   else {try FileManager.default.removeItem(at:saved)}
   until("File removal did not dismiss the banner") { status.isHidden }
  }
  // A queued event for the old file must not dismiss a newer capture.
  let old=temporary.appendingPathComponent("Old.png"),new=temporary.appendingPathComponent("New.png")
  try Data([0]).write(to:old);try Data([0]).write(to:new)
  status.showCapture(title:"Old",image:NSImage(size:NSSize(width:1,height:1)),fileURL:old)
  // Our own watch on the old file: once it has fired on the main queue, the old removal event has been delivered.
  let sentinelFD=open(old.path,O_EVTONLY);precondition(sentinelFD>=0)
  let sentinel=DispatchSource.makeFileSystemObjectSource(fileDescriptor:sentinelFD,eventMask:[.delete],queue:.main)
  var oldEventSeen=false
  sentinel.setEventHandler { oldEventSeen=true };sentinel.setCancelHandler { close(sentinelFD) };sentinel.resume()
  try FileManager.default.removeItem(at:old)
  status.showCapture(title:"New",image:NSImage(size:NSSize(width:1,height:1)),fileURL:new)
  until("the old file's removal event never arrived") { oldEventSeen }
  sentinel.cancel()
  // Then let whatever the old event queued (a main-actor task, and the 200 ms fade) run out.
  var drained=false
  Task { try? await Task.sleep(for:.milliseconds(300)); drained=true }
  until("the main actor never drained") { drained }
  precondition(!status.isHidden,"Old capture event dismissed a new banner")
  precondition(status.fileURL==new,"Reveal must target the visible capture")
  // Feedback disappears without a click (the shipped 5 s); the idle canvas has no child panel.
  CaptureStatusView.autoDismissal = .seconds(5)
  status.showCapture(title:"Screenshot saved",image:NSImage(size:NSSize(width:320,height:480)),fileURL:nil)
  precondition(status.fileURL==nil,"A copied capture must not reveal an earlier saved file")
  content.updateStatusVisibility()
  until("Feedback did not dismiss") { status.isHidden }
  precondition(status.isHidden && !panel.isVisible && panel.parent==nil,"Feedback did not dismiss")
  precondition(screen.frame==content.bounds)
  status.update(title:"Starting iOS…",busy:true)
  content.updateStatusVisibility();content.layoutSubtreeIfNeeded()
  precondition(panel.isVisible && panel.parent === window)
  // AppKit can order a child out independently on deactivate/Space changes.
  window.removeChildWindow(panel);panel.orderOut(nil)
  NotificationCenter.default.post(name:NSApplication.didBecomeActiveNotification,object:NSApp)
  precondition(panel.isVisible && panel.parent === window)
  status.isHidden=true;content.updateStatusVisibility()
  precondition(!panel.isVisible && panel.parent==nil)
  print("PASS: full canvas, no idle panel, feedback fits narrow windows, file deletion/move dismissal, transient banner, app-switch reattachment")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-status-') as directory:
 work=Path(directory);(work/'check.swift').write_text(fixture)
 sources=[root/'LightTouchMac'/name for name in ['App/WindowRestorationPolicy.swift','Features/CaptureFileMonitor.swift','UI/CaptureStatusView.swift','UI/DeviceContentView.swift']]
 subprocess.run(['swiftc','-default-isolation','MainActor','-module-cache-path',str(work/'modules'),*map(str,sources),str(work/'check.swift'),'-o',str(work/'check')],check=True)
 subprocess.run([str(work/'check')],check=True,timeout=120)  # hang guard only
