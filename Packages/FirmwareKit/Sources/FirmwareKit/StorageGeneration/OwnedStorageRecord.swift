import Darwin
import Foundation
import HostRuntime

/// Firmware-facing diagnostics over the shared lock-before-read admission.
enum OwnedStorageRecord {
    static func acquire(device: URL, policy: StorageRecordPolicy = .standalone,
                        resume: Bool = false, allowRaw: Bool = false) throws -> StoppedRecordOwner {
        do { return try StoppedRecordOwner(device: device, policy: policy, allowPendingEdit: resume, allowRaw: allowRaw) }
        catch let error as StorageLease.Failure {
            switch error {
            case .openFailed(let code): throw FirmwareError(.internal, "storage lease \(device.appendingPathComponent("work/lease").path): \(String(cString: strerror(code)))")
            case .inUse: throw FirmwareError(.internal, "device storage is in use; stop the guest before exporting or editing")
            case .pendingEdit: throw FirmwareError(.internal, "device has an unfinished edit session; resolve it before exporting")
            }
        } catch StorageRecordPaths.Failure.invalidRecord {
            throw FirmwareError(.unsupported, "storage transactions require a valid device record")
        } catch StoragePathAuthority.Failure.invalidPath(let url) {
            throw FirmwareError(.internal, "\(url.path) is not this device's writable storage")
        }
    }
}

/// Public admission policy shared by record-facing firmware maintenance APIs.
public typealias VolumeRecordPolicy = StorageRecordPolicy
