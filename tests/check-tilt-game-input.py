#!/usr/bin/env python3
"""Drive production Mac input through the production mounted gravity model.

The C shim replaces only QEMU's asynchronous dispatch. It uses the same
ipod_attitude_vector function as the real bridge and LIS302DL, so a gesture
that moves the rendered shell without changing guest gravity fails here.
No app, emulator, saved device state, or preferences are opened.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile


root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--qemu-source", type=Path, default=root.parent / "qemu-ios")
args = parser.parse_args()
qemu = args.qemu_source.resolve()
if not (qemu / "include/hw/arm/ipod-attitude.h").is_file():
    parser.error("--qemu-source must contain include/hw/arm/ipod-attitude.h")

display = (root / "LightTouchMac/DisplayView.swift").read_text()
emulator = (root / "LightTouchMac/EmulatorController.swift").read_text()


def method(source, signature):
    start = source.index(signature)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


methods = "\n".join(method(display, signature) for signature in (
    "    override func mouseDown(",
    "    override func mouseDragged(",
    "    override func mouseUp(",
    "    override func scrollWheel(",
    "    private func beginScrollTilt(",
    "    private func scrollTiltChanged(",
    "    private static func scrollMovement(",
    "    private static func layerAngle(",
    "    private func sendAttitude(",
    "    func resetMotion(",
    "    private func endTilt(",
))
methods = methods.replace("private ", "").replace("CACurrentMediaTime()", "testTime")
rest_angle = next(line for line in display.splitlines() if "private var restAngle:" in line)
methods += "\n" + rest_angle.replace("private ", "")
set_tilt = method(emulator, "    func setTilt(")
scroll_gain = next(line for line in display.splitlines() if "private static let scrollTiltGain:" in line)

header = r'''
#include <stdint.h>
void qemu_ios_ui_attitude(double pitch, double roll, int pose);
void tilt_test_vector(int8_t out[3]);
int tilt_test_samples(void);
'''
c_source = r'''
#include <assert.h>
#include <string.h>
#include "hw/arm/ipod-attitude.h"
#include "bridge.h"
static int8_t latest[3];
static int samples;
void qemu_ios_ui_attitude(double pitch, double roll, int pose) {
    assert(pose == 0 || pose == 1);
    assert(ipod_attitude_vector(pitch, roll, pose != 0, latest));
    samples++;
}
void tilt_test_vector(int8_t out[3]) { memcpy(out, latest, sizeof latest); }
int tilt_test_samples(void) { return samples; }
'''

swift = r'''import Cocoa
import QuartzCore

enum TouchPhase { static let begin: Int32 = 0, update: Int32 = 1, end: Int32 = 2 }

@MainActor class EventSink {
    func mouseDown(with event: NSEvent) {}
    func mouseDragged(with event: NSEvent) {}
    func mouseUp(with event: NSEvent) {}
    func scrollWheel(with event: NSEvent) {}
}

final class ScrollEvent: NSEvent {
    var eventPhase: NSEvent.Phase = .began
    var momentum: NSEvent.Phase = []
    var dx = 0.0, dy = 0.0
    var precise = true, inverted = false
    override var phase: NSEvent.Phase { eventPhase }
    override var momentumPhase: NSEvent.Phase { momentum }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var isDirectionInvertedFromDevice: Bool { inverted }
}

@MainActor final class Check: EventSink {
    enum MotionPose: Int, CaseIterable { case upright, flat }
    final class Emulator {
        var motionPose = MotionPose.upright, rotationDegrees = 0
        var acceptsInput = true, isSleeping = false
        var keyboardTiltRate = 90.0
        /// The helper's link: the attitude command reaches the same C model.
        struct Link { func send(_ c: LinkCommand) { if case let .attitude(p, r, pose) = c { qemu_ios_ui_attitude(p, r, Int32(pose)) } } }
        var link: Link? = Link()
''' + set_tilt + r'''
    }
    final class Window {
        var isKeyWindow = true
        func makeFirstResponder(_ responder: Any) {}
    }
    final class Indicator {
        var isHidden = true
        func update(pitch: CGFloat, roll: CGFloat) {}
    }
    var emulator: Emulator? = Emulator()
    var window: Window? = Window()
    var tiltAngle = 0.0, pitchAngle = 0.0, yawAngle = 0.0
    var scrollTilt = 0.0, scrollPitch = 0.0
    var tiltKeys = Set<UInt16>()
    var lastTiltTick = 0.0, testTime = 0.0, motionWasEnabled = false
    var motionRestAngle: CGFloat?, scrollPoint: CGPoint?
    var tilting = false, scrollTilting = false, rotatingChassis = false
    var pinching = false, pinchingGuest = false, touchInteractionEnabled = true
    var grabPoint = CGPoint.zero
    var wheelTiltResetTask: Task<Void, Never>?
    let shellLayer = CALayer(), attitudeIndicator = Indicator()
    var guestTouches = 0, guestScrolls = 0
''' + scroll_gain.replace("private ", "") + r'''
    func convert(_ point: CGPoint, from: NSView?) -> CGPoint { point }
    func isChassisEvent(_ event: NSEvent) -> Bool { true }
    func cursorOverPanel(_ event: NSEvent) -> Bool { false }
    func emit(_ event: NSEvent, _ phase: Int32) { guestTouches += 1 }
    func guestScrollDrag(_ event: NSEvent) { guestScrolls += 1 }
    func setShellAngle(_ angle: CGFloat, animated: Bool = false) {}
''' + methods + r'''

    func vector() -> [Int] {
        var result = [Int8](repeating: 0, count: 3)
        tilt_test_vector(&result)
        return result.map(Int.init)
    }
    func expect(_ expected: [Int], _ context: String) {
        precondition(vector() == expected, "\(context): \(vector()) != \(expected)")
    }
    func expectMagnitude(_ context: String) {
        let magnitude = sqrt(vector().reduce(0.0) { $0 + Double($1 * $1) })
        precondition(abs(magnitude - 64) < 1, "\(context): magnitude \(magnitude)")
    }
    func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1)!
    }
    func configure(_ pose: MotionPose, _ rotation: Int) {
        emulator!.motionPose = pose
        emulator!.rotationDegrees = rotation
        tiltKeys.removeAll()
        motionWasEnabled = false
        endTilt()
    }
    func beginMouse(_ point: CGPoint = CGPoint(x: 37, y: 91)) {
        mouseDown(with: event(.leftMouseDown, point))
    }
    func drag(horizontal: Double, vertical: Double) {
        // Inputs are degrees to the right/up; AppKit's flipped mouse Y is down.
        let gain = 0.004 * 180 / Double.pi
        let point = CGPoint(x: grabPoint.x + horizontal / gain,
                            y: grabPoint.y - vertical / gain)
        mouseDragged(with: event(.leftMouseDragged, point))
    }
    func releaseMouse() {
        mouseUp(with: event(.leftMouseUp, grabPoint))
        precondition(!tilting)
    }

    func run() {
        let rotations = [0, 90, 180, 270]
        let uprightRest = [[0,-64,0], [64,0,0], [0,64,0], [-64,0,0]]
        let uprightRight = [[32,-55,0], [55,32,0], [-32,55,0], [-55,-32,0]]
        let uprightLeft = [[-32,-55,0], [55,-32,0], [32,55,0], [-55,32,0]]
        let uprightUp = [[0,-55,-32], [55,0,-32], [0,55,-32], [-55,0,-32]]
        let flatRight = [[32,0,-55], [0,32,-55], [-32,0,-55], [0,-32,-55]]
        let flatUp = [[0,32,-55], [-32,0,-55], [0,-32,-55], [32,0,-55]]

        for pose in MotionPose.allCases {
            for (index, rotation) in rotations.enumerated() {
                let context = "\(pose) rotation=\(rotation)"
                let baseline = pose == .flat ? [0,0,-64] : uprightRest[index]
                configure(pose, rotation)
                expect(baseline, context + " rest")
                for anchor in [CGPoint(x: 37,y: 91), CGPoint(x: -200,y: 300)] {
                    beginMouse(anchor)
                    let count = tilt_test_samples()
                    drag(horizontal: 30, vertical: 0)
                    precondition(tilt_test_samples() > count)
                    expect(pose == .flat ? flatRight[index] : uprightRight[index], context + " right")
                    drag(horizontal: -30, vertical: 0)
                    let flatLeft = flatRight[index].enumerated().map { $0.offset < 2 ? -$0.element : $0.element }
                    expect(pose == .flat ? flatLeft : uprightLeft[index], context + " left")
                    drag(horizontal: 0, vertical: 30)
                    expect(pose == .flat ? flatUp[index] : uprightUp[index], context + " up")
                    for horizontal in [-45.0,-20,20,45] {
                        for vertical in [-45.0,-20,20,45] {
                            drag(horizontal: horizontal, vertical: vertical)
                            expectMagnitude(context + " diagonal")
                            precondition(vector() != baseline, context + " diagonal lost gravity")
                        }
                    }
                    drag(horizontal: 500, vertical: 500)
                    let clamped = vector()
                    drag(horizontal: 45, vertical: 45)
                    expect(clamped, context + " mouse clamp")
                    releaseMouse()
                    expect(baseline, context + " mouse-up reset")
                }



                // AppKit has already applied Natural Scrolling. Test both
                // delivered signs and flag values without applying it twice.
                for sign in [-1.0,1.0] {
                    for precise in [false,true] {
                        for inverted in [false,true] {
                            let scroll = ScrollEvent()
                            scroll.precise = precise
                            scroll.inverted = inverted
                            let points = sign * Double.pi / 6 / Self.scrollTiltGain
                            scroll.dx = points / (precise ? 1 : 10)
                            scrollWheel(with: scroll)
                            let expected: [Int]
                            if pose == .flat {
                                expected = flatRight[index].enumerated().map {
                                    $0.offset < 2 ? Int(sign) * $0.element : $0.element
                                }
                            } else {
                                expected = sign > 0 ? uprightRight[index] : uprightLeft[index]
                            }
                            expect(expected, context + " scroll horizontal")
                            scroll.eventPhase = .ended
                            scrollWheel(with: scroll)
                            expect(baseline, context + " scroll ended reset")
                        }
                    }
                }
                let diagonal = ScrollEvent()
                diagonal.dx = Double.pi / 6 / Self.scrollTiltGain
                diagonal.dy = diagonal.dx
                scrollWheel(with: diagonal)
                expectMagnitude(context + " scroll diagonal")
                precondition(vector() != baseline)
                diagonal.eventPhase = .cancelled
                scrollWheel(with: diagonal)
                expect(baseline, context + " scroll cancellation reset")

                let clamp = ScrollEvent()
                clamp.dx = 1_000_000
                clamp.dy = -1_000_000
                scrollWheel(with: clamp)
                precondition(abs(tiltAngle - .pi / 3) < 1e-12 && abs(pitchAngle + .pi / 3) < 1e-12)
                expectMagnitude(context + " scroll clamp")
                clamp.eventPhase = .ended
                scrollWheel(with: clamp)
                expect(baseline, context + " scroll clamp reset")
            }
        }
        precondition(guestTouches == 0 && guestScrolls == 0, "Chassis gestures leaked to guest touches")
        print("PASS: production mouse/scroll → Swift attitude bridge → LIS302DL gravity; upright/flat, every quarter-turn, direction, diagonal 1g, clamps and release")
    }
}
@main struct Main {
    @MainActor static func main() { Check().run() }
}
'''

with tempfile.TemporaryDirectory(prefix="ltm-tilt-game-") as directory:
    work = Path(directory)
    (work / "bridge.h").write_text(header)
    (work / "bridge.c").write_text(c_source)
    (work / "check.swift").write_text(swift)
    subprocess.run([
        "clang", "-Wall", "-Wextra", "-Werror", "-I" + str(qemu / "include"),
        "-c", str(work / "bridge.c"), "-o", str(work / "bridge.o"),
    ], check=True)
    subprocess.run([
        "swiftc", "-parse-as-library", "-module-cache-path", str(work / "module-cache"),
        "-import-objc-header", str(work / "bridge.h"), str(root / "Shared/DeviceLinkProtocol.swift"), str(work / "check.swift"),
        str(work / "bridge.o"), "-o", str(work / "check"),
    ], check=True)
    subprocess.run([str(work / "check")], check=True)
