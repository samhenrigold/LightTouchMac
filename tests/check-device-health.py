#!/usr/bin/env python3
"""Real connection probes preserve errors and abandon queued reads safely."""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[1]
services = (root/'LightTouchMac/DeviceServices.swift').read_text()
errors = services[services.index('nonisolated enum DeviceError:'):services.index('// MARK: - Timeouts')]
deadlines = services[services.index('func withDeadline<T: Sendable>'):services.index('// MARK: - Install watchdog box')]
gate = services[services.index('actor DeviceGate'):services.index('// MARK: - Errors')]
controller = (root/'LightTouchMac/EmulatorController.swift').read_text()
probe = controller[controller.index('    func deviceReady()'):controller.index('    func installedApps()')]
inspector = (root/'LightTouchMac/AppsInspectorViewController.swift').read_text()
suppression = next(line for line in inspector.splitlines() if 'private var readsSuppressed:' in line).replace('private ', '')

source = r'''
import Foundation
nonisolated func logEvent(_ message: String) {}
nonisolated enum Timeouts { static let serviceProbe = 0.015 }
nonisolated enum IMobileDevice {
 static let lock = NSLock()
 nonisolated(unsafe) static var failure: DeviceError?
 static func setFailure(_ error: DeviceError?) { lock.withLock { failure = error } }
 static func checkAttachment(socket: String) throws {
  try lock.withLock { if let failure { throw failure } }
 }
}
@MainActor final class Controller {
 struct Session { let clientSocket = "fixture" }
 struct Mux { var session: Session? = Session() }
 var usbmux = Mux()
 var usbConnected = true, isPoweredOff = false, shuttingDown = false
 var hasFileTransfer = false, isReconnecting = false, preparingDevice = false
''' + probe + r'''
}
@MainActor final class Inspector {
 let emulator = Controller()
 var installing = false
 var uninstalling: Set<String> = []
''' + suppression + r'''
}
@main struct Check {
 @MainActor static func main() async throws {
  let c = Controller()
  let ready = await c.deviceReady(); precondition(ready)
  IMobileDevice.setFailure(.unavailable)
  do { try await c.checkDeviceConnection(); preconditionFailure() }
  catch DeviceError.unavailable {} catch { throw error }
  IMobileDevice.setFailure(.notAttached)
  do { try await c.checkDeviceConnection(); preconditionFailure() }
  catch DeviceError.notAttached {} catch { throw error }
  IMobileDevice.setFailure(nil)

  // A probe waiting behind a long write must time out, leave the gate queue,
  // and retain a USB-specific cause instead of resetting app services.
  let held = ResumeOnce<Void>(), entered = ResumeOnce<Void>()
  let owner = Task {
   try await DeviceGate.shared.serialized {
    entered.resume(.success(()))
    try await withCheckedThrowingContinuation { held.attach($0) }
   }
  }
  try await withCheckedThrowingContinuation { entered.attach($0) }
  do { try await c.checkDeviceConnection(); preconditionFailure() }
  catch DeviceError.timedOut(let operation) { precondition(operation == "USB connection") }
  catch { throw error }
  precondition(AbandonedWork.count == 0, "waiting is not a blocked C request")
  held.resume(.success(())); try await owner.value
  try await c.checkDeviceConnection()

  let cancelled = Task { try await c.checkDeviceConnection() }
  cancelled.cancel()
  do { try await cancelled.value; preconditionFailure() }
  catch is CancellationError {} catch { throw error }
  c.shuttingDown = true
  let ending = await c.deviceReady(); precondition(!ending)

  let inspector = Inspector()
  inspector.uninstalling = ["queued-behind-paused-install"]
  precondition(!inspector.readsSuppressed, "queued removal must not deadlock recovery")
  inspector.installing = true; precondition(inspector.readsSuppressed)
  inspector.installing = false; inspector.emulator.hasFileTransfer = true
  precondition(inspector.readsSuppressed)
  inspector.emulator.hasFileTransfer = false; inspector.emulator.isReconnecting = true
  precondition(inspector.readsSuppressed)
  inspector.emulator.isReconnecting = false; inspector.emulator.preparingDevice = true
  precondition(inspector.readsSuppressed, "boot preparation owns device services too")
  print("PASS: typed health failures, bounded queued probes, cancellation, shutdown, and health reads during paused removals")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-health-') as d:
    p = Path(d)/'check.swift'; p.write_text(errors + deadlines + gate + source)
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', '-module-cache-path', d+'/modules', str(p), '-o', d+'/check'], check=True)
    subprocess.run([d+'/check'], check=True, timeout=10)
