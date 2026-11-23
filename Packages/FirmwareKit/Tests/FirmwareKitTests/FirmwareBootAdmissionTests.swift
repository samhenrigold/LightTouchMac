import FirmwareSchema
import Foundation
import HostRuntime
import Testing

@testable import FirmwareKit

@Suite(.detachesItsImages) struct FirmwareBootAdmissionTests {
    /// n90/n88 recipe 1 -> 2: admission records the IMEI and UDID the base's identity makes, once; a recipe 2 base
    /// (its identity has the IMEI) and other boards are left alone.
    @Test func iPhoneIMEIStep() throws {
        let root = try Fixtures.tempDir("iphone-imei")
        defer { TemporaryTrees.remove(root) }
        let base = root.appendingPathComponent("base")
        let marker = root.appendingPathComponent(FirmwareWire.migratedRecipeFile)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let ident = try UnitIdentity.synthesize(seed: "iphone4-test", modelNumber: "MC603")
        func write(board: String, version: Int, identity: UnitIdentity) throws {
            try JSONSerialization.data(withJSONObject: [
                "board": board, "entry": ["content": ["board": board, "recipe": ["version": version]]]
            ])
            .write(to: base.appendingPathComponent("device.lock.json"))
            try identity.json().write(to: base.appendingPathComponent("identity.json"))
            TemporaryTrees.remove(marker)
        }
        try write(board: "n90ap", version: 1, identity: ident)
        #expect(try FirmwareBootAdmission.iPhoneIMEI(base: base, marker: marker))
        let m = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
        #expect(
            m["recipe"] as? Int == 2 && m["step"] as? String == "iphone-imei"
                && m["udid"] as? String == ident.addingIMEI(seed: "iphone4-test").udid
        )
        #expect(try !FirmwareBootAdmission.iPhoneIMEI(base: base, marker: marker))  // once
        try write(board: "n90ap", version: 2, identity: ident.addingIMEI(seed: "iphone4-test"))
        #expect(try !FirmwareBootAdmission.iPhoneIMEI(base: base, marker: marker))
        try write(board: "n81ap", version: 1, identity: ident)
        #expect(try !FirmwareBootAdmission.iPhoneIMEI(base: base, marker: marker))
        #expect(
            FirmwareWire.admittedRecipe(1, board: "n88ap") == 2 && FirmwareWire.admittedRecipe(1, board: "n81ap") == 1
        )
    }

    private func fixture() throws -> (root: URL, device: URL, record: Data) {
        let root = try Fixtures.tempDir("boot-admission")
        let device = root.appendingPathComponent("device")
        let base = device.appendingPathComponent("base")
        let overlay = device.appendingPathComponent("overlay")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
        try Data("flash unchanged".utf8).write(to: base.appendingPathComponent("page"))
        try Data("NOR unchanged".utf8).write(to: device.appendingPathComponent("nor.bin"))
        let record: [String: Any] = [
            "id": UUID().uuidString, "board": "n72ap", "firmware": "unqualified",
            "base": ["kind": "prepared", "path": base.path],
            "storage": [
                "key": "current", "overlay": overlay.path,
                "writableNOR": device.appendingPathComponent("nor.bin").path
            ]
        ]
        let bytes = try DeviceRecord.data(record)
        try bytes.write(to: device.appendingPathComponent(DeviceRecord.name))
        return (root, device, bytes)
    }

    @Test func admissionDoesNotInspectOrConvertFirmwareAndRawRequiresOptIn() async throws {
        let f = try fixture()
        defer { TemporaryTrees.remove(f.root) }
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
        let f = try fixture()
        defer { TemporaryTrees.remove(f.root) }
        let result = try await FirmwareBootAdmission.admit(
            device: f.device,
            prepare: { owner in
                let transaction = try StorageGeneration.begin(owner: owner)
                return try await StorageGeneration.withOwner(transaction, retaining: owner) { edit in
                    try FileManager.default.createDirectory(at: edit.base, withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(at: edit.overlay, withIntermediateDirectories: true)
                    try Data("flash prepared".utf8).write(to: edit.base.appendingPathComponent("page"))
                    try Data("NOR prepared".utf8).write(to: edit.root.appendingPathComponent("nor.bin"))
                    let candidate = try await edit.candidateRecord()
                    try await edit.publish(record: candidate)
                    #expect(throws: StorageLease.Failure.inUse) {
                        _ = try StorageLease(owner.device.appendingPathComponent("work/lease"))
                    }
                    return true
                }
            }
        )
        #expect(result.changed)
        #expect(result.paths?.base != f.device.appendingPathComponent("base"))
        #expect(result.record == (try Data(contentsOf: f.device.appendingPathComponent(DeviceRecord.name))))
        let next = try StoppedRecordOwner(device: f.device)
        #expect(next.paths?.base == result.paths?.base)
    }

    /// A record a newer build wrote (a storage format this build doesn't know) is refused before any step runs.
    @Test func aNewerRecordFormatIsRefused() async throws {
        let f = try fixture()
        defer { TemporaryTrees.remove(f.root) }
        let url = f.device.appendingPathComponent(DeviceRecord.name)
        var record = try DeviceRecord.object(f.record)
        record["format"] = DeviceRecord.currentFormat + 1
        try DeviceRecord.data(record).write(to: url)
        await #expect(throws: DeviceRecord.NewerFormat.self) { try await FirmwareBootAdmission.admit(device: f.device) }
        record["format"] = DeviceRecord.currentFormat
        try DeviceRecord.data(record).write(to: url)
        _ = try await FirmwareBootAdmission.admit(device: f.device)
    }

    @Test func liveAndPendingStorageRefuseAdmission() async throws {
        let f = try fixture()
        defer { TemporaryTrees.remove(f.root) }
        let lease = try StorageLease(f.device.appendingPathComponent("work/lease"))
        await #expect(throws: (any Error).self) { try await FirmwareBootAdmission.admit(device: f.device) }
        lease.close()
        try Data("unfinished".utf8).write(to: f.device.appendingPathComponent("work/edit.json"))
        await #expect(throws: (any Error).self) {
            try await FirmwareBootAdmission.admit(device: f.device, allowRaw: true)
        }
        #expect(try Data(contentsOf: f.device.appendingPathComponent(DeviceRecord.name)) == f.record)
    }

    @Test func cancellationLeavesRecordAndIntentUntouched() async throws {
        let f = try fixture()
        defer { TemporaryTrees.remove(f.root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FirmwareBootAdmission.admit(device: f.device)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: f.device.appendingPathComponent(DeviceRecord.name)) == f.record)
        #expect(!FileManager.default.fileExists(atPath: f.device.appendingPathComponent("work/edit.json").path))
    }
}
