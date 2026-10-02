#!/usr/bin/env python3
"""The shared session owner classifies a helper's death by what was asked of it, not by which message won the exit race.

The imported DeviceRuntime classification runs without replacement link/owner types, and Shared/DeviceSessionProcess.swift,
compiled whole, runs against a fake link whose exit report arrives one reap retry (10 ms) after the helper dies (the
race through the real owner: boot, then Stop or a crash). The actual imported LinkChannel also drains a last frame before close. A requested stop whose qemuExited
event was lost (the helper exited before sending it: DeviceHost.halt racing QEMU's own SIGTERM handler) is still
"The iPod stopped."; a crash or kill nobody asked for is "stopped unexpectedly" (the code and signal go to the log)."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import device_runtime
import host_runtime
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
source = r'''import Foundation
import DeviceRuntime
nonisolated func logEvent(_ message: String) {}
nonisolated enum Bundled { static var logsDirectory: URL { FileManager.default.temporaryDirectory } }
@main struct Main {
 @MainActor static func main() {
  let cases: [(DeviceLinkError?, Int32?, Bool, DeviceTermination, DeviceProcessDeath)] = [
   (nil, 0, true, .exited(0), .stopped),
   (nil, nil, true, .exited(0), .stopped),
   (nil, nil, false, .exited(0), .unexpected),
   (nil, nil, false, .signaled(11), .unexpected),
   (nil, nil, false, .exited(70), .unexpected),
   (nil, 1, false, .exited(1), .unexpected),
   (nil, nil, false, .signaled(9), .unexpected),
   (.helperFailure("not booted"), 0, true, .exited(0), .startFailed(.helperFailure("not booted"))),
   (nil, nil, true, .signaled(9), .unexpected),
   (nil, nil, true, .unknown, .unexpected),
  ]
  for (failure, code, requested, termination, expected) in cases {
   precondition(DeviceProcessDeath.classify(startFailure: failure, qemuExitCode: code,
       stopRequested: requested, termination: termination) == expected)
  }
  for profile in [DeviceProfile.iPodTouch1G, .iPodTouch2G, .iPad1] {
   precondition(DeviceProcess.reason(.stopped, profile: profile) == profile.stoppedReason)
   precondition(DeviceProcess.reason(.unexpected, profile: profile) == "The \(profile.shortName) stopped unexpectedly.")
   precondition(DeviceProcess.reason(.startFailed(.helperFailure("not booted")), profile: profile) == "The \(profile.shortName) didn’t start.")
   precondition(DeviceProcess.reason(.startFailed(.helperFailure(DeviceLinkWire.leaseRefusal)), profile: profile) == DeviceLinkWire.leaseRefusal)
  }
  print("PASS: actual GUI adapter preserves all three device labels and lease refusal")
  print("PASS: real runtime exit classification preserves requested stops, crashes, kills, unknown status and start-failure precedence")
 }
}
'''

# The other order: the exit is reaped before the read source delivered the helper's last frame.
# DeviceLink.reap drains the socket first; the frame lands exactly once, before onClose.
drain = r'''import Foundation
@main struct Main {
 static func main() {
  for _ in 0..<50 {
   var sv: [Int32] = [-1, -1]; precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0)
   let queue = DispatchQueue(label: "link")
   let lock = NSLock(); var got: [String] = []; var closedAfter = -1
   let channel = LinkChannel<HelperMessage, AppMessage>(fd: sv[0], queue: queue,
     onMessage: { if case .event(.qemuExited(let rc)) = $0 { lock.withLock { got.append("exit \(rc)") } } },
     onClose: { _ in lock.withLock { closedAfter = got.count } })
   // The helper: its last message, then exit (the peer end closes).
   let frame = try! LinkChannel<AppMessage, HelperMessage>.frame(.event(.qemuExited(0)))
   _ = frame.withUnsafeBytes { write(sv[1], $0.baseAddress, $0.count) }
   close(sv[1])
   // reap, on the link's queue, before the read source had its turn (or after: either way once).
   queue.sync { channel.drainIncoming() }
   channel.close()
   queue.sync {}
   let (g, c) = lock.withLock { (got, closedAfter) }
   precondition(g == ["exit 0"] && c == 1, "delivered \(g), closed after \(c)")
  }
  print("PASS: a reaped helper's last frame is delivered once, before the channel closes")
 }
}
'''

# The race through the real session owner (DeviceSessionProcess.swift, compiled whole) against a fake DeviceLink:
# the helper boots, then dies; its exit report lands 10 ms after any qemuExited event (or with none).
link = (root / 'Shared/DeviceLink.swift').read_text()
types = ''.join(link[link.index(f'nonisolated public enum {name}'):link.index('\n}\n', link.index(f'nonisolated public enum {name}')) + 3]
                for name in ('DeviceLinkError', 'DeviceTermination'))
race = 'import Foundation\nimport HostRuntime\n' + types + r'''
public struct SharedStatus {}
/// DeviceLink's surface: start + boot succeed; terminate/kill/die report the exit one reap retry later.
@MainActor public final class DeviceLink {
 public struct Configuration { var instance: UUID }
 init(configuration: Configuration) {}
 public var onEvent: ((LinkEvent) -> Void)?
 public var onTerminated: ((DeviceTermination) -> Void)?
 public var info: HelperInfo? { nil }
 public var status: SharedStatus? { nil }
 public var pid: pid_t = 0
 var sendsExitEvent = true
 func start(_ done: @escaping (Result<HelperInfo, DeviceLinkError>) -> Void) {
  pid = 4242; done(.success(HelperInfo(protocolVersion: 1, pid: 4242, dylibPath: "", dylibModified: 0)))
 }
 func request(_ request: LinkRequest, timeout: TimeInterval, _ done: @escaping (Result<LinkReply, DeviceLinkError>) -> Void) { done(.success(.ok(true))) }
 func terminate() { die(.exited(0)) }
 func kill() { die(.signaled(9)) }
 func die(_ how: DeviceTermination) {
  if sendsExitEvent, case .exited(let code) = how { onEvent?(.qemuExited(code)) }
  DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { self.onTerminated?(how) }
 }
}
@main struct Main {
 @MainActor static func main() async {
  func death(_ act: (DeviceSessionProcess) -> Void) async -> DeviceProcessDeath? {
   let p = DeviceSessionProcess(configuration: .init(instance: UUID()))
   var booted = false
   p.start({ _ in BootConfig(argv: [], machine: "iPod-Touch") }) { if case .success = $0 { booted = true } }
   precondition(booted, "the fake boot failed")
   act(p)
   let start = Date()
   while !p.isDead, Date().timeIntervalSince(start) < 1 { try? await Task.sleep(for: .milliseconds(5)) }
   return p.death
  }
  let cases: [(DeviceProcessDeath, (DeviceSessionProcess) -> Void)] = [
   (.stopped, { $0.terminate() }),                                         // Stop; QEMU's exit reported first
   (.stopped, { $0.link.sendsExitEvent = false; $0.terminate() }),         // the race: exited 0 before qemuExited
   (.stopped, { $0.link.die(.exited(0)) }),                                // the guest powered off: QEMU exited 0
   (.unexpected, { $0.link.sendsExitEvent = false; $0.link.die(.exited(0)) }),   // nobody asked
   (.unexpected, { $0.link.die(.signaled(11)) }),
   (.unexpected, { $0.link.sendsExitEvent = false; $0.link.die(.exited(70)) }),
   (.unexpected, { $0.link.die(.exited(1)) }),
   (.unexpected, { $0.kill() }),
  ]
  for (i, (expected, act)) in cases.enumerated() {
   let got = await death(act)
   precondition(got == expected, "case \(i): expected \(expected), got \(String(describing: got))")
  }
  print("PASS: through the real session owner, a booted helper's Stop is .stopped with or without the qemuExited event; crashes, kills and unasked exits are .unexpected")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-reap-') as d:
    p = Path(d) / 'check.swift'; p.write_text(source)
    subprocess.run(['swiftc', *device_runtime.swift_flags(root), '-parse-as-library',
                    '-module-cache-path', d + '/modules', *[str(root / name) for name in (
                        'LightTouchMac/Device/DeviceProcess.swift', 'LightTouchMac/Device/DeviceProfile.swift',
                        'LightTouchMac/Device/DeviceProfile+Display.swift', 'LightTouchMac/Transport/NativeLogging.swift',
                        'LightTouchMac/Library/StorageLocations.swift')], str(p), '-o', d + '/check'], check=True)
    subprocess.run([d + '/check'], check=True, timeout=8)
    p = Path(d) / 'drain.swift'; p.write_text(drain)
    subprocess.run(['swiftc', *device_runtime.swift_flags(Path(__file__).resolve().parents[2]), '-parse-as-library', '-module-cache-path', d + '/modules', str(p), '-o', d + '/drain'], check=True)
    subprocess.run([d + '/drain'], check=True, timeout=8)
    p = Path(d) / 'race.swift'; p.write_text(race)
    subprocess.run(['swiftc', *host_runtime.swift_flags(root), '-parse-as-library', '-module-cache-path', d + '/modules',
                    str(root / 'Shared/DeviceLinkProtocol.swift'), str(root / 'Shared/DeviceSessionProcess.swift'), str(p), '-o', d + '/race'], check=True)
    subprocess.run([d + '/race'], check=True, timeout=8)
