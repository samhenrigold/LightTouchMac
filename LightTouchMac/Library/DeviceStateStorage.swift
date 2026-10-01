import HostRuntime
import Foundation
import Darwin

/// Disk operations shared by the controller and the device-free regression check.
nonisolated enum DeviceStateStorage {
    /// Only call after the native VM has exited and released its files.
    /// `snapshots`: saved-state files older builds wrote (and their .meta), swept with the overlay.
    /// `owner` is the device being erased; every path must pass checkRemovable.
    static func erase(overlay: URL, snapshots: [URL], state: URL, owner: UUID?) throws {
        let lease = try stoppedLease(owner, state: state)
        defer { withExtendedLifetime(lease) {} }
        let fm = FileManager.default
        let paths = snapshots.flatMap { [$0, $0.appendingPathExtension("meta")] } + [overlay]
        for path in paths { try checkRemovable(path, state: state, owner: owner) }
        for path in paths where fm.fileExists(atPath: path.path) {
            try fm.removeItem(at: path)
        }
    }

    /// The helper/export/edit lock is the authority, including external CLI
    /// owners. A cached GUI "stopped" state cannot authorize deleting its files.
    private final class Lease {
        let descriptor: Int32
        init(_ descriptor: Int32) { self.descriptor = descriptor }
        deinit { close(descriptor) }
    }
    private static func stoppedLease(_ owner: UUID?, state: URL) throws -> Lease? {
        guard let owner else { return nil } // legacy profile-only stores
        let work = state.appendingPathComponent("Devices/\(owner.uuidString)/work")
        try checkRemovable(work, state: state, owner: owner)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let descriptor = open(work.appendingPathComponent("lease").path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let lease = Lease(descriptor)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0,
              !FileManager.default.fileExists(atPath: work.appendingPathComponent("edit.json").path) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey:
                "This device’s storage is in use. Stop the device or finish its filesystem edit first."])
        }
        return lease
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

    /// Managed GUI records must keep writable state under their own record directory.
    /// Explicit external read-only bases and caller-authorized raw CLI fixtures are separate policy.
    /// This read-only preflight must run before helper spawn or storage preparation.
    static func checkBootPaths(base: URL, mutable: [URL], state: URL, owner: UUID) throws {
        let directory = state.appendingPathComponent("Devices/\(owner.uuidString)")
        func invalid(_ url: URL) -> CocoaError {
            CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path,
                NSLocalizedDescriptionKey: "Light Touch can’t start this device because \(url.path) isn’t its writable storage."])
        }
        func checkLinks(_ url: URL) throws {
            // canonicalPath resolves existing links; a dangling/cyclic link has no
            // realpath result and must not be mistaken for an uncreated private suffix.
            var component = URL(fileURLWithPath: "/")
            var followedLink = false
            for part in url.pathComponents.dropFirst() {
                // Lexical standardization would erase link/.. before realpath,
                // although the OS traverses the link before moving to its parent.
                if part == "..", followedLink { throw invalid(url) }
                component.appendPathComponent(part)
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: component.path)) != nil {
                    followedLink = true
                    if !FileManager.default.fileExists(atPath: component.path) { throw invalid(url) }
                }
            }
        }
        try checkLinks(directory)
        try checkRemovable(directory, state: state, owner: owner)
        let owned = canonicalPath(directory)
        let immutable = canonicalPath(base)
        for url in mutable {
            try checkLinks(url)
            try checkRemovable(url, state: state, owner: owner)
            let path = canonicalPath(url)
            guard path.hasPrefix(owned + "/"),
                  path != immutable, !path.hasPrefix(immutable + "/"),
                  !immutable.hasPrefix(path + "/") else { throw invalid(url) }
        }
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
        let lease = try stoppedLease(id, state: state)
        defer { withExtendedLifetime(lease) {} }
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
        try PreparedDeviceBoot.writableNOR(base: base, overlay: overlay)
    }

    /// A copy-on-write overlay is only valid over the exact base it was made
    /// from: over a rebuilt base its dirty pages mix with different clean ones
    /// (seen as an unactivated iPad after a golden rebuild). The overlay
    /// carries the base's identity; false means it belongs to another base,
    /// or predates pinning, and must not be booted. An empty or missing
    /// overlay is adopted by the base.
    static func pinOverlay(_ overlay: URL, toBase identity: String) throws -> Bool {
        try PreparedDeviceBoot.pinOverlay(overlay, toBase: identity)
    }
}
