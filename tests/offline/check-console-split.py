#!/usr/bin/env python3
"""The main pane's console split (UI/ConsoleSplit.swift), compiled from the real sources, never on screen:
snap detents and the collapse threshold, the show/hide state machine, drags and double-clicks on the bar,
window resizes that squeeze and give back the console, per-name persistence, Clear and Filter on the log.
LTM_CONSOLE_SPLIT_PNGS=<dir> also renders the view offscreen at a few positions into PNGs there."""
from pathlib import Path
import os, subprocess, tempfile
root = Path(__file__).resolve().parents[2]
check = r"""import Cocoa
typealias L = ConsoleSplitLayout
func expect(_ ok: Bool, _ what: String, line: Int = #line) { if !ok { print("FAIL line \(line): \(what)"); exit(1) } }

@main struct Check {
 @MainActor static func main() async throws {
  _ = NSApplication.shared
  // Detents: available 600 -> range 100...440, middle 270, default 200; tolerance 10 (strict).
  let cases: [(CGFloat, CGFloat?)] = [(265, 270), (279.5, 270), (261, 270), (280, 280), (260, 260),
      (195, 200), (209, 200), (210, 210), (191, 200), (190, 190),
      (99, 100), (50, 100), (49.9, nil), (0, nil), (1000, 440), (433.7, 433)]
  for (proposed, want) in cases {
   let got = L.resolve(proposed, in: 600)
   expect(got == want, "resolve(\(proposed)) = \(String(describing: got)), want \(String(describing: want))")
  }
  // A short pane: range 100...195, so the 200 detent is out of reach and must not pull past the maximum.
  expect(L.resolve(195, in: 355) == 195 && L.resolve(300, in: 355) == 195, "detent beyond the maximum")
  expect(L.resolve(150, in: 355) == 148, "middle of a short range snaps")   // (100+195)/2 = 147.5 -> 148

  // Show/hide: a fresh window starts collapsed at the default height; hiding keeps the height.
  var l = L()
  expect(l.isCollapsed && l.height == 200, "fresh state")
  l.toggle(); expect(!l.isCollapsed && l.height == 200, "show restores")
  l.height = 320; l.toggle(); expect(l.isCollapsed && l.height == 320, "hide keeps the height")
  l.toggle(); expect(!l.isCollapsed && l.height == 320, "show brings it back")
  l = L(height: 40, isCollapsed: true); l.toggle(); expect(!l.isCollapsed && l.height == 200, "too-short height reopens at default")
  // Drags: collapsing by drag keeps the height the drag started from.
  let start = L(height: 320, isCollapsed: false)
  l = start; l.drag(from: start, to: 30, in: 600); expect(l.isCollapsed && l.height == 320, "drag collapse keeps start height")
  l.drag(from: start, to: 120, in: 600); expect(!l.isCollapsed && l.height == 120, "drag back open")

  // Persistence round trip, per name.
  let suite = "ltm-console-split-check-\(getpid())", defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  L(height: 333, isCollapsed: false).save("a", to: defaults)
  expect(L.load("a", from: defaults) == L(height: 333, isCollapsed: false), "round trip")
  expect(L.load("b", from: defaults) == L(), "other names start fresh")

  // The view, offscreen.
  let top = Stage()
  let split = ConsoleSplitView(top: top, autosaveName: "view", defaults: defaults)
  split.appearance = NSAppearance(named: .aqua)
  // Hosted as the window hosts it: the host's size is fixed (a window's content view), the split fills it.
  let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600 + ConsoleBar.height))
  split.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(split)
  let hostWidth = host.widthAnchor.constraint(equalToConstant: 800), hostHeight = host.heightAnchor.constraint(equalToConstant: 0)
  NSLayoutConstraint.activate([hostWidth, hostHeight, split.leadingAnchor.constraint(equalTo: host.leadingAnchor),
   split.trailingAnchor.constraint(equalTo: host.trailingAnchor), split.topAnchor.constraint(equalTo: host.topAnchor),
   split.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
  func resize(_ height: CGFloat) { hostHeight.constant = height + ConsoleBar.height; host.layoutSubtreeIfNeeded() }
  resize(600)
  let bar = split.bar, log = split.log
  expect(log.frame.height == 0 && bar.frame.minY == 0 && top.frame.height == 600, "collapsed: bar pinned at the bottom")
  expect(bar.filter.isHidden && bar.clearButton.isHidden && !bar.toggleButton.isHidden, "collapsed bar shows only the toggle")
  expect(bar.toggleButton.state == .off && bar.toggleButton.toolTip == "Show Console (⇧⌘Y)", "toggle off")
  let log1 = try sampleLog()
  defer { try? FileManager.default.removeItem(at: log1.deletingLastPathComponent()) }
  split.sources = [log1, log1.deletingLastPathComponent().appendingPathComponent("usbmuxd.log")]
  expect(bar.source.itemTitles == ["serial.log", "usbmuxd.log"] && log.url == log1, "sources")
  func settle() async throws { try await Task.sleep(for: .milliseconds(400)); split.layoutSubtreeIfNeeded() }
  render(split, "collapsed")

  bar.toggleButton.performClick(nil); try await settle()
  expect(!split.layout.isCollapsed && log.frame.height == 200 && !log.isHidden, "toggle shows at 200, got \(log.frame.height)")
  expect(bar.toggleButton.state == .on && !bar.filter.isHidden && bar.toggleButton.toolTip == "Hide Console (⇧⌘Y)", "toggle on")
  expect(L.load("view", from: defaults) == split.layout, "toggle persists")
  log.text.string = (1...40).map { "[\($0)] serial: line \($0)" }.joined(separator: "\n")
  render(split, "expanded-default")

  // Drags on the bar, from 200: up 62 is 262, within 10 of the middle (100+440)/2 = 270.
  func drag(_ dy: CGFloat, clicks: Int = 1) {
   func event(_ type: NSEvent.EventType, _ y: CGFloat) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: NSPoint(x: 400, y: y), modifierFlags: [], timestamp: 0, windowNumber: 0,
                       context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
   }
   bar.mouseDown(with: event(.leftMouseDown, 300)); bar.mouseDragged(with: event(.leftMouseDragged, 300 + dy / 2))
   bar.mouseDragged(with: event(.leftMouseDragged, 300 + dy)); bar.mouseUp(with: event(.leftMouseUp, 300 + dy))
   split.layoutSubtreeIfNeeded()
  }
  drag(62); expect(log.frame.height == 270, "drag to 262 snaps to 270, got \(log.frame.height)")
  render(split, "snapped-middle")
  drag(-40); expect(log.frame.height == 230, "drag to 230 stays, got \(log.frame.height)")
  drag(180); expect(log.frame.height == 410, "drag to 410 stays, got \(log.frame.height)")
  render(split, "expanded-tall")
  drag(-400); expect(split.layout.isCollapsed && log.frame.height == 0 && split.layout.height == 410, "drag below threshold collapses, keeps 410")
  expect(L.load("view", from: defaults) == L(height: 410, isCollapsed: true), "drag persists")
  drag(150); expect(!split.layout.isCollapsed && log.frame.height == 150, "drag up from collapsed opens at the drag")
  drag(-60); expect(log.frame.height == 100, "between threshold and minimum clamps to 100, got \(log.frame.height)")
  drag(0, clicks: 2); try await settle(); expect(split.layout.isCollapsed && log.frame.height == 0, "double-click hides")
  drag(0, clicks: 2); try await settle(); expect(!split.layout.isCollapsed && log.frame.height == 100, "double-click shows")

  // A short window squeezes the console to leave the device 160 pt, and gives the height back.
  drag(300); expect(log.frame.height == 400, "set up 400, got \(log.frame.height)")
  resize(400)
  expect(log.frame.height == 240 && top.frame.height == 160, "short window: console 240, got \(log.frame.height)")
  resize(600)
  expect(log.frame.height == 400 && split.layout.height == 400, "tall again: the console's height comes back")
  // A new view with the same name reopens where this one was left.
  let again = ConsoleSplitView(top: NSView(), autosaveName: "view", defaults: defaults)
  expect(again.layout == L(height: 400, isCollapsed: false) && again.bar.toggleButton.state == .on, "restored")

  // Clear and Filter.
  try Data("old 1\nold 2\n".utf8).write(to: log1)
  let size = UInt64(try FileManager.default.attributesOfItem(atPath: log1.path)[.size] as! Int)
  try FileHandle(forWritingTo: log1).then { try $0.seekToEnd(); try $0.write(contentsOf: Data("new 3\n".utf8)); try $0.close() }
  let cleared = LogWindowController.tail(log1, from: size)
  expect(cleared.text == "new 3\n" && !cleared.rotated, "clear shows only what came after, got \(cleared.text)")
  expect(LogWindowController.tail(log1, from: size + 6).text == "", "cleared and nothing new: empty, not the placeholder")
  try Data("rotated\n".utf8).write(to: log1, options: .atomic)
  let rotated = LogWindowController.tail(log1, from: size)
  expect(rotated.rotated && rotated.text == "rotated\n", "a shorter file was replaced: read it all")
  expect(LogTextView.filtered("usb up\nkernel\nUSB down", by: "usb") == "usb up\nUSB down", "filter is case-insensitive per line")
  expect(LogTextView.filtered("a\nb", by: "") == "a\nb", "empty filter shows all")

  if let dir = ProcessInfo.processInfo.environment["LTM_CONSOLE_SPLIT_PNGS"] {
   for (name, image) in rendered { try image.write(to: URL(fileURLWithPath: dir).appendingPathComponent("console-\(name).png")) }
   print("wrote \(rendered.count) PNGs to \(dir)")
  }
  print("PASS: detents, collapse threshold, toggle, drag, double-click, resize, persistence, clear and filter")
 }
}

@MainActor var rendered: [(String, Data)] = []
@MainActor func render(_ view: NSView, _ name: String) {
 view.layoutSubtreeIfNeeded()
 let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
 view.cacheDisplay(in: view.bounds, to: rep)
 rendered.append((name, rep.representation(using: .png, properties: [:])!))
}

func sampleLog() throws -> URL {
 let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-console-\(getpid())")
 try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
 let url = dir.appendingPathComponent("serial.log"); try Data("boot\n".utf8).write(to: url); return url
}

extension FileHandle { func then(_ body: (FileHandle) throws -> Void) rethrows { try body(self) } }

/// A stand-in for the device pane.
final class Stage: NSView {
 override func draw(_ dirtyRect: NSRect) {
  NSGradient(starting: .systemIndigo, ending: .systemTeal)!.draw(in: bounds, angle: 90)
  let label = "Device" as NSString
  let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 28, weight: .semibold), .foregroundColor: NSColor.white]
  let size = label.size(withAttributes: attributes)
  label.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
 }
}
"""
with tempfile.TemporaryDirectory(prefix='ltm-console-split-') as tmp:
    tmp = Path(tmp)
    (tmp / 'check.swift').write_text(check)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-default-isolation', 'MainActor', '-module-cache-path', str(tmp / 'modules'),
                    str(root / 'LightTouchMac/App/WindowRestorationPolicy.swift'), str(root / 'LightTouchMac/UI/LogWindowController.swift'),
                    str(root / 'LightTouchMac/UI/ConsoleSplit.swift'), str(tmp / 'check.swift'), '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check')], check=True, timeout=60, env=os.environ)
