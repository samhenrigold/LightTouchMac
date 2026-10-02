import Foundation
import Testing
import HostRuntime

struct StorageBootProofTests {
    @Test func helperLeaseRechecksGenerationWithoutRejectingGuestMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let record = root.appendingPathComponent("device.json")
        var data: [String: Any] = ["base": ["kind": "prepared", "path": "base/old"],
                                 "storage": ["key": "old", "overlay": "overlay/old"],
                                 "identity": ["die_id": "original"], "guest": ["active": 1]]
        func write() throws { try JSONSerialization.data(withJSONObject: data).write(to: record) }
        try write()
        let proof = try StorageBootProof.capture(record: record)
        let lease = try StorageLease(root.appendingPathComponent("work/lease"))
        try proof.verify(record: record, lease: lease)
        data["guest"] = ["active": 2]
        try write()
        try proof.verify(record: record, lease: lease)
        // Changing paths while accidentally reusing the key must also refuse.
        data["base"] = ["kind": "prepared", "path": "base/new"]
        try write()
        #expect(throws: StorageBootProof.Failure.changedGeneration) { try proof.verify(record: record, lease: lease) }
        data["base"] = ["kind": "prepared", "path": "base/old"]
        data["identity"] = ["die_id": "changed"]
        try write()
        #expect(throws: StorageBootProof.Failure.changedGeneration) { try proof.verify(record: record, lease: lease) }
        data["identity"] = ["die_id": "original"]
        data["storage"] = ["key": "new", "overlay": "overlay/old"]
        try write()
        #expect(throws: StorageBootProof.Failure.changedGeneration) { try proof.verify(record: record, lease: lease) }
        lease.close()
        #expect(throws: StorageBootProof.Failure.missingLease) { try proof.verify(record: record, lease: lease) }
    }
}
