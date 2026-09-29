#!/usr/bin/env python3
"""Exercise AppKit's real restoration entry points without opening the emulator."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
fixture = r'''import Cocoa
nonisolated final class UntouchedCoder: NSCoder {
 var accesses = 0
 override var allowsKeyedCoding: Bool { accesses += 1; return true }
 override func containsValue(forKey key: String) -> Bool { accesses += 1; return false }
 override func decodeObject(forKey key: String) -> Any? { accesses += 1; return nil }
 override func encode(_ objv: Any?, forKey key: String) { accesses += 1 }
}
@main struct Check {
 @MainActor static func main() {
  let domain = "ltm-window-restoration-test-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: domain)!
  defer { defaults.removePersistentDomain(forName: domain) }
  defaults.set(true, forKey: "NSQuitAlwaysKeepsWindows")
  defaults.set(false, forKey: "ApplePersistenceIgnoreState")
  defaults.set("/chosen/captures", forKey: "captureFolder")
  defaults.set("guest-state", forKey: "resumeOnLaunch")
  let persisted = defaults.persistentDomain(forName: domain)!
  defaults.setVolatileDomain(["testArgument": "retained"], forName: UserDefaults.argumentDomain)
  WindowRestorationPolicy.configureDefaults(defaults)
  precondition(!defaults.bool(forKey: "NSQuitAlwaysKeepsWindows"))
  precondition(defaults.bool(forKey: "ApplePersistenceIgnoreState"))
  precondition(defaults.string(forKey: "testArgument") == "retained")
  precondition(defaults.persistentDomain(forName: domain)! as NSDictionary == persisted as NSDictionary,
               "restoration policy must not change emulator or user preferences")
  let app = LightTouchApplication.shared
  precondition(app is LightTouchApplication)
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
  window.isRestorable = true
  WindowRestorationPolicy.configure(window)
  precondition(!window.isRestorable && window.restorationClass == nil && window.frameAutosaveName.isEmpty)
  let coder = UntouchedCoder()
  var completions = 0
  let accepted = app.restoreWindow(withIdentifier: .init("old-crashed-window"), state: coder) { restored, error in
   completions += 1
   precondition(restored == nil && error == nil)
  }
  precondition(accepted && completions == 1, "ignored restoration must finish rather than hanging launch")
  app.restoreState(with: coder)
  app.encodeRestorableState(with: coder)
  app.encodeRestorableState(with: coder, backgroundQueue: OperationQueue())
  precondition(coder.accesses == 0, "old window archives must never be inspected")
  print("PASS: no window restoration/encoding, completed restoration callbacks, per-window opt-out, process-only defaults and preserved preferences")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-window-restoration-') as directory:
 work = Path(directory)
 (work/'check.swift').write_text(fixture)
 subprocess.run(['swiftc', '-swift-version', '6', '-default-isolation', 'MainActor', '-module-cache-path', str(work/'modules'),
                 str(root/'LightTouchMac/WindowRestorationPolicy.swift'), str(work/'check.swift'), '-o', str(work/'check')], check=True)
 subprocess.run([str(work/'check')], check=True, timeout=15)
# These construction paths must opt out before displaying a window. The native
# check above validates the shared policy; guard against an accidental bypass.
for path in ['AppDelegate.swift', 'MainWindowController.swift', 'DeviceFilesWindowController.swift', 'LogWindowController.swift']:
 text = (root/'LightTouchMac'/path).read_text()
 assert 'WindowRestorationPolicy.configure(' in text, path
 assert 'setFrameAutosaveName(' not in text and 'setFrameUsingName(' not in text, path
main = (root/'LightTouchMac/main.swift').read_text()
assert main.index('WindowRestorationPolicy.configureDefaults()') < main.index('LightTouchApplication.shared')
assert main.index('LightTouchApplication.shared') < main.index('NSApplicationMain(')
project = (root/'LightTouchMac.xcodeproj/project.pbxproj').read_text()
assert project.count('INFOPLIST_KEY_NSPrincipalClass = LightTouchApplication;') == 2
