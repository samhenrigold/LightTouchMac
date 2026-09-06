#!/usr/bin/env python3
"""Actual Swift AFC browsing/import/export against an owned disposable guest."""
from pathlib import Path
from types import SimpleNamespace
import os, subprocess, sys, tempfile, time
APP=Path(__file__).resolve().parents[1]
ROOT=APP.parent/'qemu-ios'
sys.path.insert(0,str(ROOT/'tests/ipod'))
import regress as r
out=Path(tempfile.mkdtemp(prefix='ltm-files-native-'))
swift=r'''import Foundation
nonisolated func logEvent(_ message: String) { print(message) }
struct InstalledApp: Sendable { let id, name, version: String }
struct MediaPhoto: Sendable { let id: String; let image: URL }
struct MediaSong: Sendable { let id: String; let audio: URL; static let extensions: Set<String> = ["m4a"] }
nonisolated enum Bundled { static var frameworksDirectory: String? { CommandLine.arguments[2] } }
func tryEqual(_ url:URL,_ bytes:Data)->Bool { (try? Data(contentsOf:url))==bytes }
@main struct Check {
 static func main() async throws {
  let service=DeviceServices(clientSocket:CommandLine.arguments[1])
  let directory=URL(fileURLWithPath:CommandLine.arguments[3])
  for bad in ["/etc", "../etc", "foo/../bar", "foo//bar", "x\0y", "."] {
   do { try DeviceServices.validateFilePath(bad); fatalError("invalid path accepted") } catch {}
  }
  let bytes=Data((0..<200003).map { UInt8($0 % 251) })
  let source=directory.appendingPathComponent("Quoted ' $ été.bin")
  try bytes.write(to:source)
  try await service.uploadFile(source,into:"FilesCheck") { _ in }
  try await service.uploadFile(source,into:"FilesCheck") { _ in }
  let root=try await service.files(in:"")
  precondition(root.contains{$0.name == "FilesCheck" && $0.isDirectory})
  let files=try await service.files(in:"FilesCheck")
  precondition(files.count==1 && files[0].isRegular && files[0].size==bytes.count)
  let empty=directory.appendingPathComponent("empty.bin")
  try Data().write(to:empty)
  try await service.uploadFile(empty,into:"FilesCheck") { _ in }
  let updated=try await service.files(in:"FilesCheck")
  let emptyFile=updated.first{$0.name=="empty.bin"}!
  precondition(emptyFile.isRegular && emptyFile.size==0)
  try await service.download(emptyFile,to:directory.appendingPathComponent("empty-export.bin")) { _ in }
  let destination=directory.appendingPathComponent("export.bin")
  try Data("existing host file".utf8).write(to:destination)
  try await service.download(files[0],to:destination) { _ in }
  precondition(tryEqual(destination,bytes))
  let sentinel=Data("keep existing host data".utf8)
  try sentinel.write(to:destination)
  do {
   try await service.download(files[0],to:destination) { _ in withUnsafeCurrentTask { $0?.cancel() } }
   fatalError("cancelled export published")
  } catch is CancellationError {}
  precondition(tryEqual(destination,sentinel))
  try bytes.write(to:destination)
  let changed=DeviceFile(name:files[0].name,path:files[0].path,isDirectory:false,isRegular:true,size:1)
  do { try await service.download(changed,to:destination) { _ in };fatalError("size mismatch accepted") } catch {}
  precondition(tryEqual(destination,bytes))
  try Data("different".utf8).write(to:source)
  do { try await service.uploadFile(source,into:"FilesCheck") { _ in };fatalError("device file replaced") } catch {}
  try await service.download(files[0],to:destination) { _ in }
  precondition(tryEqual(destination,bytes))
  let names=try FileManager.default.contentsOfDirectory(atPath:directory.path)
  precondition(names.allSatisfy{!$0.hasPrefix(".LightTouch-")})
  let free=try await service.freeSpaceBytes();precondition(free>0)
  print("PASS: native AFC listing, binary import/export, duplicate import, mismatch preservation and temporary cleanup")
 }
}
'''
(out/'check.swift').write_text(swift)
subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor',
 '-module-cache-path',str(out/'modules'),*[str(APP/'LightTouchMac'/f'{name}.swift') for name in ['DeviceServices','DeviceFiles','IMobileDevice']],
 str(out/'check.swift'),'-o',str(out/'check')],check=True)
files=APP.parent/'qemu-ios-files'
cfg=SimpleNamespace(out=str(out),files=str(files),base_nand=str(files/'nand-agent-v4'),nor=str(files/'ios3/nor_7E18.bin'),overlay=str(out/'overlay'),
 qemu=str(ROOT/'build-native14/qemu-build/qemu-system-arm'),usbmuxd=str(ROOT/'build-native14/build/usbmuxd/src/usbmuxd'),usbmuxd_ok=True,
 usb_port=r.free_port(1520,1539),mux_port=r.free_port(27400,27419),qmp_port=r.free_port(28200,28219),wifi=False,cpu=None,mem='128M')
p=r.Procs();d=r.Device(cfg,p,"files");r.START=time.time()
os.environ['PATH']=str(APP.parent/'qemu-ios-deps12/bin')+':'+os.environ['PATH']
print('OUTPUT',out,flush=True)
try:
 d.start()
 ok,detail,_=d.wait_for_home(240);assert ok,detail
 udid,detail=r.wait_for_device(cfg,timeout=120);assert udid,detail
 subprocess.run([str(out/'check'),'127.0.0.1:'+str(cfg.mux_port),str(ROOT/'build-native14/Light Touch-latest.app/Contents/Frameworks'),str(out)],check=True,timeout=180)
 d.powerdown()
finally:
 if d.qmp:d.qmp.close()
 p.stop_all()
