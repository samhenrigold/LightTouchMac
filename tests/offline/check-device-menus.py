#!/usr/bin/env python3
"""Build the real menus and exercise the production device validation branches.

EXPECTED is the whole menu bar as built for each board: every item, its menu, its shortcut, and
which items start hidden or alternate; any move, rename or shortcut change fails here first."""
from pathlib import Path
import re,subprocess,tempfile
root=Path(__file__).resolve().parents[2]/'LightTouchMac'
menu=(root/'App/MainMenu.swift').read_text()
controller=(root/'UI/MainWindowController.swift').read_text()
a=controller.index('        case #selector(deviceRotate(_:)), #selector(deviceRotateLeft(_:))')
b=controller.index('        case #selector(configureWebProxy(_:)):',a)
validation=controller[a:b]
a=controller.index('    @objc func toggleDevicePause(')
b=controller.index('    @objc func devicePause(',a)
toggle=controller[a:b]
capture=(root/'Features/CaptureController.swift').read_text()
a=capture.index('    var canTakeScreenshot: Bool {')
b=capture.index('    init(preferences:',a)
captureAvailability=capture[a:b]
selectors=set(re.findall(r'#selector\(MainWindowController\.(\w+)\(',menu))
selectors.update(re.findall(r'#selector\((\w+)\(',validation))
selectors.discard('toggleDevicePause')
stubs='\n'.join('@objc func '+name+'(_ sender:Any?) {}' for name in sorted(selectors))
# (profile, menu path / title  shortcut [hidden] [alternate]); "-" is a separator. The Help and Services
# menus' own contents come from AppKit.
IPOD_BAR='''
Light Touch/About Light Touch
Light Touch/-
Light Touch/Settings…  ⌘,
Light Touch/-
Light Touch/Services ▸
Light Touch/-
Light Touch/Hide Light Touch  ⌘h
Light Touch/Hide Others  ⌥⌘h
Light Touch/Show All
Light Touch/-
Light Touch/Quit Light Touch  ⌘q
File/Add Device…  ⌘n
File/-
File/Import IPSW…
File/Download and Prepare
File/Cancel Download
File/-
File/Start
File/-
File/Show in Finder
File/Delete Device…
File/-
File/Copy to iPod…
File/Save to Mac…
File/Cancel Transfer
File/Refresh Files
File/-
File/Close  ⌘w
Edit/Undo  ⌘z
Edit/Redo  ⇧⌘z
Edit/-
Edit/Cut  ⌘x
Edit/Copy  ⌘c
Edit/Paste  ⌘v
Edit/Delete
Edit/Select All  ⌘a
Edit/-
Edit/Paste Text to iPod  ⌃⌘v
Edit/-
Edit/Find…  ⌘f
Edit/Search Apps  ⌥⌘f alternate
Edit/-
Edit/Select Text on Screen
View/Show Sidebar  ⌃⌘s
View/Show Inspector  ⌥⌘i
View/Show Console  ⇧⌘y
View/-
View/Physical Size  ⌘0
View/Zoom to Fit  ⌘9
View/Zoom In  ⌘+
View/Zoom In  ⌘= hidden
View/Zoom Out  ⌘-
View/-
View/Show Finger Dots
View/Show Hidden Files
View/-
View/Show Toolbar  ⌥⌘t
View/Customize Toolbar…
View/-
View/Enter Full Screen  ⌃⌘f
Device/Home Screen  ⇧⌘h
Device/Lock  ⌘l
Device/-
Device/Rotate Left  ⌘←
Device/Rotate Right  ⌘→
Device/Rotate Automatically
Device/-
Device/Motion ▸
Device/Motion/Upright
Device/Motion/Flat
Device/Motion/-
Device/Motion/Reset Tilt
Device/Motion/-
Device/Motion/Shake
Device/Motion/Special Trick
Device/Input ▸
Device/Input/Volume Up  ⌥⌘↑
Device/Input/Volume Down  ⌥⌘↓
Device/Input/-
Device/Input/Send Keyboard Input
Device/Network ▸
Device/Network/Connect to the Internet
Device/Network/-
Device/Network/Proxy…
Device/Battery ▸
Device/Battery/100%
Device/Battery/80%
Device/Battery/50%
Device/Battery/20%
Device/Battery/5%
Device/Battery/-
Device/Battery/Charge Automatically
Device/Battery/Charging
Device/Battery/Not Charging
Device/-
Device/Pause
Device/-
Device/Restart…
Device/Restart with Guest Tools ▸ hidden
Device/Restart with Guest Tools/Previous
Device/Restart with Guest Tools/Built-in
Device/Restart with Guest Tools/Latest
Device/Power Off
Device/-
Device/Erase All Content and Settings…
Apps/Install App…  ⇧⌘i
Apps/Import Media…
Apps/-
Apps/Open
Apps/Uninstall…
Apps/-
Apps/Refresh Apps
Capture/Save Screenshot  ⌘s
Capture/Save Screenshot As…  ⇧⌘s
Capture/Copy Screenshot
Capture/Open Screenshot in Preview
Capture/-
Capture/Start Recording  ⌘r
Capture/Discard Recording…  ⌘.
Capture/-
Capture/Capture Screen Only
Capture/-
Capture/Show Unfinished Recordings
Window/Minimize  ⌘m
Window/Zoom
Window/-
Window/Show Device  ⌘1
Window/Show iPod Files  ⌘2
Window/Device Logs
Window/-
Window/Bring All to Front
Help/Light Touch Help  ⌘?
Help/-
Help/Export Diagnostics…
'''.strip()
# The iPad's differences: its name, a compass, and the USB charger choice.
IPAD_BAR=(IPOD_BAR.replace('iPod','iPad')
    .replace('Device/Input ▸','Device/Compass Heading ▸\nDevice/Compass Heading/North\nDevice/Compass Heading/East\nDevice/Compass Heading/South\nDevice/Compass Heading/West\nDevice/Input ▸')
    .replace('Device/Battery/Not Charging','Device/Battery/Not Charging\nDevice/Battery/-\nDevice/Battery/High-Power USB Port'))
source=r'''import Cocoa
struct Instance { let id=UUID() }
@MainActor final class Emulator {
 var isPaused=false,isRunning=true,isInstalling=false,acceptsInput=true,isSleeping=false
 let instance=Instance()
 var batteryLevel:Int?=nil,batteryCharging:Int32=0,highPowerUSB=true,canChooseUSBCharger=false
 var compassHeading:Int?=nil,hasCompass=false
 func pause(){isPaused=true;isRunning=false}
 func resume(){isPaused=false;isRunning=true}
}
@MainActor enum AppInstaller { static var hasPendingWork=false; static func hasPendingWork(for id:UUID)->Bool {hasPendingWork} }
@MainActor final class AppDelegate:NSObject { @objc func toggleAutomaticRotation(_ sender:Any?) {}
 @objc func toggleInternetAccess(_ sender:Any?) {}
 @objc func showHelp(_ sender:Any?) {}
 @objc func showDeviceWindow(_ sender:Any?) {}
 @objc func showFilesWindow(_ sender:Any?) {}
 @objc func quit(_ sender:Any?) {} }
@MainActor final class DeviceFilesViewController:NSObject {
 @objc func importFile() {}
 @objc func exportFile() {}
 @objc func cancelTransfer() {}
 @objc func refreshFiles(_ sender:Any?) {}
 @objc func toggleHidden(_ sender:Any?) {}
}
@MainActor final class Recording {
 enum Phase { case idle, saving }
 var phase:Phase = .idle
 var canStop=false,needsRecovery=false
}
@MainActor final class MainWindowController:NSWindowController {
 let emulator:Emulator?=Emulator(),recording=Recording()
 var screenshotBusy=false
 var capture:MainWindowController { self }   // CaptureController's availability, below
'''+stubs+'\n'+toggle+'\n'+captureAvailability+r'''
 func validateMenuItem(_ menuItem:NSMenuItem)->Bool {
 guard let emulator else {return false}
 switch menuItem.action {
'''+validation+r'''
 default:return true
 }
 }
}
/// One line per item: its menu path, title, shortcut, and whether it starts hidden or is an Option alternate.
@MainActor func dump(_ menu:NSMenu,_ path:String)->[String] {
 menu.items.flatMap { item->[String] in
  if item.isSeparatorItem { return [path+"/-"] }
  var mods=""
  let m=item.keyEquivalentModifierMask
  if m.contains(.control){mods+="⌃"}; if m.contains(.option){mods+="⌥"}; if m.contains(.shift){mods+="⇧"}; if m.contains(.command){mods+="⌘"}
  let arrows:[Int:String]=[NSLeftArrowFunctionKey:"←",NSRightArrowFunctionKey:"→",NSUpArrowFunctionKey:"↑",NSDownArrowFunctionKey:"↓"]
  let key=item.keyEquivalent.unicodeScalars.first.flatMap{arrows[Int($0.value)]} ?? item.keyEquivalent
  var line=path+"/"+item.title+(item.submenu != nil ? " ▸" : "")+(key.isEmpty ? "" : "  "+mods+key)
  if item.isHidden {line+=" hidden"}; if item.isAlternate {line+=" alternate"}
  // AppKit fills Services and Help's search; their contents aren't ours.
  guard let sub=item.submenu, item.title != "Services" else { return [line] }
  return [line]+dump(sub,path+"/"+item.title)
 }
}
@main struct Check {
 @MainActor static func main() {
  _ = NSApplication.shared
  MainMenuBuilder.install(profile: .iPad1)
  let ipad=NSApp.mainMenu!.items.flatMap{ dump($0.submenu!,$0.title) }
  let expectedIPad=CommandLine.arguments[2].components(separatedBy:"\n")
  precondition(ipad==expectedIPad,"iPad menu bar:\n"+ipad.joined(separator:"\n"))
  MainMenuBuilder.install(profile: .iPodTouch2G)
  let root=NSApp.mainMenu!
  let bar=root.items.flatMap{ dump($0.submenu!,$0.title) }
  precondition(bar==CommandLine.arguments[1].components(separatedBy:"\n"),"iPod menu bar:\n"+bar.joined(separator:"\n"))
  // With no device the Apps menu still lists its commands, every one dimmed, and a
  // device's inspector leaving hands it back the same way (MainMenuBuilder.resetAppsMenu).
  let apps=root.item(withTitle:"Apps")!.submenu!
  precondition(!apps.autoenablesItems && apps.delegate==nil && apps.items.count==7 && apps.items.allSatisfy{ !$0.isEnabled },"Apps with no device")
  apps.removeAllItems();apps.addItem(withTitle:"Open “Stale”",action:nil,keyEquivalent:"")
  MainMenuBuilder.resetAppsMenu()
  precondition(apps.items.map(\.title)==["Install App…","Import Media…","","Open","Uninstall…","","Refresh Apps"] && apps.items.allSatisfy{ !$0.isEnabled },"Apps reset")
  precondition(root.item(withTitle:"View")!.submenu!.items[0].action==#selector(NSSplitViewController.toggleSidebar(_:)))
  let app=root.items[0].submenu!
  precondition(app.item(withTitle:"Settings…") != nil)
  let device=root.item(withTitle:"Device")!.submenu!
  func find(_ name:String, in menu:NSMenu)->NSMenuItem? {
   for item in menu.items {
    if item.title==name{return item}
    if let sub=item.submenu, let match=find(name,in:sub){return match}
   }
   return nil
  }
  precondition(!root.autoenablesItems && root.items.allSatisfy{ $0.isEnabled })
  precondition(find("Reset Tilt",in:device) != nil && find("Upright",in:device) != nil)
  let motion=device.item(withTitle:"Motion")!.submenu!
  let input=device.item(withTitle:"Input")!.submenu!
  precondition(find("Upright",in:motion) != nil && find("Flat",in:motion) != nil && find("Shake",in:motion) != nil)
  precondition(find("Upright",in:input)==nil && find("Reset Tilt",in:input)==nil)
  for name in ["Add Device…","Start","Import IPSW…","Delete Device…","Show in Finder"] {
   precondition(find(name,in:device)==nil,"library command \(name) belongs to File")
  }
  // Default presses alternate between upright portrait and home-button-right
  // landscape. Option reverses the same next turn, including after auto-rotation.
  var degrees=0
  for expected in [270,0,270,0] {
   let action=RotationControlAction(rotationDegrees:degrees,optionPressed:false)
   degrees=(degrees+(action.clockwise ? 90:270))%360
   precondition(degrees==expected)
  }
  for degrees in [0,90,180,270] {
   let normal=RotationControlAction(rotationDegrees:degrees,optionPressed:false)
   let alternate=RotationControlAction(rotationDegrees:degrees,optionPressed:true)
   precondition(normal.clockwise != alternate.clockwise && normal.symbol != alternate.symbol)
  }
  let help=root.item(withTitle:"Help")!.submenu!
  for name in ["Open SSH","Restart SpringBoard","Verbose Boot","Kernel Console"] {
   precondition(find(name,in:root)==nil,"Developer command leaked into the regular menus")
  }
  precondition(find("Show Unfinished Recordings",in:help)==nil && find("Device Logs",in:help)==nil)
  let file=root.item(withTitle:"File")!.submenu!
  for name in ["Copy to iPod…","Save to Mac…","Cancel Transfer","Refresh Files","Close"] {
   precondition(find(name,in:file) != nil,name)
  }
  let capture=root.item(withTitle:"Capture")!.submenu!
  precondition(capture.items.prefix(4).map(\.title)==["Save Screenshot","Save Screenshot As…","Copy Screenshot","Open Screenshot in Preview"])
  precondition(find("Save Screenshot",in:capture)?.keyEquivalent=="s")
  precondition(find("Save Screenshot",in:capture)?.keyEquivalentModifierMask==[.command])
  precondition(capture.items.allSatisfy{ $0.submenu==nil },"Capture stays flat")
  precondition(capture.items.filter{ !$0.isSeparatorItem }.map(\.title)==["Save Screenshot","Save Screenshot As…","Copy Screenshot","Open Screenshot in Preview","Start Recording","Discard Recording…","Capture Screen Only","Show Unfinished Recordings"])
  precondition(find("Open Screenshot in Preview",in:capture)?.keyEquivalent.isEmpty==true,"⌘O is Open’s, not a new screenshot’s")
  for (name,key,modifiers) in [("Save Screenshot As…","s",NSEvent.ModifierFlags([.shift,.command])),("Start Recording","r",[.command]),("Discard Recording…",".",[.command])] {
   precondition(find(name,in:capture)?.keyEquivalent==key && find(name,in:capture)?.keyEquivalentModifierMask==modifiers)
  }
  precondition(find("Copy Screenshot",in:capture)?.keyEquivalent.isEmpty==true)
  precondition(find("Copy",in:root.item(withTitle:"Edit")!.submenu!)?.keyEquivalent=="c")
  precondition(find("Show Finger Dots",in:root.item(withTitle:"View")!.submenu!) != nil)
  precondition(find("Discard Recording…",in:capture)?.isHidden==false)
  precondition(find("Save Screenshot As…",in:file)==nil)
  precondition(find("Rotate Left",in:device)?.keyEquivalent==String(UnicodeScalar(NSLeftArrowFunctionKey)!))
  precondition(find("Rotate Right",in:device)?.keyEquivalent==String(UnicodeScalar(NSRightArrowFunctionKey)!))
  for name in ["Shake","Pause"] { precondition(find(name,in:device)?.keyEquivalent.isEmpty==true) }
  func leaves(_ menu:NSMenu)->[NSMenuItem] {
   menu.items.flatMap { item in item.submenu.map(leaves) ?? [item] }
  }
  var shortcuts=Set<String>()
  for item in leaves(root) where !item.keyEquivalent.isEmpty {
   let chord="\(item.keyEquivalent.lowercased()):\(item.keyEquivalentModifierMask.rawValue)"
   precondition(shortcuts.insert(chord).inserted,"Duplicate shortcut: \(item.title)")
   let arrows=[NSLeftArrowFunctionKey,NSRightArrowFunctionKey].map{String(UnicodeScalar($0)!)}
   // Command-arrows are rotation's (Sam, 0928c); nothing else may take them.
   precondition(!(arrows.contains(item.keyEquivalent) && item.keyEquivalentModifierMask==[.command]) || item.title.hasPrefix("Rotate "),"Command-arrow is rotation's: \(item.title)")
   precondition(!(item.keyEquivalentModifierMask==[.command,.option] && ["+","-","="].contains(item.keyEquivalent)),"Reserved accessibility zoom")
  }
  let windows=root.item(withTitle:"Window")!.submenu!
  precondition(windows.items.map(\.title)==["Minimize","Zoom","","Show Device","Show iPod Files","Device Logs","","Bring All to Front"])
  precondition(windows.item(withTitle:"Show Device")?.keyEquivalent=="1")
  precondition(windows.item(withTitle:"Show iPod Files")?.keyEquivalent=="2")
  precondition(find("Show Capture Controls",in:root)==nil && find("Hide Capture Controls",in:root)==nil)
  for menu in root.items.compactMap({$0.submenu}) {
   for submenu in menu.items.compactMap({$0.submenu}) {
    precondition(submenu.items.allSatisfy{$0.submenu==nil},"Avoid nested submenus")
   }
  }
  for name in ["Volume Up","Volume Down","Power Off","Rotate Automatically","Connect to the Internet"] {
   precondition(find(name,in:device) != nil,name)
  }
  for name in ["Volume Up","Volume Down"] {
   let item=find(name,in:device)!
   precondition(item.keyEquivalentModifierMask==[.option,.command])
   precondition(item.keyEquivalent != "-" && item.keyEquivalent != "=")
  }
  precondition(root.item(withTitle:"Help")!.submenu!.item(withTitle:"Export Diagnostics…") != nil)
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:200,height:100),styleMask:[.titled],backing:.buffered,defer:false)
  let controller=MainWindowController(window:window)
  precondition(controller.canTakeScreenshot && controller.canStartRecording && controller.canToggleRecording)
  controller.emulator!.isRunning=false;controller.emulator!.isPaused=true
  precondition(controller.canTakeScreenshot && !controller.canStartRecording && !controller.canToggleRecording)
  controller.emulator!.isSleeping=true
  precondition(!controller.canTakeScreenshot && !controller.canToggleRecording)
  controller.recording.canStop=true
  precondition(controller.canToggleRecording,"Stopping must remain available when the guest stops")
  controller.recording.phase = .saving
  precondition(!controller.canToggleRecording)
  controller.recording.phase = .idle;controller.recording.canStop=false;controller.recording.needsRecovery=true
  precondition(controller.canToggleRecording,"Recovery must remain available offline")
  controller.recording.needsRecovery=false;controller.emulator!.isSleeping=false
  controller.emulator!.isRunning=true;controller.emulator!.isPaused=false;controller.screenshotBusy=true
  precondition(!controller.canTakeScreenshot && !controller.canStartRecording && !controller.canToggleRecording)
  controller.screenshotBusy=false
  let pause=find("Pause",in:device)!
  precondition(device.item(withTitle:"Save State Now") == nil)
  precondition(root.item(withTitle:"Window")!.submenu!.item(withTitle:"Show iPod Files") != nil)
  precondition(root.item(withTitle:"View")!.submenu!.item(withTitle:"Physical Size") != nil)
  precondition(controller.validateMenuItem(pause))
  controller.toggleDevicePause(nil)
  precondition(controller.validateMenuItem(pause) && pause.title=="Resume")
  controller.toggleDevicePause(nil)
  precondition(controller.validateMenuItem(pause) && pause.title=="Pause")
  AppInstaller.hasPendingWork=true;precondition(!controller.validateMenuItem(pause));AppInstaller.hasPendingWork=false
  let text=NSTextView(frame:window.contentView!.bounds);window.contentView!.addSubview(text)
  window.makeFirstResponder(text)
  precondition(!controller.validateMenuItem(find("Rotate Left",in:device)!))
  controller.emulator!.acceptsInput=false
  precondition(!controller.validateMenuItem(find("Volume Up",in:device)!))
  print("PASS: command homes, Window order, stable menus, unique/reserved shortcuts, capture availability, pause and input validation")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-menu-check-') as tmp:
    tmp=Path(tmp);(tmp/'check.swift').write_text(source)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor',str(root/'App/MainMenu.swift'),str(root/'Device/DeviceProfile.swift'),str(root/'UI/RotationControlAction.swift'),str(tmp/'check.swift'),'-o',str(tmp/'check')],check=True)
    subprocess.run([str(tmp/'check'),IPOD_BAR,IPAD_BAR],check=True)
