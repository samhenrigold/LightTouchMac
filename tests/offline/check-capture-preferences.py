#!/usr/bin/env python3
"""Native capture preferences, the Settings window (General, Capture, Storage) and its Capture and General
panes' actions, and notification payloads. --out DIR keeps the panes' renders (settings-*.png); nothing is
put on screen."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
import argparse, subprocess, tempfile
ap = argparse.ArgumentParser()
ap.add_argument('--out')
args = ap.parse_args()
DEVICE_PROFILE = str(Path(__file__).resolve().parents[2] / 'LightTouchMac/Device/DeviceProfile.swift')
root = Path(__file__).resolve().parents[2]
fixture = r'''import Cocoa
import UserNotifications
func descendants(_ view: NSView) -> [NSView] {
 var children = view.subviews
 if let stack = view as? NSStackView {
  for child in stack.arrangedSubviews where !children.contains(where: { $0 === child }) { children.append(child) }
 }
 return [view] + children.flatMap(descendants)
}
/// Storage's stand-in: its own measuring needs the whole app; any pane with a size will do.
final class StubPane: NSView, SettingsPane {
 var onResize: (() -> Void)?
 override var fittingSize: NSSize { NSSize(width: 520, height: 300) }
}
func render(_ view: NSView, _ name: String) throws {
 guard CommandLine.arguments.count > 1 else { return }
 let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
 view.cacheDisplay(in: view.bounds, to: rep)
 try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name))
}
@main struct Check {
 @MainActor static func main() async throws {
  _ = NSApplication.shared
  let domain = "ltm-capture-preferences-test-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: domain)!
  defer { defaults.removePersistentDomain(forName: domain) }
  let preferences = CapturePreferences(defaults: defaults)
  precondition(preferences.saveLocation == CapturePreferences.desktopDirectory)
  precondition(preferences.openFinderAfterCapture && preferences.soundEffectsEnabled)
  precondition(!preferences.copyOnCapture && !preferences.notifyOnRecordingRecovery)
  precondition(preferences.reminderAfterDuration == 0 && preferences.spaceBarAction == .none)
  precondition(defaults.persistentDomain(forName: domain)?.isEmpty ?? true)
  let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Capture options " + UUID().uuidString)
  try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: base) }
  let oldFolder = base.appendingPathComponent("Existing save location")
  defaults.set(oldFolder.path, forKey: "captureFolder")
  precondition(preferences.saveLocation.path == oldFolder.standardizedFileURL.path)
  precondition(preferences.saveLocations.contains { $0.path == oldFolder.standardizedFileURL.path })
  for name in ["One", "Two", "Three", "Four", "Two"] { preferences.saveLocation = base.appendingPathComponent(name) }
  precondition(defaults.stringArray(forKey: "captureRecentFolders")!.count == 3)
  precondition(preferences.saveLocations.dropFirst().map(\.lastPathComponent) == ["Two", "Four", "Three"])
  preferences.saveLocation = CapturePreferences.desktopDirectory
  precondition(preferences.saveLocations.count == 4)
  defaults.set("/no-longer-installed/Image.app", forKey: "openInApplicationPath")
  precondition(preferences.openInApplicationURL == CapturePreferences.previewApplicationURL)
  let app = base.appendingPathComponent("Image Editor.app")
  try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
  let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "test.capture.editor", "CFBundleName": "Image Editor"]
  try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
  preferences.openInApplicationURL = app
  precondition(preferences.openInApplicationURL?.path == app.path)
  precondition(preferences.openInApplicationName == "Image Editor")
  preferences.openInApplicationURL = base
  precondition(preferences.openInApplicationURL?.path == app.path, "invalid app must not replace an explicit choice")
  defaults.set(999, forKey: "spaceBarAction")
  defaults.set(-60, forKey: "reminderAfterDuration")
  precondition(preferences.spaceBarAction == .none && preferences.reminderAfterDuration == 0)
  var prompts = 0
  var permission = false
  let view = CaptureOptionsView(preferences: preferences, profile: .iPodTouch2G, authorizeNotifications: { prompts += 1; return permission })
  // One Settings window: a toolbar tab per pane, titled after the pane, sized to it.
  let general = GeneralSettingsView()
  let settings = SettingsWindowController(general: general, capture: view, storage: StubPane())
  let window = settings.window!
  precondition(window.toolbar?.items.map(\.label) == ["General", "Capture", "Storage"], "\(window.toolbar?.items.map(\.label) ?? [])")
  precondition(!window.isVisible && !window.isRestorable)
  func fits(_ pane: NSView) -> Bool { window.contentRect(forFrameRect: window.frame).size == pane.fittingSize }
  precondition(settings.pane == .general && fits(general), "General: \(window.frame) vs \(general.fittingSize)")
  try render(general, "settings-general.png")
  settings.pane = .capture
  precondition(window.title == "Capture" && fits(view), "Capture: \(window.title) \(window.frame) vs \(view.fittingSize)")
  precondition(view.fittingSize == view.frame.size && view.fittingSize.width == 430,
               "the Capture pane must size correctly as the Settings window's content")
  settings.pane = .storage
  precondition(window.title == "Storage" && fits(settings.view(for: .storage)))
  settings.pane = .capture
  // General: internet access is Connect, Use Offline, or no saved answer (the device asks).
  defer { UserDefaults.standard.removeObject(forKey: NetworkAccessPreference.key) }
  let internet = descendants(general).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Internet access" }!
  for (tag, saved) in [(0, false as Bool?), (1, true), (-1, nil)] {
   internet.selectItem(withTag: tag)
   internet.sendAction(internet.action!, to: internet.target)
   precondition(UserDefaults.standard.object(forKey: NetworkAccessPreference.key) as? Bool == saved, "internet tag \(tag)")
  }
  UserDefaults.standard.set(false, forKey: NetworkAccessPreference.key)
  general.reload()
  precondition(internet.selectedTag() == 0)
  precondition(prompts == 0, "opening options must not request notification access")
  func button(_ title: String) -> NSButton { descendants(view).compactMap { $0 as? NSButton }.first { $0.title == title }! }
  button("Show captures in Finder").performClick(nil)
  button("Copy screenshots to the clipboard").performClick(nil)
  button("Play sound effects").performClick(nil)
  precondition(!preferences.openFinderAfterCapture && preferences.copyOnCapture && !preferences.soundEffectsEnabled)
  let popups = descendants(view).compactMap { $0 as? NSPopUpButton }
  let space = popups.first { $0.accessibilityLabel() == "Space bar captures" }!
  space.selectItem(withTag: CaptureSpaceBarAction.saveScreenshot.rawValue)
  space.sendAction(space.action!, to: space.target)
  precondition(preferences.spaceBarAction == .saveScreenshot)
  let apps = popups.first { $0.accessibilityLabel() == "Open screenshots in" }!
  precondition((apps.selectedItem!.representedObject as? URL)?.path == app.path, "chosen app retained even outside discovery")
  let recovery = button("Notify when a recording is recovered")
  recovery.performClick(nil)
  while !recovery.isEnabled { try await Task.sleep(for: .milliseconds(10)) }
  precondition(prompts == 1 && !preferences.notifyOnRecordingRecovery)
  permission = true
  recovery.performClick(nil)
  while !recovery.isEnabled { try await Task.sleep(for: .milliseconds(10)) }
  precondition(prompts == 2 && preferences.notifyOnRecordingRecovery)
  let reminder = popups.first { $0.accessibilityLabel() == "Recording reminder" }!
  reminder.selectItem(withTag: 300)
  reminder.sendAction(reminder.action!, to: reminder.target)
  while !reminder.isEnabled { try await Task.sleep(for: .milliseconds(10)) }
  precondition(preferences.reminderAfterDuration == 300)
  reminder.selectItem(withTag: 0)
  reminder.sendAction(reminder.action!, to: reminder.target)
  precondition(preferences.reminderAfterDuration == 0 && prompts == 3)
  view.layoutSubtreeIfNeeded()
  for control in descendants(view) where control is NSControl && !control.isHiddenOrHasHiddenAncestor {
   let rect = control.convert(control.bounds, to: view)
   precondition(rect.minX >= -3 && rect.maxX <= view.bounds.width + 3, "horizontal overflow: \(control), \(rect)")
   precondition(rect.minY >= -3 && rect.maxY <= view.bounds.height + 3, "vertical overflow: \(control), \(rect)")
  }
  try render(view, "settings-capture.png")
  let restored = CapturePreferences(defaults: defaults)
  precondition(restored.copyOnCapture && !restored.openFinderAfterCapture && !restored.soundEffectsEnabled)
  precondition(restored.spaceBarAction == .saveScreenshot)
  let id = UUID()
  let notification = CaptureNotifications.reminderContent(recordingID: id, profile: .iPodTouch2G)
  precondition(notification.userInfo["recordingID"] as? String == id.uuidString)
  let content = CaptureNotifications.recoveryContent(filename: "Recovered.mov", bookmark: Data([1,2,3]))
  precondition(content.body == "Recovered.mov" && content.userInfo["recordingBookmark"] as? Data == Data([1,2,3]))
  try FileManager.default.removeItem(at: app)
  precondition(preferences.openInApplicationURL == CapturePreferences.previewApplicationURL,
               "a deleted app must not remain selected through Bundle's metadata cache")
  print("PASS: capture defaults/migration, recent folders, app fallback, Settings tabs, titles and sizing, General's internet choice, Capture pane actions/layout, notification opt-in and payload identity")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-capture-preferences-') as directory:
 work = Path(directory)
 (work/'check.swift').write_text(fixture)
 subprocess.run(['swiftc', *host_runtime.swift_flags(Path(__file__).resolve().parents[2]), DEVICE_PROFILE, '-swift-version', '6', '-default-isolation', 'MainActor', '-module-cache-path', str(work/'modules'),
   *[str(root/'LightTouchMac'/name) for name in ['Features/CapturePreferences.swift', 'UI/CaptureOptionsView.swift', 'Features/CaptureNotifications.swift',
                                                  'UI/SettingsWindowController.swift', 'App/WindowRestorationPolicy.swift', 'App/NetworkAccessPreference.swift']],
   str(work/'check.swift'), '-o', str(work/'check')], check=True)
 subprocess.run([str(work/'check'), *([args.out] if args.out else [])], check=True, timeout=25)
