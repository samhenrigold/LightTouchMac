// Created by Sam on 2026-08-05.
//
// One device's stock lockdown services, in-process through the dlopen'd
// libimobiledevice (Transport/IMobileDevice.swift): the struct and its `run`
// kernel here, one file per service beside it — InstallationProxy (list,
// install, uninstall), AFC (free space, staging, the Files browser),
// LockdownTools (ActivationState, the lockdown-tz child). This is what retires
// ideviceinstaller and the 579-line install script from the app's path, and with them a week of glue
// bugs: the unbounded idevice_wait_for_command_to_complete hang, retry logic
// that string-matched stderr, and an ssh ControlPath that silently disabled
// every guest command.
//
// Three rules hold this together:
//   1. Blocking C calls run on a detached task and race an explicit deadline.
//      A deadline loss abandons (leaks) the still-blocked task — a blocked C
//      call cannot be cancelled — and reconnects fresh. Never free a handle
//      from the watchdog side; that frees under a live library thread.
//   2. One process-wide serial gate. setenv(USBMUXD_SOCKET_ADDRESS) is global
//      and the guest serves ~one lockdown session, so all of this is one at a
//      time — across devices too: with several running, the gate is what keeps
//      each operation on its own device's usbmuxd (DeviceGate.point(at:)).
//      Correct, but the devices wait for each other; the phase-4 option is to
//      run these services inside each device's helper, one process per daemon. The gate does NOT bound the leaked threads on its own — what
//      releases it is the deadline, not the thread — so they are counted
//      (AbandonedWork) and the gate refuses new work past the cap.
//   3. Errors are typed (the C libraries' own return codes), and the retry
//      policy is expressed over those codes, not over the text of a message.

import Foundation

nonisolated struct DeviceServices: Sendable {
    let clientSocket: String

    // MARK: - Execution: gate + deadline + fresh handles

    /// Run blocking libimobiledevice work under the process-wide gate and a
    /// deadline, with a freshly-opened idevice handle freed on the way out.
    /// `body` gets the loaded library and an attached device; it opens whatever
    /// service clients it needs and frees them itself.
    func run<T: Sendable>(_ seconds: Double, _ label: String,
                          _ body: @escaping @Sendable (IMobileDevice.Type, OpaquePointer) throws -> T)
        async throws -> T
    {
        let socket = clientSocket
        return try await DeviceGate.shared.serialized {
            let started = ContinuousClock.now
            do {
                return try await withDeadline(seconds, label) {
                    let imd = IMobileDevice.self
                    guard imd.isAvailable, let idevice_new = imd.idevice_new else {
                        throw DeviceError.unavailable
                    }
                    // Points the whole library at OUR emulator's usbmuxd rather than
                    // a real device or another instance (they share a UDID).
                    DeviceGate.point(at: socket)
                    var device: OpaquePointer?
                    guard idevice_new(&device, nil) == imd.success, let device else {
                        throw DeviceError.notAttached
                    }
                    defer { _ = imd.idevice_free?(device) }
                    return try body(imd, device)
                }
            } catch {
                if !(error is CancellationError) {
                    logEvent("device operation \(label) failed after \(started.duration(to: .now)): \(error.localizedDescription)")
                }
                throw error
            }
        }
    }

    // MARK: - Attachment

    /// Does the USB bridge see the guest? Bounded and gated. A bare
    /// `Task.detached` here once had neither: `idevice_new` against a half-open
    /// usbmuxd socket blocks with no timeout, and this is called from the quit
    /// path — so a wedged socket hung the quit itself. `withDeadline` abandons
    /// the blocked thread; the gate keeps it from racing other device work.
    func checkAttachment() async throws {
        let socket = clientSocket
        // Bounded INCLUDING the wait for the gate. withDeadline bounds the probe
        // itself, but not the queue in front of it, and this is called from the
        // quit path — where waiting out a 120s uninstall means the app's own
        // backstop fires and the guest is killed without ever being asked to
        // power down. Giving up on the answer is safe; every caller treats a
        // silent device as "could not prove it is alive", not "it is dead".
        let result: Result<Void, Error>? = await withSoftDeadline(Timeouts.serviceProbe * 2) {
            do {
                try await DeviceGate.shared.serialized {
                    try await withDeadline(Timeouts.serviceProbe, "USB connection") {
                        try IMobileDevice.checkAttachment(socket: socket)
                    }
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try Task.checkCancellation()
        guard let result else { throw DeviceError.timedOut(operation: "USB connection") }
        try result.get()
    }
}
