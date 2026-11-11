// Where IPSWs live, and the checks every one passes before it is used:
// downloads in Caches/<bundle>/IPSW, imports
// in State/IPSW, both named by sha1, so either one satisfies an entry.
// An import from another volume isn't copied: State/IPSW holds a symbolic
// link to the user's file instead, read in place.

import Crypto
import FirmwareSchema
import Foundation

public nonisolated enum FirmwareError: LocalizedError, Equatable {
    case corrupted
    case notEnoughSpace(required: Int64, available: Int64)
    /// The IPSW's ProductType and build are a catalog entry's, its bytes aren't.
    case wrongFile(model: String, version: String)
    case unsupported
    /// Several files dropped or chosen, and none an IPSW the catalog knows.
    case noneSupported
    case failed(String)

    public var errorDescription: String? {
        let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return switch self {
        case .corrupted: "The download is damaged. Try again."
        case .notEnoughSpace(let required, let available):
            "Not enough disk space: this needs \(format(required)), and \(format(available)) is available."
        case .wrongFile(let model, let version): "This isn’t the IPSW Light Touch knows for \(model) iOS \(version)."
        case .unsupported: "This IPSW isn’t supported."
        case .noneSupported: "None of these files is a supported IPSW."
        case .failed(let message): message
        }
    }
}

public nonisolated struct IPSWStore: Sendable {
    /// Caches/<bundle>/IPSW: CDN downloads, their .partial and .resume files.
    public let downloads: URL
    /// State/IPSW: user imports.
    public let imports: URL

    public static var shared: IPSWStore {
        IPSWStore(
            downloads: cachesDirectory.appendingPathComponent("IPSW", isDirectory: true),
            imports: Bundled.stateDirectory.appendingPathComponent("IPSW", isDirectory: true)
        )
    }

    /// ~/Library/Caches/<bundle>; also where the preparer keeps Decrypted/.
    public static var cachesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(StorageLocations.bundleIdentifier, isDirectory: true)
    }

    public func download(_ sha1: String) -> URL { downloads.appendingPathComponent("\(sha1).ipsw") }
    public func partial(_ sha1: String) -> URL { downloads.appendingPathComponent("\(sha1).partial") }
    public func resumeData(_ sha1: String) -> URL { downloads.appendingPathComponent("\(sha1).resume") }
    public func imported(_ sha1: String) -> URL { imports.appendingPathComponent("\(sha1).ipsw") }

    /// The IPSW with this sha1 if either store has it. A referenced IPSW counts only while its file is there with
    /// the size and modification date it was hashed at; otherwise the reference goes, and the entry isn't downloaded.
    public func existing(_ sha1: String) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: download(sha1).path) { return download(sha1) }
        let link = imported(sha1)
        guard let file = referenced(sha1) else { return fm.fileExists(atPath: link.path) ? link : nil }
        if let stamp = Self.stamp(file), stamp == Self.recordedStamp(link) { return link }
        try? fm.removeItem(at: link)
        return nil
    }

    /// The user's file that State/IPSW/<sha1>.ipsw refers to, if it is a reference (whether or not it's still there).
    public func referenced(_ sha1: String) -> URL? {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: imported(sha1).path)).map {
            URL(fileURLWithPath: $0)
        }
    }

    /// A reference's record of its file: size and modification date, an extended attribute on the link itself.
    private static let stampAttribute = "\(StorageLocations.bundleIdentifier).ipsw-stamp"

    private static func stamp(_ file: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? Int64, let date = attributes[.modificationDate] as? Date
        else { return nil }
        return "\(size) \(date.timeIntervalSince1970)"
    }

    private static func recordedStamp(_ link: URL) -> String? {
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = getxattr(link.path, stampAttribute, &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        return count > 0 ? String(decoding: buffer.prefix(count), as: UTF8.self) : nil
    }

    // MARK: - Checks

    /// SHA1 of a file read in 4 MiB chunks, never whole. `progress` gets the fraction read. Throws CancellationError
    /// between chunks once the task it runs in is cancelled.
    public static func sha1(of url: URL, progress: ((Double) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = max(1, (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 1)
        var hash = Insecure.SHA1()
        var read: Int64 = 0
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
            read += Int64(chunk.count)
            progress?(Double(read) / Double(size))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Checks a finished download's size and sha1, then renames it to
    /// <sha1>.ipsw. On a mismatch the file is deleted.
    public func install(_ file: URL, sha1: String, bytes: Int64?) throws -> URL {
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

    /// A "rar" source's finished download (`file`): `firmwarekit unwrap` checks the archive against the entry,
    /// extracts its IPSW and checks that, into <sha1>.ipsw. The archive goes either way; a refusal is `.corrupted`,
    /// so the download moves on to the next source as for a plain IPSW.
    public func installArchive(_ file: URL, entry: FirmwareCatalog.Entry, preparer: URL?) throws -> URL {
        let fm = FileManager.default
        let entryFile = file.appendingPathExtension("entry.json")
        defer {
            try? fm.removeItem(at: file)
            try? fm.removeItem(at: entryFile)
        }
        guard let preparer, let sha1 = entry.source.sha1 else { throw FirmwareError.unsupported }
        try JSONEncoder().encode(entry).write(to: entryFile)
        let unwrap = Process()
        unwrap.executableURL = preparer
        unwrap.arguments = FirmwareCommand.Unwrap(entry: entryFile, archive: file, out: download(sha1)).arguments
        unwrap.standardOutput = FileHandle.nullDevice
        unwrap.standardError = FileHandle.nullDevice
        try unwrap.run()
        unwrap.waitUntilExit()
        guard unwrap.terminationStatus == 0, fm.fileExists(atPath: download(sha1).path) else {
            throw FirmwareError.corrupted
        }
        return download(sha1)
    }

    /// `url` or its nearest existing parent, for volume questions.
    private static func existing(_ url: URL) -> URL {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        return probe
    }

    public static func availableSpace(at url: URL) throws -> Int64 {
        try StorageCapacity.available(at: existing(url))
    }

    /// Free space for `required` bytes on the volume holding `url` (or its nearest existing parent).
    public static func checkSpace(_ required: Int64, at url: URL) throws {
        try checkSpace(required, available: availableSpace(at: url))
    }

    /// Below this, booting and recording go ahead with a warning.
    public static let lowSpaceThreshold: Int64 = 2_000_000_000

    /// The warning for booting or recording with little room left, else nil.
    public static func lowSpaceWarning(at url: URL) -> String? {
        guard let available = try? availableSpace(at: url), available < lowSpaceThreshold else { return nil }
        let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return
            "Your Mac is almost out of disk space: \(format(available)) is available, and Light Touch needs at least \(format(lowSpaceThreshold)) to save changes reliably."
    }

    public static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let x = try? existing(a).resourceValues(forKeys: [key]).volumeIdentifier as? NSObject,
            let y = try? existing(b).resourceValues(forKeys: [key]).volumeIdentifier as? NSObject
        else { return false }
        return x.isEqual(y)
    }

    public static func checkSpace(_ required: Int64, available: Int64) throws {
        guard available >= required else {
            throw FirmwareError.notEnoughSpace(required: required, available: available)
        }
    }

    // MARK: - Import

    /// ProductType and ProductBuildVersion from the IPSW's Restore.plist, or nil if it has none.
    public static func restoreInfo(_ ipsw: URL) -> (productType: String, build: String)? {
        guard let data = ZipMembers.data(ipsw, "Restore.plist"),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let type = plist["ProductType"] as? String, let build = plist["ProductBuildVersion"] as? String
        else { return nil }
        return (type, build)
    }

    /// The entry pinning this sha1, else why not: the same ProductType and
    /// build as an entry means the wrong file, anything else is unsupported.
    public static func match(
        sha1: String,
        restore: (productType: String, build: String)?,
        in catalog: FirmwareCatalog
    ) throws -> FirmwareCatalog.Entry {
        let ipsw = catalog.entries
        if let entry = ipsw.first(where: { $0.source.sha1 == sha1 }) { return entry }
        if let restore,
            let entry = ipsw.first(where: { $0.productType == restore.productType && $0.build == restore.build })
        {
            throw FirmwareError.wrongFile(model: entry.marketingName, version: entry.version)
        }
        throw FirmwareError.unsupported
    }

    /// Hashes a user's IPSW, matches it to the catalog and clones it into
    /// State/IPSW (APFS clonefile on the same volume); from another volume it
    /// records a reference instead of copying (`existing` checks it).
    /// Offline: nothing here touches the network. Cancelling its task stops it,
    /// and nothing it copied is kept.
    public func importIPSW(
        _ url: URL,
        catalog: FirmwareCatalog,
        progress: ((Double) -> Void)? = nil
    ) throws -> (entry: FirmwareCatalog.Entry, ipsw: URL) {
        // A reference names the file itself, not a link to it.
        let url = url.resolvingSymlinksInPath()
        // Taken before hashing: a file changed while it's read doesn't match.
        let stamp = Self.stamp(url)
        let sha1 = try Self.sha1(of: url, progress: progress)
        let entry = try Self.match(sha1: sha1, restore: Self.restoreInfo(url), in: catalog)
        if let existing = existing(sha1) { return (entry, existing) }
        try StorageLocations.privateDirectory(imports)
        StorageLocations.excludeFromBackup(imports)
        let destination = imported(sha1)
        if !Self.sameVolume(url, imports), let stamp {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: url.absoluteURL)
            guard setxattr(destination.path, Self.stampAttribute, stamp, stamp.utf8.count, 0, XATTR_NOFOLLOW) == 0
            else {
                let reason = String(cString: strerror(errno))
                try? FileManager.default.removeItem(at: destination)
                throw FirmwareError.failed(reason)
            }
            return (entry, destination)
        }
        let temporary = imports.appendingPathComponent(".\(sha1).importing")
        try? FileManager.default.removeItem(at: temporary)
        try FileManager.default.copyItem(at: url, to: temporary)
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: temporary)
            throw CancellationError()
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return (entry, destination)
    }

    /// Copy into Light Touch: a reference's file copied into State/IPSW, so the IPSW no longer needs that file's disk.
    /// The copy replaces the reference only once it's whole, by rename(2), which replaces the link itself and never
    /// follows it to the user's file.
    public func copyIn(_ sha1: String) throws {
        guard existing(sha1) != nil, let file = referenced(sha1) else { throw CocoaError(.fileNoSuchFile) }
        let temporary = imports.appendingPathComponent(".\(sha1).importing")
        try? FileManager.default.removeItem(at: temporary)
        try FileManager.default.copyItem(at: file, to: temporary)
        guard rename(temporary.path, imported(sha1).path) == 0 else {
            let error = StorageLocations.posixError()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    // MARK: - Removal

    /// Posted after Remove IPSW: rows that said Downloaded read the store again.
    public static let didChangeNotification = Notification.Name("IPSWStoreDidChange")

    /// Remove IPSW: the download, its .partial and .resume, and the import (a reference only, never the user's file).
    public func remove(_ sha1: String) throws {
        defer { NotificationCenter.default.post(name: Self.didChangeNotification, object: nil) }
        for url in [download(sha1), partial(sha1), resumeData(sha1), imported(sha1)]
        where (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Launch, under the app lock: a .partial outlives only a crash (it's
    /// renamed within one delegate call), and so does an .importing copy.
    public func sweep() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: downloads.path)) ?? [] where name.hasSuffix(".partial") {
            try? fm.removeItem(at: downloads.appendingPathComponent(name))
        }
        for name in (try? fm.contentsOfDirectory(atPath: imports.path)) ?? []
        where name.hasPrefix(".") && name.hasSuffix(".importing") {
            try? fm.removeItem(at: imports.appendingPathComponent(name))
        }
    }
}
