import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import LightTouchCore

/// Erase completes after the helper exits, then restarts the device (never quits the app); a stopped device just
/// erases; a helper that won't exit leaves the data and says so.
struct DeviceEraseTests {
    /// Issue 136: what mobile_obliterator wrote to an iPod touch 2G's NOR on 3.1.3, against a recovery with no erase.
    @Test func recoveryFromTheGuestsOwnEraseIsAnErase() async throws {
        try await withScratchDirectory { dir in
            let nor = dir.appendingPathComponent("nor.bin")
            #expect(!DeviceErase.guestAsked(nor: nor), "no NOR yet")
            #expect(!DeviceErase.guestAsked(nor: nil))
            try Data("debug-uarts=1\0auto-boot=false\0".utf8).write(to: nor)
            #expect(!DeviceErase.guestAsked(nor: nor), "recovery for another reason")
            try Data("obliteration=Could not unmount the Data partition\0auto-boot=false\0".utf8).write(to: nor)
            #expect(DeviceErase.guestAsked(nor: nor))
        }
    }

    func session(_ directory: URL) throws -> FakeSession {
        let s = FakeSession(directory: directory)
        s.state = .running
        s.ladder.budgets.halt = 0.2
        s.eraser.exitWait = .milliseconds(50)
        s.eraser.exitPoll = .milliseconds(5)
        let overlay = directory.appendingPathComponent("overlay")
        try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
        try Data("personal data".utf8).write(to: overlay.appendingPathComponent("file"))
        try Data("nvram".utf8).write(to: directory.appendingPathComponent("nor.bin"))
        try Data("old".utf8).write(to: directory.appendingPathComponent("snapshot"))
        return s
    }
    func exists(_ directory: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    @Test func eraseWaitsForTheHelperThenRestartsTheDevice() async throws {
        try await withScratchDirectory { root in
            let directory = root.appendingPathComponent("success")
            let c = try session(directory)
            var erasedBeforeRestart: Bool?
            c.onRestart = {
                erasedBeforeRestart = !self.exists(directory, "overlay") && !c.isErasing && c.fakeHelper!.isDead
            }
            c.notices.report("Couldn’t finish erasing the iPod", for: .erase)
            c.eraser.request()
            c.eraser.request()  // coalesced
            #expect(c.isErasing && c.steps.prefix(2) == ["discard", "stopWatches"])
            await eventually("erased") { !c.isErasing }
            #expect(erasedBeforeRestart == true, "data gone, helper gone, before the restart")
            #expect(c.steps.filter { $0 == "restart" }.count == 1 && c.steps.filter { $0 == "discard" }.count == 1)
            #expect(!exists(directory, "nor.bin"), "a prepared device's NOR copy goes with its overlay")
            #expect(!exists(directory, "snapshot"))
            #expect(c.link.commands == [.machine(.quit)] && c.fakeHelper!.terms == 1, "halted, then told to quit")
            #expect(c.notices.message == nil, "the erase notice resolves")
        }
    }

    @Test func aHelperThatWontExitKeepsTheData() async throws {
        try await withScratchDirectory { root in
            let directory = root.appendingPathComponent("stuck")
            let c = try session(directory)
            c.fakeHelper!.hung = true
            c.ladder.budgets.kill = 0.05
            // A helper that survives even SIGKILL (as one whose guest powered itself off would, until it exits).
            let helper = c.fakeHelper!
            helper.onExit = { helper.isDead = false }
            c.eraser.request()
            await eventually("gave up") { !c.isErasing }
            #expect(exists(directory, "overlay") && exists(directory, "nor.bin"))
            #expect(
                c.notices.message == "Couldn’t stop the iPod to erase it. Try again." && !c.steps.contains("restart")
            )
        }
    }

    @Test func aDeadHelperErasesAndRestartsAndAStoppedDeviceOnlyErases() async throws {
        try await withScratchDirectory { root in
            let dead = try session(root.appendingPathComponent("dead"))
            dead.state = .dead(exitCode: nil)
            dead.eraser.request()
            await eventually("erased") { !dead.isErasing }
            #expect(dead.fakeHelper!.terms == 0 && dead.link.commands.isEmpty && dead.steps.last == "restart")

            let directory = root.appendingPathComponent("stopped")
            let stopped = try session(directory)
            stopped.state = .notStarted
            stopped.started = false
            stopped.eraser.request()
            await eventually("erased") { !stopped.isErasing }
            #expect(
                !exists(directory, "overlay") && !stopped.steps.contains("restart") && stopped.link.commands.isEmpty
            )
        }
    }

    @Test func aFailedEraseSaysSo() async throws {
        try await withScratchDirectory { root in
            let c = try session(root.appendingPathComponent("refused"))
            c.state = .notStarted
            c.started = false
            // The erase only removes inside the state directory it owns; this overlay is elsewhere.
            let outside = root.appendingPathComponent("elsewhere")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            c.eraseTargetsOverride = DeviceErase.Targets(
                overlay: outside,
                snapshots: [],
                preparedNOR: nil,
                state: root.appendingPathComponent("refused"),
                owner: UUID()
            )
            c.eraser.request()
            await eventually("failed") { !c.isErasing }
            #expect(c.notices.message?.hasPrefix("Couldn’t finish erasing the iPod: ") == true)
            #expect(FileManager.default.fileExists(atPath: outside.path))
        }
    }
}
