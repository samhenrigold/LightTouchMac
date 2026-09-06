#!/usr/bin/env python3
"""Exercise production chassis mouse dragging independently of trackpad input."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'LightTouchMac/DisplayView.swift').read_text()
a = s.index('    override func mouseDragged(')
b = s.index('\n    override func mouseUp(', a)
method = s[a:b]
source = r'''import Cocoa
let QEMU_IOS_TOUCH_UPDATE = 1
@MainActor class Sink { func mouseDragged(with event: NSEvent) {} }
@MainActor final class Check: Sink {
 var tilting = true
 var modelView: NSObject? = NSObject()
 var grabPoint = CGPoint.zero, grabAngle = 0.0
 var tiltAngle = 0.0, pitchAngle = 0.0, restAngle = 0.0
 static let rotationGain = 0.4
 var attitudes = 0, guestUpdates = 0, shellAngle = 0.0
 func convert(_ point: CGPoint, from: NSView?) -> CGPoint { point }
 func mouseAngle(_ event: NSEvent) -> CGFloat { atan2(event.locationInWindow.y, event.locationInWindow.x) }
 func setShellAngle(_ angle: CGFloat) { shellAngle = angle }
 func sendAttitude() { attitudes += 1 }
 func emit(_ event: NSEvent, _ phase: Int32) { precondition(phase == QEMU_IOS_TOUCH_UPDATE); guestUpdates += 1 }
''' + method + r'''
 func drag(_ x: CGFloat, _ y: CGFloat) {
  let e = NSEvent.mouseEvent(with:.leftMouseDragged, location:CGPoint(x:x,y:y),
    modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!
  mouseDragged(with:e)
 }
 func run() {
  grabPoint = CGPoint(x:10,y:20)
  drag(35,70);precondition(abs(tiltAngle + 0.1)<1e-10 && abs(pitchAngle + 0.2)<1e-10)
  drag(-15,-30);precondition(abs(tiltAngle - 0.1)<1e-10 && abs(pitchAngle - 0.2)<1e-10)
  drag(10000,-10000);precondition(tiltAngle == -.pi/4 && pitchAngle == .pi/4)
  for rest in [0.0,Double.pi/2,Double.pi,-Double.pi/2] {
   restAngle = rest;drag(35,70);precondition(abs(shellAngle - (rest-0.1))<1e-10)
  }
  modelView = nil;grabAngle = 0
  drag(1,1);precondition(abs(tiltAngle + .pi/4*Self.rotationGain)<1e-10)
  grabAngle = .pi-0.1;drag(cos(-Double.pi+0.1),sin(-Double.pi+0.1))
  precondition(abs(tiltAngle + 0.2*Self.rotationGain)<1e-10)
  precondition(guestUpdates == 0)
  let count=attitudes;tilting=false;drag(1,1)
  precondition(guestUpdates == 1 && attitudes == count)
  print("PASS: opposite Cartesian/polar chassis drag, bounds, orientation, wraparound and guest-touch routing")
 }
}
@main struct Main { @MainActor static func main() { Check().run() } }
'''
with tempfile.TemporaryDirectory(prefix='ltm-chassis-') as work:
    work = Path(work)
    source_file = work / 'check.swift'
    source_file.write_text(source)
    exe = work / 'check'
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(work/'modules'),
                    str(source_file), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
