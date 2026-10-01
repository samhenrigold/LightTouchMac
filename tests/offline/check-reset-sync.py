#!/usr/bin/env python3
"""Production restart must sync successfully before retiring the boot/resetting."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
s=(root/'LightTouchMac/Device/EmulatorController.swift').read_text()
a=s.index('    func reset()');b=s.index('    /// Retain the QEMU',a)
method=s[a:b]
source=r'''import Foundation
enum Machine {case reset}
enum Command {case machine(Machine)}
@MainActor final class Link {var resets=0;func send(_ value:Command){resets+=1}}
@MainActor final class Agent {
 var fails=false
 var beforeReturn:(()->Void)?
 var syncs=0
 func sync() async throws {syncs+=1;beforeReturn?();if fails {throw CocoaError(.fileReadUnknown)}}
}
func withSoftDeadline<T:Sendable>(_ seconds:Double,_ work:@escaping @Sendable ()async->T)async->T? {await work()}
@MainActor final class Controller {
 enum State {case running,booting}
 enum Notice {case powerOff}
 let bootScope=BootSessionScope()
 var bootGeneration:Int {bootScope.generation}
 var readinessTask:Task<Void,Never>?
 var workerRetirement:Task<Void,Never>?
 var isPoweredOff=false,shuttingDown=false,storageFailed=false,isDead=false,stopped=false,releasing=false
 var hasGuestTools=true,didSweepStaging=true,isReconnecting=true
 var deviceReachable:Bool?,reachableSince:Date?
 var rotationDegrees=0
 var state=State.running
 let guestAgent=Agent()
 let link:Link?=Link()
 var onRestartRequested:(()->Void)?
 var halts=0,notices=0,readinessStarts=0
 func powerOn(){}
 func halt(completion:@escaping(Bool)->Void){halts+=1;completion(true)}
 func retireBoot(){bootScope.retire()}
 func publishDeveloperConnection(){}
 func reconnectUSB(){}
 func startTimeZoneSync(){}
 func setAccelerometer(for value:Int){}
 func startForegroundWatch(){}
 func startOrientationWatch(){}
 func startReadinessWatch(){readinessStarts+=1}
 func startGuestPackageWatch(){}
 func startBootWatch(){}
 func reportDeviceNotice(_ value:String,for operation:Notice){notices+=1}
 func resolveDeviceNotice(for operation:Notice){notices=0}
'''+method+r'''}
@main struct Probe {
 @MainActor static func main() async {
  let success=Controller();let old=success.bootScope.id
  success.reset();let good=success.bootScope[.reset];await good?.value
  precondition(success.guestAgent.syncs==1 && success.link!.resets==1 && success.bootScope.id != old && !success.bootScope.retired)
  let failure=Controller();failure.state = .booting;failure.guestAgent.fails=true
  failure.reset();let bad=failure.bootScope[.reset];await bad?.value
  precondition(failure.link!.resets==0 && !failure.bootScope.retired && failure.notices==1 && failure.readinessStarts==1)
  let stale=Controller();stale.guestAgent.beforeReturn={stale.bootScope.retire()}
  stale.reset();let previous=stale.bootScope[.reset];await previous?.value
  precondition(stale.link!.resets==0 && stale.notices==0)
  let noTools=Controller();noTools.hasGuestTools=false
  noTools.reset();await noTools.bootScope[.reset]?.value
  precondition(noTools.halts==1 && noTools.guestAgent.syncs==0 && noTools.link!.resets==0)
  print("PASS: sync precedes reset; failed/stale sync cannot reset; no-tools path uses halt/restart")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-reset-sync-') as temporary:
 folder=Path(temporary);main=folder/'main.swift';main.write_text(source);binary=folder/'probe'
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(root/'LightTouchMac/Device/BootSessionScope.swift'),str(main),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)
