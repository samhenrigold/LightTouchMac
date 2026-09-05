#!/usr/bin/env python3
"""Exercise the production AFC streaming loop with short writes and failures."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root/'LightTouchMac/DeviceServices.swift').read_text()
loop = s[s.index('    func stage('):s.index('    /// A stable device-side filename')]
errors = s[s.index('nonisolated enum DeviceError'):s.index('// MARK: - Timeouts')]
source = r'''import Foundation
nonisolated enum Timeouts { static let stage = 300.0 }
final class State: @unchecked Sendable {
 let lock = NSLock()
 var bytes = Data(), removed = false, closeCalls = 0
 var failure = false, badCount = false, closeFailure = false
 func reset() { lock.withLock { bytes = Data(); removed = false; closeCalls = 0; failure = false; badCount = false; closeFailure = false } }
}
nonisolated enum IMobileDevice {
 static let state = State(), success: Int32 = 0, afcWriteMode: UInt64 = 3
 static let afc_client_start_service: ((OpaquePointer, inout OpaquePointer?, String)->Int32)? = { _, c, _ in c = OpaquePointer(bitPattern: 1); return 0 }
 static let afc_make_directory: ((OpaquePointer, UnsafePointer<CChar>)->Int32)? = { _,_ in 0 }
 static let afc_file_open: ((OpaquePointer, UnsafePointer<CChar>, UInt64, inout UInt64)->Int32)? = { _,_,_,h in h=1;return 0 }
 static let afc_file_write: ((OpaquePointer, UInt64, UnsafePointer<CChar>, UInt32, inout UInt32)->Int32)? = { _,_,p,n,w in
  state.lock.withLock {
   if state.failure && !state.bytes.isEmpty { return 1 }
   if state.badCount { w = n+1; return 0 }
   w = min(n, 317); state.bytes.append(UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), count: Int(w)); return 0
  }
 }
 static let afc_file_close: ((OpaquePointer, UInt64)->Int32)? = { _,_ in state.lock.withLock { state.closeCalls += 1;return state.closeFailure ? 20 : 0 } }
 static let afc_remove_path: ((OpaquePointer, UnsafePointer<CChar>)->Int32)? = { _,_ in state.lock.withLock { state.removed=true;return 0 } }
 static let afc_client_free: ((OpaquePointer)->Int32)? = { _ in 0 }
}
struct Services {
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
  for kind in 0..<3 {
   state.reset()
   state.failure = kind == 0; state.badCount = kind == 1; state.closeFailure = kind == 2
   do { _ = try await Services().stage(path) { _ in }; fatalError("failed upload accepted") }
   catch let e as DeviceError { precondition(e.shouldPauseInstallQueue) }
   precondition(state.removed && state.closeCalls == 1)
  }
  print("PASS: streamed AFC bytes survive short writes; write/count/close errors reject and clean partial files")
 }
}
'''
with tempfile.TemporaryDirectory() as work:
    swift=Path(work)/'check.swift'; swift.write_text(source)
    exe=Path(work)/'check'
    subprocess.run(['swiftc','-parse-as-library','-module-cache-path','/tmp/ltm-module-cache',str(swift),'-o',str(exe)],check=True)
    subprocess.run([str(exe),str(Path(work)/'fixture.ipa')],check=True)
