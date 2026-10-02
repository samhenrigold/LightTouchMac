#!/usr/bin/env python3
"""Every Music-library tag and the cover art survive the way from a tagged file to the device's library writer.

Builds an AAC M4A (afconvert, tagged by ffmpeg with iTunes atoms and a PNG cover) and an MP3
(ffmpeg-encoded, with an iTunes-style ID3v2.3 tag: TCMP, TPE2, a JPEG APIC and an ID3v1-number genre), plus ID3-tagged ADTS AAC that must be converted without losing tags, runs the production
MediaSong.prepare on each, then the guest's own itmedia mapping (qemu-ios contrib/it-media/itmedia.c built with
-DITMEDIA_HOST_CHECK) on what AFC would stage. Checks the properties itmedia hands 7E18 MusicLibrary's
insertItemFromPurchaseFolder, the year it writes, and the cover it hands ArtworkCache for the native library's artwork ID: each field's value, and the decoded art's size and four quadrant colours.
A tag or the art dropped anywhere on the host or in the guest's mapping fails here; MusicLibrary itself
is the booted check (tests/sessions/check-media-metadata-guest.py).
"""
from pathlib import Path
import math
import plistlib
import sqlite3
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
    # Real ADTS AAC can carry ID3 tags. Conversion must preserve these separately
    # because AVAudioFile writes audio samples, not the source's metadata.
    subprocess.run([ffmpeg, '-v', 'error', '-i', str(work/'plain.m4a'),
                    '-c:a', 'copy', '-f', 'adts', str(work/'untagged.aac')], check=True)
    (work/'Song.aac').write_bytes(header + frames + (work/'untagged.aac').read_bytes())
    # Same AAC samples with different readable tags are distinct import candidates.
    other_frames = frames.replace(text('TIT2', 'Tagged Tïtle'), text('TIT2', 'Another Title'), 1)
    size = len(other_frames)
    other_header = b'ID3\3\0\0' + bytes([(size >> 21) & 127, (size >> 14) & 127, (size >> 7) & 127, size & 127])
    (work/'Other.aac').write_bytes(other_header + other_frames + (work/'untagged.aac').read_bytes())
    failures = []
    identities = {}
    for name, genre in (('Song.m4a', 'Synthpop'), ('Song.mp3', 'Rock'), ('Song.aac', 'Rock')):
        out = work/(name + '.out')
        out.mkdir()
        prepared = subprocess.run([str(executable), str(work/name), str(out)],
                                  capture_output=True, text=True)
        if prepared.returncode:
            print(f'{name}: preparation failed ({prepared.returncode})\n{prepared.stdout}\n{prepared.stderr}')
            raise SystemExit(1)
        staging = prepared.stdout.strip()
        identities[name] = staging
        subprocess.run([str(mapping), str(out/'metadata.plist'), staging, str(out/'guest.plist')], check=True)
        guest = plistlib.loads((out/'guest.plist').read_bytes())
        properties = guest['properties']
        expected = {'itemName': COMMON['title'], 'artistName': COMMON['artist'], 'playlistName': COMMON['album'],
                    'playlistArtistName': COMMON['album_artist'], 'composerName': COMMON['composer'], 'genre': genre,
                    'trackNumber': 3, 'trackCount': 12, 'discNumber': 2, 'discCount': 3, 'compilation': True,
                    'kind': 'song',
                    'com.apple.iTunesStore.downloadInfo': {'mediaAssetFilename': 'audio.m4a' if Path(name).suffix == '.aac' else 'audio' + Path(name).suffix}}
        for field, value in expected.items():
            if properties.get(field) != value:
                failures.append(f'{name}: MusicLibrary {field} = {properties.get(field)!r}, expected {value!r}')
        supplied_duration = plistlib.loads((out/'metadata.plist').read_bytes())['duration_ms']
        if not isinstance(properties.get('duration'), int) or properties['duration'] != max(1, int(supplied_duration + 0.5)):
            failures.append(f'{name}: purchase duration is not whole milliseconds: {properties.get("duration")!r}')
        if not 2900 < properties.get('duration', 0) < 3200:
            failures.append(f'{name}: MusicLibrary duration = {properties.get("duration")!r}')
        if 'itemId' in properties:   # the artwork key: allocated at import from the library (below), not by the mapping
            failures.append(f'{name}: the mapping chose itemId {properties["itemId"]!r} before the library allocated it')
        if guest.get('year') != COMMON['year']:
            failures.append(f'{name}: item year = {guest.get("year")!r}, expected {COMMON["year"]}')
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
    other_out = work/'Other.aac.out'
    other_out.mkdir()
    other = subprocess.run([str(executable), str(work/'Other.aac'), str(other_out)],
                           check=True, capture_output=True, text=True).stdout.strip()
    if other == identities['Song.aac']:
        failures.append('different AAC tags collapsed into one import identity')
    # Invalid numeric tags must fail rather than being truncated or redirected.
    valid = plistlib.loads((out/'metadata.plist').read_bytes())
    for key, value in [('track_number', 3.5), ('year', 1987.5), ('artwork', '../cover.jpg')]:
        bad = work/'bad.plist'
        bad.write_bytes(plistlib.dumps(valid | {key: value}))
        result = subprocess.run([str(mapping), str(bad), staging, str(work/'bad-out.plist')], capture_output=True)
        if result.returncode != 1:
            failures.append(f'invalid {key} was accepted: {result.returncode}')
    # The ArtworkCache key (= the purchase itemId) is the library's MAX(artwork_cache_id)+1 for each song with
    # art: itmedia's own read_query/next_artwork_id, compiled for the Mac against a scratch Library.itdb.
    c = itmedia.read_text()
    a, b = c.index('static __typeof__(sqlite3_open_v2) *sql_open;'), c.index('static void import_artwork(')
    library = work/'library'; library.mkdir()
    (work/'alloc.c').write_text('#include <stdio.h>\n#include <unistd.h>\n#include <sqlite3.h>\n'
        f'#define LIBRARY "{library}/"\n'
        'static void fail(const char *r) { fprintf(stderr, "%s\\n", r); _exit(1); }\n' + c[a:b] +
        'int main(void) { sql_open = sqlite3_open_v2; sql_timeout = sqlite3_busy_timeout; sql_exec = sqlite3_exec;'
        ' sql_prepare = sqlite3_prepare_v2; sql_bind = sqlite3_bind_text; sql_column = sqlite3_column_int64;'
        ' sql_step = sqlite3_step; sql_finalize = sqlite3_finalize; sql_close = sqlite3_close; sql_error = sqlite3_errmsg;'
        ' printf("%u\\n", next_artwork_id()); return 0; }\n')
    subprocess.run(['xcrun', 'clang', '-w', '-o', str(work/'alloc'), str(work/'alloc.c'), '-lsqlite3'], check=True)
    with sqlite3.connect(library/'Library.itdb') as db:
        db.execute('CREATE TABLE item (pid INTEGER PRIMARY KEY, artwork_cache_id INTEGER)')
    def allocate():
        r = subprocess.run([str(work/'alloc')], capture_output=True, text=True)
        return int(r.stdout) if r.returncode == 0 else None
    for songs, want in (([], 1), ([1], 2), ([0], 2), ([2], 3), ([41], 42), ([0xfffffffe], 0xffffffff), ([0xffffffff], None)):
        with sqlite3.connect(library/'Library.itdb') as db:   # songs imported since: with art (an id) or without (0)
            db.executemany('INSERT INTO item (artwork_cache_id) VALUES (?)', [(v,) for v in songs])
        if (got := allocate()) != want:
            failures.append(f'artwork key after importing {songs}: {got!r}, expected {want!r} (MAX(artwork_cache_id)+1)')
    if failures:
        print('FAIL:\n  ' + '\n  '.join(failures)); sys.exit(1)
    print('PASS: M4A, MP3 and converted ADTS AAC title/artist/album/album artist/composer/genre/track/disc/year/compilation/duration and cover art reach MusicLibrary and ArtworkCache; artwork keys are MAX+1 per song')
