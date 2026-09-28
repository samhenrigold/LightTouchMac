#!/usr/bin/env python3
"""Erase completes after the helper exits, then restarts the device (never quits
the app); a stopped device just erases; failures stay visible."""
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
/// The helper's link: quit stands for the helper exiting (it releases every writer).
@MainActor struct FakeLink { func send(_ c:LinkCommand){ if case .machine(.quit)=c {events.append("stop");if exitNative {current.isDead=true}} } }
nonisolated func logEvent(_ s:String){}
@MainActor enum AppInstaller {static let hasPendingWork=false; static var discarded=0; static func discard(for id:UUID){discarded+=1}}
@MainActor func restart(){
 precondition(!current.isErasing && current.isDead)
 precondition(!FileManager.default.fileExists(atPath:current.overlayURL.path))
 events.append("restart")
}
@MainActor final class Controller {
 enum State {case running,notStarted}
 enum Notice {case erase}
 struct Instance { let id=UUID() }
 let instance=Instance()
 var isErasing=false,isInstalling=false,isDead=false,skipNextQuitSnapshot=false
 var state=State.running
 var started=true
 var link:FakeLink?=FakeLink()
 var onRestartRequested:(()->Void)?={restart()}
 var foregroundTask:Task<Void,Never>?,orientationTask:Task<Void,Never>?
 struct Options {let nand="nand",packedNAND="/missing"}
 let options=Options()
 var packedImage:Int?=nil
 var stateDir:URL{root}
 let root:URL
 var overlayURL:URL{root.appendingPathComponent("overlay")}
 var preparedNORURL:URL?{root.appendingPathComponent("nor.bin")}
 var snapshotURL:URL{root.appendingPathComponent("snapshot")}
 var snapshotTmpURL:URL{snapshotURL.appendingPathExtension("tmp")}
 var snapshotBadURL:URL{snapshotURL.appendingPathExtension("bad")}
 var resetMarkerURL:URL{root.appendingPathComponent(".reset")}
 init(_ root:URL)throws {
  self.root=root
  try FileManager.default.createDirectory(at:overlayURL,withIntermediateDirectories:true)
  try Data("personal data".utf8).write(to:overlayURL.appendingPathComponent("file"))
  try Data("nvram".utf8).write(to:preparedNORURL!)
 }
 func halt(completion:@escaping(Bool)->Void){events.append("halt");completion(true)}
 /// The helper process: gone once the fake link quit it.
 struct Helper { let isDead: Bool }
 var process:Helper?{Helper(isDead:isDead)}
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
  precondition(events==["halt","stop","restart"])
  precondition(!FileManager.default.fileExists(atPath:current.preparedNORURL!.path), "a prepared device's NOR copy is erased with its overlay")
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
  precondition(events==["restart"])
  // A device that isn't running (DeviceSessionHost.stoppedController): erase only.
  events=[];current=try Controller(root.appendingPathComponent("stopped"))
  current.started=false;current.state = .notStarted;current.onRestartRequested=nil
  current.requestFactoryReset()
  while current.isErasing {try await Task.sleep(for:.milliseconds(5))}
  precondition(events==[] && !FileManager.default.fileExists(atPath:current.overlayURL.path))
  print("PASS: erase waits for the helper to exit, removes data before restarting the device, coalesces requests, preserves data on stop failure, retries from a dead helper, and erases a stopped device without quitting; a prepared device's NOR copy goes with its overlay")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-erase-') as d:
 p=Path(d)/'check.swift';p.write_text(source)
 subprocess.run(['swiftc','-module-cache-path',d+'/modules',str(root/'LightTouchMac/DeviceStateStorage.swift'),str(root/'Shared/DeviceLinkProtocol.swift'),str(p),'-o',d+'/check'],check=True)
 subprocess.run([d+'/check'],check=True,timeout=10)
