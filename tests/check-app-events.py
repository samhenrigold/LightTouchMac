#!/usr/bin/env python3
"""Production app log formatting, concurrent append, permissions, rotation and failure."""
from pathlib import Path
import os, subprocess, tempfile
root=Path(__file__).resolve().parents[1]
controller=(root/'LightTouchMac/EmulatorController.swift').read_text()
notice=controller[controller.index('    enum NoticeOperation:'):controller.index('    private var foregroundTask:')].replace('UserDefaults.standard','defaults')
with tempfile.TemporaryDirectory(prefix='ltm-events-') as temp:
 p=Path(temp)
 (p/'check.swift').write_text('import Foundation\nlet domain=UUID().uuidString\nlet defaults=UserDefaults(suiteName:domain)!\n@MainActor final class NoticeDevice { var storageFailed=false; var onStatusChange:(()->Void)?\n'+notice+'}\n'+r'''
@main struct Check {
 static func main() async throws {
  let device=NoticeDevice();var changes=0;device.onStatusChange={changes+=1}
  device.reportDeviceNotice("Retry preparation",for:.preparation)
  precondition(NoticeDevice().deviceNotice=="Retry preparation" && changes==1)
  device.resolveDeviceNotice(for:.powerOff);precondition(device.deviceNotice != nil)
  device.resolveDeviceNotice(for:.preparation);precondition(NoticeDevice().deviceNotice==nil)
  device.storageFailed=true;device.reportDeviceNotice("Another failure",for:.powerOff)
  precondition(device.deviceNotice!.hasPrefix("Storage writes failed"))
  device.dismissDeviceNotice();precondition(device.deviceNotice != nil)
  device.storageFailed=false;device.dismissDeviceNotice()
  defaults.removePersistentDomain(forName:domain)
  let directory=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
  let log=AppEventLog(directory:directory)
  await withTaskGroup(of:Void.self){group in
   for i in 0..<200 { group.addTask{log.append("event-\(i)")} }
  }
  await log.flush()
  let file=directory.appendingPathComponent("app.log")
  let data=try String(contentsOf:file,encoding:.utf8)
  let lines=data.split(separator:"\n");precondition(lines.count==200)
  for i in 0..<200{precondition(lines.contains{$0.hasSuffix(" event-\(i)")})}
  let permissions=try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as! NSNumber
  precondition(permissions.intValue & 0o777 == 0o600)
  try Data(repeating:65,count:999_999).write(to:file)
  log.append("after rotation");await log.flush()
  precondition(try! Data(contentsOf:file.appendingPathExtension("1")).count==999_999)
  precondition(try! String(contentsOf:file,encoding:.utf8).contains("after rotation"))
  log.append(String(repeating:"🦋",count:100_000));await log.flush()
  precondition(try! Data(contentsOf:file).count<33_000)
  log.append("a"+String(repeating:"\u{301}",count:100_000));await log.flush()
  precondition(try! Data(contentsOf:file).count<66_000)
  let blocked=directory.appendingPathComponent("blocked")
  try Data("keep".utf8).write(to:blocked)
  let broken=AppEventLog(directory:blocked)
  broken.append("cannot write");broken.append("still cannot write");await broken.flush()
  precondition(try! String(contentsOf:blocked,encoding:.utf8)=="keep")
  logEvent("literal 100%")
  logEvent("formatted %@", "value")
  await AppEventLog.shared.flush()
  let formatted=try String(contentsOf:Bundled.stateDirectory.appendingPathComponent("app.log"),encoding:.utf8)
  precondition(formatted.contains("literal 100%") && formatted.contains("formatted value"))
  print("PASS: concurrent event logging, literal percent/formatting, private files, bounds/rotation and write failure")
 }
}
''')
 subprocess.run(['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-module-cache-path',str(p/'modules'),str(root/'LightTouchMac/AppEventLog.swift'),str(root/'LightTouchMac/Bundled.swift'),str(p/'check.swift'),'-o',str(p/'check')],check=True)
 subprocess.run([str(p/'check'),str(p/'events')],env=dict(os.environ,LTM_STATE_DIR=str(p/'state')),check=True)
