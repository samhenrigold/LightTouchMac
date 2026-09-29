#!/usr/bin/env python3
"""DeviceProcess names a helper's death by what was asked of it, not by which message won the exit race.

LightTouchMac/Device/DeviceProcess.swift, compiled whole, runs against a fake link whose exit report arrives one
reap retry (10 ms, DeviceLink.reap on waitpid == 0) after the helper dies. A requested stop whose qemuExited
event was lost (the helper exited before sending it: DeviceHost.halt racing QEMU's own SIGTERM handler) is still
"The iPod stopped."; a crash or kill nobody asked for is "stopped unexpectedly" (the code and signal go to the log)."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
link = (root / 'Shared/DeviceLink.swift').read_text()
a = link.index('nonisolated enum DeviceTermination'); termination = link[a:link.index('\n}\n', a) + 3]
source = 'import Foundation\n' + termination + r'''
nonisolated func logEvent(_ s: String) {}
struct SharedStatus {}
final class ProcessLogCapture {
 init(url: URL) throws {}
 var writeDescriptor: Int32 { -1 }
 func flush() {}
}
enum DeviceLinkError: Error { case helperFailure(String) }
/// The helper's death as DeviceLink reports it: NOTE_EXIT, waitpid == 0 once, the retry 10 ms later.
@MainActor final class DeviceLink {
 struct Configuration {
  var helper = URL(fileURLWithPath: "/usr/bin/false")
  var instance: UUID
  var outputDescriptor: Int32 = -1
  var machine = ""
  var requirement: String? = nil
  var arguments: [String] = []
 }
 init(configuration: Configuration) {}
 var onEvent: ((LinkEvent) -> Void)?
 var onTerminated: ((DeviceTermination) -> Void)?
 var info: HelperInfo? { nil }
 var status: SharedStatus? { nil }
 var pid: pid_t = 1
 var sendsExitEvent = true
 func start(_ done: @escaping (Result<HelperInfo, DeviceLinkError>) -> Void) {}
 func request(_ request: LinkRequest, timeout: TimeInterval, _ done: @escaping (Result<LinkReply, DeviceLinkError>) -> Void) {}
 func terminate() { die(.exited(0)) }
 func kill() { die(.signaled(9)) }
 func die(_ how: DeviceTermination) {
  if sendsExitEvent, case .exited(let code) = how { onEvent?(.qemuExited(code)) }
  DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { self.onTerminated?(how) }
 }
}
@main struct Main {
 @MainActor static func main() async throws {
  func reason(_ act: (DeviceProcess) -> Void) async -> String {
   let p = DeviceProcess(instance: UUID(), profile: .iPodTouch2G, log: URL(fileURLWithPath: "/dev/null")); act(p)
   let start = Date()
   while !p.isDead, Date().timeIntervalSince(start) < 1 { try? await Task.sleep(for: .milliseconds(5)) }
   return p.deathReason ?? "(never died)"
  }
  let stopped = "The iPod stopped.", crashed = "The iPod stopped unexpectedly. Open Device Logs for details."
  let cases: [(String, (DeviceProcess) -> Void)] = [
   // A stop whose helper reported QEMU's exit before dying.
   (stopped, { $0.terminate() }),
   // The race: the helper exited 0 before the qemuExited event went out.
   (stopped, { $0.link.sendsExitEvent = false; $0.terminate() }),
   // Nobody asked: a crash, a kill, an exit 0 keep their own reasons.
   (crashed, { $0.link.sendsExitEvent = false; $0.link.die(.exited(0)) }),
   (crashed, { $0.link.die(.signaled(11)) }),
   (crashed, { $0.link.sendsExitEvent = false; $0.link.die(.exited(70)) }),
   (crashed, { $0.link.die(.exited(1)) }),
   (crashed, { $0.kill() }),
  ]
  for (expected, act) in cases {
   let got = await reason(act)
   precondition(got == expected, "expected '\(expected)', got '\(got)'")
  }
  print("PASS: a requested stop is 'The iPod stopped.' with or without the qemuExited event; crashes are 'stopped unexpectedly'")
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
with tempfile.TemporaryDirectory(prefix='ltm-reap-') as d:
    p = Path(d) / 'check.swift'; p.write_text(source)
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', d + '/modules', str(root / 'LightTouchMac/Device/DeviceProcess.swift'),
                    str(root / 'LightTouchMac/Device/DeviceProfile.swift'), str(root / 'LightTouchMac/Device/DeviceProfile+Display.swift'),
                    str(root / 'Shared/DeviceLinkProtocol.swift'), str(p),
                    '-o', d + '/check'], check=True)
    subprocess.run([d + '/check'], check=True, timeout=8)
    p = Path(d) / 'drain.swift'; p.write_text(drain)
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', d + '/modules', str(root / 'Shared/DeviceLinkProtocol.swift'),
                    str(p), '-o', d + '/drain'], check=True)
    subprocess.run([d + '/drain'], check=True, timeout=8)
