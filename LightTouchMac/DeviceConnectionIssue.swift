import Foundation

/// An app-service read can fail while iOS and the USB bridge are still alive.
/// Keep that distinction when choosing feedback and automatic recovery.
nonisolated struct DeviceConnectionIssue: Equatable, Sendable {
    let summary: String
    let detail: String
    let blocksCommands: Bool
    let reconnectManagement: Bool

    init?(error: Error, operation: String, profile: DeviceProfile) {
        guard !(error is CancellationError) else { return nil }
        detail = "\(operation): \(error.localizedDescription)"
        switch error {
        case DeviceError.instproxy(.opInProgress, _):
            summary = "Updating apps…"
            blocksCommands = false
            reconnectManagement = false
        case DeviceError.unavailable:
            summary = "App connection unavailable"
            blocksCommands = true
            reconnectManagement = false
        case DeviceError.lockdown(-17), DeviceError.lockdown(-35):
            summary = "Unlock the \(profile.shortName) to connect"
            blocksCommands = true
            reconnectManagement = false
        case DeviceError.lockdown(-4), DeviceError.lockdown(-18), DeviceError.lockdown(-19),
             DeviceError.lockdown(-20), DeviceError.lockdown(-21), DeviceError.lockdown(-29),
             DeviceError.lockdown(-30), DeviceError.lockdown(-31):
            summary = "Couldn’t pair with the \(profile.shortName)"
            blocksCommands = true
            reconnectManagement = false
        case DeviceError.lockdown(-26), DeviceError.lockdown(-27):
            summary = "Waiting for app services…"
            blocksCommands = true
            reconnectManagement = false
        case DeviceError.lockdown(-32), DeviceError.lockdown(-33):
            summary = "\(profile.shortName) activation unavailable"
            blocksCommands = true
            reconnectManagement = false
        case DeviceError.notAttached:
            summary = "USB connection lost — retrying…"
            blocksCommands = true
            reconnectManagement = false
        case DeviceError.timedOut(let operation) where operation == "USB connection":
            summary = "USB connection delayed — retrying…"
            blocksCommands = true
            reconnectManagement = false
        case DeviceError.lockdown, DeviceError.recovering, DeviceError.timedOut,
             DeviceError.instproxy(.connFailed, _), DeviceError.instproxy(.receiveTimeout, _):
            summary = "App connection interrupted — retrying…"
            blocksCommands = true
            reconnectManagement = true
        default:
            summary = "Couldn’t update apps — retrying…"
            blocksCommands = true
            reconnectManagement = false
        }
    }
}
