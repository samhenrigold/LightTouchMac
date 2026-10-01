#!/usr/bin/env python3
"""Every Music-library tag and the cover art survive the way from a tagged file to the device's library writer.

Builds an AAC M4A (afconvert, tagged by ffmpeg with iTunes atoms and a PNG cover) and an MP3
(ffmpeg-encoded, with an iTunes-style ID3v2.3 tag: TCMP, TPE2, a JPEG APIC and an ID3v1-number genre), runs the production
MediaSong.prepare on each, then the guest's own itmedia mapping (qemu-ios contrib/it-media/itmedia.c built with
-DITMEDIA_HOST_CHECK) on what AFC would stage. Checks the properties itmedia hands 7E18 MusicLibrary's
insertItemFromPurchaseFolder, the year it writes, and the cover it hands ArtworkCache under the key MusicLibrary
reads (the item's itemId): each field's value, and the decoded art's size and four quadrant colours.
A tag or the art dropped anywhere on the host or in the guest's mapping fails here; MusicLibrary itself
is the booted check (tests/sessions/check-media-metadata-guest.py).
"""
from pathlib import Path
import math
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import wave
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root/'scripts'))
import sources
itmedia = sources.path('qemu-ios')/'contrib/it-media/itmedia.c'
if not itmedia.is_file():
    print(f'SKIP: no qemu-ios checkout at {itmedia.parent} (QEMU_IOS_DIR)'); raise SystemExit(0)
ffmpeg = shutil.which('ffmpeg')
if not ffmpeg:
    print('SKIP: ffmpeg is needed to tag the fixtures'); raise SystemExit(0)
QUADRANTS = [((0.25, 0.25), (200, 40, 40)), ((0.75, 0.25), (40, 180, 60)),
             ((0.25, 0.75), (40, 60, 200)), ((0.75, 0.75), (240, 220, 30))]
COMMON = {'title': 'Tagged Tïtle', 'artist': 'Track Artist', 'album': 'The Album',
          'album_artist': 'Album Artist', 'composer': 'Some Composer',
          'track_number': 3, 'track_count': 12, 'disc_number': 2, 'disc_count': 3,
          'year': 1987, 'compilation': True}
TAGS = ['-metadata', 'title=Tagged Tïtle', '-metadata', 'artist=Track Artist', '-metadata', 'album=The Album',
        '-metadata', 'album_artist=Album Artist', '-metadata', 'composer=Some Composer',
        '-metadata', 'track=3/12', '-metadata', 'disc=2/3', '-metadata', 'date=1987', '-metadata', 'compilation=1']

with tempfile.TemporaryDirectory(prefix='ltm-media-metadata-') as work:
    work = Path(work)
    executable = work/'prepare'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-default-isolation', 'MainActor',
        '-module-cache-path', str(work/'modules'),
        *[str(root/'LightTouchMac/Features'/f) for f in ('MediaIdentity.swift', 'MediaSong.swift', 'MediaPhoto.swift')],
        str(root/'tests/fixtures/media-metadata.swift'), '-o', str(executable)], check=True)
    mapping = work/'itmedia-host'
    subprocess.run(['xcrun', 'clang', '-DITMEDIA_HOST_CHECK', '-o', str(mapping), str(itmedia)], check=True)
    cover = Image.new('RGB', (1000, 1000))
    draw = ImageDraw.Draw(cover)
    for (x, y), colour in QUADRANTS:
        draw.rectangle((int((x-0.25)*1000), int((y-0.25)*1000), int((x+0.25)*1000)-1, int((y+0.25)*1000)-1), fill=colour)
    cover.save(work/'cover.png'); cover.save(work/'cover.jpg', quality=95)
    with wave.open(str(work/'tone.wav'), 'wb') as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100)
        w.writeframes(b''.join(struct.pack('<hh', s, s) for s in
                      (int(8000*math.sin(2*math.pi*440*i/44100)) for i in range(44100*3))))
    subprocess.run(['afconvert', '-f', 'm4af', '-d', 'aac', '-b', '128000', str(work/'tone.wav'), str(work/'plain.m4a')], check=True)
    subprocess.run([ffmpeg, '-v', 'error', '-i', str(work/'plain.m4a'), '-i', str(work/'cover.png'), '-map', '0', '-map', '1',
                    '-c', 'copy', '-disposition:v', 'attached_pic', *TAGS, '-metadata', 'genre=Synthpop', str(work/'Song.m4a')], check=True)
    # The MP3 carries the ID3v2.3 frames iTunes writes (TCMP, TPE2, a "(17)" TCON), built here
    # rather than by ffmpeg, which files the compilation flag under TXXX.
    subprocess.run([ffmpeg, '-v', 'error', '-i', str(work/'tone.wav'), '-c:a', 'libmp3lame', '-b:a', '128k',
                    '-id3v2_version', '0', '-write_id3v1', '0', str(work/'untagged.mp3')], check=True)
    def frame(ident, body): return ident.encode() + struct.pack('>I', len(body)) + b'\0\0' + body
    def text(ident, value): return frame(ident, b'\1' + value.encode('utf-16'))   # UTF-16 with BOM
    frames = b''.join(text(k, v) for k, v in [('TIT2', 'Tagged Tïtle'), ('TPE1', 'Track Artist'), ('TALB', 'The Album'),
        ('TPE2', 'Album Artist'), ('TCOM', 'Some Composer'), ('TRCK', '3/12'), ('TPOS', '2/3'), ('TYER', '1987'),
        ('TCON', '(17)'), ('TCMP', '1')])
    frames += frame('APIC', b'\0image/jpeg\0\3\0' + (work/'cover.jpg').read_bytes())
    size = len(frames)
    header = b'ID3\3\0\0' + bytes([(size >> 21) & 127, (size >> 14) & 127, (size >> 7) & 127, size & 127])
    (work/'Song.mp3').write_bytes(header + frames + (work/'untagged.mp3').read_bytes())
    failures = []
    for name, genre in (('Song.m4a', 'Synthpop'), ('Song.mp3', 'Rock')):
        out = work/(name + '.out')
        out.mkdir()
        staging = subprocess.run([str(executable), str(work/name), str(out)], check=True,
                                 capture_output=True, text=True).stdout.strip()
        subprocess.run([str(mapping), str(out/'metadata.plist'), staging, str(out/'guest.plist')], check=True)
        guest = plistlib.loads((out/'guest.plist').read_bytes())
        properties = guest['properties']
        key = int(staging[:8], 16) & 0x7fffffff or 1
        expected = {'itemName': COMMON['title'], 'artistName': COMMON['artist'], 'playlistName': COMMON['album'],
                    'playlistArtistName': COMMON['album_artist'], 'composerName': COMMON['composer'], 'genre': genre,
                    'trackNumber': 3, 'trackCount': 12, 'discNumber': 2, 'discCount': 3, 'compilation': True,
                    'kind': 'song', 'itemId': key,
                    'com.apple.iTunesStore.downloadInfo': {'mediaAssetFilename': 'audio' + Path(name).suffix}}
        for field, value in expected.items():
            if properties.get(field) != value:
                failures.append(f'{name}: MusicLibrary {field} = {properties.get(field)!r}, expected {value!r}')
        if not 2900 < properties.get('duration', 0) < 3200:
            failures.append(f'{name}: MusicLibrary duration = {properties.get("duration")!r}')
        if guest.get('year') != COMMON['year']:
            failures.append(f'{name}: item year = {guest.get("year")!r}, expected {COMMON["year"]}')
        if guest.get('artworkKey') != str(key):
            failures.append(f'{name}: ArtworkCache key = {guest.get("artworkKey")!r}, expected {str(key)!r} (the itemId)')
        art = out/guest.get('artwork', 'artwork.jpg')
        if not art.is_file():
            failures.append(f'{name}: no cover handed to ArtworkCache'); continue
        with Image.open(art) as image:
            if image.format != 'JPEG' or image.info.get('progressive') or image.size != (640, 640):
                failures.append(f'{name}: artwork is {image.format} {image.size} progressive={image.info.get("progressive")}')
            rgb = image.convert('RGB')
            for (x, y), colour in QUADRANTS:
                actual = rgb.getpixel((int(x*image.width), int(y*image.height)))
                if any(abs(a-b) > 12 for a, b in zip(actual, colour)):
                    failures.append(f'{name}: artwork pixel at {(x, y)} is {actual}, expected {colour}')
    if failures:
        print('FAIL:\n  ' + '\n  '.join(failures)); sys.exit(1)
    print('PASS: M4A and MP3 title/artist/album/album artist/composer/genre/track/disc/year/compilation/duration and cover art reach MusicLibrary and ArtworkCache')
