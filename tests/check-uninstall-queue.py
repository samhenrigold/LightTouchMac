#!/usr/bin/env python3
"""Run the production removal flow behind an install, through cancellation and failure."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'LightTouchMac/AppsInspectorViewController.swift').read_text()
def block(start, end):
    return source[source.index(start):source.index(end, source.index(start))]
state = block('    static var hasPendingWork:', '    static func resume(_ device')
remove = block('    static func remove(_ apps:', '    @MainActor\n    static func presentError(')
code = r'''import Foundation
final class NSWindow {}
struct InstalledApp { let id: String }
final class InstallJob { let deviceID = UUID(); var isCancellable = true; var downloadProgress: Double?; var status = "Waiting"; var task: Task<Void, Never>?; var dismissed = false; func cancel() {} }
enum DeviceError: Error { case timedOut; var shouldPauseInstallQueue: Bool { true } }
extension Notification.Name {
 static let ltmAppsChanged = Notification.Name("changed")
 static let ltmInstallProgress = Notification.Name("progress")
}
@MainActor final class AppMetadataCache {
 static let shared = AppMetadataCache(); var forgotten: [String] = []
 func forget(_ id: String) { forgotten.append(id) }
}
struct DeviceInstance { let id = UUID() }
@MainActor enum IPALibrary { static var forgotten: [String] = []; static func forget(_ id: String, device: DeviceInstance) { forgotten.append(id) } }
@MainActor final class EmulatorController {
 let instance = DeviceInstance()
 var deviceReachable: Bool? = true
 func reportConnectionFailure(_ error: Error, operation: String) { deviceReachable = false }
 var started: [String] = []
 var pending: [String: CheckedContinuation<Void, Error>] = [:]
 func uninstall(_ id: String) async throws {
  started.append(id)
  try await withCheckedThrowingContinuation { pending[id] = $0 }
 }
 func finish(_ id: String, error: Error? = nil) {
  let continuation = pending.removeValue(forKey: id)!
  if let error { continuation.resume(throwing: error) } else { continuation.resume() }
 }
}
@MainActor enum AppInstaller {
''' + state + remove + r'''
 static var errors = 0
 static func presentError(_ error: Error, in window: NSWindow?) { errors += 1 }
 static var device = UUID()
 static func takeDevice() async throws { try await queue(for: device).acquire() }
 static func releaseDevice() { queue(for: device).release() }
 static func pauseDevice() { queue(for: device).pause() }
 static func resumeDevice() { queue(for: device).resume() }
 static var isUsingDevice: Bool { isUsingDevice(device) }
 static var isPaused: Bool { isPaused(device) }
}
@main struct Check {
 @MainActor static func main() async throws {
  func until(_ condition: () -> Bool) async throws {
   let deadline = ContinuousClock.now + .seconds(5)
   while !condition() {
    precondition(ContinuousClock.now < deadline, "removal queue stalled")
    try await Task.sleep(for: .milliseconds(5))
   }
  }
  let emulator = EmulatorController()
  AppInstaller.device = emulator.instance.id
  var started: [String] = [], removed: [String] = [], finished = 0
  func remove(_ ids: [String]) {
   AppInstaller.remove(ids.map { InstalledApp(id: $0) }, with: emulator, presenting: nil) {
    started.append($0.id)
   } didRemove: { removed.append($0.id) } didFinish: { finished += 1 }
  }
  // The user confirms while an install owns the device: preserve the request.
  try await AppInstaller.takeDevice()
  remove(["diner"])
  precondition(AppInstaller.hasPendingWork)
  await Task.yield()
  precondition(started.isEmpty && removed.isEmpty && AppInstaller.isUsingDevice)
  AppInstaller.releaseDevice()
  try await until { started == ["diner"] }
  var laterInstall = false
  let installer = Task { @MainActor in
   try await AppInstaller.takeDevice()
   laterInstall = true
   AppInstaller.releaseDevice()
  }
  await Task.yield()
  precondition(!laterInstall && removed.isEmpty)
  emulator.finish("diner")
  try await installer.value
  try await until { finished == 1 }
  precondition(removed == ["diner"] && laterInstall && !AppInstaller.hasPendingWork)
  precondition(AppMetadataCache.shared.forgotten == ["diner"] && IPALibrary.forgotten == ["diner"])

  // Quit cancels queued removals, including when transfers have been paused.
  AppInstaller.pauseDevice()
  remove(["cancelled"])
  await Task.yield()
  AppInstaller.cancelPendingWork()
  try await until { finished == 2 }
  AppInstaller.resumeDevice()
  precondition(!started.contains("cancelled") && !AppInstaller.hasPendingWork && !AppInstaller.isUsingDevice)

  // An in-progress non-cancellable guest call keeps the slot and quit guard
  // until it finishes, while cancellation skips the rest of its batch.
  remove(["active", "skip"])
  try await until { started.contains("active") }
  AppInstaller.cancelPendingWork()
  await Task.yield()
  precondition(AppInstaller.hasPendingWork && AppInstaller.isUsingDevice && finished == 2)
  emulator.finish("active")
  try await until { finished == 3 }
  precondition(!started.contains("skip") && removed.contains("active") && !AppInstaller.hasPendingWork)

  // Failure reports once, releases the queue and leaves the app's metadata.
  struct Failure: Error {}
  remove(["broken", "unattempted"])
  try await until { started.contains("broken") }
  emulator.finish("broken", error: Failure())
  try await until { finished == 4 }
  precondition(AppInstaller.errors == 1 && !started.contains("unattempted"))
  precondition(!removed.contains("broken") && !IPALibrary.forgotten.contains("broken"))
  precondition(!AppInstaller.isUsingDevice && !AppInstaller.hasPendingWork)
  // A dead transport pauses the shared queue. Later requests remain accepted
  // and visible, but no next write begins until the device is resumed.
  remove(["lost"])
  try await until { started.contains("lost") }
  remove(["after-recovery"])
  await Task.yield()
  emulator.finish("lost", error: DeviceError.timedOut)
  try await until { finished == 5 }
  precondition(AppInstaller.isPaused && !AppInstaller.isUsingDevice && AppInstaller.hasPendingWork)
  precondition(emulator.deviceReachable == false && !started.contains("after-recovery"))
  AppInstaller.resumeDevice()
  try await until { started.contains("after-recovery") }
  emulator.finish("after-recovery")
  try await until { finished == 6 }
  precondition(AppInstaller.errors == 2 && !AppInstaller.hasPendingWork && !AppInstaller.isUsingDevice)

  // A guest failure after Quit cancelled the active task must not open an
  // error sheet during shutdown.
  remove(["quit-active"])
  try await until { started.contains("quit-active") }
  AppInstaller.cancelPendingWork()
  emulator.finish("quit-active", error: DeviceError.timedOut)
  try await until { finished == 7 }
  precondition(AppInstaller.errors == 2 && !AppInstaller.isPaused && !AppInstaller.hasPendingWork)
  print("PASS: confirmed removal queues behind installs, serializes later installs, survives active cancellation, cancels waiting work, pauses on device failure and resumes queued work")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-uninstall-') as directory:
    work = Path(directory)
    (work / 'check.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
                    '-module-cache-path', str(work / 'modules'), str(root / 'LightTouchMac/InstallationQueue.swift'),
                    str(work / 'check.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True, timeout=20)
