#!/usr/bin/env python3
"""Actual DeviceRuntime preparation ordering and stopped lease/cancellation ownership."""
from pathlib import Path
import subprocess, tempfile, sys
root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'scripts'))
import device_runtime
source=r'''
import Foundation
import DeviceRuntime
import HostRuntime
@main struct Main {
 @MainActor static func main() async throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {try? FileManager.default.removeItem(at:dir)}
  let leasePath=dir.appendingPathComponent("work/lease")
  var configuration=DeviceLink.Configuration(instance:UUID())
  configuration.helper=dir.appendingPathComponent("must-not-spawn")
  enum Failure: Error {case controlled}
  let failed=DeviceSessionProcess(configuration:configuration)
  var completions=0,deaths=0,configured=false
  failed.onDeath={_ in deaths += 1}
  failed.start({_ in configured=true;return nil},preparation:{
   let lease=try StorageLease(leasePath);defer{lease.close()}
   do {_ = try StorageLease(leasePath);fatalError("admission lost exclusion")}
   catch StorageLease.Failure.inUse {}
   throw Failure.controlled
  }) {result in
   completions += 1
   guard case .failure(.helperFailure(let message))=result,message.contains("controlled") else {fatalError("wrong admission failure")}
  }
  let failedExited = await failed.waitForExit(timeout:3)
  precondition(failedExited)
  precondition(completions==1 && deaths==1 && !configured && failed.link.pid==0)
  let afterFailure=try StorageLease(leasePath);afterFailure.close()

  for kill in [false,true] {
  let stopped=DeviceSessionProcess(configuration:configuration)
  var release:CheckedContinuation<Void,Never>?,entered=false
  completions=0;deaths=0
  stopped.onDeath={death in precondition(death == .stopped);deaths += 1}
  stopped.start({_ in configured=true;return nil},preparation:{
   let lease=try StorageLease(leasePath);defer{lease.close()}
   entered=true
   // Even an operation which returns after cancellation cannot spawn later.
   await withCheckedContinuation {release=$0}
  }) {result in
   completions += 1
   guard case .failure(.closed)=result else {fatalError("cancelled admission succeeded")}
  }
  while !entered {await Task.yield()}
  if kill {stopped.kill()} else {stopped.terminate()}
  precondition(stopped.link.pid==0 && !stopped.isDead)
  do {_ = try StorageLease(leasePath);fatalError("Stop abandoned active ownership")}
  catch StorageLease.Failure.inUse {}
  release!.resume()
  let stoppedExited = await stopped.waitForExit(timeout:3)
  precondition(stoppedExited)
  precondition(completions==1 && deaths==1 && !configured && stopped.link.pid==0)
  let afterStop=try StorageLease(leasePath);afterStop.close()
  var duplicate=0
  stopped.start({_ in fatalError("duplicate configure")}) {result in
   guard case .failure(.closed)=result else {fatalError("duplicate start allowed")};duplicate += 1
  }
  precondition(duplicate==1 && deaths==1)
  }
  print("PASS: actual pre-spawn failure, lease ownership, Stop/kill cancellation cleanup, no late helper and exactly-once completion/death")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-preparation-',dir='/private/tmp') as out:
 p=Path(out)/'main.swift';p.write_text(source)
 subprocess.run(['xcrun','swiftc',*device_runtime.swift_flags(root),'-swift-version','5','-parse-as-library',str(p),'-o',out+'/check'],check=True)
 subprocess.run([out+'/check'],check=True)
