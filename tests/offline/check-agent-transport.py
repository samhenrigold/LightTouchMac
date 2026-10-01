#!/usr/bin/env python3
"""GuestAgent and GuestServices (LightTouchMac/Guest/GuestAgent.swift, GuestServices.swift) over a device's link.

The link is a stand-in with DeviceLink's surface (status, request, send). Behind it is a
fake guest that answers like contrib/it-agent's v2 ops (ping with an op list, spawn with a
NUL-separated argv and no shell, put/get/chown/unlink/sync/launch/frontmost/lockstatus/
orientation/dlicon/halt) or like a v1 agent (only `it_agent v1`, -ENOSYS for the v2 ops,
and `exec` through /bin/sh). Checked: capability detection and its cache, typed wire
formats, the v1 exec fallback with shell quoting, ENOENT handling, media commit through
the package's helper or an uploaded one (cleaned up on failure too), launch vs a locked
device, the component upgrade (agent path from its own job, never a downgrade, the host-
sequenced SpringBoard reload (loaded again after a failed write), legacy it-pbd retired with stock launchctl, and nothing on a
packaged image), halt submission, stale/absent agents and cancellation (agentCancel).
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]

fixture = r'''
import Foundation
nonisolated func logEvent(_ message: String) {}
struct SharedStatus { var agentStatus: Int }
enum DeviceLinkError: Error { case timedOut, closed(String) }
final class DeviceLink: @unchecked Sendable {
 let lock = NSLock()
 var agent = 1, hold = false, version = 2, locked = false, launchFails = false, angle = "90"
 var files: [String: Data] = [:], modes: [String: String] = [:], owners: [String: String] = [:]
 var cancelled: [String] = [], ops: [String] = [], spawns: [[String]] = [], shells: [String] = [], halts = 0
 var spawnOutput: [String: (Int, String)] = [:]
 var failPut: String?
 var waiting: [String: CheckedContinuation<LinkReply, Error>] = [:]
 var status: SharedStatus? { lock.withLock { SharedStatus(agentStatus: agent) } }
 func send(_ command: LinkCommand) {
  guard case let .agentCancel(id) = command else { return }
  let c: CheckedContinuation<LinkReply, Error>? = lock.withLock { cancelled.append(id); return waiting.removeValue(forKey: id) }
  c?.resume(returning: .agent(nil))
 }
 static let v2ops = ["exec", "spawn", "sync", "put", "get", "chown", "unlink", "launch", "frontmost", "lockstatus", "orientation", "dlicon", "halt"]
 func answer(_ op: String, _ args: String, _ body: Data) -> (Int, Data) {
  let v2only: Set<String> = ["spawn", "sync", "chown", "unlink", "dlicon"]
  if version == 1 && v2only.contains(op) { return (-78, Data()) }
  switch op {
  case "ping": return (0, Data((version == 2 ? "it_agent v2\nops ping " + Self.v2ops.joined(separator: " ") + "\n" : "it_agent v1\n").utf8))
  case "spawn":
   precondition(body.last == 0, "argv is NUL-terminated")
   let argv = body.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
   spawns.append(argv)
   precondition(argv[0].hasPrefix("/"), "argv[0] absolute")
   if let (status, out) = spawnOutput[argv[0]] { return (status, Data(out.utf8)) }
   if argv[0].hasPrefix("/tmp/") && files[argv[0]] == nil { return (-2, Data()) }
   if argv[0].hasPrefix("/usr/local/lighttouch/") && files[argv[0]] == nil { return (-2, Data()) }
   return (0, Data())
  case "exec": shells.append(args); return (0, Data())
  case "sync": return (0, Data())
  case "put":
   let words = args.split(separator: " ")
   let path = words.dropLast().joined(separator: " ")
   if path == failPut { return (-28, Data()) }
   files[path] = body; modes[path] = String(words.last!); owners[path] = "0:0"
   return (0, Data())
  case "get": return files[args].map { (0, $0) } ?? (-2, Data())
  case "chown":
   let w = args.split(separator: " ", maxSplits: 2).map(String.init)
   owners[w[2]] = w[0] + ":" + w[1]; return (0, Data())
  case "unlink": return files.removeValue(forKey: args) == nil ? (-2, Data()) : (0, Data())
  case "launch": return launchFails ? (-1, Data()) : (0, Data())
  case "lockstatus": return (0, Data("locked=\(locked ? 1 : 0) passcode=0\n".utf8))
  case "frontmost": return (0, Data((locked ? "com.apple.springboard\nLock Screen\n" : "com.example.game\nGame\n").utf8))
  case "orientation": return (0, Data((angle + "\n").utf8))
  case "dlicon": return (0, Data())
  default: preconditionFailure(op)
  }
 }
 func request(_ request: LinkRequest, timeout: TimeInterval = 10) async throws -> LinkReply {
  guard case let .agent(wire, deadline) = request else { fatalError() }
  let lines = wire.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
  let header = lines[0].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
  let id = String(header[0]), op = String(header[1]), args = header.count > 2 ? String(header[2]) : ""
  let body = Data(base64Encoded: String(lines[1]))!
  lock.withLock { ops.append(op) }
  if deadline <= 0 { precondition(op == "halt"); lock.withLock { halts += 1 }; return .ok(true) }
  let (status, data) = lock.withLock { answer(op, args, body) }
  let reply = "\(id) \(status)\n\(data.base64EncodedString())"
  return try await withCheckedThrowingContinuation { c in
   let held: Bool = lock.withLock { waiting[id] = c; return hold }
   guard !held else { return }
   DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
    let c: CheckedContinuation<LinkReply, Error>? = self.lock.withLock { self.waiting.removeValue(forKey: id) }
    c?.resume(returning: .agent(reply))
   }
  }
 }
}
'''
main = r'''
func check(_ ok: Bool, _ message: String = "") { precondition(ok, message) }
func expectFailure(_ what: String, _ body: () async throws -> Void) async {
 do { try await body(); preconditionFailure(what) } catch {}
}
@main struct Check {
 static func main() async throws {
  let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: tmp) }
  func local(_ name: String, _ data: Data) throws -> URL { let u = tmp.appendingPathComponent(name); try data.write(to: u); return u }

  // v2: typed ops, capabilities cached.
  let link = DeviceLink()
  let cache = GuestAgentCache()
  let agent = GuestAgent(link: link, cache: cache)
  try await agent.spawn(["/bin/launchctl", "stop", "com.apple.SpringBoard"])
  try await agent.sync()
  precondition(link.spawns == [["/bin/launchctl", "stop", "com.apple.SpringBoard"]] && link.shells.isEmpty)
  precondition(link.ops.filter { $0 == "ping" }.count == 1, "the ping is cached")
  precondition(cache.capabilities?.version == 2 && cache.capabilities!.has("dlicon"))
  try await agent.put("/tmp/a b", mode: 0o644, Data("x".utf8))
  precondition(link.files["/tmp/a b"] == Data("x".utf8) && link.modes["/tmp/a b"] == "644", "mode is octal, the last word")
  check(try await agent.get("/nope") == nil, "ENOENT is absent")
  try await agent.unlink("/nope")
  try await agent.chown(501, 501, "/tmp/a b"); precondition(link.owners["/tmp/a b"] == "501:501")
  check(try await agent.placeholder("add", id: "qemu-install-x", bundleID: "com.x"))
  let front = try await agent.frontmost()
  precondition(front.bundleID == "com.example.game" && front.name == "Game")
  check(try await agent.orientation() == 90)
  link.angle = "17"
  await expectFailure("invalid angle accepted") { _ = try await agent.orientation() }
  link.angle = "90"

  // v1: the same calls through exec, shell-quoted; no dlicon.
  let old = DeviceLink(); old.version = 1
  let v1 = GuestAgent(link: old, cache: GuestAgentCache())
  try await v1.spawn(["/bin/launchctl", "stop", "it's"])
  try await v1.unlink("/tmp/x y"); try await v1.chown(501, 501, "/var/mobile/Media/LightTouch"); try await v1.sync()
  precondition(old.shells == ["'/bin/launchctl' 'stop' 'it'\\''s'", "rm -f '/tmp/x y'", "chown 501:501 '/var/mobile/Media/LightTouch'", "sync"], "\(old.shells)")
  precondition(old.spawns.isEmpty && !old.ops.contains("spawn"), "a v1 agent is never sent a v2 op")
  check(try await v1.placeholder("add", id: "x") == false && !old.ops.contains("dlicon"))

  // Media commit: an uploaded helper on a legacy image, removed afterwards.
  let id = UUID().uuidString
  let helper = try local("itphoto", Data("helper".utf8))
  link.spawnOutput["/tmp/ltm-itphoto-\(id)"] = (0, "imported\n")
  let legacy = GuestServices(agent: agent)
  check(try await legacy.commitMedia(id: id, helper: "itphoto", localHelper: { helper }, metadata: nil))
  precondition(link.spawns.last == ["/tmp/ltm-itphoto-\(id)", id] && link.files["/tmp/ltm-itphoto-\(id)"] == nil)
  precondition(link.owners["/var/mobile/Media/LightTouch/\(id)"] == "501:501")
  // An older package's executable must never silently discard new fields.
  let packaged = GuestServices(agent: agent, packaged: true)
  let plist = try local("m.plist", Data("<plist/>".utf8))
  let music = try local("itmedia", Data("current media helper".utf8))
  link.spawnOutput["/usr/local/lighttouch/current/bin/itmedia"] = (0, "imported\n")
  link.spawnOutput["/tmp/ltm-itmedia-\(id)"] = (0, "imported\n")
  check(try await packaged.commitMedia(id: id, helper: "itmedia", localHelper: { music }, metadata: plist))
  precondition(link.spawns.last == ["/tmp/ltm-itmedia-\(id)", "/tmp/ltm-media-\(id).plist", id])
  precondition(!link.spawns.contains { $0.first == "/usr/local/lighttouch/current/bin/itmedia" })
  precondition(link.files["/tmp/ltm-media-\(id).plist"] == nil, "metadata removed")
  // ... and a failing helper still cleans up, and the error surfaces.
  link.spawnOutput["/tmp/ltm-itmedia-\(id)"] = (3, "no library")
  await expectFailure("failed commit succeeded") { _ = try await legacy.commitMedia(id: id, helper: "itmedia", localHelper: { music }, metadata: plist) }
  precondition(link.files.keys.allSatisfy { !$0.hasPrefix("/tmp/ltm-") }, "\(link.files.keys)")
  link.spawnOutput["/tmp/ltm-itmedia-\(id)"] = (0, "partial\n")
  check(try await legacy.commitMedia(id: id, helper: "itmedia", localHelper: { music }, metadata: plist) == false)

  // Launch: a refusal on a locked device is .locked, otherwise .failed.
  try await legacy.launch("com.example.game")
  link.launchFails = true; link.locked = true
  do { try await legacy.launch("com.example.game"); preconditionFailure() } catch AppLaunchError.locked {}
  link.locked = false
  do { try await legacy.launch("com.example.game"); preconditionFailure() } catch AppLaunchError.failed {}
  link.launchFails = false
  try await legacy.respring(); precondition(link.spawns.last == ["/bin/launchctl", "stop", "com.apple.SpringBoard"])
  try await legacy.reconnectManagement(); precondition(link.spawns.last == ["/bin/launchctl", "stop", "com.apple.mobile.lockdown"])

  // Time zone: 4.x locationd's record of its first external zone is cleared with locationd unloaded, the rest
  // of its cache kept; no record, no cache: nothing touched (smoke #58).
  let tzCache = "/var/root/Library/Caches/locationd/cache.plist", tzJob = "/System/Library/LaunchDaemons/com.apple.locationd.plist"
  link.files[tzCache] = try PropertyListSerialization.data(fromPropertyList: ["PreviousTimeZone": "America/New_York", "TimeZoneBorderDistance": 12.5], format: .binary, options: 0)
  let spawnsBefore = link.spawns.count, opsBefore = link.ops.count
  check(try await legacy.forgetExternalTimeZone(), "a record to clear")
  precondition(Array(link.spawns.dropFirst(spawnsBefore)) == [["/bin/launchctl", "unload", tzJob], ["/bin/launchctl", "load", tzJob]], "\(link.spawns)")
  let tzOps = Array(link.ops.dropFirst(opsBefore))
  precondition(tzOps.firstIndex(of: "put")! > tzOps.firstIndex(of: "spawn")! && tzOps.lastIndex(of: "spawn")! > tzOps.firstIndex(of: "put")!, "written while locationd is unloaded: \(tzOps)")
  let cleared = try PropertyListSerialization.propertyList(from: link.files[tzCache]!, format: nil) as! [String: Any]
  precondition(cleared["PreviousTimeZone"] == nil && cleared["TimeZoneBorderDistance"] as? Double == 12.5, "\(cleared)")
  check(try await legacy.forgetExternalTimeZone() == false && link.spawns.count == spawnsBefore + 2, "no record: locationd left running")
  link.files[tzCache] = nil
  check(try await legacy.forgetExternalTimeZone() == false && link.spawns.count == spawnsBefore + 2, "no cache: nothing")

  // Halt: submitted with deadline 0; absent and stale agents.
  check(await agent.requestHalt() && link.halts == 1)
  link.agent = 0
  check(await agent.requestHalt() == false)
  await expectFailure("absent agent answered") { _ = try await agent.frontmost() }
  check(await agent.waitAlive(seconds: 0.3) == false)
  link.agent = 2
  await expectFailure("stale agent answered") { _ = try await agent.orientation() }
  let none = GuestAgent(link: nil, cache: GuestAgentCache())
  precondition(none.status == 0 && !none.isAlive)

  // Cancellation sends agentCancel and ends the request.
  link.agent = 1; link.hold = true
  let task = Task { try await agent.orientation() }
  try await Task.sleep(for: .milliseconds(150)); task.cancel()
  do { _ = try await task.value; preconditionFailure("cancelled request completed") } catch is CancellationError {}
  precondition(link.cancelled.count == 1)
  precondition(GuestAgentCapabilities.parse("it_agent v1\n") == GuestAgentCapabilities(version: 1, ops: []))
  precondition(GuestAgentCapabilities.parse("nonsense") == nil)
  print("PASS: v2 typed ops and cached capabilities, v1 exec fallback with quoting, media commit (package, upload, cleanup), launch/lock, component upgrade (job path, no downgrade, SpringBoard reload even after a failed write, it-pbd, packaged no-op), locationd's first-zone record cleared, halt, stale/absent, cancellation")
 }
}
'''
with tempfile.TemporaryDirectory() as temp:
    p = Path(temp)
    (p / 'check.swift').write_text(fixture + main)
    subprocess.run(['swiftc', *host_runtime.swift_flags(Path(__file__).resolve().parents[2]), '-module-cache-path', str(p / 'cache'), '-swift-version', '5', '-default-isolation', 'MainActor', '-parse-as-library',
                    str(root / 'Shared/DeviceLinkProtocol.swift'), str(root / 'LightTouchMac/Device/DeviceProfile.swift'),
                    str(root / 'LightTouchMac/Guest/GuestServices.swift'), str(root / 'LightTouchMac/Guest/GuestAgent.swift'),
                    str(root / 'LightTouchMac/Transport/DeviceExecution.swift'), str(p / 'check.swift'), '-o', str(p / 'check')], check=True)
    subprocess.run([str(p / 'check')], check=True, timeout=60)
