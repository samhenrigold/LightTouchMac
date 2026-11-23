// The services helper's engine for one endpoint: the run kernel every operation goes through (the gate, a
// deadline, a fresh idevice handle), the attachment probe and lockdown reads.

import Foundation
import HostServiceWire

extension DeviceServices {
    // MARK: - Execution: gate + deadline + fresh handles

    /// Run blocking libimobiledevice work under the process-wide gate and a
    /// deadline, with a freshly-opened idevice handle freed on the way out.
    /// `body` gets an attached device; it opens whatever service clients it needs and frees them itself.
    func run<T: Sendable>(_ seconds: Double, _ label: String, _ body: @escaping @Sendable (OpaquePointer) throws -> T)
        async throws -> T
    {
        let socket = clientSocket
        return try await DeviceGate.shared.serialized(socket: socket) {
            let started = ContinuousClock.now
            do {
                return try await withDeadline(seconds, label) {
                    var device: OpaquePointer?
                    let opened =
                        endpoint.udid.map { id in id.withCString { idevice_new(&device, $0) } }
                        ?? idevice_new(&device, nil)
                    guard opened.ok, let device else { throw DeviceError.notAttached }
                    defer { _ = idevice_free(device) }
                    return try body(device)
                }
            } catch {
                if !(error is CancellationError) {
                    logEvent(
                        "device operation \(label) failed after \(started.duration(to: .now)): \(error.localizedDescription)"
                    )
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
                try await DeviceGate.shared.serialized(socket: socket) {
                    try await withDeadline(Timeouts.serviceProbe, "USB connection") {
                        try IMobileDevice.checkAttachment()
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

    /// Stock lockdown reads share the same endpoint, timeout and error contract.
    func lockdownValue(_ key: String, domain: String? = nil) async throws -> String? {
        try await run(Timeouts.query, "lockdown " + key) { device in
            var client: OpaquePointer?
            let rc = lockdownd_client_new_with_handshake(device, &client, "LightTouchMac")
            guard rc.ok, let client else { throw DeviceError.lockdown(rc.code) }
            defer { _ = lockdownd_client_free(client) }

            var value: plist_t?
            let vr = lockdownd_get_value(client, domain, key, &value)
            guard vr.ok, let value else { throw DeviceError.lockdown(vr.code) }
            defer { plist_free(value) }
            switch IMobileDevice.decode(value) {
            case let text as String: return text
            case let data as Data: return data.map { String(format: "%02x", $0) }.joined()
            case let number as NSNumber: return number.stringValue
            default: return nil
            }
        }
    }
}
