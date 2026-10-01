// Stock host services execute in an immutable-endpoint, killable host worker.
// Only the worker calls the local C engine; no shipping GUI fallback exists.

import Foundation

nonisolated struct DeviceServices: Sendable {
    static let session = UUID()
    let clientSocket: String
    let endpoint: HostServiceEndpoint
    let local: Bool
    init(clientSocket: String, udid: String? = nil, session: UUID = Self.session, local: Bool = false) {
        self.clientSocket = clientSocket
        self.endpoint = HostServiceEndpoint(socket: clientSocket, udid: udid, session: session)
        self.local = local
    }

    // MARK: - Execution: gate + deadline + fresh handles

    /// Run blocking libimobiledevice work under the process-wide gate and a
    /// deadline, with a freshly-opened idevice handle freed on the way out.
    /// `body` gets the loaded library and an attached device; it opens whatever
    /// service clients it needs and frees them itself.
    func run<T: Sendable>(_ seconds: Double, _ label: String,
                          _ body: @escaping @Sendable (IMobileDevice.Type, OpaquePointer) throws -> T)
        async throws -> T
    {
        guard local else { throw DeviceToolsError.failed("Unrouted host service operation.") }
        let socket = clientSocket
        return try await DeviceGate.shared.serialized(socket: socket) {
            let started = ContinuousClock.now
            do {
                return try await withDeadline(seconds, label) {
                    let imd = IMobileDevice.self
                    guard imd.isAvailable, let idevice_new = imd.idevice_new else {
                        throw DeviceError.unavailable
                    }
                    var device: OpaquePointer?
                    let opened = endpoint.udid.map { id in id.withCString { idevice_new(&device, $0) } } ?? idevice_new(&device, nil)
                    guard opened == imd.success, let device else {
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
        if !local { _ = try await remote(.attachment, seconds: Timeouts.serviceProbe * 2); return }
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
}
