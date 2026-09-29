#!/usr/bin/env python3
"""Exercise the production boot readiness watch with emulated backlight and cancellation."""
from pathlib import Path
import subprocess, tempfile
DEVICE_PROFILE = str(Path(__file__).resolve().parents[2] / 'LightTouchMac/DeviceProfile.swift')
root=Path(__file__).resolve().parents[2]
s=(root/'LightTouchMac/EmulatorController.swift').read_text()
a=s.index('    private func startReadinessWatch()');b=s.index('    /// Keep the guest',a)
method=s[a:b].replace('private func','func',1)
a=s.index('    func powerOn()');b=s.index('    private func startForegroundWatch()',a)
power_on=s[a:b]
source=r'''import Foundation
struct DeviceToolsError: Error {static func failed(_ s:String)->Self{Self()}}
@MainActor var sleeping=false
@MainActor var queryHook:(()->Void)?
/// The helper's status block (read live) and link (commands go nowhere).
struct Status { var displaySleeping: Bool; var shutdownConfirmed = false }
struct FakeLink { func send(_ c: LinkCommand) {} }
@MainActor final class Controller {
 let profile = DeviceProfile.iPodTouch2G
 enum State{case running,booting,poweredOff};enum Notice{case preparation}
 var state=State.running
 var hasGuestTools=true
 func setAccelerometer(for degrees:Int){}
 var isSleeping=false,preparingDevice=false,isDead=false,storageFailed=false,shuttingDown=false
 var readinessFailure:String?,readinessTask:Task<Void,Never>?
 var bootGeneration=0,homes=0,rotationDegrees=0
 var poweringOn=false
 var reachableSince:Date?,ethlinkUp=false
 var status:Status? { queryHook?(); return Status(displaySleeping: sleeping) }
 var link:FakeLink?=FakeLink()
 struct Helper { let isDead = false }
 var process:Helper?=Helper()
 var onRestartRequested:(()->Void)?
 var foregroundAppName:String?,deviceReachable:Bool?
 var isPoweredOff:Bool{state == .poweredOff}
 func reconnectUSB(){}
 func startForegroundWatch(){}
 func startGuestPackageWatch(){}
 func startBootWatch(){}
 var preparationStatus=""
 var onReady:(()->Void)?
 func deviceReady() async -> Bool {onReady?();return true}
 var springBoardReady=true
 var springBoardChecks=0
 func waitForSpringBoard() async throws {
  springBoardChecks+=1
  while !springBoardReady { try await Task.sleep(for:.milliseconds(10)) }
 }
 func logEvent(_ s:String){}
 func resolveDeviceNotice(for n:Notice){}
 func reportDeviceNotice(_ s:String,for n:Notice){}
 func pressHome(){precondition(preparingDevice);homes+=1;sleeping=false}
'''+method+power_on+r'''}
@main struct Main {
 @MainActor static func main() async {
  for off in [true,false] {
   sleeping=off;let c=Controller();c.startReadinessWatch();await c.readinessTask?.value
   precondition(c.homes==(off ? 1:0) && !c.preparingDevice)
  }
  let pending=Controller();pending.springBoardReady=false;pending.startReadinessWatch()
  while pending.springBoardChecks==0 {await Task.yield()}
  precondition(pending.preparingDevice && pending.preparationStatus == "Waiting for the Home screen…")
  pending.springBoardReady=true;await pending.readinessTask?.value
  precondition(!pending.preparingDevice)
  sleeping=true;let cold=Controller();cold.state = .poweredOff
  cold.powerOn();precondition(cold.bootGeneration==1)
  cold.state = .running
  let deadline=ContinuousClock.now + .seconds(2)
  while cold.readinessTask==nil,ContinuousClock.now<deadline {await Task.yield()}
  await cold.readinessTask?.value;precondition(cold.homes==1)
  let stale=Controller();stale.onReady={stale.bootGeneration+=1}
  stale.startReadinessWatch();await stale.readinessTask?.value
  precondition(stale.preparingDevice)
  let cancelled=Controller();cancelled.onReady={cancelled.readinessTask?.cancel()}
  cancelled.startReadinessWatch();await cancelled.readinessTask?.value
  precondition(cancelled.homes==0 && !cancelled.preparingDevice)
  let quitting=Controller();quitting.onReady={quitting.shuttingDown=true}
  quitting.startReadinessWatch();await quitting.readinessTask?.value;precondition(quitting.homes==0)
  print("PASS: one boot wake only for backlight-off; awake/cancelled/new-boot/shutdown sessions unchanged")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-wake-') as d:
 p=Path(d)/'check.swift';p.write_text(source)
 subprocess.run(['swiftc', DEVICE_PROFILE,str(root/'Shared/DeviceLinkProtocol.swift'),'-parse-as-library','-module-cache-path',d+'/modules',str(p),'-o',d+'/check'],check=True)
 subprocess.run([d+'/check'],check=True,timeout=10)
