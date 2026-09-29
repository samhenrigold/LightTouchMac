#!/usr/bin/env python3
"""Production app-launch flow wakes the screen without bypassing guest locks.

The guest side (the agent's launch, and lockstatus telling a locked refusal apart) is
tests/offline/check-agent-transport.py; this checks the controller and the inspector around it."""
from pathlib import Path
import subprocess, tempfile
DEVICE_PROFILE = str(Path(__file__).resolve().parents[2] / 'LightTouchMac/Device/DeviceProfile.swift')
root = Path(__file__).resolve().parents[2]
def method(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n    }', start) + 6]
tools = (root / 'LightTouchMac/Guest/GuestServices.swift').read_text()
controller = (root / 'LightTouchMac/Device/EmulatorController.swift').read_text()
inspector = (root / 'LightTouchMac/UI/AppsInspectorViewController.swift').read_text()
error = tools[tools.index('enum AppLaunchError:'):tools.index("/// The app's guest operations")]
code = r'''import Cocoa
''' + error + r'''
enum DeviceToolsError: LocalizedError { case failed(String); var errorDescription: String? { switch self { case .failed(let text): text } } }
func logEvent(_ message: String) { }
@MainActor var displaySleeping = false
@MainActor final class FakeGuest {
 var failure: Error?
 var commands: [String] = []
 func launch(_ bundleID: String) async throws {
  commands.append(bundleID)
  if let failure { throw failure }
 }
}
struct Agent { let isAlive = true }
@MainActor final class EmulatorController {
 let profile = DeviceProfile.iPodTouch2G
 var acceptsInput = true, isSleeping = false
 var wakes = 0
 let deviceTools = FakeGuest()
 var guest: FakeGuest { deviceTools }        // GuestServices
 let guestAgent = Agent()
 var services: Void { get throws {} }          // EmulatorController.services: USB is up
 func pressHome() { wakes += 1; displaySleeping = false }
 var status: (displaySleeping: Bool, Void)? { (displaySleeping, ()) }  // the helper's status block
''' + method(controller, '    func launchApp(_ bundleID: String) async throws {') + r'''
}
struct InstalledApp { let id: String; let name: String }
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
  // Typed launch errors reach the caller unchanged; a cancellation stays one.
  device.isSleeping = false
  device.deviceTools.failure = AppLaunchError.locked
  do { try await device.launchApp("com.example.game"); preconditionFailure("locked launch accepted") }
  catch AppLaunchError.locked { }
  precondition(device.wakes == 1)
  device.deviceTools.failure = CancellationError()
  do { try await device.launchApp("com.example.game"); preconditionFailure("cancelled launch accepted") }
  catch is CancellationError { }
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
