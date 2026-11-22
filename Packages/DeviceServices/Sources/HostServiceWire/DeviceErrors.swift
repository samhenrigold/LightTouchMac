// The service errors both sides speak (the helper throws them, the wire carries them, the app words them) and
// the timeout knobs.

import Foundation

// MARK: - Errors

public nonisolated enum DeviceError: Error, LocalizedError, Codable, Sendable {
    case unavailable  // library not loaded
    case notAttached  // idevice_new failed
    case lockdown(Int32)
    case instproxy(InstproxyError, phase: String?)
    case afc(AFCError)
    case upload(AFCError, written: UInt64, total: UInt64)
    case diskFull(free: Int64, needed: Int64)
    case timedOut(operation: String)
    case recovering  // earlier requests still stuck
    case endpointBusy  // another device still owns blocked calls
    case preflight(String)  // ipod-helper findings
    case failed(String)

    /// Transient service hiccups worth retrying — a fresh boot or a just-freed
    /// service slot refuses connections for a few seconds. A rejected .ipa or a
    /// full disk fails the same way every time and must not loop.
    public var shouldPauseInstallQueue: Bool {
        switch self {
        case .notAttached, .lockdown, .afc, .upload, .timedOut, .recovering, .endpointBusy: return true
        case .instproxy(let error, _): return error.isTransient
        default: return false
        }
    }

    public var isTransient: Bool {
        switch self {
        // NOT .timedOut. A timed-out operation has left a blocked C thread and
        // an open service connection behind it (see AbandonedWork), so retrying
        // one stacks a second and a third against a guest that serves about one
        // — turning a single wedged install into a session with no working app
        // management at all. Only failures that left nothing behind retry.
        case .timedOut: return false
        case .recovering, .endpointBusy: return true
        case .lockdown: return true
        case .instproxy(let e, _): return e.isTransient
        case .afc(let e): return e.isTransient
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "App services are missing from this copy of Light Touch. Reinstall Light Touch."
        case .notAttached: return "The device is not reachable over USB yet."
        case .lockdown(let c): return "The device refused the connection (error \(c))."
        case .instproxy(let e, let phase):
            return "The install didn’t finish (\(phase ?? "install")): \(e)."
        case .afc(let e): return "File-transfer error: \(e)."
        case .upload(let e, let written, let total):
            return
                "Upload stopped after \(written / 1_048_576) of \(total / 1_048_576) MB: \(e). Pending installs are paused; resume them from the app list’s context menu after the device responds."
        case .diskFull(let free, let needed):
            return "Not enough space on the device: \(free / 1_048_576) MB free, "
                + "about \(needed / 1_048_576) MB needed. Uninstall something first."
        case .timedOut(let op): return "The device stopped responding during \(op)."
        case .recovering:
            return "The device stopped responding; still waiting for earlier requests to finish."
        case .endpointBusy:
            return
                "Another device’s USB request is still running. Wait for it to finish before connecting to this device."
        case .preflight(let m): return m
        case .failed(let m): return m
        }
    }
}

/// A failure the app words itself: a missing bundled tool, or a message for the alert.
public nonisolated enum DeviceToolsError: LocalizedError, Codable, Sendable {
    case toolMissing(String)
    case failed(String)
    /// lockdown took the time zone, but the device kept this one (lockdown-tz's exit 4).
    case zoneKept(String)
    public var errorDescription: String? {
        switch self {
        case .toolMissing(let t):
            return "A component (\(t)) is missing from this copy of Light Touch. Reinstall Light Touch."
        case .failed(let msg): return msg
        case .zoneKept(let zone): return "The device kept its time zone (\(zone))."
        }
    }
}

/// installation_proxy error codes (installation_proxy.h). Only the ones the
/// retry policy keys on are named; everything else is `.other`.
public nonisolated enum InstproxyError: Equatable, CustomStringConvertible, Codable, Sendable {
    case success, connFailed, opInProgress, opFailed, receiveTimeout
    case packageExtractionFailed, alreadyInstalled
    case other(Int32)

    public init(code: Int32) {
        switch code {
        case 0: self = .success
        case -3: self = .connFailed
        case -4: self = .opInProgress
        case -5: self = .opFailed
        case -6: self = .receiveTimeout
        case -9: self = .alreadyInstalled
        case -34: self = .packageExtractionFailed
        default: self = .other(code)
        }
    }
    /// Connection-level refusals recover; a rejected package does not.
    public var isTransient: Bool {
        switch self {
        case .connFailed, .opInProgress, .receiveTimeout: return true
        default: return false
        }
    }
    public var description: String {
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
        // Nor "may still be encrypted, or built for a different architecture": the install reads the binary for
        // both before it uploads (AppBinary).
        case .packageExtractionFailed: return "the device couldn’t unpack the app’s archive; the file may be damaged"
        case .other(let c): return "code \(c)"
        }
    }
}

/// AFC error codes (afc.h). Named subset; the rest is `.other`.
public nonisolated enum AFCError: Equatable, CustomStringConvertible, Codable, Sendable {
    case success, opTimeout, noMem, internalError
    case other(Int32)
    public init(code: Int32) {
        switch code {
        case 0: self = .success
        case 12: self = .opTimeout
        case 23: self = .internalError
        case 31: self = .noMem
        default: self = .other(code)
        }
    }
    public var isTransient: Bool { self == .opTimeout }
    public var description: String {
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

public nonisolated enum Timeouts {
    // nonisolated(unsafe): calibration knobs the offline checks shorten before any device work starts; read-only after.
    public nonisolated(unsafe) static var serviceProbe: Double = 5
    public nonisolated(unsafe) static var browse: Double = 20
    public nonisolated(unsafe) static var uninstall: Double = 120
    public nonisolated(unsafe) static var query: Double = 15
    public nonisolated(unsafe) static var stage: Double = 300  // whole-.ipa AFC upload backstop
    // since the last status callback; installd goes quiet 2–3 min on big IPAs
    public nonisolated(unsafe) static var installIdle: Double = 300
    public nonisolated(unsafe) static var installAbsolute: Double = 600
}
