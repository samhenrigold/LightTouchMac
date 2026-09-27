#!/usr/bin/env python3
"""Execute production shutdown control flow with a slow boot and uncooperative preparation."""
from pathlib import Path
import subprocess,tempfile
DEVICE_PROFILE = str(Path(__file__).resolve().parents[1] / 'LightTouchMac/DeviceProfile.swift')
root=Path(__file__).resolve().parents[1]
s=(root/'LightTouchMac/EmulatorController.swift').read_text()
a=s.index('    static let preparationShutdownBudget:');b=s.index('    /// Menu ▸ Save State Now',a)
shutdown=s[a:b].replace('preparationShutdownBudget: TimeInterval = 5','preparationShutdownBudget: TimeInterval = 0.02').replace('haltShutdownBudget: TimeInterval = 30','haltShutdownBudget: TimeInterval = 0.7').replace('syncShutdownBudget: TimeInterval = 20','syncShutdownBudget: TimeInterval = 0.02')
a=s.index('    func haltFilesystem() async throws {');b=s.index('    func restartSpringBoard()',a)
halt=s[a:b]
services=(root/'LightTouchMac/DeviceServices.swift').read_text()
a=services.index('func withSoftDeadline<T: Sendable>');b=services.index('// MARK: - Install watchdog box',a)
helpers=services[a:b]
s=(root/'LightTouchMac/DeviceStateStorage.swift').read_text()
a=s.index('    @MainActor\n    static func waitForShutdown');b=s.index('    /// Publish',a)
wait=s[a:b]
source=r'''import Foundation
@MainActor var powerOff=false
@MainActor func qemu_ios_ui_guest_shutdown_confirmed()->Bool{powerOff}
@MainActor func qemu_ios_ui_powerdown(){}
@MainActor func qemu_ios_snapshot_resume(){}
@MainActor var agentReady:Int32=0
@MainActor func qemu_ios_agent_status()->Int32{agentReady}
nonisolated func logEvent(_ s:String){}
enum DeviceStateStorage {
'''+wait+'}\n'+helpers+r'''
@MainActor final class Controller {
 enum State{case notStarted,booting,running,paused,snapshotting,poweredOff}
 var state=State.booting,isDead=false,storageFailed=false,shuttingDown=false,canManageApps=true
 var isPoweredOff:Bool{state == .poweredOff}
 var connectionRecoveryTask:Task<Void,Never>?,orientationTask:Task<Void,Never>?,foregroundTask:Task<Void,Never>?,mediaPreparationTask:Task<Void,Never>?,cleanShutdownTask:Task<Void,Never>?
 var shutdownCompletions:[(Bool)->Void]=[]
 var haltAttempts=0,syncAttempts=0,attemptNeeded=2
 func haltFilesystem() async throws {
  haltAttempts+=1
  if haltAttempts>=attemptNeeded{powerOff=true}else{throw CocoaError(.fileReadUnknown)}
 }
 func syncFilesystem() async throws{syncAttempts+=1}
 func pollStorageFailure(){if powerOff {state = .poweredOff}}
'''+shutdown+r'''}
@MainActor enum DeviceTools {
 static var available=true
 static func requestIndependentHalt() async -> Bool {available}
 func haltFilesystem() async throws {}
}
@MainActor struct MissingUSB {
 func tools() throws -> DeviceTools {throw CocoaError(.fileReadUnknown)}
'''+halt+r'''}
@main struct Main {
 @MainActor static func main() async throws {
  let c=Controller(),held=ResumeOnce<Void>()
  c.mediaPreparationTask=Task {try? await withCheckedThrowingContinuation{held.attach($0)}}
  let completed=ResumeOnce<Void>()
  var callbacks:[Bool]=[]
  func record(_ result:Bool){callbacks.append(result);if callbacks.count==2{completed.resume(.success(()))}}
  let started=ContinuousClock.now
  c.beginCleanShutdown(completion:record)
  c.beginCleanShutdown(completion:record)
  precondition(c.shuttingDown && c.state == .booting)
  try await withCheckedThrowingContinuation{completed.attach($0)}
  precondition(callbacks==[true,true] && c.haltAttempts==2 && c.syncAttempts==0)
  precondition(c.isPoweredOff && !c.shuttingDown)
  precondition(started.duration(to:.now) < .seconds(2),"preparation held quit indefinitely")
  held.resume(.success(()));await c.mediaPreparationTask?.value
  powerOff=false
  let failed=Controller();failed.attemptNeeded=100
  let result=await withCheckedContinuation{continuation in failed.beginCleanShutdown{continuation.resume(returning:$0)}}
  precondition(!result && failed.syncAttempts==1 && !failed.shuttingDown)
  let save=Controller();save.state = .snapshotting
  var saveResult:Bool?
  save.beginCleanShutdown{saveResult=$0}
  precondition(saveResult==false && !save.shuttingDown && save.haltAttempts==0)
  powerOff=false;agentReady=1
  let noUSB=Controller();noUSB.canManageApps=false;noUSB.attemptNeeded=1
  let independent=await withCheckedContinuation{continuation in noUSB.beginCleanShutdown{continuation.resume(returning:$0)}}
  precondition(independent && noUSB.haltAttempts==1)
  try await MissingUSB().haltFilesystem()
  DeviceTools.available=false
  do {try await MissingUSB().haltFilesystem();preconditionFailure("USB fallback must fail")} catch {}
  print("PASS: independent halt without USB, bounded preparation cancellation, boot-time halt retry, joined completions, sync fallback, snapshot guard")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-shutdown-') as d:
 p=Path(d)/'check.swift';p.write_text(source)
 subprocess.run(['swiftc','-parse-as-library','-module-cache-path',d+'/modules',DEVICE_PROFILE,str(p),'-o',d+'/check'],check=True)
 subprocess.run([d+'/check'],check=True,timeout=8)
