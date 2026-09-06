#!/usr/bin/env python3
"""Rebuild the bundled RealityKit studio environment (NumPy, Pillow, Xcode).

Broad cool reflection bands describe the rolled chrome. A front softbox's
lower edge gives the concave Home button its dark-to-light falloff.
Radiance is stored at quarter intensity; DeviceModelView restores two stops.
"""
import numpy as np
from pathlib import Path
w,h=512,256
u,v=np.meshgrid((np.arange(w)+.5)/w,(np.arange(h)+.5)/h)
lon=(u-.5)*2*np.pi;lat=(.5-v)*np.pi
rz=np.cos(lat)*np.cos(lon);ry=np.sin(lat)
band=np.exp(-((rz+.1)/.32)**2)
front=np.clip((ry+.12)/.12,0,1);front=front*front*(3-2*front)
light=.005+1.5*band+2*front*np.clip((abs(rz)-.9)/.08,0,1)
rgb=light[...,None]*np.array([.92,.96,1.])
from PIL import Image
ldr=np.clip(rgb/4,0,1)
srgb=np.where(ldr<=.0031308,12.92*ldr,1.055*ldr**(1/2.4)-.055)
import subprocess, tempfile
with tempfile.TemporaryDirectory() as temporary:
    image = Path(temporary)/"N72Studio.png"
    Image.fromarray(np.uint8(srgb*255)).save(image)
    subprocess.run(["xcrun", "realitytool", "image", "--platform", "macosx",
        "--deployment-target", "14.0", "--cube-face-size", "256", "--specular-size", "256",
        "--output-reality-asset", str(Path(__file__).resolve().parents[1]/"LightTouchMac/N72Studio.realityenv"),
        str(image)], check=True)
