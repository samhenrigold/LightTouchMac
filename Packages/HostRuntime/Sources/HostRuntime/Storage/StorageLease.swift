import Darwin
import Foundation

/// Owns the stopped/live device exclusion descriptor, never the lease pathname.
/// Keep the inode in place: unlinking it permits another owner to lock a new file.
public nonisolated final class StorageLease {
    public enum Failure: Error, Equatable {
        case openFailed(Int32)
        case inUse
        case pendingEdit
    }
    private let descriptor: Int32

    /// Resume callers may allow a pending edit only while validating their exact
    /// durable session under this same lease; ordinary boot/export/maintenance deny it.
    public init(_ path: URL, allowPendingEdit: Bool = false) throws {
        let directory = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = open(path.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.openFailed(errno) }
        do {
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.inUse }
            // Inspect durable intent after exclusion, so a previous editor's exit
            // cannot admit boot/export while its unfinished transaction remains.
            if !allowPendingEdit && FileManager.default.fileExists(atPath: directory.appendingPathComponent("edit.json").path) {
                throw Failure.pendingEdit
            }
            descriptor = fd
        } catch {
            close(fd)
            throw error
        }
    }
    deinit { close(descriptor) }
}
