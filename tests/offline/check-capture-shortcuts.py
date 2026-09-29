#!/usr/bin/env python3
"""Production capture key routing, native Copy, and recording sheet callbacks."""
from pathlib import Path
import subprocess, tempfile
DEVICE_PROFILE = str(Path(__file__).resolve().parents[2] / 'LightTouchMac/Device/DeviceProfile.swift')

root = Path(__file__).resolve().parents[2]
source = (root / 'LightTouchMac/UI/MainWindowController.swift').read_text()


def method(signature):
    start = source.index(signature)
    return source[start:source.index('\n    }', start) + 6].replace('private func', 'func')


keyboard = method('    private func installCaptureKeyboardShortcuts()')
keyboard = keyboard.replace('NSEvent.addLocalMonitorForEvents', 'EventMonitor.install')
discard = method('    @objc func discardRecording(').replace('NSAlert()', 'TestAlert()')
save_start = source.index('        recording.chooseSaveDestination = ')
save_end = source.index('\n        recording.onCompleted = ', save_start)
save_hook = source[save_start:save_end].replace('NSSavePanel()', 'TestSavePanel()')

code = r'''import Cocoa
import UniformTypeIdentifiers

// Exercise AppKit's responder chain without taking focus from the running app.
@MainActor final class TestApplication: NSApplication {
 var commandWindow: NSWindow?
 var modal: NSWindow?
 var testActive = false
 override var keyWindow: NSWindow? { commandWindow }
 override var mainWindow: NSWindow? { commandWindow }
 override var modalWindow: NSWindow? { modal }
 override var isActive: Bool { testActive }
}
@MainActor final class TestWindow: NSWindow {
 var key = true
 var testSheet: NSWindow?
 override var isKeyWindow: Bool { key }
 override var attachedSheet: NSWindow? { testSheet }
}
@MainActor final class TestScreen: NSView {
 var isShowingLiveText = false
 override var acceptsFirstResponder: Bool { true }
}
@MainActor final class DeviceController { let screen = TestScreen() }
@MainActor final class EventMonitor {
 let handler: (NSEvent) -> NSEvent?
 init(_ handler: @escaping (NSEvent) -> NSEvent?) { self.handler = handler }
 static func install(matching: NSEvent.EventTypeMask,
                     handler: @escaping (NSEvent) -> NSEvent?) -> Any {
  precondition(matching == [.keyDown, .keyUp]); return EventMonitor(handler)
 }
}
@MainActor final class TestRecording {
 var id = UUID(), canStop = true
 var stops: [Bool] = []
 var chooseSaveDestination: ((Error) async -> URL?)?
 func stop(discard: Bool = false) { stops.append(discard); canStop = false }
 func reset() { id = UUID(); canStop = true; stops = [] }
}
@MainActor final class CaptureNotifications {
 static let shared = CaptureNotifications()
 enum RecordingAction { case stopAndSave, stopAndDelete }
 var onRecordingAction: ((UUID, RecordingAction) -> Void)?
 var reminders: [(TimeInterval, UUID)] = [], cancellations = 0
 func scheduleReminder(after delay: TimeInterval, recordingID: UUID, profile: DeviceProfile) async {
  reminders.append((delay, recordingID))
 }
 func cancelReminder() { cancellations += 1 }
}
@MainActor final class TestAlert {
 static var last: TestAlert?
 var messageText = "", buttons: [NSButton] = []
 var reply: ((NSApplication.ModalResponse) -> Void)?
 func addButton(withTitle title: String) { buttons.append(NSButton(title: title, target: nil, action: nil)) }
 func beginSheetModal(for window: NSWindow, completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
  Self.last = self; reply = completionHandler
 }
}
@MainActor final class TestSavePanel {
 static var last: TestSavePanel?
 static var response = NSApplication.ModalResponse.cancel
 static var selected: URL?
 var allowedContentTypes: [UTType] = [], directoryURL: URL?, nameFieldStringValue = ""
 var url: URL? { Self.selected }
 func beginSheetModal(for window: NSWindow) async -> NSApplication.ModalResponse {
  Self.last = self; return Self.response
 }
}
@MainActor final class EmulatorController { let profile = DeviceProfile.iPodTouch2G }
@MainActor final class CaptureController: NSWindowController {
 let emulator = EmulatorController()
 let deviceVC: DeviceController? = DeviceController(), recording = TestRecording()
 let currentProfile = DeviceProfile.iPodTouch2G
 let capturePreferences: CapturePreferences
 var captureKeyMonitor: Any?, consumedCaptureSpace = false
 var captures: [String] = []
 var captureFolder: URL { capturePreferences.saveLocation }
 func captureName(_ name: String) -> String { name + " test" }
 init(window: NSWindow, preferences: CapturePreferences) {
  capturePreferences = preferences
  super.init(window: window)
  window.contentView!.addSubview(deviceVC!.screen)
  deviceVC!.screen.frame = window.contentView!.bounds
  installCaptureKeyboardShortcuts()
  installCaptureNotifications()
  installSaveFallback()
 }
 required init?(coder: NSCoder) { fatalError() }
 @objc func copyScreen(_ sender: Any?) { captures.append("copy") }
 @objc func saveScreenshot(_ sender: Any?) { captures.append("save") }
 @objc func saveScreenshotAs(_ sender: Any?) { captures.append("saveAs") }
 @objc func toggleRecording(_ sender: Any?) { captures.append("record") }
 func installSaveFallback() {
''' + save_hook + '\n }\n' + keyboard + '\n' + method('    @objc func copy(') + '\n' + discard + '\n' + method('    private func installCaptureNotifications()') + '\n' + method('    @objc private func recordingAppDidResignActive()') + '\n' + r'''
 @objc func recordingAppDidBecomeActive() { CaptureNotifications.shared.cancelReminder() }
 func route(_ event: NSEvent) -> NSEvent? { (captureKeyMonitor as! EventMonitor).handler(event) }
}
@main struct Check {
 @MainActor static func main() async throws {
  let app = TestApplication.shared as! TestApplication
  let domain = "ltm-capture-shortcuts-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: domain)!
  defer { defaults.removePersistentDomain(forName: domain) }
  let preferences = CapturePreferences(defaults: defaults)
  let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
  let controller = CaptureController(window: window, preferences: preferences)
  app.commandWindow = window
  window.makeFirstResponder(controller.deviceVC!.screen)
  func key(_ type: NSEvent.EventType = .keyDown, flags: NSEvent.ModifierFlags = [],
           repeat repeating: Bool = false, code: UInt16 = 49, in target: NSWindow? = nil) -> NSEvent {
   NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: (target ?? window).windowNumber, context: nil,
                    characters: " ", charactersIgnoringModifiers: " ", isARepeat: repeating, keyCode: code)!
  }
  func captured(_ event: NSEvent) -> Bool { controller.route(event) == nil }
  precondition(!captured(key()), "default Space must reach the iPod")
  precondition(!captured(key(.keyUp)))
  for (action, expected) in [(CaptureSpaceBarAction.copyScreenshot, "copy"), (.saveScreenshot, "save"),
                            (.saveScreenshotAs, "saveAs"), (.toggleRecording, "record")] {
   preferences.spaceBarAction = action
   let before = controller.captures.count
   let first = key()
   precondition(captured(first) && controller.captures.last == expected, "first capture: window \(String(describing: first.window)) number \(window.windowNumber), responder \(String(describing: window.firstResponder)), key \(window.isKeyWindow), prefs \(preferences.spaceBarAction)")
   precondition(captured(key(repeat: true)))
   precondition(controller.captures.count == before + 1, "holding Space must not toggle recording repeatedly")
   precondition(captured(key(.keyUp)))
   precondition(!captured(key(.keyUp)), "release is consumed only once")
  }
  for flags: NSEvent.ModifierFlags in [.command, .control, .option, .shift, [.option, .shift]] {
   precondition(!captured(key(flags: flags)))
   precondition(!captured(key(.keyUp, flags: flags)))
  }
  precondition(!captured(key(code: 0)))
  precondition(captured(key()))
  precondition(captured(key(flags: .option, repeat: true)), "owned repeats stay consumed after modifier changes")
  let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
  window.contentView!.addSubview(editor)
  window.makeFirstResponder(editor)
  precondition(captured(key(repeat: true)), "owned repeats stay consumed after focus changes")
  precondition(captured(key(.keyUp)))
  precondition(!captured(key()), "typing spaces must not capture")
  precondition(!captured(key(.keyUp)))
  window.makeFirstResponder(controller.deviceVC!.screen)
  precondition(captured(key()))
  // The key-up can be delivered to another app after Cmd-Tab. A later,
  // unrelated modified key press must not inherit stale ownership.
  precondition(!captured(key(flags: .shift)))
  precondition(!captured(key(.keyUp, flags: .shift)))
  controller.deviceVC!.screen.isShowingLiveText = true
  precondition(!captured(key()))
  controller.deviceVC!.screen.isShowingLiveText = false
  window.key = false
  precondition(!captured(key()))
  window.key = true
  let other = TestWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
  precondition(!captured(key(in: other)))
  window.testSheet = other
  precondition(!captured(key()))
  window.testSheet = nil
  app.modal = other
  precondition(!captured(key()))
  app.modal = nil
  // A native Copy selector resolves to the focused editor before the window
  // controller, and resolves to screenshot Copy only on the device itself.
  let copy = #selector(NSText.copy(_:))
  precondition(NSApp.target(forAction: copy) as? CaptureController === controller)
  let beforeCopy = controller.captures.count
  precondition(NSApp.sendAction(copy, to: nil, from: nil))
  precondition(controller.captures.count == beforeCopy + 1 && controller.captures.last == "copy")
  window.makeFirstResponder(editor)
  editor.string = "Selected text"
  editor.setSelectedRange(NSRange(location: 0, length: 8))
  precondition(NSApp.target(forAction: copy) as? NSTextView === editor)
  // Avoid replacing the user's pasteboard: native target resolution is enough.
  controller.copy(nil)
  precondition(controller.captures.count == beforeCopy + 1)
  window.makeFirstResponder(controller.deviceVC!.screen)
  controller.deviceVC!.screen.isShowingLiveText = true
  controller.copy(nil)
  precondition(controller.captures.count == beforeCopy + 1)
  controller.deviceVC!.screen.isShowingLiveText = false
  // Notification buttons are tied to the original take, never a later take.
  let notifications = CaptureNotifications.shared
  let recording = controller.recording
  notifications.onRecordingAction?(UUID(), .stopAndSave)
  precondition(recording.stops.isEmpty)
  notifications.onRecordingAction?(recording.id, .stopAndSave)
  precondition(recording.stops == [false])
  notifications.onRecordingAction?(recording.id, .stopAndDelete)
  precondition(recording.stops == [false])
  recording.reset()
  notifications.onRecordingAction?(recording.id, .stopAndDelete)
  precondition(recording.stops == [true])
  recording.reset()
  controller.recordingAppDidResignActive()
  recording.reset()
  await Task.yield()
  precondition(notifications.reminders.isEmpty, "a delayed reminder cannot follow a replaced take")
  app.testActive = true
  controller.recordingAppDidResignActive()
  await Task.yield()
  precondition(notifications.reminders.isEmpty, "returning to the app cancels pending reminder scheduling")
  app.testActive = false
  preferences.reminderAfterDuration = 300
  controller.recordingAppDidResignActive()
  for _ in 0..<20 where notifications.reminders.isEmpty { await Task.yield() }
  precondition(notifications.reminders.count == 1 && notifications.reminders[0].0 == 300)
  precondition(notifications.reminders[0].1 == recording.id)
  // Discard confirmation can keep recording, save, or discard. A stale
  // confirmation cannot stop a replacement recording.
  controller.discardRecording(nil)
  TestAlert.last!.reply?(.alertThirdButtonReturn)
  precondition(recording.stops.isEmpty)
  controller.discardRecording(nil)
  TestAlert.last!.reply?(.alertSecondButtonReturn)
  precondition(recording.stops == [false])
  recording.reset()
  controller.discardRecording(nil)
  TestAlert.last!.reply?(.alertFirstButtonReturn)
  precondition(recording.stops == [true])
  recording.reset()
  controller.discardRecording(nil)
  let oldReply = TestAlert.last!.reply
  recording.reset()
  oldReply?(.alertFirstButtonReturn)
  precondition(recording.stops.isEmpty)
  // Failed automatic saves use a per-file MOV picker and leave defaults alone.
  let preferred = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("preferred")
  let selected = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chosen.mov")
  preferences.saveLocation = preferred
  TestSavePanel.response = .OK
  TestSavePanel.selected = selected
  let saved = await recording.chooseSaveDestination?(CocoaError(.fileWriteNoPermission))
  precondition(saved == selected && preferences.saveLocation.path == preferred.path)
  precondition(TestSavePanel.last!.allowedContentTypes == [.quickTimeMovie])
  precondition(TestSavePanel.last!.directoryURL?.path == preferred.path)
  TestSavePanel.response = .cancel
  let cancelled = await recording.chooseSaveDestination?(CocoaError(.fileWriteNoPermission))
  precondition(cancelled == nil)
  controller.window = nil
  let closed = await recording.chooseSaveDestination?(CocoaError(.fileWriteNoPermission))
  precondition(closed == nil)
  print("PASS: native Copy routing; Space ownership, repeats, focus, modifiers and sheets; reminder identity; discard and save fallback callbacks")
 }
}
'''

with tempfile.TemporaryDirectory(prefix='ltm-capture-shortcuts-') as directory:
    work = Path(directory)
    (work / 'check.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', DEVICE_PROFILE, '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
                    '-module-cache-path', str(work / 'modules'), str(root / 'LightTouchMac/Features/CapturePreferences.swift'),
                    str(work / 'check.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True, timeout=25)
