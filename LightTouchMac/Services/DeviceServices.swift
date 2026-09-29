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
//      time — across devices too: with several running, the gate is what keeps
//      each operation on its own device's usbmuxd (DeviceGate.point(at:)).
//      Correct, but the devices wait for each other; the phase-4 option is to
//      run these services inside each device's helper, one process per daemon. The gate does NOT bound the leaked threads on its own — what
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

    nonisolated static func validateFilePath(_ path: String) throws {
        guard !path.hasPrefix("/"), !path.contains("\0"),
              path.isEmpty || path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DeviceError.preflight("Invalid device file path.")
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

    func stageVideo(_ video: MediaVideo, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard UUID(uuidString: video.id) != nil, video.video.lastPathComponent == "video.m4v" else {
            throw DeviceError.preflight("Invalid video staging path.")
        }
        _ = try await stageFile(video.video, remote: "LightTouch/\(video.id)/video.m4v", reuseIdentical: true, progress: progress)
    }

    func uploadFile(_ source: URL, into directory: String,
                    progress: @escaping @Sendable (Double) -> Void) async throws {
        try Self.validateFilePath(directory)
        let path = directory.isEmpty ? source.lastPathComponent : directory + "/" + source.lastPathComponent
        try Self.validateFilePath(path)
        guard !path.isEmpty else { throw DeviceError.preflight("Select a file to import.") }
        _ = try await stageFile(source, remote: path, reuseIdentical: true, allowEmpty: true, progress: progress)
    }

    /// Callers supply a validated relative destination. The same chunked AFC
    /// upload, cancellation and incomplete-file cleanup serve apps and songs.
    private func stageFile(_ ipa: URL, remote: String, reuseIdentical: Bool = false, allowEmpty: Bool = false,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        return try await run(Timeouts.stage, "upload") { imd, device in
            // File I/O stays on the detached worker, including opening the file.
            let input = try FileHandle(forReadingFrom: ipa)
            defer { try? input.close() }
            let total = try input.seekToEnd()
            try input.seek(toOffset: 0)
            guard total > 0 || allowEmpty else { throw DeviceError.preflight("The file is empty.") }
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
            let destination = reuseIdentical ? remote + ".upload-" + Self.stagingSession + "-" + UUID().uuidString : remote
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
            try Task.checkCancellation()
            if reuseIdentical {
                let renamed = destination.withCString { from in
                    remote.withCString { to in imd.afc_rename_path!(client, from, to) }
                }
                guard renamed == imd.success else { throw DeviceError.afc(.init(code: renamed)) }
            }
            complete = true
            progress(1)
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

    private static func isOrphanedMediaUpload(_ name: String) -> Bool {
        let parts = name.components(separatedBy: ".upload-")
        guard parts.count == 2,
              ["audio.mp3", "audio.m4a", "audio.aac", "audio.wav", "image.jpg"].contains(parts[0]),
              !parts[1].hasPrefix(stagingSession + "-") else { return false }
        let suffix = parts[1]
        if UUID(uuidString: suffix) != nil { return true } // Earlier atomic uploads.
        return suffix.count == 73 && suffix[suffix.index(suffix.startIndex, offsetBy: 36)] == "-"
            && UUID(uuidString: String(suffix.prefix(36))) != nil
            && UUID(uuidString: String(suffix.suffix(36))) != nil
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

            func entries(_ path: String) -> [String] {
                var list: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                guard path.withCString({ readDir(client, $0, &list) }) == imd.success,
                      let list else { return [] }
                defer { _ = dictFree(list) }
                var names: [String] = [], i = 0
                while let entry = list[i] { names.append(String(cString: entry)); i += 1 }
                return names
            }
            for name in entries("PublicStaging") {
                try Task.checkCancellation()
                guard Self.isOrphanedStagingName(name) else { continue }
                logEvent("device: removing orphaned staging upload \(name)")
                _ = "PublicStaging/\(name)".withCString { remove(client, $0) }
            }
            for directory in entries("LightTouch") where UUID(uuidString: directory) != nil {
                try Task.checkCancellation()
                for name in entries("LightTouch/\(directory)") {
                    try Task.checkCancellation()
                    guard Self.isOrphanedMediaUpload(name) else { continue }
                    _ = "LightTouch/\(directory)/\(name)".withCString { remove(client, $0) }
                }
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

    nonisolated private final class InstallConnection: @unchecked Sendable {
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

    /// A deadline may win immediately after connection succeeds. Keep handles
    /// reachable until the caller claims them or the losing worker closes them.
    nonisolated private final class PendingInstallConnection: @unchecked Sendable {
        private let lock = NSLock()
        private var connection: InstallConnection?
        private var abandoned = false
        func store(_ opened: InstallConnection) {
            let discard = lock.withLock {
                if abandoned { return true }
                connection = opened
                return false
            }
            if discard { opened.free() }
        }
        func take(abandon: Bool = false) -> InstallConnection? {
            lock.withLock {
                abandoned = abandon
                defer { connection = nil }
                return connection
            }
        }
    }

    private nonisolated static func installConnection(socket: String) async throws -> InstallConnection {
        let pending = PendingInstallConnection()
        do {
            try await withDeadline(Timeouts.serviceProbe * 2, "install connection") {
                pending.store(try openInstallConnection(socket: socket))
            }
        } catch {
            if let connection = pending.take(abandon: true) {
                // The C startup worker has finished; this is a separate cleanup
                // operation. Run even if the caller's task was cancelled.
                await Task.detached {
                    _ = try? await withDeadline(Timeouts.serviceProbe * 2, "install connection cleanup") {
                        connection.free()
                    }
                }.value
            }
            throw error
        }
        // A successful startup always stores before completing the deadline.
        guard let connection = pending.take() else { throw DeviceError.unavailable }
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
            let client = try imd.startInstallationProxy(device: device)
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
}
