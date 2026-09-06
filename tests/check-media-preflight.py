#!/usr/bin/env python3
"""Compile actual MediaSong preflight and verify the generated media fixtures."""
from pathlib import Path
import shutil
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
fixtures = root.parent/'qemu-ios/contrib/it-harness/build/Payload/Harness.app'
with tempfile.TemporaryDirectory(prefix='ltm-media-check-') as work:
    executable = Path(work)/'check'
    subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor',
        '-module-cache-path',str(Path(work)/'modules'),
        str(root/'LightTouchMac/MediaIdentity.swift'),str(root/'LightTouchMac/MediaSong.swift'),str(root/'tests/media-preflight.swift'),
        '-o',str(executable)],check=True)
    raw = Path(work)/'raw.aac'
    ffmpeg = shutil.which('ffmpeg')
    assert ffmpeg, 'ffmpeg is required to generate the raw AAC test fixture'
    subprocess.run([ffmpeg,'-v','error','-i',str(fixtures/'aac.m4a'),'-c:a','copy','-f','adts',str(raw)],check=True)
    subprocess.run([str(executable),str(fixtures),str(raw)],check=True)
