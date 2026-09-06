#!/usr/bin/env python3
"""Exercise the production Settings window without starting an emulator."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='ltm-settings-') as tmp:
    tmp=Path(tmp)
    (tmp/'check.swift').write_text(r'''import Cocoa
@MainActor final class EmulatorController {
 static let autoRotateDefaultsKey="autoRotateWithGuest"
 static var autoRotateEnabled: Bool { UserDefaults.standard.object(forKey:autoRotateDefaultsKey) as? Bool ?? true }
 var keyboardTiltRate: Double=90
 func setKeyboardTiltRate(_ value: Double) { keyboardTiltRate=value }
}
@MainActor enum CatalogClient {
 static var baseURL: URL { URL(string:UserDefaults.standard.string(forKey:"LTMCatalogBaseURL") ?? "https://legacystore.app")! }
}
@main struct Check {
 @MainActor static func main() {
  _ = NSApplication.shared
  let defaults=UserDefaults.standard
  let domain="ltm-settings-check-"+UUID().uuidString
  defaults.setPersistentDomain([:],forName:domain)
  defaults.addSuite(named:domain)
  // The compiled fixture has its own defaults domain, never the app's bundle ID.
  defer { defaults.removeObject(forKey:"autoRotateWithGuest");defaults.removeObject(forKey:"LTMCatalogBaseURL");defaults.removePersistentDomain(forName:domain) }
  let emulator=EmulatorController()
  let controller=SettingsWindowController(emulator:emulator)
  controller.showWindow(nil)
  let window=controller.window!
  precondition(!window.styleMask.contains(.resizable) && !window.styleMask.contains(.miniaturizable))
  func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
  let views=descendants(window.contentView!)
  let button=views.compactMap{$0 as? NSButton}.first{$0.title=="Rotate with the device"}!
  button.performClick(nil);precondition(!EmulatorController.autoRotateEnabled)
  let tilt=views.compactMap{$0 as? NSPopUpButton}.first!
  tilt.selectItem(at:2);tilt.sendAction(tilt.action,to:tilt.target)
  precondition(emulator.keyboardTiltRate==180)
  let field=views.compactMap{$0 as? NSTextField}.first{$0.isEditable}!
  for bad in ["file:///etc/passwd","https://user:secret@example.com","https://example.com?x=1","https://example.com:70000","relative"] {
   precondition(SettingsWindowController.catalogURL(bad)==nil,bad)
   field.stringValue=bad;controller.controlTextDidEndEditing(Notification(name:NSControl.textDidEndEditingNotification,object:field))
   precondition(defaults.string(forKey:"LTMCatalogBaseURL")==nil)
  }
  field.stringValue="http://127.0.0.1:8000/catalog"
  controller.controlTextDidEndEditing(Notification(name:NSControl.textDidEndEditingNotification,object:field))
  precondition(CatalogClient.baseURL.absoluteString==field.stringValue)
  field.stringValue="";controller.controlTextDidEndEditing(Notification(name:NSControl.textDidEndEditingNotification,object:field))
  precondition(CatalogClient.baseURL.absoluteString=="https://legacystore.app")
  window.appearance=NSAppearance(named:.aqua)
  RunLoop.main.run(until:Date(timeIntervalSinceNow:0.2))
  window.contentView!.layoutSubtreeIfNeeded()
  let content=window.contentView!
  for view in views where view is NSControl {
   let rect=view.convert(view.bounds,to:content)
   precondition(content.bounds.insetBy(dx:-1,dy:-1).contains(rect),"Control outside window: \(rect)")
  }
  window.close()
  print("PASS: Settings actions, catalog validation/reset, fixed window and layout bounds")
 }
}
''')
    subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor',str(root/'LightTouchMac/SettingsWindowController.swift'),str(tmp/'check.swift'),'-o',str(tmp/'check')],check=True)
    subprocess.run([str(tmp/'check')],check=True)
