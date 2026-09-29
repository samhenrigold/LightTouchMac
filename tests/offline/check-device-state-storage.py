#!/usr/bin/env python3
"""DeviceStateStorage compiled whole against tests/fixtures/device-state-storage.swift (erase GC, removable checks)."""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='ltm-device-state-') as tmp:
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', tmp + '/modules', str(root / 'LightTouchMac/Library/DeviceStateStorage.swift'),
                    str(root / 'tests/fixtures/device-state-storage.swift'), '-o', tmp + '/check'], check=True)
    subprocess.run([tmp + '/check'], check=True)
