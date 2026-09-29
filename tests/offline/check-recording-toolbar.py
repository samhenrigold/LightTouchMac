#!/usr/bin/env python3
"""Exercise the production native recording button in a customizable toolbar."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
source=r'''import Cocoa
@MainActor final class Target:NSObject,NSToolbarDelegate {
 let button=RecordingToolbarButton(target:nil,action:#selector(record(_:)))
 var count=0
 @objc func record(_ sender:Any?) {count += 1}
 func toolbarDefaultItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier] { [.init("record")] }
 func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier] {toolbarDefaultItemIdentifiers(toolbar)}
 func toolbar(_ toolbar:NSToolbar,itemForItemIdentifier id:NSToolbarItem.Identifier,willBeInsertedIntoToolbar flag:Bool)->NSToolbarItem? {
  let item=NSToolbarItem(itemIdentifier:id);item.label="Record";item.view=button;return item
 }
}
@main struct Check {
 @MainActor static func main() {
  _=NSApplication.shared
  let target=Target(),window=NSWindow(contentRect:NSRect(x:0,y:0,width:620,height:420),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
  let toolbar=NSToolbar(identifier:"record-check");toolbar.delegate=target;toolbar.displayMode = .iconOnly
  window.toolbar=toolbar
  let button=target.button;button.target=target
  button.update(.idle,elapsed:"0:00",enabled:true)
  precondition(button.title.isEmpty && button.accessibilityLabel()=="Start Recording" && button.isEnabled)
  let idleWidth=button.intrinsicContentSize.width
  button.performClick(nil);precondition(target.count==1)
  button.update(.recording,elapsed:"1:23:45",enabled:true)
  precondition(button.title=="1:23:45" && button.accessibilityLabel()=="Stop Recording")
  precondition(button.accessibilityValue() as? String == "1:23:45")
  precondition(button.intrinsicContentSize.width>idleWidth)
  window.contentView?.layoutSubtreeIfNeeded()
  precondition(button.frame.width>=button.intrinsicContentSize.width,"Elapsed time clipped")
  button.performClick(nil);precondition(target.count==2)
  button.update(.saving,elapsed:"1:23:45",enabled:false)
  button.layoutSubtreeIfNeeded()
  let spinner=button.subviews.compactMap{$0 as? NSProgressIndicator}.first!
  precondition(!button.isEnabled && button.title.isEmpty && button.accessibilityLabel()=="Saving Recording…")
  precondition(spinner.frame.width>0 && spinner.frame.height>0 && button.bounds.contains(spinner.frame),"Saving progress must fit")
  precondition(button.accessibilityValue()==nil)
  button.update(.recovery,elapsed:"1:23:45",enabled:true)
  precondition(button.accessibilityLabel()=="Save Recording As…" && button.isEnabled)
  button.update(.idle,elapsed:"0:00",enabled:false)
  precondition(button.intrinsicContentSize.width==idleWidth && button.title.isEmpty && !button.isEnabled)
  print("PASS: native record/stop action, elapsed sizing, saving progress, accessible phase labels, recovery and idle reset")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-recording-toolbar-') as directory:
 work=Path(directory);(work/'check.swift').write_text(source)
 subprocess.run(['swiftc','-swift-version','6','-default-isolation','MainActor','-module-cache-path',str(work/'modules'),str(root/'LightTouchMac/UI/RecordingToolbarButton.swift'),str(work/'check.swift'),'-o',str(work/'check')],check=True)
 subprocess.run([str(work/'check')],check=True,timeout=20)
