#!/usr/bin/env python3
"""Native column browser loading, navigation, layout and stale-reply handling."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='ltm-files-ui-') as tmp:
 tmp=Path(tmp)
 (tmp/'check.swift').write_text(r'''import Cocoa
// Supply the test window to AppKit's real action dispatcher without requiring
// desktop activation (the test must also run while the Mac is locked).
@MainActor final class FilesApplication:NSApplication {
 var commandWindow:NSWindow?
 override var keyWindow:NSWindow? { commandWindow }
 override var mainWindow:NSWindow? { commandWindow }
}
struct DeviceFile: Sendable { let name,path:String;let isDirectory,isRegular:Bool;let size:UInt64 }
struct DeviceServices: Sendable {
 func files(in path:String) async throws ->[DeviceFile] {
  try? await Task.sleep(for:.milliseconds(30)) // Deliberately deliver after cancellation.
  return path.isEmpty ? [DeviceFile(name:"Folder",path:"Folder",isDirectory:true,isRegular:false,size:0)] : [DeviceFile(name:"file.bin",path:"Folder/file.bin",isDirectory:false,isRegular:true,size:10)]
 }
 func freeSpaceBytes() async throws ->Int64 { 2_500_000_000 }
 func uploadFile(_ source:URL,into path:String,progress:@escaping @Sendable(Double)->Void) async throws {}
 func download(_ file:DeviceFile,to path:URL,progress:@escaping @Sendable(Double)->Void) async throws {}
}
final class Sink: NSResponder {
 var events = 0
 override func keyDown(with event:NSEvent) { events += 1 }
 override func scrollWheel(with event:NSEvent) { events += 1 }
}
@main struct Check {
 @MainActor static func main() {
  _ = FilesApplication.shared
  Task { @MainActor in
   do { try await runChecks(); exit(0) }
   catch { fatalError(String(describing:error)) }
  }
  NSApp.run()
 }
 @MainActor static func runChecks() async throws {
  let controller=DeviceFilesWindowController(profile:.iPodTouch2G)
  let vc=controller.browser;vc.services=DeviceServices()
  let window=controller.window!
  (NSApp as! FilesApplication).commandWindow=window
  controller.showWindow(nil)
  window.setContentSize(NSSize(width:360,height:500))
  vc.reload()
  try await Task.sleep(for:.milliseconds(100))
  func children(_ view:NSView)->[NSView] { view.subviews.flatMap{[$0]+children($0)} }
  let all=children(vc.view)
  let browser=all.compactMap{$0 as? NSBrowser}.first!
  precondition(browser.matrix(inColumn:0)!.numberOfRows==1)
  browser.selectRow(0,inColumn:0)
  browser.addColumn()
  for _ in 0..<40 {
   if browser.matrix(inColumn:1)?.numberOfRows == 1 { break }
   try await Task.sleep(for:.milliseconds(50))
  }
  precondition(browser.matrix(inColumn:1)!.numberOfRows==1)
  browser.selectRow(0,inColumn:1)
  browser.sendAction(browser.action!,to:browser.target)
  let export=all.compactMap{$0 as? NSButton}.first{$0.title=="Save to Mac…"}!
  precondition(export.isEnabled)
  let save=NSMenuItem(title:"Save to Mac…",action:#selector(DeviceFilesViewController.exportFile),keyEquivalent:"")
  let copy=NSMenuItem(title:"Copy to iPod…",action:#selector(DeviceFilesViewController.importFile),keyEquivalent:"")
  let cancel=NSMenuItem(title:"Cancel Transfer",action:#selector(DeviceFilesViewController.cancelTransfer),keyEquivalent:"")
  let hidden=NSMenuItem(title:"Show Hidden Files",action:#selector(DeviceFilesViewController.toggleHidden(_:)),keyEquivalent:"")
  precondition(vc.validateMenuItem(save) && vc.validateMenuItem(copy) && !vc.validateMenuItem(cancel))
  vc.focusBrowser()
  precondition(NSApp.target(forAction:save.action!,to:nil,from:save) as? DeviceFilesViewController === vc,"File menu reaches focused browser")
  precondition(NSApp.sendAction(hidden.action!,to:nil,from:hidden))
  precondition(vc.validateMenuItem(hidden) && hidden.title=="Hide Hidden Files" && hidden.state == .off)
  precondition(NSApp.sendAction(hidden.action!,to:nil,from:hidden))
  try await Task.sleep(for:.milliseconds(100))
  browser.selectRow(0,inColumn:0);browser.addColumn()
  try await Task.sleep(for:.milliseconds(100))
  precondition(!vc.validateMenuItem(save),"Directories cannot be exported as files")
  browser.selectRow(0,inColumn:1);browser.sendAction(browser.action!,to:browser.target)
  for width in [360.0,660.0,900.0] {
   window.setContentSize(NSSize(width:width,height:500));vc.view.layoutSubtreeIfNeeded()
   for button in all.compactMap({$0 as? NSButton}) where !button.isHidden {
    let frame=button.convert(button.bounds,to:vc.view)
    precondition(frame.minX>=0 && frame.maxX<=width,"clipped \(button.title): \(frame)")
   }
  }
  window.setContentSize(NSSize(width:360,height:500));vc.view.layoutSubtreeIfNeeded()
  let image=vc.view.bitmapImageRepForCachingDisplay(in:vc.view.bounds)!
  vc.view.cacheDisplay(in:vc.view.bounds,to:image)
  try image.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/ltm-files-ui.png"))
  window.close()
  controller.showWindow(nil)
  precondition(controller.browser === vc && browser.selectedColumn == 1)
  precondition(!window.isExcludedFromWindowsMenu && window.styleMask.contains(.resizable))
  vc.reload();vc.services=nil;vc.reload()
  try await Task.sleep(for:.milliseconds(100))
  precondition(browser.matrix(inColumn:0)!.numberOfRows==0 && !export.isEnabled)
  precondition(!vc.validateMenuItem(save) && !vc.validateMenuItem(copy) && !vc.validateMenuItem(cancel))
  let idleStatus=vc.transferStatus;vc.cancelTransfer();precondition(vc.transferStatus==idleStatus)
  let sink=Sink();let next=vc.view.nextResponder;vc.view.nextResponder=sink
  let key=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"x",charactersIgnoringModifiers:"x",isARepeat:false,keyCode:7)!
  vc.view.keyDown(with:key);vc.view.scrollWheel(with:key)
  precondition(sink.events==0)
  vc.view.nextResponder=next
  vc.stop()
  print("PASS: native Files routing, selection/connection validation, columns, 360/660/900-point layout and stale reply rejection")
 }
}
''')
 subprocess.run(['xcrun','swiftc','-default-isolation','MainActor',str(root/'LightTouchMac/WindowRestorationPolicy.swift'),str(root/'LightTouchMac/DeviceFilesViewController.swift'),str(root/'LightTouchMac/DeviceFilesWindowController.swift'),str(root/'LightTouchMac/DeviceProfile.swift'),str(tmp/'check.swift'),'-o',str(tmp/'check')],check=True)
 subprocess.run([str(tmp/'check')],check=True,timeout=20)
