import Foundation
import Darwin

/// Disk operations shared by the controller and the device-free regression check.
nonisolated enum DeviceStateStorage {
    /// Only call after the native VM has exited and released its files.
    /// `snapshots`: saved-state files older builds wrote (and their .meta), swept with the overlay.
    /// `owner` is the device being erased; every path must pass checkRemovable.
    static func erase(overlay: URL, snapshots: [URL], state: URL, owner: UUID?) throws {
        let fm = FileManager.default
        let paths = snapshots.flatMap { [$0, $0.appendingPathExtension("meta")] } + [overlay]
        for path in paths { try checkRemovable(path, state: state, owner: owner) }
        for path in paths where fm.fileExists(atPath: path.path) {
            try fm.removeItem(at: path)
        }
    }

    // MARK: - Removal

    /// A path with symlinks resolved as far as it exists (the rest appended
    /// as written), so `..` and links can't point a removal elsewhere.
    static func canonicalPath(_ url: URL) -> String {
        var head = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: head.path), head.pathComponents.count > 1 {
            tail.insert(head.lastPathComponent, at: 0)
            head.deleteLastPathComponent()
        }
        let resolved = realpath(head.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? head.path
        return tail.reduce(URL(fileURLWithPath: resolved)) { $0.appendingPathComponent($1) }.path
    }

    /// The record directories under Devices/ (a UUID name with a device.json), but `owner`'s.
    private static func otherRecordDirectories(state: URL, owner: UUID?) -> [String] {
        let devices = state.appendingPathComponent("Devices", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: devices.path)) ?? []).filter { name in
            UUID(uuidString: name) != nil && UUID(uuidString: name) != owner
                && FileManager.default.fileExists(atPath: devices.appendingPathComponent("\(name)/device.json").path)
        }.map { canonicalPath(devices.appendingPathComponent($0)) }
    }

    /// Erase and Delete only remove paths strictly inside the state root that
    /// are neither the root, Devices/, nor inside another record's directory.
    /// A damaged or hand-edited record can't reach anything else.
    static func checkRemovable(_ url: URL, state: URL, owner: UUID?) throws {
        let root = canonicalPath(state), path = canonicalPath(url)
        let devices = root + "/Devices"
        let others = otherRecordDirectories(state: state, owner: owner)
        guard path.hasPrefix(root + "/"), path != devices,
              !others.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey:
                "Light Touch didn’t remove \(url.path): it isn’t this device’s storage."])
        }
    }

    /// Removes a tree even where a preparer made it read-only (the NAND is
    /// chmod a-w) or lockBase made it immutable: on a refusal every directory
    /// in it is unlocked and made writable, then the removal is tried once
    /// more and its error thrown.
    static func removeTree(_ url: URL) throws {
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: url.path)) != nil else { return }
        if (try? fm.removeItem(at: url)) != nil { return }
        for directory in directories(under: url) {
            chflags(directory.path, 0)
            chmod(directory.path, 0o700)
        }
        try fm.removeItem(at: url)
    }

    /// `url` and every directory below it (symlinks not followed).
    private static func directories(under url: URL) -> [URL] {
        var directories = [url]
        if let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            for case let item as URL in walk {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true, values?.isSymbolicLink != true { directories.append(item) }
            }
        }
        return directories
    }

    /// A published base is immutable (chflags uchg on it and every directory
    /// in it): the Finder refuses to delete, rename or add to it with a system
    /// dialog, and nothing here writes into it. Idempotent; removeTree undoes it.
    static func lockBase(_ base: URL) {
        for directory in directories(under: base) { chflags(directory.path, UInt32(UF_IMMUTABLE)) }
    }

    /// Delete Device: Devices/<uuid> is renamed to Devices/.deleting-<uuid>
    /// first, so a crash mid-removal never leaves a half device that loads
    /// (DeviceInstance.all skips the name); the launch sweep finishes it.
    static func removeDevice(_ id: UUID, state: URL) throws {
        let devices = state.appendingPathComponent("Devices", isDirectory: true)
        let directory = devices.appendingPathComponent(id.uuidString, isDirectory: true)
        let doomed = devices.appendingPathComponent(".deleting-\(id.uuidString)", isDirectory: true)
        try checkRemovable(directory, state: state, owner: id)
        if FileManager.default.fileExists(atPath: directory.path) {
            try removeTree(doomed)
            guard rename(directory.path, doomed.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        try removeTree(doomed)
    }

    /// Launch (under the app lock): finish deletes a crash interrupted.
    static func sweepDeleting(state: URL) {
        let devices = state.appendingPathComponent("Devices", isDirectory: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: devices.path)) ?? []
        where name.hasPrefix(".deleting-") {
            try? removeTree(devices.appendingPathComponent(name))
        }
    }

    /// Publish a complete private NOR copy beside the NAND pages. Keeping it
    /// inside the overlay also includes it in erase and snapshot freshness.
    static func writableNOR(base: URL, overlay: URL) throws -> URL {
        let fm = FileManager.default
        let destination = overlay.appendingPathComponent("nor.bin")
        try fm.createDirectory(at: overlay, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: destination.path) {
            let staged = overlay.appendingPathComponent(".nor-\(UUID().uuidString).tmp")
            defer { try? fm.removeItem(at: staged) }
            try fm.copyItem(at: base, to: staged)
            let size = try fm.attributesOfItem(atPath: staged.path)[.size] as? NSNumber
            guard size?.intValue == 1_048_576 else { throw CocoaError(.fileReadCorruptFile) }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
            let handle = try FileHandle(forWritingTo: staged)
            defer { try? handle.close() }
            try handle.synchronize()
            try fm.moveItem(at: staged, to: destination)
        }
        let attributes = try fm.attributesOfItem(atPath: destination.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue == 1_048_576 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return destination
    }

    /// A copy-on-write overlay is only valid over the exact base it was made
    /// from: over a rebuilt base its dirty pages mix with different clean ones
    /// (seen as an unactivated iPad after a golden rebuild). The overlay
    /// carries the base's identity; false means it belongs to another base,
    /// or predates pinning, and must not be booted. An empty or missing
    /// overlay is adopted by the base.
    static func pinOverlay(_ overlay: URL, toBase identity: String) throws -> Bool {
        let fm = FileManager.default
        let stamp = overlay.appendingPathComponent(".base-identity")
        let contents = (try? fm.contentsOfDirectory(atPath: overlay.path)) ?? []
        if contents.isEmpty {
            try fm.createDirectory(at: overlay, withIntermediateDirectories: true)
            try Data(identity.utf8).write(to: stamp, options: .atomic)
            return true
        }
        return (try? String(contentsOf: stamp, encoding: .utf8)) == identity
    }
}
