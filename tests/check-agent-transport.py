from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
source=(root/'LightTouchMac/DeviceTools.swift').read_text().split('private actor GuestAgentTransport {',1)[1]
source='private actor GuestAgentTransport {'+source
fixture=r'''
import Foundation
private enum DeviceToolsError: Error { case failed(String) }
private final class Bridge: @unchecked Sendable {
 static let shared=Bridge()
 let lock=NSLock()
 var status:Int32=1, hold=false, angle="90", responseStatus=0
 var pending:[String]=[], cancelled:[String]=[], operations:[String]=[]
 var ready=Date.distantPast
 func request(_ wire:String)->Bool { lock.withLock {
  let lines=wire.split(separator:"\n",maxSplits:1,omittingEmptySubsequences:false)
  let header=lines[0].split(separator:" ",maxSplits:2)
  let id=String(header[0]), op=String(header[1]);operations.append(op)
  let data:Data
  switch op {
  case "orientation":data=Data((angle+"\n").utf8)
  case "frontmost":data=Data("com.apple.mobilesafari\nSafari\n".utf8)
  case "exec":data=Data(base64Encoded:String(lines[1]))!
  default:preconditionFailure(op)
  }
  pending.insert("\(id) \(responseStatus)\n\(data.base64EncodedString())",at:0)
  ready=Date().addingTimeInterval(0.03)
  return true
 } }
}
private func qemu_ios_agent_status()->Int32 { Bridge.shared.lock.withLock { Bridge.shared.status } }
private func qemu_ios_agent_request(_ p:UnsafePointer<CChar>)->Bool { Bridge.shared.request(String(cString:p)) }
private func qemu_ios_agent_result()->UnsafeMutablePointer<CChar>? { Bridge.shared.lock.withLock {
 guard !Bridge.shared.hold, Date()>=Bridge.shared.ready, !Bridge.shared.pending.isEmpty else{return nil}
 return strdup(Bridge.shared.pending.removeFirst())
} }
private func qemu_ios_agent_free_result(_ p:UnsafeMutablePointer<CChar>){free(p)}
private func qemu_ios_agent_cancel(_ p:UnsafePointer<CChar>){Bridge.shared.lock.withLock{Bridge.shared.cancelled.append(String(cString:p))}}
private func qemu_ios_ui_ready()->Bool {true}
'''
main=r'''
@main struct Check {
 static func main() async throws {
  let transport=GuestAgentTransport.shared
  async let angle=transport.orientationIfAvailable()
  async let echo=transport.runIfAvailable("printf test",stdinPath:nil)
  let values=try await(angle,echo)
  precondition(values.0==90 && values.1==Data())
  let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let data=Data((0..<256).map{UInt8($0)})
  try data.write(to:path);defer{try? FileManager.default.removeItem(at:path)}
  let binaryEcho=try await transport.runIfAvailable("cat",stdinPath:path.path)
  precondition(binaryEcho==data)
  Bridge.shared.lock.withLock{Bridge.shared.angle="17"}
  do{_ = try await transport.orientationIfAvailable();preconditionFailure("invalid angle accepted")}
  catch is DeviceToolsError{}
  Bridge.shared.lock.withLock{Bridge.shared.status=0}
  let absent=try await transport.orientationIfAvailable();precondition(absent==nil)
  Bridge.shared.lock.withLock{Bridge.shared.status=2}
  do{_ = try await transport.orientationIfAvailable();preconditionFailure("stale agent became fallback")}
  catch is DeviceToolsError{}
  Bridge.shared.lock.withLock{Bridge.shared.status=1;Bridge.shared.hold=true}
  let task=Task{try await transport.orientationIfAvailable()}
  try await Task.sleep(for:.milliseconds(150));task.cancel()
  do{_ = try await task.value;preconditionFailure("cancelled request completed")}
  catch is CancellationError{}
  precondition(Bridge.shared.lock.withLock{Bridge.shared.cancelled.count==1})
  print("PASS: shared agent reply routing, binary exec, typed orientation, stale state and cancellation")
 }
}
'''
with tempfile.TemporaryDirectory() as temp:
 p=Path(temp);(p/'check.swift').write_text(fixture+source+main)
 subprocess.run(['swiftc','-module-cache-path',str(p/'cache'),'-swift-version','6','-parse-as-library',str(p/'check.swift'),'-o',str(p/'check')],check=True)
 subprocess.run([str(p/'check')],check=True)
