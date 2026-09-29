#!/usr/bin/env python3
"""Exercise capture lifecycle races and durable saving without an emulator."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
fixture = r'''import Cocoa
nonisolated enum CaptureError: LocalizedError {
 case failed(String)
 var errorDescription: String? { if case let .failed(message) = self { message } else { nil } }
}
@MainActor enum Bundled { static var stateDirectory = URL(fileURLWithPath: CommandLine.arguments[1]) }
final class GuestAudioCapture: Sendable { func stop() {} }
@MainActor final class ScreenMovieWriter {
 static var starts = 0
 static var failStartup = false
 static var failFrame = 0
 static var delay: Duration = .milliseconds(30)
 var output: URL?
 var frames = 0
 func start(url: URL, audio: GuestAudioCapture?, canvasSize: CGSize? = nil, background: CGImage? = nil) async throws {
  Self.starts += 1
  frames = 0
  try await Task.sleep(for: Self.delay)
  if Self.failStartup { throw CaptureError.failed("Encoder unavailable") }
  output = url
  try Data("movie".utf8).write(to: url)
 }
 func append(_ image: CGImage?, seconds: Double) async throws {
  frames += 1; if frames == Self.failFrame { throw CaptureError.failed("Audio buffer overflow") }
 }
 func finish(seconds: Double) async throws { precondition(frames > 0 && seconds > 0); output = nil }
 func cancel() async { if let output { try? FileManager.default.removeItem(at: output) }; output = nil }
 static func configure(fail: Bool) { failStartup = fail }
}
@main struct Check {
 @MainActor static func wait(_ check: () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(5)
  while !check(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
  precondition(check(), "Timed out")
 }
 @MainActor static func main() async throws {
  let root = Bundled.stateDirectory
  let session = ScreenRecordingSession()
  var cues = [String]()
  session.onBeganRecording = { cues.append("start") }
  session.onStoppedRecording = { cues.append("stop") }
  var completions = [Bool]()
  session.onFinished = { completions.append($0) }
  let output = root.appendingPathComponent("saved.mov")
  let thumbnail = CGContext(data:nil,width:16,height:24,bitsPerComponent:8,bytesPerRow:64,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
  session.start(frame: { thumbnail }, destination: { output })
  session.start(frame: { nil }, destination: { fatalError("Duplicate start") })
  session.stop()
  precondition(session.phase == .saving)
  try await wait { !session.isActive }
  precondition(session.phase == .saved(output) && completions == [true])
  precondition(cues.isEmpty,"A take stopped during startup must not play success sounds")
  precondition(session.previewImage === thumbnail,"Saved recording lost its thumbnail")
  let contents = try Data(contentsOf: output); precondition(contents == Data("movie".utf8))
  session.start(frame: { nil }, destination: { fatalError("Discard must not save") })
  precondition(session.previewImage == nil,"A new recording retained the previous thumbnail")
  session.stop(discard: true)
  try await wait { !session.isActive }
  precondition(session.phase == .idle && completions == [true, true])
  precondition(try FileManager.default.contentsOfDirectory(atPath: ScreenRecordingSession.recoveryDirectory.path).isEmpty)
  // An existing destination must survive an automatic save collision.
  session.start(frame: { nil }, destination: { output })
  try await wait { session.phase == .recording }
  precondition(cues == ["start"])
  session.stop()
  session.stop()
  precondition(cues == ["start", "stop"],"Stop must play once, including repeated stop requests")
  try await wait { !session.isActive }
  guard case let .recovery(recovery) = session.phase else { fatalError("No recovery") }
  precondition(FileManager.default.fileExists(atPath: recovery.path))
  let starts = ScreenMovieWriter.starts
  session.start(frame: { nil }, destination: { output })
  let after = ScreenMovieWriter.starts; precondition(after == starts)
  // A failed retry retains the same movie and reports completion (quit cannot hang).
  session.retrySave(to: root.appendingPathComponent("missing/output.mov"))
  try await wait { !session.isActive }
  precondition(session.phase == .recovery(recovery) && completions.last == false)
  let retry = root.appendingPathComponent("retry.mov")
  try Data("old".utf8).write(to: retry)
  session.retrySave(to: retry)
  try await wait { !session.isActive }
  precondition(session.phase == .saved(retry) && completions.last == true)
  precondition(cues == ["start", "stop"],"Retrying a save must not play recording cues")
  precondition(!FileManager.default.fileExists(atPath: recovery.path))
  let replaced = try Data(contentsOf: retry); precondition(replaced == Data("movie".utf8))
  // Dismiss leaves recovery files durable and permits another capture.
  session.start(frame: { nil }, destination: { output }); session.stop()
  try await wait { !session.isActive }
  guard case let .recovery(retained) = session.phase else { fatalError() }
  session.dismiss(); precondition(FileManager.default.fileExists(atPath: retained.path))
  ScreenMovieWriter.failFrame = 3
  session.start(frame: { nil }, destination: { output })
  try await wait { !session.isActive }
  guard case let .recovery(partial) = session.phase else { fatalError("Lost partial movie") }
  precondition(FileManager.default.fileExists(atPath: partial.path))
  precondition(session.failure?.localizedDescription == "Audio buffer overflow")
  precondition(cues == ["start", "stop", "start", "stop"],"An interrupted take must finish its sound pair")
  session.retrySave(to: partial)
  try await wait { !session.isActive }
  precondition(session.phase == .saved(partial) && FileManager.default.fileExists(atPath: partial.path))
  session.dismiss(); ScreenMovieWriter.failFrame = 0
  ScreenMovieWriter.configure(fail: true)
  session.start(frame: { nil }, destination: { output }); session.stop()
  try await wait { !session.isActive }
  precondition(session.phase == .idle && session.failure?.localizedDescription == "Encoder unavailable")
  precondition(cues == ["start", "stop", "start", "stop"],"Failed startup must not play recording cues")
  // WireView-style fallback: preferred-folder failure opens one save panel
  // while the take remains busy, without announcing failure first.
  ScreenMovieWriter.configure(fail: false)
  let fallback = ScreenRecordingSession()
  var outcomes: [ScreenRecordingSession.Completion] = []
  fallback.onCompleted = { outcomes.append($0) }
  let alternate = root.appendingPathComponent("alternate.mov")
  try Data("replace me".utf8).write(to: alternate)
  var panels = 0
  fallback.chooseSaveDestination = { _ in
   precondition(fallback.phase == .saving && outcomes.isEmpty)
   panels += 1
   return alternate
  }
  fallback.start(frame: { thumbnail }, destination: { output }); fallback.stop()
  try await wait { !fallback.isActive }
  precondition(fallback.phase == .saved(alternate) && outcomes == [.saved(alternate)] && panels == 1)
  precondition(fallback.failure == nil)
  precondition(try! Data(contentsOf: alternate) == Data("movie".utf8))

  // Cancelling the panel retains the sole completed copy. Discard is explicit
  // and removes that durable source instead of allowing launch recovery later.
  fallback.chooseSaveDestination = { _ in panels += 1; return nil }
  fallback.start(frame: { thumbnail }, destination: { throw CaptureError.failed("Folder unavailable") })
  fallback.stop(); try await wait { !fallback.isActive }
  guard case let .recovery(cancelledSave) = fallback.phase else { fatalError("Panel cancellation lost recovery") }
  precondition(outcomes.last == .recovery(cancelledSave) && panels == 2)
  precondition(FileManager.default.fileExists(atPath: cancelledSave.path))
  fallback.discardRecovery()
  precondition(outcomes.last == .discarded && fallback.phase == .idle && fallback.failure == nil)
  precondition(!FileManager.default.fileExists(atPath: cancelledSave.path))

  // An invalid chosen path does not loop the picker or destroy the source.
  fallback.chooseSaveDestination = { _ in panels += 1; return root.appendingPathComponent("missing/fallback.mov") }
  fallback.start(frame: { thumbnail }, destination: { output }); fallback.stop()
  try await wait { !fallback.isActive }
  guard case let .recovery(failedSave) = fallback.phase else { fatalError("Failed fallback lost recovery") }
  precondition(panels == 3 && outcomes.last == .recovery(failedSave))
  fallback.retrySave(to: root.appendingPathComponent("fixed.mov"))
  try await wait { !fallback.isActive }
  precondition(outcomes.last == .saved(root.appendingPathComponent("fixed.mov")) && panels == 3)
  print("PASS: lifecycle/sounds, atomic saves, fallback picker success/cancel/failure, typed outcomes and explicit recovery discard")
 }
}
'''.replace('precondition(try FileManager.default.contentsOfDirectory(atPath: ScreenRecordingSession.recoveryDirectory.path).isEmpty)', 'let files = try FileManager.default.contentsOfDirectory(atPath: ScreenRecordingSession.recoveryDirectory.path); precondition(files.isEmpty)')
with tempfile.TemporaryDirectory(prefix='ltm-session-') as directory:
    work = Path(directory)
    (work/'check.swift').write_text(fixture)
    subprocess.run(['swiftc','-swift-version','6','-default-isolation','MainActor','-module-cache-path',str(work/'modules'),str(root/'LightTouchMac/ScreenRecordingSession.swift'),str(work/'check.swift'),'-o',str(work/'check')],check=True)
    subprocess.run([str(work/'check'),str(work)],check=True,timeout=30)
