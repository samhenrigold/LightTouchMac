import Foundation
import HostRuntime
import Testing

@testable import FirmwareKit

struct StorageGenerationTests {
    enum Interrupted: Error { case crash }
    private func fixture() throws -> URL {
        let device = try Fixtures.tempDir("storage-generation")
        let record: [String: Any] = [
            "id": UUID().uuidString, "board": "n72ap", "firmware": "7E18",
            "identity": ["udid": "keep-this-identity"], "unknown": ["preserved": true],
            "base": ["path": "original", "kind": "prepared"],
            "storage": [
                "key": "original", "overlay": "overlay", "snapshot": "old-snapshot",
                "writableNOR": "nor.bin", "usbmuxConf": "conf"
            ]
        ]
        try DeviceRecord.data(record).write(to: device.appendingPathComponent(DeviceRecord.name))
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
        let id = try await stoppedOwner()  // Owner exits; intent must continue excluding boot.
        #expect(throws: FirmwareError.self) { try OwnedStorageRecord.acquire(device: device) }
        let resumed = try StorageGeneration.resume(device: device, id: id)
        try await resumed.discard()
        try await resumed.close()
        #expect(!FileManager.default.fileExists(atPath: device.appendingPathComponent("work/edit.json").path))
        #expect(
            try String(contentsOf: device.appendingPathComponent(DeviceRecord.name), encoding: .utf8).contains(
                "original"
            )
        )
    }

    @Test(arguments: [StorageGeneration.Checkpoint.ready, .recordPublished])
    func recoveryAfterOwnerExit(at interruption: StorageGeneration.Checkpoint) async throws {
        let device = try fixture()
        defer { try? FileManager.default.removeItem(at: device) }
        let id: UUID
        let expected: Data
        do {
            let edit = try StorageGeneration.begin(device: device)
            id = edit.id
            expected = try await candidate(edit)
            await #expect(throws: Interrupted.crash) {
                try await edit.publish(record: expected) { if $0 == interruption { throw Interrupted.crash } }
            }
            let current = try Data(contentsOf: device.appendingPathComponent(DeviceRecord.name))
            #expect(
                (StorageGeneration.hash(current) == StorageGeneration.hash(expected))
                    == (interruption == .recordPublished)
            )
            try await edit.close()
        }
        do {
            let recovery = try StorageGeneration.resume(device: device, id: id)
            try await recovery.recoverPublication()
            try await recovery.close()
        }
        #expect(try Data(contentsOf: device.appendingPathComponent(DeviceRecord.name)) == expected)
        #expect(!FileManager.default.fileExists(atPath: device.appendingPathComponent("work/edit.json").path))
        let lease = try OwnedStorageRecord.acquire(device: device)
        withExtendedLifetime(lease) {}
        let json = try DeviceRecord.object(expected)
        #expect(((json["base"] as? [String: String])?["path"]?.hasPrefix("/") == false))
        #expect((json["unknown"] as? [String: Bool])?["preserved"] == true)
        #expect((json["storage"] as? [String: String])?["snapshot"]?.contains(id.uuidString) == true)
    }

    @Test func changedRecordOrIdentityCannotBePublished() async throws {
        let device = try fixture()
        defer { try? FileManager.default.removeItem(at: device) }
        let edit = try StorageGeneration.begin(device: device)
        let data = try await candidate(edit)
        var record = try DeviceRecord.object(data)
        record["identity"] = ["udid": "another-device"]
        await #expect(throws: FirmwareError.self) { try await edit.publish(record: DeviceRecord.data(record)) }
        try Data("changed".utf8).write(to: device.appendingPathComponent(DeviceRecord.name))
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
        #expect(
            try String(contentsOf: device.appendingPathComponent(DeviceRecord.name), encoding: .utf8).contains(
                "original"
            )
        )
        try await resumed.discard()
        try await resumed.close()
    }

    /// The certificate's file digest reads a chip file's data extents, not its holes, so a 16 GiB store of a few
    /// written pages takes well under a second, and a byte changed in an extent, a zero written into a hole (the
    /// same bytes, laid out differently) or the size grown each change it.
    @Test func sparseChipFilesAreCertifiedByTheirExtents() throws {
        let dir = try Fixtures.tempDir("sparse-digest")
        defer { try? FileManager.default.removeItem(at: dir) }
        let chip = dir.appendingPathComponent("cs0.pages")
        #expect(FileManager.default.createFile(atPath: chip.path, contents: nil))
        let f = try FileHandle(forWritingTo: chip)
        defer { try? f.close() }
        func write(_ bytes: [UInt8], at offset: UInt64) throws {
            try f.seek(toOffset: offset)
            try f.write(contentsOf: bytes)
            try f.synchronize()
        }
        try f.truncate(atOffset: 16 << 30)
        for page in [0, 700, 1 << 20] { try write([UInt8](repeating: 0x5A, count: 4096), at: UInt64(page) * 4096) }
        let start = ContinuousClock.now
        let first = try StorageGeneration.sparseDigest(chip)
        #expect(ContinuousClock.now - start < .seconds(2), "the holes were read")
        #expect(try StorageGeneration.sparseDigest(chip) == first)
        try write([0x5B], at: 700 * 4096 + 9)
        let changed = try StorageGeneration.sparseDigest(chip)
        #expect(changed != first)
        try write([0], at: 8 << 30)
        let filled = try StorageGeneration.sparseDigest(chip)
        #expect(filled != changed)
        try f.truncate(atOffset: (16 << 30) + 4096)
        #expect(try StorageGeneration.sparseDigest(chip) != filled)
    }

    @Test func wrongResumeCannotBypassPendingIntent() async throws {
        let device = try fixture()
        defer { try? FileManager.default.removeItem(at: device) }
        let original = try Data(contentsOf: device.appendingPathComponent(DeviceRecord.name))
        func start() async throws -> UUID {
            let edit = try StorageGeneration.begin(device: device)
            try await edit.close()
            return edit.id
        }
        let id = try await start()
        #expect(throws: FirmwareError.self) { _ = try StorageGeneration.resume(device: device, id: UUID()) }
        #expect(throws: FirmwareError.self) { _ = try OwnedStorageRecord.acquire(device: device) }
        #expect(try Data(contentsOf: device.appendingPathComponent(DeviceRecord.name)) == original)
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
            reached = true
            arrival?.resume()
            arrival = nil
            await withCheckedContinuation { release = $0 }
        }
        func wait() async {
            if !reached { await withCheckedContinuation { arrival = $0 } }
        }
        func open() {
            release?.resume()
            release = nil
        }
    }

    @Test(arguments: [false, true])
    func publicationSuspensionRetainsLeaseAndRevalidates(_ cancel: Bool) async throws {
        let device = try fixture()
        defer { try? FileManager.default.removeItem(at: device) }
        let original = try Data(contentsOf: device.appendingPathComponent(DeviceRecord.name))
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
        if cancel {
            operation.cancel()
            expected = original
        } else {
            expected = original + Data(" \n".utf8)
            try expected.write(to: device.appendingPathComponent(DeviceRecord.name))
        }
        await gate.open()
        await #expect(throws: (any Error).self) { try await operation.value }
        #expect(try Data(contentsOf: device.appendingPathComponent(DeviceRecord.name)) == expected)
        #expect(FileManager.default.fileExists(atPath: edit.root.appendingPathComponent(DeviceRecord.name).path))
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
        try await edit.close()
        try await edit.close()
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
        let original = try Data(contentsOf: device.appendingPathComponent(DeviceRecord.name))
        owner.lease.close()
        #expect(owner.lease.isClosed)
        await #expect(throws: FirmwareError.self) { _ = try await edit.candidateRecord() }
        await #expect(throws: FirmwareError.self) { try await edit.discard() }
        #expect(throws: FirmwareError.self) { _ = try StorageGeneration.begin(owner: owner) }
        #expect(try Data(contentsOf: device.appendingPathComponent(DeviceRecord.name)) == original)
        try await edit.close()
    }
}
