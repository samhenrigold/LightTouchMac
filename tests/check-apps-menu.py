#!/usr/bin/env python3
"""Production menu builder: selection, context row, batches and cancellation."""
from pathlib import Path
import re,subprocess,tempfile
root=Path(__file__).resolve().parents[1]/'LightTouchMac'
source=(root/'AppsInspectorViewController.swift').read_text()
a=source.index('extension AppsInspectorViewController: NSMenuDelegate')
b=source.index('// MARK: - Table data',a)
menu=source[a:b]
actions=set(re.findall(r'#selector\((\w+)\(',menu))
stubs='\n'.join('@objc func '+name+'(_ sender:Any?) {}' for name in actions)
code=r"""import Cocoa
struct InstalledApp { let id:String }
struct CatalogApp { let bundleID:String; let name:String; var appURL:URL?=URL(string:"https://example.com") }
final class InstallJob { var isFinished=false,isCancelled=false,isCancellable=true }
enum CatalogRowState { case installable, unavailable }
@MainActor enum AppInstaller { static var isPaused=false }
@MainActor final class Emulator { var canQueueInstall=true,canReachDevice=true }
@MainActor final class MainWindowController:NSObject {
 @objc func installApp(_ sender:Any?) {}
 @objc func syncMedia(_ sender:Any?) {}
}
@MainActor final class Table {
 var selectedRow=0,clickedRow=1
 var selectedRowIndexes=IndexSet(integer:0)
 var menu:NSMenu?=NSMenu()
}
@MainActor final class AppsInspectorViewController:NSObject {
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
"""+stubs+'\n}\n'+menu+r"""
@main struct Check {
 @MainActor static func main() {
  _ = NSApplication.shared
  let c=AppsInspectorViewController(),main=NSMenu()
  let context=c.tableView.menu!
  func represented(_ menu:NSMenu,_ prefix:String)->String? {
   (menu.items.first(where:{$0.title.hasPrefix(prefix)})?.representedObject as? InstalledApp)?.id
  }
  c.menuNeedsUpdate(main);c.menuNeedsUpdate(context)
  precondition(represented(main,"Open")=="one" && represented(context,"Open")=="two")
  precondition(main.item(withTitle:"Install App…")?.keyEquivalentModifierMask == [.shift,.command])
  precondition(main.item(withTitle:"Refresh")?.keyEquivalent=="r")
  precondition(context.items.allSatisfy{$0.keyEquivalent.isEmpty})
  c.emulator.canQueueInstall=false;c.menuNeedsUpdate(main)
  precondition(main.item(withTitle:"Install App…")?.isEnabled==false)
  c.selectedApps=c.apps;c.menuNeedsUpdate(main)
  precondition(main.item(withTitle:"Uninstall 2 Apps…") != nil)
  c.selectedApps=[];c.pending=[InstallJob()];c.pending[0].isCancelled=true;c.menuNeedsUpdate(main)
  precondition(main.item(withTitle:"Cancel Install")?.isEnabled==false)
  c.pending=[];c.searching=true;c.menuNeedsUpdate(main)
  precondition(main.item(withTitle:"Versions and Details…") != nil)
  precondition(main.item(withTitle:"Refresh") != nil)
  c.tableView.selectedRow = -1;c.menuNeedsUpdate(main)
  precondition(!main.items.contains{$0.title.hasPrefix("Open")})
  precondition(main.item(withTitle:"Refresh") != nil)
  AppInstaller.isPaused=true;c.menuNeedsUpdate(main)
  precondition(main.item(withTitle:"Resume Pending Installs") != nil)
  print("PASS: main/context row routing, batch actions, disabled cancellation, catalog and empty selection")
 }
}
"""
with tempfile.TemporaryDirectory(prefix='ltm-apps-menu-') as tmp:
 tmp=Path(tmp);(tmp/'check.swift').write_text(code)
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(tmp/'check.swift'),'-o',str(tmp/'check')],check=True)
 subprocess.run([str(tmp/'check')],check=True)
