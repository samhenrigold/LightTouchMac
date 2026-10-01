#!/usr/bin/env python3
"""Actual erase/delete methods must refuse an external owner and pending edit."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
import fcntl, pathlib, subprocess, tempfile
ROOT=pathlib.Path(__file__).resolve().parents[2]
SOURCE=r'''import Foundation
@main struct Probe {
 static func main() throws {
  let state=URL(fileURLWithPath:CommandLine.arguments[1]), id=UUID(uuidString:CommandLine.arguments[2])!
  let overlay=state.appendingPathComponent("Devices/\(id.uuidString)/overlay")
  for operation in ["erase", "delete"] {
   do {
    if operation == "erase" { try DeviceStateStorage.erase(overlay:overlay,snapshots:[],state:state,owner:id) }
    else { try DeviceStateStorage.removeDevice(id,state:state) }
    fatalError("maintenance bypassed lease: \(operation)")
   } catch is CocoaError {}
  }
 }
}
'''
with tempfile.TemporaryDirectory(prefix="ltm-maintenance-") as temporary:
 folder=pathlib.Path(temporary)
 import uuid
 identity=str(uuid.uuid4()).upper()
 device=folder/'Devices'/identity
 work=device/'work';work.mkdir(parents=True)
 overlay=device/'overlay';overlay.mkdir()
 marker=overlay/'keep';marker.write_bytes(b'unchanged')
 (device/'device.json').write_text('{}')
 main=folder/'main.swift';main.write_text(SOURCE)
 executable=folder/'probe'
 subprocess.run(['xcrun','swiftc', *host_runtime.swift_flags(Path(__file__).resolve().parents[2]),'-parse-as-library',str(ROOT/'LightTouchMac/Library/DeviceStateStorage.swift'),str(main),'-o',str(executable)],check=True)
 with (work/'lease').open('wb') as owner:
  fcntl.flock(owner,fcntl.LOCK_EX|fcntl.LOCK_NB)
  subprocess.run([str(executable),str(folder),identity],check=True)
 assert marker.read_bytes()==b'unchanged'
 (work/'edit.json').write_text('{}')
 subprocess.run([str(executable),str(folder),identity],check=True)
 assert marker.read_bytes()==b'unchanged'
 print('PASS: erase and deletion refuse external lease and durable edit without modifying storage')
