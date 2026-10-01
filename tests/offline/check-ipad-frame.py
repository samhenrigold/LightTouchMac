#!/usr/bin/env python3
"""The iPad frame asset must match the profile's shell size, screen cutout and Home circle.

Compiles DeviceProfile+Display.swift whole and reads the iPad's geometry from it. With a screenshot
argument (a 1024x768 panel dump from qemu-ios docs/ipad1/screens), also writes
docs/ipad-frame/composite-check.png: the frame with the panel turned upright into the cutout, the way
DisplayView draws it."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
import subprocess, sys, tempfile
from PIL import Image

root = Path(__file__).resolve().parents[2]
frame = Image.open(root / 'LightTouchMac/Assets.xcassets/ipad-frame.imageset/ipad-frame.png').convert('RGBA')

with tempfile.TemporaryDirectory(prefix='ltm-ipad-frame-') as tmp:
    tmp = Path(tmp)
    (tmp / 'main.swift').write_text('''import Foundation
let p = DeviceProfile.iPad1
print(Int(p.shellPixels.width), Int(p.shellPixels.height), Int(p.screenCutout.minX), Int(p.screenCutout.minY),
      Int(p.screenCutout.width), Int(p.screenCutout.height), p.homeButtonDiameter, p.homeButtonBottomInset)
''')
    subprocess.run(['xcrun', 'swiftc', *host_runtime.swift_flags(Path(__file__).resolve().parents[2]), '-module-cache-path', str(tmp / 'modules'), str(root / 'LightTouchMac/Device/DeviceProfile.swift'),
                    str(root / 'LightTouchMac/Device/DeviceProfile+Display.swift'), str(tmp / 'main.swift'), '-o', str(tmp / 'geometry')], check=True)
    values = subprocess.check_output([tmp / 'geometry'], text=True).split()
shell = (int(values[0]), int(values[1]))
cut = tuple(int(v) for v in values[2:6])
diameter, inset = float(values[6]), float(values[7])

assert frame.size == shell, (frame.size, shell)
x, y, w, h = cut
assert (w, h) == (768, 1024) and x * 2 + w == shell[0] and y * 2 + h == shell[1], cut
# The glass is opaque black where the screen goes; the Home button is lighter than the glass around it.
cy = shell[1] - inset - diameter / 2
r = diameter / 2
button = frame.crop((int(shell[0] / 2 - r), int(cy - r), int(shell[0] / 2 + r), int(cy + r))).convert('L')
beside = frame.crop((int(shell[0] / 2 + 2 * r), int(cy - r), int(shell[0] / 2 + 4 * r), int(cy + r))).convert('L')
assert button.getextrema()[1] > beside.getextrema()[1] + 60, (button.getextrema(), beside.getextrema())
print('PASS: frame %dx%d, screen at (%d,%d) %dx%d, Home circle d=%g at y=%g'
      % (shell + cut + (diameter, cy)))

if len(sys.argv) > 1:
    panel = Image.open(sys.argv[1]).convert('RGBA').rotate(90, expand=True)   # panelRotation -pi/2
    out = frame.copy()
    out.paste(panel, (x, y))
    dst = root / 'docs/ipad-frame/composite-check.png'
    out.save(dst)
    print('wrote', dst)
