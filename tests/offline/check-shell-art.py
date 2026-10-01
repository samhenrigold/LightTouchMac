#!/usr/bin/env python3
"""Every catalog board has its own flat picture (the prepare screen's art, DisplayView's fallback shell).

Compiles DeviceProfile(+Display) whole and asks it, for each board in the shipped firmware catalog, which asset
(shellImageName) and shell size it uses. Fails when a board has no profile or no asset, when two boards share an
asset name or identical pixels (the 1G showing the 2G's shell was the bug), or when an asset's size is not the
profile's shellPixels (the screen cutout and Home circle are placed in those pixels).
"""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
import hashlib, json, subprocess, tempfile
from PIL import Image

root = Path(__file__).resolve().parents[2]
assets = root / 'LightTouchMac/Assets.xcassets'
boards = sorted({e['board'] for e in json.loads((root / 'LightTouchMac/Resources/firmware-catalog.json').read_text())['entries']})

with tempfile.TemporaryDirectory(prefix='ltm-shell-art-') as tmp:
    tmp = Path(tmp)
    (tmp / 'main.swift').write_text('''import Foundation
for board in CommandLine.arguments.dropFirst() {
    guard let p = [DeviceProfile.iPodTouch2G, .iPad1, .iPodTouch1G].first(where: { $0.boardID == board }) else { print(board, "-"); continue }
    let c = p.screenCutout
    print(board, p.shellImageName, Int(p.shellPixels.width), Int(p.shellPixels.height), Int(c.midX), Int(c.midY), Int(c.minY / 2))
}
''')
    subprocess.run(['xcrun', 'swiftc', *host_runtime.swift_flags(Path(__file__).resolve().parents[2]), '-module-cache-path', str(tmp / 'modules'), str(root / 'LightTouchMac/Device/DeviceProfile.swift'),
                    str(root / 'LightTouchMac/Device/DeviceProfile+Display.swift'), str(tmp / 'main.swift'), '-o', str(tmp / 'art')], check=True)
    rows = [line.split() for line in subprocess.check_output([tmp / 'art', *boards], text=True).splitlines()]

seen = {}
tones = {}
for board, name, *size in rows:
    size, (cx, cy, above) = size[:2], map(int, size[2:])
    assert name != '-', f'{board}: no DeviceProfile'
    imageset = assets / f'{name}.imageset'
    files = json.loads((imageset / 'Contents.json').read_text())['images']
    png = imageset / files[0]['filename']
    digest = hashlib.sha256(png.read_bytes()).hexdigest()
    for other, (other_name, other_digest) in seen.items():
        assert name != other_name, f'{board} and {other} share the picture {name}'
        assert digest != other_digest, f'{board} ({name}) and {other} ({other_name}) are the same image'
    seen[board] = (name, digest)
    w, h = Image.open(png).size
    assert (w, h) == (int(size[0]), int(size[1])), f'{board}: {png.name} is {w}x{h}, profile shellPixels {size}'
    rgb = Image.open(png).convert('RGB')
    tones[board] = (rgb.getpixel((cx, cy)), rgb.getpixel((cx, above)))   # the screen-off LCD, the glass above it
    print(f'{board}: {name} ({png.name}, {w}x{h}), LCD {tones[board][0]}, glass {tones[board][1]}')
# The two iPods are drawn as siblings: the 1G art uses the 2G photo's LCD and glass tones (not a render's pure black).
for a, b in zip(tones['n45ap'], tones['n72ap']):
    assert max(abs(x - y) for x, y in zip(a, b)) <= 6, f'n45ap art tones {tones["n45ap"]} differ from n72ap {tones["n72ap"]}'
print(f'PASS: {len(seen)} catalog boards, each with its own picture; the iPods share one palette')
