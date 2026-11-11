import Darwin
import Foundation
import Testing

@testable import FirmwareKit

struct FirmwareCacheTests {
    @Test func pruningCannotDeleteActiveReadersOrReplaceLockInode() throws {
        let root = try Fixtures.tempDir("cache-lease")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("result")
        try Data("cached".utf8).write(to: file)
        func reader() throws {
            let lease = try FirmwareCache.consume(root: root)
            defer { withExtendedLifetime(lease) {} }
            #expect(throws: FirmwareError.self) { try FirmwareCache.prune(root: root) }
            #expect(try Data(contentsOf: file) == Data("cached".utf8))
        }
        try reader()
        var before = stat()
        var after = stat()
        #expect(lstat(root.appendingPathComponent(".lease").path, &before) == 0)
        try FirmwareCache.prune(root: root)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(lstat(root.appendingPathComponent(".lease").path, &after) == 0)
        #expect(before.st_ino == after.st_ino)
    }

    /// The app prunes one IPSW's results once its device is prepared: the other IPSWs' stay.
    @Test func pruningOneIPSWKeepsTheOthers() throws {
        let root = try Fixtures.tempDir("cache-ipsw")
        defer { try? FileManager.default.removeItem(at: root) }
        let pruned = String(repeating: "a", count: 40)
        let kept = String(repeating: "b", count: 40)
        func result(_ sha1: String) throws -> URL {
            let directory = root.appendingPathComponent("decrypted-v\(DecryptionCache.format)/\(sha1)/key")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("rootfs".utf8).write(to: directory.appendingPathComponent("rootfs.dmg"))
            return directory
        }
        let gone = try result(pruned)
        let stays = try result(kept)
        try FirmwareCache.prune(root: root, ipsw: pruned)
        #expect(!FileManager.default.fileExists(atPath: gone.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: stays.appendingPathComponent("rootfs.dmg").path))
    }
}
