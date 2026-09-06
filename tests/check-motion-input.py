#!/usr/bin/env python3
"""Exercise production motion event handling with deterministic clock and input sinks."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'LightTouchMac/DisplayView.swift').read_text()
a = s.index('    private func sendAttitude()')
b = s.index('    private func setShellAngle(', a)
motion = s[a:b]
start = motion.index('    private var controllerInput')
end = motion.index('    private func updateKeyboardTilt()', start)
motion = (motion[:start] + motion[end:]).replace('private func', 'func').replace('CACurrentMediaTime()', 'now')
a = s.index('    override func keyDown(')
b = s.index('    // MARK: - Drag & drop', a)
keys = s[a:b]
source = r'''import Cocoa
@MainActor class Sink {
 func keyDown(with event: NSEvent) {}
 func keyUp(with event: NSEvent) {}
 func flagsChanged(with event: NSEvent) {}
 func resignFirstResponder() -> Bool { true }
}
@MainActor final class Check: Sink {
 enum Pose { case upright, flat }
 final class Emulator {
  var motionPose = Pose.upright, rotationDegrees = 0
  var keyboardTiltRate = 90.0
  var sent: [(UInt16, Bool)] = [], attitudes: [(CGFloat, CGFloat)] = []
  var shakes = 0
  func shake() { shakes += 1 }
  func setTilt(angle: CGFloat, pitch: CGFloat) { attitudes.append((angle, pitch)) }
  func sendKey(macKeyCode: UInt16, down: Bool) { sent.append((macKeyCode, down)) }
 }
 struct Window { var isKeyWindow = true }
 let emulator: Emulator? = Emulator()
 var window: Window? = Window()
 var touchInteractionEnabled = true, isShowingLiveText = false
 var tiltKeys: Set<UInt16> = [], consumedTiltKeys: Set<UInt16> = []
 var tiltAngle = 0.0, pitchAngle = 0.0, lastTiltTick = 0.0, now = 0.0
 var restAngle = Double.pi / 2, motionRestAngle: CGFloat?
 class Indicator { var isHidden=false; func update(pitch:Double,roll:Double) {} }
 let attitudeIndicator=Indicator()
 var motionWasEnabled = false
 static func layerAngle(_ degrees: Int) -> CGFloat { CGFloat(degrees) * .pi / 180 }
 func setShellAngle(_ angle: CGFloat) {}
 func endTilt() { tiltAngle = 0; pitchAngle = 0; motionRestAngle = nil; sendAttitude() }
 func endControllerTouch() {}
 func endLiveText() { isShowingLiveText = false }
''' + motion + keys + r'''
 func event(_ code: UInt16, _ flags: NSEvent.ModifierFlags = .option, repeatKey: Bool = false) -> NSEvent {
  NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
   timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
   isARepeat: repeatKey, keyCode: code)!
 }
 func tick(_ dt: Double = 0.05) { now += dt; updateKeyboardTilt() }
 func run() {
  let e = emulator!
  for rate in [45.0, 90.0, 180.0] {
   e.keyboardTiltRate = rate
   keyDown(with: event(124)); keyDown(with: event(126)); tick()
   precondition(abs(tiltAngle - rate * .pi / 180 * 0.05) < 1e-8)
   precondition(abs(pitchAngle - tiltAngle) < 1e-8)
   keyUp(with: event(124)); precondition(pitchAngle > 0)
   keyUp(with: event(126)); precondition(tiltAngle == 0 && pitchAngle == 0)
  }
  keyDown(with: event(123)); for _ in 0..<100 { tick() }
  precondition(abs(tiltAngle + .pi / 4) < 1e-8)
  flagsChanged(with: event(58, [])); precondition(tiltKeys.isEmpty && tiltAngle == 0)
  keyUp(with: event(123, [])); precondition(e.sent.isEmpty)
  keyDown(with: event(49)); keyDown(with: event(49, repeatKey: true)); keyUp(with: event(49))
  precondition(e.shakes == 1)
  keyDown(with: event(124)); tick(); window?.isKeyWindow = false; tick()
  precondition(tiltAngle == 0 && tiltKeys.isEmpty)
  keyUp(with: event(124)); window?.isKeyWindow = true; tick()
  keyDown(with: event(124)); tick(); touchInteractionEnabled = false; tick()
  precondition(tiltAngle == 0 && tiltKeys.isEmpty)
  keyUp(with: event(124)); keyDown(with: event(49)); keyUp(with: event(49))
  precondition(e.shakes == 1 && e.sent.isEmpty)
  touchInteractionEnabled = true
  isShowingLiveText = true; keyDown(with: event(124)); keyUp(with: event(124))
  precondition(tiltKeys.isEmpty && e.sent.isEmpty)
  keyDown(with: event(53, [])); precondition(!isShowingLiveText)
  keyDown(with: event(124)); tick(); _ = resignFirstResponder()
  keyUp(with: event(124)); precondition(tiltKeys.isEmpty && tiltAngle == 0 && e.sent.isEmpty)
  e.motionPose = .flat; tiltAngle = 0.2; pitchAngle = 0.3; sendAttitude()
  precondition(e.attitudes.last!.0 == 0.2 && e.attitudes.last!.1 == 0.3)
  e.motionPose = .upright; sendAttitude(); precondition(e.attitudes.last!.0 == restAngle + 0.2)
  keyDown(with: event(0, [])); keyUp(with: event(0, []))
  precondition(e.sent.count == 2 && e.sent[0].1 && !e.sent[1].1)
  let count=e.sent.count
  keyDown(with:event(0,[.control]));keyUp(with:event(0,[.control]))
  keyDown(with:event(124,[.control,.option]));keyUp(with:event(124,[.control,.option]))
  precondition(e.sent.count==count && tiltKeys.isEmpty,"Mac accessibility shortcuts must not reach guest or tilt")
  print("PASS: motion rates, clamp, pose, Option release, focus, sleep, Live Text and guest key isolation")
 }
}
@main struct Main { @MainActor static func main() { Check().run() } }
'''
with tempfile.TemporaryDirectory() as work:
    p = Path(work) / 'check.swift'; p.write_text(source)
    exe = Path(work) / 'check'
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', '/tmp/ltm-module-cache', str(p), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
