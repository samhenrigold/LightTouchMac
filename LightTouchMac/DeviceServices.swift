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
//      time — which also bounds the leaked-thread count to at most one.
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
        let data = try Data(contentsOf: ipa)
        let remote = "PublicStaging/\(Self.stagingName(ipa))"
        return try await run(Timeouts.stage, "upload") { imd, device in
            guard let start = imd.afc_client_start_service,
                  let mkdir = imd.afc_make_directory,
                  let open = imd.afc_file_open,
                  let write = imd.afc_file_write,
                  let close = imd.afc_file_close else { throw DeviceError.unavailable }
            var client: OpaquePointer?
            let rc = start(device, &client, "LightTouchMac")
            guard rc == imd.success, let client else { throw DeviceError.afc(.init(code: rc)) }
            defer { _ = imd.afc_client_free?(client) }

            _ = "PublicStaging".withCString { mkdir(client, $0) }   // ignore "exists"
            var handle: UInt64 = 0
            let or = remote.withCString { open(client, $0, IMobileDevice.afcWriteMode, &handle) }
            guard or == imd.success else { throw DeviceError.afc(.init(code: or)) }

            var written = 0
            var writeError: Int32 = imd.success
            data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return }
                let total = raw.count
                while written < total {
                    let chunk = UInt32(min(1 << 16, total - written))
                    var w: UInt32 = 0
                    let wr = write(client, handle, base + written, chunk, &w)
                    if wr != imd.success { writeError = wr; break }
                    if w == 0 { writeError = 1; break }
                    written += Int(w)
                    progress(Double(written) / Double(total))
                }
            }
            _ = close(client, handle)
            guard writeError == imd.success, written == data.count else {
                throw DeviceError.afc(.init(code: writeError))
            }
            return remote
        }
    }

    /// A stable device-side filename from the .ipa: staging paths must survive
    /// odd characters (`Super Monkey Ball [SEGA]`), so reduce to a safe set.
    private static func stagingName(_ ipa: URL) -> String {
        let base = ipa.deletingPathExtension().lastPathComponent
        let safe = base.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(safe) + ".ipa"
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

    private final class InstallContext {
        let box: SyncBox
        let progress: @Sendable (Int, String) -> Void
        init(_ box: SyncBox, _ progress: @escaping @Sendable (Int, String) -> Void) {
            self.box = box; self.progress = progress
        }
    }

    /// The C status callback runs on libimobiledevice's updater thread. It only
    /// decodes and hands off — nothing that could block or throw.
    private static let installCallback: IMobileDevice.InstproxyStatusCB = { _, status, userData in
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

    private static func blockingInstall(socket: String, stagedPath: String,
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
        case .done:
            Unmanaged<InstallContext>.fromOpaque(ctxPtr).release()
            _ = imd.instproxy_client_free?(client); _ = imd.idevice_free?(device)
        case .failed(let e, let desc):
            Unmanaged<InstallContext>.fromOpaque(ctxPtr).release()
            _ = imd.instproxy_client_free?(client); _ = imd.idevice_free?(device)
            throw DeviceError.instproxy(e, phase: desc)
        case nil:
            throw DeviceError.timedOut(operation: "install")   // leak; gate bounds it
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
func withDeadline<T: Sendable>(_ seconds: Double, _ operation: String,
                               _ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await Task.detached { try work() }.value }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw DeviceError.timedOut(operation: operation)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

// MARK: - Install watchdog box

/// Bridges the C updater thread (which calls `touch`/`finish`) to the waiting
/// install thread. `wait` blocks until a terminal result or until the callback
/// has gone quiet for `idle` seconds — the watchdog that bounds the otherwise
/// unbounded installd wait. NSCondition, because both sides are plain threads.
final class SyncBox: @unchecked Sendable {
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

    func serialized<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        do { let r = try await body(); release(); return r }
        catch { release(); throw error }
    }
}

// MARK: - Errors

enum DeviceError: Error, LocalizedError {
    case unavailable                                   // library not loaded
    case notAttached                                   // idevice_new failed
    case lockdown(Int32)
    case instproxy(InstproxyError, phase: String?)
    case afc(AFCError)
    case diskFull(free: Int64, needed: Int64)
    case timedOut(operation: String)
    case preflight(String)                             // ipod-helper findings
    case failed(String)

    /// Transient service hiccups worth retrying — a fresh boot or a just-freed
    /// service slot refuses connections for a few seconds. A rejected .ipa or a
    /// full disk fails the same way every time and must not loop.
    var isTransient: Bool {
        switch self {
        case .timedOut: return true
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
        case .diskFull(let free, let needed):
            return "Not enough space on the device: \(free / 1_048_576) MB free, "
                + "about \(needed / 1_048_576) MB needed. Uninstall something first."
        case .timedOut(let op): return "The device stopped responding during \(op)."
        case .preflight(let m): return m
        case .failed(let m): return m
        }
    }
}

/// installation_proxy error codes (installation_proxy.h). Only the ones the
/// retry policy keys on are named; everything else is `.other`.
enum InstproxyError: Equatable, CustomStringConvertible {
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
        case .packageExtractionFailed: return "package extraction failed (device may be full)"
        case .other(let c): return "code \(c)"
        }
    }
}

/// AFC error codes (afc.h). Named subset; the rest is `.other`.
enum AFCError: Equatable, CustomStringConvertible {
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
        case .other(let c): return "code \(c)"
        }
    }
}

// MARK: - Timeouts (the calibration knob — emulated-hardware speed varies)

enum Timeouts {
    static var serviceProbe: Double = 5
    static var browse: Double = 20
    static var uninstall: Double = 120
    static var query: Double = 15
    static var stage: Double = 300           // whole-.ipa AFC upload backstop
    static var installIdle: Double = 90      // since the last status callback
    static var installAbsolute: Double = 600
    static var ssh: Double = 90
}
