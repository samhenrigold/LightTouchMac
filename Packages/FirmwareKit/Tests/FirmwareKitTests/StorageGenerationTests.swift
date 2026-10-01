import Foundation
import Testing
@testable import FirmwareKit

struct StorageGenerationTests {
    enum Interrupted: Error { case crash }
    private func fixture() throws -> URL {
        let device = try Fixtures.tempDir("storage-generation")
        let record: [String: Any] = ["id": UUID().uuidString, "board": "n72ap", "firmware": "7E18",
            "identity": ["udid": "keep-this-identity"], "unknown": ["preserved": true],
            "base": ["path": "original", "kind": "prepared"],
            "storage": ["key": "original", "overlay": "overlay", "snapshot": "old-snapshot",
                        "writableNOR": "nor.bin", "usbmuxConf": "conf"]]
        try JSONSerialization.data(withJSONObject: record).write(to: device.appendingPathComponent("device.json"))
        return device
    }
    private func candidate(_ edit: StorageGeneration) async throws -> Data {
        let fm = FileManager.default
        for path in [edit.base, edit.overlay] { try fm.createDirectory(at: path, withIntermediateDirectories: true) }
        try Data("complete-flash".utf8).write(to: edit.base.appendingPathComponent("page"))
        try Data("complete-nor".utf8).write(to: edit.root.appendingPathComponent("nor.bin"))
        return try await edit.candidateRecord()
    }

    @Test func intentAndLeaseBlockAnotherOwnerUntilDiscard() async throws {
        let device = try fixture()
        defer { try? FileManager.default.removeItem(at: device) }
        func stoppedOwner() async throws -> UUID {
            let edit = try StorageGeneration.begin(device: device)
            #expect(throws: FirmwareError.self) { try StorageGeneration.begin(device: device) }
            #expect(throws: FirmwareError.self) { try OwnedStorageRecord.acquire(device: device) }
            try await edit.close()
            return edit.id
        }
        let id = try await stoppedOwner() // Owner exits; intent must continue excluding boot.
        #expect(throws: FirmwareError.self) { try OwnedStorageRecord.acquire(device: device) }
        let resumed = try StorageGeneration.resume(device: device, id: id)
        try await resumed.discard()
        try await resumed.close()
        #expect(!FileManager.default.fileExists(atPath: device.appendingPathComponent("work/edit.json").path))
        #expect(try String(contentsOf: device.appendingPathComponent("device.json"), encoding: .utf8).contains("original"))
    }

    @Test(arguments: [StorageGeneration.Checkpoint.ready, .recordPublished])
    func recoveryAfterOwnerExit(at interruption: StorageGeneration.Checkpoint) async throws {
        let device = try fixture()
        defer { try? FileManager.default.removeItem(at: device) }
        let id: UUID
        let expected: Data
        do {
            let edit = try StorageGeneration.begin(device: device)
            id = edit.id; expected = try await candidate(edit)
            await #expect(throws: Interrupted.crash) {
                try await edit.publish(record: expected) { if $0 == interruption { throw Interrupted.crash } }
            }
            let current = try Data(contentsOf: device.appendingPathComponent("device.json"))
            #expect((StorageGeneration.hash(current) == StorageGeneration.hash(expected)) == (interruption == .recordPublished))
            try await edit.close()
        }
        do {
            let recovery = try StorageGeneration.resume(device: device, id: id)
            try await recovery.recoverPublication()
            try await recovery.close()
        }
        #expect(try Data(contentsOf: device.appendingPathComponent("device.json")) == expected)
        #expect(!FileManager.default.fileExists(atPath: device.appendingPathComponent("work/edit.json").path))
        let lease = try OwnedStorageRecord.acquire(device: device)
        withExtendedLifetime(lease) {}
        let json = try #require(try JSONSerialization.jsonObject(with: expected) as? [String: Any])
        #expect(((json["base"] as? [String: String])?["path"]?.hasPrefix("/") == false))
        #expect((json["unknown"] as? [String: Bool])?["preserved"] == true)
        #expect((json["storage"] as? [String: String])?["snapshot"]?.contains(id.uuidString) == true)
    }

    @Test func changedRecordOrIdentityCannotBePublished() async throws {
        let device = try fixture()
        defer { try? FileManager.default.removeItem(at: device) }
        let edit = try StorageGeneration.begin(device: device)
        let data = try await candidate(edit)
        var record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        record["identity"] = ["udid": "another-device"]
        await #expect(throws: FirmwareError.self) { try await edit.publish(record: JSONSerialization.data(withJSONObject: record)) }
        try Data("changed".utf8).write(to: device.appendingPathComponent("device.json"))
        await #expect(throws: FirmwareError.self) { try await edit.publish(record: data) }
        await #expect(throws: FirmwareError.self) { try await edit.discard() }
    }
    @Test func damagedReadyGenerationCannotReplaceOriginal() async throws {
        let device = try fixture()
        defer { try? FileManager.default.removeItem(at: device) }
        let id: UUID
        do {
            let edit = try StorageGeneration.begin(device: device)
            id = edit.id
            let record = try await candidate(edit)
            await #expect(throws: Interrupted.crash) {
                try await edit.publish(record: record) { if $0 == .ready { throw Interrupted.crash } }
            }
            try Data("damaged".utf8).write(to: edit.base.appendingPathComponent("page"))
            try await edit.close()
        }
        let resumed = try StorageGeneration.resume(device: device, id: id)
        await #expect(throws: FirmwareError.self) { try await resumed.recoverPublication() }
        #expect(try String(contentsOf: device.appendingPathComponent("device.json"), encoding: .utf8).contains("original"))
        try await resumed.discard()
        try await resumed.close()
    }

    @Test func wrongResumeCannotBypassPendingIntent() async throws {
        let device = try fixture()
        defer { try? FileManager.default.removeItem(at: device) }
        let original = try Data(contentsOf: device.appendingPathComponent("device.json"))
        func start() async throws -> UUID {
            let edit = try StorageGeneration.begin(device: device)
            try await edit.close(); return edit.id
        }
        let id = try await start()
        #expect(throws: FirmwareError.self) { _ = try StorageGeneration.resume(device: device, id: UUID()) }
        #expect(throws: FirmwareError.self) { _ = try OwnedStorageRecord.acquire(device: device) }
        #expect(try Data(contentsOf: device.appendingPathComponent("device.json")) == original)
        let resumed = try StorageGeneration.resume(device: device, id: id)
        try await resumed.discard()
        try await resumed.close()
        #expect(!FileManager.default.fileExists(atPath: device.appendingPathComponent("work/edit.json").path))
    }

    private actor PublicationGate {
        private var reached = false
        private var arrival: CheckedContinuation<Void, Never>?
        private var release: CheckedContinuation<Void, Never>?
        func pause() async {
            reached = true; arrival?.resume(); arrival = nil
            await withCheckedContinuation { release = $0 }
        }
        func wait() async {
            if !reached { await withCheckedContinuation { arrival = $0 } }
        }
        func open() { release?.resume(); release = nil }
    }

    @Test(arguments: [false, true])
    func publicationSuspensionRetainsLeaseAndRevalidates(_ cancel: Bool) async throws {
        let device = try fixture()
        defer { try? FileManager.default.removeItem(at: device) }
        let original = try Data(contentsOf: device.appendingPathComponent("device.json"))
        let edit = try StorageGeneration.begin(device: device)
        let candidate = try await candidate(edit)
        let gate = PublicationGate()
        let operation = Task {
            try await edit.publish(record: candidate) { if $0 == .ready { await gate.pause() } }
        }
        await gate.wait()
        await #expect(throws: FirmwareError.self) { try await edit.close() }
        await #expect(throws: FirmwareError.self) { try await edit.discard() }
        await #expect(throws: FirmwareError.self) { _ = try await edit.candidateRecord() }
        #expect(throws: FirmwareError.self) { _ = try OwnedStorageRecord.acquire(device: device, resume: true) }
        let expected: Data
        if cancel { operation.cancel(); expected = original }
        else {
            expected = original + Data(" \n".utf8)
            try expected.write(to: device.appendingPathComponent("device.json"))
        }
        await gate.open()
        await #expect(throws: (any Error).self) { try await operation.value }
        #expect(try Data(contentsOf: device.appendingPathComponent("device.json")) == expected)
        #expect(FileManager.default.fileExists(atPath: edit.root.appendingPathComponent("device.json").path))
        #expect(FileManager.default.fileExists(atPath: device.appendingPathComponent("work/edit.json").path))
        try await edit.close()
        let retained = try OwnedStorageRecord.acquire(device: device, resume: true)
        withExtendedLifetime((edit, retained)) {}
    }

    @Test func closedTransactionRejectsEveryStorageOperationAndReleasesRetainedOwner() async throws {
        let device = try fixture()
        defer { try? FileManager.default.removeItem(at: device) }
        let edit = try StorageGeneration.begin(device: device)
        let candidate = try await candidate(edit)
        try await edit.close(); try await edit.close()
        await #expect(throws: FirmwareError.self) { _ = try await edit.candidateRecord() }
        await #expect(throws: FirmwareError.self) { try await edit.publish(record: candidate) }
        await #expect(throws: FirmwareError.self) { try await edit.discard() }
        await #expect(throws: FirmwareError.self) { try await edit.recoverPublication() }
        let held = try OwnedStorageRecord.acquire(device: device, resume: true)
        withExtendedLifetime((edit, held)) {}
    }

    @Test func explicitlyClosedSharedAliasCannotConferTransactionAuthority() async throws {
        let device = try fixture()
        defer { try? FileManager.default.removeItem(at: device) }
        let owner = try OwnedStorageRecord.acquire(device: device)
        let edit = try StorageGeneration.begin(owner: owner)
        let original = try Data(contentsOf: device.appendingPathComponent("device.json"))
        owner.lease.close()
        #expect(owner.lease.isClosed)
        await #expect(throws: FirmwareError.self) { _ = try await edit.candidateRecord() }
        await #expect(throws: FirmwareError.self) { try await edit.discard() }
        #expect(throws: FirmwareError.self) { _ = try StorageGeneration.begin(owner: owner) }
        #expect(try Data(contentsOf: device.appendingPathComponent("device.json")) == original)
        try await edit.close()
    }

}
