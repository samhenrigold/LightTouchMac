#!/usr/bin/env python3
"""Production app-launch flow wakes the screen without bypassing guest locks."""
from pathlib import Path
import subprocess, tempfile
DEVICE_PROFILE = str(Path(__file__).resolve().parents[1] / 'LightTouchMac/DeviceProfile.swift')
root = Path(__file__).resolve().parents[1]
def method(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n    }', start) + 6]
tools = (root / 'LightTouchMac/DeviceTools.swift').read_text()
controller = (root / 'LightTouchMac/EmulatorController.swift').read_text()
inspector = (root / 'LightTouchMac/AppsInspectorViewController.swift').read_text()
error = tools[tools.index('enum AppLaunchError:'):tools.index('enum DeviceToolsError:')]
code = r'''import Cocoa
''' + error + r'''
enum DeviceToolsError: LocalizedError { case failed(String); var errorDescription: String? { switch self { case .failed(let text): text } } }
func logEvent(_ message: String) { }
@MainActor var displaySleeping = false
@MainActor func qemu_ios_ui_display_sleeping() -> Bool { displaySleeping }
@MainActor final class DeviceTools {
 var bakedGuestTools = true
 var guestShell = true
 var failure: Error?
 var foreground: String?
 var commands: [String] = []
 var lockChecks = 0
 @discardableResult func guestRun(_ command: String) async throws -> Data {
  commands.append(command)
  if let failure { throw failure }
  return Data()
 }
 func foregroundAppName(stageHelper: Bool) async throws -> String? {
  precondition(!stageHelper); lockChecks += 1; return foreground
 }
''' + method(tools, '    func launchApp(_ bundleID: String) async throws {') + r'''
}
@MainActor final class EmulatorController {
 var acceptsInput = true, isSleeping = false
 var wakes = 0
 let deviceTools = DeviceTools()
 func tools() throws -> DeviceTools { deviceTools }
 func pressHome() { wakes += 1; displaySleeping = false }
''' + method(controller, '    func launchApp(_ bundleID: String) async throws {') + r'''
}
struct InstalledApp { let id: String; let name: String }
extension Notification.Name { static let ltmAppLaunched = Notification.Name("Launched") }
@MainActor final class LaunchFixture: NSViewController {
 let emulator = EmulatorController()
 var busyWithDevice = false, uninstalling = Set<String>()
 func displayName(_ app: InstalledApp) -> String { app.name }
''' + method(inspector, '    private func launch(_ app: InstalledApp?) {') + r'''
}
@main struct Check {
 @MainActor static func main() async throws {
  let device = EmulatorController()
  try await device.launchApp("com.example.game")
  precondition(device.wakes == 0 && device.deviceTools.commands.count == 1)
  device.isSleeping = true; displaySleeping = true
  try await device.launchApp("com.example.game")
  precondition(device.wakes == 1 && !displaySleeping && device.deviceTools.commands.count == 2)
  // The launch API still refuses a locked device. We ask its read-only lock
  // helper for the reason; the app never issues an unlock request.
  device.isSleeping = false
  device.deviceTools.failure = DeviceToolsError.failed("sblaunch: com.example.game -> 3")
  device.deviceTools.foreground = "Lock Screen"
  do { try await device.launchApp("com.example.game"); preconditionFailure("locked launch accepted") }
  catch AppLaunchError.locked { }
  precondition(device.deviceTools.lockChecks == 1 && device.wakes == 1)
  device.deviceTools.foreground = "Home Screen"
  do { try await device.launchApp("com.example.game"); preconditionFailure("failed launch accepted") }
  catch AppLaunchError.failed { }
  precondition(device.deviceTools.lockChecks == 2)
  device.deviceTools.failure = CancellationError()
  do { try await device.launchApp("com.example.game"); preconditionFailure("cancelled launch accepted") }
  catch is CancellationError { }
  precondition(device.deviceTools.lockChecks == 2)
  device.acceptsInput = false
  let commands = device.deviceTools.commands.count
  do { try await device.launchApp("com.example.game"); preconditionFailure("unavailable device accepted") }
  catch AppLaunchError.unavailable { }
  precondition(device.deviceTools.commands.count == commands)
  print("PASS: Open wakes a sleeping display, leaves awake screens alone, respects guest locks and presents typed launch errors")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-app-launch-') as directory:
    work = Path(directory)
    (work / 'check.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', DEVICE_PROFILE, '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
                    '-module-cache-path', str(work / 'modules'), str(work / 'check.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True, timeout=20)
