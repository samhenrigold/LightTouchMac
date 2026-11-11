import Foundation

/// Retain the qualified preparation records through 14G61's first migration.
/// The native restore worker still generates the capability cache, and all
/// other native migrations run normally. No userland sealing boot is needed.
enum A6FirstBoot {
    struct Component: Sendable {
        let path: String, originalSHA256: String, preparedSHA256: String
        let edits: [(offset: Int, original: Data, replacement: Data)]
    }

    static let components = [
        Component(
            path: "System/Library/DataClassMigrators/MobileGestaltMigrator.migrator/MobileGestaltMigrator",
            originalSHA256: "c849fe475fdf8209e0bafe1e0ae7be96cb1686bdeea2721ca35af54b343a45a1",
            preparedSHA256: "52b2a6f670e515bd70d0a9222fed7f1afd7e76c20561dc1de1d3999c4a70e695",
            edits: [(0x3f3c, Data([0x00, 0xf0, 0x5e, 0xe8]), Data([0x00, 0xbf, 0x00, 0xbf]))]),
        Component(
            path: "System/Library/DataClassMigrators/MCProfile.migrator/MCProfile",
            originalSHA256: "ed767fe8c1ec39657e9d5332b9f65592ecf87294f1efd1bc7d7d69a00be8e951",
            preparedSHA256: "fd32b295887e8bd8fc93d965a7975a2fe73255903ab005e0678b6539a560be9d",
            edits: [
                (0x3672, Data([0x00, 0xf0, 0xbc, 0xec]), Data([0x01, 0x20, 0x00, 0xbf])),
                (0x36aa, Data([0x00, 0xf0, 0xa0, 0xec]), Data([0x01, 0x20, 0x00, 0xbf]))
            ])
    ]
    static let groups = ["systemgroup.com.apple.mobilegestaltcache", "systemgroup.com.apple.configurationprofiles"]
    static let groupRoot = "containers/Shared/SystemGroup/"
    static let metadataName = ".com.apple.mobile_container_manager.metadata.plist"
    static let cloudPath = groupRoot + groups[1] + "/Library/ConfigurationProfiles/CloudConfigurationDetails.plist"

    private static func invalid(_ reason: String) -> FirmwareError {
        FirmwareError(.unsupported, "N42 first boot: " + reason)
    }

    static func prepare(_ original: Data, component: Component) throws -> Data {
        let hash = Preparer.sha256(original)
        if hash == component.preparedSHA256 { return original }
        guard hash == component.originalSHA256 else { throw invalid("unrecognized " + component.path) }
        var prepared = original
        for edit in component.edits {
            let range = edit.offset..<(edit.offset + edit.original.count)
            guard range.upperBound <= original.count, original.subdata(in: range) == edit.original else {
                throw invalid("migration call layout differs")
            }
            prepared.replaceSubrange(range, with: edit.replacement)
        }
        prepared = try Activation.signed(prepared)
        guard Preparer.sha256(prepared) == component.preparedSHA256 else { throw invalid("signed output differs") }
        _ = try A6GuestAssets.verifiedCodeDirectories(prepared)
        return prepared
    }

    static func containerMetadata(_ identifier: String, uuid: UUID = UUID()) throws -> [String: Any] {
        guard groups.contains(identifier) else { throw invalid("unqualified SystemGroup") }
        // Source-generated schema and a fresh identity; never import an Apple
        // metadata file or an identity from a previously initialized guest.
        return [
            "MCMMetadataIdentifier": identifier, "MCMMetadataUUID": uuid.uuidString,
            "MCMMetadataPersona": 499, "MCMMetadataContentClass": 13
        ]
    }

    static func validMetadata(_ metadata: [String: Any], identifier: String) -> Bool {
        groups.contains(identifier) && metadata["MCMMetadataIdentifier"] as? String == identifier
            && metadata["MCMMetadataPersona"] as? Int == 499
            && metadata["MCMMetadataContentClass"] as? Int == 13
            && (metadata["MCMMetadataUUID"] as? String).flatMap(UUID.init(uuidString:)) != nil
    }

    /// Inventory only the exact prepared components, retaining all native
    /// trusted identities. A partially prepared pair is never accepted.
    static func preparedPaths(in volume: HFSPlusVolume) throws -> [String] {
        var paths: [String] = []
        for component in components {
            let hash = Preparer.sha256(try volume.contents(volume.record(at: component.path)))
            if hash == component.preparedSHA256 {
                paths.append(component.path)
            } else if hash != component.originalSHA256 {
                throw invalid("migration component differs")
            }
        }
        guard paths.isEmpty || paths.count == components.count else {
            throw invalid("incomplete migration preparation")
        }
        return paths
    }

    static func install(system: URL, data: URL, activationPlan: Data) throws -> Data {
        let s = try HFSPlusWriter(system)
        let d = try HFSPlusWriter(data)
        s.owner = (0, 0)
        d.owner = (0, 0)
        do {
            guard
                s.plist(at: "System/Library/CoreServices/SystemVersion.plist")?["ProductBuildVersion"] as? String
                    == "14G61",
                let plan = try PropertyListSerialization.propertyList(from: activationPlan, format: nil)
                    as? [String: Any],
                plan["Build"] as? String == "14G61",
                (plan["Overrides"] as? [String: Any])?["a6vjPkzcRjrsXmniFsm0dg"] as? Bool == true,
                d.plist(at: cloudPath)?["CloudConfigurationUIComplete"] as? Bool == true,
                !d.exists("keybags/systembag.kb"), !s.exists(A6Sealing.job), !s.exists(A6Sealing.executable)
            else {
                throw invalid("requires fresh 14G61 volumes and the existing activation/setup plan")
            }
            // Validate every input before changing either disposable volume.
            let originals = try components.map { try s.contents(at: $0.path) }
            let prepared = try zip(components, originals).map { try prepare($0.1, component: $0.0) }
            let metadata = try groups.map { identifier -> Data in
                let path = groupRoot + identifier + "/" + metadataName
                if d.exists(path) {
                    guard let existing = d.plist(at: path) as? [String: Any],
                        validMetadata(existing, identifier: identifier)
                    else {
                        throw invalid("existing SystemGroup metadata differs")
                    }
                    return try d.contents(at: path)
                }
                return try PropertyListSerialization.data(
                    fromPropertyList: containerMetadata(identifier), format: .binary, options: 0)
            }
            for (component, bytes) in zip(components, prepared) { try s.put(bytes, at: component.path, mode: 0o755) }
            for (identifier, bytes) in zip(groups, metadata) {
                let path = groupRoot + identifier
                try d.makeDirectory(path, mode: 0o755)
                try d.put(bytes, at: path + "/" + metadataName, mode: 0o644)
            }
            try s.close()
            try d.close()
            return try JSONSerialization.data(
                withJSONObject: [
                    "schema": 1, "build": "14G61", "mode": "first-normal-boot",
                    "components": zip(components, originals).map {
                        ["path": $0.0.path, "inputSHA256": Preparer.sha256($0.1), "outputSHA256": $0.0.preparedSHA256]
                    },
                    "containers": groups
                ], options: [.prettyPrinted, .sortedKeys])
        } catch {
            try? s.close()
            try? d.close()
            throw error
        }
    }
}
