#!/usr/bin/env python3
"""Exercise production Store and transfer cells at narrow/wide inspector widths."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
source=(root/'LightTouchMac/UI/AppsInspectorViewController.swift').read_text()
def method(signature):
 a=source.index(signature)
 return source[a:source.index('\n    }',a)+6]
fixture=r'''import Cocoa
struct CatalogApp {var name:String; var bundleID:String?="test";var ipaID=1;var version:String?="1.0";var subtitle="Example Developer · 5 MB"}
final class InstallJob {
 let deviceID=UUID()
 var failed=false,dismissed=false,isCancellable=true
 var catalogIpaID:Int?=1;var bundleID:String?="test";var status="Downloading…";var retry:(()->Void)?
 func cancel(){}
}
enum AppInstaller {static var isPaused=false; static func isPaused(_ id:UUID)->Bool {isPaused}}
final class Fixture:NSObject {
 enum State:Equatable {case installable,installed,unavailable,downloading(Double?),installing}
 var state=State.installable
 var pending:[InstallJob]=[]
 var uninstalling=Set<String>(),removingApp:String?

 struct App {var id:String};var apps=[App(id:"test")]
 struct Instance {let id=UUID()}
 struct Emulator {var canReachDevice=true;let instance=Instance()};var emulator=Emulator();var busyWithDevice=false
 func catalogState(of app:CatalogApp)->State {state}
 func catalogIcon(_ app:CatalogApp)->NSImage? {nil}
 func catalogJob(for app:CatalogApp)->InstallJob? {pending.first}
 static func setIcon(_ icon:NSImage?,on image:NSImageView){image.image=icon}
 @objc func catalogInstallClicked(_ sender:Any?){}
 @objc func resumeInstallsClicked(_ sender:Any?){}
'''+method('    private func removalStatus(')+'\n'+method('    private func catalogCell(')+'\n'+method('    private func progressCell(')+r'''
 static func run() {
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:56),styleMask:[.titled],backing:.buffered,defer:false)
  let fixture=Fixture()
  for width in [240.0,320.0,500.0] {
   for name in ["Facebook", "Doodle Jump — BE WARNED: Insanely Addictive!"] {
    for state in [State.installable,.installed,.downloading(0.5),.installing] {
     fixture.state=state;fixture.pending=[InstallJob()]
     let cell=fixture.catalogCell(for:CatalogApp(name:name),row:0)
     window.contentView=cell;window.setContentSize(NSSize(width:width,height:56));window.orderFront(nil)
     cell.layoutSubtreeIfNeeded()
     let title=cell.textField!,image=cell.imageView!
     let subtitle=cell.subviews.compactMap{$0 as? NSTextField}.first{$0 !== title}!
     precondition(title.maximumNumberOfLines==1)
     precondition(abs(title.frame.minX-subtitle.frame.minX)<0.5)
     precondition(abs(image.frame.midY-28)<0.5 && abs(image.frame.width-32)<0.5)
     let button=cell.subviews.compactMap{$0 as? NSButton}.first!
     let buttonFrame=button.alignmentRect(forFrame:button.frame)
     precondition(abs(buttonFrame.width-(state == .installed || state == .installable ? 60:54))<0.5,"Action width changed with text")
     precondition(title.frame.maxX<buttonFrame.minX && title.frame.minX>image.frame.maxX)
     if state == .installing || state == .downloading(0.5) {
      let progress=cell.subviews.compactMap{$0 as? NSProgressIndicator}.first!
      precondition(!progress.isHidden && !button.isHidden && progress.frame.width==16,"Progress must remain visible alongside Cancel")
      precondition(progress.isIndeterminate == (state == .installing))
     }
    }
   }
  }
  fixture.uninstalling=["test"];fixture.state = .installed
  let queued=fixture.catalogCell(for:CatalogApp(name:"Diner Dash"),row:0)
  precondition(queued.subviews.compactMap{$0 as? NSTextField}.contains{$0.stringValue=="Waiting to remove…"})
  fixture.removingApp="test"
  let removing=fixture.catalogCell(for:CatalogApp(name:"Diner Dash"),row:0)
  precondition(removing.subviews.compactMap{$0 as? NSTextField}.contains{$0.stringValue=="Removing…"})
  print("PASS: Store/transfer rows align icons and labels, preserve compact actions and show determinate/indeterminate progress with Cancel")
 }
}
@main struct Check { @MainActor static func main(){_=NSApplication.shared;Fixture.run()} }
'''
with tempfile.TemporaryDirectory(prefix='ltm-row-layout-') as directory:
 work=Path(directory);(work/'check.swift').write_text(fixture)
 subprocess.run(['swiftc','-default-isolation','MainActor',str(root/'LightTouchMac/UI/InlineActionButton.swift'),str(work/'check.swift'),'-o',str(work/'check')],check=True)
 subprocess.run([str(work/'check')],check=True,timeout=20)
