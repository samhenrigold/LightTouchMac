#!/usr/bin/env python3
"""Rebuild N45's rim-and-glass environment (NumPy, Pillow, Xcode): LightTouchMac/N45Rim.realityenv.

DeviceModelView lights only N45's graphite frame and cover glass with it; every other surface keeps
N72Studio. Apple's product shots light the brushed rim from the upper left: light there, falling to dark
at the lower right, with a soft highlight along the bevel. The glass (reflecting what is behind the
camera) shows a faint lighter sheen to the upper right of a diagonal. Radiance at quarter intensity, as
N72Studio; DeviceModelView restores two stops.
"""
import numpy as np, subprocess, tempfile
from pathlib import Path
from PIL import Image
w, h = 1024, 512
u, v = np.meshgrid((np.arange(w) + .5) / w, (np.arange(h) + .5) / h)
lon = (u - .5) * 2 * np.pi; lat = (.5 - v) * np.pi
# Direction per texel; the camera-facing (+z) side is the image centre.
x, y, z = np.cos(lat) * np.sin(lon), np.sin(lat), np.cos(lat) * np.cos(lon)
key = np.array([-.62, .62, -.48]); key /= np.linalg.norm(key)
along = x * key[0] + y * key[1] + z * key[2]
# Broad upper-left fill, then a soft key for the bevel highlight.
light = .08 + .9 * np.clip(along * .5 + .5, 0, 1) ** 2.2 + 1.2 * np.exp(-((1 - along) / .2) ** 2)
# The glass sheen: behind the camera (the flat glass mirrors only the few degrees around +z), brighter
# to the upper right of a soft diagonal through the view axis.
behind = np.clip((-z - .96) / .02, 0, 1)
t = np.clip((y + .9 * x - .06) / .02, 0, 1)
light += behind * .6 * t * t * (3 - 2 * t)
rgb = light[..., None] * np.array([.94, .97, 1.])
ldr = np.clip(rgb / 4, 0, 1)
srgb = np.where(ldr <= .0031308, 12.92 * ldr, 1.055 * ldr ** (1 / 2.4) - .055)
with tempfile.TemporaryDirectory() as temporary:
    image = Path(temporary) / "N45Rim.png"
    Image.fromarray(np.uint8(np.round(srgb * 255))).save(image)
    subprocess.run(["xcrun", "realitytool", "image", "--platform", "macosx",
        "--deployment-target", "14.0", "--cube-face-size", "256", "--specular-size", "256",
        "--output-reality-asset", str(Path(__file__).resolve().parents[1] / "LightTouchMac/N45Rim.realityenv"),
        str(image)], check=True)
