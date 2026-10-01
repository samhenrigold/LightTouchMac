import Darwin
import Foundation
import Testing
import HostRuntime

struct StorageLeaseTests {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func sameInodeExcludesUntilOwnerRelease() throws {
        try fixture { root in
            let path = root.appendingPathComponent("explicit-external/work/lease")
            var inode: NSNumber?
            do {
                let owner = try StorageLease(path)
                inode = try FileManager.default.attributesOfItem(atPath: path.path)[.systemFileNumber] as? NSNumber
                #expect(throws: StorageLease.Failure.inUse) { _ = try StorageLease(path) }
                let descriptors = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap(Int32.init)
                let matching = descriptors.filter { fd in
                    var attributes = stat()
                    return fstat(fd, &attributes) == 0 && attributes.st_ino == inode?.uint64Value
                }
                #expect(matching.count == 1)
                #expect(matching.allSatisfy { fcntl($0, F_GETFD) & FD_CLOEXEC != 0 })
                let fd = open(path.path, O_RDWR | O_NOFOLLOW)
                #expect(fd >= 0)
                defer { close(fd) }
                #expect(flock(fd, LOCK_EX | LOCK_NB) != 0)
                withExtendedLifetime(owner) {}
            }
            let owner = try StorageLease(path)
            #expect(try FileManager.default.attributesOfItem(atPath: path.path)[.systemFileNumber] as? NSNumber == inode)
            withExtendedLifetime(owner) {}
        }
    }

    @Test func pendingIntentCheckedAfterExclusionAndResumeKeepsIntent() throws {
        try fixture { root in
            let path = root.appendingPathComponent("work/lease")
            let intent = path.deletingLastPathComponent().appendingPathComponent("edit.json")
            let bytes = Data("durable-intent".utf8)
            do {
                let owner = try StorageLease(path)
                try bytes.write(to: intent)
                // A competing owner cannot inspect/permit intent before exclusion.
                #expect(throws: StorageLease.Failure.inUse) { _ = try StorageLease(path) }
                withExtendedLifetime(owner) {}
            }
            #expect(throws: StorageLease.Failure.pendingEdit) { _ = try StorageLease(path) }
            do {
                let resumed = try StorageLease(path, allowPendingEdit: true)
                #expect(try Data(contentsOf: intent) == bytes)
                #expect(throws: StorageLease.Failure.inUse) { _ = try StorageLease(path, allowPendingEdit: true) }
                withExtendedLifetime(resumed) {}
            }
            try FileManager.default.removeItem(at: intent)
            let owner = try StorageLease(path)
            withExtendedLifetime(owner) {}
        }
    }

    @Test func symlinkLeafCannotMutateOrLockTarget() throws {
        try fixture { root in
            let target = root.appendingPathComponent("target")
            let bytes = Data("unchanged".utf8)
            try bytes.write(to: target)
            let path = root.appendingPathComponent("lease")
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
            #expect(throws: StorageLease.Failure.openFailed(ELOOP)) { _ = try StorageLease(path) }
            #expect(try Data(contentsOf: target) == bytes)
            let independent = open(target.path, O_RDWR)
            #expect(independent >= 0)
            defer { close(independent) }
            #expect(flock(independent, LOCK_EX | LOCK_NB) == 0)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path.path) == target.path)
        }
    }
}
