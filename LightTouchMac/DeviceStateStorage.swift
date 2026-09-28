import Foundation
import Darwin
import CryptoKit

/// Disk operations shared by the controller and the device-free regression check.
nonisolated enum DeviceStateStorage {
    /// Only call after the native VM has exited and released its files.
    /// `snapshots`: saved-state files older builds wrote (and their .meta), swept with the overlay.
    /// `owner` is the device being erased; every path must pass checkRemovable.
    static func erase(overlay: URL, snapshots: [URL], legacyMarker: URL, state: URL, owner: UUID?) throws {
        let fm = FileManager.default
        let paths = snapshots.flatMap { [$0, $0.appendingPathExtension("meta")] }
            + [overlay, legacyMarker]
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

    /// Packed images use their content manifest. Development images also record
    /// every page's identity/mtime so rebaking a directory invalidates old RAM.
    static func developmentImageIdentity(at root: URL, key: String) throws -> String {
        let fm = FileManager.default
        var failure: Error?
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                       errorHandler: { _, error in failure = error; return false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        var records = [key]
        for case let url as URL in files {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard let date = attributes[.modificationDate] as? Date,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let size = attributes[.size] as? NSNumber else {
                throw CocoaError(.fileReadCorruptFile)
            }
            records.append("\(url.path.dropFirst(root.path.count))\t\(inode)\t\(size)\t\(date.timeIntervalSince1970)")
        }
        if let failure { throw failure }
        guard records.count > 1 else { throw CocoaError(.fileReadCorruptFile) }
        return SHA256.hash(data: Data(records.sorted().joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
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

    struct PackedImage: Codable, Equatable {
        let key: String
        let directory: String
    }

    /// Keep an existing device on its original base until an explicit reset.
    /// The active pointer is independent of the app's installation path.
    static func packedImage(state: URL, nand: String, legacyKey: String,
                            manifest: URL) throws -> (image: PackedImage, retained: Bool) {
        let fm = FileManager.default
        let latest = try bundledImage(nand: nand, manifest: manifest)
        let pointer = state.appendingPathComponent("device/active-\(nand).json")
        var active: PackedImage
        var recorded: PackedImage?
        if fm.fileExists(atPath: pointer.path) {
            active = try JSONDecoder().decode(PackedImage.self, from: Data(contentsOf: pointer))
            recorded = active
        } else if fm.fileExists(atPath: state.appendingPathComponent("device/\(nand)").path) {
            let names = try fm.contentsOfDirectory(atPath: state.path)
            let candidates = names.filter { $0 == "nandrw-\(nand)" || $0.hasPrefix("nandrw-\(nand)-") }
            let key: String
            if candidates.contains("nandrw-\(legacyKey)") {
                key = legacyKey
            } else if candidates.count == 1 {
                key = String(candidates[0].dropFirst("nandrw-".count))
            } else if candidates.isEmpty {
                key = legacyKey
            } else {
                // Multiple historical roots cannot be attributed to this base.
                throw CocoaError(.fileReadCorruptFile)
            }
            active = PackedImage(key: key, directory: "device/\(nand)")
        } else {
            // Never silently abandon an overlay whose original base is missing.
            for key in [legacyKey, nand] where fm.fileExists(atPath: state.appendingPathComponent("nandrw-\(key)").path) {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey:
                    "The existing device overlay has no extracted base image. Restore its device/\(nand) directory before launching."])
            }
            active = latest
        }
        if active != latest, !fm.fileExists(atPath: state.appendingPathComponent(active.directory).path) {
            throw CocoaError(.fileNoSuchFile)
        }
        // Rewriting an unchanged pointer only churns its inode.
        if recorded != active {
            try fm.createDirectory(at: pointer.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(active).write(to: pointer, options: .atomic)
        }
        return (active, active != latest)
    }
    private static func bundledImage(nand: String, manifest: URL) throws -> PackedImage {
        let digest = try String(contentsOf: manifest, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard digest.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return PackedImage(key: "\(nand)-\(digest)", directory: "device/\(nand)-\(digest)")
    }

    /// Explicit erase adopts the current bundled base only after removing any
    /// user overlay previously associated with it. Startup never consumes an
    /// erase marker or silently switches an existing device to a new base.
    /// `owner` is the erased device: its record follows the pointer on its
    /// next resolve, so the base it names now doesn't keep that base alive.
    static func adoptBundledImageAfterErase(state: URL, nand: String, manifest: URL, owner: UUID?) throws {
        let latest = try bundledImage(nand: nand, manifest: manifest)
        let snapshot = state.appendingPathComponent("snapshot-\(latest.key)")
        try erase(overlay: state.appendingPathComponent("nandrw-\(latest.key)"),
                  snapshots: [snapshot, snapshot.appendingPathExtension("tmp"), snapshot.appendingPathExtension("bad")],
                  legacyMarker: state.appendingPathComponent(".reset-\(latest.key)"), state: state, owner: owner)
        let pointer = state.appendingPathComponent("device/active-\(nand).json")
        try FileManager.default.createDirectory(at: pointer.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(latest).write(to: pointer, options: .atomic)
        try removeUnreferencedBases(state: state, nand: nand, except: owner)
    }

    /// device/<nand>* (older bases, a torn .partial unpack) that neither an
    /// active-*.json pointer nor a record other than `except` names.
    static func removeUnreferencedBases(state: URL, nand: String, except: UUID?) throws {
        let fm = FileManager.default
        let device = state.appendingPathComponent("device", isDirectory: true)
        let names = (try? fm.contentsOfDirectory(atPath: device.path)) ?? []
        var referenced = Set<String>()
        for name in names where name.hasPrefix("active-") && name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: device.appendingPathComponent(name)),
                  let image = try? JSONDecoder().decode(PackedImage.self, from: data) else {
                return   // an unreadable pointer: keep every base rather than guess
            }
            referenced.insert(image.directory)
        }
        let devices = state.appendingPathComponent("Devices", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: devices.path)) ?? [] where UUID(uuidString: name) != nil && UUID(uuidString: name) != except {
            guard let data = try? Data(contentsOf: devices.appendingPathComponent("\(name)/device.json")) else { continue }
            guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = (record["base"] as? [String: Any])?["path"] as? String else { return }
            referenced.insert(path.hasPrefix(state.path + "/") ? String(path.dropFirst(state.path.count + 1)) : path)
        }
        for name in names where (name == nand || name.hasPrefix(nand + "-") || name.hasPrefix(nand + ".")) && !referenced.contains("device/\(name)") {
            let base = device.appendingPathComponent(name)
            try checkRemovable(base, state: state, owner: except)
            try removeTree(base)
        }
    }

}
