#!/usr/bin/env python3
"""The install queue is per device: discarding, pausing and busy checks on device A leave device B alone."""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'LightTouchMac/UI/AppsInspectorViewController.swift').read_text()


def block(start, end):
    a = source.index(start)
    return source[a:source.index(end, a)]


job = block('extension Notification.Name {', '/// Shared install flow')
state = block('    static var hasPendingWork:', '    @discardableResult\n    static func start(')
media = block('    @discardableResult\n    static func startMedia(', '    /// A Legacy Store copy:')
finish = block('    private static func finish(', '    /// Queue when bytes are ready,')
remove = block('    static func remove(_ apps:', '    /// Every queued mutation of one device')
pause = block('    private static func pauseIfNeeded(', '    @MainActor\n    static func presentError(')
code = r'''import Cocoa
enum DeviceError: Error { case timedOut; var shouldPauseInstallQueue: Bool { true } }
enum DeviceProfile { case iPodTouch2G }
struct InstalledApp { let id: String }
struct DeviceInstance { let id = UUID() }
@MainActor final class AppMetadataCache { static let shared = AppMetadataCache(); func forget(_ id: String) {} }
@MainActor final class DeviceLibrary { static let shared = DeviceLibrary(); var instances: [DeviceInstance] = [] }
@MainActor enum IPALibrary {
 static func forget(_ id: String, device: DeviceInstance) {}
 static func retained(_ id: String, by devices: [DeviceInstance]) -> Bool { false }
}
@MainActor struct PreparedMedia {
 let directory: URL, title: String, destination: String
 static func prepare(_ source: URL, profile: DeviceProfile) async throws -> PreparedMedia {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-queue-scope-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  return PreparedMedia(directory: directory, title: source.deletingPathExtension().lastPathComponent, destination: "Photos")
 }
}
@MainActor final class EmulatorController {
 let profile = DeviceProfile.iPodTouch2G
 let instance = DeviceInstance()
 var deviceReachable: Bool? = true
 var failures = 0
 func reportConnectionFailure(_ error: Error, operation: String) { failures += 1; deviceReachable = false }
 var imported: [String] = [], removed: [String] = []
 var uploads: [String: CheckedContinuation<Void, Error>] = [:]
 func importMedia(_ media: PreparedMedia, progress: @escaping @Sendable (Double) -> Void, willCommit: () -> Void) async throws {
  imported.append(media.title)
  try await withCheckedThrowingContinuation { uploads[media.title] = $0 }
  try Task.checkCancellation()
  willCommit()
 }
 func uninstall(_ id: String) async throws {
  removed.append(id)
  try await withCheckedThrowingContinuation { uploads[id] = $0 }
 }
 func finish(_ name: String, error: Error? = nil) {
  let reply = uploads.removeValue(forKey: name)!
  if let error { reply.resume(throwing: error) } else { reply.resume() }
 }
}
''' + job + '\n@MainActor enum AppInstaller {\n' + state + media + finish + remove + pause + r'''
 static func presentError(_ error: Error, in window: NSWindow?) {}
 static func occupy(_ device: UUID) async throws { try await queue(for: device).acquire() }
 static func release(_ device: UUID) { queue(for: device).release() }
}
@MainActor final class Changes { var devices: [UUID?] = [] }
@main struct Check {
 @MainActor static func main() async throws {
  func until(line: Int = #line, _ condition: () -> Bool) async throws {
   let deadline = ContinuousClock.now + .seconds(5)
   while !condition() {
    precondition(ContinuousClock.now < deadline, "queue stalled at line \(line)")
    try await Task.sleep(for: .milliseconds(5))
   }
  }
  let changes = Changes()
  let observer = NotificationCenter.default.addObserver(forName: .ltmAppsChanged, object: nil, queue: nil) { note in
   let device = note.object as? UUID
   MainActor.assumeIsolated { changes.devices.append(device) }
  }
  defer { NotificationCenter.default.removeObserver(observer) }
  let a = EmulatorController(), b = EmulatorController()
  func add(_ name: String, to emulator: EmulatorController) -> InstallJob {
   AppInstaller.startMedia(URL(fileURLWithPath: "/tmp/\(name).png"), with: emulator, presenting: nil)
  }
  // Rows carry their device; each device's queue is its own.
  try await AppInstaller.occupy(a.instance.id)
  try await AppInstaller.occupy(b.instance.id)
  let onA = add("On A", to: a), onB = add("On B", to: b)
  precondition(onA.deviceID == a.instance.id && onB.deviceID == b.instance.id)
  try await until { onA.status == "Waiting for other transfers…" && onB.status == "Waiting for other transfers…" }
  precondition(AppInstaller.hasPendingWork(for: a.instance.id) && AppInstaller.hasPendingWork(for: b.instance.id))
  precondition(AppInstaller.isUsingDevice(a.instance.id) && AppInstaller.isUsingDevice(b.instance.id))

  // Power Off / Erase on A discards A's job only; B's keeps waiting and then runs.
  AppInstaller.discard(for: a.instance.id)
  try await until { onA.isFinished }
  precondition(onA.isCancelled && onA.dismissed && !onB.isFinished && !onB.dismissed && !onB.isCancelled)
  precondition(changes.devices.contains(a.instance.id) && !changes.devices.contains(b.instance.id))
  precondition(!AppInstaller.hasPendingWork(for: a.instance.id) && AppInstaller.hasPendingWork(for: b.instance.id))
  AppInstaller.release(b.instance.id)
  try await until { b.imported == ["On B"] }
  b.finish("On B")
  try await until { onB.isFinished }
  precondition(onB.status == "Added to Photos" && !AppInstaller.hasPendingWork)
  AppInstaller.release(a.instance.id)
  precondition(!AppInstaller.isUsingDevice(a.instance.id) && !AppInstaller.isUsingDevice(b.instance.id))

  // A transport failure on A pauses A's queue and A's waiting rows, not B's.
  let lostA = add("Lost A", to: a)
  try await until { a.imported == ["Lost A"] }
  let waitA = add("Wait A", to: a), waitB = add("Wait B", to: b)
  try await until { waitA.status == "Waiting for other transfers…" && b.imported == ["On B", "Wait B"] }
  a.finish("Lost A", error: DeviceError.timedOut)
  try await until { lostA.isFinished }
  precondition(lostA.failed && AppInstaller.isPaused(a.instance.id) && !AppInstaller.isPaused(b.instance.id))
  precondition(waitA.status == "Paused" && waitB.status == "Copying media…" && a.failures == 1 && b.failures == 0)
  b.finish("Wait B")
  try await until { waitB.isFinished }
  precondition(waitB.status == "Added to Photos" && !waitB.failed)
  AppInstaller.resume(a.instance.id)
  try await until { a.imported == ["Lost A", "Wait A"] }
  a.finish("Wait A")
  try await until { waitA.isFinished }
  precondition(waitA.status == "Added to Photos")

  // A removal on B is B's pending work, and A's discard leaves it queued.
  var finished = 0
  AppInstaller.remove([InstalledApp(id: "app.b")], with: b, presenting: nil, willRemove: { _ in }, didRemove: { _ in }) { finished += 1 }
  try await until { b.removed == ["app.b"] }
  precondition(AppInstaller.hasPendingWork(for: b.instance.id) && !AppInstaller.hasPendingWork(for: a.instance.id))
  AppInstaller.discard(for: a.instance.id)
  await Task.yield()
  precondition(finished == 0 && AppInstaller.isUsingDevice(b.instance.id))
  b.finish("app.b")
  try await until { finished == 1 }
  precondition(!AppInstaller.hasPendingWork)
  print("PASS: jobs carry their device; discard(for:), pause and busy/pending checks are scoped to one device")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-queue-scope-') as directory:
    work = Path(directory)
    (work / 'check.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
                    '-module-cache-path', str(work / 'modules'), str(root / 'LightTouchMac/Features/InstallationQueue.swift'),
                    str(work / 'check.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True, timeout=25)
