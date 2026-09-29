#!/usr/bin/env python3
"""Actual macOS iPod export: compatible movie, metadata, identity and cancellation."""
from pathlib import Path
import json, shutil, subprocess, sys, tempfile
DEVICE_PROFILE = str(Path(__file__).resolve().parents[1] / 'LightTouchMac/DeviceProfile.swift')

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'scripts'))
import sources  # the pinned checkouts (build-support/sources.json)
fixtures = sources.path('qemu-ios') / 'contrib/it-harness/build/Payload/Harness.app'
if not fixtures.is_dir():
    print(f'SKIP: no harness fixtures at {fixtures}; build them with contrib/it-harness/build.sh in the pinned checkout (or set QEMU_IOS_DIR)'); raise SystemExit(0)
code = r'''import Foundation
import AVFoundation
enum DeviceToolsError: LocalizedError {
 case failed(String)
 var errorDescription: String? { switch self { case .failed(let text): text } }
}
@main struct Check {
 static func main() async throws {
  let source = URL(fileURLWithPath: CommandLine.arguments[1])
  let work = URL(fileURLWithPath: CommandLine.arguments[2])
  let original = try Data(contentsOf: source)
  let first = try await MediaVideo.prepare(source, cacheDirectory: work.appendingPathComponent("cache"), profile: .iPodTouch2G)
  defer { try? FileManager.default.removeItem(at: first.directory) }
  precondition(first.title == source.deletingPathExtension().lastPathComponent)
  precondition(first.video.lastPathComponent == "video.m4v" && UUID(uuidString: first.id) != nil)
  let data = try Data(contentsOf: first.metadata)
  let metadata = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
  precondition(metadata["kind"] as? String == "feature-movie")
  precondition(metadata["filename"] as? String == "video.m4v")
  precondition(metadata["title"] as? String == first.title)
  let duration = metadata["duration_ms"] as! Double
  precondition(duration > 5900 && duration < 6100)
  try FileManager.default.copyItem(at: first.video, to: work.appendingPathComponent("prepared.m4v"))
  try await Task.sleep(for: .milliseconds(1100))
  let second = try await MediaVideo.prepare(source, cacheDirectory: work.appendingPathComponent("cache"), profile: .iPodTouch2G)
  defer { try? FileManager.default.removeItem(at: second.directory) }
  precondition(first.id == second.id && first.directory != second.directory, "repeated exports must reconcile to one guest library item")
  let unchanged = try Data(contentsOf: source)
  precondition(unchanged == original, "preparation must not rewrite the user's movie")
  let cache = work.appendingPathComponent("cache")
  let cached = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first!
  let directoryMode = try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as! NSNumber
  let fileMode = try FileManager.default.attributesOfItem(atPath: cached.path)[.posixPermissions] as! NSNumber
  precondition(directoryMode.intValue == 0o700 && fileMode.intValue == 0o600)
  // Two simultaneous drops must adopt the same atomic cache winner.
  let simultaneous = work.appendingPathComponent("simultaneous-cache")
  async let a = MediaVideo.prepare(source, cacheDirectory: simultaneous, profile: .iPodTouch2G)
  async let b = MediaVideo.prepare(source, cacheDirectory: simultaneous, profile: .iPodTouch2G)
  let (left, right) = try await (a, b)
  defer { try? FileManager.default.removeItem(at: left.directory); try? FileManager.default.removeItem(at: right.directory) }
  precondition(left.id == right.id)
  // A damaged disposable cache entry can never poison future imports.
  try Data("invalid cache".utf8).write(to: cached)
  let repaired = try await MediaVideo.prepare(source, cacheDirectory: cache, profile: .iPodTouch2G)
  defer { try? FileManager.default.removeItem(at: repaired.directory) }
  let repairedSize = try FileManager.default.attributesOfItem(atPath: repaired.video.path)[.size] as! NSNumber
  precondition(repairedSize.intValue > 0)
  for name in ["empty.mp4", "broken.mov", "audio.mov", "folder.mp4", "unknown.avi"] {
   do { _ = try await MediaVideo.prepare(work.appendingPathComponent(name), cacheDirectory: work.appendingPathComponent("cache"), profile: .iPodTouch2G); preconditionFailure("accepted \(name)") }
   catch { }
  }
  let cancelled = Task { try await MediaVideo.prepare(source, cacheDirectory: work.appendingPathComponent("cache"), profile: .iPodTouch2G) }
  cancelled.cancel()
  do { _ = try await cancelled.value; preconditionFailure("cancelled export succeeded") }
  catch is CancellationError { }
  let duringExport = Task { try await MediaVideo.prepare(source, cacheDirectory: work.appendingPathComponent("cancel-cache"), profile: .iPodTouch2G) }
  try await Task.sleep(for: .milliseconds(10))
  duringExport.cancel()
  do { _ = try await duringExport.value; preconditionFailure("cancelled active export succeeded") }
  catch is CancellationError { }
  print("PASS: iPod movie export, native metadata, immutable source, private/atomic reusable conversion, corrupt cache recovery, invalid media and cancellation")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-video-check-') as directory:
    work = Path(directory)
    (work / 'check.swift').write_text(code)
    movie = work / "Movie 'quoted' $title — été.mp4"
    shutil.copyfile(fixtures / 'h264.mp4', movie)
    (work / 'empty.mp4').touch()
    (work / 'broken.mov').write_bytes(b'not a movie')
    shutil.copyfile(fixtures / 'aac.m4a', work / 'audio.mov')
    (work / 'folder.mp4').mkdir()
    shutil.copyfile(movie, work / 'unknown.avi')
    subprocess.run(['xcrun', 'swiftc', DEVICE_PROFILE, '-swift-version', '6', '-default-isolation', 'MainActor',
                    '-module-cache-path', str(work / 'modules'), str(root / 'LightTouchMac/MediaIdentity.swift'),
                    str(root / 'LightTouchMac/MediaVideo.swift'), str(work / 'check.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check'), str(movie), str(work)], check=True, timeout=90)
    streams = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-of', 'json',
                                                 str(work / 'prepared.m4v')]))['streams']
    video = next(stream for stream in streams if stream['codec_type'] == 'video')
    assert video['codec_name'] == 'h264' and 'Baseline' in video['profile'], video
    assert video['width'] <= 640 and video['height'] <= 480 and video['level'] <= 30, video
    num, den = map(int, video['avg_frame_rate'].split('/'))
    assert num / den <= 30, video
    for audio in (stream for stream in streams if stream['codec_type'] == 'audio'):
        assert audio['codec_name'] == 'aac' and audio['channels'] <= 2 and int(audio['sample_rate']) <= 48000, audio
    print('PASS: H.264 Baseline Level ≤3, ≤640×480 at ≤30 fps and compatible audio')
