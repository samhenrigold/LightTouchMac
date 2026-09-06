#!/usr/bin/env python3
"""Exercise the production capture destination without launching the emulator."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
source = (root/'LightTouchMac/MainWindowController.swift').read_text()
def extract(start, end):
    return source[source.index(start):source.index(end, source.index(start))].replace('private ', '')
code = 'import Foundation\nstruct Capture {\n' + extract('    private var captureFolder:', '    @objc func showCaptures') + extract('    private func captureName', '    @objc func showLiveText') + '}\n'
code += r'''let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: base); UserDefaults.standard.removeObject(forKey: "captureFolder") }
UserDefaults.standard.set(base.appendingPathComponent("nested").path, forKey: "captureFolder")
let capture = Capture()
let first = try capture.captureDestination("Screenshot", extension: "png")
let second = try capture.captureDestination("Screenshot", extension: "png")
assert(first != second && first.pathExtension == "png")
assert(FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
try Data([1,2,3]).write(to: first, options: .atomic)
assert(try Data(contentsOf: first) == Data([1,2,3]))
let blocker = base.appendingPathComponent("file")
try Data().write(to: blocker)
UserDefaults.standard.set(blocker.appendingPathComponent("child").path, forKey: "captureFolder")
do { _ = try capture.captureDestination("Recording", extension: "mov"); fatalError("accepted an unwritable directory") } catch {}
print("PASS: capture destinations create folders, preserve suffixes, avoid collisions, and propagate failure")
'''
# Swift assert's autoclosure cannot throw.
code = code.replace('assert(try Data(contentsOf: first) == Data([1,2,3]))', 'let data = try Data(contentsOf: first); assert(data == Data([1,2,3]))')
with tempfile.TemporaryDirectory() as tmp:
    script = Path(tmp)/'check.swift'
    script.write_text(code)
    subprocess.run(['swift', str(script)], check=True)
