#!/usr/bin/env python3
"""Exercise production mouse/trackpad model manipulation without QEMU or a window."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'LightTouchMac/DisplayView.swift').read_text()
a = s.index('    override func mouseDragged(')
b = s.index('\n    override func mouseUp(', a)
methods = s[a:b]
a = s.index('    private func beginScrollTilt(')
b = s.index('    override func mouseDown(', a)
methods += s[a:b].replace('private ', '')
a = s.index('    override func scrollWheel(')
b = s.index('    private func guestScrollDrag(', a)
methods += s[a:b]
source = r'''import Cocoa
enum TouchPhase { static let begin: Int32 = 0, update: Int32 = 1, end: Int32 = 2 }
@MainActor class Sink {
 func mouseDragged(with event: NSEvent) {}
 func rotate(with event: NSEvent) {}
 func scrollWheel(with event: NSEvent) {}
}
final class Gesture: NSEvent {
 var eventPhase: NSEvent.Phase = .changed, momentum: NSEvent.Phase = []
 var dx = 0.0, dy = 0.0, degrees: Float = 0
 var precise = true, inverted = false, option = false
 override var phase: NSEvent.Phase { eventPhase }
 override var momentumPhase: NSEvent.Phase { momentum }
 override var scrollingDeltaX: CGFloat { dx }
 override var scrollingDeltaY: CGFloat { dy }
 override var hasPreciseScrollingDeltas: Bool { precise }
 override var isDirectionInvertedFromDevice: Bool { inverted }
 override var modifierFlags: NSEvent.ModifierFlags { option ? .option : [] }
 override var rotation: Float { degrees }
}
@MainActor final class Check: Sink {
 var tilting = true, rotatingChassis = false
 var modelView: NSObject? = NSObject()
 var grabPoint = CGPoint.zero
 var tiltAngle = 0.0, pitchAngle = 0.0, yawAngle = 0.0, restAngle = 0.0
 var scrollTilt = 0.0, scrollPitch = 0.0, scrollTilting = false
 var motionRestAngle: CGFloat?, scrollPoint: CGPoint?
 var wheelTiltResetTask: Task<Void, Never>?
 var touchInteractionEnabled = true, onPanel = false, pinchingGuest = false
 var attitudes = 0, guestUpdates = 0, shellAngle = 0.0, guestScrolls = 0
 static let scrollTiltGain = 0.0015
 let shellLayer = CALayer()
 struct Emulator { var rotationDegrees = 0 }
 var emulator: Emulator? = Emulator()
 static func layerAngle(_ degrees:Int)->CGFloat {CGFloat(degrees) * .pi / 180}
 func convert(_ point: CGPoint, from: NSView?) -> CGPoint { point }
 func setShellAngle(_ angle: CGFloat) { shellAngle = angle }
 func sendAttitude() { attitudes += 1 }
 func cursorOverPanel(_ event:NSEvent)->Bool { onPanel }
 func guestScrollDrag(_ event:NSEvent) { guestScrolls += 1 }
 func emit(_ event: NSEvent, _ phase: Int32) { precondition(phase == TouchPhase.update); guestUpdates += 1 }
 func endTilt() {
  wheelTiltResetTask?.cancel(); tilting=false;scrollTilting=false;rotatingChassis=false
  scrollTilt=0;scrollPitch=0;yawAngle=0;pitchAngle=0;tiltAngle=0;motionRestAngle=nil
 }
''' + methods + r'''
 func drag(_ x: CGFloat, _ y: CGFloat) {
  let e = NSEvent.mouseEvent(with:.leftMouseDragged, location:CGPoint(x:x,y:y),
    modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!
  mouseDragged(with:e)
 }
 func run() async throws {
  grabPoint = CGPoint(x:10,y:20)
  drag(35,70);precondition(abs(tiltAngle - 0.1)<1e-10 && abs(pitchAngle + 0.2)<1e-10 && yawAngle == 0)
  drag(-15,-30);precondition(abs(tiltAngle + 0.1)<1e-10 && abs(pitchAngle - 0.2)<1e-10 && yawAngle == 0)
  drag(10000,-10000);precondition(tiltAngle == .pi/4 && pitchAngle == .pi/4)
  for rest in [0.0,Double.pi/2,Double.pi,-Double.pi/2] {
   restAngle = rest;drag(35,70);precondition(abs(shellAngle-rest-tiltAngle)<1e-10 && tiltAngle>0 && pitchAngle<0)
  }
  modelView=nil;drag(-15,-30);precondition(tiltAngle<0 && pitchAngle>0 && yawAngle==0)
  precondition(guestUpdates == 0)
  let count=attitudes;tilting=false;drag(1,1)
  precondition(guestUpdates == 1 && attitudes == count)
  let event=Gesture()
  // Line-based wheel deltas and precise point deltas have the same scale.
  for precise in [false,true] {
   endTilt();event.precise=precise;event.dx=precise ? 10:1;event.dy=precise ? -20:-2
   event.eventPhase = .began;scrollWheel(with:event)
   precondition(abs(tiltAngle-0.015)<1e-10 && abs(pitchAngle+0.03)<1e-10 && yawAngle==0)
   event.eventPhase = .ended;scrollWheel(with:event)
   precondition(tiltAngle==0 && pitchAngle==0 && !scrollTilting)
  }
  // The same physical swipe is represented with opposite deltas under the
  // other system preference. Do not reverse those already-adjusted values.
  for inverted in [false,true] {
   endTilt();event.precise=true;event.inverted=inverted;event.dx=inverted ? -10:10;event.dy=0
   event.eventPhase = .began;scrollWheel(with:event)
   precondition(abs(tiltAngle-(inverted ? -0.015:0.015))<1e-10)
  }
  endTilt();event.momentum = .changed;event.eventPhase=[];scrollWheel(with:event)
  precondition(tiltAngle==0 && !scrollTilting && guestScrolls==0)
  event.momentum=[];event.precise=false;event.dx=1;event.dy=0;scrollWheel(with:event)
  precondition(tiltAngle>0 && scrollTilting)
  try await Task.sleep(for:.milliseconds(250))
  precondition(tiltAngle==0 && !scrollTilting,"A conventional wheel must return to rest after its burst")
  event.eventPhase = .began;event.degrees=30;rotate(with:event)
  precondition(abs(tiltAngle + .pi/6)<1e-10 && yawAngle==0)
  event.eventPhase = .cancelled;rotate(with:event);precondition(tiltAngle==0)
  onPanel=true;event.eventPhase = .began;rotate(with:event);precondition(!rotatingChassis)
  event.option=true;rotate(with:event);precondition(rotatingChassis && tiltAngle<0)
  event.eventPhase = .ended;rotate(with:event);precondition(tiltAngle==0)
  print("PASS: linear roll/pitch drag for tilt games, wheel/precise scaling, Natural Scrolling, momentum, wheel timeout and explicit trackpad twist")
 }
}
@main struct Main { @MainActor static func main() async throws { let check = Check(); try await check.run() } }
'''
with tempfile.TemporaryDirectory(prefix='ltm-chassis-') as work:
    work = Path(work)
    source_file = work / 'check.swift'; source_file.write_text(source)
    exe = work / 'check'
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(work/'modules'), str(source_file), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
