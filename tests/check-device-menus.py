#!/usr/bin/env python3
"""Build the real menus and exercise the production device validation branches."""
from pathlib import Path
import re,subprocess,tempfile
root=Path(__file__).resolve().parents[1]/'LightTouchMac'
menu=(root/'MainMenu.swift').read_text()
controller=(root/'MainWindowController.swift').read_text()
a=controller.index('        case #selector(deviceRotate(_:)), #selector(deviceRotateLeft(_:))')
b=controller.index('        case #selector(configureBattery(_:)):',a)
validation=controller[a:b]
a=controller.index('    @objc func toggleDevicePause(')
b=controller.index('    @objc func devicePause(',a)
toggle=controller[a:b]
selectors=set(re.findall(r'#selector\(MainWindowController\.(\w+)\(',menu))
selectors.update(re.findall(r'#selector\((\w+)\(',validation))
selectors.discard('toggleDevicePause')
stubs='\n'.join('@objc func '+name+'(_ sender:Any?) {}' for name in sorted(selectors))
source=r'''import Cocoa
@MainActor final class Emulator {
 var isPaused=false,isRunning=true,isInstalling=false,acceptsInput=true
 func pause(){isPaused=true;isRunning=false}
 func resume(){isPaused=false;isRunning=true}
}
@MainActor enum AppInstaller { static var hasPendingWork=false }
@MainActor final class AppDelegate:NSObject { @objc func showSettings(_ sender:Any?) {} }
@MainActor final class MainWindowController:NSWindowController {
 let emulator=Emulator()
'''+stubs+'\n'+toggle+r'''
 func validateMenuItem(_ menuItem:NSMenuItem)->Bool {
 switch menuItem.action {
'''+validation+r'''
 default:return true
 }
 }
}
@main struct Check {
 @MainActor static func main() {
  _ = NSApplication.shared
  MainMenuBuilder.install()
  let root=NSApp.mainMenu!
  let app=root.items[0].submenu!
  let settings=app.item(withTitle:"Settings…")!
  precondition(settings.keyEquivalent=="," && settings.keyEquivalentModifierMask==[.command])
  let device=root.item(withTitle:"Device")!.submenu!
  for name in ["Volume Up","Volume Down","Pause","Save State Now","Discard Saved State…","Power Off"] {
   precondition(device.item(withTitle:name) != nil,name)
  }
  for name in ["Volume Up","Volume Down"] {
   let item=device.item(withTitle:name)!
   precondition(item.keyEquivalentModifierMask==[.option,.command])
   precondition(item.keyEquivalent != "-" && item.keyEquivalent != "=")
  }
  precondition(root.item(withTitle:"Help")!.submenu!.item(withTitle:"Export Diagnostics…")==nil)
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:200,height:100),styleMask:[.titled],backing:.buffered,defer:false)
  let controller=MainWindowController(window:window)
  let pause=device.item(withTitle:"Pause")!
  precondition(controller.validateMenuItem(pause))
  controller.toggleDevicePause(nil)
  precondition(controller.validateMenuItem(pause) && pause.title=="Resume")
  controller.toggleDevicePause(nil)
  precondition(controller.validateMenuItem(pause) && pause.title=="Pause")
  AppInstaller.hasPendingWork=true;precondition(!controller.validateMenuItem(pause));AppInstaller.hasPendingWork=false
  let text=NSTextView(frame:window.contentView!.bounds);window.contentView!.addSubview(text)
  window.makeFirstResponder(text)
  precondition(!controller.validateMenuItem(device.item(withTitle:"Rotate Left")!))
  controller.emulator.acceptsInput=false
  precondition(!controller.validateMenuItem(device.item(withTitle:"Volume Up")!))
  print("PASS: actual menu shortcuts, device actions, pause state, transfer guard and text-editor rotation guard")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-menu-check-') as tmp:
    tmp=Path(tmp);(tmp/'check.swift').write_text(source)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor',str(root/'MainMenu.swift'),str(tmp/'check.swift'),'-o',str(tmp/'check')],check=True)
    subprocess.run([str(tmp/'check')],check=True)
