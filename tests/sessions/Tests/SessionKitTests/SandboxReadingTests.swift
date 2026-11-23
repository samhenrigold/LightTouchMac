import Foundation
import Testing

@testable import SessionKit

/// A process just started may not be in its sandbox yet, so "not sandboxed" is asked again while a sandbox is expected
/// and "sandboxed" is final (SandboxReading): usbmuxd read at the helper's hello failed the iPad row now and then.
struct SandboxReadingTests {
    final class Reader {
        var answers: [Bool]
        private(set) var asked = 0
        init(_ answers: [Bool]) { self.answers = answers }
        func read() -> Bool {
            asked += 1
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
    }

    @Test func aSandboxAppliedJustAfterTheFirstReadingCounts() {
        let late = Reader([false, false, true])
        #expect(SandboxReading.settled(expected: true, late.read))
        #expect(late.asked == 3)
    }

    @Test func aProcessThatNeverEntersItsSandboxIsNotSandboxed() {
        let never = Reader([false])
        #expect(!SandboxReading.settled(expected: true, patience: .milliseconds(200), never.read))
    }

    @Test func noSandboxExpectedIsReadOnce() {
        let unsandboxed = Reader([false])
        #expect(!SandboxReading.settled(expected: false, unsandboxed.read))
        #expect(unsandboxed.asked == 1)
        let sandboxed = Reader([true])
        #expect(SandboxReading.settled(expected: false, sandboxed.read))
        #expect(sandboxed.asked == 1)
    }
}
