#!/usr/bin/env python3
"""Exercise the production AFC streaming loop with short writes and failures."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root/'LightTouchMac/DeviceServices.swift').read_text()
loop = s[s.index('    func stage('):s.index('    /// A stable device-side filename')]
errors = s[s.index('nonisolated enum DeviceError'):s.index('// MARK: - Timeouts')]
source = r'''import Foundation
nonisolated func logEvent(_ message: String) {}
nonisolated enum Timeouts { static let stage = 300.0 }
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
 static let afc_client_start_service: ((OpaquePointer, inout OpaquePointer?, String)->Int32)? = { _, c, _ in c = OpaquePointer(bitPattern: 1); return 0 }
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
}
struct Services {
 static let stagingSession=UUID().uuidString
 static func stagingName(_ url: URL) -> String { "fixture.ipa" }
 func run<T: Sendable>(_ seconds: Double, _ label: String, _ body: @escaping @Sendable (IMobileDevice.Type, OpaquePointer) throws -> T) async throws -> T {
  try await Task.detached { try body(IMobileDevice.self, OpaquePointer(bitPattern: 1)!) }.value
 }
''' + loop + '\n}\n' + errors + r'''
@main struct Check {
 static func main() async throws {
  let path = URL(fileURLWithPath: CommandLine.arguments[1])
  let expected = Data((0..<200003).map { UInt8($0 % 251) })
  try expected.write(to: path)
  let state = IMobileDevice.state
  _ = try await Services().stage(path) { _ in }
  precondition(state.bytes == expected && !state.removed && state.closeCalls == 1)
  state.reset()
  let audio = path.deletingLastPathComponent().appendingPathComponent("audio.m4a")
  try expected.write(to: audio)
  let id = UUID().uuidString
  try await Services().stageSong(MediaSong(id:id,audio:audio)) { _ in }
  precondition(state.bytes == expected && state.destination == "LightTouch/\(id)/audio.m4a")
  precondition(state.directories == ["LightTouch","LightTouch/\(id)"])
  state.reset();state.existing=expected
  try await Services().stageSong(MediaSong(id:id,audio:audio)) { _ in }
  precondition(state.bytes.isEmpty && state.closeCalls==1 && state.existing==expected)
  state.reset();state.existing=Data("different".utf8)
  do { try await Services().stageSong(MediaSong(id:id,audio:audio)) { _ in };fatalError("mismatched media overwritten") }
  catch let error as DeviceError { precondition(!error.shouldPauseInstallQueue) }
  precondition(state.bytes.isEmpty && state.existing==Data("different".utf8) && state.closeCalls==1)
  state.reset()
  do { try await Services().stageSong(MediaSong(id:"../escape",audio:audio)) { _ in }; fatalError("invalid destination accepted") }
  catch {}
  precondition(state.destination.isEmpty)
  state.reset();state.cancelOnClose=true
  do { try await Services().stageSong(MediaSong(id:id,audio:audio)) { _ in };fatalError("cancelled upload published") }
  catch is CancellationError {}
  precondition(state.removed && state.existing == nil && state.closeCalls == 1)
  for kind in 0..<3 {
   state.reset()
   state.failure = kind == 0; state.badCount = kind == 1; state.closeFailure = kind == 2
   do { _ = try await Services().stage(path) { _ in }; fatalError("failed upload accepted") }
   catch let e as DeviceError { precondition(e.shouldPauseInstallQueue) }
   precondition(state.removed && state.closeCalls == 1)
  }
  print("PASS: app/media AFC uploads, safe destination validation, short writes and failure cleanup")
 }
}
'''
with tempfile.TemporaryDirectory() as work:
    swift=Path(work)/'check.swift'; swift.write_text(source)
    exe=Path(work)/'check'
    subprocess.run(['swiftc','-parse-as-library','-module-cache-path','/tmp/ltm-module-cache',str(swift),'-o',str(exe)],check=True)
    subprocess.run([str(exe),str(Path(work)/'fixture.ipa')],check=True)
