#!/usr/bin/env python3
"""Exercise the production boot readiness watch with emulated backlight and cancellation."""
from pathlib import Path
import subprocess, tempfile
DEVICE_PROFILE = str(Path(__file__).resolve().parents[2] / 'LightTouchMac/Device/DeviceProfile.swift')
root=Path(__file__).resolve().parents[2]
s=(root/'LightTouchMac/Device/EmulatorController.swift').read_text()
a=s.index('    private func startReadinessWatch()');b=s.index('    /// Keep the guest',a)
method=s[a:b].replace('private func','func',1).replace('.seconds(profile.bootBudget)','.milliseconds(budgetMS)')
a=s.index('    func powerOn()');b=s.index('    private func startForegroundWatch()',a)
power_on=s[a:b]
source=r'''import Foundation
struct DeviceToolsError: Error {static func failed(_ s:String)->Self{Self()}}
@MainActor var sleeping=false
@MainActor var queryHook:(()->Void)?
@MainActor var budgetMS=60_000
/// The helper's status block (read live) and link (commands go nowhere).
struct Status { var displaySleeping: Bool; var shutdownConfirmed = false; var guestPackage: Int? = nil }
struct FakeLink { func send(_ c: LinkCommand) {} }
@MainActor final class Controller {
 let profile = DeviceProfile.iPodTouch2G
 enum State{case running,booting,poweredOff};enum Notice{case preparation}
 var state=State.running
 var hasGuestTools=true
 func setAccelerometer(for degrees:Int){}
 var isSleeping=false,preparingDevice=false,isDead=false,storageFailed=false,shuttingDown=false
 var readinessFailure:String?,readinessTask:Task<Void,Never>?
 let bootScope=BootSessionScope()
 var bootGeneration:Int {bootScope.generation}
 var homes=0,rotationDegrees=0
 var workerRetirement:Task<Void,Never>?
 func publishDeveloperConnection(){}
 func retireBoot(){bootScope.retire()}
 var poweringOn=false,didSweepStaging=false,isReconnecting=false
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
 var timezoneStarts=0
 func startTimeZoneSync(){timezoneStarts+=1}
 var preparationStatus=""
 var bootStage=BootStage.poweringOn,reportAtBootStart:Int?
 func noteBoot(_ e:BootStage.Event){bootStage=bootStage.after(e)}
 var onReady:(()->Void)?
 var usbAnswers=true
 var deadlineVerdict:ReadinessDeadline{ReadinessDeadline.verdict(painted:state == .running,stage:bootStage)}
 func deviceReady() async -> Bool {onReady?();return usbAnswers}
 var springBoardReady=true
 var springBoardChecks=0
 func waitForSpringBoard() async throws {
  springBoardChecks+=1
  while !springBoardReady { try await Task.sleep(for:.milliseconds(10)) }
 }
 func logEvent(_ s:String){}
 var notices:[String]=[]
 func resolveDeviceNotice(for n:Notice){notices.removeAll()}
 func reportDeviceNotice(_ s:String,for n:Notice){notices.append(s)}
 func pressHome(){precondition(preparingDevice);homes+=1;sleeping=false}
'''+method+power_on+r'''}
@main struct Main {
 @MainActor static func main() async {
  for off in [true,false] {
   sleeping=off;let c=Controller();c.startReadinessWatch();await c.readinessTask?.value
   precondition(c.homes==(off ? 1:0) && !c.preparingDevice)
   precondition(c.bootStage == .usb, "USB answered: the toast moves on to the Home screen")
  }
  let pending=Controller();pending.springBoardReady=false;pending.startReadinessWatch()
  while pending.springBoardChecks==0 {await Task.yield()}
  precondition(pending.preparingDevice && pending.preparationStatus == "Waiting for the Home screen…")
  pending.springBoardReady=true;await pending.readinessTask?.value
  precondition(!pending.preparingDevice)
  sleeping=true;let cold=Controller();cold.state = .poweredOff
  cold.powerOn();precondition(cold.bootGeneration==1 && cold.timezoneStarts==1, "cold power-on must establish a new timezone operation")
  cold.state = .running
  let deadline=ContinuousClock.now + .seconds(2)
  while cold.readinessTask==nil,ContinuousClock.now<deadline {await Task.yield()}
  await cold.readinessTask?.value;precondition(cold.homes==1)
  let stale=Controller();stale.onReady={stale.bootScope.retire()}
  stale.startReadinessWatch();await stale.readinessTask?.value
  precondition(stale.preparingDevice)
  let cancelled=Controller();cancelled.onReady={cancelled.readinessTask?.cancel()}
  cancelled.startReadinessWatch();await cancelled.readinessTask?.value
  precondition(cancelled.homes==0 && !cancelled.preparingDevice)
  let quitting=Controller();quitting.onReady={quitting.shuttingDown=true}
  quitting.startReadinessWatch();await quitting.readinessTask?.value;precondition(quitting.homes==0)
  // The deadline with iOS on screen and no USB: input on, a notice, still waiting; USB later clears it.
  budgetMS=100;sleeping=false
  let noUSB=Controller();noUSB.usbAnswers=false;noUSB.startReadinessWatch();noUSB.bootStage = .system
  try? await Task.sleep(for:.milliseconds(400))
  precondition(!noUSB.preparingDevice && noUSB.readinessFailure==nil,"kept running, not a startup failure")
  precondition(noUSB.notices==[ReadinessDeadline.notice(shortName:"iPod")],"\(noUSB.notices)")
  noUSB.usbAnswers=true;await noUSB.readinessTask?.value
  precondition(noUSB.deviceReachable==true && noUSB.notices.isEmpty && noUSB.bootStage == .usb,"USB came: ready, notice gone")
  // No picture from iOS by the deadline: the startup fails as before.
  let dark=Controller();dark.usbAnswers=false;dark.startReadinessWatch();dark.bootStage = .kernel
  await dark.readinessTask?.value
  precondition(dark.readinessFailure != nil && !dark.preparingDevice && dark.notices.count==1 && dark.notices[0] != ReadinessDeadline.notice(shortName:"iPod"))
  budgetMS=60_000
  print("PASS: one boot wake only for backlight-off; awake/cancelled/new-boot/shutdown sessions unchanged; the deadline keeps iOS on screen running without USB")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-wake-') as d:
 p=Path(d)/'check.swift';p.write_text(source)
 subprocess.run(['swiftc', DEVICE_PROFILE,str(root/'LightTouchMac/Device/BootSessionScope.swift'),str(root/'Shared/DeviceLinkProtocol.swift'),str(root/'LightTouchMac/Device/BootStage.swift'),'-parse-as-library','-module-cache-path',d+'/modules',str(p),'-o',d+'/check'],check=True)
 subprocess.run([d+'/check'],check=True,timeout=10)
