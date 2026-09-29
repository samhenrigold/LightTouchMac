#!/usr/bin/env python3
"""Compile actual MediaSong preflight and verify the generated media fixtures."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root/'scripts'))
import sources  # the pinned checkouts (build-support/sources.json)
fixtures = sources.path('qemu-ios')/'contrib/it-harness/build/Payload/Harness.app'
if not fixtures.is_dir():
    print(f'SKIP: no harness fixtures at {fixtures}; build them with contrib/it-harness/build.sh in the pinned checkout (or set QEMU_IOS_DIR)'); raise SystemExit(0)
with tempfile.TemporaryDirectory(prefix='ltm-media-check-') as work:
    executable = Path(work)/'check'
    subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor',
        '-module-cache-path',str(Path(work)/'modules'),
        str(root/'LightTouchMac/MediaIdentity.swift'),str(root/'LightTouchMac/MediaSong.swift'),str(root/'tests/fixtures/media-preflight.swift'),
        '-o',str(executable)],check=True)
    raw = Path(work)/'raw.aac'
    ffmpeg = shutil.which('ffmpeg')
    assert ffmpeg, 'ffmpeg is required to generate the raw AAC test fixture'
    subprocess.run([ffmpeg,'-v','error','-i',str(fixtures/'aac.m4a'),'-c:a','copy','-f','adts',str(raw)],check=True)
    subprocess.run([str(executable),str(fixtures),str(raw)],check=True)
