#!/usr/bin/env python3
"""Exercise the production AFC streaming loop with short writes and failures, and the staging names a late
startup sweep may remove. Compiles Services/AFC.swift and Transport/DeviceExecution.swift whole, against a fake
libimobiledevice and a DeviceServices whose run kernel calls straight through."""
from pathlib import Path
from host_service_fixtures import leaves, local_engine_stub
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
app = root / 'LightTouchMac'
source = r'''import Foundation
nonisolated func logEvent(_ message: String) {}
struct MediaVideo: Sendable { let id: String; let video: URL }
struct MediaPhoto: Sendable { let id: String; let image: URL }
struct MediaSong: Sendable {
 let id: String
 let audio: URL
 static let extensions: Set<String> = ["mp3", "m4a", "wav"]
}
final class State: @unchecked Sendable {
 let lock = NSLock()
 var existing: Data?, readOffset = 0
 var bytes = Data(), removed = false, closeCalls = 0
 var destination = "", directories: [String] = []
 var cancelOnClose = false
 var failure = false, badCount = false, closeFailure = false
 func reset() { lock.withLock { bytes = Data(); cancelOnClose = false; existing = nil; readOffset = 0; destination = ""; directories = []; removed = false; closeCalls = 0; failure = false; badCount = false; closeFailure = false } }
}
nonisolated enum IMobileDevice {
 static let state = State(), success: Int32 = 0, afcWriteMode: UInt64 = 3
 static func startService(_ name: String, device: OpaquePointer, newClient: Int?, freeClient: ((OpaquePointer)->Int32)?,
                          connectError: (Int32) -> Error) throws -> OpaquePointer {
  precondition(name == "com.apple.afc"); return OpaquePointer(bitPattern: 1)!
 }
 static let afc_client_new: Int? = 0
 static let afc_make_directory: ((OpaquePointer, UnsafePointer<CChar>)->Int32)? = { _,p in state.directories.append(String(cString:p)); return 0 }
 static let afc_file_open: ((OpaquePointer, UnsafePointer<CChar>, UInt64, inout UInt64)->Int32)? = { _,p,mode,h in
  if mode == 1 { guard state.existing != nil else{return 8};state.readOffset=0;h=2;return 0 }
  state.destination = String(cString:p);h=1;return 0
 }
 static let afc_file_read: ((OpaquePointer, UInt64, UnsafeMutablePointer<CChar>, UInt32, inout UInt32)->Int32)? = { _,_,p,n,count in
  guard let bytes=state.existing else{return 8}
  count=UInt32(min(Int(n),bytes.count-state.readOffset,317))
  bytes.withUnsafeBytes { raw in
   if count>0 { UnsafeMutableRawPointer(p).copyMemory(from:raw.baseAddress!.advanced(by:state.readOffset),byteCount:Int(count)) }
  }
  state.readOffset+=Int(count);return 0
 }
 static let afc_rename_path: ((OpaquePointer, UnsafePointer<CChar>, UnsafePointer<CChar>)->Int32)? = { _,_,p in
  state.destination=String(cString:p);state.existing=state.bytes;return 0
 }
 static let afc_file_write: ((OpaquePointer, UInt64, UnsafePointer<CChar>, UInt32, inout UInt32)->Int32)? = { _,_,p,n,w in
  state.lock.withLock {
   if state.failure && !state.bytes.isEmpty { return 1 }
   if state.badCount { w = n+1; return 0 }
   w = min(n, 317); state.bytes.append(UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), count: Int(w)); return 0
  }
 }
 static let afc_file_close: ((OpaquePointer, UInt64)->Int32)? = { _,_ in state.lock.withLock { state.closeCalls += 1;if state.cancelOnClose { withUnsafeCurrentTask { $0?.cancel() } };return state.closeFailure ? 20 : 0 } }
 static let afc_remove_path: ((OpaquePointer, UnsafePointer<CChar>)->Int32)? = { _,_ in state.lock.withLock { state.removed=true;return 0 } }
 static let afc_client_free: ((OpaquePointer)->Int32)? = { _ in 0 }
 // Not reached by these uploads (free space, the sweep's and the browser's listings).
 static let afc_get_device_info_key: ((OpaquePointer, UnsafePointer<CChar>, inout UnsafeMutablePointer<CChar>?)->Int32)? = { _,_,_ in 8 }
 static let afc_read_directory: ((OpaquePointer, UnsafePointer<CChar>, inout UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?)->Int32)? = { _,_,_ in 8 }
 static let afc_get_file_info: ((OpaquePointer, UnsafePointer<CChar>, inout UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?)->Int32)? = { _,_,_ in 8 }
 static let afc_dictionary_free: ((UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>)->Int32)? = { _ in 0 }
}
struct DeviceServices {
 func run<T: Sendable>(_ seconds: Double, _ label: String, _ body: @escaping @Sendable (IMobileDevice.Type, OpaquePointer) throws -> T) async throws -> T {
  try await Task.detached { try body(IMobileDevice.self, OpaquePointer(bitPattern: 1)!) }.value
 }
}
func stagingNames() {
  let file=URL(fileURLWithPath:"/tmp/Temple Run.ipa")
  let first=DeviceServices.stagingName(file), second=DeviceServices.stagingName(file)
  precondition(first != second)
  let old="Temple_Run-01234567.ipa"
  // Simulate the directory listing returning after both new uploads started.
  let removed=[old,first,second,".","..","../escape",""].filter(DeviceServices.isOrphanedStagingName)
  precondition(removed == [old])
  precondition(!first.contains("/"))
  let uuid=UUID().uuidString
  precondition(DeviceServices.isOrphanedMediaUpload("audio.m4a.upload-"+uuid))
  precondition(DeviceServices.isOrphanedMediaUpload("image.jpg.upload-"+uuid+"-"+UUID().uuidString))
  precondition(!DeviceServices.isOrphanedMediaUpload("audio.m4a.upload-"+DeviceServices.stagingSession+"-"+uuid))
  for name in ["audio.m4a","image.jpg",".photo-receipt","song.json","audio.m4a.upload-invalid","../image.jpg.upload-"+uuid] {
   precondition(!DeviceServices.isOrphanedMediaUpload(name),name)
  }
}
@main struct Check {
 static func main() async throws {
  let path = URL(fileURLWithPath: CommandLine.arguments[1])
  let expected = Data((0..<200003).map { UInt8($0 % 251) })
  try expected.write(to: path)
  let state = IMobileDevice.state
  _ = try await DeviceServices().stage(path) { _ in }
  precondition(state.bytes == expected && !state.removed && state.closeCalls == 1)
  state.reset()
  let audio = path.deletingLastPathComponent().appendingPathComponent("audio.m4a")
  try expected.write(to: audio)
  let id = UUID().uuidString
  try await DeviceServices().stageSong(MediaSong(id:id,audio:audio)) { _ in }
  precondition(state.bytes == expected && state.destination == "LightTouch/\(id)/audio.m4a")
  precondition(state.directories == ["LightTouch","LightTouch/\(id)"])
  state.reset();state.existing=expected
  try await DeviceServices().stageSong(MediaSong(id:id,audio:audio)) { _ in }
  precondition(state.bytes.isEmpty && state.closeCalls==1 && state.existing==expected)
  state.reset();state.existing=Data("different".utf8)
  do { try await DeviceServices().stageSong(MediaSong(id:id,audio:audio)) { _ in };fatalError("mismatched media overwritten") }
  catch let error as DeviceError { precondition(!error.shouldPauseInstallQueue) }
  precondition(state.bytes.isEmpty && state.existing==Data("different".utf8) && state.closeCalls==1)
  state.reset()
  do { try await DeviceServices().stageSong(MediaSong(id:"../escape",audio:audio)) { _ in }; fatalError("invalid destination accepted") }
  catch {}
  precondition(state.destination.isEmpty)
  state.reset()
  let video = path.deletingLastPathComponent().appendingPathComponent("video.m4v")
  try expected.write(to: video)
  try await DeviceServices().stageVideo(MediaVideo(id:id,video:video)) { _ in }
  precondition(state.bytes == expected && state.destination == "LightTouch/\(id)/video.m4v")
  state.reset();state.existing=expected
  try await DeviceServices().stageVideo(MediaVideo(id:id,video:video)) { _ in }
  precondition(state.bytes.isEmpty && state.existing == expected)
  state.reset()
  do { try await DeviceServices().stageVideo(MediaVideo(id:id,video:audio)) { _ in };fatalError("invalid movie path accepted") }
  catch {}
  precondition(state.destination.isEmpty)
  state.reset();state.cancelOnClose=true
  do { try await DeviceServices().stageSong(MediaSong(id:id,audio:audio)) { _ in };fatalError("cancelled upload published") }
  catch is CancellationError {}
  precondition(state.removed && state.existing == nil && state.closeCalls == 1)
  for kind in 0..<3 {
   state.reset()
   state.failure = kind == 0; state.badCount = kind == 1; state.closeFailure = kind == 2
   do { _ = try await DeviceServices().stage(path) { _ in }; fatalError("failed upload accepted") }
   catch let e as DeviceError { precondition(e.shouldPauseInstallQueue) }
   precondition(state.removed && state.closeCalls == 1)
  }
  stagingNames()
  print("PASS: app/media AFC uploads, safe destination validation, short writes and failure cleanup; late sweeps preserve active uploads, canonical media and receipts")
 }
}
'''
with tempfile.TemporaryDirectory() as work:
    swift=Path(work)/'check.swift'; swift.write_text(source)
    exe=Path(work)/'check'
    subprocess.run(['swiftc', *leaves(root), *local_engine_stub(Path(work)),'-parse-as-library','-module-cache-path','/tmp/ltm-module-cache',str(app/'Services/AFC.swift'), str(app/'Services/MediaStaging.swift'),
                    str(app/'Transport/DeviceExecution.swift'),str(swift),'-o',str(exe)],check=True)
    subprocess.run([str(exe),str(Path(work)/'fixture.ipa')],check=True)
