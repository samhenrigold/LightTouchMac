#!/usr/bin/env python3
"""Exercise the real proxy panel's choices and transient status layout, and the
per-device proxy files (each device's helper proxy reads its own routing)."""
from pathlib import Path
import subprocess, tempfile
DEVICE_PROFILE = str(Path(__file__).resolve().parents[2] / 'LightTouchMac/Device/DeviceProfile.swift')
root = Path(__file__).resolve().parents[2]
fixture = r'''import Cocoa
struct Bundled { static let stateDirectory = URL(fileURLWithPath: NSTemporaryDirectory()) }
struct WebProxyEndpoint: Equatable { var config: String; var socket: String }
enum DeviceToolsError: Error { case failed(String) }
struct DeviceInstance {
 struct Storage { var usbmuxConf: String }
 struct Paths { var directory: URL }
 var storage: Storage
 var paths: Paths
}
func descendants(_ view: NSView) -> [NSView] {
 var children = view.subviews
 if let stack = view as? NSStackView {
  for child in stack.arrangedSubviews where !children.contains(where: { $0 === child }) { children.append(child) }
 }
 return [view] + children.flatMap(descendants)
}
@main struct Check {
 @MainActor static func main() {
  NSTimeZone.default = TimeZone(identifier: CommandLine.arguments[1])!
  // The device that kept the legacy pairing conf keeps the legacy files (its guest trusts that CA).
  let legacy = DeviceInstance(storage: .init(usbmuxConf: "work/usbmuxd-conf"), paths: .init(directory: URL(fileURLWithPath: "/nonexistent")))
  precondition(WebProxyConfiguration.directory(for: legacy) == Bundled.stateDirectory)
  let own = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ltm-proxy-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: own) }
  let other = DeviceInstance(storage: .init(usbmuxConf: "Devices/x/usbmuxd-conf"), paths: .init(directory: own))
  precondition(WebProxyConfiguration.directory(for: other) == own)
  precondition(WebProxyConfiguration.load(from: own) == WebProxyConfiguration(), "a new device starts with the proxy off")
  let saved = WebProxyConfiguration(mode: .archive, archiveDate: "20100101")
  try! saved.save(in: own)
  precondition(WebProxyConfiguration.load(from: own) == saved)
  precondition((try? String(contentsOf: WebProxyConfiguration.file(in: own), encoding: .utf8)) == "archive\n20100101\n")
  let endpoint = WebProxyConfiguration.endpoint(directory: own)
  precondition(endpoint.config == WebProxyConfiguration.file(in: own).path && endpoint.socket.utf8.count < 104)
  precondition(endpoint != WebProxyConfiguration.endpoint(directory: own.appendingPathComponent("other")), "one socket per device")
  precondition(WebProxyConfiguration.guestForward(socket: "/t/a,b's") == ",guestfwd=tcp:10.0.2.100:3128-cmd:/usr/bin/nc -U '/t/a,,b'\"'\"'s'")
  _ = NSApplication.shared
  for mode in [WebProxyConfiguration.Mode.off, .direct, .archive] {
   let initial = WebProxyConfiguration(mode: mode, archiveDate: "20090909")
   let panel = ProxySettingsView(configuration: initial, status: .ready, profile: .iPodTouch2G)
   let alert = NSAlert()
   alert.messageText = "Proxy"
   alert.addButton(withTitle: "Apply")
   alert.addButton(withTitle: "Cancel")
   alert.accessoryView = panel
   panel.onResize = { [weak alert] in alert?.layout() }
   alert.layout()
   precondition(panel.configuration == initial)
   let all = descendants(panel)
   let buttons = all.compactMap { $0 as? NSButton }
   let enabled = buttons.first { $0.title == "Use HTTP proxy" }!
   let archive = buttons.first { $0.title == "Browse the Internet Archive" }!
   let date = all.compactMap { $0 as? NSDatePicker }.first!
   // AppKit exposes an NSDate for accessibility. Its local calendar day must
   // agree with the selected date, not the previous evening in western zones.
   let components = Calendar.current.dateComponents([.year, .month, .day, .hour], from: date.dateValue)
   precondition(components.year == 2009 && components.month == 9 && components.day == 9 && components.hour == 0,
                "archive date shifted in \(NSTimeZone.default): \(date.stringValue)")
   precondition(archive.isEnabled == (mode != .off))
   precondition(date.isEnabled == (mode == .archive))
   let readyHeight = panel.frame.height
   for status in [WebProxyStatus.waiting, .applying, .failed, .ready] {
    panel.updateStatus(status)
    panel.layoutSubtreeIfNeeded()
    let visible = descendants(panel).filter { !$0.isHiddenOrHasHiddenAncestor }
    let labels = visible.compactMap { ($0 as? NSTextField)?.stringValue }
    if let message = status.message(for: .iPodTouch2G) { precondition(labels.contains(message), labels.description) }
    else { precondition(!labels.contains(where: { $0.contains("proxy…") || $0.contains("Try again") })) }
    precondition(panel.frame.height >= readyHeight)
    precondition(panel.frame.width == 300)
    for view in visible where view is NSControl {
     let rect = view.convert(view.bounds, to: panel)
     precondition(rect.minX >= -3 && rect.maxX <= panel.bounds.width + 3, "horizontal overflow: \(view) \(rect)")
     precondition(rect.minY >= -3 && rect.maxY <= panel.bounds.height + 3, "vertical overflow: \(view) \(rect), height \(panel.bounds.height)")
    }
   }
   if enabled.state == .off { enabled.performClick(nil) }
   precondition(archive.isEnabled)
   if archive.state == .off { archive.performClick(nil) }
   precondition(date.isEnabled && panel.configuration.mode == .archive)
   precondition(panel.configuration.archiveDate == "20090909")
   enabled.performClick(nil)
   precondition(panel.configuration.mode == .off && !date.isEnabled)
   // Disabling the proxy retains the selected archive date for next time.
   enabled.performClick(nil)
   precondition(panel.configuration.mode == .archive)
   let localCalendar = date.calendar!
   date.dateValue = localCalendar.date(from: DateComponents(year: 2009, month: 11, day: 1))!
   precondition(panel.configuration.archiveDate == "20091101")
   date.dateValue = localCalendar.date(byAdding: .day, value: 1, to: date.dateValue)!
   precondition(panel.configuration.archiveDate == "20091102", "day stepping across daylight saving time")
  }
  print("PASS: proxy choices, local archive dates, day stepping, changing status and native alert layout (\(NSTimeZone.default.identifier))")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-proxy-panel-') as directory:
 work = Path(directory)
 (work/'check.swift').write_text(fixture)
 subprocess.run(['swiftc', DEVICE_PROFILE, '-default-isolation', 'MainActor', '-module-cache-path', str(work/'modules'),
   str(root/'LightTouchMac/Device/WebProxyConfiguration.swift'), str(root/'LightTouchMac/UI/ProxySettingsView.swift'),
   str(work/'check.swift'), '-o', str(work/'check')], check=True)
 for zone in ['America/New_York', 'America/Los_Angeles', 'Asia/Tokyo']:
  subprocess.run([str(work/'check'), zone], check=True, timeout=15)
