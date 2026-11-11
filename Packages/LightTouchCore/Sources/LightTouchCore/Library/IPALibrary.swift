// Every .ipa this app has installed, kept once: a content-addressed store
// (State/Library/IPAs/<sha256>.ipa + index.plist) and, per device that has
// the app, a clone of the blob at Devices/<uuid>/IPAs/<bundle-id>.ipa (APFS:
// no extra space). The device copy is what an installed row drags out as a
// real file and what uninstall removes; the blob outlives it, for the next
// device and for Legacy Store to skip a download it already made, until
// nothing references it and Settings ▸ Storage removes it. The collection
// is the point of this program.

import Crypto
import Darwin
import Foundation
import HostRuntime

@MainActor
public enum IPALibrary {
    /// One stored archive; the optional fields are what the install that
    /// stored it knew.
    public struct Entry: Codable, Equatable, Sendable {
        nonisolated public init(
            bundleID: String,
            name: String? = nil,
            version: String? = nil,
            minOS: String? = nil,
            size: Int64,
            md5: String,
            catalogIpaID: Int? = nil,
            kept: Bool? = nil
        ) {
            self.bundleID = bundleID
            self.name = name
            self.version = version
            self.minOS = minOS
            self.size = size
            self.md5 = md5
            self.catalogIpaID = catalogIpaID
            self.kept = kept
        }
        public var bundleID: String
        public var name: String? = nil
        public var version: String? = nil
        public var minOS: String? = nil
        public var size: Int64
        /// The archive's own checksum, which is what Legacy Store publishes.
        public var md5: String
        public var catalogIpaID: Int? = nil
        /// Added in Settings ▸ Storage to keep, not by an install: Remove Unused leaves it.
        public var kept: Bool? = nil
    }

    /// What an install knows about the archive it just landed.
    public struct Metadata: Sendable {
        nonisolated public init(
            bundleID: String,
            name: String? = nil,
            version: String? = nil,
            minOS: String? = nil,
            catalogIpaID: Int? = nil
        ) {
            self.bundleID = bundleID
            self.name = name
            self.version = version
            self.minOS = minOS
            self.catalogIpaID = catalogIpaID
        }
        public var bundleID: String
        public var name: String? = nil
        public var version: String? = nil
        public var minOS: String? = nil
        public var catalogIpaID: Int? = nil
    }

    public nonisolated struct Digests: Sendable {
        public let sha256: String, md5: String
        public let size: Int64
    }

    /// The state directory the library and the device copies live under; nil is Bundled's. Tests point it at a
    /// temporary directory.
    // nonisolated(unsafe): set by tests before any library work starts; read-only otherwise.
    public nonisolated(unsafe) static var stateRoot: URL?

    public nonisolated static var directory: URL {
        (stateRoot ?? Bundled.stateDirectory).appendingPathComponent("Library/IPAs", isDirectory: true)
    }
    /// An XML property list; earlier builds kept index.json, converted on the first read.
    private nonisolated static var indexURL: URL { directory.appendingPathComponent("index.plist") }
    public nonisolated static func blob(_ sha256: String) -> URL { directory.appendingPathComponent("\(sha256).ipa") }

    // MARK: - Index

    private static var loaded: (url: URL, index: [String: Entry])?

    /// sha256 → entry, read once per process (the app holds the library lock).
    public static var index: [String: Entry] {
        if let loaded, loaded.url == indexURL { return loaded.index }
        let read =
            (try? PropertyListFile.read(
                [String: Entry].self,
                from: indexURL,
                legacyJSON: directory.appendingPathComponent("index.json")
            )) ?? [:]
        loaded = (indexURL, read)
        return read
    }

    private static func save(_ index: [String: Entry]) {
        loaded = (indexURL, index)
        do {
            try StorageLocations.privateDirectory(directory)
            try PropertyListFile.write(index, to: indexURL)
        } catch {
            logEvent("library: could not write the index: %@", error.localizedDescription)
            AppReports.failed("Library.writeFailed", error, ["what": "index"])
        }
    }

    private static func record(_ digests: Digests, _ metadata: Metadata, kept: Bool? = nil) {
        var index = index
        let old = index[digests.sha256]
        let new = Entry(
            bundleID: metadata.bundleID,
            name: metadata.name ?? old?.name,
            version: metadata.version ?? old?.version,
            minOS: metadata.minOS ?? old?.minOS,
            size: digests.size,
            md5: digests.md5,
            catalogIpaID: metadata.catalogIpaID ?? old?.catalogIpaID,
            kept: kept ?? old?.kept
        )
        guard new != old else { return }
        index[digests.sha256] = new
        save(index)
    }

    // MARK: - Device copies

    /// Same guard as AppMetadataCache: a bundle id is about to become a path
    /// component, and an archive can claim anything as its identifier.
    private nonisolated static func safe(_ bundleID: String) -> String? {
        guard !bundleID.isEmpty, !bundleID.hasPrefix("."),
            !bundleID.contains("/"), !bundleID.contains(":"), !bundleID.contains("\0")
        else { return nil }
        return bundleID
    }

    private nonisolated static func file(_ id: String, device: DeviceInstance) -> URL {
        ipas(device).appendingPathComponent("\(id).ipa")
    }

    /// A device's IPAs directory, under `stateRoot` when one is set.
    private nonisolated static func ipas(_ device: DeviceInstance) -> URL {
        guard let stateRoot else { return device.paths.ipas }
        return device.paths(state: stateRoot, logs: stateRoot.appendingPathComponent("Logs", isDirectory: true)).ipas
    }

    /// The device's copy for this app, or nil if we never kept one.
    public nonisolated static func url(for bundleID: String, device: DeviceInstance) -> URL? {
        guard let id = safe(bundleID) else { return nil }
        let url = file(id, device: device)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Keep a just-installed .ipa: hashed once, into the store if new, and
    /// cloned into the device's IPAs. Best-effort: dragging and reuse are
    /// conveniences, never worth failing an install over.
    public static func adopt(_ ipa: URL, _ metadata: Metadata, device: DeviceInstance) async {
        guard let id = safe(metadata.bundleID) else { return }
        do {
            record(try await store(ipa, cloneTo: file(id, device: device)), metadata)
        } catch {
            logEvent("library: could not preserve IPA for %@: %@", id, error.localizedDescription)
            AppReports.failed("Library.writeFailed", error, ["what": "preserve"])
        }
    }

    /// The archive is read end to end, off the main actor; `copy`, when given, is a clone for a device.
    @concurrent private nonisolated static func store(_ ipa: URL, cloneTo copy: URL? = nil) async throws -> Digests {
        let digests = try digests(of: ipa)
        let blob = blob(digests.sha256)
        if !FileManager.default.fileExists(atPath: blob.path) { try clone(ipa, to: blob) }
        if let copy { try clone(blob, to: copy) }
        return digests
    }

    /// Settings ▸ Storage's Add App…: an .ipa kept in the store (a clone on the same volume) without installing it,
    /// which Remove Unused leaves. The user's file stays where it is.
    public static func keep(_ ipa: URL) async throws {
        guard let id = await AppMetadataCache.bundleID(of: ipa) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: ipa])
        }
        let info = await AppMetadataCache.info(of: ipa) ?? [:]
        let metadata = Metadata(
            bundleID: id,
            name: (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String,
            version: (info["CFBundleShortVersionString"] ?? info["CFBundleVersion"]) as? String,
            minOS: info["MinimumOSVersion"] as? String
        )
        record(try await store(ipa), metadata, kept: true)
    }

    /// The uninstall path drops the device's copy; the blob stays.
    public static func forget(_ bundleID: String, device: DeviceInstance) {
        guard let id = safe(bundleID) else { return }
        try? FileManager.default.removeItem(at: file(id, device: device))
    }

    /// Whether one of these devices still keeps the app: its app-wide name
    /// and icon (AppMetadataCache) stay while one does.
    public nonisolated static func retained(_ bundleID: String, by devices: [DeviceInstance]) -> Bool {
        devices.contains { url(for: bundleID, device: $0) != nil }
    }

    // MARK: - Store

    /// The blob Legacy Store's checksum names, when the store has it: the
    /// same copy, downloaded before for any device.
    public static func stored(md5: String) -> URL? {
        let md5 = md5.lowercased()
        guard let sha256 = index.first(where: { $0.value.md5 == md5 })?.key else { return nil }
        let url = blob(sha256)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Blobs no device copy references. A reference is a copy named for the
    /// entry's bundle id with the entry's size.
    public static func unused(devices: [DeviceInstance]) -> [String: Entry] { unused(index, devices: devices) }

    /// `index`'s entries no device has a copy of and nobody kept, off the main thread (Settings ▸ Storage measures
    /// with it).
    public nonisolated static func unused(_ index: [String: Entry], devices: [DeviceInstance]) -> [String: Entry] {
        let devices = deviceCounts(index, devices: devices)
        return index.filter { sha256, entry in
            entry.kept != true && devices[sha256] == nil
        }
    }

    /// How many devices have a copy of each of `index`'s entries, by sha256 (none: absent). One archive can be on
    /// several devices, and each version of an app is its own entry.
    public nonisolated static func deviceCounts(_ index: [String: Entry], devices: [DeviceInstance]) -> [String: Int] {
        index.compactMapValues { entry in
            let count = devices.count { device in
                guard let copy = url(for: entry.bundleID, device: device) else {
                    return false
                }
                return Self.size(of: copy) == entry.size
            }
            return count > 0 ? count : nil
        }
    }

    /// Settings ▸ Storage's Remove Unused.
    public static func removeUnused(devices: [DeviceInstance]) throws {
        try remove(Array(unused(devices: devices).keys))
    }

    /// Settings ▸ Storage's Delete for apps no device has: their blobs and entries. The user's own files elsewhere stay.
    public static func remove(_ sha256s: [String]) throws {
        var index = index
        defer { save(index) }
        for sha256 in sha256s {
            let url = blob(sha256)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            index[sha256] = nil
        }
    }

    /// Launch, under the app lock: every device copy is in the store once.
    /// Builds before per-device copies kept one State/IPAs for every device;
    /// Idempotent, and cheap after the first run: a device copy whose bundle
    /// id and size the index lists is not read again.
    public static func sweep(devices: [DeviceInstance]) {
        // An entry whose blob went (removed by hand) says nothing true any more.
        var index = index.filter { FileManager.default.fileExists(atPath: blob($0.key).path) }
        let stored = devices.reduce(0) { $0 + store(copies: ipas($1), into: &index).stored }
        if stored > 0 { logEvent("library: \(stored) device copies stored") }
        if index != self.index { save(index) }
    }

    /// The <bundle-id>.ipa files of a device from the old layout (LegacyState).
    /// Hashed and cloned off the main actor (hundreds of MB, seconds); the index is written here. Returns the
    /// copies it couldn't keep (unreadable, or the store couldn't take them).
    @discardableResult public static func adopt(copies directory: URL) async -> [URL] {
        let before = index
        let (after, (stored, missed)) = await Task.detached {
            var index = before
            let result = store(copies: directory, into: &index)
            return (index, result)
        }.value
        if stored > 0 { logEvent("library: \(stored) copies kept from \(directory.path)") }
        var index = index  // what the main actor recorded meanwhile, plus what was stored
        for (sha256, entry) in after where before[sha256] != entry { index[sha256] = entry }
        if index != self.index { save(index) }
        return missed
    }

    /// Every <bundle-id>.ipa in `directory` the index doesn't list, into the store; how many, and the copies (or the
    /// directory, unlistable) it couldn't keep.
    private nonisolated static func store(
        copies directory: URL,
        into index: inout [String: Entry]
    ) -> (stored: Int, missed: [URL]) {
        let fm = FileManager.default
        var stored = 0
        var missed: [URL] = []
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return (0, fm.fileExists(atPath: directory.path) ? [directory] : [])
        }
        for name in names where name.hasSuffix(".ipa") && !name.hasPrefix(".") {
            let copy = directory.appendingPathComponent(name)
            let bundleID = String(name.dropLast(4))
            guard let size = size(of: copy) else {
                missed.append(copy)
                continue
            }
            if index.values.contains(where: { $0.bundleID == bundleID && $0.size == size }) { continue }
            do {
                let digests = try digests(of: copy)
                if !fm.fileExists(atPath: blob(digests.sha256).path) { try clone(copy, to: blob(digests.sha256)) }
                index[digests.sha256] = Entry(bundleID: bundleID, size: digests.size, md5: digests.md5)
                stored += 1
            } catch {
                logEvent("library: could not store \(name) from \(directory.path): \(error.localizedDescription)")
                AppReports.failed("Library.writeFailed", error, ["what": "store"])
                missed.append(copy)
            }
        }
        return (stored, missed)
    }

    // MARK: - Files

    private nonisolated static func size(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    /// sha256 (the blob's name), md5 (Legacy Store's checksum) and size in one read.
    public nonisolated static func digests(of url: URL) throws -> Digests {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha256 = SHA256()
        var md5 = Insecure.MD5()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            sha256.update(data: chunk)
            md5.update(data: chunk)
            size += Int64(chunk.count)
        }
        func hex(_ digest: some Sequence<UInt8>) -> String { digest.map { String(format: "%02x", $0) }.joined() }
        return Digests(sha256: hex(sha256.finalize()), md5: hex(md5.finalize()), size: size)
    }

    /// `source` published at `destination` as an APFS clone (a copy on
    /// another volume or file system), through a temporary sibling and a
    /// rename, so a reader never sees a partial file.
    public nonisolated static func clone(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let dir = destination.deletingLastPathComponent()
        try StorageLocations.privateDirectory(dir)
        let temporary = dir.appendingPathComponent(".\(UUID().uuidString).ipa")
        defer { try? fm.removeItem(at: temporary) }
        if clonefile(source.path, temporary.path, 0) != 0 {
            try fm.copyItem(at: source, to: temporary)
        }
        guard rename(temporary.path, destination.path) == 0 else { throw StorageLocations.posixError() }
    }
}
