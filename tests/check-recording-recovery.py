#!/usr/bin/env python3
"""Launch recovery validates real MOVs, preserves failed sources, and skips current takes."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
fixture = r'''import Cocoa
import AVFoundation
@MainActor enum Bundled { static var stateDirectory = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath() }
@main struct Check {
 @MainActor static func main() async throws {
  let root = Bundled.stateDirectory
  let recovered = root.appendingPathComponent("Saved", isDirectory: true)
  let missing = try await ScreenRecordingSession.recoverRecordings(createdBefore: Date()) { _ in fatalError("No files yet") }
  precondition(missing.saved.isEmpty && missing.remaining.isEmpty)
  let directory = ScreenRecordingSession.recoveryDirectory
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: recovered, withIntermediateDirectories: true)
  let context = CGContext(data: nil, width: 32, height: 48, bitsPerComponent: 8, bytesPerRow: 128,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  context.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
  let image = context.makeImage()!
  let valid = directory.appendingPathComponent("valid.mov")
  let writer = ScreenMovieWriter()
  try await writer.start(url: valid, canvasSize: CGSize(width: 32, height: 48))
  try await writer.append(image, seconds: 0)
  try await Task.sleep(for: .milliseconds(30))
  try await writer.append(image, seconds: 0.1)
  try await writer.finish(seconds: 0.2)
  let collision = directory.appendingPathComponent("collision.mov")
  try FileManager.default.copyItem(at: valid, to: collision)
  let blocked = directory.appendingPathComponent("blocked.mov")
  try FileManager.default.copyItem(at: valid, to: blocked)
  let corrupt = directory.appendingPathComponent("incomplete.mov")
  try Data("incomplete recording".utf8).write(to: corrupt)
  let untouched = directory.appendingPathComponent("notes.txt")
  try Data("keep".utf8).write(to: untouched)
  let nested = directory.appendingPathComponent("folder.mov", isDirectory: true)
  try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
  let linked = directory.appendingPathComponent("linked.mov")
  try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: valid)
  let existing = recovered.appendingPathComponent("collision.mov")
  try Data("existing capture".utf8).write(to: existing)
  let launchDate = Date()
  try await Task.sleep(for: .milliseconds(100))
  let current = directory.appendingPathComponent("current.mov")
  try Data("currently being written".utf8).write(to: current)
  var requested: [String] = []
  let report = try await ScreenRecordingSession.recoverRecordings(createdBefore: launchDate) { source in
   requested.append(source.lastPathComponent)
   if source.lastPathComponent == blocked.lastPathComponent { throw CaptureError.failed("Preferred location unavailable") }
   return recovered.appendingPathComponent(source.lastPathComponent)
  }
  precondition(Set(requested) == Set(["valid.mov", "collision.mov", "blocked.mov"]))
  precondition(report.saved == [recovered.appendingPathComponent("valid.mov")], "saved=\(report.saved) remaining=\(report.remaining)")
  precondition(Set(report.remaining.map(\.lastPathComponent)) == Set([collision, blocked, corrupt].map(\.lastPathComponent)))
  precondition(!FileManager.default.fileExists(atPath: valid.path))
  for retained in [collision, blocked, corrupt, current, untouched, nested] {
   precondition(FileManager.default.fileExists(atPath: retained.path), "Recovery discarded a source")
  }
  precondition(try! Data(contentsOf: existing) == Data("existing capture".utf8))
  let saved = AVURLAsset(url: report.saved[0])
  precondition(try await saved.load(.isPlayable))
  // A second pass can recover a previously blocked destination without
  // overwriting the collision, touching the current take, or losing corruption.
  let retry = try await ScreenRecordingSession.recoverRecordings(createdBefore: launchDate) { source in
   recovered.appendingPathComponent("retry-" + source.lastPathComponent)
  }
  precondition(Set(retry.saved.map(\.lastPathComponent)) == Set(["retry-blocked.mov", "retry-collision.mov"]))
  precondition(retry.remaining.map(\.lastPathComponent) == [corrupt.lastPathComponent])
  precondition(FileManager.default.fileExists(atPath: current.path))
  print("PASS: playable launch recovery, atomic collision protection, destination retry, incomplete-source retention and active-file cutoff")
 }
}
'''.replace('precondition(try await saved.load(.isPlayable))', 'let playable = try await saved.load(.isPlayable); precondition(playable)')
with tempfile.TemporaryDirectory(prefix='ltm-recording-recovery-') as directory:
    work = Path(directory)
    (work/'check.swift').write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
                    '-module-cache-path', str(work/'modules'), str(root/'LightTouchMac/ScreenMovieWriter.swift'), str(root/'Shared/DeviceLinkProtocol.swift'),
                    str(root/'LightTouchMac/ScreenRecordingSession.swift'), str(work/'check.swift'), '-o', str(work/'check')], check=True)
    subprocess.run([str(work/'check'), str(work)], check=True, timeout=30)
