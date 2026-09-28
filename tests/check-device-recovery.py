#!/usr/bin/env python3
"""Repeated management failures recover once, without reboot or transfer interruption."""
from pathlib import Path
import subprocess,tempfile
DEVICE_PROFILE = str(Path(__file__).resolve().parents[1] / 'LightTouchMac/DeviceProfile.swift')
root=Path(__file__).resolve().parents[1]
s=(root/'LightTouchMac/EmulatorController.swift').read_text()
a=s.index('    private var connectionFailures =');b=s.index('    private var didSweepStaging',a)
recovery=s[a:b].replace('.seconds(2)','.milliseconds(1)').replace('    private var lastConnectionRecovery','    var lastConnectionRecovery')
report=s[s.index('    private(set) var connectionIssue:'):a]
services=(root/'LightTouchMac/DeviceServices.swift').read_text()
errors=services[services.index('nonisolated enum DeviceError:'):services.index('// MARK: - Timeouts')]
issue=(root/'LightTouchMac/DeviceConnectionIssue.swift').read_text()
source=r'''import Foundation
@MainActor var agentReady=1
struct FakeLink {}
nonisolated func logEvent(_ message:String){}
nonisolated enum AbandonedWork {static let count=0}
extension Notification.Name {static let ltmAppsChanged=Self("apps")}
@MainActor enum AppInstaller {static var isUsingDevice=false; static func isUsingDevice(_ id:UUID)->Bool {isUsingDevice}}
@MainActor enum DeviceTools {
 static var recoveries=0
 static func reconnectManagementService(agent: FakeLink?, cache: Int) async throws -> Bool {recoveries+=1;return true}
}
struct Instance { let id=UUID() }
@MainActor final class Controller {
 let profile = DeviceProfile.iPodTouch2G
 let instance=Instance()
 var isRunning=true,isInstalling=false,hasFileTransfer=false,preparingMedia=false
 var usbConnected=true
 var link:FakeLink?=FakeLink()
 let agentCache=0
 var liveAgentStatus:Int{agentReady}
 var onStatusChange:(()->Void)?
 var deviceReachable:Bool? {didSet{if deviceReachable==true {connectionIssue=nil};considerConnectionRecovery()}}
'''+report+recovery+r'''}
@main struct Check {
 @MainActor static func main() async throws {
  let c=Controller()
  c.reportConnectionFailure(DeviceError.instproxy(.opInProgress,phase:"browse"),operation:"Refreshing apps")
  precondition(c.connectionIssue?.summary=="Updating apps…" && c.deviceReachable==nil)
  for error:DeviceError in [.notAttached,.unavailable,.timedOut(operation:"USB connection"),.instproxy(.opFailed,phase:"browse"),.lockdown(-17),.lockdown(-4),.lockdown(-27),.lockdown(-32)] {
   c.reportConnectionFailure(error,operation:"Checking connection")
   c.deviceReachable=false;c.deviceReachable=false
   try await Task.sleep(for:.milliseconds(10));precondition(DeviceTools.recoveries==0,"do not restart lockdownd for a different failure")
  }
  let previous=c.connectionIssue
  c.reportConnectionFailure(CancellationError(),operation:"Closing inspector")
  precondition(c.connectionIssue==previous,"cancellation is not a connection failure")
  c.reportConnectionFailure(DeviceError.instproxy(.connFailed,phase:"connect"),operation:"Refreshing apps")
  try await Task.sleep(for:.milliseconds(10));precondition(DeviceTools.recoveries==0)
  c.deviceReachable=false
  for _ in 0..<10 {c.deviceReachable=false}
  try await Task.sleep(for:.milliseconds(10));precondition(DeviceTools.recoveries==1 && !c.isReconnecting)
  c.deviceReachable=true;precondition(c.connectionIssue==nil)
  c.reportConnectionFailure(DeviceError.lockdown(-8),operation:"Refreshing apps");c.deviceReachable=false
  try await Task.sleep(for:.milliseconds(10));precondition(DeviceTools.recoveries==1,"must back off")
  c.lastConnectionRecovery = .distantPast;AppInstaller.isUsingDevice=true
  c.deviceReachable=false;c.deviceReachable=false
  try await Task.sleep(for:.milliseconds(10));precondition(DeviceTools.recoveries==1,"must not interrupt install")
  AppInstaller.isUsingDevice=false;c.preparingMedia=true;c.deviceReachable=false
  try await Task.sleep(for:.milliseconds(10));precondition(DeviceTools.recoveries==1,"must not interrupt boot preparation")
  c.preparingMedia=false;c.hasFileTransfer=true;c.deviceReachable=false
  try await Task.sleep(for:.milliseconds(10));precondition(DeviceTools.recoveries==1,"must not interrupt file transfer")
  c.hasFileTransfer=false;agentReady=0;c.deviceReachable=false
  try await Task.sleep(for:.milliseconds(10));precondition(DeviceTools.recoveries==1,"no independent channel")
  agentReady=1;c.isRunning=false;c.deviceReachable=false
  try await Task.sleep(for:.milliseconds(10));precondition(DeviceTools.recoveries==1,"never recover during shutdown")
  c.isRunning=true;c.deviceReachable=false
  try await Task.sleep(for:.milliseconds(10));precondition(DeviceTools.recoveries==2)
  print("PASS: busy/cancelled/USB/unavailable failures do not reset services; repeated app-service failures recover with cooldown and transfer/lifecycle guards")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-recovery-') as d:
 p=Path(d)/'check.swift';p.write_text(errors+issue+source)
 subprocess.run(['swiftc', DEVICE_PROFILE,'-parse-as-library','-module-cache-path',d+'/modules',str(p),'-o',d+'/check'],check=True)
 subprocess.run([d+'/check'],check=True,timeout=8)
