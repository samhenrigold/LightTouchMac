#!/usr/bin/env python3
"""A failed install row shows one short reason, never the installer transcript."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'LightTouchMac/DeviceTools.swift').read_text()
a = s.index('    static func installFailureReason(')
b = s.index('\n    }\n', a) + len('\n    }\n')
source = 'import Foundation\nenum T {\n' + s[a:b] + r'''}
let transcript = """
--- Evernote.ipa  bundle  com.evernote.iPhone.Evernote
Copying to device...
Install: StagingPackage (10%)
ERROR: Install failed. Got error "APIInternalError" with code 0xe8000001
"""
let reason = T.installFailureReason(transcript)
precondition(reason == "Couldn’t install: Install failed. Got error \"APIInternalError\" with code 0xe8000001", reason)
precondition(!reason.contains("---") && !reason.contains("\n"))
precondition(T.installFailureReason("--- x.ipa  bundle  com.x\nCopying to device...\n").hasSuffix("Open Device Logs for details."))
precondition(T.installFailureReason("ERROR: " + String(repeating: "x", count: 300)).count < 110)
print("PASS: failed installs show the installer's error line or a pointer to the log, short")
'''
with tempfile.TemporaryDirectory() as work:
    p = Path(work) / 'check.swift'; p.write_text(source)
    subprocess.run(['swiftc', '-module-cache-path', '/tmp/ltm-module-cache', str(p), '-o', str(Path(work) / 'check')], check=True)
    subprocess.run([str(Path(work) / 'check')], check=True)
