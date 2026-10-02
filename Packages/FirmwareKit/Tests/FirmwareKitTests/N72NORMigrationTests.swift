import Foundation
import Testing
@testable import FirmwareKit

struct N72NORMigrationTests {
    private enum Stop: Error { case injected }
    func fixture() throws -> (root: URL, device: URL, record: Data, writable: Data) {
        let root = try Fixtures.tempDir("nor-migration")
        let device = root.appendingPathComponent("device"), base = device.appendingPathComponent("base")
        let fm = FileManager.default
        try fm.createDirectory(at: base.appendingPathComponent("nand/cs0"), withIntermediateDirectories: true)
        try Data("durable base NAND".utf8).write(to: base.appendingPathComponent("nand/cs0/1.page"))
        let original = try N72NORFormatTests().fixture().base
        try original.write(to: base.appendingPathComponent("nor.bin"))
        let lock: [String: Any] = ["build": "5F138", "derived": ["wrap_shsh_types": ["ibot"], "nor_images": ["illb", "ibot", "dtre"]],
                                  "outputs": ["nor": ["path": "nor.bin", "sha256": StorageGeneration.hash(original)]]]
        try JSONSerialization.data(withJSONObject: lock).write(to: base.appendingPathComponent("device.lock.json"))
        let overlay = device.appendingPathComponent("overlay")
        try fm.createDirectory(at: overlay, withIntermediateDirectories: true)
        try Data("durable overlay NAND".utf8).write(to: overlay.appendingPathComponent("2.page"))
        try Data("old".utf8).write(to: overlay.appendingPathComponent(".base-identity"))
        let nor = device.appendingPathComponent("nor.bin")
        var writable = original; writable[0xfc100] ^= 0x66; writable[0x2000] ^= 0x55
        try writable.write(to: nor)
        let snapshot = device.appendingPathComponent("snapshot")
        try Data("old guest CPU state".utf8).write(to: snapshot)
        let record: [String: Any] = ["id": UUID().uuidString, "board": "n72ap", "firmware": "n72ap-5F138",
            "base": ["kind": "prepared", "path": base.path],
            "storage": ["key": "old", "overlay": overlay.path, "snapshot": snapshot.path, "writableNOR": nor.path]]
        let bytes = try JSONSerialization.data(withJSONObject: record)
        try bytes.write(to: device.appendingPathComponent("device.json"))
        return (root, device, bytes, writable)
    }

    @Test func publicationPreservesStorageAndInvalidatesOldCPUState() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(try await N72NORMigration.migrate(device: f.device))
        #expect(try await N72NORMigration.migrate(device: f.device) == false)
        let owner = try OwnedStorageRecord.acquire(device: f.device)
        let paths = try #require(owner.paths)
        #expect(try Data(contentsOf: paths.base.appendingPathComponent("nand/cs0/1.page")) == Data("durable base NAND".utf8))
        #expect(try Data(contentsOf: paths.overlay.appendingPathComponent("2.page")) == Data("durable overlay NAND".utf8))
        let workingNOR = try #require(paths.writableNOR)
        let nor = try Data(contentsOf: workingNOR)
        #expect(nor[0xfc100] == f.writable[0xfc100])
        #expect(nor[0x2000] == f.writable[0x2000])
        let snapshot = try #require(paths.snapshot)
        #expect(FileManager.default.fileExists(atPath: snapshot.path) == false)
        #expect(try Data(contentsOf: f.device.appendingPathComponent("snapshot")) == Data("old guest CPU state".utf8))
        #expect(try Data(contentsOf: f.device.appendingPathComponent("nor.bin")) == f.writable)
    }

    @Test(arguments: [N72NORMigration.Checkpoint.planned, .staged, .ready, .published])
    func failuresRetainOrRecoverExactGeneration(_ stop: N72NORMigration.Checkpoint) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            _ = try await N72NORMigration.migrate(device: f.device) { point in
                if point == stop { throw Stop.injected }
            }
            Issue.record("Expected injected failure")
        } catch Stop.injected {}
        let record = try Data(contentsOf: f.device.appendingPathComponent("device.json"))
        #expect(try Data(contentsOf: f.device.appendingPathComponent("nor.bin")) == f.writable)
        let intentURL = f.device.appendingPathComponent("work/edit.json")
        switch stop {
        case .planned, .staged:
            #expect(record == f.record)
            #expect(FileManager.default.fileExists(atPath: intentURL.path) == false)
        case .ready, .published:
            let intent = try JSONDecoder().decode(StorageGeneration.Intent.self, from: Data(contentsOf: intentURL))
            let edit = try StorageGeneration.resume(device: f.device, id: intent.id)
            try await StorageGeneration.withOwner(edit) { edit in try await edit.recoverPublication() }
            #expect(FileManager.default.fileExists(atPath: intentURL.path) == false)
            #expect(try await N72NORMigration.migrate(device: f.device) == false)
        }
    }

    @Test(arguments: [false, true]) func cancellationRetainsOriginal(_ afterStaging: Bool) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let task = Task {
            if afterStaging == false { withUnsafeCurrentTask { $0?.cancel() } }
            return try await N72NORMigration.migrate(device: f.device) { point in
                if afterStaging && point == .staged { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError {}
        #expect(try Data(contentsOf: f.device.appendingPathComponent("device.json")) == f.record)
        #expect(FileManager.default.fileExists(atPath: f.device.appendingPathComponent("work/edit.json").path) == false)
    }
}
