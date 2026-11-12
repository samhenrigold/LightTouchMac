// HFSPlus: read a raw HFS+/HFSX volume image (volume header, B-trees, catalog, extents overflow) and edit
// catalog ownership/mode in place. Ports imgtools/hfsvol.py + build_nand.FlatVolume/set_owner and
// setowner.py (same records, same bytes), without a mount.
//
//   let vol = try HFSPlusVolume(image)                        // read-only
//   try vol.record(at: "private/var/mobile")                  // CatalogRecord: cnid, uid, gid, mode, forks
//   try vol.listing()                                         // every path: owner, mode, size, sha256, link
//   try vol.owners(under: "private/var")                      // ipad1_rootfs.var_owners, from the catalog
//   let rw = try HFSPlusVolume(image, writable: true)
//   try rw.setOwner(["usr/local", "usr/local/bin"], uid: 0, gid: 0)          // build_nand.set_owner
//   try rw.setOwner(["x/y.plist"], uid: 0, gid: 0, mode: 0o644)             // setowner.py PATH:0:0:644
//
// Paths are volume-relative, "/"-separated, no leading slash ("" is the root folder).

import BinaryParsing
import Compression
import Crypto
import Foundation

public final class HFSPlusVolume {
    public struct Extent: Sendable, Equatable { public let start: UInt32, count: UInt32 }

    public struct Fork: Sendable, Equatable {
        public let logicalSize: UInt64
        public let totalBlocks: UInt32
        public let extents: [Extent]
        /// HFSPlusForkData: logicalSize (no more than an Int holds), clumpSize, totalBlocks, eight extents.
        init(parsing s: inout ParserSpan) throws {
            logicalSize = UInt64(try Int(parsing: &s, storedAsBigEndian: UInt64.self))
            _ = try UInt32(parsingBigEndian: &s)
            totalBlocks = try UInt32(parsingBigEndian: &s)
            extents = try [Extent](parsing: &s, count: 8) { e in
                Extent(start: try UInt32(parsingBigEndian: &e), count: try UInt32(parsingBigEndian: &e))
            }.filter { $0.count > 0 }
        }
        init(_ b: [UInt8], _ o: Int) throws {
            self = try parsing(b, "fork data") { s in
                try s.seek(toRelativeOffset: o)
                return try Fork(parsing: &s)
            }
        }
    }

    /// One folder or file record of the catalog, with where it sits (for in-place edits).
    public struct CatalogRecord: Sendable {
        public enum Kind: Sendable { case folder, file }
        public let kind: Kind
        public let parent: UInt32, name: String, cnid: UInt32
        public let uid: UInt32, gid: UInt32, adminFlags: UInt8, ownerFlags: UInt8, mode: UInt16, special: UInt32
        public let fileType: UInt32, creator: UInt32
        public let data: Fork?, resource: Fork?
        /// create, content-modified, attribute-modified, accessed, backup: seconds since 1904-01-01.
        public let dates: [UInt32]
        /// B-tree node number and the byte offset of the record body (past the key) within that node.
        public let node: Int, bodyOffset: Int
        public var isSymlink: Bool { kind == .file && mode & 0o170000 == 0o120000 }
        /// An HFS+ file hard link ('hlnk'/'hfs+'): the content is the private directory's iNode<special>.
        public var isHardLink: Bool { kind == .file && fileType == 0x686C_6E6B && creator == 0x6866_732B }
    }

    public struct Entry: Sendable, Equatable, Codable {
        public var path: String
        public var uid: UInt32, gid: UInt32, mode: UInt16, flags: UInt32
        public var size: UInt64, resourceSize: UInt64
        public var sha256: String?
        public var link: String?
    }

    public let url: URL
    public let writable: Bool
    public let signature: String
    public let blockSize: Int, totalBlocks: Int, freeBlocks: Int, fileCount: Int, folderCount: Int, nextCatalogID: Int
    let fd: Int32
    let extentsFork: Fork, catalogFork: Fork, attributesFork: Fork
    private var overflow: [UInt64: [(UInt32, [Extent])]]?
    private var decmpfs: [UInt32: [UInt8]]?
    private var catalogCache: [CatalogRecord]?

    static let rootID: UInt32 = 2, extentsID: UInt32 = 3, catalogID: UInt32 = 4, attributesID: UInt32 = 8
    static let compressed: UInt8 = 0x20  // UF_COMPRESSED: the content is in com.apple.decmpfs (+ the resource fork)
    static let privateDirs: Set<String> = ["\0\0\0\0HFS+ Private Data", ".HFS+ Private Directory Data\r"]

    public init(_ url: URL, writable: Bool = false) throws {
        self.url = url
        self.writable = writable
        fd = open(url.path, writable ? O_RDWR : O_RDONLY)
        guard fd >= 0 else { throw FirmwareError(.internal, "open \(url.path): \(String(cString: strerror(errno)))") }
        var vh = [UInt8](repeating: 0, count: 512)
        guard pread(fd, &vh, 512, 1024) == 512, vh[0] == 0x48, vh[1] == 0x2B || vh[1] == 0x58 else {
            close(fd)
            throw FirmwareError(.unsupported, "\(url.lastPathComponent): no HFS+ volume header")
        }
        signature = vh[1] == 0x58 ? "HX" : "H+"
        fileCount = Int(try be32(vh, 32))
        folderCount = Int(try be32(vh, 36))
        blockSize = Int(try be32(vh, 40))
        totalBlocks = Int(try be32(vh, 44))
        freeBlocks = Int(try be32(vh, 48))
        nextCatalogID = Int(try be32(vh, 64))
        guard (512...(1 << 24)).contains(blockSize), blockSize & (blockSize - 1) == 0 else {
            close(fd)
            throw FirmwareError(.unsupported, "\(url.lastPathComponent): block size \(blockSize)")
        }
        extentsFork = try Fork(vh, 192)
        catalogFork = try Fork(vh, 272)
        attributesFork = try Fork(vh, 352)
    }

    deinit { close(fd) }

    /// The size a volume header at `at` in `bytes` gives its volume, blockSize × totalBlocks (big-endian u32s at 40
    /// and 44); nil when no HFS+ or HFSX signature is there. A product past what an Int holds is refused.
    static func headerBytes(_ bytes: [UInt8], at: Int) throws -> Int? {
        try parsing(bytes, "HFS+ volume header") { s in
            try s.seek(toRelativeOffset: at)
            var header = try s.sliceSpan(byteCount: 48)
            guard [0x482B, 0x4858].contains(try UInt16(parsingBigEndian: &header)) else { return nil }
            try header.seek(toRelativeOffset: 38)
            let blockSize = try Int(parsing: &header, storedAsBigEndian: UInt32.self)
            return try blockSize.multipliedThrowingOnOverflow(by: Int(parsing: &header, storedAsBigEndian: UInt32.self))
        }
    }

    // MARK: - Raw fork I/O

    /// The fork's extents in file order: the eight inline ones, then any in the extents overflow file.
    func extents(_ fork: Fork, fileID: UInt32, resource: Bool = false) throws -> [Extent] {
        let inline = fork.extents.reduce(0) { $0 + Int($1.count) }
        guard inline < Int(fork.totalBlocks), fileID != Self.extentsID else { return fork.extents }
        if overflow == nil { overflow = try readOverflow() }
        let more = (overflow?[UInt64(fileID) << 8 | (resource ? 0xFF : 0)] ?? []).sorted { $0.0 < $1.0 }.flatMap(\.1)
        let all = fork.extents + more
        guard all.reduce(0, { $0 + Int($1.count) }) >= Int(fork.totalBlocks) else {
            throw FirmwareError(.unsupported, "\(url.lastPathComponent): file \(fileID) is missing overflow extents")
        }
        return all
    }

    func io(
        _ fork: Fork,
        fileID: UInt32,
        resource: Bool = false,
        offset: Int,
        count: Int,
        _ body: (_ diskOffset: Int, _ bufferOffset: Int, _ n: Int) throws -> Void
    ) throws {
        var off = offset
        var done = 0
        var base = 0
        for e in try extents(fork, fileID: fileID, resource: resource) where done < count {
            let len = Int(e.count) * blockSize
            if off < base + len {
                let n = min(count - done, base + len - off)
                try body(Int(e.start) * blockSize + (off - base), done, n)
                done += n
                off += n
            }
            base += len
        }
        guard done == count else {
            throw FirmwareError(.unsupported, "\(url.lastPathComponent): read past the end of file \(fileID)")
        }
    }

    func read(_ fork: Fork, fileID: UInt32, resource: Bool = false, offset: Int, count: Int) throws -> [UInt8] {
        guard offset >= 0, count >= 0, offset + count <= Int(fork.totalBlocks) * blockSize else {
            throw FirmwareError(.unsupported, "\(url.lastPathComponent): read past the end of file \(fileID)")
        }
        var out = [UInt8](repeating: 0, count: count)
        try io(fork, fileID: fileID, resource: resource, offset: offset, count: count) { disk, at, n in
            let got = out.withUnsafeMutableBytes { p in p.baseAddress.map { pread(fd, $0 + at, n, off_t(disk)) } ?? 0 }
            // past the end of a sparse or short image reads as zeros, as build_nand.FlatVolume does
            if got < 0 { throw FirmwareError(.internal, "pread \(url.path): \(String(cString: strerror(errno)))") }
        }
        return out
    }

    func write(_ fork: Fork, fileID: UInt32, offset: Int, bytes: [UInt8]) throws {
        guard writable else { throw FirmwareError(.internal, "\(url.lastPathComponent) is open read-only") }
        try io(fork, fileID: fileID, offset: offset, count: bytes.count) { disk, at, n in
            let put = bytes.withUnsafeBytes { p in p.baseAddress.map { pwrite(fd, $0 + at, n, off_t(disk)) } ?? 0 }
            if put != n { throw FirmwareError(.internal, "pwrite \(url.path): \(String(cString: strerror(errno)))") }
        }
    }

    /// Streams a file's content through `body`: its data fork, following a hard link to its inode, and
    /// decompressed when the file is HFS-compressed (decmpfs zlib, inline or in the resource fork).
    public func readContents(_ r: CatalogRecord, _ body: (ArraySlice<UInt8>) throws -> Void) throws {
        let r = try r.isHardLink ? inode(r) : r
        if r.ownerFlags & Self.compressed != 0 { return try body(try decompressed(r)[...]) }
        guard let fork = r.data else { return }
        var off = 0
        let size = Int(fork.logicalSize)
        while off < size {
            let n = min(1 << 22, size - off)
            try body(try read(fork, fileID: r.cnid, offset: off, count: n)[...])
            off += n
        }
    }

    /// The content size: the data fork's, or a compressed file's decmpfs uncompressed size.
    public func size(_ r: CatalogRecord) throws -> UInt64 {
        let r = try r.isHardLink ? inode(r) : r
        if r.ownerFlags & Self.compressed != 0, let x = try decmpfsHeader(r.cnid) { return try le64(x, 8) }
        return r.data?.logicalSize ?? 0
    }

    func decmpfsHeader(_ cnid: UInt32) throws -> [UInt8]? {
        if decmpfs == nil { decmpfs = try readDecmpfs() }
        return decmpfs?[cnid].flatMap { x in x.count >= 16 && (try? le32(x, 0)) == 0x636D_7066 ? x : nil }
    }

    /// The catalog IDs that own any extended attribute (the attributes B-tree's keys).
    public func attributeOwners() throws -> Set<UInt32> {
        var out = Set<UInt32>()
        guard attributesFork.logicalSize > 0 else { return out }
        try leaves(try btree(attributesFork, fileID: Self.attributesID)) { _, _, r in
            if r.count >= 14 { out.insert(try r.be32(at: 4)) }
        }
        return out
    }

    private func readDecmpfs() throws -> [UInt32: [UInt8]] {
        var out: [UInt32: [UInt8]] = [:]
        guard attributesFork.logicalSize > 0 else { return out }
        let want = Array("com.apple.decmpfs".utf16)
        try leaves(try btree(attributesFork, fileID: Self.attributesID)) { _, _, r in
            guard r.count >= 14 else { return }
            let keyLen = Int(try r.be16(at: 0))
            let nameLen = Int(try r.be16(at: 12))
            guard nameLen == want.count, 14 + 2 * nameLen <= r.count,
                try (0..<nameLen).allSatisfy({ try r.be16(at: 14 + 2 * $0) == want[$0] })
            else { return }
            let body = 2 + keyLen
            guard body + 16 <= r.count, try r.be32(at: body) == 0x10 else { return }  // kHFSPlusAttrInlineData
            let size = Int(try r.be32(at: body + 12))
            guard body + 16 + size <= r.count else { return }
            out[try r.be32(at: 4)] = try r.bytes(at: body + 16, size)
        }
        return out
    }

    /// decmpfs types 3 (zlib, inline in the attribute) and 4 (zlib, 64 KiB blocks in the resource fork).
    func decompressed(_ r: CatalogRecord) throws -> [UInt8] {
        guard let x = try decmpfsHeader(r.cnid) else {
            throw FirmwareError(.unsupported, "\(r.name): compressed, no decmpfs attribute")
        }
        return try Self.decmpfs(x, name: r.name) {
            guard let rf = r.resource else { return [] }
            return try read(rf, fileID: r.cnid, resource: true, offset: 0, count: Int(rf.logicalSize))
        }
    }

    /// The content of a compressed file from its com.apple.decmpfs attribute `x` and, for type 4, its resource fork.
    static func decmpfs(_ x: [UInt8], name: String, resourceFork: () throws -> [UInt8]) throws -> [UInt8] {
        // decmpfs_disk_header: magic, compression_type, uncompressed_size (little-endian)
        let (type, size) = try parsing(x, "\(name): decmpfs header") { s in
            try s.seek(toRelativeOffset: 4)
            return (try UInt32(parsingLittleEndian: &s), try Int(parsing: &s, storedAsLittleEndian: UInt64.self))
        }
        func inflate(_ c: ArraySlice<UInt8>, _ max: Int) throws -> [UInt8] {
            guard let first = c.first else { return [] }
            if first & 0x0F == 0x0F { return Array(c.dropFirst()) }  // stored
            let z = Array(c.dropFirst(2))  // zlib header; COMPRESSION_ZLIB is raw deflate
            // deflate expands at most 1032:1
            guard max <= 1032 * z.count + 1032 else {
                throw FirmwareError(.unsupported, "\(name): decmpfs size past what its data holds")
            }
            var out = [UInt8](repeating: 0, count: max)
            let n = compression_decode_buffer(&out, max, z, z.count, nil, COMPRESSION_ZLIB)
            guard n > 0 || max == 0 else { throw FirmwareError(.unsupported, "\(name): bad decmpfs zlib data") }
            return Array(out.prefix(n))
        }
        var out: [UInt8]
        switch type {
        case 3: out = try inflate(x[16...], size)
        case 4:
            let fork = try resourceFork()
            guard fork.count >= 260 else { throw FirmwareError(.unsupported, "\(name): no compressed resource fork") }
            // a resource fork header's data offset, then there: its length, the block count, (offset, length) each
            let blocks = try parsing(fork, "\(name): decmpfs block table") { s in
                let base = Int(try UInt32(parsingBigEndian: &s)) + 4
                try s.seek(toAbsoluteOffset: base)
                var blocks: [(Int, Int)] = []
                for _ in 0..<(try UInt32(parsingLittleEndian: &s)) {
                    blocks.append(
                        (base + Int(try UInt32(parsingLittleEndian: &s)), Int(try UInt32(parsingLittleEndian: &s)))
                    )
                }
                return blocks
            }
            out = []
            out.reserveCapacity(min(size, blocks.count << 16))
            for (off, len) in blocks {
                guard off + len <= fork.count else {
                    throw FirmwareError(.unsupported, "\(name): decmpfs block past the fork")
                }
                out += try inflate(fork[off..<off + len], min(1 << 16, size - out.count))
            }
        default: throw FirmwareError(.unsupported, "\(name): decmpfs type \(type)")
        }
        guard out.count == size else {
            throw FirmwareError(.unsupported, "\(name): decompressed \(out.count) of \(size) bytes")
        }
        return out
    }

    public func contents(_ r: CatalogRecord) throws -> Data {
        var d = Data()
        try readContents(r) { d.append(contentsOf: $0) }
        return d
    }

    // MARK: - B-trees

    struct BTree {
        let fork: Fork, fileID: UInt32, nodeSize: Int, firstLeaf: UInt32
    }

    func btree(_ fork: Fork, fileID: UInt32) throws -> BTree {
        let h = try read(fork, fileID: fileID, offset: 0, count: 512)
        let (nodeSize, firstLeaf) = try parsing(h, "\(url.lastPathComponent): B-tree header") { s in
            (Int(try s.be16(at: 14 + 18)), try s.be32(at: 14 + 10))
        }
        guard (512...32768).contains(nodeSize), nodeSize & (nodeSize - 1) == 0 else {
            throw FirmwareError(.unsupported, "\(url.lastPathComponent): B-tree node size \(nodeSize)")
        }
        return BTree(fork: fork, fileID: fileID, nodeSize: nodeSize, firstLeaf: firstLeaf)
    }

    /// Every record of every leaf node, in order: (node number, the record's offset in the node, the record).
    func leaves(_ t: BTree, _ body: (Int, Int, inout ParserSpan) throws -> Void) throws {
        var n = t.firstLeaf
        var seen = Set<UInt32>()
        while n != 0 {
            guard seen.insert(n).inserted else {
                throw FirmwareError(.unsupported, "\(url.lastPathComponent): B-tree leaf loop at node \(n)")
            }
            let buf = try read(t.fork, fileID: t.fileID, offset: Int(n) * t.nodeSize, count: t.nodeSize)
            n = try parsing(buf, "\(url.lastPathComponent): B-tree node \(n)") { node in
                // the records' offsets, then the free space's, from the node's end
                let count = Int(try node.be16(at: 10))
                var table = try node.seeking(toOffsetFromEnd: 2 * (count + 1))
                let offs = try [UInt16](parsing: &table, count: count + 1) { try UInt16(parsingBigEndian: &$0) }
                    .reversed().map(Int.init)
                for i in 0..<count where offs[i + 1] >= offs[i] {
                    var r = try node.seeking(toRelativeOffset: offs[i])
                    var record = try r.sliceSpan(byteCount: offs[i + 1] - offs[i])
                    try body(Int(n), offs[i], &record)
                }
                return try node.be32(at: 0)
            }
        }
    }

    private func readOverflow() throws -> [UInt64: [(UInt32, [Extent])]] {
        var out: [UInt64: [(UInt32, [Extent])]] = [:]
        guard extentsFork.logicalSize > 0 else { return out }
        try leaves(try btree(extentsFork, fileID: Self.extentsID)) { _, _, r in
            // HFSPlusExtentKey (keyLength, forkType, pad, fileID, startBlock), then eight extents
            guard r.count >= 12 + 64 else { return }
            try r.seek(toRelativeOffset: 2)
            let fork = try UInt8(parsing: &r)
            try r.seek(toRelativeOffset: 1)
            let key = UInt64(try UInt32(parsingBigEndian: &r)) << 8 | UInt64(fork)
            let start = try UInt32(parsingBigEndian: &r)
            let exts = try [Extent](parsing: &r, count: 8) { e in
                Extent(start: try UInt32(parsingBigEndian: &e), count: try UInt32(parsingBigEndian: &e))
            }.filter { $0.count > 0 }
            out[key, default: []].append((start, exts))
        }
        return out
    }

    /// Every folder and file record, in catalog (leaf) order.
    public func catalog() throws -> [CatalogRecord] {
        if let c = catalogCache { return c }
        var out: [CatalogRecord] = []
        try leaves(try btree(catalogFork, fileID: Self.catalogID)) { node, start, r in
            guard r.count >= 10 else { return }
            let keyLen = Int(try r.be16(at: 0))
            let parent = try r.be32(at: 2)
            let nameLen = Int(try r.be16(at: 6))
            var body = start + 2 + keyLen
            if body % 2 == 1 { body += 1 }
            let b = body - start
            guard b + 2 <= r.count, 8 + 2 * nameLen <= r.count else { return }
            let type = try r.be16(at: b)
            guard type == 1 || type == 2, b + 48 <= r.count else { return }  // folder / file (threads skipped)
            var n = try r.seeking(toRelativeOffset: 8)
            let name = String(
                decoding: try [UInt16](parsing: &n, count: nameLen) { try UInt16(parsingBigEndian: &$0) },
                as: UTF16.self
            )
            let file = type == 2 && b + 248 <= r.count
            out.append(
                CatalogRecord(
                    kind: type == 1 ? .folder : .file,
                    parent: parent,
                    name: name,
                    cnid: try r.be32(at: b + 8),
                    uid: try r.be32(at: b + 32),
                    gid: try r.be32(at: b + 36),
                    adminFlags: try r.byte(at: b + 40),
                    ownerFlags: try r.byte(at: b + 41),
                    mode: try r.be16(at: b + 42),
                    special: try r.be32(at: b + 44),
                    fileType: b + 56 <= r.count ? try r.be32(at: b + 48) : 0,
                    creator: b + 56 <= r.count ? try r.be32(at: b + 52) : 0,
                    data: file ? try r.fork(at: b + 88) : nil,
                    resource: file ? try r.fork(at: b + 168) : nil,
                    dates: try (0..<5).map { try r.be32(at: b + 12 + 4 * $0) },
                    node: node,
                    bodyOffset: body
                )
            )
        }
        catalogCache = out
        return out
    }

    /// (parent CNID, name) -> record, as setowner.index_catalog builds it.
    public func index() throws -> [Key: CatalogRecord] {
        var out: [Key: CatalogRecord] = [:]
        for r in try catalog() { out[Key(parent: r.parent, name: r.name)] = r }
        return out
    }

    public struct Key: Hashable, Sendable { public let parent: UInt32, name: String }

    public func record(at path: String) throws -> CatalogRecord {
        try resolve(path, try index())
    }

    func resolve(_ path: String, _ idx: [Key: CatalogRecord]) throws -> CatalogRecord {
        var cid = Self.rootID
        var hit: CatalogRecord?
        for part in path.split(separator: "/") {
            guard let r = idx[Key(parent: cid, name: Self.catalogName(String(part)))] else {
                throw FirmwareError(
                    .internal,
                    "\(url.lastPathComponent): not in the catalog: \(path) (stuck at \(part))"
                )
            }
            hit = r
            cid = r.cnid
        }
        if let hit { return hit }
        guard let root = try catalog().first(where: { $0.cnid == Self.rootID }) else {
            throw FirmwareError(.unsupported, "no root folder")
        }
        return root
    }

    func inode(_ link: CatalogRecord) throws -> CatalogRecord {
        let idx = try index()
        guard let dir = idx[Key(parent: Self.rootID, name: "\0\0\0\0HFS+ Private Data")],
            let node = idx[Key(parent: dir.cnid, name: "iNode\(link.special)")]
        else {
            throw FirmwareError(
                .unsupported,
                "\(url.lastPathComponent): hard link \(link.name) has no iNode\(link.special)"
            )
        }
        return node
    }

    // MARK: - Listings

    /// A catalog name as macOS presents it in a path, and back: HFS+ names may hold "/", which the VFS shows as ":"
    /// (1.0's /usr/share/zoneinfo/Etc/GMT-0/15 is GMT-0:15 on the host).
    static func posixName(_ name: String) -> String { name.replacingOccurrences(of: "/", with: ":") }
    static func catalogName(_ name: String) -> String { name.replacingOccurrences(of: ":", with: "/") }

    /// Volume-relative path of every folder and file record (the root is ""), skipping the hard-link
    /// private directories the kernel hides.
    public func paths() throws -> [(path: String, record: CatalogRecord)] {
        let recs = try catalog()
        var byID: [UInt32: CatalogRecord] = [:]
        for r in recs { byID[r.cnid] = r }
        var memo: [UInt32: String?] = [Self.rootID: ""]
        func path(_ id: UInt32) -> String? {
            if let p = memo[id] { return p }
            memo[id] = .some(nil)  // a parent loop in a damaged catalog leads nowhere
            guard let r = byID[id], r.parent != 1 else { return nil }
            let p: String? =
                r.parent == Self.rootID && Self.privateDirs.contains(r.name)
                ? nil
                : path(r.parent).map { $0.isEmpty ? Self.posixName(r.name) : $0 + "/" + Self.posixName(r.name) }
            memo[id] = .some(p)
            return p
        }
        return recs.compactMap { r in path(r.cnid).map { ($0, r) } }.sorted { $0.path < $1.path }
    }

    /// Owner, mode, flags, sizes, content sha256 (files) and symlink targets for every path under `prefix`.
    public func listing(under prefix: String = "", hashes: Bool = true) throws -> [Entry] {
        try paths().filter { prefix.isEmpty || $0.path == prefix || $0.path.hasPrefix(prefix + "/") }.map { p, r in
            let content = try r.isHardLink ? inode(r) : r
            // a hard link's own record reuses the BSD fields for the link chain; the inode has the real ones
            let c = content
            var e = Entry(
                path: p,
                uid: c.uid,
                gid: c.gid,
                mode: c.mode,
                flags: UInt32(c.adminFlags) << 16 | UInt32(c.ownerFlags),
                size: try size(r),
                resourceSize: content.resource?.logicalSize ?? 0
            )
            if r.isSymlink {
                e.link = String(decoding: try contents(r), as: UTF8.self)
            } else if r.kind == .file && hashes {
                var h = SHA256()
                try readContents(r) { s in s.withUnsafeBytes { h.update(bufferPointer: $0) } }
                e.sha256 = h.finalize().map { String(format: "%02x", $0) }.joined()
            }
            return e
        }
    }

    /// ipad1_rootfs.var_owners: {path relative to `top`: (uid, gid)} for everything below it.
    public func owners(under top: String) throws -> [String: (uid: UInt32, gid: UInt32)] {
        var out: [String: (uid: UInt32, gid: UInt32)] = [:]
        for (p, r) in try paths() where p.hasPrefix(top + "/") {
            out[String(p.dropFirst(top.count + 1))] = (r.uid, r.gid)
        }
        return out
    }

    // MARK: - Edits

    /// Sets uid/gid (and with `mode`, the permission bits; the file type is kept) on each path's catalog
    /// record, in place. Without `mode` a record already at (uid, gid) is left alone, as build_nand.set_owner
    /// does; returns the number of records changed. Throws before writing anything if a path is missing.
    @discardableResult
    public func setOwner(_ paths: [String], uid: UInt32, gid: UInt32, mode: UInt16? = nil, flags: UInt32? = nil) throws
        -> Int
    {
        let idx = try index()
        let targets = try paths.map { p -> CatalogRecord in
            guard !p.split(separator: "/").isEmpty else {
                throw FirmwareError(.internal, "refusing to touch the volume root")
            }
            let record = try resolve(p, idx)
            return try record.isHardLink ? inode(record) : record
        }
        let t = try btree(catalogFork, fileID: Self.catalogID)
        var changed = 0
        var done = Set<UInt32>()
        for r in targets where done.insert(r.cnid).inserted {
            var patch = [UInt8](repeating: 0, count: 8)
            putBE32(&patch, 0, uid)
            putBE32(&patch, 4, gid)
            let at = r.node * t.nodeSize + r.bodyOffset + 32
            if let mode {
                let m = r.mode & 0o170000 | mode & 0o7777
                try write(catalogFork, fileID: Self.catalogID, offset: at, bytes: patch)
                try write(
                    catalogFork,
                    fileID: Self.catalogID,
                    offset: at + 10,
                    bytes: [UInt8(m >> 8), UInt8(m & 0xFF)]
                )
                changed += 1
            } else if (r.uid, r.gid) != (uid, gid) {
                try write(catalogFork, fileID: Self.catalogID, offset: at, bytes: patch)
                changed += 1
            }
            if let flags {
                try write(
                    catalogFork,
                    fileID: Self.catalogID,
                    offset: at + 8,
                    bytes: [UInt8(truncatingIfNeeded: flags >> 16), UInt8(truncatingIfNeeded: flags)]
                )
            }
        }
        catalogCache = nil
        return changed
    }

    /// Sets each folder's HFSX folder count (folderCount, the number of subfolders; kept only on records with
    /// kHFSHasFolderCountMask) in place. Bookkeeping only: nothing else in the record changes. Throws before
    /// writing anything if a CNID is not such a folder.
    public func setFolderCounts(_ counts: [UInt32: UInt32]) throws {
        guard writable else { throw FirmwareError(.internal, "\(url.lastPathComponent) is open read-only") }
        let byID = Dictionary(
            try catalog().filter { $0.kind == .folder }.map { ($0.cnid, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        let t = try btree(catalogFork, fileID: Self.catalogID)
        let targets = try counts.map { cnid, n -> (Int, UInt32) in
            guard let r = byID[cnid] else {
                throw FirmwareError(.internal, "\(url.lastPathComponent): no folder \(cnid)")
            }
            let body = r.node * t.nodeSize + r.bodyOffset
            // kHFSHasFolderCountMask
            guard try read(catalogFork, fileID: Self.catalogID, offset: body + 3, count: 1)[0] & 0x10 != 0 else {
                throw FirmwareError(.internal, "\(url.lastPathComponent): folder \(cnid) keeps no folder count")
            }
            return (body + 84, n)  // HFSPlusCatalogFolder.folderCount
        }
        for (at, n) in targets {
            var b = [UInt8](repeating: 0, count: 4)
            putBE32(&b, 0, n)
            try write(catalogFork, fileID: Self.catalogID, offset: at, bytes: b)
        }
        catalogCache = nil
    }

    // MARK: - Determinism (what a mount leaves behind: dates, a fresh volume's identifier, the journal)

    /// The newest create/modify/attribute/access date in the catalog: on a pristine IPSW volume, its newest file.
    public func newestDate() throws -> UInt32 {
        try catalog().reduce(0) { max($0, $1.dates.prefix(4).max() ?? 0) }
    }

    /// Makes an edited volume the same for the same edits. Every catalog date (create, content-modified,
    /// attribute-modified, accessed) later than `after` becomes `to`, and macOS's "date added" in those records'
    /// extended Finder info (a Unix time; iOS leaves it 0) is cleared; the volume headers' create/modify/backup/
    /// checked dates likewise (newfs_hfs dates a volume "now"); with `uuid`, the 8-byte Finder-info volume
    /// identifier (newfs_hfs draws a random one); and the unused bytes of every B-tree node are zeroed (records
    /// macOS made and the unmount deleted, .fseventsd's random names, stay there otherwise). Returns the number of
    /// catalog records dated. Apple's own dates stay: they are older than `after`.
    @discardableResult
    public func normalize(after: UInt32, to: UInt32, uuid: [UInt8]? = nil) throws -> Int {
        guard writable else { throw FirmwareError(.internal, "\(url.lastPathComponent) is open read-only") }
        let t = try btree(catalogFork, fileID: Self.catalogID)
        var changed = 0
        for r in try catalog() where r.dates.prefix(4).contains(where: { $0 > after }) {
            var patch = [UInt8](repeating: 0, count: 16)
            for (i, d) in r.dates.prefix(4).enumerated() { putBE32(&patch, 4 * i, d > after ? to : d) }
            let body = r.node * t.nodeSize + r.bodyOffset
            try write(catalogFork, fileID: Self.catalogID, offset: body + 12, bytes: patch)
            // finderInfo.date_added
            try write(catalogFork, fileID: Self.catalogID, offset: body + 68, bytes: [0, 0, 0, 0])
            changed += 1
        }
        catalogCache = nil
        for at in headerOffsets() {
            var vh = [UInt8](repeating: 0, count: 512)
            guard pread(fd, &vh, 512, off_t(at)) == 512 else {
                throw FirmwareError(.internal, "read volume header at \(at) of \(url.lastPathComponent)")
            }
            for o in stride(from: 16, through: 28, by: 4) where try be32(vh, o) > after { putBE32(&vh, o, to) }
            if let uuid, uuid.count == 8 { vh.replaceSubrange(104..<112, with: uuid) }
            guard pwrite(fd, vh, 512, off_t(at)) == 512 else {
                throw FirmwareError(.internal, "write volume header at \(at) of \(url.lastPathComponent)")
            }
        }
        try zeroBTreeSlack()
        return changed
    }

    /// Zeroes each B-tree node's unused bytes (between its last record and its offset table) in the catalog,
    /// extents and attributes trees. A node: fLink, bLink, kind, height, numRecords (14 bytes), records, free
    /// space, then the offsets of the records and of the free space, from the node's end.
    func zeroBTreeSlack() throws {
        for (fork, id) in [
            (catalogFork, Self.catalogID), (extentsFork, Self.extentsID), (attributesFork, Self.attributesID)
        ] where fork.logicalSize > 0 {
            let t = try btree(fork, fileID: id)
            for node in 0..<(Int(fork.logicalSize) / t.nodeSize) {
                let buf = try read(fork, fileID: id, offset: node * t.nodeSize, count: t.nodeSize)
                let records = Int(try be16(buf, 10))
                let table = t.nodeSize - 2 * (records + 1)
                guard records > 0, table > 14 else { continue }
                let free = Int(try be16(buf, table))
                guard free >= 14, free < table, buf[free..<table].contains(where: { $0 != 0 }) else { continue }
                try write(
                    fork,
                    fileID: id,
                    offset: node * t.nodeSize + free,
                    bytes: [UInt8](repeating: 0, count: table - free)
                )
            }
        }
    }

    /// The volume header and its alternate(s): at 1024, at the volume's end - 1024 and, once VolumeMount.grow has
    /// padded the file, at the file's end - 1024; whichever carry the signature.
    func headerOffsets() -> [Int] {
        var st = stat()
        let size = fstat(fd, &st) == 0 ? Int(st.st_size) : 0
        return Set([1024, totalBlocks * blockSize - 1024, size - 1024]).sorted().filter { at in
            var sig = [UInt8](repeating: 0, count: 2)
            return at >= 1024 && pread(fd, &sig, 2, off_t(at)) == 2 && sig[0] == 0x48
                && (sig[1] == 0x2B || sig[1] == 0x58)
        }
    }

    /// The journal's byte offset and size in the volume when the volume is journaled and the journal lives in it;
    /// `needsInit` while the kernel has yet to write its header (newfs_hfs leaves a volume so).
    public func journal() throws -> (offset: Int, size: Int, needsInit: Bool)? {
        var vh = [UInt8](repeating: 0, count: 512)
        // kHFSVolumeJournaledBit, journalInfoBlock
        guard pread(fd, &vh, 512, 1024) == 512, try be32(vh, 4) & (1 << 13) != 0, try be32(vh, 12) != 0 else {
            return nil
        }
        var jib = [UInt8](repeating: 0, count: 52)  // flags, device_signature[8], offset, size
        // in the volume
        guard pread(fd, &jib, 52, off_t(Int(try be32(vh, 12)) * blockSize)) == 52, try be32(jib, 0) & 3 == 1 else {
            return nil
        }
        let offset = Int(try be64(jib, 36))
        let size = Int(try be64(jib, 44))
        return size > 0 ? (offset, size, try be32(jib, 0) & 4 != 0) : nil
    }

    /// The journal info block and the journal (offset, bytes) while the journal is still to be initialized or is
    /// empty (start == end: nothing to replay); nil otherwise. VolumeMount puts them back after a mount: the mount
    /// initializes the journal, fills it with transactions and moves its header, and a clean unmount leaves it
    /// empty again, so the bytes as they were are as good and the same every time.
    public func journalSnapshot() throws -> [(offset: Int, bytes: Data)]? {
        var vh = [UInt8](repeating: 0, count: 512)
        guard let j = try journal(), pread(fd, &vh, 512, 1024) == 512 else { return nil }
        if !j.needsInit {
            var hdr = [UInt8](repeating: 0, count: 32)  // magic, endian, start, end, ...
            guard pread(fd, &hdr, 32, off_t(j.offset)) == 32, hdr[8..<16] == hdr[16..<24] else { return nil }
        }
        return try [(Int(try be32(vh, 12)) * blockSize, blockSize), (j.offset, j.size)].map { at, n in
            var bytes = Data(count: n)
            guard bytes.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, n, off_t(at)) }) == n else {
                throw FirmwareError(.internal, "read the journal of \(url.lastPathComponent)")
            }
            return (at, bytes)
        }
    }

    /// Hands the journal to the device: zeroes it and sets the info block's kJIJournalNeedInitMask, as newfs_hfs
    /// leaves it, so the device's kernel writes the header for its own block size at the first mount. A header
    /// the host wrote says 512-byte blocks, which a kernel that adopts the header's size (iPhone OS 1.x, on
    /// 2048-byte NAND pages) then fails its I/O with.
    public func leaveJournalToDevice() throws {
        guard writable else { throw FirmwareError(.internal, "\(url.lastPathComponent) is open read-only") }
        var vh = [UInt8](repeating: 0, count: 512)
        guard let j = try journal(), pread(fd, &vh, 512, 1024) == 512 else {
            throw FirmwareError(.internal, "\(url.lastPathComponent) has no journal in the volume")
        }
        let at = Int(try be32(vh, 12)) * blockSize
        var jib = [UInt8](repeating: 0, count: 52)  // flags, device_signature[8], offset, size
        guard pread(fd, &jib, 52, off_t(at)) == 52 else {
            throw FirmwareError(.internal, "read the journal info block of \(url.lastPathComponent)")
        }
        // Write the whole block, not just the flags word: the kernel's newfs leaves its own fill in the bytes after
        // offset/size (0x5a on some hosts, 0 on others), so trusting them made the output depend on the host that
        // prepared the volume — two hosts recorded different .journal_info_block listings. A fresh block, with only
        // the needs-init flag set, the device signature zeroed and the journal's offset and size kept, is the same
        // everywhere, as newfs_hfs leaves it.
        var block = [UInt8](repeating: 0, count: blockSize)
        putBE32(&block, 0, (try be32(jib, 0) | 4) & 0x7)  // kJIJournalInFSMask | kJIJournalNeedInitMask
        block.replaceSubrange(36..<52, with: jib[36..<52])  // offset, size, as diskutil/newfs wrote them
        try restore([(j.offset, Data(count: j.size)), (at, Data(block))])
    }

    /// Sets kHFSContentProtectionBit (0x40000000) in the volume header's attributes, as a restore formats iOS's
    /// data volume.
    public func setContentProtection() throws {
        guard writable else { throw FirmwareError(.internal, "\(url.lastPathComponent) is open read-only") }
        for at in headerOffsets() {
            var a = [UInt8](repeating: 0, count: 4)
            guard pread(fd, &a, 4, off_t(at + 4)) == 4 else {
                throw FirmwareError(.internal, "read volume header at \(at) of \(url.lastPathComponent)")
            }
            putBE32(&a, 0, try be32(a, 0) | 0x4000_0000)
            guard pwrite(fd, a, 4, off_t(at + 4)) == 4 else {
                throw FirmwareError(.internal, "write volume header at \(at) of \(url.lastPathComponent)")
            }
        }
    }

    public func restore(_ pieces: [(offset: Int, bytes: Data)]) throws {
        guard writable else { throw FirmwareError(.internal, "\(url.lastPathComponent) is open read-only") }
        for p in pieces {
            guard
                p.bytes.withUnsafeBytes({ pwrite(fd, $0.baseAddress, p.bytes.count, off_t(p.offset)) }) == p.bytes.count
            else {
                throw FirmwareError(.internal, "write \(url.lastPathComponent) at \(p.offset)")
            }
        }
    }
}

extension ParserSpan {
    /// The HFSPlusForkData `o` bytes in; the span stays where it is.
    func fork(at o: Int) throws -> HFSPlusVolume.Fork {
        var s = try seeking(toRelativeOffset: o)
        return try HFSPlusVolume.Fork(parsing: &s)
    }
}
