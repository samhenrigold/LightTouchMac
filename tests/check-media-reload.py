#!/usr/bin/env python3
"""The real reload command restores SpringBoard on success and write failure."""
from pathlib import Path
import os
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "LightTouchMac/DeviceTools.swift").read_text()
start = source.index("    private func reloadMediaCompositor(")
end = source.index("    static func lockButtonPreferences(", start)
method = source[start:end].replace("private func", "func")
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    swift = root / "check.swift"
    swift.write_text("import Foundation\nstruct Check {\n" + method + """
        func guestRun(_ command: String, stdinPath: String?) async throws { print(command) }
    }
    @main struct Main {
        static func main() async throws {
            try await Check().reloadMediaCompositor(preferencesFile: "test")
        }
    }
    """)
    executable = root / "check"
    subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(executable)], check=True)
    command = subprocess.check_output([str(executable)], text=True)
    preferences = root / "preferences.plist"
    command = command.replace("/var/mobile/Library/Preferences/com.apple.springboard.plist", str(preferences))
    command = command.replace("/System/Library/LaunchDaemons/com.apple.SpringBoard.plist", str(root / "job.plist"))
    for name, contents in {
        "launchctl": '#!/bin/sh\necho "$1" >> "$CALLS"\n',
        "chown": '#!/bin/sh\nexit "$FAIL_WRITE"\n',
        "sync": '#!/bin/sh\nexit 0\n',
    }.items():
        path = root / name
        path.write_text(contents)
        path.chmod(0o755)
    calls = root / "calls"
    for failure in [0, 1]:
        preferences.write_bytes(b"original")
        calls.write_text("")
        env = dict(os.environ, PATH=str(root) + ":/usr/bin:/bin", CALLS=str(calls), FAIL_WRITE=str(failure))
        result = subprocess.run(["/bin/sh", "-c", command], input=b"updated", env=env)
        assert (result.returncode != 0) == bool(failure)
        assert calls.read_text().splitlines() == ["unload", "load"]
        assert preferences.read_bytes() == (b"original" if failure else b"updated")
print("PASS: stopped-before-write ordering, atomic preference replacement, reload after failure")
