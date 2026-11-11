import DeviceRuntime
import Foundation
import Testing

/// DeviceRuntime's power-off gesture and its shutdown driver: event deadlines, the wire round trip, the cable gate after
/// backlight and completion, refusal, timeout, interruption and cancellation; and its gestures on the guest's clock:
/// their events, and a run that ends when the guest's driver has read the touch, or says it didn't. No guest.
struct VirtualInputTests {
    @Test func powerOffGestureDeadlines() throws {
        let n72 = try HostInputAutomation.powerOffGesture(firstGeneration: false)
        let n45 = try HostInputAutomation.powerOffGesture(firstGeneration: true)
        #expect(n72.count == 29 && VirtualInputEvent.valid(n72) && VirtualInputEvent.valid(n45))
        #expect(n72[0].atMilliseconds == 0 && n72[1].atMilliseconds == 150)
        #expect(n72[2].atMilliseconds == 2650 && n72[3].atMilliseconds == 6150)
        #expect(n45[3].atMilliseconds == 8650 && n72.last!.atMilliseconds == 9570)
        #expect(n72.last!.phase == 2 && n72.last!.x == 295.0 / 320)
        var bad = n72
        bad[1].atMilliseconds = -1
        #expect(!VirtualInputEvent.valid(bad))
        bad = n72
        bad[8].x = .nan
        #expect(!VirtualInputEvent.valid(bad))
        bad = n72
        bad.removeLast()
        #expect(!VirtualInputEvent.valid(bad))
        #expect(throws: (any Error).self) {
            try HostInputAutomation.powerOffGesture(firstGeneration: false, knobY: 480)
        }
    }

    @Test func typedEventsSurviveTheWire() throws {
        let n72 = try HostInputAutomation.powerOffGesture(firstGeneration: false)
        let encoded = try JSONEncoder().encode(AppMessage.request(id: 1, .inputSequence(id: 99, events: n72)))
        guard
            case .request(_, .inputSequence(let id, let events)) = try JSONDecoder().decode(
                AppMessage.self,
                from: encoded
            )
        else {
            Issue.record("not an input sequence")
            return
        }
        #expect(id == 99 && events == n72)
    }

    @Test func shutdownUnplugsOnlyAfterBacklightAndCompletion() async throws {
        let n72 = try HostInputAutomation.powerOffGesture(firstGeneration: false)
        var replies = 0
        var seen: [LinkRequest] = []
        var confirmed = false
        var sleeping = false
        try await HostInputAutomation.performShutdown(
            id: 99,
            events: n72,
            timeout: 3,
            request: { r in
                seen.append(r)
                switch r {
                case .inputSequence: return .ok(true)
                case .inputSequenceStatus:
                    replies += 1
                    if replies == 1 {
                        sleeping = true
                        return .inputSequenceStatus(1)
                    }
                    return .inputSequenceStatus(2)
                case .usbConnection(false):
                    confirmed = true
                    return .ok(true)
                default:
                    Issue.record("unexpected \(r)")
                    return .ok(false)
                }
            },
            power: { (confirmed, sleeping, false) }
        )
        #expect(replies == 2 && seen.last == .usbConnection(false))
    }

    @Test func refusalIsReported() async throws {
        let n72 = try HostInputAutomation.powerOffGesture(firstGeneration: false)
        var refused: [LinkRequest] = []
        await #expect(throws: HostInputAutomation.Failure.refused) {
            try await HostInputAutomation.performShutdown(
                id: 100,
                events: n72,
                timeout: 1,
                request: { r in
                    refused.append(r)
                    return .failure("old dylib")
                },
                power: { (false, false, false) }
            )
        }
        #expect(refused.count == 1)
    }

    @Test func timeoutCancelsTheSequenceAndKeepsTheCable() async throws {
        let n72 = try HostInputAutomation.powerOffGesture(firstGeneration: false)
        var timed: [LinkRequest] = []
        await #expect(throws: HostInputAutomation.Failure.timedOut) {
            try await HostInputAutomation.performShutdown(
                id: 101,
                events: n72,
                timeout: 0.02,
                request: { r in
                    timed.append(r)
                    if case .inputSequenceStatus = r { return .inputSequenceStatus(1) }
                    return .ok(true)
                },
                power: { (false, true, false) }
            )
        }
        #expect(timed.last == .inputSequenceCancel(id: 101))
        #expect(!timed.contains(.usbConnection(false)))
    }

    @Test func interruptionCancelsTheSequence() async throws {
        let n72 = try HostInputAutomation.powerOffGesture(firstGeneration: false)
        var interrupted: [LinkRequest] = []
        await #expect(throws: HostInputAutomation.Failure.interrupted) {
            try await HostInputAutomation.performShutdown(
                id: 102,
                events: n72,
                timeout: 1,
                request: { r in
                    interrupted.append(r)
                    if case .inputSequenceStatus = r { return .inputSequenceStatus(3) }
                    return .ok(true)
                },
                power: { (false, false, false) }
            )
        }
        #expect(interrupted.last == .inputSequenceCancel(id: 102))
    }

    @Test func taskCancellationCancelsTheSequence() async throws {
        let n72 = try HostInputAutomation.powerOffGesture(firstGeneration: false)
        var cancelled: [LinkRequest] = []
        let task = Task { @MainActor in
            try await HostInputAutomation.performShutdown(
                id: 103,
                events: n72,
                timeout: 1,
                request: { r in
                    cancelled.append(r)
                    if case .inputSequenceStatus = r { return .inputSequenceStatus(1) }
                    return .ok(true)
                },
                power: { (false, false, false) }
            )
        }
        while cancelled.isEmpty { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cancelled.last == .inputSequenceCancel(id: 103))
    }

    @Test func gesturesAreValidSequencesInGuestTime() {
        let tap = HostInputAutomation.tap(0.25, 0.75)
        #expect(tap == [.touch(phase: 0, x: 0.25, y: 0.75, at: 0), .touch(phase: 2, x: 0.25, y: 0.75, at: 80)])
        let drag = HostInputAutomation.drag(from: (0.18, 0.9), to: (0.92, 0.9))
        #expect(VirtualInputEvent.valid(tap) && VirtualInputEvent.valid(drag))
        #expect(drag.count == 32 && drag[1].atMilliseconds == 150 && drag[30].atMilliseconds == 1020)
        #expect(abs(drag[30].x - 0.92) < 1e-12 && drag[31].x == 0.92 && drag[31].phase == 2)
        #expect(drag[31].atMilliseconds == 1350, "as the harness's slide always was")
        #expect(abs(drag[1].x - (0.18 + 0.74 / 30)) < 1e-12, "the first move is a step, not the start again")
        let press = HostInputAutomation.press(0)
        #expect(press == [.button(0, down: true, at: 0), .button(0, down: false, at: 150)])
        #expect(VirtualInputEvent.valid(press))
    }

    /// Made, then read: the run returns only when the emulator made every event and the guest's driver read the
    /// press and the lift.
    @Test func aGestureEndsWhenTheGuestHasReadIt() async throws {
        var seen: [LinkRequest] = []
        var statuses = [0, 1, 1, 2]
        var waits = [true, true, false]
        try await HostInputAutomation.perform(HostInputAutomation.tap(0.5, 0.5), id: 7) { r in
            seen.append(r)
            switch r {
            case .inputSequence(7, let events): return .ok(events.count == 2)
            case .inputSequenceStatus(7): return .inputSequenceStatus(statuses.removeFirst())
            case .touchWaiting: return .touchWaiting(waits.removeFirst(), reads: 3)
            default:
                Issue.record("unexpected \(r)")
                return .ok(false)
            }
        }
        #expect(statuses.isEmpty && waits.isEmpty && seen.last == .touchWaiting)
        #expect(!seen.contains(.inputSequenceCancel(id: 7)))
        // A button reaches no digitizer, and an emulator before the call can't say: neither waits.
        seen = []
        try await HostInputAutomation.perform(HostInputAutomation.press(0), id: 8) { r in
            seen.append(r)
            if case .inputSequenceStatus = r { return .inputSequenceStatus(2) }
            return .ok(true)
        }
        #expect(seen == [.inputSequence(id: 8, events: HostInputAutomation.press(0)), .inputSequenceStatus(id: 8)])
        try await HostInputAutomation.perform(HostInputAutomation.tap(0.5, 0.5), id: 9) { r in
            switch r {
            case .inputSequenceStatus: .inputSequenceStatus(2)
            case .touchWaiting: .failure("Touch delivery unavailable")
            default: .ok(true)
            }
        }
    }

    /// A guest whose driver reads nothing (its digitizer powered down) is told apart from one that took the tap.
    @Test func aTouchTheGuestNeverReadIsUnread() async throws {
        var asked = 0
        await #expect(throws: HostInputAutomation.Failure.unread) {
            try await HostInputAutomation.perform(HostInputAutomation.tap(0.5, 0.5), id: 10, grace: 0.05) { r in
                switch r {
                case .inputSequenceStatus: return .inputSequenceStatus(2)
                case .touchWaiting:
                    asked += 1
                    return .touchWaiting(true, reads: 0)
                default: return .ok(true)
                }
            }
        }
        #expect(asked >= 1)
    }

    @Test func aGestureTheEmulatorRefusesOrCutsShortSaysSo() async throws {
        for (status, failure) in [(4, HostInputAutomation.Failure.refused), (3, .interrupted)] {
            var seen: [LinkRequest] = []
            await #expect(throws: failure) {
                try await HostInputAutomation.perform(HostInputAutomation.tap(0.5, 0.5), id: 11) { r in
                    seen.append(r)
                    if case .inputSequenceStatus = r { return .inputSequenceStatus(status) }
                    return .ok(true)
                }
            }
            #expect(seen.last == .inputSequenceCancel(id: 11) && !seen.contains(.touchWaiting))
        }
        await #expect(throws: HostInputAutomation.Failure.refused) {
            try await HostInputAutomation.perform(HostInputAutomation.tap(0.5, 0.5)) { _ in .failure("old dylib") }
        }
        await #expect(throws: HostInputAutomation.Failure.timedOut) {
            try await HostInputAutomation.perform(HostInputAutomation.tap(0.5, 0.5), timeout: 0.05) { r in
                if case .inputSequenceStatus = r { return .inputSequenceStatus(1) }
                return .ok(true)
            }
        }
        await #expect(throws: HostInputAutomation.Failure.invalidGesture) {
            try await HostInputAutomation.perform([.touch(phase: 0, x: 0.5, y: 0.5, at: 0)]) { _ in .ok(true) }
        }
    }
}
