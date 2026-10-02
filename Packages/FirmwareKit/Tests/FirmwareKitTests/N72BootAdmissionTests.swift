import Foundation
import HostRuntime
import Testing
@testable import FirmwareKit

struct N72BootAdmissionTests {
    @Test func unqualifiedBuildKeepsGenerationAndRawInputsRequireOptIn() async throws {
        let f = try N72NORMigrationTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let admitted = try await N72BootAdmission.admit(device: f.device)
        #expect(admitted.changed == false)
        #expect(admitted.record == f.record)
        #expect(admitted.paths?.base == f.device.appendingPathComponent("base"))
        #expect(try Data(contentsOf: f.device.appendingPathComponent("nor.bin")) == f.writable)
        let output = try #require(JSONSerialization.jsonObject(with: admitted.jsonData()) as? [String: Any])
        #expect(output["event"] as? String == "admitted")
        #expect(output["changed"] as? Bool == false)
        #expect(output["record"] is [String: Any])
        #expect((output["paths"] as? [String: String])?["base"] == admitted.paths?.base.path)
        let raw = f.root.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await N72BootAdmission.admit(device: raw) }
        let rawAdmission = try await N72BootAdmission.admit(device: raw, allowRaw: true)
        #expect(rawAdmission.changed == false)
        #expect(rawAdmission.record == nil)
        #expect(rawAdmission.paths == nil)
    }

    @Test func qualifiedMigrationKeepsLeaseThroughPublishedPathRefresh() async throws {
        let f = try N72NORMigrationTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let admitted = try await N72BootAdmission.admit(device: f.device, qualifiedBuilds: ["5F138"], afterMigration: {
            #expect(throws: StorageLease.Failure.inUse) { _ = try StorageLease(f.device.appendingPathComponent("work/lease")) }
        })
        #expect(admitted.changed)
        #expect(admitted.paths?.base != f.device.appendingPathComponent("base"))
        #expect(admitted.record == (try Data(contentsOf: f.device.appendingPathComponent("device.json"))))
        let owner = try StoppedRecordOwner(device: f.device)
        #expect(owner.paths?.base == admitted.paths?.base)
        #expect(try Data(contentsOf: #require(admitted.paths?.base).appendingPathComponent("nand/cs0/1.page")) == Data("durable base NAND".utf8))
    }

    @Test func liveAndPendingStorageRefuseAdmissionBeforeRecordReads() async throws {
        let f = try N72NORMigrationTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try StorageLease(f.device.appendingPathComponent("work/lease"))
        await #expect(throws: (any Error).self) { try await N72BootAdmission.admit(device: f.device, qualifiedBuilds: ["5F138"]) }
        lease.close()
        try Data("unfinished".utf8).write(to: f.device.appendingPathComponent("work/edit.json"))
        await #expect(throws: (any Error).self) { try await N72BootAdmission.admit(device: f.device, allowRaw: true) }
        #expect(try Data(contentsOf: f.device.appendingPathComponent("device.json")) == f.record)
    }

    @Test func cancelledAdmissionDoesNotPublishOrStrandIntent() async throws {
        let f = try N72NORMigrationTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await N72BootAdmission.admit(device: f.device, qualifiedBuilds: ["5F138"])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: f.device.appendingPathComponent("device.json")) == f.record)
        #expect(FileManager.default.fileExists(atPath: f.device.appendingPathComponent("work/edit.json").path) == false)
    }
}
