import Darwin
import Foundation

/// A stable root inode coordinates producers, consumers, and pruning across
/// GUI jobs and command-line preparations. The lease file is never removed.
public enum FirmwareCache {
    public final class Lease {
        private let descriptor: Int32
        fileprivate init(root: URL, exclusive: Bool) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fd = open(root.appendingPathComponent(".lease").path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let flags = exclusive ? LOCK_EX | LOCK_NB : LOCK_SH
            while flock(fd, flags) != 0 {
                if errno == EINTR { continue }
                close(fd)
                throw FirmwareError(.internal, "firmware cache is in use; retry cleanup when preparations finish")
            }
            descriptor = fd
        }
        deinit { close(descriptor) }
    }
    public static func consume(root: URL) throws -> Lease { try Lease(root: root, exclusive: false) }
    /// Remove only cache contents under the exclusive lease, retaining its
    /// directory/inode so another process cannot acquire a replacement lock.
    public static func prune(root: URL, ipsw: String? = nil) throws {
        let lease = try Lease(root: root, exclusive: true)
        defer { withExtendedLifetime(lease) {} }
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: root.path)
        if let ipsw {
            guard ipsw.count == 40, ipsw.allSatisfy({ $0.isHexDigit }) else { throw FirmwareError(.internal, "invalid cache IPSW digest") }
            for name in names where name == ipsw || name == ipsw + ".tmp" {
                try fm.removeItem(at: root.appendingPathComponent(name))
            }
            for name in names where name.hasPrefix("decrypted-v") {
                let directory = root.appendingPathComponent(name)
                let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard values.isSymbolicLink != true, values.isDirectory == true else { continue }
                let candidate = directory.appendingPathComponent(ipsw)
                if fm.fileExists(atPath: candidate.path) { try fm.removeItem(at: candidate) }
            }
        } else {
            for name in names where name != ".lease" { try fm.removeItem(at: root.appendingPathComponent(name)) }
        }
    }
}
