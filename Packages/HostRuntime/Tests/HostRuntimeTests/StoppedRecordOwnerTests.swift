import Darwin
import Foundation
import Testing
import HostRuntime

struct StoppedRecordOwnerTests {
    private func fixture(_ body: (URL, URL, UUID) throws -> Void) throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = UUID(); let device = state.appendingPathComponent("Devices/\(id.uuidString)")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        try body(state, device, id)
    }
    private func bytes(_ id: UUID, base: String, overlay: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "unknown": ["retained": true],
            "base": ["path": base], "storage": ["overlay": overlay]])
    }
    @Test func exclusionPrecedesRecordReadAndFailureReleasesDescriptor() throws {
        try fixture { _, device, _ in
            let record = device.appendingPathComponent("device.json")
            try Data("not-json".utf8).write(to: record)
            do {
                let held = try StorageLease(device.appendingPathComponent("work/lease"))
                #expect(throws: StorageLease.Failure.inUse) { _ = try StoppedRecordOwner(device: device) }
                withExtendedLifetime(held) {}
            }
            #expect(throws: (any Error).self) { _ = try StoppedRecordOwner(device: device) }
            let held = try StorageLease(device.appendingPathComponent("work/lease"))
            withExtendedLifetime(held) {}
            #expect(try Data(contentsOf: record) == Data("not-json".utf8))
        }
    }
    @Test func immutableSnapshotAndLegacyRelativeRootShareOneOwner() throws {
        try fixture { state, device, id in
            let original = try bytes(id, base: "external-base", overlay: "standalone-overlay")
            let record = device.appendingPathComponent("device.json")
            try original.write(to: record)
            do {
                let owner = try StoppedRecordOwner(device: device)
                #expect(owner.bytes == original)
                #expect(owner.paths?.base == state.appendingPathComponent("external-base"))
                #expect(owner.paths?.overlay == state.appendingPathComponent("standalone-overlay"))
                try bytes(id, base: "new-base", overlay: "new-overlay").write(to: record)
                #expect(owner.bytes == original)
                #expect(throws: StorageLease.Failure.inUse) { _ = try StorageLease(device.appendingPathComponent("work/lease")) }
                withExtendedLifetime(owner) {}
            }
            let current = try StoppedRecordOwner(device: device)
            #expect(current.paths?.base == state.appendingPathComponent("new-base"))
            withExtendedLifetime(current) {}
        }
    }
    @Test func explicitManagedPolicyPreservesExternalBaseAndPrivateGenerations() throws {
        try fixture { state, device, id in
            let record = device.appendingPathComponent("device.json")
            let original = try bytes(id, base: state.appendingPathComponent("external-base").path,
                overlay: "Devices/\(id.uuidString)/generations/new/overlay")
            try original.write(to: record)
            do {
                let owner = try StoppedRecordOwner(device: device, policy: .managed(state: state, id: id))
                #expect(owner.bytes == original)
                #expect(owner.paths?.absoluteStyle == true)
                withExtendedLifetime(owner) {}
            }
            try bytes(UUID(), base: "external", overlay: "Devices/\(id.uuidString)/overlay").write(to: record)
            #expect(throws: StorageRecordPaths.Failure.self) { _ = try StoppedRecordOwner(device: device, policy: .managed(state: state, id: id)) }
            try bytes(id, base: "external", overlay: "unowned/overlay").write(to: record)
            #expect(throws: StoragePathAuthority.Failure.self) { _ = try StoppedRecordOwner(device: device, policy: .managed(state: state, id: id)) }
            // The same deliberately external record is supported only by explicit standalone policy.
            let owner = try StoppedRecordOwner(device: device)
            withExtendedLifetime(owner) {}
        }
    }
    @Test(arguments: ["snapshot", "writableNOR", "usbmuxConf"])
    func presentMalformedMutablePathCannotEscapeValidation(_ field: String) throws {
        try fixture { state, device, id in
            var object = try JSONSerialization.jsonObject(with: bytes(id, base: "external", overlay: "Devices/\(id.uuidString)/overlay")) as! [String: Any]
            var storage = object["storage"] as! [String: Any]
            storage[field] = 42; object["storage"] = storage
            try JSONSerialization.data(withJSONObject: object).write(to: device.appendingPathComponent("device.json"))
            #expect(throws: StorageRecordPaths.Failure.self) { _ = try StoppedRecordOwner(device: device, policy: .managed(state: state, id: id)) }
            let held = try StorageLease(device.appendingPathComponent("work/lease"))
            withExtendedLifetime(held) {}
        }
    }

    @Test(arguments: ["work", "generations", "."])
    func managedMutableAuthorityCannotOverlapImmutableBase(_ directory: String) throws {
        try fixture { state, device, id in
            try bytes(id, base: device.appendingPathComponent(directory).path,
                overlay: device.appendingPathComponent("overlay").path).write(to: device.appendingPathComponent("device.json"))
            #expect(throws: StoragePathAuthority.Failure.self) { _ = try StoppedRecordOwner(device: device, policy: .managed(state: state, id: id)) }
            let held = try StorageLease(device.appendingPathComponent("work/lease"))
            withExtendedLifetime(held) {}
        }
    }

    @Test func managedPublishedGenerationRetainsImmutableBaseWithMutableSiblings() throws {
        try fixture { state, device, id in
            let generation = device.appendingPathComponent("generations/published")
            let base = generation.appendingPathComponent("base")
            let overlay = generation.appendingPathComponent("overlay")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
            let record = try bytes(id, base: base.path, overlay: overlay.path)
            try record.write(to: device.appendingPathComponent("device.json"))
            let owner = try StoppedRecordOwner(device: device, policy: .managed(state: state, id: id))
            #expect(owner.paths?.base.path == base.path)
            #expect(owner.paths?.overlay.path == overlay.path)
            #expect(owner.bytes == record)
            withExtendedLifetime(owner) {}
        }
    }

    @Test func publishedGenerationStillRejectsMutableBaseOverlapAndForeignContainer() throws {
        try fixture { state, device, id in
            let generation = device.appendingPathComponent("generations/published")
            let base = generation.appendingPathComponent("base")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let recordURL = device.appendingPathComponent("device.json")
            try bytes(id, base: base.path, overlay: base.appendingPathComponent("overlay").path).write(to: recordURL)
            #expect(throws: StoragePathAuthority.Failure.self) {
                _ = try StoppedRecordOwner(device: device, policy: .managed(state: state, id: id))
            }
            let foreign = state.appendingPathComponent("foreign")
            try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
            try FileManager.default.removeItem(at: device.appendingPathComponent("generations"))
            try FileManager.default.createSymbolicLink(at: device.appendingPathComponent("generations"), withDestinationURL: foreign)
            try bytes(id, base: state.appendingPathComponent("external").path, overlay: device.appendingPathComponent("overlay").path).write(to: recordURL)
            #expect(throws: StoragePathAuthority.Failure.self) {
                _ = try StoppedRecordOwner(device: device, policy: .managed(state: state, id: id))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: foreign.path).isEmpty)
        }
    }

    @Test func pendingPublishedRecordAdmitsOnlyExplicitRecovery() throws {
        try fixture { state, device, id in
            let generation = device.appendingPathComponent("generations/published")
            let data = try bytes(id, base: generation.appendingPathComponent("base").path,
                overlay: generation.appendingPathComponent("overlay").path)
            try data.write(to: device.appendingPathComponent("device.json"))
            try FileManager.default.createDirectory(at: device.appendingPathComponent("work"), withIntermediateDirectories: true)
            try Data("pending".utf8).write(to: device.appendingPathComponent("work/edit.json"))
            #expect(throws: StorageLease.Failure.pendingEdit) {
                _ = try StoppedRecordOwner(device: device, policy: .managed(state: state, id: id))
            }
            let recovery = try StoppedRecordOwner(device: device, policy: .managed(state: state, id: id), allowPendingEdit: true)
            #expect(recovery.bytes == data)
            #expect(recovery.paths?.base == generation.appendingPathComponent("base"))
            withExtendedLifetime(recovery) {}
        }
    }

}
