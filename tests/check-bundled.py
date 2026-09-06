#!/usr/bin/env python3
"""Production lookup accepts readable guest resources without executable bits."""
from pathlib import Path
import subprocess, tempfile
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
precondition(Bundled.resolveResource("missing", fallbacks: [missing, file]) == file)
precondition(Bundled.resolveResource("missing", fallbacks: [missing]) == nil)
let bundled = Bundled.toolsDirectory! + "/com.qemu.it-agent.plist"
try FileManager.default.createDirectory(atPath: Bundled.toolsDirectory!, withIntermediateDirectories: true)
try Data("bundled".utf8).write(to: URL(fileURLWithPath: bundled))
try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bundled)
precondition(Bundled.resolveResource("com.qemu.it-agent.plist", fallbacks: [file]) == bundled)
print("PASS: non-executable guest resources, missing resources, bundle precedence; executable checks retained")
''')
    executable = work / 'Check.app/Contents/MacOS/check'
    executable.parent.mkdir(parents=True)
    (executable.parent.parent / 'Resources').mkdir()
    subprocess.run(['swiftc', '-module-cache-path', str(work/'modules'), str(root/'LightTouchMac/Bundled.swift'), str(source), '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(work)], check=True)
