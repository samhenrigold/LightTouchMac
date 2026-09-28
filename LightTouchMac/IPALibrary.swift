// Created by Sam on 2026-08-06.
//
// Every .ipa this app has installed, kept once: a content-addressed store
// (State/Library/IPAs/<sha256>.ipa + index.json) and, per device that has
// the app, a clone of the blob at Devices/<uuid>/IPAs/<bundle-id>.ipa (APFS:
// no extra space). The device copy is what an installed row drags out as a
// real file and what uninstall removes; the blob outlives it, for the next
// device and for Legacy Store to skip a download it already made, until
// nothing references it and Settings ▸ Storage removes it. The collection
// is the point of this program.

import Foundation
import CryptoKit
import Darwin

@MainActor
enum IPALibrary {

    /// One stored archive; the optional fields are what the install that
    /// stored it knew.
    struct Entry: Codable, Equatable, Sendable {
        var bundleID: String
        var name: String? = nil
        var version: String? = nil
        var minOS: String? = nil
        var size: Int64
        /// The archive's own checksum, which is what Legacy Store publishes.
        var md5: String
        var catalogIpaID: Int? = nil
    }

    /// What an install knows about the archive it just landed.
    struct Metadata: Sendable {
        var bundleID: String
        var name: String? = nil
        var version: String? = nil
        var minOS: String? = nil
        var catalogIpaID: Int? = nil
    }

    nonisolated struct Digests: Sendable {
        let sha256: String, md5: String
        let size: Int64
    }

    nonisolated static var directory: URL {
        Bundled.stateDirectory.appendingPathComponent("Library/IPAs", isDirectory: true)
    }
    private nonisolated static var indexURL: URL { directory.appendingPathComponent("index.json") }
    nonisolated static func blob(_ sha256: String) -> URL { directory.appendingPathComponent("\(sha256).ipa") }

    // MARK: - Index

    private static var loaded: [String: Entry]?

    /// sha256 → entry, read once per process (the app holds the library lock).
    static var index: [String: Entry] {
        if let loaded { return loaded }
        let read = (try? Data(contentsOf: indexURL))
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        loaded = read
        return read
    }

    private static func save(_ index: [String: Entry]) {
        loaded = index
        do {
            try StorageLocations.privateDirectory(directory)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(index).write(to: indexURL, options: .atomic)
        } catch {
            logEvent("library: could not write the index: %@", error.localizedDescription)
        }
    }

    private static func record(_ digests: Digests, _ metadata: Metadata) {
        var index = index
        let old = index[digests.sha256]
        let new = Entry(bundleID: metadata.bundleID, name: metadata.name ?? old?.name,
                        version: metadata.version ?? old?.version, minOS: metadata.minOS ?? old?.minOS,
                        size: digests.size, md5: digests.md5, catalogIpaID: metadata.catalogIpaID ?? old?.catalogIpaID)
        guard new != old else { return }
        index[digests.sha256] = new
        save(index)
    }

    // MARK: - Device copies

    /// Same guard as AppMetadataCache: a bundle id is about to become a path
    /// component, and an archive can claim anything as its identifier.
    private nonisolated static func safe(_ bundleID: String) -> String? {
        guard !bundleID.isEmpty, !bundleID.hasPrefix("."),
              !bundleID.contains("/"), !bundleID.contains(":"), !bundleID.contains("\0") else { return nil }
        return bundleID
    }

    private nonisolated static func file(_ id: String, device: DeviceInstance) -> URL {
        device.paths.ipas.appendingPathComponent("\(id).ipa")
    }

    /// The device's copy for this app, or nil if we never kept one.
    nonisolated static func url(for bundleID: String, device: DeviceInstance) -> URL? {
        guard let id = safe(bundleID) else { return nil }
        let url = file(id, device: device)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Keep a just-installed .ipa: hashed once, into the store if new, and
    /// cloned into the device's IPAs. Best-effort: dragging and reuse are
    /// conveniences, never worth failing an install over.
    static func adopt(_ ipa: URL, _ metadata: Metadata, device: DeviceInstance) async {
        guard let id = safe(metadata.bundleID) else { return }
        do {
            record(try await store(ipa, cloneTo: file(id, device: device)), metadata)
        } catch {
            logEvent("library: could not preserve IPA for %@: %@", id, error.localizedDescription)
        }
    }

    /// The archive is read end to end, off the main actor.
    @concurrent private nonisolated static func store(_ ipa: URL, cloneTo copy: URL) async throws -> Digests {
        let digests = try digests(of: ipa)
        let blob = blob(digests.sha256)
        if !FileManager.default.fileExists(atPath: blob.path) { try clone(ipa, to: blob) }
        try clone(blob, to: copy)
        return digests
    }

    /// The uninstall path drops the device's copy; the blob stays.
    static func forget(_ bundleID: String, device: DeviceInstance) {
        guard let id = safe(bundleID) else { return }
        try? FileManager.default.removeItem(at: file(id, device: device))
    }

    /// Whether one of these devices still keeps the app: its app-wide name
    /// and icon (AppMetadataCache) stay while one does.
    nonisolated static func retained(_ bundleID: String, by devices: [DeviceInstance]) -> Bool {
        devices.contains { url(for: bundleID, device: $0) != nil }
    }

    // MARK: - Store

    /// The blob Legacy Store's checksum names, when the store has it: the
    /// same copy, downloaded before for any device.
    static func stored(md5: String) -> URL? {
        let md5 = md5.lowercased()
        guard let sha256 = index.first(where: { $0.value.md5 == md5 })?.key else { return nil }
        let url = blob(sha256)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Blobs no device copy references. A reference is a copy named for the
    /// entry's bundle id with the entry's size.
    // ponytail: size + bundle id, not a hash of every device copy on each
    // Settings reload; a different build of the same size only keeps a blob
    // longer, never removes a referenced one.
    static func unused(devices: [DeviceInstance]) -> [String: Entry] {
        index.filter { _, entry in
            !devices.contains { device in
                guard let copy = url(for: entry.bundleID, device: device) else { return false }
                return Self.size(of: copy) == entry.size
            }
        }
    }

    /// Settings ▸ Storage's Remove Unused.
    static func removeUnused(devices: [DeviceInstance]) throws {
        var index = index
        for sha256 in unused(devices: devices).keys {
            let url = blob(sha256)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            index[sha256] = nil
        }
        save(index)
    }

    /// Launch, under the app lock: every device copy is in the store once.
    /// Builds before per-device copies kept one State/IPAs for every device;
    /// those are cloned into each device first, then the shared directory
    /// goes. Idempotent, and cheap after the first run: a device copy whose
    /// bundle id and size the index lists is not read again.
    static func sweep(devices: [DeviceInstance]) {
        let fm = FileManager.default
        let shared = Bundled.stateDirectory.appendingPathComponent("IPAs", isDirectory: true)
        if !devices.isEmpty, let names = try? fm.contentsOfDirectory(atPath: shared.path) {
            var complete = true
            for device in devices {
                for name in names where name.hasSuffix(".ipa") && !name.hasPrefix(".") {
                    let destination = device.paths.ipas.appendingPathComponent(name)
                    guard !fm.fileExists(atPath: destination.path) else { continue }
                    do { try clone(shared.appendingPathComponent(name), to: destination) }
                    catch {
                        complete = false
                        logEvent("library: could not move \(name) to \(device.id.uuidString): \(error.localizedDescription)")
                    }
                }
            }
            if complete {
                try? fm.removeItem(at: shared)
                logEvent("library: IPA copies are per device now (\(names.count) moved)")
            }
        }
        // An entry whose blob went (removed by hand) says nothing true any more.
        var index = index.filter { fm.fileExists(atPath: blob($0.key).path) }
        var stored = 0
        for device in devices {
            let dir = device.paths.ipas
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            where name.hasSuffix(".ipa") && !name.hasPrefix(".") {
                let copy = dir.appendingPathComponent(name)
                let bundleID = String(name.dropLast(4))
                guard let size = size(of: copy),
                      !index.values.contains(where: { $0.bundleID == bundleID && $0.size == size }) else { continue }
                do {
                    let digests = try digests(of: copy)
                    if !fm.fileExists(atPath: blob(digests.sha256).path) { try clone(copy, to: blob(digests.sha256)) }
                    index[digests.sha256] = Entry(bundleID: bundleID, size: digests.size, md5: digests.md5)
                    stored += 1
                } catch {
                    logEvent("library: could not store \(name) of \(device.id.uuidString): \(error.localizedDescription)")
                }
            }
        }
        if stored > 0 { logEvent("library: \(stored) device copies stored") }
        if index != self.index { save(index) }
    }

    // MARK: - Files

    private nonisolated static func size(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    /// sha256 (the blob's name), md5 (Legacy Store's checksum) and size in one read.
    nonisolated static func digests(of url: URL) throws -> Digests {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha256 = SHA256(), md5 = Insecure.MD5()
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
    nonisolated static func clone(_ source: URL, to destination: URL) throws {
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
