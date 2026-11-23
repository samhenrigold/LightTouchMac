import Crypto
import Darwin
import Foundation
import HostRuntime

/// The N72 generated-store adapter is provisional. Transactions are shared.
///
/// 1.x devices (n45ap, m68ap; the legacy FTL, N45FTL) are edited in place instead: the generation keeps a clone
/// of the base and of the overlay, and commit writes each changed logical page over the physical page the FTL
/// maps it to in the overlay clone (its spare kept). The FTL's context is untouched, so the guest reads the new
/// data where it expects the old. A device the FTL did not shut down cleanly is refused (N45FTL).
///
/// YaFTL devices (the iPad, the A4 and S5L8920 boards; K48NAND) have a data volume beside the system volume; it mounts
/// on the system volume's private/var. Commit lays both out into a fresh store as preparation does (K48NAND.rebuild),
/// with the store's own MBR and signature, and the generation starts with an empty overlay.
public enum StoppedVolumeEdit {
    public struct Session: Codable, Sendable {
        public let id: UUID
        public let device: URL
        public let image: URL
        public let mountPoint: String?
        /// The data volume (YaFTL devices), mounted at the system volume's private/var.
        public var data: URL? = nil
        /// Each volume and the suffix of its baseline files ("original.img", "metadata.json").
        var volumes: [(image: URL, suffix: String)] { [(image, "")] + (data.map { [($0, "-data")] } ?? []) }
    }
    private static var fm: FileManager { .default }

    nonisolated(nonsending) public static func begin(
        device: URL,
        policy: StorageRecordPolicy = .standalone,
        log: (String) -> Void = { _ in }
    ) async throws -> Session {
        let (transaction, source, paths, bytes) = try admit(device: device, policy: policy)
        let record = try object(bytes)
        return try await StorageGeneration.withOwner(transaction) { transaction in
            let exported = try await VolumeExport.export(
                .init(base: source.base, overlay: source.overlay),
                out: transaction.volumes,
                log: log
            )
            guard exported.first?.volume == "system", exported.dropFirst().allSatisfy({ $0.volume == "data" }),
                exported.count <= 2
            else {
                throw FirmwareError(.unsupported, "a stopped edit requires a system volume and at most a data volume")
            }
            let image = URL(fileURLWithPath: exported[0].image)
            let data = exported.count == 2 ? URL(fileURLWithPath: exported[1].image) : nil
            let session = Session(id: transaction.id, device: device, image: image, mountPoint: nil, data: data)
            for (volume, suffix) in session.volumes {
                try clone(volume, to: transaction.root.appendingPathComponent("original\(suffix).img"))
                try StorageGeneration.write(
                    JSONEncoder().encode(HFSPlusVolume(volume).listing(hashes: false)),
                    to: transaction.root.appendingPathComponent("metadata\(suffix).json")
                )
            }
            // Clone immutable boot material, never edit the original prepared base.
            let nand = source.base.resolvingSymlinksInPath()
            let originalBase = nand.deletingLastPathComponent()
            try clone(originalBase, to: transaction.base)
            try makeWritable(transaction.base)
            let oldNAND = transaction.base.appendingPathComponent("nand")
            let store = try VolumeRebuild.board(of: oldNAND)
            if store == .ipad {
                // The store and overlay as the guest left them, commit's inputs (never written: a commit cut short
                // starts over from them); the new store goes in the base, under an empty overlay.
                try fm.moveItem(at: oldNAND, to: transaction.root.appendingPathComponent("guest-nand"))
                if let overlay = source.overlay {
                    try clone(overlay, to: transaction.root.appendingPathComponent("guest-overlay"))
                }
                try fm.createDirectory(at: transaction.overlay, withIntermediateDirectories: false)
            } else if store == .legacy {
                // edited in place: the overlay as the guest left it, written over at commit
                if let overlay = source.overlay {
                    try clone(overlay, to: transaction.overlay)
                } else {
                    try fm.createDirectory(at: transaction.overlay, withIntermediateDirectories: false)
                }
                // The overlay belongs to the generation's key now (PreparedDeviceBoot.pinOverlay): the clone's stamp
                // names the old one, and a fresh overlay that takes the edit's pages would have none.
                try Data(transaction.id.uuidString.utf8).write(
                    to: transaction.overlay.appendingPathComponent(".base-identity"),
                    options: .atomic
                )
            } else {
                try fm.removeItem(at: oldNAND)
                try fm.createDirectory(at: transaction.overlay, withIntermediateDirectories: false)
            }
            guard let storage = record["storage"] as? [String: Any] else {
                throw FirmwareError(.unsupported, "invalid device metadata")
            }
            if let path = storage["writableNOR"] as? String {
                let nor = StorageRecordPaths.resolve(path, relativeRoot: paths.relativeRoot)
                let original = fm.fileExists(atPath: nor.path) ? nor : originalBase.appendingPathComponent("nor.bin")
                try clone(original, to: transaction.root.appendingPathComponent("nor.bin"))
                try fm.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: transaction.root.appendingPathComponent("nor.bin").path
                )
            }
            try StorageGeneration.write(
                JSONEncoder().encode(session),
                to: transaction.root.appendingPathComponent("session.json")
            )
            return session
        }
    }

    private static func admit(device: URL, policy: StorageRecordPolicy) throws
        -> (StorageGeneration, VolumeExport.ResolvedSource, StorageRecordPaths, Data)
    {
        let owner = try OwnedStorageRecord.acquire(device: device, policy: policy)
        guard let bytes = owner.bytes, let record = try? DeviceRecord.object(bytes),
            let paths = owner.paths
        else { throw FirmwareError(.unsupported, "invalid device metadata") }
        defer { withExtendedLifetime(owner) {} }
        let source = VolumeExport.ResolvedSource(owner: owner)
        if let overlay = source.overlay { try refuseLinks(overlay) }  // before anything reads it
        if try VolumeRebuild.board(of: source.base) == .ipad {
            return (try StorageGeneration.begin(owner: owner), source, paths, bytes)
        }
        if HostRuntime.Board(rawValue: record["board"] as? String ?? "")?.soc == .s5l8900,
            try VolumeRebuild.board(of: source.base) == .legacy
        {
            _ = try N45FTL(base: source.base, overlay: source.overlay)  // refuses an unclean FTL before any work
            return (try StorageGeneration.begin(owner: owner), source, paths, bytes)
        }
        guard record["board"] as? String == "n72ap" else {
            throw FirmwareError(
                .unsupported,
                "stopped writable volumes support the N72 generated store, YaFTL stores and 1.x devices only"
            )
        }
        guard try VolumeRebuild.board(of: source.base) == .ipod else {
            throw FirmwareError(.unsupported, "this device does not have a supported writable store")
        }
        let sourceLock = try DeviceLock.read(base: source.base.deletingLastPathComponent())
        guard let epoch = sourceLock?.nandEpoch,
            [nil, "n72-generated-v1"].contains(sourceLock?.derived?["storage_layout"]?.string)
        else {
            throw FirmwareError(
                .unsupported,
                "writable export requires the N72 generated layout; physical FTL storage must use guest services"
            )
        }
        // Certify the fixed mapping in legacy locks before applying its writer.
        // Arbitrary page directories are not an interchangeable storage format.
        let read = try N72NANDImage.reader(base: source.base, overlay: nil)
        for (page, bytes) in N72NAND.metadataPages(blocks: 0, epoch: epoch) where page.page < 128 {
            guard try read(page) == bytes else {
                throw FirmwareError(.unsupported, "N72 mapping metadata differs; use guest services for this store")
            }
        }
        return (try StorageGeneration.begin(owner: owner), source, paths, bytes)
    }
    private static func object(_ bytes: Data) throws -> [String: Any] {
        guard let record = try? DeviceRecord.object(bytes) else {
            throw FirmwareError(.unsupported, "invalid device metadata")
        }
        return record
    }

    /// The durable edit intent, rather than a long-lived CLI process, excludes
    /// guest boot for the entire Finder mount. Closing Finder is not commit.
    /// `mountPoint`: the folder the volume is mounted on, out of Finder's sidebar (nobrowse); the edit's own
    /// "File System" folder when nil.
    nonisolated(nonsending) public static func mount(
        device: URL,
        id: UUID,
        policy: StorageRecordPolicy = .standalone,
        mountPoint: URL? = nil
    ) async throws -> Session {
        try await StorageGeneration.withOwner(
            try StorageGeneration.resume(device: device, id: id, policy: policy)
        ) { edit in
            let session = try readSession(edit)
            try await eject(edit)
            let root = mountPoint ?? edit.root.appendingPathComponent("File System")
            let attached = try await VolumeMount.attachHidden(session.image, at: root)
            if let data = session.data {
                do {
                    _ = try await VolumeMount.attachHidden(
                        data,
                        on: attached.mountPoint ?? root.path,
                        at: "private/var"
                    )
                } catch {
                    try? await eject(edit)
                    throw error
                }
            }
            let mounted = Session(
                id: id,
                device: device,
                image: session.image,
                mountPoint: attached.mountPoint,
                data: session.data
            )
            try StorageGeneration.write(
                JSONEncoder().encode(mounted),
                to: edit.root.appendingPathComponent("session.json")
            )
            return mounted
        }
    }

    /// `amend`: after the volumes' metadata is settled and before the store is built, with the system volume's image
    /// and the generation's (writable) base; the members it returns go into the generation's lock. On a 1.x (legacy
    /// FTL) store the base keeps its boot files: only the lock takes the members.
    nonisolated(nonsending) public static func commit(
        device: URL,
        id: UUID,
        policy: StorageRecordPolicy = .standalone,
        log: (String) -> Void = { _ in },
        amend: ((_ system: URL, _ base: URL) throws -> [String: Any])? = nil
    ) async throws {
        try await StorageGeneration.withOwner(try StorageGeneration.resume(device: device, id: id, policy: policy)) {
            edit in
            let session = try readSession(edit)
            try await eject(edit)
            for (image, suffix) in session.volumes {
                let before = try JSONDecoder().decode(
                    [HFSPlusVolume.Entry].self,
                    from: Data(contentsOf: edit.root.appendingPathComponent("metadata\(suffix).json"))
                )
                try await preserveMetadata(
                    edit: edit,
                    image: image,
                    original: edit.root.appendingPathComponent("original\(suffix).img"),
                    before: before
                )
            }
            if (try? VolumeRebuild.board(of: edit.base.appendingPathComponent("nand"))) == .legacy {
                if let amend {  // the 1.x jailbreak's lock member (StoppedVolumeEdit.jailbreak1x)
                    let lockURL = edit.base.appendingPathComponent("device.lock.json")
                    var lock = try object(lockURL)
                    try makeWritable(edit.base)
                    lock.merge(try amend(session.image, edit.base)) { $1 }
                    try StorageGeneration.write(try DeviceLock(json: lock).data(), to: lockURL)
                }
                try await commitLegacy(edit: edit, image: session.image, log: log)
                return
            }
            let lockURL = edit.base.appendingPathComponent("device.lock.json")
            let originalLockData = try Data(contentsOf: lockURL)
            var lock = try object(lockURL)
            if let amend {
                try makeWritable(edit.base)
                lock.merge(try amend(session.image, edit.base)) { $1 }
            }
            let nand = edit.base.appendingPathComponent("nand")
            let guestNAND = edit.root.appendingPathComponent("guest-nand")
            let yaftl = fm.fileExists(atPath: guestNAND.path)
            if yaftl {
                log("building the edited store")
                if fm.fileExists(atPath: nand.path) {  // a commit cut short, maybe after its base was made read-only
                    try makeWritable(edit.base)
                    try fm.removeItem(at: nand)
                }
                let guestOverlay = edit.root.appendingPathComponent("guest-overlay")
                try await K48NAND.rebuild(
                    store: guestNAND,
                    overlay: fm.fileExists(atPath: guestOverlay.path) ? guestOverlay : nil,
                    system: session.image,
                    data: session.data,
                    out: nand,
                    work: edit.root,
                    log: log
                )
            } else {
                guard let epoch = (lock["derived"] as? [String: Any])?["nand_epoch"] as? Int else {
                    throw FirmwareError(.unsupported, "device lock lacks its NAND epoch")
                }
                let hfs = try HFSPlusVolume(session.image, writable: true)
                if fm.fileExists(atPath: nand.path) { try fm.removeItem(at: nand) }
                log("building edited N72 generation")
                _ = try N72NAND.write(
                    volume: session.image,
                    blocks: hfs.totalBlocks * hfs.blockSize / N72NAND.page,
                    epoch: epoch,
                    out: nand
                )
            }
            let roundtrip = edit.root.appendingPathComponent("roundtrip")
            if fm.fileExists(atPath: roundtrip.path) { try fm.removeItem(at: roundtrip) }
            let reconstructed = try VolumeRebuild.rebuild(base: nand, overlay: nil, into: roundtrip)
            let expected = try session.volumes.map { try Preparer.digest($0.image, SHA256()) }
            guard try reconstructed.map({ try Preparer.digest($0.image, SHA256()) }) == expected else {
                throw FirmwareError(.internal, "edited NAND did not reconstruct to the exact volume; original retained")
            }
            try fm.removeItem(at: roundtrip)
            let files = try Recipe.nandFiles(nand)
            let listing = try Preparer.nandListing(nand, files: files)
            var derived = lock["derived"] as? [String: Any] ?? [:]
            derived.removeValue(forKey: "built_listing_sha256")
            derived.removeValue(forKey: "listing_sha256")
            if !yaftl { derived["storage_layout"] = "n72-generated-v1" }
            derived["storage_generation"] = id.uuidString
            lock["derived"] = derived
            var outputs = lock["outputs"] as? [String: Any] ?? [:]
            outputs["nand"] = [
                "path": "nand", "pages": files.filter { $0.hasSuffix(".page") }.count,
                "listing_sha256": listing.sha256, "built_listing_sha256": listing.sha256
            ]
            // Immutable boot outputs were cloned, so update legacy absolute output
            // paths only when their named file actually exists in the new base.
            for (name, value) in outputs where name != "nand" {
                guard var output = value as? [String: Any], let path = output["path"] as? String else { continue }
                let filename = URL(fileURLWithPath: path).lastPathComponent
                let file = edit.base.appendingPathComponent(filename)
                if fm.fileExists(atPath: file.path) {
                    output["path"] = filename
                    if output["sha256"] != nil { output["sha256"] = try Preparer.digest(file, SHA256()) }  // amend's
                    outputs[name] = output
                }
            }
            lock["outputs"] = outputs
            var maintenance: [String: Any] = [
                "kind": "stopped-volume-edit", "volume_sha256": expected[0],
                "generation": id.uuidString, "original_lock_sha256": StorageGeneration.hash(originalLockData)
            ]
            let workingNOR = edit.root.appendingPathComponent("nor.bin")
            if fm.fileExists(atPath: workingNOR.path) {
                maintenance["working_nor_sha256"] = try Preparer.digest(workingNOR, SHA256())
            }
            lock["maintenance"] = maintenance
            let lockData = try DeviceLock(json: lock).data()
            try StorageGeneration.write(lockData, to: lockURL)
            let provenance: [String: Any] = [
                "lock": try edit.recordPath(lockURL), "sha256": StorageGeneration.hash(lockData)
            ]
            try Preparer.readOnly(edit.base)
            // K48NAND.rebuild and N72NAND.write lay out image stores: a format 1 device leaves the edit in format 2
            let format = DeviceRecord.imageFormat
            try await edit.publish(record: edit.candidateRecord(provenance: provenance, format: format))
            log("published storage generation \(id.uuidString)")
            // the old store's clones would keep its blocks for as long as this generation lives
            for input in ["guest-nand", "guest-overlay"] {
                try? fm.removeItem(at: edit.root.appendingPathComponent(input))
            }
        }
    }

    /// 1.x: the edited volume's changed pages over the physical pages the FTL maps them to (in the generation's
    /// overlay clone), the journal left for the device to initialize (a host-written header says 512-byte blocks,
    /// which 1.x adopts and then fails its 2048-byte I/O with), then publish.
    nonisolated(nonsending) private static func commitLegacy(edit: StorageGeneration, image: URL, log: (String) -> Void)
        async throws
    {
        try HFSPlusVolume(image, writable: true).leaveJournalToDevice()
        let nand = edit.base.appendingPathComponent("nand")
        // an image store (format 2) is edited in the generation's live clone, made here if the device has none yet
        let live =
            PageNANDImage.of(nand) == nil
            ? nil
            : try PageNANDImage.Store(PreparedDeviceBoot.liveNAND(base: nand, overlay: edit.overlay), writable: true)
        let ftl = try N45FTL(base: nand, overlay: edit.overlay)
        let f = try FileHandle(forReadingFrom: image)
        defer { try? f.close() }
        let ps = N45NAND.page
        let room = (ftl.logicalPages - N45NAND.firstLBA) * ps
        guard try f.seekToEnd() <= room else {
            throw FirmwareError(.unsupported, "\(image.path) is larger than the \(room) bytes the FTL maps")
        }
        try f.seek(toOffset: 0)
        var changed = 0
        var lpn = N45NAND.firstLBA
        while let chunk = try f.read(upToCount: ps), !chunk.isEmpty {
            let data = [UInt8](chunk) + [UInt8](repeating: 0, count: ps - chunk.count)
            let old = ftl.read(lpn: lpn)
            if data != old?.data ?? [UInt8](repeating: 0, count: ps) {
                guard let p = ftl.location(lpn: lpn) else {
                    throw FirmwareError(.unsupported, "\(image.path): logical page \(lpn) is past the FTL's map")
                }
                let record = data + (old?.spare ?? N45NAND.dataSpare(lpn))
                if let live {
                    try live.write(p, record)
                } else {
                    let dir = edit.overlay.appendingPathComponent("bank\(p.bank)")
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    try Data(record).write(to: dir.appendingPathComponent("\(p.page).page"))
                }
                changed += 1
            }
            lpn += 1
        }
        try live?.sync()
        log("wrote \(changed) changed pages through the 1.x FTL")
        let lockURL = edit.base.appendingPathComponent("device.lock.json")
        let provenance: [String: Any] = [
            "lock": try edit.recordPath(lockURL), "sha256": StorageGeneration.hash(try Data(contentsOf: lockURL)),
            "kind": "stopped-volume-edit", "legacy_ftl_pages": changed
        ]
        try Preparer.readOnly(edit.base)
        try await edit.publish(record: edit.candidateRecord(provenance: provenance))
        log("published storage generation \(edit.id.uuidString)")
    }

    nonisolated(nonsending) public static func discard(device: URL, id: UUID, policy: StorageRecordPolicy = .standalone)
        async throws
    {
        try await StorageGeneration.withOwner(try StorageGeneration.resume(device: device, id: id, policy: policy)) {
            edit in
            try await eject(edit)
            try await edit.discard()
        }
    }
    nonisolated(nonsending) public static func recover(device: URL, id: UUID, policy: StorageRecordPolicy = .standalone)
        async throws
    {
        try await StorageGeneration.withOwner(try StorageGeneration.resume(device: device, id: id, policy: policy)) {
            edit in
            try await edit.recoverPublication()
        }
    }

    private static func readSession(_ edit: StorageGeneration) throws -> Session {
        let session = try JSONDecoder().decode(
            Session.self,
            from: Data(contentsOf: edit.root.appendingPathComponent("session.json"))
        )
        guard session.id == edit.id,
            session.volumes.allSatisfy({ $0.image.resolvingSymlinksInPath().path.hasPrefix(edit.volumes.path + "/") })
        else {
            throw FirmwareError(.internal, "invalid stopped-edit session")
        }
        return session
    }
    nonisolated(nonsending) private static func eject(_ edit: StorageGeneration) async throws {
        let prefix = edit.root.resolvingSymlinksInPath().path + "/"
        // the data volume first: it is mounted on the system volume
        let attachedImages = try await DiskImage.checkedAttachedImages()
        for attached in attachedImages.filter({ $0.image.hasSuffix("/data.img") })
            + attachedImages.filter({ !$0.image.hasSuffix("/data.img") })
        where URL(fileURLWithPath: attached.image).resolvingSymlinksInPath().path.hasPrefix(prefix) {
            try await DiskImage.detach(attached.device)  // Never force an editor's open files.
        }
        guard
            try await DiskImage.checkedAttachedImages().allSatisfy({
                !URL(fileURLWithPath: $0.image).resolvingSymlinksInPath().path.hasPrefix(prefix)
            })
        else {
            throw FirmwareError(.internal, "edit volume is still busy; close its files and retry")
        }
    }
    nonisolated(nonsending) private static func preserveMetadata(
        edit: StorageGeneration,
        image: URL,
        original: URL,
        before: [HFSPlusVolume.Entry]
    ) async throws {
        let originalHFS = try HFSPlusVolume(original)
        let oldLinks = Dictionary(
            grouping: try originalHFS.paths().filter { $0.record.isHardLink },
            by: { $0.record.special }
        )
        // Only entries that had attributes have any to restore. Listing every file's would also need read
        // access to each, which a mode-000 file (iOS 4's /.file) refuses on the mounted baseline.
        let originalRecords = Dictionary(uniqueKeysWithValues: try originalHFS.paths().map { ($0.path, $0.record) })
        let attributed = try originalHFS.attributeOwners()
        let editedHFS = try HFSPlusVolume(image)
        let afterRecords = Dictionary(uniqueKeysWithValues: try editedHFS.paths().map { ($0.path, $0.record) })
        for group in oldLinks.values {
            let remaining = group.compactMap { afterRecords[$0.path] }
            guard remaining.allSatisfy(\.isHardLink), Set(remaining.map(\.special)).count <= 1 else {
                throw FirmwareError(
                    .unsupported,
                    "an edit replaced a hard link; original retained, restore its link group before committing"
                )
            }
        }
        // The kernel manages compression attributes and their storage forks.
        // Only restore missing ordinary metadata; never reattach old compressed
        // bytes to newly edited uncompressed content.
        // This is a private baseline copy. Mount through the native driver so
        // it can recover its journal; never mount the source device's flash.
        try await VolumeMount.withMounted(original, at: edit.root.appendingPathComponent("baseline-mount")) {
            baseline in
            try await VolumeMount.withMounted(image, at: edit.root.appendingPathComponent("metadata-mount")) { root in
                for entry in before
                where !entry.path.isEmpty && ![".journal", ".journal_info_block"].contains(entry.path)
                    && afterRecords[entry.path] != nil
                    // a file the edit left in place kept its attributes (6.x's data volume: root's mode-600 logs)
                    && originalRecords[entry.path].map({ old in
                        old.isHardLink || old.cnid != afterRecords[entry.path]?.cnid
                    }) ?? true
                    && (entry.resourceSize > 0
                        || originalRecords[entry.path].map { $0.isHardLink || attributed.contains($0.cnid) } ?? true)
                {
                    let src = baseline.appendingPathComponent(entry.path)
                    let dst = root.appendingPathComponent(entry.path)
                    do {
                        try restoreMissingAttributes(
                            from: src,
                            to: dst,
                            compressed: entry.flags & UInt32(UF_COMPRESSED) != 0
                        )
                    } catch { throw FirmwareError(.internal, "restore metadata for \(entry.path): \(error)") }
                }
            }
        }
        let volume = try HFSPlusVolume(image, writable: true)
        let existing = Dictionary(uniqueKeysWithValues: before.map { ($0.path, $0) })
        let after = try volume.listing(hashes: false)
        struct Owner: Hashable {
            let uid: UInt32, gid: UInt32
            let mode: UInt16
            let flags: UInt32
        }
        var groups: [Owner: [String]] = [:]
        for entry in after where !entry.path.isEmpty {
            let owner: Owner
            if let old = existing[entry.path] {
                owner = Owner(
                    uid: old.uid,
                    gid: old.gid,
                    mode: old.mode,
                    flags: old.flags & ~UInt32(UF_COMPRESSED) | entry.flags & UInt32(UF_COMPRESSED)
                )
            } else {
                var parent = (entry.path as NSString).deletingLastPathComponent
                while existing[parent] == nil && !parent.isEmpty {
                    parent = (parent as NSString).deletingLastPathComponent
                }
                let ancestor = existing[parent]
                owner = Owner(uid: ancestor?.uid ?? 0, gid: ancestor?.gid ?? 0, mode: entry.mode, flags: entry.flags)
            }
            groups[owner, default: []].append(entry.path)
        }
        for (owner, paths) in groups {
            try volume.setOwner(paths, uid: owner.uid, gid: owner.gid, mode: owner.mode, flags: owner.flags)
        }
        let checked = try await VolumeMount.attach(image)
        let checkedResult: (ok: Bool, output: String)
        do { checkedResult = try await VolumeMount.check(checked) } catch {
            await VolumeMount.cleanupDetach(checked)
            throw error
        }
        try await VolumeMount.detach(checked)
        guard checkedResult.ok else { throw FirmwareError(.internal, "edited metadata failed filesystem validation") }
    }
    private static func restoreMissingAttributes(from source: URL, to destination: URL, compressed: Bool) throws {
        let size = listxattr(source.path, nil, 0, XATTR_NOFOLLOW_ANY)
        // macOS refuses a content-protected file (6.x on); its key wrapped the old contents, not the replacement's
        if size < 0, errno == EACCES || errno == EPERM { return }
        guard size >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var names = [CChar](repeating: 0, count: size)
        if size == 0 { return }
        guard listxattr(source.path, &names, size, XATTR_NOFOLLOW_ANY) == size else { throw POSIXError(.EIO) }
        for bytes in names.split(separator: 0) {
            let name = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name == "com.apple.decmpfs" || compressed && name == "com.apple.ResourceFork" { continue }
            if getxattr(destination.path, name, nil, 0, 0, XATTR_NOFOLLOW_ANY) >= 0 { continue }
            guard errno == ENOATTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let count = getxattr(source.path, name, nil, 0, 0, XATTR_NOFOLLOW_ANY)
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var value = [UInt8](repeating: 0, count: count)
            guard getxattr(source.path, name, &value, count, 0, XATTR_NOFOLLOW_ANY) == count,
                setxattr(destination.path, name, value, count, 0, XATTR_NOFOLLOW_ANY) == 0
            else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }
    private static func object(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw FirmwareError(.internal, "invalid device metadata")
        }
        return value
    }
    private static func clone(_ source: URL, to destination: URL) throws {
        try refuseLinks(source)
        guard clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
            throw FirmwareError(.internal, "clone staging: \(String(cString: strerror(errno)))")
        }
    }
    /// What a stopped edit reads and clones is the device's, and its sandboxed helper writes the overlay and the
    /// NOR: a link there (or the overlay itself a link) would lead this unsandboxed edit's reads and writes out of
    /// the device's folder, a host file into the guest or the guest's pages over a host file. None is taken.
    private static func refuseLinks(_ url: URL) throws {
        let walk = fm.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey])  // never enters a link
        for item in [url] + (walk?.compactMap { $0 as? URL } ?? [])
        where try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw FirmwareError(.unsupported, "\(item.path) is a link; a stopped edit takes none from the device")
        }
    }
    private static func makeWritable(_ directory: URL) throws {
        guard chflags(directory.path, 0) == 0, chmod(directory.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        for child in try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw FirmwareError(.internal, "prepared base contains a symlink")
            }
            if values.isDirectory == true {
                try makeWritable(child)
            } else {
                guard chflags(child.path, 0) == 0, chmod(child.path, 0o600) == 0 else { throw POSIXError(.EIO) }
            }
        }
    }
}
