#!/usr/bin/env python3
"""Production capture key routing and recording sheet callbacks: Features/CaptureController.swift compiled whole
against tests/fixtures/capture-controller.swift, with its AppKit sheets and the key monitor swapped for recorders
(NSAlert(), NSSavePanel(), NSEvent's local monitor). The window controller's own Copy responder
(MainWindowController.copy) is not part of this file."""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'LightTouchMac'


def patched(text, old, new):
    assert old in text, old
    return text.replace(old, new)


capture = (app / 'Features/CaptureController.swift').read_text()
capture = patched(capture, 'NSEvent.addLocalMonitorForEvents', 'EventMonitor.install')
capture = patched(capture, 'NSEvent.removeMonitor', 'EventMonitor.removeMonitor')
capture = patched(capture, 'NSAlert()', 'TestAlert()')
capture = patched(capture, 'NSSavePanel()', 'TestSavePanel()')

code = r'''import Cocoa
import UniformTypeIdentifiers

// Exercise AppKit's key routing without taking focus from the running app.
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
@MainActor final class EventMonitor {
 let handler: (NSEvent) -> NSEvent?
 init(_ handler: @escaping (NSEvent) -> NSEvent?) { self.handler = handler }
 static var last: EventMonitor?
 static func install(matching: NSEvent.EventTypeMask,
                     handler: @escaping (NSEvent) -> NSEvent?) -> Any {
  precondition(matching == [.keyDown, .keyUp]); last = EventMonitor(handler); return last!
 }
 nonisolated static func removeMonitor(_ monitor: Any) {}
}
@MainActor final class TestAlert {
 static var last: TestAlert?
 var messageText = "", informativeText = "", buttons: [NSButton] = []
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
 func beginSheetModal(for window: NSWindow, completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
  Self.last = self; completionHandler(Self.response)
 }
}
/// Records which capture the Space bar asked for instead of taking it.
@MainActor final class RecordingController: CaptureController {
 var captures: [String] = []
 override func copyScreen() { captures.append("copy") }
 override func saveScreenshot() { captures.append("save") }
 override func saveScreenshotAs() { captures.append("saveAs") }
 override func toggleRecording() { captures.append("record") }
 func route(_ event: NSEvent) -> NSEvent? { EventMonitor.last!.handler(event) }
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
  let device = DeviceSession()
  let controller = RecordingController(preferences: preferences)
  controller.window = window
  controller.session = { device }
  let screen = device.workspace.deviceVC.screen
  window.contentView!.addSubview(screen)
  screen.frame = window.contentView!.bounds
  app.commandWindow = window
  window.makeFirstResponder(screen)
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
  window.makeFirstResponder(screen)
  precondition(captured(key()))
  // The key-up can be delivered to another app after Cmd-Tab. A later,
  // unrelated modified key press must not inherit stale ownership.
  precondition(!captured(key(flags: .shift)))
  precondition(!captured(key(.keyUp, flags: .shift)))
  screen.isShowingLiveText = true
  precondition(!captured(key()))
  screen.isShowingLiveText = false
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
  // Discard confirmation: Discard (destructive, not the default) or Cancel, which keeps
  // recording. A stale confirmation cannot stop a replacement recording.
  controller.discardRecording()
  let discard = TestAlert.last!
  precondition(discard.buttons.map(\.title) == ["Discard", "Cancel"] && !discard.informativeText.isEmpty)
  precondition(discard.buttons[0].keyEquivalent != "\r" && discard.buttons[1].keyEquivalent == "\u{1b}", "Return must not discard")
  discard.reply?(.alertSecondButtonReturn)
  precondition(recording.stops.isEmpty)
  controller.discardRecording()
  TestAlert.last!.reply?(.alertFirstButtonReturn)
  precondition(recording.stops == [true])
  recording.reset()
  controller.discardRecording()
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
  print("PASS: Space ownership, repeats, focus, modifiers and sheets; reminder identity; discard and save fallback callbacks")
 }
}
'''

with tempfile.TemporaryDirectory(prefix='ltm-capture-shortcuts-') as directory:
    work = Path(directory)
    (work / 'check.swift').write_text(code)
    (work / 'CaptureController.swift').write_text(capture)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-default-isolation', 'MainActor',
                    '-module-cache-path', str(work / 'modules'),
                    *[str(app / f) for f in ['Device/DeviceProfile.swift', 'Features/CapturePreferences.swift', 'Features/CaptureSound.swift']],
                    str(work / 'CaptureController.swift'), str(root / 'tests/fixtures/capture-controller.swift'),
                    str(work / 'check.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True, timeout=25)
