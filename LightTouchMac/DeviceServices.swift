// Created by Sam on 2026-08-05.
//
// Every device operation the app used to shell out for — listing, installing,
// uninstalling apps, checking free space — done in-process through the
// dlopen'd libimobiledevice (see IMobileDevice.swift), the way SpringBoardIcons
// already talks to sbservices. This is what retires ideviceinstaller and the
// 579-line install script from the app's path, and with them a week of glue
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
//      time. The gate does NOT bound the leaked threads on its own — what
//      releases it is the deadline, not the thread — so they are counted
//      (AbandonedWork) and the gate refuses new work past the cap.
//   3. Errors are typed (the C libraries' own return codes), and the retry
//      policy is expressed over those codes, not over the text of a message.

import Foundation

struct DeviceServices: Sendable {
    let clientSocket: String

    // MARK: - List

    /// Installed third-party apps, via instproxy_browse with an
    /// ApplicationType=User filter. Replaces parsing `ideviceinstaller list`.
    func installedApps() async throws -> [InstalledApp] {
        try await run(Timeouts.browse, "list apps") { imd, device in
            guard let start = imd.instproxy_client_start_service,
                  let browse = imd.instproxy_browse,
                  let plistFree = imd.plist_free else { throw DeviceError.unavailable }

            var client: OpaquePointer?
            let rc = start(device, &client, "LightTouchMac")
            guard rc == imd.success, let client else {
                throw DeviceError.instproxy(.init(code: rc), phase: "connect")
            }
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
            guard let start = imd.instproxy_client_start_service,
                  let uninstall = imd.instproxy_uninstall else { throw DeviceError.unavailable }
            var client: OpaquePointer?
            let rc = start(device, &client, "LightTouchMac")
            guard rc == imd.success, let client else {
                throw DeviceError.instproxy(.init(code: rc), phase: "connect")
            }
            defer { _ = imd.instproxy_client_free?(client) }
            // Synchronous form: no status callback, so the return code is the
            // whole answer (unlike install, whose errors arrive in the callback).
            let ur = bundleID.withCString { uninstall(client, $0, nil, nil, nil) }
            guard ur == imd.success else {
                throw DeviceError.instproxy(.init(code: ur), phase: "uninstall")
            }
        }
    }

    // MARK: - Free space

    /// Bytes free on the media partition, via AFC. The pre-flight that names a
    /// full device before installd fails opaquely with PackageExtractionFailed.
    func freeSpaceBytes() async throws -> Int64 {
        try await run(Timeouts.query, "free space") { imd, device in
            guard let start = imd.afc_client_start_service,
                  let infoKey = imd.afc_get_device_info_key else { throw DeviceError.unavailable }
            var client: OpaquePointer?
            let rc = start(device, &client, "LightTouchMac")
            guard rc == imd.success, let client else {
                throw DeviceError.afc(.init(code: rc))
            }
            defer { _ = imd.afc_client_free?(client) }
            var value: UnsafeMutablePointer<CChar>?
            let fr = "FSFreeBytes".withCString { infoKey(client, $0, &value) }
            guard fr == imd.success, let value else { throw DeviceError.afc(.init(code: fr)) }
            defer { free(value) }
            return Int64(String(cString: value)) ?? 0
        }
    }

    // MARK: - Stage (AFC upload into /PublicStaging)

    /// Upload the .ipa into the AFC jail and return its device-relative path,
    /// which is what instproxy_install wants. Chunked so progress is live.
    func stage(_ ipa: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try await stageFile(ipa, remote: "PublicStaging/\(Self.stagingName(ipa))", progress: progress)
    }

    func stageSong(_ song: MediaSong, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard UUID(uuidString: song.id) != nil,
              MediaSong.extensions.contains(song.audio.pathExtension),
              song.audio.lastPathComponent == "audio." + song.audio.pathExtension else {
            throw DeviceError.preflight("Invalid media staging path.")
        }
        _ = try await stageFile(song.audio, remote: "LightTouch/\(song.id)/\(song.audio.lastPathComponent)",
                                reuseIdentical: true, progress: progress)
    }

    func stagePhoto(_ photo: MediaPhoto, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard UUID(uuidString: photo.id) != nil, photo.image.lastPathComponent == "image.jpg" else {
            throw DeviceError.preflight("Invalid photo staging path.")
        }
        _ = try await stageFile(photo.image, remote: "LightTouch/\(photo.id)/image.jpg", reuseIdentical: true, progress: progress)
    }

    /// Callers supply a validated relative destination. The same chunked AFC
    /// upload, cancellation and incomplete-file cleanup serve apps and songs.
    private func stageFile(_ ipa: URL, remote: String, reuseIdentical: Bool = false,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        return try await run(Timeouts.stage, "upload") { imd, device in
            // File I/O stays on the detached worker, including opening the file.
            let input = try FileHandle(forReadingFrom: ipa)
            defer { try? input.close() }
            let total = try input.seekToEnd()
            try input.seek(toOffset: 0)
            guard total > 0 else { throw DeviceError.preflight("The file is empty.") }
            guard let start = imd.afc_client_start_service,
                  let mkdir = imd.afc_make_directory,
                  let open = imd.afc_file_open,
                  let write = imd.afc_file_write,
                  let close = imd.afc_file_close else { throw DeviceError.unavailable }
            var client: OpaquePointer?
            let rc = start(device, &client, "LightTouchMac")
            guard rc == imd.success, let client else { throw DeviceError.afc(.init(code: rc)) }
            defer { _ = imd.afc_client_free?(client) }
            if reuseIdentical {
                guard let read = imd.afc_file_read, imd.afc_rename_path != nil else { throw DeviceError.unavailable }
                var existing: UInt64 = 0
                let result = remote.withCString { open(client, $0, 1, &existing) } // AFC_FOPEN_RDONLY.
                if result == imd.success {
                    defer { _ = close(client, existing) }
                    var buffer = [CChar](repeating: 0, count: 65536)
                    while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty {
                        var offset = 0
                        while offset < chunk.count {
                            try Task.checkCancellation()
                            var count: UInt32 = 0
                            let rc = read(client, existing, &buffer, UInt32(chunk.count - offset), &count)
                            guard rc == imd.success, count > 0, count <= chunk.count - offset,
                                  Data(bytes: buffer, count: Int(count)) == chunk.subdata(in: offset..<(offset + Int(count))) else {
                                throw DeviceError.preflight("An existing media file differs from this import. It was kept unchanged.")
                            }
                            offset += Int(count)
                        }
                    }
                    var count: UInt32 = 0
                    guard read(client, existing, &buffer, 1, &count) == imd.success, count == 0 else {
                        throw DeviceError.preflight("An existing media file differs from this import. It was kept unchanged.")
                    }
                    progress(1)
                    return remote
                }
                guard result == 8 else { throw DeviceError.afc(.init(code: result)) } // Object not found.
            }
            // Publish complete media only. Interrupted uploads never truncate a
            // library file or leave a partial file at its content-derived path.
            let destination = reuseIdentical ? remote + ".upload-" + UUID().uuidString : remote
            var parent = ""
            for component in remote.split(separator: "/").dropLast() {
                parent = parent.isEmpty ? String(component) : parent + "/" + component
                _ = parent.withCString { mkdir(client, $0) }
            }
            var handle: UInt64 = 0
            let opened = destination.withCString { open(client, $0, IMobileDevice.afcWriteMode, &handle) }
            guard opened == imd.success else { throw DeviceError.afc(.init(code: opened)) }
            var closed = false
            var complete = false
            defer {
                if !closed { _ = close(client, handle) }
                if !complete { _ = destination.withCString { imd.afc_remove_path?(client, $0) } }
            }
            var written: UInt64 = 0
            while written < total {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: Int(min(1 << 16, total - written))),
                      !chunk.isEmpty else { throw DeviceError.preflight("The file changed during upload.") }
                try chunk.withUnsafeBytes { raw in
                    let base = raw.bindMemory(to: CChar.self).baseAddress!
                    var offset = 0
                    while offset < raw.count {
                        try Task.checkCancellation()
                        var count: UInt32 = 0
                        let rc = write(client, handle, base + offset, UInt32(raw.count - offset), &count)
                        guard rc == imd.success, count > 0, count <= raw.count - offset else {
                            throw DeviceError.upload(.init(code: rc == 0 ? 1 : rc), written: written, total: total)
                        }
                        offset += Int(count)
                        written += UInt64(count)
                    }
                }
                progress(Double(written) / Double(total))
            }
            let result = close(client, handle)
            closed = true
            guard result == imd.success else { throw DeviceError.upload(.init(code: result), written: written, total: total) }
            if reuseIdentical {
                let renamed = destination.withCString { from in
                    remote.withCString { to in imd.afc_rename_path!(client, from, to) }
                }
                guard renamed == imd.success else { throw DeviceError.afc(.init(code: renamed)) }
            }
            complete = true
            return remote
        }
    }

    /// A stable device-side filename from the .ipa: staging paths must survive
    /// odd characters (`Super Monkey Ball [SEGA]`), so reduce to a safe set.
    /// Unique per upload. Collapsing punctuation to "_" made "Temple Run",
    /// "Temple-Run" and "Temple.Run" all stage to one path, so re-dropping a
    /// newer build landed on a file the device still held open from the last
    /// attempt — AFC refused it (the bare "File-transfer error: code 1") — and
    /// one install's fire-and-forget cleanup could delete the next install's
    /// upload out from under it. A unique suffix removes both.
    private static let stagingSession = UUID().uuidString

    private static func stagingName(_ ipa: URL) -> String {
        let base = ipa.deletingPathExtension().lastPathComponent
        let safe = String(base.map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(48))
        return "\(safe)-\(stagingSession)-\(UUID().uuidString.prefix(8)).ipa"
    }

    /// Startup cleanup can run after a new upload begins. Session-tagged names
    /// protect every upload from this process, including ones not yet queued.
    private static func isOrphanedStagingName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && !name.contains("-\(stagingSession)-")
    }

    func sweepStaging() async {
        _ = try? await run(Timeouts.query, "staging sweep") { imd, device in
            guard let start = imd.afc_client_start_service,
                  let readDir = imd.afc_read_directory,
                  let remove = imd.afc_remove_path,
                  let dictFree = imd.afc_dictionary_free else { return }
            var client: OpaquePointer?
            guard start(device, &client, "LightTouchMac") == imd.success, let client else { return }
            defer { _ = imd.afc_client_free?(client) }

            var list: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
            guard "PublicStaging".withCString({ readDir(client, $0, &list) }) == imd.success,
                  let list else { return }
            defer { _ = dictFree(list) }

            var i = 0
            while let entry = list[i] {
                let name = String(cString: entry)
                i += 1
                try Task.checkCancellation()
                guard Self.isOrphanedStagingName(name) else { continue }
                NSLog("device: removing orphaned staging upload \(name)")
                _ = "PublicStaging/\(name)".withCString { remove(client, $0) }
            }
        }
    }

    /// Best-effort cleanup of a staged upload.
    func removeStaged(_ path: String) async {
        _ = try? await run(Timeouts.query, "cleanup") { imd, device in
            guard let start = imd.afc_client_start_service,
                  let remove = imd.afc_remove_path else { return }
            var client: OpaquePointer?
            guard start(device, &client, "LightTouchMac") == imd.success, let client else { return }
            defer { _ = imd.afc_client_free?(client) }
            _ = path.withCString { remove(client, $0) }
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
            try await Task.detached {
                try Self.blockingInstall(socket: socket, stagedPath: stagedPath, progress: progress)
            }.value
        }
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

    nonisolated private static func blockingInstall(socket: String, stagedPath: String,
                                                    progress: @escaping @Sendable (Int, String) -> Void) throws {
        let imd = IMobileDevice.self
        guard imd.isAvailable, let idevice_new = imd.idevice_new,
              let start = imd.instproxy_client_start_service,
              let installFn = imd.instproxy_install else { throw DeviceError.unavailable }
        setenv("USBMUXD_SOCKET_ADDRESS", socket, 1)

        var device: OpaquePointer?
        guard idevice_new(&device, nil) == imd.success, let device else { throw DeviceError.notAttached }
        var client: OpaquePointer?
        let rc = start(device, &client, "LightTouchMac")
        guard rc == imd.success, let client else {
            _ = imd.idevice_free?(device)
            throw DeviceError.instproxy(.init(code: rc), phase: "connect")
        }

        let box = SyncBox()
        let ctx = InstallContext(box, progress)
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
        let ir = stagedPath.withCString { installFn(client, $0, nil, installCallback, ctxPtr) }
        guard ir == imd.success else {
            Unmanaged<InstallContext>.fromOpaque(ctxPtr).release()
            _ = imd.instproxy_client_free?(client); _ = imd.idevice_free?(device)
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
            _ = imd.instproxy_client_free?(client); _ = imd.idevice_free?(device)
            Unmanaged<InstallContext>.fromOpaque(ctxPtr).release()
        case .failed(let e, let desc):
            _ = imd.instproxy_client_free?(client); _ = imd.idevice_free?(device)
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

    /// lockdownd's ActivationState: "Activated", "Unactivated", "FactoryActivated".
    ///
    /// The tell for a torn filesystem. A hard exit loses HFS+ catalog updates
    /// that were still in memory, and if the activation record is among them the
    /// guest boots to the Connect-to-iTunes screen — where lockdownd still
    /// answers but every service refuses, so the app's only symptom was an
    /// unexplained "Install service error (connect): code -256". Asking turns
    /// that dead end into something the UI can name and offer a fix for.
    func activationState() async -> String? {
        try? await run(Timeouts.query, "activation state") { imd, device in
            guard let newClient = imd.lockdownd_client_new_with_handshake,
                  let getValue = imd.lockdownd_get_value,
                  let plistFree = imd.plist_free else { throw DeviceError.unavailable }
            var client: OpaquePointer?
            let rc = newClient(device, &client, "LightTouchMac")
            guard rc == imd.success, let client else { throw DeviceError.lockdown(rc) }
            defer { _ = imd.lockdownd_client_free?(client) }

            var value: OpaquePointer?
            let vr = "ActivationState".withCString { getValue(client, nil, $0, &value) }
            guard vr == imd.success, let value else { throw DeviceError.lockdown(vr) }
            defer { plistFree(value) }
            return IMobileDevice.decode(value) as? String
        }
    }

    // MARK: - Service readiness

    /// Does installation_proxy answer right now? A fresh boot brings lockdownd
    /// up ~40s before its services, so "lockdown replies" ≠ "installd is ready".
    func installProxyReady() async -> Bool {
        (try? await run(Timeouts.serviceProbe, "installd probe") { imd, device in
            guard let start = imd.instproxy_client_start_service else { throw DeviceError.unavailable }
            var client: OpaquePointer?
            let rc = start(device, &client, "LightTouchMac")
            guard rc == imd.success, let client else {
                throw DeviceError.instproxy(.init(code: rc), phase: "probe")
            }
            _ = imd.instproxy_client_free?(client)
            return true
        }) ?? false
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
        let socket = clientSocket
        return try await DeviceGate.shared.serialized {
            try await withDeadline(seconds, label) {
                let imd = IMobileDevice.self
                guard imd.isAvailable, let idevice_new = imd.idevice_new else {
                    throw DeviceError.unavailable
                }
                // Points the whole library at OUR emulator's usbmuxd rather than
                // a real device or another instance (they share a UDID).
                setenv("USBMUXD_SOCKET_ADDRESS", socket, 1)
                var device: OpaquePointer?
                guard idevice_new(&device, nil) == imd.success, let device else {
                    throw DeviceError.notAttached
                }
                defer { _ = imd.idevice_free?(device) }
                return try body(imd, device)
            }
        }
    }
}

// MARK: - Deadline

/// Race blocking work against a timeout. The loser is abandoned: a blocked C
/// call ignores cancellation, so on a timeout the detached task keeps running
/// until the call returns and its result is discarded — the deliberate leak the
/// serial gate bounds to one.
/// The race MUST be unstructured. A task group awaits every child before its
/// scope unwinds — and `await Task.detached{}.value` is not interrupted by
/// cancellation — so racing inside a group produced the timeout error but then
/// blocked until the C call returned anyway: the deadline never actually fired,
/// and a wedged guest held the serial gate forever (every later device op
/// queued behind it with no error, looking like "buttons do nothing").
/// Resume-once + a detached worker is what genuinely leaves the thread behind.
func withDeadline<T: Sendable>(_ seconds: Double, _ operation: String,
                               _ work: @escaping @Sendable () throws -> T) async throws -> T {
    let once = ResumeOnce<T>()
    let worker = Task.detached {
        let result: Result<T, Error>
        do { result = .success(try work()) } catch { result = .failure(error) }
        // Losing the race means the deadline already fired and this thread was
        // written off. It is alive again now, so give the budget its slot back.
        if !once.resume(result) { AbandonedWork.returned() }
    }
    Task.detached {
        try? await Task.sleep(for: .seconds(seconds))
        once.resume(.failure(DeviceError.timedOut(operation: operation)), onWin: {
            AbandonedWork.abandoned(operation)
            worker.cancel()
        })
    }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { once.attach($0) }
    } onCancel: {
        // Do not free C handles or release the gate until the worker returns
        // (or its watchdog fires). Cooperative loops stop between C calls.
        worker.cancel()
    }
}

/// How many blocked C threads have been walked away from and not come back.
///
/// The gate does NOT bound this on its own, whatever the header used to claim:
/// what releases the gate is the deadline firing, not the thread finishing, so
/// a guest that never answers leaks one thread and one lockdown session per
/// attempt — and the list poll alone attempts one every few seconds. Each of
/// those sessions is a slot the guest doesn't have, so piling on more is also
/// what stops it from ever recovering. Past the cap, new work fails fast until
/// the stuck threads drain, which they do the moment the guest comes back.
nonisolated enum AbandonedWork {
    /// ponytail: a plain counter under a lock. Fine at this scale — it is
    /// touched once per timed-out device op, not per call.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var outstanding = 0

    /// Above this, the guest is clearly not answering and more sessions will
    /// not help. Two in flight is already one more than it serves.
    static let cap = 3

    static var count: Int { lock.withLock { outstanding } }

    static func abandoned(_ operation: String) {
        let n = lock.withLock { outstanding += 1; return outstanding }
        NSLog("device: abandoned a blocked thread in \(operation) (\(n) outstanding)")
    }

    static func returned() {
        lock.withLock { if outstanding > 0 { outstanding -= 1 } }
    }
}

#if DEBUG
/// The accounting has to balance both ways. Counting an abandoned thread and
/// never giving the slot back closes the gate permanently — every device
/// operation for the rest of the run fails with "still waiting for earlier
/// requests" and nothing ever clears it — which is a worse failure than the
/// leak it exists to bound.
func abandonedWorkSelfCheck() async {
    let before = AbandonedWork.count
    do {
        _ = try await withDeadline(0.05, "self-check") { Thread.sleep(forTimeInterval: 0.5) }
        assertionFailure("withDeadline did not time out")
    } catch {}
    assert(AbandonedWork.count == before + 1, "a timeout did not count its abandoned thread")
    try? await Task.sleep(for: .seconds(1))   // past the work's own 0.5s
    assert(AbandonedWork.count == before, "an abandoned thread never gave its slot back")
}
#endif

/// Wait for `work`, but not forever — and let it finish on its own if we stop
/// waiting. The gate's own `acquire()` has no deadline: `withDeadline` bounds
/// the WORK, not the queueing in front of it, so a device operation that is
/// allowed 120 seconds (an uninstall) could hold up everything behind it,
/// including the quit path's health probe — which then blew the quit budget and
/// terminated the app before the guest was ever asked to power down.
func withSoftDeadline<T: Sendable>(_ seconds: Double,
                                   _ work: @escaping @Sendable () async -> T) async -> T? {
    let once = ResumeOnce<T?>()
    Task { once.resume(.success(await work())) }
    Task {
        try? await Task.sleep(for: .seconds(seconds))
        once.resume(.success(nil))
    }
    return try? await withCheckedThrowingContinuation { once.attach($0) }
}

/// First result wins; the rest are dropped. Handles the result landing before
/// the continuation attaches (a fast op) and vice versa (the normal case).
nonisolated private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Result<T, Error>?
    private var cont: CheckedContinuation<T, Error>?
    private var done = false

    func attach(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        if let pending, !done {
            done = true; lock.unlock(); c.resume(with: pending); return
        }
        cont = c
        lock.unlock()
    }

    /// True if this result is the one the caller gets — i.e. this side won.
    @discardableResult
    func resume(_ result: Result<T, Error>, onWin: () -> Void = {}) -> Bool {
        lock.lock()
        guard !done, pending == nil else { lock.unlock(); return false }
        // Account for abandoned work before the worker can lose this race and
        // decrement it, and before the caller is allowed to start another op.
        onWin()
        if let c = cont {
            done = true; cont = nil; lock.unlock(); c.resume(with: result); return true
        }
        pending = result
        lock.unlock()
        return true
    }
}

// MARK: - Install watchdog box

/// Bridges the C updater thread (which calls `touch`/`finish`) to the waiting
/// install thread. `wait` blocks until a terminal result or until the callback
/// has gone quiet for `idle` seconds — the watchdog that bounds the otherwise
/// unbounded installd wait. NSCondition, because both sides are plain threads.
nonisolated final class SyncBox: @unchecked Sendable {
    enum Terminal { case done, failed(InstproxyError, String) }
    private let cond = NSCondition()
    private var lastActivity = Date()
    private var terminal: Terminal?

    func touch() { cond.lock(); lastActivity = Date(); cond.signal(); cond.unlock() }
    func finish(_ t: Terminal) { cond.lock(); terminal = t; cond.signal(); cond.unlock() }

    /// Terminal result, or nil if the callback fell silent for `idle` seconds
    /// or the whole thing ran past `absolute`.
    func wait(idle: TimeInterval, absolute: TimeInterval) -> Terminal? {
        let hardDeadline = Date().addingTimeInterval(absolute)
        cond.lock(); defer { cond.unlock() }
        while terminal == nil {
            let wake = min(lastActivity.addingTimeInterval(idle), hardDeadline)
            if wake <= Date() { return nil }
            cond.wait(until: wake)
        }
        return terminal
    }
}

// MARK: - Serial gate

/// One libimobiledevice operation at a time, process-wide. The busy flag +
/// waiter queue (not actor isolation, which reentrancy would break across the
/// body's awaits) is what enforces it.
actor DeviceGate {
    static let shared = DeviceGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    func serialized<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        // Refuse rather than pile on: every one of those outstanding threads is
        // still holding a lockdown session against a guest that serves about
        // one, so starting another is what keeps it from recovering.
        guard AbandonedWork.count < AbandonedWork.cap else { throw DeviceError.recovering }
        await acquire()
        do {
            try Task.checkCancellation()
            guard AbandonedWork.count < AbandonedWork.cap else { throw DeviceError.recovering }
            let r = try await body()
            release()
            return r
        } catch { release(); throw error }
    }
}

// MARK: - Errors

nonisolated enum DeviceError: Error, LocalizedError {
    case unavailable                                   // library not loaded
    case notAttached                                   // idevice_new failed
    case lockdown(Int32)
    case instproxy(InstproxyError, phase: String?)
    case afc(AFCError)
    case upload(AFCError, written: UInt64, total: UInt64)
    case diskFull(free: Int64, needed: Int64)
    case timedOut(operation: String)
    case recovering                                    // earlier requests still stuck
    case preflight(String)                             // ipod-helper findings
    case failed(String)

    /// Transient service hiccups worth retrying — a fresh boot or a just-freed
    /// service slot refuses connections for a few seconds. A rejected .ipa or a
    /// full disk fails the same way every time and must not loop.
    var shouldPauseInstallQueue: Bool {
        switch self {
        case .notAttached, .lockdown, .afc, .upload, .timedOut, .recovering: return true
        case .instproxy(let error, _): return error.isTransient
        default: return false
        }
    }

    var isTransient: Bool {
        switch self {
        // NOT .timedOut. A timed-out operation has left a blocked C thread and
        // an open service connection behind it (see AbandonedWork), so retrying
        // one stacks a second and a third against a guest that serves about one
        // — turning a single wedged install into a session with no working app
        // management at all. Only failures that left nothing behind retry.
        case .timedOut: return false
        case .recovering: return true
        case .lockdown: return true
        case .instproxy(let e, _): return e.isTransient
        case .afc(let e): return e.isTransient
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .unavailable: return "libimobiledevice is not available."
        case .notAttached: return "The device is not reachable over USB yet."
        case .lockdown(let c): return "lockdownd error \(c)."
        case .instproxy(let e, let phase):
            return "Install service error (\(phase ?? "op")): \(e)."
        case .afc(let e): return "File-transfer error: \(e)."
        case .upload(let e, let written, let total):
            return "Upload stopped after \(written / 1_048_576) of \(total / 1_048_576) MB: \(e). Pending installs are paused; resume them from the app list’s context menu after the device responds."
        case .diskFull(let free, let needed):
            return "Not enough space on the device: \(free / 1_048_576) MB free, "
                + "about \(needed / 1_048_576) MB needed. Uninstall something first."
        case .timedOut(let op): return "The device stopped responding during \(op)."
        case .recovering:
            return "The device stopped responding; still waiting for earlier requests to finish."
        case .preflight(let m): return m
        case .failed(let m): return m
        }
    }
}

/// installation_proxy error codes (installation_proxy.h). Only the ones the
/// retry policy keys on are named; everything else is `.other`.
nonisolated enum InstproxyError: Equatable, CustomStringConvertible {
    case success, connFailed, opInProgress, opFailed, receiveTimeout
    case packageExtractionFailed, alreadyInstalled
    case other(Int32)

    init(code: Int32) {
        switch code {
        case 0:   self = .success
        case -3:  self = .connFailed
        case -4:  self = .opInProgress
        case -5:  self = .opFailed
        case -6:  self = .receiveTimeout
        case -9:  self = .alreadyInstalled
        case -34: self = .packageExtractionFailed
        default:  self = .other(code)
        }
    }
    /// Connection-level refusals recover; a rejected package does not.
    var isTransient: Bool {
        switch self { case .connFailed, .opInProgress, .receiveTimeout: return true
                      default: return false }
    }
    var description: String {
        switch self {
        case .success: return "ok"
        case .connFailed: return "connection failed"
        case .opInProgress: return "operation in progress"
        case .opFailed: return "operation failed"
        case .receiveTimeout: return "receive timeout"
        case .alreadyInstalled: return "already installed"
        // NOT "(device may be full)" any more: DeviceTools.install checks free
        // space against the archive before it uploads, so by the time installd
        // says this, space has been PROVEN. Blaming it sent people off
        // uninstalling their apps to fix something else entirely.
        case .packageExtractionFailed:
            return "the device refused the package — it may still be encrypted, "
                + "or built for a different architecture"
        case .other(let c): return "code \(c)"
        }
    }
}

/// AFC error codes (afc.h). Named subset; the rest is `.other`.
nonisolated enum AFCError: Equatable, CustomStringConvertible {
    case success, opTimeout, noMem, internalError, other(Int32)
    init(code: Int32) {
        switch code {
        case 0:  self = .success
        case 12: self = .opTimeout
        case 23: self = .internalError
        case 31: self = .noMem
        default: self = .other(code)
        }
    }
    var isTransient: Bool { self == .opTimeout }
    var description: String {
        switch self {
        case .success: return "ok"
        case .opTimeout: return "timeout"
        case .noMem: return "out of memory"
        case .internalError: return "internal error"
        case .other(1): return "unknown AFC error (code 1)"
        case .other(18): return "device storage is full (code 18)"
        case .other(11), .other(30): return "device connection lost"
        case .other(let c): return "code \(c)"
        }
    }
}

// MARK: - Timeouts (the calibration knob — emulated-hardware speed varies)

nonisolated enum Timeouts {
    static var serviceProbe: Double = 5
    static var browse: Double = 20
    static var uninstall: Double = 120
    static var query: Double = 15
    static var stage: Double = 300           // whole-.ipa AFC upload backstop
    static var installIdle: Double = 90      // since the last status callback
    static var installAbsolute: Double = 600
    static var ssh: Double = 90
}
