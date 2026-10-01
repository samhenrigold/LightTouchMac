#!/usr/bin/env python3
"""Exercise production music preparation with tagged MP3/M4A and embedded covers."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
ffmpeg = shutil.which('ffmpeg')
assert ffmpeg, 'ffmpeg is required to generate the tagged audio fixtures'
with tempfile.TemporaryDirectory(prefix='ltm-music-tags-') as work:
    work = Path(work)
    executable = work / 'check'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-default-isolation', 'MainActor',
                    '-module-cache-path', str(work / 'modules'),
                    str(root / 'LightTouchMac/Features/MediaIdentity.swift'),
                    str(root / 'LightTouchMac/Features/MediaSong.swift'),
                    str(root / 'tests/fixtures/music-metadata.swift'), '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(work), 'cover'], check=True)
    tags = dict(title='Cover Song', artist='Track Artist', album='Cover Album', album_artist='Album Artist',
                composer='Fixture Composer', genre='Jazz', track='3/12', disc='2/3')
    for extension, codec in [('m4a', 'aac'), ('mp3', 'libmp3lame')]:
        command = [ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=2',
                   '-i', str(work / 'cover.jpg'), '-map', '0:a', '-map', '1:v',
                   '-c:a', codec, '-c:v', 'copy', '-disposition:v', 'attached_pic']
        for key, value in tags.items():
            command.extend(['-metadata', key + '=' + value])
        subprocess.run(command + [str(work / ('tagged.' + extension))], check=True)
    subprocess.run([ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', 'sine=duration=2',
                    '-c:a', 'aac', str(work / 'plain.m4a')], check=True)
    subprocess.run([str(executable), str(work)], check=True, timeout=60)
