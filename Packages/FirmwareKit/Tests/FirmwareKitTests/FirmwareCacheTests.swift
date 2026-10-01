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
        var before = stat(), after = stat()
        #expect(lstat(root.appendingPathComponent(".lease").path, &before) == 0)
        try FirmwareCache.prune(root: root)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(lstat(root.appendingPathComponent(".lease").path, &after) == 0)
        #expect(before.st_ino == after.st_ino)
    }
}
