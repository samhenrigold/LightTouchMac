import Darwin
import Foundation
import Testing
@testable import FirmwareKit

struct StoppedStorageTests {
    @Test func runningHelperRefusesExportBeforeCreatingOutput() async throws {
        let dir = try Fixtures.tempDir("storage-lease")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("work/lease")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Exactly the flags used by LightTouchDevice, on an independent descriptor.
        let fd = open(path.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let out = dir.appendingPathComponent("export")
        await #expect(throws: FirmwareError.self) {
            try await VolumeExport.export(.init(device: dir), out: out)
        }
        #expect(FileManager.default.fileExists(atPath: out.path) == false)
    }

    @Test func releasedLeaseIsReusableAndPendingEditRefusesAccess() throws {
        let dir = try Fixtures.tempDir("storage-edit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("work/lease")
        do {
            let lease = try OwnedStorageRecord.acquire(device: dir, allowRaw: true)
            #expect(throws: FirmwareError.self) { try OwnedStorageRecord.acquire(device: dir, allowRaw: true) }
            withExtendedLifetime(lease) {}
        }
        do { let lease = try OwnedStorageRecord.acquire(device: dir, allowRaw: true); withExtendedLifetime(lease) {} }
        try Data("{}".utf8).write(to: dir.appendingPathComponent("work/edit.json"))
        #expect(throws: FirmwareError.self) { try OwnedStorageRecord.acquire(device: dir, allowRaw: true) }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("work/edit.json"))
        let lease = try OwnedStorageRecord.acquire(device: dir, allowRaw: true)
        withExtendedLifetime(lease) {}
    }

    @Test func failedRebuildRemovesOnlyOwnedOutput() async throws {
        let dir = try Fixtures.tempDir("storage-export-failure")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("export")
        let source = VolumeExport.Source(base: dir.appendingPathComponent("missing"), overlay: nil)
        await #expect(throws: (any Error).self) { try await VolumeExport.export(source, out: out) }
        #expect(FileManager.default.fileExists(atPath: out.path) == false)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        let marker = out.appendingPathComponent("important")
        try Data("retain".utf8).write(to: marker)
        await #expect(throws: FirmwareError.self) { try await VolumeExport.export(source, out: out) }
        #expect(try Data(contentsOf: marker) == Data("retain".utf8))
    }

    @Test func exportCannotStageInsideItsSource() async throws {
        let dir = try Fixtures.tempDir("storage-source")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("export")
        await #expect(throws: FirmwareError.self) {
            try await VolumeExport.export(.init(base: dir, overlay: nil), out: out)
        }
        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(FileManager.default.fileExists(atPath: out.path) == false)
    }

    @Test func malformedOrForeignManifestNeverDeletesDirectory() async throws {
        let dir = try Fixtures.tempDir("storage-manifest")
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: (any Error).self) { try await VolumeExport.unmount(out: dir) }
        #expect(FileManager.default.fileExists(atPath: dir.path))
        try Data("not json".utf8).write(to: VolumeExport.manifest(dir))
        await #expect(throws: (any Error).self) { try await VolumeExport.unmount(out: dir) }
        #expect(FileManager.default.fileExists(atPath: dir.path))
        let foreign = VolumeExport.Exported(volume: "system", image: "/tmp/another-device.img", clean: true,
            repaired: false, device: "/dev/disk1", mountPoint: nil, seconds: 0)
        try VolumeExport.write([foreign], dir)
        await #expect(throws: FirmwareError.self) { try await VolumeExport.unmount(out: dir) }
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }
}
