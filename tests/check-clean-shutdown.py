#!/usr/bin/env python3
"""Execute the production Stop (EmulatorController.halt) against fake helpers: a hard halt, never a guest shutdown."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'LightTouchMac/EmulatorController.swift').read_text()
a = s.index('    static let haltBudget:'); b = s.index('    /// Menu ▸ Save State Now', a)
halt = s[a:b].replace('haltBudget: TimeInterval = 10', 'haltBudget: TimeInterval = 0.3')
source = r'''import Foundation
nonisolated func logEvent(_ s: String) {}
/// DeviceProcess's surface: SIGTERM exits it (or not, when hung); SIGKILL always does.
@MainActor final class FakeProcess {
 var hung = false, terms = 0, kills = 0, isDead = false
 func terminate() { terms += 1; if !hung { Task { try? await Task.sleep(for: .milliseconds(30)); self.isDead = true } } }
 func kill() { kills += 1; isDead = true }
 func waitForExit(timeout: TimeInterval) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while !isDead, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
  return isDead
 }
}
@MainActor final class Controller {
 enum State { case notStarted, booting, running, paused, snapshotting, poweredOff }
 var state = State.booting, isDead = false, isErasing = false, shuttingDown = false, halting = false
 var isPoweredOff: Bool { state == .poweredOff }
 var connectionRecoveryTask: Task<Void, Never>?, orientationTask: Task<Void, Never>?, foregroundTask: Task<Void, Never>?, mediaPreparationTask: Task<Void, Never>?, haltTask: Task<Void, Never>?, bootWatchTask: Task<Void, Never>?
 var haltCompletions: [(Bool) -> Void] = []
 var process: FakeProcess? = FakeProcess()
''' + halt + r'''}
@main struct Main {
 @MainActor static func main() async throws {
  // Mid-boot (never lit, no guest services): Stop still halts, and requests join.
  let c = Controller(); c.mediaPreparationTask = Task { try? await Task.sleep(for: .seconds(60)) }
  precondition(c.canStop)
  var results: [Bool] = []
  let started = Date()
  await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
   c.halt { results.append($0); if results.count == 2 { done.resume() } }
   c.halt { results.append($0); if results.count == 2 { done.resume() } }
   precondition(c.shuttingDown && !c.canStop && c.mediaPreparationTask!.isCancelled)
  }
  precondition(results == [true, true] && c.process!.terms == 1 && c.process!.kills == 0 && !c.shuttingDown)
  precondition(Date().timeIntervalSince(started) < 1, "a halt waited on the guest")
  // A helper that ignores SIGTERM is killed after the budget.
  let hung = Controller(); hung.process!.hung = true
  let killed = await withCheckedContinuation { done in hung.halt { done.resume(returning: $0) } }
  precondition(killed && hung.process!.kills == 1)
  // A save in flight is left alone; a gone helper or a powered-off guest is already stopped.
  let saving = Controller(); saving.state = .snapshotting
  var saved: Bool?; saving.halt { saved = $0 }
  precondition(saved == false && saving.process!.terms == 0 && !saving.shuttingDown)
  let gone = Controller(); gone.process!.isDead = true
  var goneResult: Bool?; gone.halt { goneResult = $0 }
  precondition(goneResult == true && gone.process!.terms == 0)
  print("PASS: Stop mid-boot halts at once, joined requests, a hung helper is killed, a save is left alone")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-halt-') as d:
    p = Path(d) / 'check.swift'; p.write_text(source)
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', d + '/modules', str(p), '-o', d + '/check'], check=True)
    subprocess.run([d + '/check'], check=True, timeout=8)
