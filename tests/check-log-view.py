#!/usr/bin/env python3
"""Bounded production log reads and native window polling/selection behavior."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='ltm-logs-') as tmp:
 tmp=Path(tmp)
 (tmp/'check.swift').write_text(r"""import Cocoa
@main struct Check {
 @MainActor static func main() async throws {
  _ = NSApplication.shared
  let file=URL(fileURLWithPath:CommandLine.arguments[1])
  try Data("first\n".utf8).write(to:file)
  precondition(LogWindowController.tail(file)=="first\n")
  var large=Data(repeating:65,count:70000);large.append(Data("\nlast line\n".utf8))
  try large.write(to:file)
  precondition(LogWindowController.tail(file)=="last line\n")
  try Data([255,10]).write(to:file)
  precondition(LogWindowController.tail(file).contains("\u{fffd}"))
  try Data().write(to:file);precondition(LogWindowController.tail(file)=="No log output yet.")
  let missing=file.appendingPathExtension("missing")
  precondition(LogWindowController.tail(missing).hasPrefix("Cannot read"))
  try Data("visible\n".utf8).write(to:file)
  let controller=LogWindowController(logs:[file,missing])
  controller.showWindow(nil)
  try await Task.sleep(for:.milliseconds(300))
  let content=controller.window!.contentView!
  let scroll=content.subviews.compactMap{$0 as? NSScrollView}.first!
  let text=scroll.documentView as! NSTextView
  precondition(text.string=="visible\n" && !text.isEditable && text.isSelectable && text.usesFindBar)
  precondition(scroll.frame.width>0 && scroll.frame.height>0)
  text.setSelectedRange(NSRange(location:0,length:3))
  try Data("replacement\n".utf8).write(to:file,options:.atomic)
  try await Task.sleep(for:.milliseconds(1200))
  precondition(text.string=="visible\n","selection must pause updates")
  text.setSelectedRange(NSRange(location:0,length:0))
  try await Task.sleep(for:.milliseconds(1200))
  precondition(text.string=="replacement\n","atomic log rotation must reopen the file")
  let controls=content.subviews.compactMap{$0 as? NSStackView}.first!
  let pause=controls.arrangedSubviews.compactMap{$0 as? NSButton}.first{$0.title=="Pause updates"}!
  pause.state = .on
  try Data("paused\n".utf8).write(to:file)
  try await Task.sleep(for:.milliseconds(1200));precondition(text.string=="replacement\n")
  pause.state = .off
  controller.close()
  try await Task.sleep(for:.milliseconds(1200));precondition(text.string=="replacement\n")
  controller.showWindow(nil)
  try await Task.sleep(for:.milliseconds(300));precondition(text.string=="paused\n")
  controller.close()
  print("PASS: bounded UTF-8 tail, empty/missing files, native polling, rotation, selection/pause and close/reopen")
 }
}
""")
 subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor',str(root/'LightTouchMac/LogWindowController.swift'),str(tmp/'check.swift'),'-o',str(tmp/'check')],check=True)
 subprocess.run([str(tmp/'check'),str(tmp/'serial.log')],check=True)
