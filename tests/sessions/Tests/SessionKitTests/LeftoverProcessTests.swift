import Foundation
import Testing

@testable import SessionKit

/// A run's end kills a recorded process id only while it still names a process the run started: one of the
/// executables a run starts, started no earlier than the run (LeftoverProcess), never merely a live id, which may have
/// passed to another process.
struct LeftoverProcessTests {
    @Test func aRecordedIDIsKilledOnlyWhileItIsTheRunsOwnProcess() throws {
        let before = Date()
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer {
            sleeper.terminate()
            sleeper.waitUntilExit()
        }
        let pid = sleeper.processIdentifier
        #expect(LeftoverProcess.isOurs(pid, since: before, executables: ["sleep"]))
        // Not an executable a run starts: another process holding a recorded id.
        #expect(!LeftoverProcess.isOurs(pid, since: before))
        // Started before the run: a process that was there already.
        #expect(!LeftoverProcess.isOurs(pid, since: before.addingTimeInterval(60), executables: ["sleep"]))
        sleeper.terminate()
        sleeper.waitUntilExit()
        #expect(!LeftoverProcess.isOurs(pid, since: before, executables: ["sleep"]))
    }
}
