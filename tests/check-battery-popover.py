#!/usr/bin/env python3
"""Exercise the production battery popover, apply action and inline errors."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'LightTouchMac/MainWindowController.swift').read_text()
a=s.index('    private var batteryPopover:');b=s.index('    @objc func configureWebProxy(',a)
code=r"""import Cocoa
func logEvent(_ value:String) {}
@MainActor final class Emulator {
 var batteryControlsAvailable=true,usbConnected=true,fail=false
 var batteryLevel=96,batteryCharging=0,batteryDrain=0.0,applied=0
 func configureBattery(level:Int,charging:Int,drain:Double,usbConnected:Bool)throws {
  if fail {throw NSError(domain:"test",code:1,userInfo:[NSLocalizedDescriptionKey:"Device stopped. Start it, then try again."])}
  batteryLevel=level;applied+=1
 }
 func logEvent(_ value:String) {}
}
@MainActor final class Check:NSWindowController {
 let emulator=Emulator(),deviceVC=NSViewController()
"""+s[a:b].replace('private var','var').replace('private let','let').replace('private func','func').replace('popover.behavior = .transient','popover.behavior = .transient; popover.animates = false')+r"""
 func run() {
  let window=NSWindow(contentRect:NSRect(x:100,y:100,width:640,height:480),styleMask:[.titled],backing:.buffered,defer:false)
  self.window=window;deviceVC.view=NSView(frame:window.contentView!.bounds);window.contentView=deviceVC.view
  window.orderFront(nil)
  defer {batteryPopover?.close();window.orderOut(nil)}
  let anchor=NSButton(title:"Battery",target:nil,action:nil)
  anchor.frame=NSRect(x:300,y:200,width:100,height:30);deviceVC.view.addSubview(anchor)
  configureBattery(anchor)
  precondition(batteryPopover!.isShown)
  let content=batteryPopover!.contentViewController!.view
  content.layoutSubtreeIfNeeded()
  precondition(content.frame.width>300 && content.frame.width<520 && content.frame.height>200)
  func all(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(all)}
  for control in all(content).compactMap({$0 as? NSControl}) {
   let rect=control.convert(control.bounds,to:content)
   precondition(content.bounds.insetBy(dx:-2,dy:-2).contains(rect),"Control outside popover: \(rect)")
  }
  let slider=all(content).compactMap{$0 as? NSSlider}.first!
  slider.integerValue=25
  emulator.fail=true;applyBatterySettings(nil)
  precondition(batteryPopover!.isShown && batteryError.stringValue.contains("Start it"))
  emulator.fail=false;applyBatterySettings(nil)
  RunLoop.main.run(until:Date(timeIntervalSinceNow:0.3))
  precondition(emulator.applied==1 && emulator.batteryLevel==25 && !batteryPopover!.isShown,"applied=\(emulator.applied) level=\(emulator.batteryLevel) shown=\(batteryPopover!.isShown)")
  configureBattery(anchor);precondition(batteryError.stringValue.isEmpty)
  configureBattery(anchor);RunLoop.main.run(until:Date(timeIntervalSinceNow:0.3));precondition(!batteryPopover!.isShown)
  emulator.batteryControlsAvailable=false;configureBattery(anchor)
  precondition(!batteryPopover!.isShown)
  print("PASS: native battery popover layout, apply, inline failure, reopen/toggle and unavailable gate")
 }
}
@main struct Main {@MainActor static func main(){_ = NSApplication.shared;Check(window:nil).run()}}
"""
with tempfile.TemporaryDirectory() as tmp:
 tmp=Path(tmp);(tmp/'check.swift').write_text(code)
 subprocess.run(['xcrun','swiftc','-default-isolation','MainActor',str(root/'LightTouchMac/BatterySettingsView.swift'),str(tmp/'check.swift'),'-o',str(tmp/'check')],check=True)
 subprocess.run([str(tmp/'check')],check=True)
