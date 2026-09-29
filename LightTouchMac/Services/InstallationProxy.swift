// installation_proxy: the installed-app list, install of a staged .ipa (with the
// owned idle watchdog) and uninstall, on DeviceServices' run kernel.

import Foundation

struct InstalledApp: Identifiable, Sendable {
    /// The `CFBundleIdentifier`
    let id: String
    let name: String
    let version: String
}

extension DeviceServices {
    // MARK: - List

    /// Installed third-party apps, via instproxy_browse with an
    /// ApplicationType=User filter. Replaces parsing `ideviceinstaller list`.
    func installedApps() async throws -> [InstalledApp] {
        try await run(Timeouts.browse, "list apps") { imd, device in
            guard let browse = imd.instproxy_browse,
                  let plistFree = imd.plist_free else { throw DeviceError.unavailable }

            let client = try imd.startInstallationProxy(device: device)
            defer { _ = imd.instproxy_client_free?(client) }

            // ApplicationType=User: skip Apple's own bundles. Built as a plist
            // rather than via instproxy's variadic option builder (uncallable
            // through a function pointer).
            guard let options = IMobileDevice.encode(["ApplicationType": "User"]) else {
                throw DeviceError.unavailable
            }
            defer { plistFree(options) }

            var result: OpaquePointer?
            let br = browse(client, options, &result)
            guard br == imd.success, let result else {
                throw DeviceError.instproxy(.init(code: br), phase: "browse")
            }
            defer { plistFree(result) }

            let apps = (IMobileDevice.decode(result) as? [[String: Any]] ?? []).compactMap {
                (dict: [String: Any]) -> InstalledApp? in
                guard let id = dict["CFBundleIdentifier"] as? String else { return nil }
                let name = (dict["CFBundleDisplayName"] as? String)
                    ?? (dict["CFBundleName"] as? String) ?? id
                let version = (dict["CFBundleVersion"] as? String)
                    ?? (dict["CFBundleShortVersionString"] as? String) ?? ""
                return InstalledApp(id: id, name: name, version: version)
            }
            return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    // MARK: - Uninstall

    func uninstall(_ bundleID: String) async throws {
        try await run(Timeouts.uninstall, "uninstall \(bundleID)") { imd, device in
            guard let uninstall = imd.instproxy_uninstall else { throw DeviceError.unavailable }
            let client = try imd.startInstallationProxy(device: device)
            defer { _ = imd.instproxy_client_free?(client) }
            // Synchronous form: no status callback, so the return code is the
            // whole answer (unlike install, whose errors arrive in the callback).
            let ur = bundleID.withCString { uninstall(client, $0, nil, nil, nil) }
            guard ur == imd.success else {
                throw DeviceError.instproxy(.init(code: ur), phase: "uninstall")
            }
        }
    }

    // MARK: - Install (instproxy_install + owned idle watchdog)

    /// Install a staged .ipa. The owned idle watchdog is the fix for the
    /// unbounded idevice_wait_for_command_to_complete hang: with a status
    /// callback installed, errors arrive ONLY in the callback, and if installd
    /// resets mid-install nothing arrives at all — so the idle timer, not the
    /// library, is what ends the wait.
    func install(stagedPath: String, progress: @escaping @Sendable (Int, String) -> Void) async throws {
        try await DeviceGate.shared.serialized {
            let socket = self.clientSocket
            let cancellation = InstallCancellation()
            try await withTaskCancellationHandler {
                let connection = try await Self.installConnection(socket: socket)
                // Once the guest mutation begins, retain the gate until its
                // existing callback watchdog finishes. Cancelling before that
                // point closes the connection without submitting an install.
                try await Task.detached {
                    try Self.blockingInstall(connection: connection, cancellation: cancellation,
                                             stagedPath: stagedPath, progress: progress)
                }.value
            } onCancel: {
                cancellation.cancel()
            }
        }
    }

    nonisolated private final class InstallCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        /// The mutation's ownership boundary. Cancellation after this check
        /// leaves the active install owned until its terminal callback/watchdog.
        func beginMutation() throws {
            try lock.withLock { if cancelled { throw CancellationError() } }
        }
    }

    nonisolated private final class InstallConnection: OpenedHandles, @unchecked Sendable {
        let device: OpaquePointer
        let client: OpaquePointer
        init(device: OpaquePointer, client: OpaquePointer) {
            self.device = device; self.client = client
        }
        func free() {
            _ = IMobileDevice.instproxy_client_free?(client)
            _ = IMobileDevice.idevice_free?(device)
        }
    }

    /// A deadline may win immediately after connection succeeds; openBeforeDeadline
    /// frees the late handles then.
    private nonisolated static func installConnection(socket: String) async throws -> InstallConnection {
        // A successful startup always stores before completing the deadline.
        guard let connection = try await openBeforeDeadline(Timeouts.serviceProbe * 2, "install connection", {
            try openInstallConnection(socket: socket)
        }) else { throw DeviceError.unavailable }
        return connection
    }

    private nonisolated static func openInstallConnection(socket: String) throws -> InstallConnection {
        let imd = IMobileDevice.self
        guard imd.isAvailable, let idevice_new = imd.idevice_new,
              imd.instproxy_install != nil else { throw DeviceError.unavailable }
        DeviceGate.point(at: socket)
        var device: OpaquePointer?
        guard idevice_new(&device, nil) == imd.success, let device else { throw DeviceError.notAttached }
        let client: OpaquePointer
        do {
            try Task.checkCancellation()
            client = try imd.startInstallationProxy(device: device)
        } catch {
            _ = imd.idevice_free?(device)
            throw error
        }
        let connection = InstallConnection(device: device, client: client)
        do { try Task.checkCancellation() }
        catch { connection.free(); throw error }
        return connection
    }

    nonisolated private final class InstallContext {
        let box: SyncBox
        let progress: @Sendable (Int, String) -> Void
        init(_ box: SyncBox, _ progress: @escaping @Sendable (Int, String) -> Void) {
            self.box = box; self.progress = progress
        }
    }

    /// The C status callback runs on libimobiledevice's updater thread. It only
    /// decodes and hands off — nothing that could block or throw.
    nonisolated private static let installCallback: IMobileDevice.InstproxyStatusCB = { _, status, userData in
        guard let userData, let status else { return }
        let ctx = Unmanaged<InstallContext>.fromOpaque(userData).takeUnretainedValue()
        let imd = IMobileDevice.self
        ctx.box.touch()

        var errName: UnsafeMutablePointer<CChar>?
        var errDesc: UnsafeMutablePointer<CChar>?
        var errCode: UInt64 = 0
        let er = imd.instproxy_status_get_error?(status, &errName, &errDesc, &errCode) ?? 0
        if er != imd.success || errName != nil {
            let desc = errDesc.map { String(cString: $0) }
                ?? errName.map { String(cString: $0) } ?? "install failed"
            errName.map { free($0) }; errDesc.map { free($0) }
            ctx.box.finish(.failed(InstproxyError(code: er == 0 ? -5 : er), desc))
            return
        }

        var namePtr: UnsafeMutablePointer<CChar>?
        imd.instproxy_status_get_name?(status, &namePtr)
        let name = namePtr.map { String(cString: $0) } ?? ""
        namePtr.map { free($0) }

        if name == "Complete" { ctx.box.finish(.done); return }

        var percent: Int32 = -1
        imd.instproxy_status_get_percent_complete?(status, &percent)
        ctx.progress(Int(percent), name)
    }

    nonisolated private static func blockingInstall(connection: InstallConnection,
                                                    cancellation: InstallCancellation, stagedPath: String,
                                                    progress: @escaping @Sendable (Int, String) -> Void) throws {
        let imd = IMobileDevice.self
        guard let installFn = imd.instproxy_install else {
            connection.free()
            throw DeviceError.unavailable
        }
        do { try cancellation.beginMutation() }
        catch { connection.free(); throw error }
        let box = SyncBox()
        let ctx = InstallContext(box, progress)
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
        let ir = stagedPath.withCString { installFn(connection.client, $0, nil, installCallback, ctxPtr) }
        guard ir == imd.success else {
            connection.free()
            Unmanaged<InstallContext>.fromOpaque(ctxPtr).release()
            throw DeviceError.instproxy(.init(code: ir), phase: "start")
        }

        // Block THIS detached thread until a terminal status or an idle/absolute
        // timeout. On timeout the updater thread may still be live, so its
        // handles are leaked deliberately rather than freed under it.
        let terminal = box.wait(idle: Timeouts.installIdle, absolute: Timeouts.installAbsolute)
        switch terminal {
        // Free the client FIRST: that is what joins libimobiledevice's status
        // updater thread. Releasing the context before the join deallocates it
        // under a thread that may still fire one more callback, and the callback
        // does takeUnretainedValue → a write through a freed NSCondition.
        case .done:
            connection.free()
            Unmanaged<InstallContext>.fromOpaque(ctxPtr).release()
        case .failed(let e, let desc):
            connection.free()
            Unmanaged<InstallContext>.fromOpaque(ctxPtr).release()
            throw DeviceError.instproxy(e, phase: desc)
        case nil:
            // Deliberately leaks the client and the device handle: freeing them
            // here would free them under libimobiledevice's own updater thread,
            // which is still live. Tell the accountant, though — this is the
            // one leak that never did, so the cap meant to stop leaked sessions
            // piling up could not see the very case it exists for.
            // Counted, and GIVEN BACK on a timer. The leaked handles here are
            // not a blocked thread — blockingInstall returns — so nothing else
            // will ever call returned() for them, and three install timeouts
            // in a session would otherwise close the gate permanently: every
            // later device operation failing with "still waiting for earlier
            // requests" until the app is relaunched. The cap exists to stop a
            // pile-up, not to become one.
            AbandonedWork.abandoned("install")
            Task.detached {
                try? await Task.sleep(for: .seconds(Timeouts.installIdle))
                AbandonedWork.returned()
            }
            throw DeviceError.timedOut(operation: "install")
        }
    }

    // MARK: - Service readiness

    /// Does installation_proxy answer right now? A fresh boot brings lockdownd
    /// up ~40s before its services, so "lockdown replies" ≠ "installd is ready".
    func installProxyReady() async -> Bool {
        (try? await run(Timeouts.serviceProbe, "installd probe") { imd, device in
            let client = try imd.startInstallationProxy(device: device)
            _ = imd.instproxy_client_free?(client)
            return true
        }) ?? false
    }
}
