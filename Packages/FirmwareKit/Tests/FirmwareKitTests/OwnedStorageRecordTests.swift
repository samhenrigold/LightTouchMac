import Foundation
import HostRuntime
import Testing
@testable import FirmwareKit

struct OwnedStorageRecordTests {
    private func fixture() throws -> URL {
        let state = try Fixtures.tempDir("owned-record")
        let dir = state.appendingPathComponent("Devices/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func record(_ device: URL, base: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": device.lastPathComponent,
            "unknown": ["preserved": true], "base": ["path": base], "storage": ["overlay": "missing-overlay"]])
    }
    @Test func selectedDeviceResolvesLatestRecordOnlyAfterAdmission() throws {
        let device = try fixture()
        defer { try? FileManager.default.removeItem(at: device.deletingLastPathComponent().deletingLastPathComponent()) }
        let url = device.appendingPathComponent("device.json")
        try Data("not yet valid".utf8).write(to: url)
        let selected = try VolumeExport.Source(device: device) // No read, parse or lock.
        let latest = try record(device, base: "latest-generation")
        try latest.write(to: url)
        do {
            let (owner, resolved) = try selected.admit()
            let admitted = try #require(owner)
            #expect(admitted.bytes == latest)
            #expect(resolved.base == device.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("latest-generation"))
            let transaction = try StorageGeneration.begin(owner: admitted)
            #expect(try Data(contentsOf: transaction.root.appendingPathComponent("original-device.json")) == latest)
            #expect(throws: StorageLease.Failure.inUse) { _ = try StorageLease(device.appendingPathComponent("work/lease")) }
            let candidate = try JSONSerialization.jsonObject(with: transaction.candidateRecord()) as? [String: Any]
            #expect((candidate?["unknown"] as? [String: Bool])?["preserved"] == true)
            try transaction.discard()
            withExtendedLifetime((transaction, admitted)) {}
        }
        let held = try StorageLease(device.appendingPathComponent("work/lease"))
        withExtendedLifetime((held, selected)) {}
    }
    @Test func exportFailureReleasesLeaseWithSelectionStillAlive() throws {
        let device = try fixture()
        defer { try? FileManager.default.removeItem(at: device.deletingLastPathComponent().deletingLastPathComponent()) }
        try record(device, base: "missing-generation").write(to: device.appendingPathComponent("device.json"))
        let selected = try VolumeExport.Source(device: device)
        let out = device.appendingPathComponent("export")
        #expect(throws: (any Error).self) { _ = try VolumeExport.export(selected, out: out) }
        let held = try StorageLease(device.appendingPathComponent("work/lease"))
        #expect(!FileManager.default.fileExists(atPath: device.appendingPathComponent("work/edit.json").path))
        withExtendedLifetime((held, selected)) {}
    }
    @Test func busyRecordRefusesBeforeParseOrStagingAndUnsupportedEditLeavesNoIntent() throws {
        let device = try fixture()
        defer { try? FileManager.default.removeItem(at: device.deletingLastPathComponent().deletingLastPathComponent()) }
        let recordURL = device.appendingPathComponent("device.json")
        try Data("malformed".utf8).write(to: recordURL)
        let selected = try VolumeExport.Source(device: device)
        let out = device.appendingPathComponent("export")
        do {
            let held = try StorageLease(device.appendingPathComponent("work/lease"))
            #expect(throws: FirmwareError.self) { _ = try VolumeExport.export(selected, out: out) }
            #expect(!FileManager.default.fileExists(atPath: out.path))
            #expect(try Data(contentsOf: recordURL) == Data("malformed".utf8))
            withExtendedLifetime(held) {}
        }
        try record(device, base: "unsupported").write(to: recordURL)
        #expect(throws: FirmwareError.self) { _ = try StoppedVolumeEdit.begin(device: device) }
        #expect(!FileManager.default.fileExists(atPath: device.appendingPathComponent("work/edit.json").path))
        let held = try StorageLease(device.appendingPathComponent("work/lease"))
        withExtendedLifetime(held) {}
    }
    @Test(arguments: 0..<16) func functionReturnReleasesTransactionOwner(_ iteration: Int) throws {
        let device = try fixture()
        defer { try? FileManager.default.removeItem(at: device.deletingLastPathComponent().deletingLastPathComponent()) }
        try record(device, base: "original").write(to: device.appendingPathComponent("device.json"))
        weak var previous: StorageGeneration?
        func start() throws -> UUID {
            let edit = try StorageGeneration.begin(device: device)
            previous = edit
            return edit.id
        }
        let id = try start()
        #expect(previous == nil, "transaction instance survived its owning function in iteration \(iteration)")
        let resumed = try StorageGeneration.resume(device: device, id: id)
        // Resource lifetime only: do not fan out synchronous disk-image subprocess checks.
        withExtendedLifetime(resumed) {}
    }

}
