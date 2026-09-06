#!/usr/bin/env python3
"""Exercise production Help against its actual bundled text."""
from pathlib import Path
import plistlib,shutil,subprocess,tempfile
root=Path(__file__).resolve().parents[1]/'LightTouchMac'
s=(root/'AppDelegate.swift').read_text()
a=s.index('    @objc func showHelp(');b=s.index('    func applicationDockMenu(',a)
source="import Cocoa\n@MainActor final class Check:NSObject { var helpController:NSWindowController?\n"+s[a:b]+r'''
}
@main struct Run {
 @MainActor static func main() {
  _=NSApplication.shared
  let check=Check();check.showHelp(nil)
  let window=check.helpController!.window!
  check.showHelp(nil);precondition(check.helpController!.window===window)
  let scroll=window.contentView!.subviews.compactMap{$0 as? NSScrollView}.first!
  let text=scroll.documentView as! NSTextView
  precondition(!text.isEditable && text.isSelectable && text.usesFindBar)
  precondition(text.string.contains("Recordings include device audio"))
  precondition(text.string.contains("Controller release"))
  precondition(scroll.hasVerticalScroller && text.frame.height>scroll.contentSize.height)
  window.setContentSize(NSSize(width:400,height:400));window.contentView!.layoutSubtreeIfNeeded()
  precondition(text.textContainer!.widthTracksTextView)
  window.close()
  print("PASS: bundled Help content, scrolling, selectable text, Find and reused window")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-help-') as tmp:
    tmp=Path(tmp);app=tmp/'Help Check.app/Contents'
    (app/'MacOS').mkdir(parents=True);(app/'Resources').mkdir()
    (app/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='app.lighttouch.helpcheck',CFBundleExecutable='check',CFBundlePackageType='APPL')))
    shutil.copyfile(root/'Help.txt',app/'Resources/Help.txt')
    (tmp/'check.swift').write_text(source)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor',str(tmp/'check.swift'),'-parse-as-library','-o',str(app/'MacOS/check')],check=True)
    subprocess.run([str(app/'MacOS/check')],check=True)
