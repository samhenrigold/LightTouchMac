#!/usr/bin/env python3
"""Exercise the actual battery editor and controller validation with isolated defaults."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'LightTouchMac/EmulatorController.swift').read_text()
start=s.index('    private(set) var usbConnected = true')
end=s.index('    enum MotionPose:',start)
methods=s[start:end].replace('UserDefaults.standard','defaults').replace('private func reconnectUSB','func reconnectUSB')
source=r'''import Cocoa
enum DeviceToolsError: Error { case failed(String) }
enum AppInstaller { static var hasPendingWork = false }
final class Check {
 let suite = "battery-test-" + UUID().uuidString
 lazy var defaults = UserDefaults(suiteName: suite)!
 var acceptsInput = true, shuttingDown = false, isInstalling = false
 var deviceReachable: Bool? = true
 var onStatusChange: (() -> Void)?
 var batterySetter: ((Int32, Int32, Double) -> Bool)?
 var usbConnectionSetter: ((Bool) -> Bool)?
''' + methods + r'''
 func run() throws {
  defer { defaults.removePersistentDomain(forName: suite) }
  var updates = 0, connections: [Bool] = []
  batterySetter = { level, mode, rate in
   precondition(level == 60 && mode == 2 && rate == 0.5); updates += 1; return true
  }
  usbConnectionSetter = { connections.append($0); return true }
  precondition(batteryLevel == 96 && batteryDrain == 0 && usbConnected)
  for rate in [-1.0, 101.0, Double.nan, Double.infinity] {
   do { try configureBattery(level: 60, charging: 2, drain: rate, usbConnected: false); fatalError("invalid rate") }
   catch {}
  }
  AppInstaller.hasPendingWork = true
  precondition(!batteryControlsAvailable)
  do { try configureBattery(level: 60, charging: 2, drain: 0.5, usbConnected: false); fatalError("interrupted install") }
  catch {}
  AppInstaller.hasPendingWork = false
  precondition(updates == 0 && connections.isEmpty)
  try configureBattery(level: 60, charging: 2, drain: 0.5, usbConnected: false)
  precondition(updates == 1 && connections == [false] && !usbConnected && deviceReachable == nil)
  precondition(batteryLevel == 60 && batteryCharging == 2 && batteryDrain == 0.5)
  reconnectUSB(); reconnectUSB()
  precondition(usbConnected && connections == [false,true])
  let editor = BatterySettingsView(level: 60, charging: 2, drain: 0.5, usbConnected: false)
  precondition(editor.level == 60 && editor.charging == 2 && editor.drain == 0.5 && !editor.usbConnected)
  print("PASS: battery controls, invalid rates, transfer guard, USB reconnect and editor values")
 }
}
@main struct Main {
 static func main() throws { _ = NSApplication.shared; try Check().run() }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-battery-check-') as tmp:
    tmp=Path(tmp);(tmp/'check.swift').write_text(source)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor',
        str(root/'LightTouchMac/BatterySettingsView.swift'),str(tmp/'check.swift'),'-o',str(tmp/'check')],check=True)
    subprocess.run([str(tmp/'check')],check=True)
