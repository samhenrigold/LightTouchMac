import Darwin
import Foundation
import HostRuntime

/// Firmware error adapter over the shared descriptor-owning device lease.
struct StoppedStorageLease {
    private let lease: StorageLease

    init(_ path: URL, allowPendingEdit: Bool = false) throws {
        do { lease = try StorageLease(path, allowPendingEdit: allowPendingEdit) }
        catch let error as StorageLease.Failure {
            switch error {
            case .openFailed(let code):
                throw FirmwareError(.internal, "storage lease \(path.path): \(String(cString: strerror(code)))")
            case .inUse:
                throw FirmwareError(.internal, "device storage is in use; stop the guest before exporting or editing")
            case .pendingEdit:
                throw FirmwareError(.internal, "device has an unfinished edit session; resolve it before exporting")
            }
        }
    }
}
