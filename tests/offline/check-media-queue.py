#!/usr/bin/env python3
"""Production media jobs wait behind installs, report progress, and cancel safely."""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'LightTouchMac/AppsInspectorViewController.swift').read_text()


def block(start, end):
    a = source.index(start)
    return source[a:source.index(end, a)]


job = block('extension Notification.Name {', '/// Shared install flow')
state = block('    static var hasPendingWork:', '    @discardableResult\n    static func start(')
media = block('    @discardableResult\n    static func startMedia(', '    /// A Legacy Store copy:')
finish = block('    private static func finish(', '    /// Queue when bytes are ready,')
pause = block('    private static func pauseIfNeeded(', '    @MainActor\n    static func presentError(')
code = r'''import Cocoa
enum DeviceError: Error { case timedOut; var shouldPauseInstallQueue: Bool { true } }
struct Failure: LocalizedError { var errorDescription: String? { "Unreadable photo" } }
enum DeviceProfile { case iPodTouch2G }
@MainActor struct PreparedMedia {
 static var failed = Set<String>()
 static var delayed = Set<String>()
 static var preparation: [String: CheckedContinuation<Void, Error>] = [:]
 let directory: URL, title: String, destination: String
 static func prepare(_ source: URL, profile: DeviceProfile) async throws -> PreparedMedia {
  let name = source.deletingPathExtension().lastPathComponent
  if delayed.contains(name) { try await withCheckedThrowingContinuation { preparation[name] = $0 } }
  try Task.checkCancellation()
  if failed.contains(name) { throw Failure() }
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-media-queue-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  return PreparedMedia(directory: directory, title: name, destination: source.pathExtension == "mp3" ? "Music" : "Photos")
 }
}
struct DeviceInstance { let id = UUID() }
@MainActor final class EmulatorController {
 let profile = DeviceProfile.iPodTouch2G
 let instance = DeviceInstance()
 var deviceReachable: Bool? = true
 func reportConnectionFailure(_ error: Error, operation: String) { deviceReachable = false }
 var started: [String] = [], committed: [String] = []
 var uploads: [String: CheckedContinuation<Void, Error>] = [:]
 func importMedia(_ media: PreparedMedia, progress: @escaping @Sendable (Double) -> Void,
                  willCommit: () -> Void) async throws {
  precondition(AppInstaller.isUsingDevice(instance.id) && uploads.isEmpty, "guest mutations overlapped")
  started.append(media.title)
  progress(0.25)
  try await withCheckedThrowingContinuation { uploads[media.title] = $0 }
  try Task.checkCancellation()
  willCommit()
  committed.append(media.title)
 }
 func finish(_ name: String, error: Error? = nil) {
  let reply = uploads.removeValue(forKey: name)!
  if let error { reply.resume(throwing: error) } else { reply.resume() }
 }
}
''' + job + '\n@MainActor enum AppInstaller {\n' + state + media + finish + pause + r'''
 static var device = UUID()
 static func occupyDevice() async throws { try await queue(for: device).acquire() }
 static func releaseDevice() { queue(for: device).release() }
 static var isUsingDevice: Bool { isUsingDevice(device) }
 static var isPaused: Bool { isPaused(device) }
 static func resume() { resume(device) }
}
@MainActor final class JobObservations {
 var starts: [InstallJob] = [], updates: [String] = []
}
@main struct Check {
 @MainActor static func main() async throws {
  func until(_ condition: () -> Bool) async throws {
   let deadline = ContinuousClock.now + .seconds(5)
   while !condition() {
    precondition(ContinuousClock.now < deadline, "media job stalled")
    try await Task.sleep(for: .milliseconds(5))
   }
  }
  let observations = JobObservations()
  let start = NotificationCenter.default.addObserver(forName: .ltmInstallStarted, object: nil, queue: nil) { note in
   let job = note.object as! InstallJob
   MainActor.assumeIsolated { observations.starts.append(job) }
  }
  let progress = NotificationCenter.default.addObserver(forName: .ltmInstallProgress, object: nil, queue: nil) { note in
   let job = note.object as! InstallJob
   MainActor.assumeIsolated { observations.updates.append(job.status) }
  }
  defer { NotificationCenter.default.removeObserver(start); NotificationCenter.default.removeObserver(progress) }
  let emulator = EmulatorController()
  AppInstaller.device = emulator.instance.id
  func add(_ filename: String) -> InstallJob {
   AppInstaller.startMedia(URL(fileURLWithPath: "/tmp/" + filename), with: emulator, presenting: nil)
  }
  // An install already owns the guest. Dropping a photo immediately publishes
  // a job, then retains the prepared media until its serialized turn arrives.
  try await AppInstaller.occupyDevice()
  let photo = add("Photo.png")
  precondition(observations.starts.last === photo && photo.status == "Preparing media…")
  precondition(AppInstaller.hasPendingWork)
  try await until { photo.status == "Waiting for other transfers…" }
  let song = add("Song.mp3")
  try await until { song.status == "Waiting for other transfers…" }
  precondition(emulator.started.isEmpty && !photo.isFinished && !song.isFinished)
  AppInstaller.releaseDevice()
  try await until { emulator.started == ["Photo"] }
  try await until { photo.downloadProgress == 0.25 }
  precondition(photo.status == "Copying media… 25%" && song.status == "Waiting for other transfers…")
  emulator.finish("Photo")
  try await until { photo.isFinished && emulator.started == ["Photo", "Song"] }
  precondition(photo.status == "Added to Photos" && !photo.failed && !photo.isCancellable)
  emulator.finish("Song")
  try await until { song.isFinished }
  precondition(song.status == "Added to Music" && emulator.committed == ["Photo", "Song"])
  precondition(!AppInstaller.hasPendingWork && !AppInstaller.isUsingDevice)

  // Cancellation before the guest slot is acquired cannot remove another job
  // or silently become a failed transfer row.
  try await AppInstaller.occupyDevice()
  let cancelled = add("Cancelled.png")
  try await until { cancelled.status == "Waiting for other transfers…" }
  cancelled.cancel()
  try await until { cancelled.isFinished }
  precondition(cancelled.isCancelled && !cancelled.failed && !emulator.started.contains("Cancelled"))
  AppInstaller.releaseDevice()
  PreparedMedia.delayed.insert("Preparing")
  let preparing = add("Preparing.png")
  try await until { PreparedMedia.preparation["Preparing"] != nil }
  preparing.cancel()
  // Some system media APIs return their own error on cancellation.
  PreparedMedia.preparation.removeValue(forKey: "Preparing")!.resume(throwing: Failure())
  try await until { preparing.isFinished }
  precondition(preparing.isCancelled && !preparing.failed)

  // Bad input is visible and retryable, never a success that vanishes.
  PreparedMedia.failed.insert("Bad")
  let bad = add("Bad.png")
  try await until { bad.isFinished }
  precondition(bad.failed && bad.status == "Unreadable photo" && bad.retry != nil)
  PreparedMedia.failed.remove("Bad")
  bad.retry?()
  precondition(bad.dismissed)
  try await until { emulator.started.last == "Bad" }
  emulator.finish("Bad")
  try await until { !AppInstaller.hasPendingWork }

  // A transport error pauses waiting imports; Resume must retain and execute
  // the original job without a second drop.
  let disconnected = add("Disconnected.png")
  try await until { emulator.started.last == "Disconnected" }
  let waiting = add("After reconnect.mp3")
  try await until { waiting.status == "Waiting for other transfers…" }
  emulator.finish("Disconnected", error: DeviceError.timedOut)
  try await until { disconnected.isFinished }
  precondition(disconnected.failed && AppInstaller.isPaused && waiting.status == "Paused")
  precondition(!emulator.started.contains("After reconnect") && !waiting.isFinished)
  emulator.deviceReachable = true
  AppInstaller.resume()
  try await until { emulator.started.last == "After reconnect" }
  emulator.finish("After reconnect")
  try await until { waiting.isFinished }
  precondition(!waiting.failed && waiting.status == "Added to Music" && !AppInstaller.hasPendingWork)
  print("PASS: media publishes immediate feedback, waits behind installs, imports in order, cancels preparation/waiting, retries failure and resumes after disconnection")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-media-queue-check-') as directory:
    work = Path(directory)
    (work / 'check.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
                    '-module-cache-path', str(work / 'modules'), str(root / 'LightTouchMac/InstallationQueue.swift'),
                    str(work / 'check.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True, timeout=25)
