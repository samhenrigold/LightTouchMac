import Darwin
import Foundation
import os

/// Owns the stopped/live device exclusion descriptor, never the lease pathname.
/// Keep the inode in place: unlinking it permits another owner to lock a new file.
public nonisolated final class StorageLease: Sendable {
    public enum Failure: Error, Equatable {
        case openFailed(Int32)
        case inUse
        case pendingEdit
    }
    private let descriptor: OSAllocatedUnfairLock<Int32?>

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
            descriptor = OSAllocatedUnfairLock(initialState: fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }
    public var isClosed: Bool { descriptor.withLock { $0 == nil } }

    /// End an explicitly shared ownership scope after all operations finish.
    /// Retained aliases are then closed owners; the inode remains in place.
    public func close() {
        descriptor.withLock { descriptor in
            guard let fd = descriptor else { return }
            descriptor = nil
            // Closing only this reference can leave a transient inherited
            // pre-exec alias holding flock despite FD_CLOEXEC. End the scope.
            flock(fd, LOCK_UN)
            Darwin.close(fd)
        }
    }
    deinit { close() }
}
