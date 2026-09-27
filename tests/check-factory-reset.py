#!/usr/bin/env python3
"""Erase completes after native writers exit, before quit; failures stay visible."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'LightTouchMac/EmulatorController.swift').read_text()
a=s.index('    func requestFactoryReset()');b=s.index('    func cancelFactoryReset()',a)
reset=s[a:b].replace('.seconds(15)','.milliseconds(30)').replace('.milliseconds(100)','.milliseconds(5)')
source=r'''import Foundation
@MainActor var events:[String]=[]
@MainActor var exitNative=true
@MainActor var current:Controller!
@MainActor func qemu_ios_ui_quit(){events.append("stop");if exitNative {current.isDead=true}}
nonisolated func logEvent(_ s:String){}
@MainActor enum AppInstaller {static let hasPendingWork=false; static var discarded=0; static func discardAll(){discarded+=1}}
@MainActor enum AppDelegate {
 static func requestTermination(){
  precondition(!current.isErasing && current.isDead)
  precondition(!FileManager.default.fileExists(atPath:current.overlayURL.path))
  events.append("quit")
 }
}
@MainActor final class Controller {
 enum State {case running,notStarted}
 enum Notice {case erase}
 var isErasing=false,isInstalling=false,isDead=false,skipNextQuitSnapshot=false
 var state=State.running
 var foregroundTask:Task<Void,Never>?,orientationTask:Task<Void,Never>?
 struct Options {let nand="nand",packedNAND="/missing"}
 let options=Options()
 var packedImage:Int?=nil
 var stateDir:URL{root}
 let root:URL
 var overlayURL:URL{root.appendingPathComponent("overlay")}
 var snapshotURL:URL{root.appendingPathComponent("snapshot")}
 var snapshotTmpURL:URL{snapshotURL.appendingPathExtension("tmp")}
 var snapshotBadURL:URL{snapshotURL.appendingPathExtension("bad")}
 var resetMarkerURL:URL{root.appendingPathComponent(".reset")}
 init(_ root:URL)throws {
  self.root=root
  try FileManager.default.createDirectory(at:overlayURL,withIntermediateDirectories:true)
  try Data("personal data".utf8).write(to:overlayURL.appendingPathComponent("file"))
 }
 func beginCleanShutdown(completion:@escaping(Bool)->Void){events.append("halt");completion(true)}
 func resolveDeviceNotice(for operation:Notice){}
 func reportDeviceNotice(_ text:String,for operation:Notice){events.append("failure")}
'''+reset+r'''}
@main struct Check {
 @MainActor static func main() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {try? FileManager.default.removeItem(at:root)}
  current=try Controller(root.appendingPathComponent("success"))
  current.requestFactoryReset();current.requestFactoryReset()
  while current.isErasing {try await Task.sleep(for:.milliseconds(5))}
  precondition(events==["halt","stop","quit"])
  events=[];exitNative=false
  current=try Controller(root.appendingPathComponent("stuck"))
  current.requestFactoryReset()
  while current.isErasing {try await Task.sleep(for:.milliseconds(5))}
  precondition(events==["halt","stop","failure"])
  precondition(FileManager.default.fileExists(atPath:current.overlayURL.path))
  precondition(!FileManager.default.fileExists(atPath:current.resetMarkerURL.path))
  events=[];current.isDead=true
  current.requestFactoryReset()
  while current.isErasing {try await Task.sleep(for:.milliseconds(5))}
  precondition(events==["quit"])
  print("PASS: erase waits for native exit, removes data before quit, coalesces requests, preserves data on stop failure, and retries from stopped state")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-erase-') as d:
 p=Path(d)/'check.swift';p.write_text(source)
 subprocess.run(['swiftc','-module-cache-path',d+'/modules',str(root/'LightTouchMac/DeviceStateStorage.swift'),str(p),'-o',d+'/check'],check=True)
 subprocess.run([d+'/check'],check=True,timeout=10)
