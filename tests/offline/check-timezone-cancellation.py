#!/usr/bin/env python3
"""Exercise production child teardown and timezone cancellation boundaries."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
# Reuse already-built package products when supplied. Otherwise build only the
# existing Subprocess dependency, not the app or the preparation library.
def subprocess_products():
    if value := os.environ.get('LTM_SUBPROCESS_PRODUCTS'):
        return Path(value), Path(os.environ['LTM_SOURCE_PACKAGES'])
    scratch = ROOT / '.build/offline-subprocess'
    subprocess.run(['swift', 'build', '--package-path', str(ROOT / 'Packages/FirmwareKit'),
                    '--scratch-path', str(scratch), '--target', 'Subprocess'], check=True)
    return scratch / 'debug', scratch / 'checkouts'

products, checkouts = subprocess_products()
source = (ROOT / 'LightTouchMac/Services/LockdownTools.swift').read_text()
methods = source[source.index('    static func setTimeZone(_ identifier:'):source.index('    /// Offer a CA')]
methods += source[source.index('    private static func lockdownChild('):source.index('    /// A development build')]
methods = methods.replace('private static func', 'static func')
agent_source = (ROOT / 'LightTouchMac/Guest/GuestAgent.swift').read_text()
wait = agent_source[agent_source.index('    func waitAlive(seconds:'):agent_source.rfind('\n}')]
with tempfile.TemporaryDirectory(prefix='ltm-timezone-cancel-') as temporary:
    tmp = Path(temporary)
    harness = r'''
import Foundation
import Subprocess
import System
func logEvent(_ value: String) {}
enum DeviceToolsError: Error { case failed(String), zoneKept(String) }
enum Timeouts { static var query: Double = 2 }
struct DeviceServices {
METHODS
}
final class ActualWaitAgent { var isAlive = false
WAIT
}
actor State {
 var waiting = false, release = false, forgets = 0
 func wait() async -> Bool {
  waiting = true
  while !release { try? await Task.sleep(for: .milliseconds(2)) }
  return true // Simulate a service becoming ready just as cancellation arrives.
 }
 func started() -> Bool { waiting }
 func unblock() { release = true }
 func forget() { forgets += 1 }
 func count() -> Int { forgets }
}
struct FakeAgent { let state: State; func waitAlive(seconds: Double) async -> Bool { await state.wait() } }
struct GuestServices {
 let agent: FakeAgent
 func forgetExternalTimeZone() async throws -> Bool { await agent.state.forget(); return true }
}
@main struct Main {
 static func main() async throws {
  let root = URL(fileURLWithPath: CommandLine.arguments[1])
  let slow = root.appendingPathComponent("slow.sh")
  let zone = root.appendingPathComponent("zone.sh")
  let marker = root.appendingPathComponent("late-marker")
  let attempts = root.appendingPathComponent("attempts")
  let started = root.appendingPathComponent("started")
  func write(_ url: URL, _ text: String) throws {
   try text.write(to: url, atomically: true, encoding: .utf8)
   try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }
  // Delayed side effects must disappear when the actual child is cancelled.
  // SIGTERM is ignored deliberately, proving teardown escalates to SIGKILL.
  try write(slow, "#!/bin/sh\ntrap '' TERM\n/usr/bin/touch '\(started.path)'\n/bin/sleep 0.4\n/usr/bin/touch '\(marker.path)'\n")
  let child = Task { try await DeviceServices.lockdownChild(slow.path, [], socket: "127.0.0.1:31411") }
  let spawnDeadline = ContinuousClock.now + .seconds(2)
  while !FileManager.default.fileExists(atPath: started.path) {
   precondition(ContinuousClock.now < spawnDeadline, "child never spawned")
   try await Task.sleep(for: .milliseconds(2))
  }
  child.cancel()
  do { _ = try await child.value; fatalError("cancelled child succeeded") } catch is CancellationError {}
  try await Task.sleep(for: .milliseconds(500))
  precondition(!FileManager.default.fileExists(atPath: marker.path), "cancelled child left a delayed writer")
  // A process that does not answer must be reaped at its deadline too.
  Timeouts.query = 0.1
  do { _ = try await DeviceServices.lockdownChild(slow.path, [], socket: "127.0.0.1:31411"); fatalError("deadline succeeded") }
  catch DeviceToolsError.failed {} 
  try await Task.sleep(for: .milliseconds(500))
  precondition(!FileManager.default.fileExists(atPath: marker.path), "deadline left a delayed writer")
  Timeouts.query = 2
  // Cancel precisely during zoneKept's readiness wait; no forget or retry may land.
  try write(zone, "#!/bin/sh\nprintf 'attempt\\n' >> '\(attempts.path)'\nprintf 'UTC\\n'\nexit 4\n")
  let state = State(), guest = GuestServices(agent: FakeAgent(state: state))
  let operation = Task { try await DeviceServices.setTimeZone("Etc/UTC", tool: zone.path,
                          socket: "127.0.0.1:31411", guest: guest) }
  while !(await state.started()) { try await Task.sleep(for: .milliseconds(2)) }
  operation.cancel(); await state.unblock()
  do { _ = try await operation.value; fatalError("cancelled zone retry succeeded") } catch is CancellationError {}
  let forgetCount = await state.count()
  precondition(forgetCount == 0, "cancelled timezone cleared guest state")
  let attemptLog = try String(contentsOf: attempts, encoding: .utf8)
  precondition(attemptLog == "attempt\n", "cancelled timezone retried")
  // The actual waitAlive implementation must return promptly on cancellation.
  let readiness = ActualWaitAgent()
  let waitStart = ContinuousClock.now
  let pending = Task { await readiness.waitAlive(seconds: 60) }
  try await Task.sleep(for: .milliseconds(20)); pending.cancel()
  let ready = await pending.value
  precondition(ready == false)
  precondition(ContinuousClock.now - waitStart < .seconds(1), "cancelled waitAlive spun until deadline")
  print("PASS: timezone child cancellation/deadline reap, zoneKept no mutation/retry, readiness cancellation")
 }
}
'''.replace('METHODS', methods).replace('WAIT', wait)
    swift = tmp / 'Probe.swift'; swift.write_text(harness)
    maps = [checkouts / 'swift-system/Sources/CSystem/include/module.modulemap',
            checkouts / 'swift-subprocess/Sources/_SubprocessCShims/include/module.modulemap']
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5',
        '-module-cache-path', str(tmp / 'modules'), '-I', str(products),
        *[arg for path in maps for arg in ['-Xcc', '-fmodule-map-file=' + str(path)]],
        str(swift), *[str(products / (name + '.o')) for name in ['Subprocess', 'SystemPackage', 'CSystem', '_SubprocessCShims']],
        '-o', str(tmp / 'probe')], check=True)
    subprocess.run([str(tmp / 'probe'), str(tmp)], check=True, timeout=20)
