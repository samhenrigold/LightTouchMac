#!/usr/bin/env python3
"""Run production deadline/serial-gate cancellation without a device or timed assumptions about the main actor."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[2]
execution=(root/'LightTouchMac/Transport/DeviceExecution.swift').read_text()
source=r'''import Foundation
import Dispatch
nonisolated func logEvent(_ s:String){}
'''+execution+r'''
nonisolated final class Blocked: @unchecked Sendable {
 let entered=DispatchSemaphore(value:0), release=DispatchSemaphore(value:0)
 func run() -> Int {entered.signal();release.wait();return 42}
 func waitForEntry(){entered.wait()}
}
@main struct Check {
 static func drain() async {
  let deadline=ContinuousClock.now + .seconds(2)
  while AbandonedWork.count > 0, ContinuousClock.now < deadline {await Task.yield()}
  precondition(AbandonedWork.count==0,"worker did not return abandonment slot")
 }
 static func main() async throws {
  let timed=Blocked()
  let task=Task {try await withDeadline(0.03,"fixture",timed.run)}
  await Task.detached {timed.waitForEntry()}.value
  do {_=try await task.value;preconditionFailure("no timeout")} catch DeviceError.timedOut {} catch {throw error}
  precondition(AbandonedWork.count==1)
  timed.release.signal();await drain()
  // Cancellation completes before an uncooperative worker, without freeing
  // that worker's slot early. Its eventual result is discarded exactly once.
  let blocked=Blocked()
  let cancelled=Task {try await withDeadline(60,"cancelled",blocked.run)}
  await Task.detached {blocked.waitForEntry()}.value
  cancelled.cancel()
  let cancellationFinished=await withSoftDeadline(1) {
   do {_=try await cancelled.value;return false} catch is CancellationError {return true} catch{return false}
  }
  precondition(cancellationFinished==true && AbandonedWork.count==1)
  blocked.release.signal();await drain()
  for _ in 0..<40 {let value=try await withDeadline(1,"fast"){7};precondition(value==7)}
  precondition(AbandonedWork.count==0)
  let gate=DeviceGate(), held=ResumeOnce<Void>(), entered=ResumeOnce<Void>()
  let owner=Task {
   try await gate.serialized {
    entered.resume(.success(()))
    try await withCheckedThrowingContinuation {held.attach($0)}
   }
  }
  try await withCheckedThrowingContinuation {entered.attach($0)}
  let queued=Task {try await gate.serialized {() -> Bool in preconditionFailure("cancelled waiter executed")}}
  queued.cancel()
  let queuedCancelled=await withSoftDeadline(1) {
   do {_=try await queued.value;return false} catch is CancellationError {return true} catch{return false}
  }
  precondition(queuedCancelled==true,"queue cancellation waited for owner")
  let dropped: Bool??=await withSoftDeadline(0.03) {
   try? await gate.serialized {() -> Bool in preconditionFailure("timed-out queue waiter executed")}
  }
  precondition(dropped==nil)
  held.resume(.success(()));try await owner.value
  let next=try await gate.serialized {13}
  precondition(next==13)
  // A timed-out C operation can connect again after the caller has returned.
  // Keep its endpoint unchanged, including when another device is queued.
  let routed=Blocked()
  let endpointA="UNIX:/tmp/ltm-deadline-device-a"
  let endpointB="UNIX:/tmp/ltm-deadline-device-b"
  let late=Task {
   try await DeviceGate.shared.serialized(socket:endpointA) {
    try await withDeadline(0.03,"late connection") {
     _=routed.run()
     precondition(String(cString:getenv("USBMUXD_SOCKET_ADDRESS"))==endpointA,
                  "late C connection was routed to another device")
     return 1
    }
   }
  }
  await Task.detached {routed.waitForEntry()}.value
  do {_=try await late.value;preconditionFailure("missing timeout")} catch DeviceError.timedOut {}
  do {
   _=try await DeviceGate.shared.serialized(socket:endpointB) {99}
   preconditionFailure("switched endpoint with live abandoned work")
  } catch DeviceError.endpointBusy {}
  precondition(String(cString:getenv("USBMUXD_SOCKET_ADDRESS"))==endpointA)
  let same=try await DeviceGate.shared.serialized(socket:endpointA) {17}
  precondition(same==17,"same-device recovery was blocked")
  routed.release.signal();await drain()
  let other=try await DeviceGate.shared.serialized(socket:endpointB) {23}
  precondition(other==23 && String(cString:getenv("USBMUXD_SOCKET_ADDRESS"))==endpointB)
  print("PASS: timeout/cancellation balance, prompt queued cancellation, cancelled soft deadlines, gate reuse, late-connect endpoint isolation")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-deadlines-') as d:
 p=Path(d)/'check.swift';p.write_text(source)
 subprocess.run(['swiftc','-parse-as-library','-swift-version','6','-module-cache-path',d+'/modules',str(p),'-o',d+'/check'],check=True)
 subprocess.run([d+'/check'],check=True,timeout=10)
