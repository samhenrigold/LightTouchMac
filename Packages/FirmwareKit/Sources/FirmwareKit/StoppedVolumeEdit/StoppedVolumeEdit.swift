import CryptoKit
import Darwin
import Foundation

/// The N72 generated-store adapter is provisional. Transactions are shared;
/// physical FTL/crypto formats require their own guest-mediated writer.
public enum StoppedVolumeEdit {
    public struct Session: Codable, Sendable {
        public let id: UUID
        public let device: URL
        public let image: URL
        public let mountPoint: String?
    }
    private static var fm: FileManager { .default }

    public static func begin(device: URL, log: (String) -> Void = { _ in }) throws -> Session {
        let record = try object(device.appendingPathComponent("device.json"))
        guard record["board"] as? String == "n72ap" else {
            throw FirmwareError(.unsupported, "stopped writable volumes currently support the N72 generated store only")
        }
        let source = try VolumeExport.Source(device: device)
        guard try VolumeRebuild.board(of: source.base) == .ipod else {
            throw FirmwareError(.unsupported, "this device does not have a supported writable store")
        }
        let sourceLock = try object(source.base.deletingLastPathComponent().appendingPathComponent("device.lock.json"))
        guard let derived = sourceLock["derived"] as? [String: Any], let epoch = derived["nand_epoch"] as? Int,
              derived["storage_layout"] == nil || derived["storage_layout"] as? String == "n72-generated-v1" else {
            throw FirmwareError(.unsupported, "writable export requires the N72 generated layout; physical FTL storage must use guest services")
        }
        // Certify the fixed mapping in legacy locks before applying its writer.
        // Arbitrary page directories are not an interchangeable storage format.
        for (page, bytes) in N72NAND.metadataPages(blocks: 0, epoch: epoch) where page.page < 128 {
            guard try Data(contentsOf: source.base.appendingPathComponent("cs\(page.cs)/\(page.page).page")) == Data(bytes) else {
                throw FirmwareError(.unsupported, "N72 mapping metadata differs; use guest services for this store")
            }
        }
        let transaction = try StorageGeneration.begin(device: device)
        let exported = try VolumeExport.export(.init(base: source.base, overlay: source.overlay),
                                               out: transaction.volumes, log: log)
        guard exported.count == 1 else { throw FirmwareError(.unsupported, "N72 edit requires one logical volume") }
        let image = URL(fileURLWithPath: exported[0].image)
        try clone(image, to: transaction.root.appendingPathComponent("original.img"))
        try StorageGeneration.write(JSONEncoder().encode(HFSPlusVolume(image).listing(hashes: false)),
                                    to: transaction.root.appendingPathComponent("metadata.json"))
        // Clone immutable boot material, never edit the original prepared base.
        let nand = source.base.resolvingSymlinksInPath()
        let originalBase = nand.deletingLastPathComponent()
        try clone(originalBase, to: transaction.base)
        try makeWritable(transaction.base)
        let oldNAND = transaction.base.appendingPathComponent("nand")
        try fm.removeItem(at: oldNAND)
        try fm.createDirectory(at: transaction.overlay, withIntermediateDirectories: false)
        let state = device.deletingLastPathComponent().deletingLastPathComponent()
        let storage = record["storage"] as! [String: Any]
        if let path = storage["writableNOR"] as? String {
            let nor = resolve(path, state: state)
            let original = fm.fileExists(atPath: nor.path) ? nor : originalBase.appendingPathComponent("nor.bin")
            try clone(original, to: transaction.root.appendingPathComponent("nor.bin"))
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transaction.root.appendingPathComponent("nor.bin").path)
        }
        try StorageGeneration.write(JSONEncoder().encode(Session(id: transaction.id, device: device, image: image, mountPoint: nil)),
                                    to: transaction.root.appendingPathComponent("session.json"))
        return Session(id: transaction.id, device: device, image: image, mountPoint: nil)
    }

    /// The durable edit intent, rather than a long-lived CLI process, excludes
    /// guest boot for the entire Finder mount. Closing Finder is not commit.
    public static func mount(device: URL, id: UUID) throws -> Session {
        let edit = try StorageGeneration.resume(device: device, id: id)
        let session = try readSession(edit)
        try eject(edit)
        let attached = try DiskImage.attach(session.image, mount: true)
        let mounted = Session(id: id, device: device, image: session.image, mountPoint: attached.mountPoint)
        try StorageGeneration.write(JSONEncoder().encode(mounted), to: edit.root.appendingPathComponent("session.json"))
        return mounted
    }

    public static func commit(device: URL, id: UUID, log: (String) -> Void = { _ in }) throws {
        let edit = try StorageGeneration.resume(device: device, id: id)
        let session = try readSession(edit)
        try eject(edit)
        let before = try JSONDecoder().decode([HFSPlusVolume.Entry].self, from: Data(contentsOf: edit.root.appendingPathComponent("metadata.json")))
        try preserveMetadata(edit: edit, image: session.image, before: before)
        let hfs = try HFSPlusVolume(session.image, writable: true)
        let lockURL = edit.base.appendingPathComponent("device.lock.json")
        let originalLockData = try Data(contentsOf: lockURL)
        var lock = try object(lockURL)
        guard let epoch = (lock["derived"] as? [String: Any])?["nand_epoch"] as? Int else {
            throw FirmwareError(.unsupported, "device lock lacks its NAND epoch")
        }
        let nand = edit.base.appendingPathComponent("nand")
        if fm.fileExists(atPath: nand.path) { try fm.removeItem(at: nand) }
        log("building edited N72 generation")
        _ = try N72NAND.write(volume: session.image, blocks: hfs.totalBlocks * hfs.blockSize / N72NAND.page, epoch: epoch, out: nand)
        let roundtrip = edit.root.appendingPathComponent("roundtrip")
        if fm.fileExists(atPath: roundtrip.path) { try fm.removeItem(at: roundtrip) }
        let reconstructed = try VolumeRebuild.rebuild(base: nand, overlay: nil, into: roundtrip)
        let expected = try Preparer.digest(session.image, SHA256())
        guard reconstructed.count == 1, try Preparer.digest(reconstructed[0].image, SHA256()) == expected else {
            throw FirmwareError(.internal, "edited NAND did not reconstruct to the exact volume; original retained")
        }
        let files = try Recipe.nandFiles(nand)
        let listing = try Preparer.nandListing(nand, files: files)
        var derived = lock["derived"] as? [String: Any] ?? [:]
        derived.removeValue(forKey: "built_listing_sha256")
        derived.removeValue(forKey: "listing_sha256")
        derived["storage_layout"] = "n72-generated-v1"
        derived["storage_generation"] = id.uuidString
        lock["derived"] = derived
        var outputs = lock["outputs"] as? [String: Any] ?? [:]
        outputs["nand"] = ["path": "nand", "pages": files.filter { $0.hasSuffix(".page") }.count,
                           "listing_sha256": listing.sha256, "built_listing_sha256": listing.sha256]
        // Immutable boot outputs were cloned, so update legacy absolute output
        // paths only when their named file actually exists in the new base.
        for (name, value) in outputs where name != "nand" {
            guard var output = value as? [String: Any], let path = output["path"] as? String else { continue }
            let filename = URL(fileURLWithPath: path).lastPathComponent
            if fm.fileExists(atPath: edit.base.appendingPathComponent(filename).path) {
                output["path"] = filename; outputs[name] = output
            }
        }
        lock["outputs"] = outputs
        var maintenance: [String: Any] = ["kind": "stopped-volume-edit", "volume_sha256": expected,
            "generation": id.uuidString, "original_lock_sha256": StorageGeneration.hash(originalLockData)]
        let workingNOR = edit.root.appendingPathComponent("nor.bin")
        if fm.fileExists(atPath: workingNOR.path) {
            maintenance["working_nor_sha256"] = try Preparer.digest(workingNOR, SHA256())
        }
        lock["maintenance"] = maintenance
        let lockData = try JSONSerialization.data(withJSONObject: lock, options: [.prettyPrinted, .sortedKeys])
        try StorageGeneration.write(lockData, to: lockURL)
        let provenance: [String: Any] = ["lock": try edit.recordPath(lockURL), "sha256": StorageGeneration.hash(lockData)]
        try Preparer.readOnly(edit.base)
        try edit.publish(record: edit.candidateRecord(provenance: provenance))
        log("published storage generation \(id.uuidString)")
    }

    public static func discard(device: URL, id: UUID) throws {
        let edit = try StorageGeneration.resume(device: device, id: id)
        try eject(edit)
        try edit.discard()
    }
    public static func recover(device: URL, id: UUID) throws {
        let edit = try StorageGeneration.resume(device: device, id: id)
        try edit.recoverPublication()
    }

    private static func readSession(_ edit: StorageGeneration) throws -> Session {
        let session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: edit.root.appendingPathComponent("session.json")))
        guard session.id == edit.id, session.image.resolvingSymlinksInPath().path.hasPrefix(edit.volumes.path + "/") else {
            throw FirmwareError(.internal, "invalid stopped-edit session")
        }
        return session
    }
    private static func eject(_ edit: StorageGeneration) throws {
        let prefix = edit.root.resolvingSymlinksInPath().path + "/"
        for attached in try DiskImage.checkedAttachedImages() where URL(fileURLWithPath: attached.image).resolvingSymlinksInPath().path.hasPrefix(prefix) {
            DiskImage.detach(attached.device) // Never force an editor's open files.
        }
        guard try DiskImage.checkedAttachedImages().allSatisfy({ !URL(fileURLWithPath: $0.image).resolvingSymlinksInPath().path.hasPrefix(prefix) }) else {
            throw FirmwareError(.internal, "edit volume is still busy; close its files and retry")
        }
    }
    private static func preserveMetadata(edit: StorageGeneration, image: URL, before: [HFSPlusVolume.Entry]) throws {
        let original = edit.root.appendingPathComponent("original.img")
        let originalHFS = try HFSPlusVolume(original)
        let oldLinks = Dictionary(grouping: try originalHFS.paths().filter { $0.record.isHardLink }, by: { $0.record.special })
        let editedHFS = try HFSPlusVolume(image)
        let afterRecords = Dictionary(uniqueKeysWithValues: try editedHFS.paths().map { ($0.path, $0.record) })
        for group in oldLinks.values {
            let remaining = group.compactMap { afterRecords[$0.path] }
            guard remaining.allSatisfy(\.isHardLink), Set(remaining.map(\.special)).count <= 1 else {
                throw FirmwareError(.unsupported, "an edit replaced a hard link; original retained, restore its link group before committing")
            }
        }
        // The kernel manages compression attributes and their storage forks.
        // Only restore missing ordinary metadata; never reattach old compressed
        // bytes to newly edited uncompressed content.
        // This is a private baseline copy. Mount through the native driver so
        // it can recover its journal; never mount the source device's flash.
        try VolumeMount.withMounted(original, at: edit.root.appendingPathComponent("baseline-mount")) { baseline in
            try VolumeMount.withMounted(image, at: edit.root.appendingPathComponent("metadata-mount")) { root in
                for entry in before where !entry.path.isEmpty && ![".journal", ".journal_info_block"].contains(entry.path) && afterRecords[entry.path] != nil {
                    let src = baseline.appendingPathComponent(entry.path)
                    let dst = root.appendingPathComponent(entry.path)
                    do { try restoreMissingAttributes(from: src, to: dst, compressed: entry.flags & UInt32(UF_COMPRESSED) != 0) }
                    catch { throw FirmwareError(.internal, "restore metadata for \(entry.path): \(error)") }
                }
            }
        }
        let volume = try HFSPlusVolume(image, writable: true)
        let existing = Dictionary(uniqueKeysWithValues: before.map { ($0.path, $0) })
        let after = try volume.listing(hashes: false)
        struct Owner: Hashable { let uid: UInt32, gid: UInt32; let mode: UInt16; let flags: UInt32 }
        var groups: [Owner: [String]] = [:]
        for entry in after where !entry.path.isEmpty {
            let owner: Owner
            if let old = existing[entry.path] {
                owner = Owner(uid: old.uid, gid: old.gid, mode: old.mode,
                    flags: old.flags & ~UInt32(UF_COMPRESSED) | entry.flags & UInt32(UF_COMPRESSED))
            } else {
                var parent = (entry.path as NSString).deletingLastPathComponent
                while existing[parent] == nil && !parent.isEmpty { parent = (parent as NSString).deletingLastPathComponent }
                let ancestor = existing[parent]
                owner = Owner(uid: ancestor?.uid ?? 0, gid: ancestor?.gid ?? 0, mode: entry.mode, flags: entry.flags)
            }
            groups[owner, default: []].append(entry.path)
        }
        for (owner, paths) in groups {
            try volume.setOwner(paths, uid: owner.uid, gid: owner.gid, mode: owner.mode, flags: owner.flags)
        }
        let checked = try VolumeMount.attach(image)
        defer { VolumeMount.detach(checked) }
        guard VolumeMount.check(checked).ok else { throw FirmwareError(.internal, "edited metadata failed filesystem validation") }
    }
    private static func restoreMissingAttributes(from source: URL, to destination: URL, compressed: Bool) throws {
        let size = listxattr(source.path, nil, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var names = [CChar](repeating: 0, count: size)
        if size == 0 { return }
        guard listxattr(source.path, &names, size, XATTR_NOFOLLOW) == size else { throw POSIXError(.EIO) }
        for bytes in names.split(separator: 0) {
            let name = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name == "com.apple.decmpfs" || compressed && name == "com.apple.ResourceFork" { continue }
            if getxattr(destination.path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0 { continue }
            guard errno == ENOATTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let count = getxattr(source.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var value = [UInt8](repeating: 0, count: count)
            guard getxattr(source.path, name, &value, count, 0, XATTR_NOFOLLOW) == count,
                  setxattr(destination.path, name, value, count, 0, XATTR_NOFOLLOW) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }
    private static func resolve(_ path: String, state: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : state.appendingPathComponent(path)
    }
    private static func object(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw FirmwareError(.internal, "invalid device metadata")
        }
        return value
    }
    private static func clone(_ source: URL, to destination: URL) throws {
        guard clonefile(source.path, destination.path, 0) == 0 else {
            throw FirmwareError(.internal, "clone staging: \(String(cString: strerror(errno)))")
        }
    }
    private static func makeWritable(_ directory: URL) throws {
        guard chflags(directory.path, 0) == 0, chmod(directory.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        for child in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw FirmwareError(.internal, "prepared base contains a symlink") }
            if values.isDirectory == true { try makeWritable(child) } else {
                guard chflags(child.path, 0) == 0, chmod(child.path, 0o600) == 0 else { throw POSIXError(.EIO) }
            }
        }
    }
}
