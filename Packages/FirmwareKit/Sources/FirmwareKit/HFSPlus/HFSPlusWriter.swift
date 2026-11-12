// HFSPlusWriter: file-level edits of a raw HFSX (case-sensitive HFS+) volume image without a mount, from TN1150's format: files,
// folders, symlinks and file hard links created, replaced, renamed and removed in the catalog, their content in
// blocks from the allocation bitmap (contiguous where it can, extents overflow records past eight extents). The
// three B-trees are held as their records (BTreeFile) and laid out afresh by `close()`, which also writes the
// bitmap and both volume headers; nothing reaches the catalog on disk before then.
//
//   let w = try HFSPlusWriter(image)
//   try w.put(Data("x".utf8), at: "etc/fstab")              // in place: an existing file keeps its record and owner
//   try w.makeDirectory("usr/local/bin")                    // mkdir -p
//   try w.makeSymlink("var", to: "private/var")
//   try w.link("bin/gunzip", to: "bin/uncompress")          // a hard link (iNode<n> in the private directory)
//   try w.rename("a", to: "b"); try w.remove("b")           // remove is recursive
//   try w.close()
//
// New items take what a noowners mount by this process would give them: its uid and gid, 0666/0777 less its
// umask; dates are `date` (the volume's own modify date unless set). Paths are volume-relative as HFSPlusVolume's,
// and no link on the volume is followed (VolumeFiles' rule, DevicePath's on a mount). A journaled volume must have
// nothing to replay; the journal is left as it is.

import BinaryParsing
import FirmwareSchema
import Foundation

public final class HFSPlusWriter: VolumeFiles {
    public let url: URL
    public let blockSize: Int
    /// The catalog date of everything this writer creates or changes (seconds since 1904).
    public var date: UInt32
    /// The owner of new items; nil: this process's uid and gid, as a noowners mount gives them (not the parent
    /// folder's gid).
    public var owner: (uid: UInt32, gid: UInt32)?
    /// Whether `close()` sets every folder's valence and folder count from its children (recountFolders); false keeps
    /// the counts the catalog has, adjusted by the edits, so a damaged count is left for fsck_hfs to find.
    var recountsFolders = true
    private let fd: Int32
    private var vh: [UInt8]
    private(set) var totalBlocks: Int
    private var bitmap: [UInt8]
    private var freeHint = 0
    private var catalog: BTreeFile
    private var extents: BTreeFile
    private var attributes: BTreeFile
    private var closed = false

    static let rootID: UInt32 = 2
    static let privateDirName = "\0\0\0\0HFS+ Private Data"
    static let folderType: UInt16 = 1, fileType: UInt16 = 2, folderThread: UInt16 = 3, fileThread: UInt16 = 4
    static let threadExists: UInt16 = 0x02, hasAttributes: UInt16 = 0x04, hasFolderCount: UInt16 = 0x10
    static let hasLinkChain: UInt16 = 0x20
    static let compressed: UInt8 = 0x20, immutable: UInt8 = 0x02

    /// This process's umask, as a mount applies it to what the process creates. Read once: reading it means
    /// setting it, which is process-wide.
    static let creationMask: UInt16 = {
        let m = Darwin.umask(0o022)
        Darwin.umask(m)
        return UInt16(m)
    }()

    public init(_ url: URL) throws {
        self.url = url
        fd = open(url.path, O_RDWR)
        guard fd >= 0 else { throw FirmwareError(.internal, "open \(url.path): \(String(cString: strerror(errno)))") }
        do {
            vh = [UInt8](repeating: 0, count: 512)
            guard pread(fd, &vh, 512, 1024) == 512, vh[0] == 0x48, vh[1] == 0x2B || vh[1] == 0x58 else {
                throw FirmwareError(.unsupported, "\(url.lastPathComponent): no HFS+ volume header")
            }
            blockSize = Int(try be32(vh, 40))
            totalBlocks = Int(try be32(vh, 44))
            date = try be32(vh, 20)
            guard (512...(1 << 24)).contains(blockSize), blockSize & (blockSize - 1) == 0 else {
                throw FirmwareError(.unsupported, "\(url.lastPathComponent): block size \(blockSize)")
            }
            let readSpecial = { [fd, vh, blockSize] o in try Self.readSpecial(fd, vh, o, blockSize: blockSize) }
            let cat = try readSpecial(272)
            guard vh[1] == 0x58, cat.count > 512, cat[14 + 37] == 0xBC else {
                throw FirmwareError(.unsupported, "\(url.lastPathComponent): not a case-sensitive (HFSX) volume")
            }
            catalog = try BTreeFile(cat, compare: BTreeFile.catalogOrder, wellFormed: Self.catalogRecord)
            extents = try BTreeFile(
                try readSpecial(192),
                compare: BTreeFile.extentsOrder,
                wellFormed: Self.extentRecord
            )
            let attr = try readSpecial(352)
            attributes =
                attr.isEmpty
                ? BTreeFile(
                    nodeSize: 8192,
                    maxKeyLength: 266,
                    clumpSize: UInt32(blockSize),
                    attributes: BTreeFile.bigKeys | BTreeFile.variableIndexKeys,
                    compare: BTreeFile.attributesOrder
                ) : try BTreeFile(attr, compare: BTreeFile.attributesOrder, wellFormed: Self.attributeRecord)
            bitmap = Array(try readSpecial(112).prefix((totalBlocks + 7) / 8))
            guard bitmap.count == (totalBlocks + 7) / 8 else {
                throw FirmwareError(.unsupported, "\(url.lastPathComponent): the allocation file is short")
            }
            try checkJournal()
        } catch var refusal as FirmwareError where refusal.code == .unsupported {
            // a volume the kernel route may still edit: the app says so (turn the writer off)
            Darwin.close(fd)
            refusal.piece = HFSRoute.writerRefusal
            throw refusal
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    deinit { if !closed { Darwin.close(fd) } }

    /// What the writer reads of a catalog record at fixed offsets: a key (keyLength, parentID, name length, name)
    /// and a whole folder (88 bytes) or file (248) record, or a thread (type, reserved, parentID, name).
    static func catalogRecord(_ r: BTreeFile.Record) -> Bool {
        guard let units = try? be16(r.key, 6), r.key.count >= 8 + 2 * Int(units), r.value.count >= 10,
            let type = try? be16(r.value, 0), let threadUnits = try? be16(r.value, 8)
        else { return false }
        switch type {
        case folderType: return r.value.count >= 88
        case fileType: return r.value.count >= 248
        case folderThread, fileThread: return r.value.count >= 10 + 2 * Int(threadUnits)
        default: return false
        }
    }

    /// An extents overflow record: its 12-byte key and eight extents.
    static func extentRecord(_ r: BTreeFile.Record) -> Bool { r.key.count >= 12 && r.value.count >= 64 }

    /// An attributes record: a key (keyLength, pad, fileID, startBlock, name length, name) and an inline-data
    /// (type, reserved, size: 16 bytes before the data), fork-data (88) or extents (72) record.
    static func attributeRecord(_ r: BTreeFile.Record) -> Bool {
        guard let units = try? be16(r.key, 12), r.key.count >= 14 + 2 * Int(units), let type = try? be32(r.value, 0)
        else { return false }
        switch type {
        case 0x10: return r.value.count >= 16
        case 0x20: return r.value.count >= 88
        case 0x30: return r.value.count >= 72
        default: return true
        }
    }

    /// Writes the B-trees, the bitmap and the volume headers, and closes the image.
    public func close() throws {
        guard !closed else { return }
        try flush()
        closed = true
        Darwin.close(fd)
    }

    // MARK: - Reading

    public func item(at path: String) throws -> VolumeItem? {
        guard let r = try lookup(path).value else { return nil }
        let c = try content(of: r)
        let kind: VolumeItem.Kind =
            try be16(r, 0) == Self.folderType ? .folder : try be16(c, 42) & 0o170000 == 0o120000 ? .symlink : .file
        return VolumeItem(
            kind: kind,
            uid: try be32(c, 32),
            gid: try be32(c, 36),
            mode: try be16(c, 42),
            size: kind == .folder ? 0 : try contentSize(c),
            modified: Date(timeIntervalSince1970: TimeInterval(try be32(c, 16)) - Self.hfsEpoch)
        )
    }

    /// The names in a folder (as a mount lists them: the hard-link private folders left out), in catalog order.
    public func contentsOfDirectory(at path: String) throws -> [String] {
        guard let r = try lookup(path).value, try be16(r, 0) == Self.folderType else {
            throw FirmwareError(.internal, "\(path): not a folder")
        }
        let id = try be32(r, 8)
        return children(id).compactMap { name, _ in
            let s = String(decoding: name, as: UTF16.self)
            return id == Self.rootID && HFSPlusVolume.privateDirs.contains(s) ? nil : HFSPlusVolume.posixName(s)
        }
    }

    /// A regular file's content (a link is not read through): a hard link's inode's, decompressed when the file
    /// is HFS-compressed.
    public func contents(at path: String) throws -> Data {
        guard let r = try lookup(path).value, try be16(r, 0) == Self.fileType, !isSymlink(r) else {
            throw FirmwareError(.unsupported, "read \(path): not a regular file")
        }
        return Data(try readContent(try content(of: r)))
    }

    public func destinationOfSymlink(at path: String) throws -> String {
        guard let r = try lookup(path).value, try be16(r, 0) == Self.fileType,
            try be16(r, 42) & 0o170000 == 0o120000
        else { throw FirmwareError(.internal, "\(path): not a symlink") }
        return String(decoding: try readFork(r, data: true), as: UTF8.self)
    }

    // MARK: - Editing

    /// Writes `data` into the file at `path` in place (an existing file keeps its catalog record, owner and mode; a
    /// compressed one is stored plainly), else creates it 0666 less the umask. With `mode`, sets the permission bits.
    public func put(_ data: Data, at path: String, mode: UInt16? = nil) throws {
        try put(at: path, mode: mode, size: data.count) { body in try body(data) }
    }

    /// `put` from a file on the host, read in pieces.
    public func put(contentsOf source: URL, at path: String, mode: UInt16? = nil) throws {
        let h = try FileHandle(forReadingFrom: source)
        defer { try? h.close() }
        let size = Int(try h.seekToEnd())
        try h.seek(toOffset: 0)
        try put(at: path, mode: mode, size: size) { body in
            while let chunk = try h.read(upToCount: 1 << 22), !chunk.isEmpty { try body(chunk) }
        }
    }

    private func put(at path: String, mode: UInt16?, size: Int, _ produce: ((Data) throws -> Void) throws -> Void)
        throws
    {
        let at = try lookup(path)
        var key = catalogKey(at.parent, at.name)
        var r: [UInt8]
        var existing = at.value
        let sharedInode = try existing.flatMap { isHardLink($0) ? try inodeKey($0) : nil }.flatMap { catalog[$0] }
        let linked = try sharedInode.map { try be32($0, 44) > 1 } == true
        if let e = existing, isSymlink(e) || linked {
            // a link, or one name of a hard-linked file: the name is replaced, nothing it leads to is written
            try remove(e, parent: at.parent, name: at.name)
            existing = nil
        }
        if let existing {
            guard try be16(existing, 0) == Self.fileType else { throw FirmwareError(.internal, "\(path) is a folder") }
            if isHardLink(existing), let inode = try inodeKey(existing) {
                key = inode
                r = catalog[inode] ?? existing
            } else {
                r = existing
            }
            try freeForks(r)
            try removeAttributes(try be32(r, 8), named: "com.apple.decmpfs")
            r = catalog[key] ?? r
            r[41] &= ~Self.compressed
            r.replaceSubrange(168..<248, with: [UInt8](repeating: 0, count: 80))
        } else {
            r = try newRecord(Self.fileType, mode: 0o100000 | (0o666 & ~Self.creationMask))
            try insert(r, parent: at.parent, name: at.name)
        }
        let fork = try writeFork(try be32(r, 8), size: size, produce)
        r.replaceSubrange(88..<168, with: fork)
        if let mode { putBE16(&r, 42, try be16(r, 42) & 0o170000 | mode & 0o7777) }
        touch(&r)
        catalog[key] = r
    }

    /// mkdir -p, each folder created 0777 less the umask; with `mode`, the last one's permission bits are set.
    public func makeDirectory(_ path: String, mode: UInt16? = nil) throws {
        var done = ""
        for part in path.split(separator: "/") {
            done += (done.isEmpty ? "" : "/") + part
            let at = try lookup(done)
            if let r = at.value {
                guard try be16(r, 0) == Self.folderType else { throw FirmwareError(.internal, "\(done) is a file") }
                continue
            }
            try insert(
                try newRecord(Self.folderType, mode: 0o40000 | (0o777 & ~Self.creationMask)),
                parent: at.parent,
                name: at.name
            )
        }
        if let mode { try setAttributes(path, mode: mode) }
    }

    /// A symlink at `path` (0777 less the umask, as macOS makes one) to `target`.
    public func makeSymlink(_ path: String, to target: String) throws {
        let at = try lookup(path)
        guard at.value == nil else { throw FirmwareError(.internal, "\(path) exists") }
        var r = try newRecord(Self.fileType, mode: 0o120000 | (0o777 & ~Self.creationMask))
        putBE32(&r, 48, 0x736C_6E6B)  // 'slnk'
        putBE32(&r, 52, 0x7268_6170)  // 'rhap'
        let bytes = Data(target.utf8)
        r.replaceSubrange(88..<168, with: try writeFork(try be32(r, 8), size: bytes.count) { try $0(bytes) })
        try insert(r, parent: at.parent, name: at.name)
    }

    /// A hard link at `path` to the file at `existing` (a link to it already, or a plain file that becomes one).
    public func link(_ path: String, to existing: String) throws {
        let at = try lookup(path)
        guard at.value == nil else { throw FirmwareError(.internal, "\(path) exists") }
        let src = try lookup(existing)
        guard var srcRecord = src.value, try be16(srcRecord, 0) == Self.fileType, !isSymlink(srcRecord) else {
            throw FirmwareError(.internal, "\(existing): not a file")
        }
        let privateDir = try privateDirectory()
        let created = try be32(privateDir.value, 12)
        var inodeKey: [UInt8]
        if isHardLink(srcRecord), let k = try self.inodeKey(srcRecord) {
            inodeKey = k
        } else {
            // the file itself becomes the inode iNode<its id>, and a link takes its place
            let id = try be32(srcRecord, 8)
            let inodeName = Array("iNode\(id)".utf16)
            catalog[catalogKey(src.parent, src.name)] = nil
            try adjustParent(src.parent, folder: false, by: -1)
            inodeKey = catalogKey(privateDir.id, inodeName)
            catalog[inodeKey] = srcRecord
            catalog[catalogKey(id, [])] = threadRecord(Self.fileThread, parent: privateDir.id, name: inodeName)
            try adjustParent(privateDir.id, folder: false, by: 1)
            let first = try linkRecord(inode: id, created: created, next: 0)
            try insert(first, parent: src.parent, name: src.name)
            srcRecord[3] |= UInt8(Self.hasLinkChain)
            putBE32(&srcRecord, 4, try be32(first, 8))
            putBE32(&srcRecord, 44, 1)
            catalog[inodeKey] = srcRecord
        }
        guard var inode = catalog[inodeKey] else { throw FirmwareError(.internal, "\(existing): no inode") }
        let first = try be32(inode, 4)
        let link = try linkRecord(inode: try be32(inode, 8), created: created, next: first)
        try insert(link, parent: at.parent, name: at.name)
        try updateLink(first) { putBE32(&$0, 32, try be32(link, 8)) }
        putBE32(&inode, 4, try be32(link, 8))
        let links = try be32(inode, 44)
        guard links < .max else {
            throw FirmwareError(.unsupported, "\(existing): its inode has every link it can count")
        }
        putBE32(&inode, 44, links + 1)
        catalog[inodeKey] = inode
    }

    /// Moves `path` to `destination`, which must not exist; the item keeps its record.
    public func rename(_ path: String, to destination: String) throws {
        let from = try lookup(path)
        guard let r = from.value else { throw FirmwareError(.internal, "\(path) does not exist") }
        let to = try lookup(destination)
        guard to.value == nil else { throw FirmwareError(.internal, "\(destination) exists") }
        guard to.parent != 0 else { throw FirmwareError(.internal, "\(destination): no folder to hold it") }
        let folder = try be16(r, 0) == Self.folderType
        if folder {
            var p = to.parent
            while p != Self.rootID && p != 1 {
                guard try be32(r, 8) != p else { throw FirmwareError(.internal, "\(destination) is inside \(path)") }
                p = try parentID(of: p)
            }
        }
        catalog[catalogKey(from.parent, from.name)] = nil
        try adjustParent(from.parent, folder: folder, by: -1)
        catalog[catalogKey(to.parent, to.name)] = r
        try adjustParent(to.parent, folder: folder, by: 1)
        catalog[catalogKey(try be32(r, 8), [])] = threadRecord(
            folder ? Self.folderThread : Self.fileThread,
            parent: to.parent,
            name: to.name
        )
    }

    /// Removes `path` (a folder with everything in it; a symlink itself, not its target); nothing there is no error.
    public func remove(_ path: String) throws {
        let at = try lookup(path)
        guard let r = at.value else { return }
        guard try be32(r, 8) != Self.rootID else {
            throw FirmwareError(.internal, "refusing to remove the volume root")
        }
        try remove(r, parent: at.parent, name: at.name)
    }

    public func setMode(_ path: String, _ mode: UInt16) throws { try setAttributes(path, mode: mode) }

    /// Seconds from HFS's epoch (1904-01-01 UTC) to the Unix one; catalog dates are UTC seconds from 1904.
    static let hfsEpoch: TimeInterval = 2_082_844_800

    /// Sets the contentModDate of `path` (a hard link's inode's), as utimes does on a mount.
    public func setModified(_ path: String, _ date: Date) throws {
        let at = try lookup(path)
        guard var r = at.value else { throw FirmwareError(.internal, "\(path) does not exist") }
        var key = catalogKey(at.parent, at.name)
        if isHardLink(r), let k = try inodeKey(r), let inode = catalog[k] {
            key = k
            r = inode
        }
        let seconds = (date.timeIntervalSince1970 + Self.hfsEpoch).rounded(.down)
        let modified = UInt32(clamping: Int64(seconds))
        putBE32(&r, 16, modified)
        // a modification before the creation moves the creation back, as macOS's utimes does (but for the root,
        // whose creation is the volume's)
        if try be32(r, 12) > modified, try be32(r, 8) != Self.rootID { putBE32(&r, 12, modified) }
        catalog[key] = r
    }

    public func extract(tar: URL, excluding: [String]) throws {
        try TarArchive(contentsOf: tar).extract(into: self, excluding: excluding)
    }

    /// Sets owner, group, permission bits (the file type kept) and BSD flags (admin << 16 | owner) of `path`; a hard
    /// link's are its inode's.
    public func setAttributes(
        _ path: String,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        mode: UInt16? = nil,
        flags: UInt32? = nil
    ) throws {
        let at = try lookup(path)
        guard var r = at.value else { throw FirmwareError(.internal, "\(path) does not exist") }
        var key = catalogKey(at.parent, at.name)
        if isHardLink(r), let k = try inodeKey(r), let inode = catalog[k] {
            key = k
            r = inode
        }
        if let uid { putBE32(&r, 32, uid) }
        if let gid { putBE32(&r, 36, gid) }
        if let mode { putBE16(&r, 42, try be16(r, 42) & 0o170000 | mode & 0o7777) }
        if let flags {
            r[40] = UInt8(truncatingIfNeeded: flags >> 16)
            r[41] = UInt8(truncatingIfNeeded: flags)
        }
        catalog[key] = r
    }

    /// See `HFSPlusWriter.grow(_:toBytes:)`.
    func grow(toBytes bytes: Int) throws {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw FirmwareError(.internal, "stat \(url.path)") }
        let old = Int(st.st_size)
        guard bytes != old else { return }
        guard bytes > old, bytes % 4096 == 0 else {
            throw FirmwareError(.internal, "cannot grow \(url.lastPathComponent) from \(old) to \(bytes) bytes")
        }
        // the old alternate header goes, and with it the reservation of the volume's last block
        guard pwrite(fd, [UInt8](repeating: 0, count: 512), 512, off_t(old - 1024)) == 512,
            ftruncate(fd, off_t(bytes)) == 0
        else { throw FirmwareError(.internal, "grow \(url.path): \(String(cString: strerror(errno)))") }
        release(.init(start: UInt32(totalBlocks - 1), count: 1))
        totalBlocks = bytes / blockSize
        putBE32(&vh, 44, UInt32(totalBlocks))
        bitmap += [UInt8](repeating: 0, count: (totalBlocks + 7) / 8 - bitmap.count)
        // the last block stays reserved even where the header lies past it (a file that ends mid-block), as
        // newfs_hfs and fsck_hfs have it
        mark(.init(start: UInt32(totalBlocks - 1), count: 1), used: true)
        let have = Int(try be64(vh, 112))
        if bitmap.count > have { try growSpecial(112, by: bitmap.count - have) }
    }

    /// Journals the volume as `diskutil enableJournal` does, but with the journal left for the device's kernel to
    /// initialize (kJIJournalNeedInitMask, as newfs_hfs leaves one): the journal info block and the journal (newfs_hfs's
    /// sizes) in contiguous blocks, the root's .journal_info_block and .journal files, the header's journaled bit.
    public func enableJournal() throws {
        guard try be32(vh, 4) & (1 << 13) == 0 else { return }
        let bytes = totalBlocks * blockSize >= 128 << 20 ? 8 << 20 : 512 << 10
        let runs = try allocate(1 + (bytes + blockSize - 1) / blockSize)
        guard runs.count == 1 else {
            throw FirmwareError(.internal, "\(url.lastPathComponent): no contiguous room for a journal")
        }
        let jib = Int(runs[0].start)
        try pwriteFully(Data(count: Int(runs[0].count) * blockSize), at: jib * blockSize)
        var info = [UInt8](repeating: 0, count: 52)
        putBE32(&info, 0, 1 | 4)  // in this volume, to be initialized
        putBE64(&info, 36, UInt64((jib + 1) * blockSize))
        putBE64(&info, 44, UInt64(bytes))
        try pwriteFully(info, at: jib * blockSize)
        for (name, start, count) in [(".journal_info_block", jib, 1), (".journal", jib + 1, bytes / blockSize)] {
            // owned as the files diskutil makes: by this process's user
            var r = try newRecord(Self.fileType, mode: 0o100000)
            putBE32(&r, 48, 0x6A72_6E6C)  // 'jrnl'
            putBE32(&r, 52, 0x6866_732B)  // 'hfs+'
            putBE16(&r, 56, 0x5000)  // kIsInvisible + kNameLocked
            putBE64(&r, 88, UInt64(count * blockSize))
            putBE32(&r, 100, UInt32(count))
            putBE32(&r, 104, UInt32(start))
            putBE32(&r, 108, UInt32(count))
            try insert(r, parent: Self.rootID, name: Array(name.utf16))
        }
        putBE32(&vh, 12, UInt32(jib))
        putBE32(&vh, 4, try be32(vh, 4) | 1 << 13)
    }

    // MARK: - Catalog

    private func catalogKey(_ parent: UInt32, _ name: [UInt16]) -> [UInt8] {
        var k = [UInt8](repeating: 0, count: 8 + 2 * name.count)
        putBE16(&k, 0, UInt16(6 + 2 * name.count))
        putBE32(&k, 2, parent)
        putBE16(&k, 6, UInt16(name.count))
        for (i, u) in name.enumerated() { putBE16(&k, 8 + 2 * i, u) }
        return k
    }

    private func threadRecord(_ type: UInt16, parent: UInt32, name: [UInt16]) -> [UInt8] {
        var t = [UInt8](repeating: 0, count: 10 + 2 * name.count)
        putBE16(&t, 0, type)
        putBE32(&t, 4, parent)
        putBE16(&t, 8, UInt16(name.count))
        for (i, u) in name.enumerated() { putBE16(&t, 10 + 2 * i, u) }
        return t
    }

    /// The children of folder `id` in key order: (name, record).
    private func children(_ id: UInt32) -> [(name: [UInt16], record: [UInt8])] {
        var out: [(name: [UInt16], record: [UInt8])] = []
        catalog.scan(from: catalogKey(id, [])) { r in
            guard (try? be32(r.key, 2)) == id else { return false }
            if let name = try? Self.units(r.key, at: 6), !name.isEmpty { out.append((name, r.value)) }
            return true
        }
        return out
    }

    private func parentID(of id: UInt32) throws -> UInt32 {
        guard let t = catalog[catalogKey(id, [])] else { throw FirmwareError(.unsupported, "no thread for \(id)") }
        return try be32(t, 4)
    }

    private func record(id: UInt32) throws -> (key: [UInt8], value: [UInt8])? {
        guard let t = catalog[catalogKey(id, [])] else { return nil }
        let key = catalogKey(try be32(t, 4), try Self.units(t, at: 8))
        return catalog[key].map { (key, $0) }
    }

    /// Where `path` is: its parent folder, its catalog name, and its record if there is one.
    /// Where `path` is: its parent folder, its catalog name, and its record if there is one (parent 0 when a folder
    /// on the way is missing). No link is followed (DevicePath's rule): one on the way throws, as does a "." or ".."
    /// component.
    private func lookup(_ path: String) throws -> (parent: UInt32, name: [UInt16], value: [UInt8]?) {
        let parts = path.split(separator: "/")
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else {
            throw FirmwareError(.unsupported, "\(path): not a plain path on the device's volume")
        }
        guard !parts.isEmpty else {
            // the root: its record is keyed by the volume's name under parent 1
            guard let (key, value) = try record(id: Self.rootID) else { throw FirmwareError(.unsupported, "no root") }
            return (1, try Self.units(key, at: 6), value)
        }
        var cur = Self.rootID
        for (i, part) in parts.enumerated() {
            let name = HFSUnicode.catalogName(HFSPlusVolume.catalogName(String(part)))
            let r = catalog[catalogKey(cur, name)]
            if i == parts.count - 1 { return (cur, name, r) }
            // a folder on the way is missing: nothing is there (parent 0, which nothing can be created in)
            guard let r else { return (0, name, nil) }
            guard !isSymlink(r) else {
                throw FirmwareError(.unsupported, "\(path): a link on the device's volume, not followed")
            }
            guard try be16(r, 0) == Self.folderType else {
                throw FirmwareError(.internal, "\(path): \(part) is a file")
            }
            cur = try be32(r, 8)
        }
        throw FirmwareError(.internal, "unreachable")
    }

    /// A UTF-16 name as keys and thread records hold it: a big-endian unit count at `o`, the units after it.
    static func units(_ b: [UInt8], at o: Int) throws -> [UInt16] {
        try parsing(b, "catalog name") { s in
            try s.seek(toRelativeOffset: o)
            let n = try UInt16(parsingBigEndian: &s)
            return try [UInt16](parsing: &s, count: Int(n)) { try UInt16(parsingBigEndian: &$0) }
        }
    }

    private func isSymlink(_ r: [UInt8]) -> Bool {
        (try? be16(r, 0)) == Self.fileType && (try? be16(r, 42)).map { $0 & 0o170000 == 0o120000 } == true
    }

    private func isHardLink(_ r: [UInt8]) -> Bool {
        (try? be16(r, 0)) == Self.fileType && (try? be32(r, 48)) == 0x686C_6E6B && (try? be32(r, 52)) == 0x6866_732B
    }

    private func inodeKey(_ link: [UInt8]) throws -> [UInt8]? {
        guard let dir = catalog[catalogKey(Self.rootID, Array(Self.privateDirName.utf16))] else { return nil }
        let k = catalogKey(try be32(dir, 8), Array("iNode\(try be32(link, 44))".utf16))
        return catalog[k] == nil ? nil : k
    }

    /// The record whose content and BSD info a record has: a hard link's inode, else itself.
    private func content(of r: [UInt8]) throws -> [UInt8] {
        guard isHardLink(r), let k = try inodeKey(r), let inode = catalog[k] else { return r }
        return inode
    }

    private func newRecord(_ type: UInt16, mode: UInt16) throws -> [UInt8] {
        var r = [UInt8](repeating: 0, count: type == Self.folderType ? 88 : 248)
        putBE16(&r, 0, type)
        putBE16(&r, 2, type == Self.folderType ? Self.hasFolderCount : Self.threadExists)
        let id = try be32(vh, 64)
        guard id < .max else { throw FirmwareError(.unsupported, "the volume has no catalog ID left") }
        putBE32(&vh, 64, id + 1)
        putBE32(&r, 8, id)
        for i in 0..<4 { putBE32(&r, 12 + 4 * i, date) }
        putBE32(&r, 32, owner?.uid ?? getuid())
        putBE32(&r, 36, owner?.gid ?? getgid())
        putBE16(&r, 42, mode)
        if type == Self.fileType { putBE32(&r, 44, 1) }  // the link count a mount gives a new file
        return r
    }

    private func touch(_ r: inout [UInt8]) {
        for i in 1..<4 { putBE32(&r, 12 + 4 * i, date) }
    }

    /// Adds record `r` to folder `parent` as `name`, with its thread, counting it in the parent.
    private func insert(_ r: [UInt8], parent: UInt32, name: [UInt16]) throws {
        guard parent != 0 else {
            throw FirmwareError(.internal, "no folder to hold \(String(decoding: name, as: UTF16.self))")
        }
        let folder = try be16(r, 0) == Self.folderType
        guard name.count <= 255 else { throw FirmwareError(.internal, "a name longer than 255 characters") }
        catalog[catalogKey(parent, name)] = r
        catalog[catalogKey(try be32(r, 8), [])] = threadRecord(
            folder ? Self.folderThread : Self.fileThread,
            parent: parent,
            name: name
        )
        try adjustParent(parent, folder: folder, by: 1)
    }

    private func adjustParent(_ id: UInt32, folder: Bool, by n: Int32) throws {
        guard let (key, found) = try record(id: id) else { throw FirmwareError(.internal, "no folder \(id)") }
        var p = found
        putBE32(&p, 4, UInt32(bitPattern: Int32(bitPattern: try be32(p, 4)) &+ n))
        if folder, try be16(p, 2) & Self.hasFolderCount != 0 {
            putBE32(&p, 84, UInt32(bitPattern: Int32(bitPattern: try be32(p, 84)) &+ n))
        }
        for i in 1..<3 { putBE32(&p, 12 + 4 * i, date) }
        catalog[key] = p
    }

    private func remove(_ r: [UInt8], parent: UInt32, name: [UInt16]) throws {
        let id = try be32(r, 8)
        let folder = try be16(r, 0) == Self.folderType
        if folder {
            // by name: removing one hard link rewrites its neighbors in the chain, which may be siblings
            for c in children(id) {
                if let r = catalog[catalogKey(id, c.name)] { try remove(r, parent: id, name: c.name) }
            }
        } else if isHardLink(r), let k = try inodeKey(r), var inode = catalog[k] {
            // unchain the link; the inode goes with its last link
            let prev = try be32(r, 32)
            let next = try be32(r, 36)
            try updateLink(prev) { putBE32(&$0, 36, next) }
            try updateLink(next) { putBE32(&$0, 32, prev) }
            if try be32(inode, 4) == id { putBE32(&inode, 4, next) }
            let links = try be32(inode, 44)
            guard links > 0 else { throw FirmwareError(.unsupported, "a hard link to an inode with no links") }
            putBE32(&inode, 44, links - 1)
            catalog[k] = inode
            if try be32(inode, 44) == 0 {
                try remove(inode, parent: try be32(k, 2), name: try Self.units(k, at: 6))
            }
        } else {
            try freeForks(r)
            try removeAttributes(id)
        }
        if folder { try removeAttributes(id) }
        catalog[catalogKey(parent, name)] = nil
        catalog[catalogKey(id, [])] = nil
        try adjustParent(parent, folder: folder, by: -1)
    }

    private func updateLink(_ id: UInt32, _ edit: (inout [UInt8]) throws -> Void) throws {
        guard id != 0, let (key, found) = try record(id: id) else { return }
        var r = found
        try edit(&r)
        catalog[key] = r
    }

    private func linkRecord(inode: UInt32, created: UInt32, next: UInt32) throws -> [UInt8] {
        var r = try newRecord(Self.fileType, mode: 0o100444)
        putBE16(&r, 2, Self.threadExists | Self.hasLinkChain)
        putBE32(&r, 12, created)
        putBE32(&r, 32, 0)  // the previous link: none, a new link heads the chain
        putBE32(&r, 36, next)
        r[41] = Self.immutable
        putBE32(&r, 44, inode)
        putBE32(&r, 48, 0x686C_6E6B)  // 'hlnk'
        putBE32(&r, 52, 0x6866_732B)  // 'hfs+'
        putBE16(&r, 56, 0x0100)  // kHasBeenInited
        return r
    }

    /// The file hard links' private folder, made as the kernel makes it when there is none.
    private func privateDirectory() throws -> (id: UInt32, value: [UInt8]) {
        let name = Array(Self.privateDirName.utf16)
        if let r = catalog[catalogKey(Self.rootID, name)] { return (try be32(r, 8), r) }
        var r = try newRecord(Self.folderType, mode: 0o40000)
        putBE32(&r, 32, 0)
        putBE32(&r, 36, 0)
        r[41] = Self.immutable
        putBE32(&r, 44, 1)
        putBE16(&r, 56, 0x5000)  // kIsInvisible + kNameLocked
        putBE16(&r, 58, 16384)
        putBE16(&r, 60, 16384)
        try insert(r, parent: Self.rootID, name: name)
        return (try be32(r, 8), r)
    }

    // MARK: - Forks

    private func forkExtents(_ r: [UInt8], data: Bool) throws -> [HFSPlusVolume.Extent] {
        let fork = try HFSPlusVolume.Fork(r, data ? 88 : 168)
        var out = fork.extents
        let total = Int(fork.totalBlocks)
        var have = out.reduce(0) { $0 + Int($1.count) }
        let id = try be32(r, 8)
        while have < total, let more = extents[extentKey(id, data: data, start: UInt32(have))] {
            let e = try parsing(more, "extents record") { s in
                try [HFSPlusVolume.Extent](parsing: &s, count: 8) { x in
                    HFSPlusVolume.Extent(
                        start: try UInt32(parsingBigEndian: &x), count: try UInt32(parsingBigEndian: &x))
                }
            }.filter { $0.count > 0 }
            guard !e.isEmpty else { break }
            out += e
            have += e.reduce(0) { $0 + Int($1.count) }
        }
        return out
    }

    private func extentKey(_ id: UInt32, data: Bool, start: UInt32) -> [UInt8] {
        var k = [UInt8](repeating: 0, count: 12)
        putBE16(&k, 0, 10)
        k[2] = data ? 0 : 0xFF
        putBE32(&k, 4, id)
        putBE32(&k, 8, start)
        return k
    }

    private func readFork(_ r: [UInt8], data: Bool) throws -> [UInt8] {
        let fork = try HFSPlusVolume.Fork(r, data ? 88 : 168)
        guard fork.logicalSize <= UInt64(fork.totalBlocks) * UInt64(blockSize) else {
            throw FirmwareError(.unsupported, "file \(try be32(r, 8)) is larger than its blocks")
        }
        let size = Int(fork.logicalSize)
        var out = [UInt8](repeating: 0, count: size)
        var done = 0
        for e in try forkExtents(r, data: data) where done < size {
            let n = min(size - done, Int(e.count) * blockSize)
            _ = try Self.preadFully(fd, &out, at: done, count: n, from: Int(e.start) * blockSize)
            done += n
        }
        guard done == size else { throw FirmwareError(.unsupported, "file \(try be32(r, 8)) is missing extents") }
        return out
    }

    private func decmpfs(_ id: UInt32) -> [UInt8]? {
        // an inline-data attribute: its type (0x10), reserved, the size, the data at 16
        guard let v = attributes[attributeKey(id, "com.apple.decmpfs")], v.count >= 16, (try? be32(v, 0)) == 0x10,
            let size = try? be32(v, 12)
        else { return nil }
        let x = Array(v[16..<min(v.count, 16 + Int(size))])
        return x.count >= 16 && (try? le32(x, 0)) == 0x636D_7066 ? x : nil
    }

    private func readContent(_ r: [UInt8]) throws -> [UInt8] {
        guard r[41] & Self.compressed != 0 else { return try readFork(r, data: true) }
        guard let x = decmpfs(try be32(r, 8)) else {
            throw FirmwareError(.unsupported, "file \(try be32(r, 8)): no decmpfs")
        }
        return try HFSPlusVolume.decmpfs(x, name: "file \(try be32(r, 8))") { try readFork(r, data: false) }
    }

    private func contentSize(_ r: [UInt8]) throws -> UInt64 {
        if r[41] & Self.compressed != 0, let x = decmpfs(try be32(r, 8)) { return try le64(x, 8) }
        return try be64(r, 88)
    }

    /// Allocates and writes `size` bytes from `produce` as file `id`'s data fork; returns the fork record (its
    /// extents past the eighth in extents overflow records).
    private func writeFork(_ id: UInt32, size: Int, _ produce: ((Data) throws -> Void) throws -> Void) throws
        -> [UInt8]
    {
        let blocks = (size + blockSize - 1) / blockSize
        let runs = try allocate(blocks)
        var fork = [UInt8](repeating: 0, count: 80)
        putBE64(&fork, 0, UInt64(size))
        putBE32(&fork, 12, UInt32(blocks))
        for (i, e) in runs.prefix(8).enumerated() {
            putBE32(&fork, 16 + 8 * i, e.start)
            putBE32(&fork, 20 + 8 * i, e.count)
        }
        var start = runs.prefix(8).reduce(0) { $0 + Int($1.count) }
        for group in stride(from: 8, to: runs.count, by: 8) {
            var rec = [UInt8](repeating: 0, count: 64)
            for (i, e) in runs[group..<min(group + 8, runs.count)].enumerated() {
                putBE32(&rec, 8 * i, e.start)
                putBE32(&rec, 4 + 8 * i, e.count)
            }
            extents[extentKey(id, data: true, start: UInt32(start))] = rec
            start += runs[group..<min(group + 8, runs.count)].reduce(0) { $0 + Int($1.count) }
        }
        // the content where its blocks are, the last block's tail zeroed
        func diskOffset(_ logical: Int) -> (at: Int, room: Int) {
            var base = 0
            for e in runs {
                let len = Int(e.count) * blockSize
                if logical < base + len { return (Int(e.start) * blockSize + logical - base, base + len - logical) }
                base += len
            }
            return (0, 0)
        }
        var written = 0
        try produce { d in
            guard written + d.count <= size else {
                throw FirmwareError(.internal, "file \(id): more content than \(size) bytes")
            }
            var piece = d[...]
            while !piece.isEmpty {
                let (at, room) = diskOffset(written)
                let n = min(room, piece.count)
                try pwriteFully(piece.prefix(n), at: at)
                written += n
                piece = piece.dropFirst(n)
            }
        }
        guard written == size else { throw FirmwareError(.internal, "file \(id): \(written) of \(size) bytes") }
        if blocks * blockSize > size {
            try pwriteFully(Data(count: blocks * blockSize - size), at: diskOffset(size).at)
        }
        return fork
    }

    private func pwriteFully(_ bytes: some DataProtocol & ContiguousBytes, at offset: Int) throws {
        let n = bytes.count
        let put = bytes.withUnsafeBytes { p in p.baseAddress.map { pwrite(fd, $0, n, off_t(offset)) } ?? 0 }
        guard put == n else {
            throw FirmwareError(.internal, "pwrite \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    private func freeForks(_ r: [UInt8]) throws {
        let id = try be32(r, 8)
        for data in [true, false] {
            for e in try forkExtents(r, data: data) { release(e) }
            var stale: [[UInt8]] = []
            extents.scan(from: extentKey(id, data: data, start: 0)) { rec in
                guard (try? be32(rec.key, 4)) == id, rec.key[2] == (data ? 0 : 0xFF) else { return false }
                stale.append(rec.key)
                return true
            }
            for k in stale { extents[k] = nil }
        }
    }

    // MARK: - Attributes

    private func attributeKey(_ id: UInt32, _ name: String) -> [UInt8] {
        let n = Array(name.utf16)
        var k = [UInt8](repeating: 0, count: 14 + 2 * n.count)
        putBE16(&k, 0, UInt16(12 + 2 * n.count))
        putBE32(&k, 4, id)
        putBE16(&k, 12, UInt16(n.count))
        for (i, u) in n.enumerated() { putBE16(&k, 14 + 2 * i, u) }
        return k
    }

    /// Removes file `id`'s extended attributes (only `named`, when given), freeing the blocks of fork attributes.
    private func removeAttributes(_ id: UInt32, named: String? = nil) throws {
        var gone: [BTreeFile.Record] = []
        attributes.scan(from: named.map { attributeKey(id, $0) } ?? attributeKey(id, "")) { rec in
            guard (try? be32(rec.key, 4)) == id else { return false }
            if let named, rec.key[12...] != attributeKey(id, named)[12...] { return false }
            gone.append(rec)
            return true
        }
        for rec in gone {
            let type = try be32(rec.value, 0)
            // kHFSPlusAttrForkData: the fork at 8; kHFSPlusAttrExtents: eight extents at 8
            if type == 0x20 || type == 0x30 {
                let at = type == 0x20 ? 24 : 8
                for i in 0..<8 where try be32(rec.value, at + 4 + 8 * i) > 0 {
                    release(.init(start: try be32(rec.value, at + 8 * i), count: try be32(rec.value, at + 4 + 8 * i)))
                }
            }
            attributes[rec.key] = nil
        }
        var remain = false
        attributes.scan(from: attributeKey(id, "")) { rec in
            remain = (try? be32(rec.key, 4)) == id
            return false
        }
        if !gone.isEmpty, !remain,
            let (key, found) = try record(id: id)
        {
            var r = found
            putBE16(&r, 2, try be16(r, 2) & ~Self.hasAttributes)
            catalog[key] = r
        }
    }

    // MARK: - Allocation

    private func isUsed(_ b: Int) -> Bool { bitmap[b / 8] & (0x80 >> UInt8(b % 8)) != 0 }

    private func mark(_ e: HFSPlusVolume.Extent, used: Bool) {
        for b in Int(e.start)..<Int(e.start) + Int(e.count) {
            if used { bitmap[b / 8] |= 0x80 >> UInt8(b % 8) } else { bitmap[b / 8] &= ~(0x80 >> UInt8(b % 8)) }
        }
    }

    private func release(_ e: HFSPlusVolume.Extent) {
        mark(e, used: false)
        freeHint = min(freeHint, Int(e.start))
    }

    /// `count` blocks: the first free run that holds them all, else free runs in volume order.
    private func allocate(_ count: Int) throws -> [HFSPlusVolume.Extent] {
        guard count > 0 else { return [] }
        var runs: [HFSPlusVolume.Extent] = []
        var b = freeHint
        var firstFree: Int?
        defer { if let firstFree { freeHint = firstFree } }
        while b < totalBlocks {
            if bitmap[b / 8] == 0xFF && b % 8 == 0 {
                b += 8
                continue
            }
            guard !isUsed(b) else {
                b += 1
                continue
            }
            if firstFree == nil { firstFree = b }
            var e = b
            while e < totalBlocks && e - b < count && !isUsed(e) { e += 1 }
            let run = HFSPlusVolume.Extent(start: UInt32(b), count: UInt32(e - b))
            if e - b == count {
                mark(run, used: true)
                return [run]
            }
            runs.append(run)
            b = e
        }
        // no run holds them: take free runs in order
        var out: [HFSPlusVolume.Extent] = []
        var left = count
        for r in runs where left > 0 {
            let take = HFSPlusVolume.Extent(start: r.start, count: UInt32(min(Int(r.count), left)))
            out.append(take)
            left -= Int(take.count)
        }
        guard left == 0 else {
            throw FirmwareError(.internal, "\(url.lastPathComponent) is full (\(count) blocks wanted)")
        }
        for e in out { mark(e, used: true) }
        return out
    }

    /// `count` free blocks right after `end`, if they are free; else anywhere contiguous.
    private func allocate(_ count: Int, after end: Int) throws -> HFSPlusVolume.Extent {
        if end + count <= totalBlocks, (end..<end + count).allSatisfy({ !isUsed($0) }) {
            let e = HFSPlusVolume.Extent(start: UInt32(end), count: UInt32(count))
            mark(e, used: true)
            return e
        }
        let runs = try allocate(count)
        guard runs.count == 1 else {
            for r in runs { release(r) }
            throw FirmwareError(.internal, "\(url.lastPathComponent): no \(count) contiguous blocks for a system file")
        }
        return runs[0]
    }

    // MARK: - System files

    /// A system file's bytes along its volume-header fork (at `o`); empty for an absent one.
    private static func readSpecial(_ fd: Int32, _ vh: [UInt8], _ o: Int, blockSize: Int) throws -> [UInt8] {
        let fork = try HFSPlusVolume.Fork(vh, o)
        guard fork.logicalSize <= UInt64(fork.totalBlocks) * UInt64(blockSize) else {
            throw FirmwareError(.unsupported, "a system file is larger than its blocks")
        }
        let size = Int(fork.logicalSize)
        var out = [UInt8](repeating: 0, count: size)
        var done = 0
        for e in fork.extents where done < size {
            let n = min(size - done, Int(e.count) * blockSize)
            guard try preadFully(fd, &out, at: done, count: n, from: Int(e.start) * blockSize) else { break }
            done += n
        }
        guard done == size else { throw FirmwareError(.unsupported, "a system file has overflow extents") }
        return out
    }

    private func readSpecial(_ o: Int) throws -> [UInt8] { try Self.readSpecial(fd, vh, o, blockSize: blockSize) }

    /// Reads `count` bytes at `offset` of the image into `buffer[at...]`; past the image's end reads as zeros (a
    /// sparse or short image).
    private static func preadFully(_ fd: Int32, _ buffer: inout [UInt8], at: Int, count: Int, from offset: Int) throws
        -> Bool
    {
        let got = buffer.withUnsafeMutableBytes { p in
            p.baseAddress.map { pread(fd, $0 + at, count, off_t(offset)) } ?? 0
        }
        guard got >= 0 else { throw FirmwareError(.internal, "pread: \(String(cString: strerror(errno)))") }
        return true
    }

    private func writeSpecial(_ o: Int, _ bytes: [UInt8]) throws {
        var done = 0
        for i in 0..<8 where done < bytes.count {
            let start = Int(try be32(vh, o + 16 + 8 * i))
            let n = min(bytes.count - done, Int(try be32(vh, o + 20 + 8 * i)) * blockSize)
            try pwriteFully(bytes[done..<done + n], at: start * blockSize)
            done += n
        }
        guard done == bytes.count else { throw FirmwareError(.internal, "a system file is shorter than its content") }
    }

    /// Grows the system file whose fork is at `o` by at least `bytes`, in whole clumps, contiguously.
    private func growSpecial(_ o: Int, by bytes: Int) throws {
        let clump = max(Int(try be32(vh, o + 8)), blockSize)
        let blocks = (bytes + clump - 1) / clump * clump / blockSize
        var exts = try (0..<8).map { (try be32(vh, o + 16 + 8 * $0), try be32(vh, o + 20 + 8 * $0)) }.filter {
            $0.1 > 0
        }
        let end = exts.last.map { Int($0.0) + Int($0.1) } ?? 0
        let e = try allocate(blocks, after: end)
        if let last = exts.last, Int(last.0) + Int(last.1) == Int(e.start) {
            exts[exts.count - 1].1 += e.count
        } else {
            guard exts.count < 8 else {
                release(e)
                throw FirmwareError(.internal, "\(url.lastPathComponent): a system file would need overflow extents")
            }
            exts.append((e.start, e.count))
        }
        let (size, past) = try be64(vh, o).addingReportingOverflow(UInt64(blocks * blockSize))
        let (count, over) = try be32(vh, o + 12).addingReportingOverflow(UInt32(blocks))
        guard !past, !over else {
            release(e)
            throw FirmwareError(.unsupported, "\(url.lastPathComponent): a system file's size would overflow its fork")
        }
        putBE64(&vh, o, size)
        putBE32(&vh, o + 12, count)
        for (i, x) in exts.enumerated() {
            putBE32(&vh, o + 16 + 8 * i, x.0)
            putBE32(&vh, o + 20 + 8 * i, x.1)
        }
    }

    private func store(_ t: BTreeFile, forkAt o: Int) throws {
        if try be64(vh, o) == 0 {
            guard !t.records.isEmpty else { return }
            // an attributes file for a volume that had none (the kernel makes one so)
            putBE32(&vh, o + 8, UInt32(max(t.nodeSize, blockSize) * 16))
        }
        while true {
            let total = Int(try be64(vh, o)) / t.nodeSize
            let need = try t.nodesNeeded(totalNodes: total)
            if need <= total { break }
            try growSpecial(o, by: (need - total) * t.nodeSize)
        }
        try writeSpecial(o, try t.layout(totalNodes: Int(try be64(vh, o)) / t.nodeSize))
    }

    private func checkJournal() throws {
        guard try be32(vh, 4) & (1 << 13) != 0, try be32(vh, 12) != 0 else { return }
        var jib = [UInt8](repeating: 0, count: 52)
        guard pread(fd, &jib, 52, off_t(Int(try be32(vh, 12)) * blockSize)) == 52 else { return }
        guard try be32(jib, 0) & 1 != 0, try be32(jib, 0) & 4 == 0 else { return }  // in the volume, initialized
        var hdr = [UInt8](repeating: 0, count: 24)
        guard pread(fd, &hdr, 24, off_t(try be64(jib, 36))) == 24 else { return }
        guard hdr[8..<16] == hdr[16..<24] else {
            throw FirmwareError(.unsupported, "\(url.lastPathComponent): the journal has transactions to replay")
        }
    }

    private func flush() throws {
        if recountsFolders { try recountFolders() }
        try store(catalog, forkAt: 272)
        try store(attributes, forkAt: 352)
        try store(extents, forkAt: 192)
        var alloc = try readSpecial(112)
        alloc.replaceSubrange(0..<bitmap.count, with: bitmap)
        try writeSpecial(112, alloc)
        var files: UInt32 = 0
        var folders: UInt32 = 0
        for r in catalog.records {
            switch try be16(r.value, 0) {
            case Self.fileType: files += 1
            case Self.folderType: folders += 1
            default: break
            }
        }
        putBE32(&vh, 32, files)
        putBE32(&vh, 36, max(folders, 1) - 1)  // the root is not counted
        // bits past the last block are clear, so the set bits are the blocks in use
        putBE32(&vh, 48, UInt32(totalBlocks - bitmap.reduce(0) { $0 + $1.nonzeroBitCount }))
        putBE32(&vh, 68, try be32(vh, 68) &+ 1)
        // unmounted cleanly, not inconsistent
        putBE32(&vh, 4, try be32(vh, 4) & ~UInt32(1 << 11) | 1 << 8)
        try writeHeaders()
    }

    /// Every folder's valence and HFSX folder count (kHFSHasFolderCountMask set) as its children are: the edits keep
    /// them, and this also sets what a catalog came without (1.x's stock folders have no folder count, which
    /// fsck_hfs -fy adds on HFSX and -fn reports).
    private func recountFolders() throws {
        var children: [UInt32: UInt32] = [:]
        var folders: [UInt32: UInt32] = [:]
        for r in catalog.records where try be16(r.key, 6) > 0 {
            let type = try be16(r.value, 0)
            guard type == Self.folderType || type == Self.fileType else { continue }
            children[try be32(r.key, 2), default: 0] += 1
            if type == Self.folderType { folders[try be32(r.key, 2), default: 0] += 1 }
        }
        for r in catalog.records where try be16(r.value, 0) == Self.folderType {
            let id = try be32(r.value, 8)
            var v = r.value
            putBE32(&v, 4, children[id] ?? 0)
            putBE16(&v, 2, try be16(v, 2) | Self.hasFolderCount)
            putBE32(&v, 84, folders[id] ?? 0)
            if v != r.value { catalog[r.key] = v }
        }
    }

    private func writeHeaders() throws {
        var st = stat()
        let size = fstat(fd, &st) == 0 ? Int(st.st_size) : 0
        for at in Set([1024, size - 1024]).sorted() where at >= 1024 {
            guard pwrite(fd, vh, 512, off_t(at)) == 512 else {
                throw FirmwareError(.internal, "write volume header at \(at) of \(url.lastPathComponent)")
            }
        }
    }
}
