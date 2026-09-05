#!/usr/bin/env python3
"""Compile the real zoom calculations and check pixel scale and step boundaries."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1] / "LightTouchMac"
display = (root / "DisplayView.swift").read_text()
controller = (root / "MainWindowController.swift").read_text()

def block(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]

source = "import Cocoa\n" + block(display, "enum ZoomMode:") + """
final class Screen {
    static let nativeScreenPixels = CGSize(width: 320, height: 480)
    static let screenCutout = CGRect(x: 74, y: 213, width: 594, height: 891)
    struct Window { var backingScaleFactor: CGFloat }
    var window: Window? = Window(backingScaleFactor: 2)
    var appliedScale: CGFloat = 1
""" + block(display, "var pixelMultiple:") + "\n" + block(display, "private func shellScale(").replace("private ", "") + """
}
final class Controller {
    struct Device { let screen = Screen() }
    let deviceVC = Device()
    var zoom = ZoomMode.fit
    func apply(_ value: ZoomMode) { zoom = value }
""" + block(controller, "func stepZoom(") + """
}
let c = Controller()
let s = c.deviceVC.screen
for backing: CGFloat in [1, 2] {
    s.window = Screen.Window(backingScaleFactor: backing)
    for step in ZoomMode.steps {
        s.appliedScale = s.shellScale(guestPixelsPerDisplayPixel: step)
        assert(abs(s.pixelMultiple - CGFloat(step)) < 0.00001)
    }
}
s.appliedScale = s.shellScale(guestPixelsPerDisplayPixel: 2) * 1.2
c.stepZoom(1); assert(c.zoom == .pixels(3))
c.stepZoom(-1); assert(c.zoom == .pixels(2))
s.appliedScale = s.shellScale(guestPixelsPerDisplayPixel: 8)
c.stepZoom(1); assert(c.zoom == .pixels(8))
s.appliedScale = s.shellScale(guestPixelsPerDisplayPixel: 1)
c.stepZoom(-1); assert(c.zoom == .pixels(1))
print("PASS: backing scale, manual pixel scale, fit-to-step transitions and limits")
"""
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "check.swift"
    path.write_text(source)
    executable = Path(directory) / "check"
    subprocess.run(["swiftc", str(path), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
