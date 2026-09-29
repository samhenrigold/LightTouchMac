#!/usr/bin/env python3
"""DeviceProcess names a helper's death by what was asked of it, not by which message won the exit race.

The production terminate/received/terminated/died text runs against a fake link whose exit report arrives one
reap retry (10 ms, DeviceLink.reap on waitpid == 0) after the helper dies. A requested stop whose qemuExited
event was lost (the helper exited before sending it: DeviceHost.halt racing QEMU's own SIGTERM handler) is still
"The emulator stopped."; a crash or kill nobody asked for keeps its unexpected-exit reason."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
link = (root / 'Shared/DeviceLink.swift').read_text()
a = link.index('nonisolated enum DeviceTermination'); termination = link[a:link.index('\n}\n', a) + 3]
s = (root / 'LightTouchMac/DeviceSession.swift').read_text()
a = s.index('    /// SIGTERM: the helper runs its own clean shutdown'); b = s.index('    /// True once the helper is gone', a)
c = s.index('    private func received(_ event: LinkEvent)', b); d = s.index('    /// Geometry is DeviceProfile', c)
e = s.index('    private func terminated(_ termination: DeviceTermination)', d); f = s.index('\n}\n', e) + 1
methods = s[a:b] + s[c:d] + s[e:f]
source = 'import Foundation\n' + termination + r'''
nonisolated func logEvent(_ s: String) {}
nonisolated enum LinkEvent { case qemuExited(Int32), audio, audioEnded }
@MainActor final class FakeLog { func flush() {} }
/// The helper's death as DeviceLink reports it: NOTE_EXIT, waitpid == 0 once, the retry 10 ms later.
@MainActor final class FakeLink {
 var onEvent: ((LinkEvent) -> Void)?
 var onTerminated: ((DeviceTermination) -> Void)?
 var sendsExitEvent = true
 func terminate() { die(.exited(0)) }
 func kill() { die(.signaled(9)) }
 func die(_ how: DeviceTermination) {
  if sendsExitEvent, case .exited(let code) = how { onEvent?(.qemuExited(code)) }
  DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { self.onTerminated?(how) }
 }
}
@MainActor final class DeviceProcess {
 let link = FakeLink()
 let log: FakeLog? = nil
 var onDeath: ((String) -> Void)?
 var onAudio: ((LinkEvent) -> Void)?
 private(set) var deathReason: String?
 var isDead: Bool { deathReason != nil }
 private var qemuExitCode: Int32?
 private var startFailure: String?
 private var stopRequested = false
 private var helperPID: pid_t = 1
 init() {
  link.onEvent = { [weak self] in self?.received($0) }
  link.onTerminated = { [weak self] in self?.terminated($0) }
 }
''' + methods + r'''}
@main struct Main {
 @MainActor static func main() async throws {
  func reason(_ act: (DeviceProcess) -> Void) async -> String {
   let p = DeviceProcess(); act(p)
   let start = Date()
   while !p.isDead, Date().timeIntervalSince(start) < 1 { try? await Task.sleep(for: .milliseconds(5)) }
   return p.deathReason ?? "(never died)"
  }
  let stopped = "The emulator stopped."
  let cases: [(String, (DeviceProcess) -> Void)] = [
   // A stop whose helper reported QEMU's exit before dying.
   (stopped, { $0.terminate() }),
   // The race: the helper exited 0 before the qemuExited event went out.
   (stopped, { $0.link.sendsExitEvent = false; $0.terminate() }),
   // Nobody asked: a crash, a kill, an exit 0 keep their own reasons.
   ("The device helper exited unexpectedly (code 0).", { $0.link.sendsExitEvent = false; $0.link.die(.exited(0)) }),
   ("The device helper was killed (signal 11).", { $0.link.die(.signaled(11)) }),
   ("The device helper exited unexpectedly (code 70).", { $0.link.sendsExitEvent = false; $0.link.die(.exited(70)) }),
   ("The emulator stopped (exit code 1).", { $0.link.die(.exited(1)) }),
   ("The device helper was killed (signal 9).", { $0.kill() }),
  ]
  for (expected, act) in cases {
   let got = await reason(act)
   precondition(got == expected, "expected '\(expected)', got '\(got)'")
  }
  print("PASS: a requested stop is 'The emulator stopped.' with or without the qemuExited event; crashes keep their reason")
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
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', d + '/modules', str(p), '-o', d + '/check'], check=True)
    subprocess.run([d + '/check'], check=True, timeout=8)
    p = Path(d) / 'drain.swift'; p.write_text(drain)
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', d + '/modules', str(root / 'Shared/DeviceLinkProtocol.swift'),
                    str(p), '-o', d + '/drain'], check=True)
    subprocess.run([d + '/drain'], check=True, timeout=8)
