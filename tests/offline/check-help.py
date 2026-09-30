#!/usr/bin/env python3
"""Exercise production Help against its actual bundled text: task topics in a sidebar, the chosen topic's text,
[Device] read as the device's name, the HIG audit's Help cuts and menu paths that exist.
--out DIR keeps a render of one topic (help-topic.png); the window is never ordered front."""
from pathlib import Path
import argparse,plistlib,shutil,subprocess,tempfile
ap=argparse.ArgumentParser();ap.add_argument('--out');args=ap.parse_args()
root=Path(__file__).resolve().parents[2]/'LightTouchMac'
s=(root/'App/AppDelegate.swift').read_text()
a=s.index('    @objc func showHelp(');b=s.index('    func applicationDockMenu(',a)
# The production showHelp, minus ordering the window front: nothing goes on screen.
show=s[a:b]
for front in ['        helpController?.showWindow(sender)\n','        helpController?.window?.makeKeyAndOrderFront(sender)\n']:
    assert front in show, 'showHelp changed: update this check'
    show=show.replace(front,'')
source="import Cocoa\n@MainActor final class Check:NSObject { var helpController:HelpWindowController?\n struct Profile { var shortName=\"iPad\" }\n struct Emulator { var profile=Profile() }\n var emulator:Emulator?=Emulator()\n"+show+r'''
}
@main struct Run {
 @MainActor static func main() {
  _=NSApplication.shared
  let check=Check();check.showHelp(nil)
  let help=check.helpController!, window=help.window!
  check.showHelp(nil);precondition(check.helpController===help && help.window===window,"Help reuses its window")
  let whole=try! String(contentsOf:Bundle.main.url(forResource:"Help",withExtension:"txt")!,encoding:.utf8)
  let topics=HelpWindowController.topics(whole)
  let titles=topics.map(\.title)
  precondition(topics.count>=10 && Set(titles).count==titles.count && titles.first=="Adding and starting devices" && titles.last=="Licenses","\(titles)")
  precondition(topics.allSatisfy { !$0.body.isEmpty && !$0.body.contains("\n# ") })
  func descendants(_ v:NSView)->[NSView] { [v]+v.subviews.flatMap(descendants) }
  let list=descendants(window.contentView!).compactMap{$0 as? NSTableView}.first!, text=help.text
  precondition(list.numberOfRows==topics.count && list.selectedRow==0)
  precondition(!text.isEditable && text.isSelectable && text.usesFindBar)
  func show(_ title:String)->String {
   list.selectRowIndexes([titles.firstIndex(of:title)!],byExtendingSelection:false)
   return text.string
  }
  // Choosing a topic shows that topic, not the whole file.
  let capture=show("Screenshots and recordings")
  precondition(capture.hasPrefix("Screenshots and recordings\n") && capture.contains("Recordings include device audio") && !capture.contains("Physical Size"))
  precondition(show("Rotating and zooming").contains("Physical Size") && show("Motion").contains("Natural Scrolling") && show("Motion").contains("Rotate with two fingers"))
  // [Device] is the device's name (here the iPad the check's emulator is).
  let files=show("Device files")
  precondition(files.contains("Show iPad Files") && files.contains("Copy to iPad") && !files.contains("[Device]"),files)
  help.show(deviceName:"iPod");precondition(text.string.contains("Show iPod Files") && list.selectedRow==titles.firstIndex(of:"Device files"),"a new name keeps the topic")
  // The audit's cuts, and menu paths that moved: none may come back.
  for gone in ["stands for","It is unavailable when measurements","The pointer stops interacting","Refresh Apps refreshes","share the inspector’s queue",
               "starts when the device is free","The Apps inspector opens","converts raw AAC","stay out of captures","offers Discard, Stop and Save",
               "cancelling keeps","dismisses its notification","old saved city","moon","Successful retries","inspect the boot","Updates pause while",
               "displayed tail","Controller release","Device → Orientation","Help → Device Logs","Help → Show Unfinished","Capture → Capture Options",
               "⌘O","Edit → Search Apps","Local Network","Device Logs button","next app launch"] {
   precondition(!whole.contains(gone),"Help still says: \(gone)")
  }
  for path in ["File → Add Device (⌘N)","Window → Device Logs","Capture → Show Unfinished Recordings","Light Touch → Settings → Capture","Device → Motion"] {
   precondition(whole.contains(path),"Help lacks \(path)")
  }
  // A long topic scrolls in a small window; the text wraps to the column.
  window.setContentSize(NSSize(width:560,height:300));window.contentView!.layoutSubtreeIfNeeded()
  _=show("Screenshots and recordings");text.layoutManager!.ensureLayout(for:text.textContainer!);text.sizeToFit()
  let scroll=text.enclosingScrollView!
  precondition(scroll.hasVerticalScroller && text.frame.height>scroll.contentSize.height && text.textContainer!.widthTracksTextView)
  if CommandLine.arguments.count>1 {
   window.setContentSize(NSSize(width:780,height:560));window.contentView!.layoutSubtreeIfNeeded()
   _=show("Keyboard access")
   let content=window.contentView!
   let rep=content.bitmapImageRepForCachingDisplay(in:content.bounds)!
   content.cacheDisplay(in:content.bounds,to:rep)
   try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("help-topic.png"))
  }
  precondition(!window.isVisible)
  window.close()
  print("PASS: bundled Help as \(topics.count) task topics, topic selection, [Device] naming, the audit's cuts and current menu paths, scrolling, Find and reused window")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-help-') as tmp:
    tmp=Path(tmp);app=tmp/'Help Check.app/Contents'
    (app/'MacOS').mkdir(parents=True);(app/'Resources').mkdir()
    (app/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='app.lighttouch.helpcheck',CFBundleExecutable='check',CFBundlePackageType='APPL')))
    shutil.copyfile(root/'Help.txt',app/'Resources/Help.txt')
    (tmp/'check.swift').write_text(source)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor',str(root/'App/WindowRestorationPolicy.swift'),str(root/'UI/HelpWindowController.swift'),str(tmp/'check.swift'),'-parse-as-library','-o',str(app/'MacOS/check')],check=True)
    subprocess.run([str(app/'MacOS/check'),*([args.out] if args.out else [])],check=True)
