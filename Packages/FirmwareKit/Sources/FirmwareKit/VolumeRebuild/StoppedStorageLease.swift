import Darwin
import Foundation

/// Shares the VM helper's work/lease inode. The descriptor, never the pathname,
/// owns the lock; removing the lease file would let another writer bypass it.
final class StoppedStorageLease {
    private let descriptor: Int32

    init(_ path: URL, allowPendingEdit: Bool = false) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(path.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw FirmwareError(.internal, "storage lease \(path.path): \(String(cString: strerror(errno)))")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw FirmwareError(.internal, "device storage is in use; stop the guest before exporting or editing")
        }
        if !allowPendingEdit && FileManager.default.fileExists(atPath: path.deletingLastPathComponent().appendingPathComponent("edit.json").path) {
            close(fd)
            throw FirmwareError(.internal, "device has an unfinished edit session; resolve it before exporting")
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}
