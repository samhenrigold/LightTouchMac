import Foundation

/// Host-authored physical input only. QEMU owns execution deadlines and pins.
nonisolated public struct VirtualInputEvent: Codable, Sendable, Equatable {
    public var atMilliseconds: Int64
    public var kind: Int32
    public var value: Int32
    public var phase: Int32
    public var x: Double
    public var y: Double

    public static func button(_ button: Int32, down: Bool, at: Int64) -> Self {
        .init(atMilliseconds: at, kind: 0, value: button, phase: down ? 1 : 0, x: 0, y: 0)
    }
    public static func touch(phase: Int32, x: Double, y: Double, at: Int64) -> Self {
        .init(atMilliseconds: at, kind: 1, value: 0, phase: phase, x: x, y: y)
    }
    public static func valid(_ events: [Self]) -> Bool {
        guard !events.isEmpty, events.count <= 256 else { return false }
        var buttons = [Bool](repeating: false, count: 4), touch = false
        var previous: Int64 = 0
        for event in events {
            guard event.atMilliseconds >= previous, event.atMilliseconds <= 600_000 else { return false }
            previous = event.atMilliseconds
            if event.kind == 0 {
                guard (0...3).contains(event.value), (0...1).contains(event.phase),
                      buttons[Int(event.value)] != (event.phase == 1) else { return false }
                buttons[Int(event.value)] = event.phase == 1
            } else if event.kind == 1 {
                guard event.value == 0, (0...2).contains(event.phase),
                      event.x.isFinite, event.y.isFinite,
                      (0...1).contains(event.x), (0...1).contains(event.y),
                      event.phase == 0 ? !touch : touch else { return false }
                touch = event.phase != 2
            } else { return false }
        }
        return !touch && !buttons.contains(true)
    }
}

/// Caller-observed state for the measured 320x480 portrait QWERTY layout.
/// This is host automation for a visible keyboard, not an emulated device.
nonisolated public struct PortraitKeyboardState: Sendable, Equatable {
    public var numeric: Bool
    public var shifted: Bool
    public var automaticCapitalizationDisabled: Bool
    public init(numeric: Bool, shifted: Bool, automaticCapitalizationDisabled: Bool) {
        self.numeric = numeric
        self.shifted = shifted
        self.automaticCapitalizationDisabled = automaticCapitalizationDisabled
    }
}

nonisolated public struct PortraitKeyboardPlan: Sendable, Equatable {
    public var events: [VirtualInputEvent]
    public var finalState: PortraitKeyboardState

    public enum Failure: Error { case unknownState, unsupportedCharacter, tooLong }

    /// Measured on 2.1.1 Notes: row centres and 60ms down/140ms gaps.
    /// Unsupported characters fail before any input is emitted. The symbols
    /// page is deliberately absent until its distinct geometry is measured.
    public static func make(_ text: String, initialState: PortraitKeyboardState) throws -> Self {
        guard initialState.automaticCapitalizationDisabled,
              !initialState.numeric || !initialState.shifted else { throw Failure.unknownState }
        var state = initialState, events: [VirtualInputEvent] = []
        var at: Int64 = 0
        func tap(_ x: Int, _ y: Int) throws {
            guard events.count <= 254 else { throw Failure.tooLong }
            events.append(.touch(phase: 0, x: Double(x) / 320, y: Double(y) / 480, at: at))
            events.append(.touch(phase: 2, x: Double(x) / 320, y: Double(y) / 480, at: at + 60))
            at += 200
        }
        for character in text.utf16 {
            guard character > 0, character < 128 else { throw Failure.unsupportedCharacter }
            var numeric = false, shifted = false
            var position: (Int, Int)?
            switch character {
            case 32: position = (160, 458)
            case 10: position = (285, 458)
            case 8: position = (298, 404)
            default:
                let upper = (65...90).contains(character)
                let lower = UInt8(upper ? character + 32 : character)
                shifted = upper
                for (row, origin, y) in [("qwertyuiop", 15, 296), ("asdfghjkl", 31, 350), ("zxcvbnm", 63, 404)] {
                    if let index = Array(row.utf8).firstIndex(of: lower) { position = (origin + index * 32, y); break }
                }
                if position == nil {
                    numeric = true
                    for (row, origin, y) in [("1234567890", 15, 296), ("-/:;()$&@\"", 31, 350)] {
                        if let index = Array(row.utf8).firstIndex(of: UInt8(character)) { position = (origin + index * 32, y); break }
                    }
                }
            }
            guard let (x, y) = position else { throw Failure.unsupportedCharacter }
            if numeric != state.numeric {
                try tap(30, 458)
                state.numeric = numeric
                state.shifted = false
            }
            if !numeric && shifted != state.shifted {
                try tap(24, 404)
                state.shifted = shifted
            }
            try tap(x, y)
            // Measured single-use Shift, not Caps Lock or an inferred OS state.
            if state.shifted { state.shifted = false }
        }
        return .init(events: events, finalState: state)
    }
}

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

    /// Explicit compatibility automation for a visible, measured portrait
    /// keyboard. Normal GUI typing retains the existing board compatibility
    /// path until this adapter has matching native evidence. The returned state is usable only after complete delivery;
    /// cancellation/manual interference invalidates the caller's prior state.
    public static func typePortraitText(_ text: String, on process: DeviceSessionProcess,
        initialState: PortraitKeyboardState, timeout: TimeInterval = 60) async throws -> PortraitKeyboardState {
        guard timeout.isFinite, timeout > 0, timeout <= 3600 else { throw Failure.invalidGesture }
        let plan = try PortraitKeyboardPlan.make(text, initialState: initialState)
        if plan.events.isEmpty { return initialState }
        let id = UInt64.random(in: 1...UInt64.max)
        guard case .ok(true) = try await process.link.request(.inputSequence(id: id, events: plan.events), timeout: 5) else {
            throw Failure.refused
        }
        let deadline = ContinuousClock.now + .seconds(timeout)
        do {
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                if process.isDead { throw Failure.helperExited }
                guard case let .inputSequenceStatus(status) = try await process.link.request(.inputSequenceStatus(id: id), timeout: 5) else {
                    throw Failure.refused
                }
                if status == 2 { return plan.finalState }
                if status == 3 || status == 4 { throw Failure.interrupted }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw Failure.timedOut
        } catch {
            _ = try? await process.link.request(.inputSequenceCancel(id: id), timeout: 5)
            throw error
        }
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
