import Darwin
import Foundation

/// Explicit private-library path policy; not imposed on caller-selected standalone stores.
public nonisolated enum StoragePathAuthority {
    public enum Failure: Error { case invalidPath(URL) }
    /// A path with symlinks resolved as far as it exists (the rest appended
    /// as written), so `..` and links can't point a removal elsewhere.
    public static func canonicalPath(_ url: URL) -> String {
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

    private static func checkLinks(_ url: URL) throws {
        // canonicalPath resolves existing links; a dangling/cyclic link has no
        // realpath result and must not be mistaken for an uncreated private suffix.
        var component = URL(fileURLWithPath: "/")
        var followedLink = false
        for part in url.pathComponents.dropFirst() {
            // Lexical standardization would erase link/.. before realpath,
            // although the OS traverses the link before moving to its parent.
            if part == "..", followedLink { throw Failure.invalidPath(url) }
            component.appendPathComponent(part)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: component.path)) != nil {
                followedLink = true
                if !FileManager.default.fileExists(atPath: component.path) { throw Failure.invalidPath(url) }
            }
        }
    }

    /// Admit the private record/work directory before creating its lease.
    public static func checkManagedDirectory(_ directory: URL, state: URL, owner: UUID) throws {
        let expected = state.appendingPathComponent("Devices/\(owner.uuidString)")
        try checkLinks(directory)
        try checkLinks(directory.appendingPathComponent("work"))
        try checkRemovable(directory, state: state, owner: owner)
        let owned = canonicalPath(expected)
        guard canonicalPath(directory) == owned,
              canonicalPath(directory.appendingPathComponent("work")).hasPrefix(owned + "/") else {
            throw Failure.invalidPath(directory)
        }
        try checkRemovable(directory.appendingPathComponent("work"), state: state, owner: owner)
    }

    /// Managed GUI records must keep writable state under their own record directory.
    /// Explicit external read-only bases and caller-authorized raw CLI fixtures are separate policy.
    /// This read-only preflight must run before helper spawn or storage preparation.
    public static func checkBootPaths(base: URL, mutable: [URL], state: URL, owner: UUID) throws {
        let directory = state.appendingPathComponent("Devices/\(owner.uuidString)")
        func invalid(_ url: URL) -> Failure { .invalidPath(url) }
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
    public static func checkRemovable(_ url: URL, state: URL, owner: UUID?) throws {
        let root = canonicalPath(state), path = canonicalPath(url)
        let devices = root + "/Devices"
        let others = otherRecordDirectories(state: state, owner: owner)
        guard path.hasPrefix(root + "/"), path != devices,
              !others.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
            throw Failure.invalidPath(url)
        }
    }

}
