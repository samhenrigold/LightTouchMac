import Foundation
import Testing
@testable import FirmwareKit

struct A6FirstBootTests {
    private static let fixtureKeys = ["FK_A6_MG_MIGRATOR_14G61", "FK_A6_MC_MIGRATOR_14G61"]
    private static var hasFixtures: Bool { fixtureKeys.allSatisfy { ProcessInfo.processInfo.environment[$0] != nil } }

    @Test func rejectsUnknownComponentsAndForeignContainerMetadata() throws {
        #expect(throws: FirmwareError.self) {
            try A6FirstBoot.prepare(Data(count: 128), component: A6FirstBoot.components[0])
        }
        let group = A6FirstBoot.groups[0]
        var metadata = try A6FirstBoot.containerMetadata(group)
        #expect(A6FirstBoot.validMetadata(metadata, identifier: group))
        #expect(!A6FirstBoot.validMetadata(metadata, identifier: A6FirstBoot.groups[1]))
        metadata["MCMMetadataContentClass"] = 2
        #expect(!A6FirstBoot.validMetadata(metadata, identifier: group))
        metadata["MCMMetadataContentClass"] = 13
        metadata["MCMMetadataUUID"] = "not-a-uuid"
        #expect(!A6FirstBoot.validMetadata(metadata, identifier: group))
        #expect(throws: FirmwareError.self) { try A6FirstBoot.containerMetadata("unrelated.group") }
    }

    private func fixtures() throws -> [Data] {
        try Self.fixtureKeys.map { key in
            try Data(contentsOf: URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment[key])))
        }
    }

    @Test(.enabled(if: hasFixtures, "Set paths to the two original 14G61 migrators; no Apple fixtures are distributed"))
    func boundsEditsAndVerifiesEverySignedPage() throws {
        for (component, original) in zip(A6FirstBoot.components, try fixtures()) {
            let prepared = try A6FirstBoot.prepare(original, component: component)
            #expect(prepared.count == original.count)
            let signature = try #require(MachOSignature.codeSignature(in: original))
            let allowed = component.edits.map { $0.offset..<($0.offset + $0.original.count) }
                + [signature.offset..<(signature.offset + signature.size)]
            #expect(zip(original, prepared).enumerated().allSatisfy { index, pair in
                pair.0 == pair.1 || allowed.contains { $0.contains(index) }
            })
            #expect(try A6GuestAssets.verifiedCodeDirectories(prepared).count > 0)
            #expect(try A6FirstBoot.prepare(prepared, component: component) == prepared)
            var changed = original; changed[0] ^= 1
            #expect(throws: FirmwareError.self) { try A6FirstBoot.prepare(changed, component: component) }
        }
    }

    @Test(.enabled(if: hasFixtures, "Set paths to original 14G61 migrators for native HFS staging validation"))
    func stagesFreshVolumesAndRegistersActualPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let system = root.appendingPathComponent("system.img"), data = root.appendingPathComponent("data.img")
        for file in [system, data] { try HFSPlusWriter.makeHFS(file, size: 16 << 20, journaled: false) }
        let s = try HFSPlusWriter(system), d = try HFSPlusWriter(data)
        s.owner = (0, 0); d.owner = (0, 0)
        try s.makeDirectory("System/Library/CoreServices", mode: 0o755)
        try s.put(PropertyListSerialization.data(fromPropertyList: ["ProductBuildVersion": "14G61"], format: .binary, options: 0),
                  at: "System/Library/CoreServices/SystemVersion.plist")
        for (component, bytes) in zip(A6FirstBoot.components, try fixtures()) {
            try s.makeDirectory((component.path as NSString).deletingLastPathComponent, mode: 0o755)
            try s.put(bytes, at: component.path, mode: 0o755)
        }
        try d.makeDirectory((A6FirstBoot.cloudPath as NSString).deletingLastPathComponent, mode: 0o755)
        try d.put(PropertyListSerialization.data(fromPropertyList: ["CloudConfigurationUIComplete": true], format: .binary, options: 0),
                  at: A6FirstBoot.cloudPath)
        try s.close(); try d.close()
        let plan = try PropertyListSerialization.data(fromPropertyList:
            ["Build": "14G61", "Overrides": ["a6vjPkzcRjrsXmniFsm0dg": true]], format: .binary, options: 0)
        let record = try A6FirstBoot.install(system: system, data: data, activationPlan: plan)
        #expect((try JSONSerialization.jsonObject(with: record) as? [String: Any])?["mode"] as? String == "first-normal-boot")
        #expect(try A6FirstBoot.preparedPaths(in: HFSPlusVolume(system)) == A6FirstBoot.components.map(\.path))
        let before = try HFSPlusVolume(data)
        let metadata = try A6FirstBoot.groups.map { try before.contents(before.record(at: A6FirstBoot.groupRoot + $0 + "/" + A6FirstBoot.metadataName)) }
        _ = try A6FirstBoot.install(system: system, data: data, activationPlan: plan)
        let after = try HFSPlusVolume(data)
        for (group, bytes) in zip(A6FirstBoot.groups, metadata) {
            let path = A6FirstBoot.groupRoot + group + "/" + A6FirstBoot.metadataName
            #expect(try after.contents(after.record(at: path)) == bytes) // no identity churn
        }
        let partial = try HFSPlusWriter(system)
        try partial.put(fixtures()[1], at: A6FirstBoot.components[1].path, mode: 0o755)
        try partial.close()
        #expect(throws: FirmwareError.self) { try A6FirstBoot.preparedPaths(in: HFSPlusVolume(system)) }
    }
}
