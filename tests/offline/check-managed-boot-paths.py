#!/usr/bin/env python3
"""Real DeviceInstance paths and managed boot authority; no helper, storage mutation or guest.

Fixtures exercise supported published/development/generation layouts and aliases.
The GUI calls this read-only authority before DeviceProcess construction; actual
GUI compilation is a separate gate. Explicit CLI raw sources never call it.
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import host_runtime
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='ltm-managed-boot-') as tmp:
    subprocess.run(['xcrun', 'swiftc', *host_runtime.swift_flags(root), '-parse-as-library',
                    '-module-cache-path', tmp + '/modules',
                    *[str(root / p) for p in ['LightTouchMac/Library/DeviceStateStorage.swift',
                                             'LightTouchMac/Library/DeviceInstance.swift',
                                             'LightTouchMac/Library/StorageLocations.swift',
                                             'LightTouchMac/Library/FirmwareCatalog.swift',
                                             'Packages/FirmwareKit/Sources/FirmwareSchema/FirmwareWire.swift',
                                             'LightTouchMac/Device/DeviceProfile.swift',
                                             'LightTouchMac/Device/DeviceProfile+Display.swift',
                                             'tests/fixtures/managed-boot-paths.swift']],
                    '-o', tmp + '/check'], check=True)
    subprocess.run([tmp + '/check'], check=True)
