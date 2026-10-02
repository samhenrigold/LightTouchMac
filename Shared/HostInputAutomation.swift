import Foundation

/// A caller-requested clean shutdown, separate from GUI Stop/hard halt.
/// Only the iPod panel geometry/gesture has been measured here; iPad callers
/// continue to use their current path until a matching host gesture is qualified.
@MainActor public enum HostInputAutomation {
    public enum Failure: Error { case invalidGesture, refused, interrupted, timedOut, helperExited }

    public static func powerOffGesture(firstGeneration: Bool, knobY: Int = 68) throws -> [VirtualInputEvent] {
        guard (0..<480).contains(knobY) else { throw Failure.invalidGesture }
        let release: Int64 = firstGeneration ? 8650 : 6150
        let touchStart = release + 1500
        var events: [VirtualInputEvent] = [
            .button(0, down: true, at: 0), .button(0, down: false, at: 150),
            .button(1, down: true, at: 2650), .button(1, down: false, at: release),
            .touch(phase: 0, x: 65.0 / 320, y: Double(knobY) / 480, at: touchStart)]
        for step in 1...24 {
            // Preserve the observed integer panel-coordinate interpolation.
            let x = 65 + (295 - 65) * step / 24
            events.append(.touch(phase: step == 24 ? 2 : 1,
                                 x: Double(x) / 320, y: Double(knobY) / 480,
                                 at: touchStart + Int64(step * 80)))
        }
        return events
    }

    /// Polling is a host observation, never a gesture clock. Pausing the guest
    /// therefore pauses every button/touch deadline. Cancellation/timeout asks
    /// QEMU to release only this sequence's signals; it never forces shutdown.
    public static func shutdown(_ process: DeviceSessionProcess, firstGeneration: Bool,
                                knobY: Int = 68, timeout: TimeInterval = 50) async throws {
        let events = try powerOffGesture(firstGeneration: firstGeneration, knobY: knobY)
        let id = UInt64.random(in: 1...UInt64.max)
        try await performShutdown(id: id, events: events, timeout: timeout, unplugAfterDark: !firstGeneration,
            request: { try await process.link.request($0, timeout: 5) },
            power: { (process.status?.shutdownConfirmed == true,
                      process.status?.displaySleeping == true, process.isDead) })
    }

    /// Injected observations permit tests of refusal, cancellation and cable
    /// ordering without substituting a guest or claiming native power-off.
    public static func performShutdown(id: UInt64, events: [VirtualInputEvent],
        timeout: TimeInterval, unplugAfterDark: Bool = true,
        request: (LinkRequest) async throws -> LinkReply,
        power: () -> (confirmed: Bool, sleeping: Bool, dead: Bool)) async throws {
        guard id != 0, VirtualInputEvent.valid(events), timeout.isFinite, timeout > 0, timeout <= 3600 else {
            throw Failure.invalidGesture
        }
        let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(timeout)
        guard case .ok(true) = try await request(.inputSequence(id: id, events: events)) else {
            throw Failure.refused
        }
        var unplugged = false
        do {
            while clock.now < deadline {
                try Task.checkCancellation()
                let state = power()
                if state.confirmed { return }
                if state.dead { throw Failure.helperExited }
                guard case let .inputSequenceStatus(status) = try await request(.inputSequenceStatus(id: id)) else {
                    throw Failure.refused
                }
                if status == 3 || status == 4 { throw Failure.interrupted }
                // Match the prior board adapter: cable change only after the
                // drag completes AND the guest turns its backlight off.
                if unplugAfterDark && status == 2 && state.sleeping && !unplugged {
                    guard case .ok(true) = try await request(.usbConnection(false)) else { throw Failure.refused }
                    unplugged = true
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw Failure.timedOut
        } catch {
            _ = try? await request(.inputSequenceCancel(id: id))
            throw error
        }
    }
}
