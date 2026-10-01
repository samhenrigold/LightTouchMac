#!/usr/bin/env python3
"""Exercise the production capture destination without launching the emulator: Features/CaptureController.swift
compiled whole against tests/fixtures/capture-controller.swift."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
app = root / 'LightTouchMac'
code = r'''import Cocoa
@main struct Check {
 @MainActor static func main() throws {
  let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: base); UserDefaults.standard.removeObject(forKey: "captureFolder") }
  UserDefaults.standard.set(base.appendingPathComponent("nested").path, forKey: "captureFolder")
  let capture = CaptureController()
  UserDefaults.standard.removeObject(forKey: "captureFolder")
  precondition(capture.captureFolder == FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!)
  UserDefaults.standard.set(base.appendingPathComponent("nested").path, forKey: "captureFolder")
  let first = try capture.captureDestination("Screenshot", extension: "png")
  let second = try capture.captureDestination("Screenshot", extension: "png")
  precondition(first != second && first.pathExtension == "png")
  precondition(FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
  try Data([1,2,3]).write(to: first, options: .atomic)
  let data = try Data(contentsOf: first); precondition(data == Data([1,2,3]))
  let blocker = base.appendingPathComponent("file")
  try Data().write(to: blocker)
  UserDefaults.standard.set(blocker.appendingPathComponent("child").path, forKey: "captureFolder")
  do { _ = try capture.captureDestination("Recording", extension: "mov"); fatalError("accepted an unwritable directory") } catch {}
  print("PASS: capture destinations create folders, preserve suffixes, avoid collisions, and propagate failure")
 }
}
'''
with tempfile.TemporaryDirectory() as tmp:
    script = Path(tmp)/'main.swift'
    script.write_text(code)
    subprocess.run(['swiftc', *host_runtime.swift_flags(Path(__file__).resolve().parents[2]), '-parse-as-library', '-default-isolation', 'MainActor', '-module-cache-path', str(Path(tmp)/'modules'),
                    *[str(app/f) for f in ['Device/DeviceProfile.swift', 'Features/CapturePreferences.swift', 'Features/CaptureSound.swift',
                                           'Features/CaptureController.swift']],
                    str(root/'tests/fixtures/capture-controller.swift'), str(script), '-o', str(Path(tmp)/'check')], check=True)
    subprocess.run([str(Path(tmp)/'check')], check=True)
