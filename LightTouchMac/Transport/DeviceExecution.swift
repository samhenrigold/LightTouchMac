// The device-operation kernel every service runs on: the deadline race (withDeadline / withSoftDeadline,
// abandoned blocked C calls, handles a late open leaves behind), the one serial gate per process
// (DeviceGate), the errors and the timeout knobs. Foundation only; the offline checks compile this file whole.

import Foundation

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
    try Task.checkCancellation()
    let once = ResumeOnce<T>()
    let worker = Task.detached {
        let result: Result<T, Error>
        do {
            try Task.checkCancellation()
            result = .success(try work())
        } catch { result = .failure(error) }
        // Timeout and cancellation count the abandoned worker while holding
        // the resume-once lock. Only a losing worker returns that exact slot.
        if !once.resume(result) { AbandonedWork.returned() }
    }
    let watchdog = Task.detached {
        do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
        once.resume(.failure(DeviceError.timedOut(operation: operation)), onWin: {
            AbandonedWork.abandoned(operation)
            worker.cancel()
        })
    }
    defer { watchdog.cancel() }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { once.attach($0) }
    } onCancel: {
        // C handles remain owned by the worker. Stop waiting promptly, count
        // the still-live session against the cap, and let cooperative upload
        // loops unwind between C calls. A blocked call is never freed under it.
        once.resume(.failure(CancellationError()), onWin: {
            AbandonedWork.abandoned(operation)
            worker.cancel()
        })
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
        logEvent("device: abandoned a blocked thread in \(operation) (\(n) outstanding)")
    }

    static func returned() {
        lock.withLock { if outstanding > 0 { outstanding -= 1 } }
    }
}

/// Wait for `work`, but not forever — and let it finish on its own if we stop
/// waiting. The gate's own `acquire()` has no deadline: `withDeadline` bounds
/// the WORK, not the queueing in front of it, so a device operation that is
/// allowed 120 seconds (an uninstall) could hold up everything behind it,
/// including the quit path's health probe — which then blew the quit budget and
/// terminated the app before the guest was ever asked to power down.
func withSoftDeadline<T: Sendable>(_ seconds: Double,
                                   _ work: @escaping @Sendable () async -> T) async -> T? {
    guard !Task.isCancelled else { return nil }
    let once = ResumeOnce<T?>()
    let worker = Task { once.resume(.success(await work())) }
    let watchdog = Task.detached {
        do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
        if once.resume(.success(nil)) { worker.cancel() }
    }
    defer { watchdog.cancel() }
    return try? await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { once.attach($0) }
    } onCancel: {
        if once.resume(.success(nil)) { worker.cancel() }
    }
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

// MARK: - Handles a late open leaves behind

/// What a blocking open hands back (a service client, its callback context);
/// `free` is safe from any thread.
nonisolated protocol OpenedHandles: AnyObject, Sendable { func free() }

/// Open under a deadline and hand the handles to the caller. withDeadline
/// discards the race's loser, so an open that lands after the deadline (or the
/// caller's cancellation) has nobody to take its handles: they are freed here
/// instead, never under a live library thread. nil when `open` produced none.
func openBeforeDeadline<H: OpenedHandles>(_ seconds: Double, _ operation: String,
                                          _ open: @escaping @Sendable () throws -> H?) async throws -> H? {
    let late = LateHandles<H>()
    do {
        try await withDeadline(seconds, operation) { if let opened = try open() { late.store(opened) } }
    } catch {
        if let orphan = late.take(abandon: true) { await freeDetached(orphan, seconds, operation) }
        throw error
    }
    return late.take()
}

/// Free on a task of its own under a deadline: the C free can block (it joins
/// the library's reader thread), and it must run even when the caller was cancelled.
func freeDetached<H: OpenedHandles>(_ handles: H, _ seconds: Double, _ operation: String) async {
    await Task.detached {
        _ = try? await withDeadline(seconds, "\(operation) cleanup") { handles.free() }
    }.value
}

/// Keeps what an open produced reachable until the caller claims it or the
/// deadline's loser frees it; an open that lands after the abandon frees itself.
nonisolated private final class LateHandles<H: OpenedHandles>: @unchecked Sendable {
    private let lock = NSLock()
    private var handles: H?
    private var abandoned = false
    func store(_ opened: H) {
        let discard = lock.withLock {
            if abandoned { return true }
            handles = opened
            return false
        }
        if discard { opened.free() }
    }
    func take(abandon: Bool = false) -> H? {
        lock.withLock {
            abandoned = abandon
            defer { handles = nil }
            return handles
        }
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

    /// Points libimobiledevice at one device's usbmuxd. libusbmuxd reads
    /// USBMUXD_SOCKET_ADDRESS on every connect and the variable is
    /// process-wide, so this is only called inside `serialized`: the gate is
    /// what keeps two running devices off each other's daemon.
    /// ponytail: one gate for every device, so a long operation on one delays
    /// the other; phase 4 can move the services into each device's helper.
    /// The one way left to reach the wrong daemon is a thread abandoned past
    /// its deadline that connects again after the switch; that is logged.
    nonisolated static func point(at socket: String) {
        let previous: String? = socketLock.withLock { defer { currentSocket = socket }; return currentSocket }
        let abandoned = AbandonedWork.count
        if let previous, previous != socket, abandoned > 0 {
            logEvent("device: usbmuxd switched from \(previous) to \(socket) with \(abandoned) abandoned operation(s) outstanding; a late connect could reach the other device")
        }
        setenv("USBMUXD_SOCKET_ADDRESS", socket, 1)
    }
    private static let socketLock = NSLock()
    nonisolated(unsafe) private static var currentSocket: String?
    private var busy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    private func acquire() async throws {
        try Task.checkCancellation()
        if !busy { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().continuation.resume() }
    }

    func serialized<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        // Refuse rather than pile on: every one of those outstanding threads is
        // still holding a lockdown session against a guest that serves about
        // one, so starting another is what keeps it from recovering.
        guard AbandonedWork.count < AbandonedWork.cap else { throw DeviceError.recovering }
        try await acquire()
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
        case .unavailable: return "App services are missing from this copy of Light Touch. Reinstall Light Touch."
        case .notAttached: return "The device is not reachable over USB yet."
        case .lockdown(let c): return "The device refused the connection (error \(c))."
        case .instproxy(let e, let phase):
            return "The install didn’t finish (\(phase ?? "install")): \(e)."
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

/// A failure the app words itself: a missing bundled tool, or a message for the alert.
nonisolated enum DeviceToolsError: LocalizedError {
    case toolMissing(String)
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .toolMissing(let t):
            return "A component (\(t)) is missing from this copy of Light Touch. Reinstall Light Touch."
        case .failed(let msg): return msg
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
        // NOT "(device may be full)" any more: AppInstallPipeline.install checks free
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
        case .other(1): return "unknown error"
        case .other(18): return "the device’s storage is full"
        case .other(11), .other(30): return "device connection lost"
        case .other(let c): return "code \(c)"
        }
    }
}

// MARK: - Timeouts (the calibration knob — emulated-hardware speed varies)

nonisolated enum Timeouts {
    nonisolated(unsafe) static var serviceProbe: Double = 5
    nonisolated(unsafe) static var browse: Double = 20
    nonisolated(unsafe) static var uninstall: Double = 120
    nonisolated(unsafe) static var query: Double = 15
    nonisolated(unsafe) static var stage: Double = 300           // whole-.ipa AFC upload backstop
    nonisolated(unsafe) static var installIdle: Double = 90      // since the last status callback
    nonisolated(unsafe) static var installAbsolute: Double = 600
}
