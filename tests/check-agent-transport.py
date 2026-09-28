#!/usr/bin/env python3
"""GuestAgentTransport over a device's link: reply parsing, binary exec, typed
orientation, stale/absent agents, the halt submit, and cancellation (agentCancel).

The link is a stand-in with DeviceLink's surface (status, request, send) that
answers like LightTouchDevice's AgentDispatcher, including `.agent(nil)` on cancel.
"""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
source=(root/'LightTouchMac/DeviceTools.swift').read_text().split('private struct GuestAgentTransport: Sendable {',1)[1]
source='private struct GuestAgentTransport: Sendable {'+source
fixture=r'''
import Foundation
private enum DeviceToolsError: Error { case failed(String) }
struct SharedStatus { var agentStatus: Int }
enum DeviceLinkError: Error { case timedOut, closed(String) }
final class DeviceLink: @unchecked Sendable {
 let lock=NSLock()
 var agent=1, hold=false, angle="90", responseStatus=0
 var cancelled:[String]=[], operations:[String]=[], halts=0
 var waiting:[String:CheckedContinuation<LinkReply,Error>]=[:]
 var status: SharedStatus? { lock.withLock { SharedStatus(agentStatus: agent) } }
 func send(_ command: LinkCommand) {
  guard case let .agentCancel(id) = command else { return }
  let c: CheckedContinuation<LinkReply,Error>? = lock.withLock { cancelled.append(id); return waiting.removeValue(forKey: id) }
  c?.resume(returning: .agent(nil))
 }
 func request(_ request: LinkRequest, timeout: TimeInterval = 10) async throws -> LinkReply {
  guard case let .agent(wire, deadline) = request else { fatalError() }
  let lines=wire.split(separator:"\n",maxSplits:1,omittingEmptySubsequences:false)
  let header=lines[0].split(separator:" ",maxSplits:2)
  let id=String(header[0]), op=String(header[1])
  lock.withLock { operations.append(op) }
  if deadline <= 0 { precondition(op == "halt"); lock.withLock { halts += 1 }; return .ok(true) }
  let data:Data
  switch op {
  case "orientation":data=Data((lock.withLock{angle}+"\n").utf8)
  case "exec":data=Data(base64Encoded:String(lines[1]))!
  default:preconditionFailure(op)
  }
  let reply = "\(id) \(lock.withLock{responseStatus})\n\(data.base64EncodedString())"
  return try await withCheckedThrowingContinuation { c in
   let held: Bool = lock.withLock { waiting[id] = c; return hold }
   guard !held else { return }
   DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) {
    let c: CheckedContinuation<LinkReply,Error>? = self.lock.withLock { self.waiting.removeValue(forKey: id) }
    c?.resume(returning: .agent(reply))
   }
  }
 }
}
'''
main=r'''
@main struct Check {
 static func main() async throws {
  let link=DeviceLink()
  let transport=GuestAgentTransport(link: link)
  async let angle=transport.orientationIfAvailable()
  async let echo=transport.runIfAvailable("printf test",stdinPath:nil)
  let values=try await(angle,echo)
  precondition(values.0==90 && values.1==Data())
  let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let data=Data((0..<256).map{UInt8($0)})
  try data.write(to:path);defer{try? FileManager.default.removeItem(at:path)}
  let binaryEcho=try await transport.runIfAvailable("cat",stdinPath:path.path)
  precondition(binaryEcho==data)
  link.lock.withLock{link.responseStatus=3}
  do{_ = try await transport.runIfAvailable("false",stdinPath:nil);preconditionFailure("failed command succeeded")}
  catch is DeviceToolsError{}
  link.lock.withLock{link.responseStatus=0;link.angle="17"}
  do{_ = try await transport.orientationIfAvailable();preconditionFailure("invalid angle accepted")}
  catch is DeviceToolsError{}
  let halted=await transport.requestHaltIfAvailable()
  precondition(halted && link.lock.withLock{link.halts}==1)
  link.lock.withLock{link.agent=0}
  let absent=try await transport.orientationIfAvailable();precondition(absent==nil)
  let noHalt=await transport.requestHaltIfAvailable();precondition(!noHalt)
  let fallback=try await transport.runIfAvailable("true",stdinPath:nil)
  precondition(fallback==nil, "no agent: the caller falls back to SSH")
  link.lock.withLock{link.agent=2}
  do{_ = try await transport.orientationIfAvailable();preconditionFailure("stale agent became fallback")}
  catch is DeviceToolsError{}
  let none=GuestAgentTransport(link: nil)
  let noLink=try await none.orientationIfAvailable();precondition(noLink==nil && none.status==0)
  link.lock.withLock{link.agent=1;link.hold=true;link.angle="90"}
  let task=Task{try await transport.orientationIfAvailable()}
  try await Task.sleep(for:.milliseconds(150));task.cancel()
  do{_ = try await task.value;preconditionFailure("cancelled request completed")}
  catch is CancellationError{}
  precondition(link.lock.withLock{link.cancelled.count==1})
  print("PASS: per-link agent reply routing, binary exec, failures, typed orientation, halt submit, stale state and cancellation")
 }
}
'''
with tempfile.TemporaryDirectory() as temp:
 p=Path(temp);(p/'check.swift').write_text(fixture+source+main)
 subprocess.run(['swiftc','-module-cache-path',str(p/'cache'),'-swift-version','6','-parse-as-library',
                 str(root/'Shared/DeviceLinkProtocol.swift'),str(p/'check.swift'),'-o',str(p/'check')],check=True)
 subprocess.run([str(p/'check')],check=True)
