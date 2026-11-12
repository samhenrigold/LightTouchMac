import Foundation

/// Input the host makes for the guest in the guest's own time (qemu_ios_ui_input_sequence): taps, drags and button
/// presses that end when the guest's digitizer driver has read them (`perform`), and a caller-requested clean
/// shutdown, separate from GUI Stop/hard halt. Only the iPod panel geometry/gesture has been measured for that
/// shutdown; iPad callers continue to use their current path until a matching host gesture is qualified.
@MainActor public enum HostInputAutomation {
    public enum Failure: Error {
        case invalidGesture, refused, interrupted, timedOut, helperExited
        /// The emulator made the touch, and the guest's digitizer driver didn't read it: nothing in the guest is
        /// listening (its digitizer powered down behind a dark lock screen, its driver not up yet).
        case unread
    }

    // MARK: Gestures on the guest's clock

    /// A finger down at a point of the screen (0...1, y down) and up `hold` ms later.
    public nonisolated static func tap(_ x: Double, _ y: Double, hold: Int64 = 80) -> [VirtualInputEvent] {
        [.touch(phase: 0, x: x, y: y, at: 0), .touch(phase: 2, x: x, y: y, at: hold)]
    }

    /// A finger down at the first point, still for `lead` ms, moved to the second in `steps` moves `interval` ms
    /// apart, still for `trail` ms after the last move's interval and up: the defaults are the slide that unlocks
    /// every firmware's lock screen (1.35 s).
    public nonisolated static func drag(
        from: (x: Double, y: Double),
        to: (x: Double, y: Double),
        lead: Int64 = 150,
        steps: Int = 30,
        interval: Int64 = 30,
        trail: Int64 = 300
    ) -> [VirtualInputEvent] {
        var events: [VirtualInputEvent] = [.touch(phase: 0, x: from.x, y: from.y, at: 0)]
        for step in 1...max(1, steps) {
            let f = Double(step) / Double(max(1, steps))
            events.append(
                .touch(
                    phase: 1,
                    x: from.x + (to.x - from.x) * f,
                    y: from.y + (to.y - from.y) * f,
                    at: lead + Int64(step - 1) * interval
                )
            )
        }
        let moved = lead + Int64(max(1, steps) - 1) * interval
        events.append(.touch(phase: 2, x: to.x, y: to.y, at: moved + interval + trail))
        return events
    }

    /// A button (QEMU_IOS_BUTTON_*) down and up `hold` ms later.
    public nonisolated static func press(_ button: Int32, hold: Int64 = 150) -> [VirtualInputEvent] {
        [.button(button, down: true, at: 0), .button(button, down: false, at: hold)]
    }

    /// Makes `events` in the guest's own time (qemu_ios_ui_input_sequence), so a busy Mac neither stretches nor
    /// squeezes a gesture as the guest sees it, and returns once the emulator has made the last of them and the
    /// guest's digitizer driver has read every press and lift (qemu_ios_ui_touch_waiting; an emulator without that
    /// call isn't asked). Throws `refused` when the emulator won't start it (a finger or button the user holds),
    /// `interrupted` when other input cut it short, `unread` when the driver took none of it within `grace` seconds
    /// of its end, `timedOut` (default: four times its length and ten seconds; a paused guest's clock stands still).
    /// What iOS then makes of the touch is the guest's: the agent's report tells (GuestAgent.report).
    public nonisolated static func perform(
        _ events: [VirtualInputEvent],
        id: UInt64 = .random(in: 1...UInt64.max),
        timeout: TimeInterval? = nil,
        grace: TimeInterval = 5,
        request: (LinkRequest) async throws -> LinkReply
    ) async throws {
        guard id != 0, VirtualInputEvent.valid(events) else { throw Failure.invalidGesture }
        let clock = ContinuousClock()
        let length = Double(events.last?.atMilliseconds ?? 0) / 1000
        let deadline = clock.now + .seconds(timeout ?? 10 + 4 * length)
        guard case .ok(true) = try await request(.inputSequence(id: id, events: events)) else {
            throw Failure.refused
        }
        do {
            made: while true {
                try Task.checkCancellation()
                guard case .inputSequenceStatus(let status) = try await request(.inputSequenceStatus(id: id)) else {
                    throw Failure.refused
                }
                switch status {
                case 2: break made
                case 3: throw Failure.interrupted
                case 4: throw Failure.refused
                default: break
                }
                guard clock.now < deadline else { throw Failure.timedOut }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            _ = try? await request(.inputSequenceCancel(id: id))
            throw error
        }
        guard events.contains(where: { $0.kind == 1 }) else { return }
        // A running guest reads a report within a frame or two; the gesture's end follows its lift by 100 ms.
        let unread = clock.now + .seconds(grace)
        while case .touchWaiting(true, _) = try await request(.touchWaiting) {
            guard clock.now < unread else { throw Failure.unread }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    public static func powerOffGesture(firstGeneration: Bool, knobY: Int = 68) throws -> [VirtualInputEvent] {
        guard (0..<480).contains(knobY) else { throw Failure.invalidGesture }
        let release: Int64 = firstGeneration ? 8650 : 6150
        let touchStart = release + 1500
        var events: [VirtualInputEvent] = [
            .button(0, down: true, at: 0), .button(0, down: false, at: 150),
            .button(1, down: true, at: 2650), .button(1, down: false, at: release),
            .touch(phase: 0, x: 65.0 / 320, y: Double(knobY) / 480, at: touchStart)
        ]
        for step in 1...24 {
            // Preserve the observed integer panel-coordinate interpolation.
            let x = 65 + (295 - 65) * step / 24
            events.append(
                .touch(
                    phase: step == 24 ? 2 : 1,
                    x: Double(x) / 320,
                    y: Double(knobY) / 480,
                    at: touchStart + Int64(step * 80)
                )
            )
        }
        return events
    }

    /// Polling is a host observation, never a gesture clock. Pausing the guest
    /// therefore pauses every button/touch deadline. Cancellation/timeout asks
    /// QEMU to release only this sequence's signals; it never forces shutdown.
    public static func shutdown(
        _ process: DeviceSessionProcess,
        firstGeneration: Bool,
        knobY: Int = 68,
        timeout: TimeInterval = 50
    ) async throws {
        let events = try powerOffGesture(firstGeneration: firstGeneration, knobY: knobY)
        let id = UInt64.random(in: 1...UInt64.max)
        try await performShutdown(
            id: id,
            events: events,
            timeout: timeout,
            unplugAfterDark: !firstGeneration,
            request: { try await process.link.request($0, timeout: 5) },
            power: {
                (
                    process.status?.shutdownConfirmed == true,
                    process.status?.displaySleeping == true, process.isDead
                )
            }
        )
    }

    /// Injected observations permit tests of refusal, cancellation and cable
    /// ordering without substituting a guest or claiming native power-off.
    public static func performShutdown(
        id: UInt64,
        events: [VirtualInputEvent],
        timeout: TimeInterval,
        unplugAfterDark: Bool = true,
        request: (LinkRequest) async throws -> LinkReply,
        power: () -> (confirmed: Bool, sleeping: Bool, dead: Bool)
    ) async throws {
        guard id != 0, VirtualInputEvent.valid(events), timeout.isFinite, timeout > 0, timeout <= 3600 else {
            throw Failure.invalidGesture
        }
        let clock = ContinuousClock()
        let deadline = ContinuousClock.now + .seconds(timeout)
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
                guard case .inputSequenceStatus(let status) = try await request(.inputSequenceStatus(id: id)) else {
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
