#!/usr/bin/env python3
"""Real connection probes preserve errors and abandon queued reads safely: Services/DeviceServices.swift
(checkAttachment) and Transport/DeviceExecution.swift compiled whole against a fake attachment check, plus the
inspector's read-suppression predicate (one declaration, looked up by name)."""
from pathlib import Path
import subprocess, tempfile
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import swift_subprocess

root = Path(__file__).resolve().parents[2]
app = root / 'LightTouchMac'
inspector = (app / 'UI/AppsInspectorViewController.swift').read_text()
suppression = next(line for line in inspector.splitlines() if 'private var readsSuppressed:' in line).replace('private ', '')

source = r'''
import Foundation
nonisolated func logEvent(_ message: String) {}
nonisolated enum IMobileDevice {
 static let success: Int32 = 0, isAvailable = true
 typealias NewDevice = @convention(c) (UnsafeMutablePointer<OpaquePointer?>, UnsafePointer<CChar>?) -> Int32
 typealias Free = @convention(c) (OpaquePointer?) -> Int32
 static let idevice_new: NewDevice? = nil, idevice_free: Free? = nil   // the run kernel, not exercised here
 static let lock = NSLock()
 nonisolated(unsafe) static var failure: DeviceError?
 static func setFailure(_ error: DeviceError?) { lock.withLock { failure = error } }
 static func checkAttachment() throws {
  precondition(String(cString: getenv("USBMUXD_SOCKET_ADDRESS")) == "fixture", "gate did not select the endpoint before the attachment call")
  try lock.withLock { if let failure { throw failure } }
 }
}
/// Resumes one waiter once, whichever side comes first.
nonisolated final class Signal: @unchecked Sendable {
 private let lock = NSLock()
 private var fired = false, waiter: CheckedContinuation<Void, Never>?
 func fire() {
  let w: CheckedContinuation<Void, Never>? = lock.withLock { fired = true; defer { waiter = nil }; return waiter }
  w?.resume()
 }
 func wait() async {
  await withCheckedContinuation { c in
   if lock.withLock({ if fired { return true }; waiter = c; return false }) { c.resume() }
  }
 }
}
@MainActor final class Inspector {
 final class Emulator { var hasFileTransfer = false, isReconnecting = false, preparingDevice = false }
 let emulator = Emulator()
 var installing = false
 var uninstalling: Set<String> = []
''' + suppression + r'''
}
@main struct Check {
 @MainActor static func main() async throws {
  Timeouts.serviceProbe = 0.015
  let device = DeviceServices(clientSocket: "fixture", local: true)
  try await device.checkAttachment()
  IMobileDevice.setFailure(.unavailable)
  do { try await device.checkAttachment(); preconditionFailure() }
  catch DeviceError.unavailable {} catch { throw error }
  IMobileDevice.setFailure(.notAttached)
  do { try await device.checkAttachment(); preconditionFailure() }
  catch DeviceError.notAttached {} catch { throw error }
  IMobileDevice.setFailure(nil)

  // A probe waiting behind a long write must time out, leave the gate queue,
  // and retain a USB-specific cause instead of resetting app services.
  let held = Signal(), entered = Signal()
  let owner = Task {
   try await DeviceGate.shared.serialized {
    entered.fire()
    await held.wait()
   }
  }
  await entered.wait()
  do { try await device.checkAttachment(); preconditionFailure() }
  catch DeviceError.timedOut(let operation) { precondition(operation == "USB connection") }
  catch { throw error }
  precondition(AbandonedWork.count == 0, "waiting is not a blocked C request")
  held.fire(); try await owner.value
  try await device.checkAttachment()

  let cancelled = Task { try await device.checkAttachment() }
  cancelled.cancel()
  do { try await cancelled.value; preconditionFailure() }
  catch is CancellationError {} catch { throw error }

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
  print("PASS: typed health failures, bounded queued probes, cancellation, and health reads during paused removals")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-health-') as d:
    p = Path(d)/'check.swift'; p.write_text(source)
    subprocess.run(['swiftc', *swift_subprocess.swift_flags(root), *[str(app/'Services'/name) for name in ['HostServiceTypes.swift','HostServiceProtocol.swift','HostServiceResources.swift','HostServiceWorkers.swift']], '-swift-version', '6', '-parse-as-library', '-module-cache-path', d+'/modules',
                    str(app / 'Services/DeviceServices.swift'), str(app / 'Transport/DeviceExecution.swift'), str(p),
                    '-o', d+'/check'], check=True)
    subprocess.run([d+'/check'], check=True, timeout=10)
