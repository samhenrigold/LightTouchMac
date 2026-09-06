#!/usr/bin/env python3
"""Run the production preparation task with delayed guest replies and new boots."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
controller=(root/'LightTouchMac/EmulatorController.swift').read_text()
a=controller.index('    private func startMediaPreparation()');b=controller.index('    /// Keep the guest',a)
method=controller[a:b].replace('private func','func',1)
tools=(root/'LightTouchMac/DeviceTools.swift').read_text()
a=tools.index('    static func screenIsLocked(response:');b=tools.index("    /// Shut the guest",a)
parser=tools[a:b]
code=r'''import Foundation
struct DeviceToolsError: Error { static func failed(_ s:String)->Self{Self()} }
struct Parser {
'''+parser+r'''}
@MainActor final class StubTools {
 var response="sblaunch: locked=1 passcode=0"
 var onQuery:(()->Void)?
 func updateMediaComponents() async throws -> Bool { false }
 func screenIsLocked() async throws -> Bool {
  onQuery?()
  return try Parser.screenIsLocked(response:response)
 }
}
@MainActor func qemu_ios_ui_display_sleeping()->Bool { false }
@MainActor final class Controller {
 struct Options { var appsync=true }; enum State { case running }; enum Notice { case preparation }
 var options=Options(), state=State.running
 var isSleeping=false, preparingMedia=false, isDead=false, storageFailed=false, shuttingDown=false
 var mediaPreparationFailure:String?, mediaPreparationTask:Task<Void,Never>?
 var bootGeneration=0, homes=0
 let stub=StubTools()
 func deviceReady() async ->Bool { true }
 func tools()->StubTools {stub}
 func waitForSpringBoard() async throws {}
 func logEvent(_ s:String){}
 func resolveDeviceNotice(for n:Notice){}
 func reportDeviceNotice(_ s:String,for n:Notice){}
 func pressHome(){precondition(preparingMedia);homes+=1}
'''+method+r'''}
@main struct Main {
 @MainActor static func main() async throws {
  for locked in [true,false] {
   let c=Controller();c.stub.response="sblaunch: locked=\(locked ? 1:0) passcode=1"
   c.startMediaPreparation();await c.mediaPreparationTask?.value
   precondition(c.homes == (locked ? 1:0) && !c.preparingMedia)
  }
  let c=Controller();c.stub.onQuery={c.bootGeneration+=1}
  c.startMediaPreparation();await c.mediaPreparationTask?.value
  precondition(c.homes==0 && c.preparingMedia)
  let cancelled=Controller();cancelled.stub.onQuery={cancelled.mediaPreparationTask?.cancel()}
  cancelled.startMediaPreparation();await cancelled.mediaPreparationTask?.value
  precondition(cancelled.homes==0 && !cancelled.preparingMedia)
  do { _=try Parser.screenIsLocked(response:"sblaunch: lock status unavailable");preconditionFailure() } catch {}
  print("PASS: locked guest wakes under setup mask; unlocked guest untouched; stale/cancelled queries send no input")
 }
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'check.swift';p.write_text(code)
 subprocess.run(['swiftc','-parse-as-library','-module-cache-path',d+'/modules',str(p),'-o',d+'/check'],check=True)
 subprocess.run([d+'/check'],check=True)
