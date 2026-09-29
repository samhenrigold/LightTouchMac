// Where IPSWs live, and the checks every one passes before it is used
// (docs/multi-device-plan.md, D): downloads in Caches/<bundle>/IPSW, imports
// in State/IPSW, both named by sha1, so either one satisfies an entry.

import CryptoKit
import Foundation

nonisolated enum FirmwareError: LocalizedError, Equatable {
    case corrupted
    case notEnoughSpace(required: Int64, available: Int64)
    /// The IPSW's ProductType and build are a catalog entry's, its bytes aren't.
    case wrongFile(model: String, version: String)
    case unsupported
    case failed(String)

    var errorDescription: String? {
        let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return switch self {
        case .corrupted: "Download corrupted."
        case let .notEnoughSpace(required, available):
            "Not enough disk space: this needs \(format(required)), and \(format(available)) is available."
        case let .wrongFile(model, version): "This isn’t the IPSW Light Touch knows for \(model) iOS \(version)."
        case .unsupported: "Not a supported firmware."
        case let .failed(message): message
        }
    }
}

nonisolated struct IPSWStore: Sendable {
    /// Caches/<bundle>/IPSW: CDN downloads, their .partial and .resume files.
    let downloads: URL
    /// State/IPSW: user imports.
    let imports: URL

    static var shared: IPSWStore {
        IPSWStore(downloads: cachesDirectory.appendingPathComponent("IPSW", isDirectory: true),
                  imports: Bundled.stateDirectory.appendingPathComponent("IPSW", isDirectory: true))
    }

    /// ~/Library/Caches/<bundle>; also where the preparer keeps Decrypted/.
    static var cachesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(StorageLocations.bundleIdentifier, isDirectory: true)
    }

    func download(_ sha1: String) -> URL { downloads.appendingPathComponent("\(sha1).ipsw") }
    func partial(_ sha1: String) -> URL { downloads.appendingPathComponent("\(sha1).partial") }
    func resumeData(_ sha1: String) -> URL { downloads.appendingPathComponent("\(sha1).resume") }
    func imported(_ sha1: String) -> URL { imports.appendingPathComponent("\(sha1).ipsw") }

    /// The IPSW with this sha1 if either store has it.
    func existing(_ sha1: String) -> URL? {
        [download(sha1), imported(sha1)].first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Checks

    /// SHA1 of a file read in 4 MiB chunks, never whole. `progress` gets the fraction read.
    static func sha1(of url: URL, progress: ((Double) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = max(1, (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 1)
        var hash = Insecure.SHA1()
        var read: Int64 = 0
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
            read += Int64(chunk.count)
            progress?(Double(read) / Double(size))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Checks a finished download's size and sha1, then renames it to
    /// <sha1>.ipsw. On a mismatch the file is deleted.
    func install(_ file: URL, sha1: String, bytes: Int64?) throws -> URL {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? -1
        guard bytes.map({ $0 == size }) ?? true, try Self.sha1(of: file) == sha1 else {
            try? fm.removeItem(at: file)
            throw FirmwareError.corrupted
        }
        let destination = download(sha1)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: file, to: destination)
        return destination
    }

    /// `url` or its nearest existing parent, for volume questions.
    private static func existing(_ url: URL) -> URL {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        return probe
    }

    static func availableSpace(at url: URL) throws -> Int64 {
        try existing(url).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Free space for `required` bytes on the volume holding `url` (or its nearest existing parent).
    static func checkSpace(_ required: Int64, at url: URL) throws {
        try checkSpace(required, available: availableSpace(at: url))
    }

    /// Below this, booting and recording go ahead with a warning.
    static let lowSpaceThreshold: Int64 = 2_000_000_000

    /// The warning for booting or recording with little room left, else nil.
    static func lowSpaceWarning(at url: URL) -> String? {
        guard let available = try? availableSpace(at: url), available < lowSpaceThreshold else { return nil }
        let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return "Your Mac is almost out of disk space: \(format(available)) is available, and Light Touch needs at least \(format(lowSpaceThreshold)) to save changes reliably."
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let x = try? existing(a).resourceValues(forKeys: [key]).volumeIdentifier as? NSObject,
              let y = try? existing(b).resourceValues(forKeys: [key]).volumeIdentifier as? NSObject else { return false }
        return x.isEqual(y)
    }

    static func checkSpace(_ required: Int64, available: Int64) throws {
        guard available >= required else { throw FirmwareError.notEnoughSpace(required: required, available: available) }
    }

    // MARK: - Import

    /// ProductType and ProductBuildVersion from the IPSW's Restore.plist, or nil if it has none.
    static func restoreInfo(_ ipsw: URL) -> (productType: String, build: String)? {
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", ipsw.path, "Restore.plist"]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        unzip.standardError = FileHandle.nullDevice
        guard (try? unzip.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let type = plist["ProductType"] as? String, let build = plist["ProductBuildVersion"] as? String
        else { return nil }
        return (type, build)
    }

    /// The entry pinning this sha1, else why not: the same ProductType and
    /// build as an entry means the wrong file, anything else is unsupported.
    static func match(sha1: String, restore: (productType: String, build: String)?,
                      in catalog: FirmwareCatalog) throws -> FirmwareCatalog.Entry {
        let ipsw = catalog.entries
        if let entry = ipsw.first(where: { $0.source.sha1 == sha1 }) { return entry }
        if let restore, let entry = ipsw.first(where: { $0.productType == restore.productType && $0.build == restore.build }) {
            throw FirmwareError.wrongFile(model: entry.profile?.displayName ?? entry.productType, version: entry.version)
        }
        throw FirmwareError.unsupported
    }

    /// Hashes a user's IPSW, matches it to the catalog and clones it into
    /// State/IPSW (APFS clonefile on the same volume, a copy otherwise).
    /// Offline: nothing here touches the network.
    func importIPSW(_ url: URL, catalog: FirmwareCatalog,
                    progress: ((Double) -> Void)? = nil) throws -> (entry: FirmwareCatalog.Entry, ipsw: URL) {
        let sha1 = try Self.sha1(of: url, progress: progress)
        let entry = try Self.match(sha1: sha1, restore: Self.restoreInfo(url), in: catalog)
        if let existing = existing(sha1) { return (entry, existing) }
        try StorageLocations.privateDirectory(imports)
        StorageLocations.excludeFromBackup(imports)
        // Another volume means a full copy, not a clone.
        if !Self.sameVolume(url, imports) {
            try Self.checkSpace((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0, at: imports)
        }
        let destination = imported(sha1)
        let temporary = imports.appendingPathComponent(".\(sha1).importing")
        try? FileManager.default.removeItem(at: temporary)
        try FileManager.default.copyItem(at: url, to: temporary)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return (entry, destination)
    }

    // MARK: - Removal

    /// Remove IPSW: the download, its .partial and .resume, and the import.
    func remove(_ sha1: String) throws {
        for url in [download(sha1), partial(sha1), resumeData(sha1), imported(sha1)]
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Launch, under the app lock: a .partial outlives only a crash (it's
    /// renamed within one delegate call), and so does an .importing copy.
    func sweep() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: downloads.path)) ?? [] where name.hasSuffix(".partial") {
            try? fm.removeItem(at: downloads.appendingPathComponent(name))
        }
        for name in (try? fm.contentsOfDirectory(atPath: imports.path)) ?? [] where name.hasPrefix(".") && name.hasSuffix(".importing") {
            try? fm.removeItem(at: imports.appendingPathComponent(name))
        }
    }
}
