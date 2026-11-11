import DeviceRuntime
import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// The device's quarter turns (the iPod steps its machine, the iPad sets its accelerometer outright) and
/// auto-rotation with the guest: edges, not levels.
struct DeviceRotationTests {
    final class Host: RotationHost {
        let bootScope = BootSessionScope()
        let link = RecordingLink()
        var helperLink: HelperLink? { link }
        var state: VMState = .running
        var preparingDevice = false, isSleeping = false, isInstalling = false, canReachDevice = true
        var guestReadings: [Int?] = []
        /// What the guest agent's report tells; lockdown's relay answers `asked` (and counts the asking).
        var reportedInterfaceOrientation: Int?
        var asked = 0
        func interfaceOrientation() async throws -> Int {
            asked += 1
            return 1
        }
        func guestOrientation() async throws -> Int? {
            guard !guestReadings.isEmpty else { throw CancellationError() }
            return guestReadings.removeFirst()
        }
    }

    /// The iPod 2G steps its machine; the iPad (and every other board without the guest agent) sets its accelerometer.
    func rotation(_ directory: URL, iPad: Bool = false) -> (DeviceRotation, Host) {
        let host = Host()
        return (
            DeviceRotation(host: host, settings: DeviceSettingsFile(directory: directory), setsAccelerometer: iPad),
            host
        )
    }

    @Test func theIPodStepsItsMachineAQuarterTurnAtATime() throws {
        try withTemporaryDirectory { directory in
            let (rotation, host) = rotation(directory)
            #expect(observes({ _ = rotation.degrees }) { rotation.toggle() }, "the toolbar's rotate glyph follows")
            #expect(rotation.degrees == 270 && rotation.isLandscape, "landscape is entered counter-clockwise")
            #expect(host.link.commands == [.rotate(clockwise: false)])
            rotation.toggle()
            #expect(
                rotation.degrees == 0 && host.link.commands.last == .rotate(clockwise: true),
                "and left the short way back"
            )
            rotation.rotate(clockwise: true)
            rotation.rotate(clockwise: true)
            #expect(rotation.degrees == 180 && !rotation.isLandscape && host.link.requests.isEmpty)
            rotation.rotate(toward: 90)
            #expect(
                rotation.degrees == 90 && host.link.commands.suffix(1) == [.rotate(clockwise: false)],
                "the short way round"
            )
            rotation.rotate(toward: 270)
            #expect(
                rotation.degrees == 270
                    && host.link.commands.suffix(2) == [.rotate(clockwise: true), .rotate(clockwise: true)]
            )
        }
    }

    @Test func theIPadSetsItsAccelerometerOutright() throws {
        try withTemporaryDirectory { directory in
            let (rotation, host) = rotation(directory, iPad: true)
            rotation.rotate(clockwise: true)
            rotation.rotate(clockwise: true)
            rotation.rotate(clockwise: false)
            rotation.reset()
            #expect(host.link.commands.isEmpty, "no relative steps")
            #expect(host.link.requests == [.orientation(4), .orientation(2), .orientation(4), .orientation(1)])
            #expect(rotation.degrees == 0)
            #expect([1, 4, 2, 3, 5].map(DeviceRotation.iPadDegrees(forInterface:)) == [0, 90, 180, 270, nil])
        }
    }

    /// A boot's reset to portrait reaches a helper that can't take it yet: that refusal is no error (it filled Copy
    /// Bug Report Info's Recent errors at every iPad and 3GS start). A turn the device refuses is still logged.
    @Test func aBootsResetRefusedIsNotLoggedATurnRefusedIs() async throws {
        try await withScratchDirectory { directory in
            let (rotation, host) = rotation(directory, iPad: true)
            host.link.answer = false
            let log = Bundled.logsDirectory.appendingPathComponent("app.log")
            func count(_ value: Int) async -> Int {
                await AppEventLog.shared.flush()
                let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                return text.components(separatedBy: "rotation: the device refused orientation \(value)\n").count - 1
            }
            let (resets, turns) = (await count(1), await count(4))
            rotation.reset()
            rotation.rotate(clockwise: true)
            #expect(host.link.requests == [.orientation(1), .orientation(4)])
            #expect(await count(1) == resets, "the reset's refusal is quiet")
            #expect(await count(4) == turns + 1, "a turn's refusal is logged")
        }
    }

    @Test func theGuestTurnsTheShellOnlyOnAChange() throws {
        try withTemporaryDirectory { directory in
            let (rotation, host) = rotation(directory)
            rotation.guestOrientationChanged(to: 90)
            #expect(rotation.degrees == 0, "the first reading only seeds")
            rotation.guestOrientationChanged(to: 0)
            #expect(rotation.degrees == 0)
            rotation.rotate(clockwise: true)
            rotation.guestOrientationChanged(to: 0)
            #expect(rotation.degrees == 90, "a manual turn the guest doesn't follow stands")
            rotation.guestOrientationChanged(to: 90)
            #expect(rotation.degrees == 270, "LandscapeLeft: home button right, the device turned 270°")
            rotation.guestOrientationChanged(to: -90)
            #expect(rotation.degrees == 90)
            rotation.guestOrientationChanged(to: 45)
            #expect(rotation.degrees == 90 && rotation.lastGuestOrientation == -90, "a torn line is ignored")

            #expect(observes({ _ = rotation.autoRotateEnabled }) { rotation.toggleAutoRotate() })
            #expect(!rotation.autoRotateEnabled && DeviceSettings.load(directory).autoRotateWithGuest == false)
            rotation.guestOrientationChanged(to: 0)
            #expect(rotation.degrees == 90, "auto-rotation off")
            rotation.toggleAutoRotate()
            host.state = .booting
            rotation.guestOrientationChanged(to: 180)
            #expect(rotation.degrees == 90, "only a running guest turns the shell")
            host.state = .running
            rotation.guestOrientationChanged(to: 0)
            #expect(rotation.degrees == 0)
        }
    }

    @Test func theIPadAdoptsItsFirstReadingThenFollowsChanges() throws {
        try withTemporaryDirectory { directory in
            let (rotation, host) = rotation(directory, iPad: true)
            defer { withExtendedLifetime(host) {} }
            var last = rotation.interfaceRead(4, last: nil)
            #expect(rotation.degrees == 90 && last == 4, "iOS came back up in landscape: adopted")
            rotation.rotate(clockwise: true)
            last = rotation.interfaceRead(4, last: last)
            #expect(rotation.degrees == 180, "an unchanged reading leaves a manual turn")
            rotation.toggleAutoRotate()
            last = rotation.interfaceRead(3, last: last)
            #expect(rotation.degrees == 180 && last == 3, "auto-rotation off: changes aren't followed")
            rotation.toggleAutoRotate()
            last = rotation.interfaceRead(1, last: last)
            #expect(rotation.degrees == 0 && last == 1)
            #expect(rotation.interfaceRead(9, last: last) == 1, "an unknown value keeps the last reading")
        }
    }

    /// Issue 103: an iPad held landscape opens a portrait-only app. The shell turns to portrait with the interface,
    /// the accelerometer stays landscape, so SpringBoard turns back when the app quits and the shell follows it.
    @Test func anAppsTurnOnTheIPadLeavesTheDeviceAsItIsHeld() throws {
        try withTemporaryDirectory { directory in
            let (rotation, host) = rotation(directory, iPad: true)
            defer { withExtendedLifetime(host) {} }
            var last = rotation.interfaceRead(1, last: nil)
            rotation.rotate(clockwise: true)
            #expect(rotation.degrees == 90 && rotation.heldDegrees == 90 && host.link.requests == [.orientation(4)])
            last = rotation.interfaceRead(4, last: last)
            last = rotation.interfaceRead(1, last: last)
            #expect(rotation.degrees == 0, "the portrait-only app turns the shell")
            #expect(rotation.heldDegrees == 90 && host.link.requests == [.orientation(4)], "not the accelerometer")
            last = rotation.interfaceRead(4, last: last)
            #expect(rotation.degrees == 90 && rotation.heldDegrees == 90, "the app quit: back to landscape")

            last = rotation.interfaceRead(1, last: last)
            rotation.rotate(clockwise: false)
            #expect(
                rotation.degrees == 270 && rotation.heldDegrees == 270 && host.link.requests.last == .orientation(3),
                "a turn while the app holds portrait turns the shell as shown, and the device with it"
            )
            last = rotation.interfaceRead(3, last: last)
            rotation.toggleAutoRotate()
            last = rotation.interfaceRead(1, last: last)
            #expect(rotation.degrees == 270 && rotation.heldDegrees == 270, "auto-rotation off: neither moves")
            rotation.toggleAutoRotate()
            last = rotation.interfaceRead(2, last: last)
            #expect(rotation.degrees == 180 && rotation.heldDegrees == 270 && host.link.requests.count == 2)
            rotation.reset()
            #expect(rotation.degrees == 0 && rotation.heldDegrees == 0, "a boot starts upright")
            #expect(rotation.interfaceRead(4, last: nil) == 4 && rotation.heldDegrees == 90, "and adopts what iOS kept")
        }
    }

    /// The same on a machine stepped a quarter turn at a time (the iPod 2G, its guest agent reporting SpringBoard's
    /// angle): an app's turn moves the shell alone, and the user's next turn steps the machine from how it is held.
    @Test func anAppsTurnOnASteppedMachineLeavesTheDeviceAsItIsHeld() throws {
        try withTemporaryDirectory { directory in
            let (rotation, host) = rotation(directory)
            rotation.rotate(clockwise: false)
            #expect(rotation.degrees == 270 && rotation.heldDegrees == 270)
            rotation.guestOrientationChanged(to: 90)
            rotation.guestOrientationChanged(to: 0)
            #expect(rotation.degrees == 0, "the portrait-only app turns the shell")
            #expect(rotation.heldDegrees == 270 && host.link.commands == [.rotate(clockwise: false)], "not the machine")
            rotation.guestOrientationChanged(to: 90)
            #expect(rotation.degrees == 270 && host.link.commands.count == 1, "the app quit: back to landscape")

            rotation.guestOrientationChanged(to: 0)
            rotation.rotate(clockwise: true)
            #expect(
                rotation.degrees == 90 && rotation.heldDegrees == 90
                    && host.link.commands.suffix(2) == [.rotate(clockwise: true), .rotate(clockwise: true)],
                "a turn from the app's portrait to 90 steps the machine there from 270, the short way"
            )
        }
    }

    @Test func theGuestWatchFollowsTheAgentAndForgetsOnAFailure() async throws {
        try await withScratchDirectory { directory in
            let (rotation, host) = rotation(directory)
            host.guestReadings = [0, 90]
            rotation.startGuestWatch()
            await eventually("the guest's turn") { rotation.degrees == 270 }
            await eventually("the failed read") { rotation.lastGuestOrientation == nil }
            rotation.stopWatching()
        }
    }

    /// The interface watch takes what the guest agent tells, with no lockdown to reach first and nothing asked of
    /// its relay: the first reading adopted, a change followed within the agent's quarter second.
    @Test func theInterfaceWatchIsToldBeforeLockdownAnswers() async throws {
        try await withScratchDirectory { directory in
            let (rotation, host) = rotation(directory, iPad: true)
            host.canReachDevice = false
            host.reportedInterfaceOrientation = 4
            rotation.startInterfaceWatch()
            await eventually("the first reading, adopted") { rotation.degrees == 90 && rotation.heldDegrees == 90 }
            host.reportedInterfaceOrientation = 1
            await eventually("the app's turn, followed by the shell") {
                rotation.degrees == 0 && rotation.heldDegrees == 90
            }
            rotation.stopWatching()
            #expect(host.asked == 0, "lockdown's relay wasn't asked")
        }
    }
}
