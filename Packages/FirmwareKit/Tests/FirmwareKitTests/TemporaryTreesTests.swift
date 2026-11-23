import Darwin
import Foundation
import Testing

/// A test's temporary tree goes whatever a published generation left in it: a locked (uchg), read-only base and a
/// locked file in it (TemporaryTrees), where FileManager.removeItem gave up and the tree outlived the run.
struct TemporaryTreesTests {
    /// A tree shaped as a published generation leaves it: a locked file in a locked, read-only directory, beside a
    /// link out of the tree that must not be followed.
    func lockedTree(_ outside: URL) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fk-trees-\(UUID().uuidString)")
        let base = root.appendingPathComponent("generations/one/base")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let lock = base.appendingPathComponent("device.lock.json")
        try Data("{}".utf8).write(to: lock)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("out"), withDestinationURL: outside)
        #expect(chflags(lock.path, UInt32(UF_IMMUTABLE)) == 0)
        #expect(chmod(base.path, 0o500) == 0)
        #expect(chflags(base.path, UInt32(UF_IMMUTABLE)) == 0)
        return root
    }

    @Test func aLockedReadOnlyTreeIsRemoved() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("fk-trees-out-\(UUID().uuidString)")
        try Data("kept".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        #expect(chmod(outside.path, 0o400) == 0)

        let plain = try lockedTree(outside)
        #expect(throws: (any Error).self) { try FileManager.default.removeItem(at: plain) }
        TemporaryTrees.remove(plain)
        #expect(!FileManager.default.fileExists(atPath: plain.path))

        // The link was unlocked and removed itself: its target keeps its mode.
        var info = stat()
        #expect(stat(outside.path, &info) == 0 && info.st_mode & 0o777 == 0o400)
    }
}
