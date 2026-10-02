import Foundation
import HostRuntime
import Testing
@testable import FirmwareKit

struct FirmwareBootAdmissionTests {
    private func fixture() throws -> (root: URL, device: URL, record: Data) {
        let root = try Fixtures.tempDir("boot-admission")
        let device = root.appendingPathComponent("device"), base = device.appendingPathComponent("base")
        let overlay = device.appendingPathComponent("overlay")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
        try Data("flash unchanged".utf8).write(to: base.appendingPathComponent("page"))
        try Data("NOR unchanged".utf8).write(to: device.appendingPathComponent("nor.bin"))
        let record: [String: Any] = ["id": UUID().uuidString, "board": "n72ap", "firmware": "unqualified",
            "base": ["kind": "prepared", "path": base.path],
            "storage": ["key": "current", "overlay": overlay.path,
                        "writableNOR": device.appendingPathComponent("nor.bin").path]]
        let bytes = try JSONSerialization.data(withJSONObject: record)
        try bytes.write(to: device.appendingPathComponent("device.json"))
        return (root, device, bytes)
    }

    @Test func admissionDoesNotInspectOrConvertFirmwareAndRawRequiresOptIn() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let result = try await FirmwareBootAdmission.admit(device: f.device)
        #expect(!result.changed)
        #expect(result.record == f.record)
        #expect(result.paths?.base == f.device.appendingPathComponent("base"))
        #expect(try Data(contentsOf: f.device.appendingPathComponent("nor.bin")) == Data("NOR unchanged".utf8))
        let json = try #require(JSONSerialization.jsonObject(with: result.jsonData()) as? [String: Any])
        #expect(json["event"] as? String == "admitted")
        #expect(json["changed"] as? Bool == false)
        let raw = f.root.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await FirmwareBootAdmission.admit(device: raw) }
        let rawResult = try await FirmwareBootAdmission.admit(device: raw, allowRaw: true)
        #expect(!rawResult.changed && rawResult.record == nil && rawResult.paths == nil)
    }

    @Test func preparationBorrowsAuthorityThroughPublicationAndRefreshedPaths() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let result = try await FirmwareBootAdmission.admit(device: f.device, prepare: { owner in
            let transaction = try StorageGeneration.begin(owner: owner)
            return try await StorageGeneration.withOwner(transaction, retaining: owner) { edit in
                try FileManager.default.createDirectory(at: edit.base, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: edit.overlay, withIntermediateDirectories: true)
                try Data("flash prepared".utf8).write(to: edit.base.appendingPathComponent("page"))
                try Data("NOR prepared".utf8).write(to: edit.root.appendingPathComponent("nor.bin"))
                let candidate = try await edit.candidateRecord()
                try await edit.publish(record: candidate)
                #expect(throws: StorageLease.Failure.inUse) { _ = try StorageLease(owner.device.appendingPathComponent("work/lease")) }
                return true
            }
        })
        #expect(result.changed)
        #expect(result.paths?.base != f.device.appendingPathComponent("base"))
        #expect(result.record == (try Data(contentsOf: f.device.appendingPathComponent("device.json"))))
        let next = try StoppedRecordOwner(device: f.device)
        #expect(next.paths?.base == result.paths?.base)
    }

    @Test func liveAndPendingStorageRefuseAdmission() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try StorageLease(f.device.appendingPathComponent("work/lease"))
        await #expect(throws: (any Error).self) { try await FirmwareBootAdmission.admit(device: f.device) }
        lease.close()
        try Data("unfinished".utf8).write(to: f.device.appendingPathComponent("work/edit.json"))
        await #expect(throws: (any Error).self) { try await FirmwareBootAdmission.admit(device: f.device, allowRaw: true) }
        #expect(try Data(contentsOf: f.device.appendingPathComponent("device.json")) == f.record)
    }

    @Test func cancellationLeavesRecordAndIntentUntouched() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FirmwareBootAdmission.admit(device: f.device)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: f.device.appendingPathComponent("device.json")) == f.record)
        #expect(!FileManager.default.fileExists(atPath: f.device.appendingPathComponent("work/edit.json").path))
    }
}
