#!/usr/bin/env python3
"""Bundled tool lookup: bundle first, then the checkout; the files root from LTM_FILES."""
from pathlib import Path
import os, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='ltm-bundled-') as tmp:
    work = Path(tmp)
    source = work / 'main.swift'
    source.write_text(r'''import Foundation
let directory = CommandLine.arguments[1]
let file = directory + "/com.qemu.it-agent.plist"
let missing = directory + "/missing"
try Data("fixture".utf8).write(to: URL(fileURLWithPath: file))
try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
precondition(Bundled.resolve("missing", fallbacks: [file]) == nil)
try FileManager.default.createDirectory(atPath: Bundled.toolsDirectory!, withIntermediateDirectories: true)
let host = Bundled.hostToolsDirectory! + "/helper"
let legacy = Bundled.toolsDirectory! + "/helper"
for path in [host, legacy] {
    try Data("fixture".utf8).write(to: URL(fileURLWithPath: path))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
}
precondition(Bundled.tool("helper") == host)
try FileManager.default.removeItem(atPath: host)
precondition(Bundled.tool("helper") == legacy)
precondition(Bundled.binarySearchPaths.first == Bundled.hostToolsDirectory)
precondition(Bundled.filesRoot == CommandLine.arguments[2], "LTM_FILES names the device assets")
print("PASS: native helper precedence and checkout fallback; a non-executable file is no tool; LTM_FILES is the files root")
''')
    executable = work / 'Check.app/Contents/MacOS/check'
    executable.parent.mkdir(parents=True)
    (executable.parent.parent / 'Resources').mkdir()
    subprocess.run(['swiftc', '-module-cache-path', str(work/'modules'), str(root/'LightTouchMac/Bundled.swift'), str(root/'LightTouchMac/StorageLocations.swift'), str(root/'LightTouchMac/NativeLogging.swift'), str(source), '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(work), str(work / 'files')], check=True, env=dict(os.environ, LTM_FILES=str(work / 'files')))
