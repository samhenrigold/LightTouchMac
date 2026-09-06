#!/usr/bin/env python3
"""Check the production layer transforms across layout, repeated tilt and release."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'LightTouchMac/DisplayView.swift').read_text()
transform=next(line.strip() for line in s.splitlines() if 'contentLayer.transform = CATransform3DMakeRotation' in line)
a=s.index('    private func setShellAngle('); b=s.index('    /// Is a mouse-driven touch',a)
methods=s[a:b].replace('private func','func')
c=s.index('    private func motionTransform(');d=s.index('    private func sendAttitude()',c)
methods=s[c:d].replace('private func','func')+methods
source='''import Cocoa
import QuartzCore
@MainActor final class Check {
 let shellLayer = CALayer(), contentLayer = CALayer()
 let homeButton = NSButton()
 var pitchAngle = 0.0, scrollPitch = 0.0
 var motionRestAngle: CGFloat?
 func sendAttitude() {}
 let emulator: Emulator? = nil
 var appliedScale = 1.0, restAngle = 0.0, tiltAngle = 0.0, scrollTilt = 0.0
 var tilting = false, scrollTilting = false
 class Emulator { func setTilt(angle: Double) {} }
''' + methods + '''
 func run() {
  for rest in [0.0, Double.pi / 2, Double.pi, -Double.pi / 2] {
   restAngle = rest
   for tilt in [0.2, -0.3, 0.0, 0.4] {
    tiltAngle = tilt
    pitchAngle = tilt / 2
    scrollPitch = pitchAngle
    motionRestAngle = rest
    let angle = rest + tilt
    _ = angle
    ''' + transform + '''
    setShellAngle(angle)
    endTilt()
    let combined = CATransform3DConcat(contentLayer.transform, shellLayer.transform)
    precondition(abs(combined.m11 - 1) < 0.00001 && abs(combined.m12) < 0.00001)
    precondition(tiltAngle == 0 && scrollTilt == 0 && !scrollTilting)
    precondition(pitchAngle == 0 && scrollPitch == 0 && motionRestAngle == nil && !homeButton.isHidden)
    precondition(abs(combined.m13) < 0.00001 && abs(combined.m23) < 0.00001)
   }
  }
  print("PASS: layouts during repeated tilt return the screen and shell to the same orientation")
 }
}
@main struct Main { @MainActor static func main() { Check().run() } }
'''
with tempfile.TemporaryDirectory() as work:
    p=Path(work)/'check.swift'; p.write_text(source)
    exe=Path(work)/'check'
    subprocess.run(['swiftc','-parse-as-library','-module-cache-path','/tmp/ltm-module-cache',str(p),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
