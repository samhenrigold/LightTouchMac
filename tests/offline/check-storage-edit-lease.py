#!/usr/bin/env python3
"""Execute the helper's actual lease function against stopped edit intents."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "LightTouchDevice/main.swift").read_text()
start = source.index("var leaseDescriptor: Int32 = -1")
end = source.index('\nif let service = arguments["--connect"]', start)
with tempfile.TemporaryDirectory(prefix="ltm-edit-lease-") as tmp:
    work = Path(tmp)
    main = work / "main.swift"
    main.write_text('import Foundation\nimport Darwin\nfunc helperLog(_ s: String) {}\n' + source[start:end] + r'''
let work = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("work")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
let path = work.appendingPathComponent("lease").path
precondition(takeLease(path), "stopped device must acquire lease")
close(leaseDescriptor); leaseDescriptor = -1
let edit = work.appendingPathComponent("edit.json")
try Data("{}".utf8).write(to: edit)
precondition(!takeLease(path), "durable edit must refuse helper boot")
precondition(leaseDescriptor == -1, "refusal must not retain lease")
try FileManager.default.removeItem(at: edit)
precondition(takeLease(path), "resolving edit must permit subsequent boot")
close(leaseDescriptor)
print("PASS: helper edit intent refusal and lease recovery")
''')
    exe = work / "probe"
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(work / "modules"), str(main), "-o", str(exe)], check=True)
    subprocess.run([str(exe), str(work)], check=True)
