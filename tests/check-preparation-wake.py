#!/usr/bin/env python3
"""Exercise the production boot preparation with emulated backlight and cancellation."""
from pathlib import Path
import subprocess, tempfile
DEVICE_PROFILE = str(Path(__file__).resolve().parents[1] / 'LightTouchMac/DeviceProfile.swift')
root=Path(__file__).resolve().parents[1]
s=(root/'LightTouchMac/EmulatorController.swift').read_text()
a=s.index('    private func startMediaPreparation()');b=s.index('    /// Keep the guest',a)
method=s[a:b].replace('private func','func',1)
a=s.index('    func powerOn()');b=s.index('    private func startForegroundWatch()',a)
power_on=s[a:b]
source=r'''import Foundation
struct DeviceToolsError: Error {static func failed(_ s:String)->Self{Self()}}
@MainActor var sleeping=false
@MainActor func qemu_ios_ui_guest_shutdown_confirmed()->Bool {false}
@MainActor func qemu_ios_ui_reset(){}
@MainActor func qemu_ios_ui_resume(){}
@MainActor var queryHook:(()->Void)?
@MainActor func qemu_ios_ui_display_sleeping()->Bool {queryHook?();return sleeping}
@MainActor final class StubTools {
 var updates=0
 func updateMediaComponents() async throws -> Bool {updates+=1;return false}
}
@MainActor final class Controller {
 struct Options{var appsync=true};enum State{case running,booting,poweredOff};enum Notice{case preparation}
 var options=Options(),state=State.running
 var isSleeping=false,preparingMedia=false,isDead=false,storageFailed=false,shuttingDown=false,restoringFromSnapshot=false
 var mediaPreparationFailure:String?,mediaPreparationTask:Task<Void,Never>?
 var bootGeneration=0,homes=0,rotationDegrees=0
 var poweringOn=false
 var foregroundAppName:String?,deviceReachable:Bool?
 var isPoweredOff:Bool{state == .poweredOff}
 func reconnectUSB(){}
 func startForegroundWatch(){}
 var preparationStatus=""
 let stub=StubTools()
 var onReady:(()->Void)?
 func deviceReady() async -> Bool {onReady?();return true}
 func tools()->StubTools{stub}
 var springBoardReady=true
 var springBoardChecks=0
 func waitForSpringBoard() async throws {
  springBoardChecks+=1
  while !springBoardReady { try await Task.sleep(for:.milliseconds(10)) }
 }
 func logEvent(_ s:String){}
 func resolveDeviceNotice(for n:Notice){}
 func reportDeviceNotice(_ s:String,for n:Notice){}
 func pressHome(){precondition(preparingMedia);homes+=1;sleeping=false}
'''+method+power_on+r'''}
@main struct Main {
 @MainActor static func main() async {
  for off in [true,false] {
   sleeping=off;let c=Controller();c.startMediaPreparation();await c.mediaPreparationTask?.value
   precondition(c.homes==(off ? 1:0) && !c.preparingMedia)
  }
  let pending=Controller();pending.springBoardReady=false;pending.startMediaPreparation()
  while pending.springBoardChecks==0 {await Task.yield()}
  precondition(pending.preparingMedia && pending.preparationStatus == "Waiting for the Home screen…")
  pending.springBoardReady=true;await pending.mediaPreparationTask?.value
  precondition(!pending.preparingMedia)
  sleeping=true;let restored=Controller();restored.restoringFromSnapshot=true
  restored.startMediaPreparation();await restored.mediaPreparationTask?.value;precondition(restored.homes==0)
  sleeping=true;let cold=Controller();cold.restoringFromSnapshot=true;cold.state = .poweredOff
  cold.powerOn();precondition(!cold.restoringFromSnapshot && cold.bootGeneration==1)
  cold.state = .running
  let deadline=ContinuousClock.now + .seconds(2)
  while cold.mediaPreparationTask==nil,ContinuousClock.now<deadline {await Task.yield()}
  await cold.mediaPreparationTask?.value;precondition(cold.homes==1)
  let stale=Controller();stale.onReady={stale.bootGeneration+=1}
  stale.startMediaPreparation();await stale.mediaPreparationTask?.value
  precondition(stale.stub.updates==0 && stale.preparingMedia)
  let cancelled=Controller();cancelled.onReady={cancelled.mediaPreparationTask?.cancel()}
  cancelled.startMediaPreparation();await cancelled.mediaPreparationTask?.value
  precondition(cancelled.homes==0 && !cancelled.preparingMedia)
  let quitting=Controller();quitting.onReady={quitting.shuttingDown=true}
  quitting.startMediaPreparation();await quitting.mediaPreparationTask?.value;precondition(quitting.homes==0)
  print("PASS: one cold-boot wake only for backlight-off, restored/awake/cancelled/new-boot/shutdown sessions unchanged")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-wake-') as d:
 p=Path(d)/'check.swift';p.write_text(source)
 subprocess.run(['swiftc', DEVICE_PROFILE,'-parse-as-library','-module-cache-path',d+'/modules',str(p),'-o',d+'/check'],check=True)
 subprocess.run([d+'/check'],check=True,timeout=10)
