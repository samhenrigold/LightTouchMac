#!/usr/bin/env python3
"""The iPad frame asset must match the profile's shell size, screen cutout and Home circle.

With a screenshot argument (a 1024x768 panel dump from qemu-ios docs/ipad1/screens),
also writes docs/ipad-frame/composite-check.png: the frame with the panel turned
upright into the cutout, the way DisplayView draws it."""
from pathlib import Path
import re, sys
from PIL import Image

root = Path(__file__).resolve().parents[1]
src = (root / 'LightTouchMac/DeviceProfile+Display.swift').read_text()
frame = Image.open(root / 'LightTouchMac/Assets.xcassets/ipad-frame.imageset/ipad-frame.png').convert('RGBA')

shell = tuple(map(int, re.search(r'case \.iPad1: CGSize\(width: (\d+), height: (\d+)\)', src).groups()))
cut = tuple(map(int, re.search(r'case \.iPad1: CGRect\(x: (\d+), y: (\d+), width: (\d+), height: (\d+)\)', src).groups()))
diameter = float(re.search(r'homeButtonDiameter: CGFloat \{ self == \.iPad1 \? ([\d.]+)', src).group(1))
inset = float(re.search(r'homeButtonBottomInset: CGFloat \{ self == \.iPad1 \? ([\d.]+)', src).group(1))

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
