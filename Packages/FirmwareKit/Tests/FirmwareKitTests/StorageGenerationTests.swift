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
    private func candidate(_ edit: StorageGeneration) throws -> Data {
        let fm = FileManager.default
        for path in [edit.base, edit.overlay] { try fm.createDirectory(at: path, withIntermediateDirectories: true) }
        try Data("complete-flash".utf8).write(to: edit.base.appendingPathComponent("page"))
        try Data("complete-nor".utf8).write(to: edit.root.appendingPathComponent("nor.bin"))
        return try edit.candidateRecord()
    }

    @Test func intentAndLeaseBlockAnotherOwnerUntilDiscard() throws {
        let device = try fixture()
        defer { try? FileManager.default.removeItem(at: device) }
        func stoppedOwner() throws -> UUID {
            let edit = try StorageGeneration.begin(device: device)
            #expect(throws: FirmwareError.self) { try StorageGeneration.begin(device: device) }
            #expect(throws: FirmwareError.self) { try StoppedStorageLease(device.appendingPathComponent("work/lease")) }
            return edit.id
        }
        let id = try stoppedOwner() // Owner exits; intent must continue excluding boot.
        #expect(throws: FirmwareError.self) { try StoppedStorageLease(device.appendingPathComponent("work/lease")) }
        let resumed = try StorageGeneration.resume(device: device, id: id)
        try resumed.discard()
        #expect(!FileManager.default.fileExists(atPath: device.appendingPathComponent("work/edit.json").path))
        #expect(try String(contentsOf: device.appendingPathComponent("device.json"), encoding: .utf8).contains("original"))
    }

    @Test(arguments: [StorageGeneration.Checkpoint.ready, .recordPublished])
    func recoveryAfterOwnerExit(at interruption: StorageGeneration.Checkpoint) throws {
        let device = try fixture()
        defer { try? FileManager.default.removeItem(at: device) }
        let id: UUID
        let expected: Data
        do {
            let edit = try StorageGeneration.begin(device: device)
            id = edit.id; expected = try candidate(edit)
            #expect(throws: Interrupted.crash) {
                try edit.publish(record: expected) { if $0 == interruption { throw Interrupted.crash } }
            }
            let current = try Data(contentsOf: device.appendingPathComponent("device.json"))
            #expect((StorageGeneration.hash(current) == StorageGeneration.hash(expected)) == (interruption == .recordPublished))
        }
        do {
            let recovery = try StorageGeneration.resume(device: device, id: id)
            try recovery.recoverPublication()
        }
        #expect(try Data(contentsOf: device.appendingPathComponent("device.json")) == expected)
        #expect(!FileManager.default.fileExists(atPath: device.appendingPathComponent("work/edit.json").path))
        let lease = try StoppedStorageLease(device.appendingPathComponent("work/lease"))
        withExtendedLifetime(lease) {}
        let json = try #require(try JSONSerialization.jsonObject(with: expected) as? [String: Any])
        #expect(((json["base"] as? [String: String])?["path"]?.hasPrefix("/") == false))
        #expect((json["unknown"] as? [String: Bool])?["preserved"] == true)
        #expect((json["storage"] as? [String: String])?["snapshot"]?.contains(id.uuidString) == true)
    }

    @Test func changedRecordOrIdentityCannotBePublished() throws {
        let device = try fixture()
        defer { try? FileManager.default.removeItem(at: device) }
        let edit = try StorageGeneration.begin(device: device)
        let data = try candidate(edit)
        var record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        record["identity"] = ["udid": "another-device"]
        #expect(throws: FirmwareError.self) { try edit.publish(record: JSONSerialization.data(withJSONObject: record)) }
        try Data("changed".utf8).write(to: device.appendingPathComponent("device.json"))
        #expect(throws: FirmwareError.self) { try edit.publish(record: data) }
        #expect(throws: FirmwareError.self) { try edit.discard() }
    }
    @Test func damagedReadyGenerationCannotReplaceOriginal() throws {
        let device = try fixture()
        defer { try? FileManager.default.removeItem(at: device) }
        let id: UUID
        do {
            let edit = try StorageGeneration.begin(device: device)
            id = edit.id
            let record = try candidate(edit)
            #expect(throws: Interrupted.crash) {
                try edit.publish(record: record) { if $0 == .ready { throw Interrupted.crash } }
            }
            try Data("damaged".utf8).write(to: edit.base.appendingPathComponent("page"))
        }
        let resumed = try StorageGeneration.resume(device: device, id: id)
        #expect(throws: FirmwareError.self) { try resumed.recoverPublication() }
        #expect(try String(contentsOf: device.appendingPathComponent("device.json"), encoding: .utf8).contains("original"))
        try resumed.discard()
    }

    @Test func wrongResumeCannotBypassPendingIntent() throws {
        let device = try fixture()
        defer { try? FileManager.default.removeItem(at: device) }
        let original = try Data(contentsOf: device.appendingPathComponent("device.json"))
        func start() throws -> UUID { try StorageGeneration.begin(device: device).id }
        let id = try start()
        #expect(throws: FirmwareError.self) { _ = try StorageGeneration.resume(device: device, id: UUID()) }
        #expect(throws: FirmwareError.self) { _ = try StoppedStorageLease(device.appendingPathComponent("work/lease")) }
        #expect(try Data(contentsOf: device.appendingPathComponent("device.json")) == original)
        let resumed = try StorageGeneration.resume(device: device, id: id)
        try resumed.discard()
        #expect(!FileManager.default.fileExists(atPath: device.appendingPathComponent("work/edit.json").path))
    }

}
