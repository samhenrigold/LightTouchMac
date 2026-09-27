#!/usr/bin/env python3
"""The iPad capture rotation turns a panel frame the way the window shows it."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'LightTouchMac/DisplayView.swift').read_text()
a = s.index('    private static func rotated(')
b = s.index('\n    }\n', a) + len('\n    }\n')
source = 'import CoreGraphics\nimport Foundation\nenum V {\n' + s[a:b].replace('private static', 'static') + '''}
// 2x1 image, red pixel on the left; y-up CG space.
let ctx = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
let image = ctx.makeImage()!
func redAt(_ img: CGImage) -> (Int, Int) {   // top-left origin
    let data = img.dataProvider!.data! as Data, row = img.bytesPerRow
    for y in 0..<img.height { for x in 0..<img.width where data[y * row + x * 4] > 128 { return (x, y) } }
    return (-1, -1)
}
// Clockwise quarter: left -> top. Three quarters (counter-clockwise): left -> bottom.
let cw = V.rotated(image, clockwiseQuarterTurns: 1)!, ccw = V.rotated(image, clockwiseQuarterTurns: 3)!
precondition(cw.width == 1 && cw.height == 2 && redAt(cw) == (0, 0), "cw \\(redAt(cw))")
precondition(redAt(ccw) == (0, 1), "ccw \\(redAt(ccw))")
precondition(redAt(V.rotated(image, clockwiseQuarterTurns: 2)!) == (1, 0))
print("PASS: panel captures rotate by quarter turns")
'''
with tempfile.TemporaryDirectory() as work:
    p = Path(work) / 'check.swift'; p.write_text(source)
    exe = Path(work) / 'check'
    subprocess.run(['swiftc', '-module-cache-path', '/tmp/ltm-module-cache', str(p), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
