import Foundation

/// Record admission is explicit: standalone sources retain their legacy relative
/// root; managed libraries additionally certify ownership of writable paths.
public nonisolated enum StorageRecordPolicy: Sendable {
    case standalone
    case managed(state: URL, id: UUID)

    public static func managedDeviceDirectory(_ device: URL) throws -> Self {
        guard device.deletingLastPathComponent().lastPathComponent == "Devices",
              let id = UUID(uuidString: device.lastPathComponent) else {
            throw StorageRecordPaths.Failure.invalidRecord
        }
        return .managed(state: device.deletingLastPathComponent().deletingLastPathComponent(), id: id)
    }
}

/// A path view decoded from one immutable byte snapshot. Unknown JSON remains
/// in the snapshot and is preserved by publication; this is not a device schema.
public nonisolated struct StorageRecordPaths: Sendable {
    public enum Failure: Error { case invalidRecord }
    public let id: UUID?
    public let base: URL
    public let overlay: URL
    public let snapshot: URL?
    public let writableNOR: URL?
    public let usbmuxConf: URL?
    public let relativeRoot: URL
    public let absoluteStyle: Bool

    public init(bytes: Data, relativeRoot: URL) throws {
        guard let record = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let base = record["base"] as? [String: Any], let path = base["path"] as? String,
              let storage = record["storage"] as? [String: Any], let overlay = storage["overlay"] as? String else {
            throw Failure.invalidRecord
        }
        for field in ["snapshot", "writableNOR", "usbmuxConf"] where storage[field] != nil {
            guard storage[field] is String else { throw Failure.invalidRecord }
        }
        self.relativeRoot = relativeRoot
        id = (record["id"] as? String).flatMap(UUID.init(uuidString:))
        absoluteStyle = path.hasPrefix("/")
        self.base = Self.resolve(path, relativeRoot: relativeRoot)
        self.overlay = Self.resolve(overlay, relativeRoot: relativeRoot)
        snapshot = (storage["snapshot"] as? String).map { Self.resolve($0, relativeRoot: relativeRoot) }
        writableNOR = (storage["writableNOR"] as? String).map { Self.resolve($0, relativeRoot: relativeRoot) }
        usbmuxConf = (storage["usbmuxConf"] as? String).map { Self.resolve($0, relativeRoot: relativeRoot) }
    }
    public static func resolve(_ path: String, relativeRoot: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : relativeRoot.appendingPathComponent(path)
    }
    public func recordPath(_ url: URL) throws -> String {
        if absoluteStyle { return url.path }
        let root = relativeRoot.path + "/"
        guard url.path.hasPrefix(root) else { throw Failure.invalidRecord }
        return String(url.path.dropFirst(root.count))
    }
    public func validate(_ policy: StorageRecordPolicy, device: URL) throws {
        if case let .managed(state, expected) = policy {
            let owned = state.appendingPathComponent("Devices/\(expected.uuidString)")
            guard id == expected, StoragePathAuthority.canonicalPath(device) == StoragePathAuthority.canonicalPath(owned) else {
                throw Failure.invalidRecord
            }
            let generations = device.appendingPathComponent("generations")
            try StoragePathAuthority.checkManagedContainer(generations, state: state, owner: expected)
            let containerPath = StoragePathAuthority.canonicalPath(generations)
            let basePath = StoragePathAuthority.canonicalPath(base)
            guard containerPath != basePath, !containerPath.hasPrefix(basePath + "/") else {
                throw StoragePathAuthority.Failure.invalidPath(generations)
            }
            try StoragePathAuthority.checkBootPaths(base: base,
                mutable: [device.appendingPathComponent("work"), overlay, snapshot, writableNOR, usbmuxConf].compactMap { $0 }, state: state, owner: expected)
        }
    }
}

/// Acquires exclusion before inspecting device.json and retains the exact
/// snapshot and descriptor through reconstruction or generation publication.
public nonisolated struct StoppedRecordOwner {
    /// Retain this shared descriptor owner when transferring the snapshot into
    /// a transaction; taking another lease would contend with this admission.
    public let lease: StorageLease
    public let device: URL
    public let bytes: Data?
    public let paths: StorageRecordPaths?

    public init(device: URL, policy: StorageRecordPolicy = .standalone,
                allowPendingEdit: Bool = false, allowRaw: Bool = false) throws {
        if case let .managed(state, id) = policy {
            // Reject an aliased foreign owner directory before creating its lease.
            let expected = state.appendingPathComponent("Devices/\(id.uuidString)")
            guard StoragePathAuthority.canonicalPath(device) == StoragePathAuthority.canonicalPath(expected) else {
                throw StorageRecordPaths.Failure.invalidRecord
            }
            try StoragePathAuthority.checkManagedDirectory(device, state: state, owner: id)
        }
        self.device = device.standardizedFileURL.resolvingSymlinksInPath()
        lease = try StorageLease(self.device.appendingPathComponent("work/lease"), allowPendingEdit: allowPendingEdit)
        let record = self.device.appendingPathComponent("device.json")
        if allowRaw && !FileManager.default.fileExists(atPath: record.path), case .standalone = policy {
            bytes = nil; paths = nil
        } else {
            let snapshot = try Data(contentsOf: record)
            let paths = try StorageRecordPaths(bytes: snapshot,
                relativeRoot: self.device.deletingLastPathComponent().deletingLastPathComponent())
            try paths.validate(policy, device: self.device)
            bytes = snapshot; self.paths = paths
        }
    }
}
