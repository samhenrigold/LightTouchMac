#!/usr/bin/env python3
"""Production menu builder: selection, context row, batches and cancellation."""
from pathlib import Path
import re,subprocess,tempfile
root=Path(__file__).resolve().parents[1]/'LightTouchMac'
source=(root/'AppsInspectorViewController.swift').read_text()
a=source.index('extension AppsInspectorViewController: NSMenuDelegate')
b=source.index('// MARK: - Table data',a)
menu=source[a:b]
a=source.index('    private func canUninstall(')
uninstallValidation=source[a:source.index('\n    }',a)+6]
actions=set(re.findall(r'#selector\((\w+)\(',menu))
stubs='\n'.join('@objc func '+name+'(_ sender:Any?) {}' for name in actions)
code=r"""import Cocoa
// The menu's window scope is a dependency, not a request to focus the user's
// desktop. Live responder routing is verified separately in the running app.
@MainActor final class MenuApplication:NSApplication {
 var frontWindow:NSWindow?
 override var mainWindow:NSWindow? { frontWindow }
}
struct InstalledApp { let id:String }
struct CatalogApp { let bundleID:String; let name:String; var appURL:URL?=URL(string:"https://example.com") }
final class InstallJob { var isFinished=false,isCancelled=false,isCancellable=true,failed=false }
enum CatalogRowState { case installable, unavailable }
@MainActor enum AppInstaller { static var isPaused=false; static func isPaused(_ id:UUID)->Bool {isPaused} }
struct Instance { let id=UUID() }
@MainActor final class Emulator { var canQueueInstall=true,canReachDevice=true; let instance=Instance() }
@MainActor final class MainWindowController:NSObject {
 @objc func installApp(_ sender:Any?) {}
 @objc func syncMedia(_ sender:Any?) {}
}
@MainActor final class Table {
 var selectedRow=0,clickedRow=1
 var selectedRowIndexes=IndexSet(integer:0)
 var menu:NSMenu?=NSMenu()
}
@MainActor final class AppsInspectorViewController:NSViewController {
 override func loadView() { view=NSView() }
 let tableView=Table(),emulator=Emulator()
 var searching=false,busyWithDevice=false
 var apps=[InstalledApp(id:"one"),InstalledApp(id:"two")]
 var selectedApps:[InstalledApp]=[]
 var catalogResults=[CatalogApp(bundleID:"one",name:"One"),CatalogApp(bundleID:"two",name:"Two")]
 var pending:[InstallJob]=[],uninstalling=Set<String>()
 var job:InstallJob?
 func catalogJob(for app:CatalogApp)->InstallJob? {job}
 func catalogState(of app:CatalogApp)->CatalogRowState {.installable}
 func displayName(_ app:InstalledApp)->String {app.id}
 func app(at row:Int)->InstalledApp? {apps.indices.contains(row) ? apps[row] : nil}
"""+stubs+'\n'+uninstallValidation+'\n}\n'+menu+r"""
@main struct Check {
 @MainActor static func main() {
  let application=MenuApplication.shared as! MenuApplication
  let c=AppsInspectorViewController(),main=NSMenu()
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:200,height:200),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
  window.contentView=c.view
  application.frontWindow=window
  let context=c.tableView.menu!
  func represented(_ menu:NSMenu,_ prefix:String)->String? {
   (menu.items.first(where:{$0.title.hasPrefix(prefix)})?.representedObject as? InstalledApp)?.id
  }
  c.menuNeedsUpdate(main);c.menuNeedsUpdate(context)
  precondition(represented(main,"Open")=="one" && represented(context,"Open")=="two")
  precondition(main.item(withTitle:"Install App…")?.keyEquivalentModifierMask == [.shift,.command])
  precondition(main.item(withTitle:"Refresh Apps")?.keyEquivalent.isEmpty==true)
  precondition(context.items.allSatisfy{$0.keyEquivalent.isEmpty})
  precondition(!main.items.contains{$0.title.contains("Bundle Identifier")})
  precondition(main.item(withTitle:"Open") != nil && main.item(withTitle:"Uninstall…") != nil)
  precondition(main.item(withTitle:"Import Media…") != nil)
  c.emulator.canQueueInstall=false;c.menuNeedsUpdate(main)
  precondition(main.item(withTitle:"Install App…")?.isEnabled==false)
  c.selectedApps=c.apps;c.menuNeedsUpdate(main)
  precondition(main.item(withTitle:"Uninstall 2 Apps…") != nil)
  c.selectedApps=[];c.pending=[InstallJob()];c.pending[0].isCancelled=true;c.menuNeedsUpdate(main)
  precondition(main.item(withTitle:"Cancel Install")?.isEnabled==false)
  c.pending=[];c.searching=true;c.menuNeedsUpdate(main)
  precondition(main.item(withTitle:"Choose Version…") != nil)
  precondition(main.item(withTitle:"Install")==nil,"Installed apps offer Open, not an unavailable Install")
  c.apps=[];c.menuNeedsUpdate(main)
  precondition(main.item(withTitle:"Install") != nil && main.item(withTitle:"Open")==nil)
  c.apps=[InstalledApp(id:"one"),InstalledApp(id:"two")]
  precondition(main.item(withTitle:"Refresh Apps") != nil)
  c.tableView.selectedRow = -1;c.menuNeedsUpdate(main)
  precondition(main.item(withTitle:"Open")?.isEnabled==false && main.item(withTitle:"Uninstall…")?.isEnabled==false)
  precondition(main.item(withTitle:"Refresh Apps") != nil)
  AppInstaller.isPaused=true;c.menuNeedsUpdate(main)
  precondition(main.item(withTitle:"Resume Transfers") != nil)
  c.searching=false;c.tableView.selectedRow=0;c.emulator.canQueueInstall=false;c.emulator.canReachDevice=false;c.menuNeedsUpdate(main)
  precondition(main.items.first{$0.title.hasPrefix("Open")}?.isEnabled==false)
  precondition(main.items.first{$0.title.hasPrefix("Uninstall")}?.isEnabled==false)
  c.selectedApps=c.apps;c.menuNeedsUpdate(main)
  precondition(main.item(withTitle:"Uninstall 2 Apps…")?.isEnabled==false)
  c.emulator.canReachDevice=true;c.emulator.canQueueInstall=true;c.uninstalling=["one"];c.menuNeedsUpdate(main)
  precondition(main.item(withTitle:"Uninstall 2 Apps…")?.isEnabled==false)
  c.uninstalling=[];c.selectedApps=[];c.busyWithDevice=true;c.emulator.canReachDevice=false
  c.menuNeedsUpdate(main);c.menuNeedsUpdate(context)
  precondition(main.item(withTitle:"Uninstall…")?.isEnabled==true,"An install must not discard a requested removal")
  precondition(context.item(withTitle:"Uninstall…")?.isEnabled==true)
  precondition(main.item(withTitle:"Open")?.isEnabled==false)
  c.searching=true;c.menuNeedsUpdate(main)
  precondition(main.item(withTitle:"Uninstall…")?.isEnabled==true,"Store also queues removal while installing")
  c.uninstalling=["one"];c.menuNeedsUpdate(main)
  precondition(main.item(withTitle:"Uninstall…")?.isEnabled==false,"Do not queue the same removal twice")
  c.searching=false
  let other=NSWindow(contentRect:NSRect(x:0,y:0,width:100,height:100),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
  application.frontWindow=other;c.menuNeedsUpdate(main)
  precondition(main.items.allSatisfy{ !$0.isEnabled },"No app actions behind another main window")
  application.frontWindow=window;c.menuNeedsUpdate(main)
  precondition(main.item(withTitle:"Refresh Apps")?.isEnabled==true)
  print("PASS: main/context selection, unavailable devices, stable empty selection, and front-window scope")
 }
}
"""
with tempfile.TemporaryDirectory(prefix='ltm-apps-menu-') as tmp:
 tmp=Path(tmp);(tmp/'check.swift').write_text(code)
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(tmp/'check.swift'),'-o',str(tmp/'check')],check=True)
 subprocess.run([str(tmp/'check')],check=True,timeout=20)
