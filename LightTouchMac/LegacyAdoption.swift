// Adopts the single-device state of earlier builds, in place.
//
// Before the device library, EmulatorController derived every state path from
// a key: `nandrw-<key>`, `snapshot-<key>`, `.reset-<key>`, with the key taken
// from the files root and NAND name (development), the packed image's active
// pointer (a packaged app), or the iPad NAND path. That derivation lives here
// now, verbatim, and runs only to write a device.json. The record freezes the
// key and the paths it resolved to, so nothing is renamed or moved and a later
// change to derivation cannot hand anyone a factory-fresh device.
//
// When State/Devices is absent every device found is adopted at once (the
// iPod, and the iPad when its image or overlay is present). Afterwards a
// development launch (LTM_FILES, LIGHTTOUCH_DEVICE) that names state no
// record covers adopts it the same way.

import Foundation

nonisolated enum LegacyAdoption {

    /// The launch-option paths the old keys were derived from.
    struct Inputs: Sendable {
        var filesRoot: String
        /// Resolved: nand-current is already its target's name.
        var nand: String
        var nandImage: String
        var packedNAND: String
        var ipad1NAND: String

        var packedManifest: URL { URL(fileURLWithPath: packedNAND + ".sha256") }
        /// A packaged app ships only the blob; a raw directory wins.
        var isPacked: Bool {
            let fm = FileManager.default
            return !fm.fileExists(atPath: nandImage) && fm.fileExists(atPath: packedManifest.path)
        }
    }

    struct Resolution: Sendable {
        var instance: DeviceInstance
        /// The packaged iPod's selected base, as DeviceStateStorage.packedImage returns it.
        var packedImage: DeviceStateStorage.PackedImage?
        /// True when an existing device is kept on an older bundled base.
        var retained = false
    }

    /// UserDefaults names that became per-device ("deviceNotice.<uuid>").
    static let perDeviceDefaults = ["deviceNotice", "motionPose"]

    // MARK: - Keys (moved verbatim from EmulatorController)

    /// Distinguishes two base images that happen to share a directory name.
    /// Keying on the name alone meant `LTM_FILES=/a` and `LTM_FILES=/b`, both
    /// holding a "nand-ultimate", shared one copy-on-write overlay and one
    /// snapshot — image B read through image A's overlay, and a snapshot taken
    /// on A restored onto B.
    static func legacyImageKey(filesRoot root: String, nand: String) -> String {
        guard !root.isEmpty else { return nand }
        // Short, stable, and readable enough to identify in Finder.
        var hash: UInt64 = 5381
        for byte in root.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return "\(nand)-\(String(hash, radix: 36))"
    }

    static func iPadKey(nandPath: String) -> String {
        var hash: UInt64 = 5381
        for byte in nandPath.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return "ipad1-\((nandPath as NSString).lastPathComponent)-\(String(hash, radix: 36))"
    }

    /// migrateStateNames, as path selection instead of a rename: state written
    /// before the key included the files root (`nandrw-<nand>`) is used where
    /// it is when the keyed name is absent. Content-keyed (packed) images never
    /// adopt another image's overlay.
    private static func legacyName(_ prefix: String, key: String, nand: String,
                                   packedKey: String?, legacyKey: String, state: URL) -> String {
        let new = "\(prefix)\(key)", old = "\(prefix)\(nand)"
        let fm = FileManager.default
        guard packedKey == nil || packedKey == legacyKey, old != new,
              fm.fileExists(atPath: state.appendingPathComponent(old).path),
              !fm.fileExists(atPath: state.appendingPathComponent(new).path) else { return new }
        return old
    }

    // MARK: - Resolution

    /// The instance a launch with these inputs runs, adopting legacy state
    /// when no record covers it. Idempotent.
    static func resolve(_ inputs: Inputs, profile: DeviceProfile, state: URL,
                        defaults: UserDefaults = .standard) throws -> Resolution {
        let devices = state.appendingPathComponent("Devices", isDirectory: true)
        if !FileManager.default.fileExists(atPath: devices.path) {
            try adoptAll(inputs, profile: profile, state: state, defaults: defaults)
        }
        let records = DeviceInstance.all(state: state)
        if profile == .iPad1 {
            let key = iPadKey(nandPath: inputs.ipad1NAND)
            if let found = records.first(where: { $0.board == profile.boardID && $0.base.kind == .development && $0.storage.key == key }) {
                return Resolution(instance: found)
            }
            let adopted = try iPad(inputs, state: state, records: records, staging: nil)
            try adopted.write(state: state)
            return Resolution(instance: adopted)
        }
        if inputs.isPacked {
            let selected = try DeviceStateStorage.packedImage(
                state: state, nand: inputs.nand,
                legacyKey: legacyImageKey(filesRoot: inputs.filesRoot, nand: inputs.nand),
                manifest: inputs.packedManifest)
            if var found = records.first(where: { $0.board == profile.boardID && $0.base.kind == .legacyBundled && $0.legacy?.nand == inputs.nand }) {
                // The active pointer is the base's authority: Erase All
                // Content and Settings repoints it at the bundled image, and
                // the device's key and paths follow it there.
                if found.storage.key != selected.image.key {
                    let fresh = try iPod(inputs, packed: selected.image, id: found.id, state: state,
                                         records: records.filter { $0.id != found.id }, defaults: nil)
                    found.base = fresh.base
                    found.storage.key = fresh.storage.key
                    found.storage.overlay = fresh.storage.overlay
                    found.storage.writableNOR = fresh.storage.writableNOR
                    found.storage.snapshot = fresh.storage.snapshot
                    found.storage.resetMarker = fresh.storage.resetMarker
                    try found.write(state: state)
                }
                return Resolution(instance: found, packedImage: selected.image, retained: selected.retained)
            }
            let adopted = try iPod(inputs, packed: selected.image, id: UUID(), state: state, records: records, defaults: defaults)
            try adopted.write(state: state)
            return Resolution(instance: adopted, packedImage: selected.image, retained: selected.retained)
        }
        let key = legacyImageKey(filesRoot: inputs.filesRoot, nand: inputs.nand)
        if let found = records.first(where: { $0.board == profile.boardID && $0.base.kind == .development && $0.storage.key == key }) {
            return Resolution(instance: found)
        }
        let adopted = try iPod(inputs, packed: nil, id: UUID(), state: state, records: records, defaults: defaults)
        try adopted.write(state: state)
        return Resolution(instance: adopted)
    }

    /// The record a failed resolution would have used (the old code's
    /// `packedImage == nil` paths): never written, only so erase and status
    /// code have paths while the device reports the failure.
    static func unresolved(_ inputs: Inputs, profile: DeviceProfile, state: URL) -> DeviceInstance {
        // With no other records nothing is copied, so neither can throw.
        profile == .iPad1
            ? try! iPad(inputs, state: state, records: [], staging: nil)
            : try! iPod(inputs, packed: nil, id: UUID(), state: state, records: [], defaults: nil)
    }

    /// First run of a library-aware build. Builds every record in a staging
    /// directory and publishes them with one rename, so an interrupted run
    /// leaves no Devices/ and simply runs again.
    static func adoptAll(_ inputs: Inputs, profile: DeviceProfile, state: URL,
                         defaults: UserDefaults = .standard) throws {
        let fm = FileManager.default
        let staging = state.appendingPathComponent(".Devices-adopting-\(UUID().uuidString)", isDirectory: true)
        try StorageLocations.privateDirectory(staging)
        defer { try? fm.removeItem(at: staging) }
        var records: [DeviceInstance] = []
        var inherited: [(String, Any, String)] = []
        do {
            var selected: DeviceStateStorage.PackedImage?
            if inputs.isPacked {
                selected = try DeviceStateStorage.packedImage(
                    state: state, nand: inputs.nand,
                    legacyKey: legacyImageKey(filesRoot: inputs.filesRoot, nand: inputs.nand),
                    manifest: inputs.packedManifest).image
            }
            let iPod = try iPod(inputs, packed: selected, id: UUID(), state: state, records: records, defaults: nil)
            records.append(iPod)
            for name in perDeviceDefaults {
                if let value = defaults.object(forKey: name) { inherited.append((name, value, iPod.defaultsKey(name))) }
            }
        } catch {
            // An iPod whose base can't be attributed keeps failing at launch,
            // exactly as before; it must not block adopting the iPad.
            logEvent("adoption: iPod not adopted: \(error.localizedDescription)")
        }
        let key = iPadKey(nandPath: inputs.ipad1NAND)
        if profile == .iPad1 || fm.fileExists(atPath: inputs.ipad1NAND)
            || fm.fileExists(atPath: state.appendingPathComponent("nandrw-\(key)").path) {
            records.append(try iPad(inputs, state: state, records: records, staging: staging))
        }
        for record in records {
            let directory = staging.appendingPathComponent(record.id.uuidString, isDirectory: true)
            try StorageLocations.privateDirectory(directory)
            try DeviceInstance.encoder.encode(record)
                .write(to: directory.appendingPathComponent(DeviceInstance.recordName), options: .atomic)
        }
        let devices = state.appendingPathComponent("Devices", isDirectory: true)
        // rename(2) onto a missing name: another process that won the race
        // leaves our copy to be discarded rather than merged.
        guard rename(staging.path, devices.path) == 0 else {
            if errno == ENOTEMPTY || errno == EEXIST { return }
            throw StorageLocations.posixError()
        }
        for (name, value, key) in inherited where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            logEvent("adoption: \(name) is now \(key)")
        }
        logEvent("adoption: adopted \(records.map { "\($0.firmware) as \($0.id)" }.joined(separator: ", "))")
    }

    // MARK: - Records

    private static let legacyConf = "work/usbmuxd-conf"

    /// usbmuxd's conf (host identity and pairing records) belongs to the
    /// first device adopted. Any later one gets a copy, so its pairing
    /// survives but two daemons never write one directory.
    private static func usbmuxConf(for id: UUID, state: URL, records: [DeviceInstance],
                                   staging: URL?) throws -> String {
        guard records.contains(where: { $0.storage.usbmuxConf == legacyConf }) else { return legacyConf }
        let fm = FileManager.default
        let relative = "Devices/\(id.uuidString)/usbmuxd-conf"
        let destination = (staging?.appendingPathComponent(id.uuidString, isDirectory: true)
            ?? DeviceInstance.directory(id, state: state)).appendingPathComponent("usbmuxd-conf", isDirectory: true)
        let source = state.appendingPathComponent(legacyConf, isDirectory: true)
        if fm.fileExists(atPath: source.path), !fm.fileExists(atPath: destination.path) {
            try StorageLocations.privateDirectory(destination.deletingLastPathComponent())
            try fm.copyItem(at: source, to: destination)
        }
        return relative
    }

    private static func iPod(_ inputs: Inputs, packed: DeviceStateStorage.PackedImage?, id: UUID,
                             state: URL, records: [DeviceInstance], defaults: UserDefaults?) throws -> DeviceInstance {
        let legacyKey = legacyImageKey(filesRoot: inputs.filesRoot, nand: inputs.nand)
        let key = packed?.key ?? legacyKey
        func name(_ prefix: String) -> String {
            legacyName(prefix, key: key, nand: inputs.nand, packedKey: packed?.key, legacyKey: legacyKey, state: state)
        }
        let overlay = name("nandrw-")
        let record = DeviceInstance(
            id: id, name: DeviceProfile.iPodTouch2G.displayName, board: DeviceProfile.iPodTouch2G.boardID,
            firmware: FirmwareCatalog.legacyIPodID, created: DeviceInstance.now,
            base: packed.map { .init(kind: .legacyBundled, path: $0.directory) }
                ?? .init(kind: .development, path: inputs.nandImage),
            storage: .init(key: key, overlay: overlay, writableNOR: "\(overlay)/nor.bin",
                           snapshot: name("snapshot-"), resetMarker: name(".reset-"),
                           usbmuxConf: try usbmuxConf(for: id, state: state, records: records, staging: nil)),
            legacy: .init(filesRoot: inputs.filesRoot, nand: inputs.nand,
                          pointer: packed.map { _ in "device/active-\(inputs.nand).json" }))
        // A later-adopted iPod inherits the single-device settings only when
        // it is the first iPod the library has.
        if let defaults, !records.contains(where: { $0.board == record.board }) {
            for name in perDeviceDefaults where defaults.object(forKey: record.defaultsKey(name)) == nil {
                if let value = defaults.object(forKey: name) { defaults.set(value, forKey: record.defaultsKey(name)) }
            }
        }
        return record
    }

    private static func iPad(_ inputs: Inputs, state: URL, records: [DeviceInstance], staging: URL?) throws -> DeviceInstance {
        let key = iPadKey(nandPath: inputs.ipad1NAND)
        let id = UUID()
        return DeviceInstance(
            id: id, name: DeviceProfile.iPad1.displayName, board: DeviceProfile.iPad1.boardID,
            firmware: FirmwareCatalog.developmentIPadID, created: DeviceInstance.now,
            base: .init(kind: .development, path: inputs.ipad1NAND),
            storage: .init(key: key, overlay: "nandrw-\(key)", writableNOR: nil, snapshot: "snapshot-\(key)",
                           resetMarker: ".reset-\(key)",
                           usbmuxConf: try usbmuxConf(for: id, state: state, records: records, staging: staging)),
            legacy: .init(filesRoot: inputs.filesRoot, nand: (inputs.ipad1NAND as NSString).lastPathComponent, pointer: nil))
    }
}
