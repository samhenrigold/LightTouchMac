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

import Compression
import CryptoKit
import Foundation

public final class HFSPlusVolume {
    public struct Extent: Sendable, Equatable { public let start: UInt32, count: UInt32 }

    public struct Fork: Sendable, Equatable {
        public let logicalSize: UInt64
        public let totalBlocks: UInt32
        public let extents: [Extent]
        init(_ b: [UInt8], _ o: Int) {
            logicalSize = be64(b, o); totalBlocks = be32(b, o + 12)
            extents = (0..<8).map { Extent(start: be32(b, o + 16 + 8 * $0), count: be32(b, o + 20 + 8 * $0)) }.filter { $0.count > 0 }
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
        /// B-tree node number and the byte offset of the record body (past the key) within that node.
        public let node: Int, bodyOffset: Int
        public var isSymlink: Bool { kind == .file && mode & 0o170000 == 0o120000 }
        /// An HFS+ file hard link ('hlnk'/'hfs+'): the content is the private directory's iNode<special>.
        public var isHardLink: Bool { kind == .file && fileType == 0x686C6E6B && creator == 0x6866732B }
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
    static let compressed: UInt8 = 0x20   // UF_COMPRESSED: the content is in com.apple.decmpfs (+ the resource fork)
    static let privateDirs: Set<String> = ["\0\0\0\0HFS+ Private Data", ".HFS+ Private Directory Data\r"]

    public init(_ url: URL, writable: Bool = false) throws {
        self.url = url; self.writable = writable
        fd = open(url.path, writable ? O_RDWR : O_RDONLY)
        guard fd >= 0 else { throw FirmwareError(.internal, "open \(url.path): \(String(cString: strerror(errno)))") }
        var vh = [UInt8](repeating: 0, count: 512)
        guard pread(fd, &vh, 512, 1024) == 512, vh[0] == 0x48, vh[1] == 0x2B || vh[1] == 0x58 else {
            close(fd)
            throw FirmwareError(.unsupported, "\(url.lastPathComponent): no HFS+ volume header")
        }
        signature = vh[1] == 0x58 ? "HX" : "H+"
        fileCount = Int(be32(vh, 32)); folderCount = Int(be32(vh, 36)); blockSize = Int(be32(vh, 40))
        totalBlocks = Int(be32(vh, 44)); freeBlocks = Int(be32(vh, 48)); nextCatalogID = Int(be32(vh, 64))
        extentsFork = Fork(vh, 192); catalogFork = Fork(vh, 272); attributesFork = Fork(vh, 352)
    }

    deinit { close(fd) }

    // MARK: raw fork I/O

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

    func io(_ fork: Fork, fileID: UInt32, resource: Bool = false, offset: Int, count: Int,
            _ body: (_ diskOffset: Int, _ bufferOffset: Int, _ n: Int) throws -> Void) throws {
        var off = offset, done = 0, base = 0
        for e in try extents(fork, fileID: fileID, resource: resource) where done < count {
            let len = Int(e.count) * blockSize
            if off < base + len {
                let n = min(count - done, base + len - off)
                try body(Int(e.start) * blockSize + (off - base), done, n)
                done += n; off += n
            }
            base += len
        }
        guard done == count else { throw FirmwareError(.unsupported, "\(url.lastPathComponent): read past the end of file \(fileID)") }
    }

    func read(_ fork: Fork, fileID: UInt32, resource: Bool = false, offset: Int, count: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        try io(fork, fileID: fileID, resource: resource, offset: offset, count: count) { disk, at, n in
            let got = out.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + at, n, off_t(disk)) }
            // past the end of a sparse or short image reads as zeros, as build_nand.FlatVolume does
            if got < 0 { throw FirmwareError(.internal, "pread \(url.path): \(String(cString: strerror(errno)))") }
        }
        return out
    }

    func write(_ fork: Fork, fileID: UInt32, offset: Int, bytes: [UInt8]) throws {
        guard writable else { throw FirmwareError(.internal, "\(url.lastPathComponent) is open read-only") }
        try io(fork, fileID: fileID, offset: offset, count: bytes.count) { disk, at, n in
            let put = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress! + at, n, off_t(disk)) }
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
        if r.ownerFlags & Self.compressed != 0, let x = try decmpfsHeader(r.cnid) { return le64(x, 8) }
        return r.data?.logicalSize ?? 0
    }

    func decmpfsHeader(_ cnid: UInt32) throws -> [UInt8]? {
        if decmpfs == nil { decmpfs = try readDecmpfs() }
        return decmpfs?[cnid].flatMap { $0.count >= 16 && le32($0, 0) == 0x636D7066 ? $0 : nil }
    }

    private func readDecmpfs() throws -> [UInt32: [UInt8]] {
        var out: [UInt32: [UInt8]] = [:]
        guard attributesFork.logicalSize > 0 else { return out }
        let want = Array("com.apple.decmpfs".utf16)
        try leaves(try btree(attributesFork, fileID: Self.attributesID)) { _, buf, offs in
            for i in 0..<(offs.count - 1) where offs[i + 1] - offs[i] >= 14 {
                let o = offs[i], keyLen = Int(be16(buf, o)), nameLen = Int(be16(buf, o + 12))
                guard nameLen == want.count, o + 14 + 2 * nameLen <= offs[i + 1],
                      (0..<nameLen).allSatisfy({ be16(buf, o + 14 + 2 * $0) == want[$0] }) else { continue }
                let body = o + 2 + keyLen
                guard body + 16 <= offs[i + 1], be32(buf, body) == 0x10 else { continue }   // kHFSPlusAttrInlineData
                let size = Int(be32(buf, body + 12))
                guard body + 16 + size <= offs[i + 1] else { continue }
                out[be32(buf, o + 4)] = Array(buf[body + 16..<body + 16 + size])
            }
        }
        return out
    }

    /// decmpfs types 3 (zlib, inline in the attribute) and 4 (zlib, 64 KiB blocks in the resource fork).
    func decompressed(_ r: CatalogRecord) throws -> [UInt8] {
        guard let x = try decmpfsHeader(r.cnid) else { throw FirmwareError(.unsupported, "\(r.name): compressed, no decmpfs attribute") }
        let type = le32(x, 4), size = Int(le64(x, 8))
        func inflate(_ c: ArraySlice<UInt8>, _ max: Int) throws -> [UInt8] {
            guard let first = c.first else { return [] }
            if first & 0x0F == 0x0F { return Array(c.dropFirst()) }   // stored
            let z = Array(c.dropFirst(2))                             // zlib header; COMPRESSION_ZLIB is raw deflate
            var out = [UInt8](repeating: 0, count: max)
            let n = compression_decode_buffer(&out, max, z, z.count, nil, COMPRESSION_ZLIB)
            guard n > 0 || max == 0 else { throw FirmwareError(.unsupported, "\(r.name): bad decmpfs zlib data") }
            return Array(out.prefix(n))
        }
        var out: [UInt8]
        switch type {
        case 3: out = try inflate(x[16...], size)
        case 4:
            guard let rf = r.resource, rf.logicalSize >= 260 else { throw FirmwareError(.unsupported, "\(r.name): no compressed resource fork") }
            let fork = try read(rf, fileID: r.cnid, resource: true, offset: 0, count: Int(rf.logicalSize))
            let base = Int(be32(fork, 0)) + 4, n = Int(le32(fork, base))
            out = []
            out.reserveCapacity(size)
            for k in 0..<n {
                let off = base + Int(le32(fork, base + 4 + 8 * k)), len = Int(le32(fork, base + 8 + 8 * k))
                guard off + len <= fork.count else { throw FirmwareError(.unsupported, "\(r.name): decmpfs block past the fork") }
                out += try inflate(fork[off..<off + len], min(1 << 16, size - out.count))
            }
        default: throw FirmwareError(.unsupported, "\(r.name): decmpfs type \(type)")
        }
        guard out.count == size else { throw FirmwareError(.unsupported, "\(r.name): decompressed \(out.count) of \(size) bytes") }
        return out
    }

    public func contents(_ r: CatalogRecord) throws -> Data {
        var d = Data()
        try readContents(r) { d.append(contentsOf: $0) }
        return d
    }

    // MARK: B-trees

    struct BTree {
        let fork: Fork, fileID: UInt32, nodeSize: Int, firstLeaf: UInt32
    }

    func btree(_ fork: Fork, fileID: UInt32) throws -> BTree {
        let h = try read(fork, fileID: fileID, offset: 0, count: 512)
        return BTree(fork: fork, fileID: fileID, nodeSize: Int(be16(h, 14 + 18)), firstLeaf: be32(h, 14 + 10))
    }

    /// Every leaf node, in order: (node number, bytes, record offsets incl. the free-space offset).
    func leaves(_ t: BTree, _ body: (Int, [UInt8], [Int]) throws -> Void) throws {
        var n = t.firstLeaf, seen = Set<UInt32>()
        while n != 0 {
            guard seen.insert(n).inserted else { throw FirmwareError(.unsupported, "\(url.lastPathComponent): B-tree leaf loop at node \(n)") }
            let buf = try read(t.fork, fileID: t.fileID, offset: Int(n) * t.nodeSize, count: t.nodeSize)
            let count = Int(be16(buf, 10))
            let offs = (0...count).map { Int(be16(buf, t.nodeSize - 2 * ($0 + 1))) }
            try body(Int(n), buf, offs)
            n = be32(buf, 0)
        }
    }

    private func readOverflow() throws -> [UInt64: [(UInt32, [Extent])]] {
        var out: [UInt64: [(UInt32, [Extent])]] = [:]
        guard extentsFork.logicalSize > 0 else { return out }
        try leaves(try btree(extentsFork, fileID: Self.extentsID)) { _, buf, offs in
            for i in 0..<(offs.count - 1) where offs[i + 1] - offs[i] >= 12 + 64 {
                let o = offs[i]
                let key = UInt64(be32(buf, o + 4)) << 8 | UInt64(buf[o + 2])
                let exts = (0..<8).map { Extent(start: be32(buf, o + 12 + 8 * $0), count: be32(buf, o + 16 + 8 * $0)) }.filter { $0.count > 0 }
                out[key, default: []].append((be32(buf, o + 8), exts))
            }
        }
        return out
    }

    /// Every folder and file record, in catalog (leaf) order.
    public func catalog() throws -> [CatalogRecord] {
        if let c = catalogCache { return c }
        var out: [CatalogRecord] = []
        try leaves(try btree(catalogFork, fileID: Self.catalogID)) { node, buf, offs in
            for i in 0..<(offs.count - 1) {
                let start = offs[i], end = offs[i + 1]
                guard end - start >= 10 else { continue }
                let keyLen = Int(be16(buf, start)), parent = be32(buf, start + 2), nameLen = Int(be16(buf, start + 6))
                var body = start + 2 + keyLen
                if body % 2 == 1 { body += 1 }
                guard body + 2 <= end, start + 8 + 2 * nameLen <= end else { continue }
                let type = be16(buf, body)
                guard type == 1 || type == 2, body + 48 <= end else { continue }   // folder / file (threads skipped)
                let name = String(decoding: (0..<nameLen).map { be16(buf, start + 8 + 2 * $0) }, as: UTF16.self)
                let file = type == 2 && body + 248 <= end
                out.append(CatalogRecord(
                    kind: type == 1 ? .folder : .file, parent: parent, name: name, cnid: be32(buf, body + 8),
                    uid: be32(buf, body + 32), gid: be32(buf, body + 36), adminFlags: buf[body + 40], ownerFlags: buf[body + 41],
                    mode: be16(buf, body + 42), special: be32(buf, body + 44),
                    fileType: body + 56 <= end ? be32(buf, body + 48) : 0, creator: body + 56 <= end ? be32(buf, body + 52) : 0,
                    data: file ? Fork(buf, body + 88) : nil, resource: file ? Fork(buf, body + 168) : nil,
                    node: node, bodyOffset: body))
            }
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
        var cid = Self.rootID, hit: CatalogRecord?
        for part in path.split(separator: "/") {
            guard let r = idx[Key(parent: cid, name: String(part))] else {
                throw FirmwareError(.internal, "\(url.lastPathComponent): not in the catalog: \(path) (stuck at \(part))")
            }
            hit = r; cid = r.cnid
        }
        if let hit { return hit }
        guard let root = try catalog().first(where: { $0.cnid == Self.rootID }) else { throw FirmwareError(.unsupported, "no root folder") }
        return root
    }

    func inode(_ link: CatalogRecord) throws -> CatalogRecord {
        let idx = try index()
        guard let dir = idx[Key(parent: Self.rootID, name: "\0\0\0\0HFS+ Private Data")],
              let node = idx[Key(parent: dir.cnid, name: "iNode\(link.special)")] else {
            throw FirmwareError(.unsupported, "\(url.lastPathComponent): hard link \(link.name) has no iNode\(link.special)")
        }
        return node
    }

    // MARK: listings

    /// Volume-relative path of every folder and file record (the root is ""), skipping the hard-link
    /// private directories the kernel hides.
    public func paths() throws -> [(path: String, record: CatalogRecord)] {
        let recs = try catalog()
        var byID: [UInt32: CatalogRecord] = [:]
        for r in recs { byID[r.cnid] = r }
        var memo: [UInt32: String?] = [Self.rootID: ""]
        func path(_ id: UInt32) -> String? {
            if let p = memo[id] { return p }
            guard let r = byID[id], r.parent != 1 else { memo[id] = .some(nil); return nil }
            let p: String? = r.parent == Self.rootID && Self.privateDirs.contains(r.name) ? nil
                : path(r.parent).map { $0.isEmpty ? r.name : $0 + "/" + r.name }
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
            var e = Entry(path: p, uid: c.uid, gid: c.gid, mode: c.mode, flags: UInt32(c.adminFlags) << 16 | UInt32(c.ownerFlags),
                          size: try size(r), resourceSize: content.resource?.logicalSize ?? 0)
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
        for (p, r) in try paths() where p.hasPrefix(top + "/") { out[String(p.dropFirst(top.count + 1))] = (r.uid, r.gid) }
        return out
    }

    // MARK: edits

    /// Sets uid/gid (and with `mode`, the permission bits; the file type is kept) on each path's catalog
    /// record, in place. Without `mode` a record already at (uid, gid) is left alone, as build_nand.set_owner
    /// does; returns the number of records changed. Throws before writing anything if a path is missing.
    @discardableResult
    public func setOwner(_ paths: [String], uid: UInt32, gid: UInt32, mode: UInt16? = nil) throws -> Int {
        let idx = try index()
        let targets = try paths.map { p -> CatalogRecord in
            guard !p.split(separator: "/").isEmpty else { throw FirmwareError(.internal, "refusing to touch the volume root") }
            return try resolve(p, idx)
        }
        let t = try btree(catalogFork, fileID: Self.catalogID)
        var changed = 0, done = Set<UInt32>()
        for r in targets where done.insert(r.cnid).inserted {
            var patch = [UInt8](repeating: 0, count: 8)
            put32(&patch, 0, uid); put32(&patch, 4, gid)
            let at = r.node * t.nodeSize + r.bodyOffset + 32
            if let mode {
                let m = r.mode & 0o170000 | mode & 0o7777
                try write(catalogFork, fileID: Self.catalogID, offset: at, bytes: patch)
                try write(catalogFork, fileID: Self.catalogID, offset: at + 10, bytes: [UInt8(m >> 8), UInt8(m & 0xFF)])
                changed += 1
            } else if (r.uid, r.gid) != (uid, gid) {
                try write(catalogFork, fileID: Self.catalogID, offset: at, bytes: patch)
                changed += 1
            }
        }
        catalogCache = nil
        return changed
    }
}

fileprivate func be16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) << 8 | UInt16(b[o + 1]) }
fileprivate func be32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]) }
fileprivate func le32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
fileprivate func le64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(le32(b, o)) | UInt64(le32(b, o + 4)) << 32 }
fileprivate func be64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(be32(b, o)) << 32 | UInt64(be32(b, o + 4)) }
private func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
    b[o] = UInt8(v >> 24); b[o + 1] = UInt8(v >> 16 & 0xFF); b[o + 2] = UInt8(v >> 8 & 0xFF); b[o + 3] = UInt8(v & 0xFF)
}
