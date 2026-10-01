import Foundation

@main struct ManagedBootPaths {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let state = root.appendingPathComponent("state"), logs = root.appendingPathComponent("logs")
        let owner = UUID(), other = UUID()
        func record(_ id: UUID) -> DeviceInstance {
            let prefix = "Devices/\(id.uuidString)"
            return DeviceInstance(id: id, name: "fixture", board: "n72ap", firmware: "n72ap-7E18", created: DeviceInstance.now,
                base: .init(kind: .prepared, path: prefix + "/base"),
                storage: .init(key: "fixture", overlay: prefix + "/overlay", writableNOR: prefix + "/nor.bin",
                    snapshot: prefix + "/snapshot", usbmuxConf: prefix + "/usbmuxd-conf"))
        }
        let ordinary = record(owner), otherRecord = record(other)
        try ordinary.write(state: state); try otherRecord.write(state: state)
        let own = ordinary.paths(state: state, logs: logs).directory
        try fm.createDirectory(at: own.appendingPathComponent("base"), withIntermediateDirectories: true)
        try Data("base-sentinel".utf8).write(to: own.appendingPathComponent("base/sentinel"))
        let external = root.appendingPathComponent("external-base")
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("external-sentinel".utf8).write(to: external.appendingPathComponent("sentinel"))
        let originalRecord = try Data(contentsOf: own.appendingPathComponent("device.json"))
        func validate(_ i: DeviceInstance, in selectedState: URL = state) throws {
            let p = i.paths(state: selectedState, logs: logs)
            try DeviceStateStorage.checkBootPaths(base: p.base,
                mutable: [p.overlay, p.snapshot, p.snapshotMeta, p.snapshotTmp, p.snapshotBad, p.usbmuxConf, p.work, p.lease]
                    + [p.writableNOR].compactMap { $0 }, state: selectedState, owner: i.id)
        }
        func refused(_ label: String, _ i: DeviceInstance) throws {
            do { try validate(i); preconditionFailure("accepted \(label)") }
            catch is CocoaError {}
            // Read-only refusal: no lease/helper work, private NOR or overlay published.
            precondition(!fm.fileExists(atPath: own.appendingPathComponent("work").path))
            precondition(!fm.fileExists(atPath: own.appendingPathComponent("overlay").path))
            precondition(!fm.fileExists(atPath: own.appendingPathComponent("nor.bin").path))
            let recordAfter = try Data(contentsOf: own.appendingPathComponent("device.json"))
            let baseAfter = try String(contentsOf: own.appendingPathComponent("base/sentinel"), encoding: .utf8)
            let externalAfter = try String(contentsOf: external.appendingPathComponent("sentinel"), encoding: .utf8)
            precondition(recordAfter == originalRecord && baseAfter == "base-sentinel" && externalAfter == "external-sentinel")
            print("PASS refused: \(label), no storage mutation")
        }
        try validate(ordinary)
        var development = ordinary; development.base.path = external.path
        try validate(development)
        var absolute = ordinary
        absolute.storage.overlay = own.appendingPathComponent("overlay").path
        absolute.storage.writableNOR = own.appendingPathComponent("nor.bin").path
        absolute.storage.snapshot = own.appendingPathComponent("snapshot").path
        absolute.storage.usbmuxConf = own.appendingPathComponent("usbmuxd-conf").path
        try validate(absolute)
        // StorageGeneration records may use relative or absolute generation descendants.
        var generation = ordinary
        let relative = "Devices/\(owner.uuidString)/generations/\(UUID().uuidString)"
        generation.base.path = relative + "/base"; generation.storage.overlay = relative + "/overlay"
        generation.storage.writableNOR = relative + "/nor.bin"; generation.storage.snapshot = relative + "/snapshot"
        try validate(generation)
        generation.base.path = DeviceInstance.url(generation.base.path, state: state).path
        generation.storage.overlay = DeviceInstance.url(generation.storage.overlay, state: state).path
        generation.storage.writableNOR = DeviceInstance.url(generation.storage.writableNOR!, state: state).path
        generation.storage.snapshot = DeviceInstance.url(generation.storage.snapshot, state: state).path
        try validate(generation)
        let aliasState = root.appendingPathComponent("state-link")
        try fm.createSymbolicLink(at: aliasState, withDestinationURL: state)
        try validate(ordinary, in: aliasState)
        let moved = root.appendingPathComponent("moved-state")
        try fm.copyItem(at: state, to: moved)
        try validate(ordinary, in: moved)
        print("PASS accepted: published, external read-only base, absolute own paths, relative/absolute generations, moved state and root link")

        var bad = ordinary; bad.storage.overlay = "../outside-overlay"
        try refused("relative escape", bad)
        bad = ordinary; bad.storage.writableNOR = root.appendingPathComponent("outside-nor").path
        try refused("external mutable NOR", bad)
        bad = ordinary; bad.storage.overlay = otherRecord.storage.overlay
        try refused("other-record/shared overlay", bad)
        bad = ordinary; bad.storage.snapshot = "Devices/\(owner.uuidString)"
        try refused("whole record as snapshot", bad)
        bad = ordinary; bad.storage.overlay = "Devices/\(owner.uuidString)/base/overlay"
        try refused("mutable under base", bad)
        bad = ordinary; bad.base.path = ordinary.storage.overlay + "/nested-base"
        try refused("base under mutable", bad)
        let escaping = own.appendingPathComponent("escape-link")
        try fm.createSymbolicLink(at: escaping, withDestinationURL: external)
        bad = ordinary; bad.storage.overlay = "Devices/\(owner.uuidString)/escape-link/not-yet-created"
        try refused("existing link with missing suffix", bad)
        bad = ordinary; bad.storage.overlay = "Devices/\(owner.uuidString)/escape-link/../outside-pages"
        try refused("parent traversal after symlink", bad)
        let dangling = own.appendingPathComponent("dangling")
        try fm.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("missing-external"))
        bad = ordinary; bad.storage.overlay = dangling.appendingPathComponent("pages").path
        try refused("dangling link with missing suffix", bad)
        let snapshotMeta = own.appendingPathComponent("snapshot.meta")
        try fm.createSymbolicLink(at: snapshotMeta, withDestinationURL: own.appendingPathComponent("base/sentinel"))
        try refused("snapshot metadata aliases base", ordinary)
        try fm.removeItem(at: snapshotMeta)
        let work = own.appendingPathComponent("work")
        try fm.createSymbolicLink(at: work, withDestinationURL: external)
        do { try validate(ordinary); preconditionFailure("accepted external work/lease root") } catch is CocoaError {}
        precondition(!fm.fileExists(atPath: external.appendingPathComponent("lease").path))
        try fm.removeItem(at: work)
        let recordAliasID = UUID(), recordAlias = DeviceInstance.directory(recordAliasID, state: state)
        try fm.createSymbolicLink(at: recordAlias, withDestinationURL: own)
        try refused("other record directory alias", ordinary)
        try fm.removeItem(at: recordAlias)
        // Resolvable aliases inside owned storage are allowed; no blanket symlink ban.
        let privateStorage = own.appendingPathComponent("private")
        try fm.createDirectory(at: privateStorage, withIntermediateDirectories: true)
        let privateLink = own.appendingPathComponent("private-link")
        try fm.createSymbolicLink(at: privateLink, withDestinationURL: privateStorage)
        bad = ordinary; bad.storage.overlay = privateLink.appendingPathComponent("pages").path
        try validate(bad)
        print("PASS accepted: resolvable private alias; no helper or guest launched")
    }
}
