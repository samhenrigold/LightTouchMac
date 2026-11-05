// A legacy store (StoreFormat.legacy) and its NAND overlay as image stores (StoreFormat.image), and the page-exact
// proof that they read the same: the conversion half of the format 2 migration (K48NANDMigration).
//
// The guest's view is the IOP's (s5l8930_iop.c nand_read_page): a legacy record is served from the overlay when its
// .dirty bit is set, else from the base, and an all-zero record (a hole, or zeros the guest programmed) reads as the
// erased page, all 0xFF; an image record is stored XOR 0xFF. So a legacy record goes over as a hole when it is all
// zero, else as itself XOR 0xFF, and every page reads back as the guest read it before, the legacy format's
// zero-reads-blank included. Overlay pages written after the bitmap's last publication (a helper killed before
// a stop) are carried as the IOP read them, from the base: migration keeps the guest's view, it doesn't guess.

import Darwin
import Foundation

enum K48NANDImage {
    /// One chip select's file name in a store or overlay.
    static func name(_ i: Int, _ geo: K48NAND.Geometry, _ ext: String) -> String {
        "bus\(i / geo.cePerBus)-ce\(i % geo.cePerBus).\(ext)"
    }

    /// The overlay's chip files, its bitmaps and format marker: what goes when a device leaves the legacy format.
    static func overlayFiles(_ overlay: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: overlay.path)) ?? []).filter {
            $0.hasSuffix(".pages") || $0.hasSuffix(".dirty") || $0 == "storage-format"
        }.sorted()
    }

    /// Whether `overlay` serves any page: some chip has a bitmap. Without one the IOP reads the base alone.
    static func overlayServes(_ overlay: URL?, _ geo: K48NAND.Geometry) -> Bool {
        guard let overlay else { return false }
        return (0..<geo.numCS).contains {
            FileManager.default.fileExists(atPath: overlay.appendingPathComponent(name($0, geo, "dirty")).path)
        }
    }

    /// One chip select open for conversion or proof: the legacy base, the overlay and its bitmap as the IOP opens them.
    struct Chip {
        let base: Int32
        let overlay: Int32?
        let dirty: [UInt8]
        let size: Int

        init(base: URL, overlay: URL?, index i: Int, geo: K48NAND.Geometry) throws {
            let stride = geo.pageSize + geo.spareBytes
            size = geo.pagesPerCE * stride
            self.base = try K48NANDImage.open(base.appendingPathComponent(name(i, geo, "pages")), size: size)
            if let overlay,
                FileManager.default.fileExists(atPath: overlay.appendingPathComponent(name(i, geo, "dirty")).path)
            {
                let pages = overlay.appendingPathComponent(name(i, geo, "pages"))
                // The IOP creates an absent or empty chip file at its size, so it serves holes.
                self.overlay = try K48NANDImage.open(pages, size: size, emptyIsHoles: true)
                let bitmap = try Data(contentsOf: overlay.appendingPathComponent(name(i, geo, "dirty")))
                guard bitmap.isEmpty || bitmap.count == (geo.pagesPerCE + 7) / 8 else {
                    throw FirmwareError(.unsupported, "\(overlay.path): invalid dirty bitmap size for NAND geometry")
                }
                dirty = bitmap.isEmpty ? [UInt8](repeating: 0, count: (geo.pagesPerCE + 7) / 8) : [UInt8](bitmap)
            } else {
                self.overlay = nil
                dirty = []
            }
        }

        func owned(_ page: Int) -> Bool { !dirty.isEmpty && dirty[page / 8] >> (page % 8) & 1 != 0 }

        func close() {
            Darwin.close(base)
            if let overlay, overlay >= 0 { Darwin.close(overlay) }
        }
    }

    /// Read-only; -1 for an absent or empty file when `emptyIsHoles` (it reads as holes).
    static func open(_ url: URL, size: Int, emptyIsHoles: Bool = false) throws -> Int32 {
        var st = stat()
        if emptyIsHoles, stat(url.path, &st) != 0 || st.st_size == 0 { return -1 }
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0, fstat(fd, &st) == 0 else {
            if fd >= 0 { Darwin.close(fd) }
            throw FirmwareError(.internal, "\(url.path): \(String(cString: strerror(errno)))")
        }
        guard Int(st.st_size) == size else {
            Darwin.close(fd)
            throw FirmwareError(.unsupported, "\(url.path): NAND file size differs from geometry")
        }
        return fd
    }

    /// The byte ranges of `fd` holding data (SEEK_DATA/SEEK_HOLE). Only ENXIO means nothing is left: a volume that
    /// can't answer (ENOTSUP) or any other failure leaves the rest counted as data, since skipping it loses it.
    static func dataExtents(_ fd: Int32, seek: (Int32, off_t, Int32) -> off_t = lseek) -> [Range<off_t>] {
        var extents: [Range<off_t>] = []
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0 else { return extents }
        var offset: off_t = 0
        while offset < info.st_size {
            let start = seek(fd, offset, SEEK_DATA)
            if start < 0, errno == ENXIO { break }
            guard start >= 0 else {
                extents.append(offset..<info.st_size)
                break
            }
            let end = seek(fd, start, SEEK_HOLE)
            guard end > start else {
                extents.append(start..<info.st_size)
                break
            }
            extents.append(start..<end)
            offset = end
        }
        return extents
    }

    /// The erase blocks of `fd` holding data; APFS zero-fills holes under 16 MiB, so these include zeros, which read
    /// as erased in either format.
    static func dataBlocks(_ fd: Int32, blockBytes: Int) -> Set<Int> {
        var blocks = Set<Int>()
        for extent in dataExtents(fd) {
            blocks.formUnion(Int(extent.lowerBound) / blockBytes...(Int(extent.upperBound) - 1) / blockBytes)
        }
        return blocks
    }

    static func read(_ fd: Int32, _ buffer: inout [UInt8], at offset: Int) throws {
        guard fd >= 0 else {
            for i in buffer.indices { buffer[i] = 0 }
            return
        }
        let count = buffer.count
        let got = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        guard got == count else { throw FirmwareError(.internal, "NAND read: \(String(cString: strerror(errno)))") }
    }

    /// Syncs `fd`, then punches every all-zero 4 KiB page of its data, which reads the same as a hole (the blank page
    /// under every image store's XOR encoding), and syncs again. APFS fills a gap under 16 MiB around a write with
    /// allocated zeros at write-back, so a store written in scattered records holds far more than its records (a
    /// migrated M68's live NAND, 3.9 GB for 1 GB of pages); punching gives that back at 4 KiB granularity. The
    /// emulator's later writes fill again around themselves only. Returns the bytes punched.
    @discardableResult
    static func compact(_ fd: Int32, path: String) throws -> Int {
        let page = 4096
        let chunk = 1 << 20
        var buffer = [UInt8](repeating: 0, count: chunk)
        let zero = [UInt8](repeating: 0, count: page)
        var punched = 0
        func fail() -> FirmwareError {
            FirmwareError(.internal, "compact \(path): \(String(cString: strerror(errno)))")
        }
        func punch(_ from: Int, _ to: Int) throws {
            var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(from), fp_length: off_t(to - from))
            guard fcntl(fd, F_PUNCHHOLE, &hole) == 0 else { throw fail() }
            punched += to - from
        }
        guard fsync(fd) == 0 else { throw fail() }  // the fill happens at write-back
        var offset: off_t = 0
        while true {
            let start = lseek(fd, offset, SEEK_DATA)
            guard start >= 0 else { break }
            let end = lseek(fd, start, SEEK_HOLE)
            guard end > start else { break }
            var at = (Int(start) + page - 1) & ~(page - 1)
            let limit = Int(end) & ~(page - 1)
            var run: Int?  // where the current run of zero pages starts
            while at < limit {
                let n = min(chunk, limit - at)
                let got = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, n, off_t(at)) }
                guard got == n else { throw fail() }
                for p in Swift.stride(from: 0, to: n, by: page) {
                    let blank = same(buffer, p, zero, 0, page)
                    if blank, run == nil { run = at + p }
                    if !blank, let from = run {
                        try punch(from, at + p)
                        run = nil
                    }
                }
                at += n
            }
            if let from = run { try punch(from, limit) }
            offset = end
        }
        guard fsync(fd) == 0 else { throw fail() }
        return punched
    }

    static func write(_ fd: Int32, _ bytes: ArraySlice<UInt8>, at offset: Int) throws {
        let n = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, off_t(offset)) }
        guard n == bytes.count else {
            throw FirmwareError(
                errno == ENOSPC ? .diskFull : .internal,
                "NAND write: \(String(cString: strerror(errno)))"
            )
        }
    }

    /// `buffer` XOR 0xFF, a word at a time (records and blocks are multiples of 8 bytes).
    static func invert(_ buffer: inout [UInt8]) {
        buffer.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            for i in words.indices { words[i] = ~words[i] }
        }
    }

    /// `count` bytes of `a` at `o` equal `b`'s at `p`.
    static func same(_ a: [UInt8], _ o: Int, _ b: [UInt8], _ p: Int, _ count: Int) -> Bool {
        a.withUnsafeBytes { x in
            b.withUnsafeBytes { y in
                guard let x = x.baseAddress, let y = y.baseAddress else { return count == 0 }
                return memcmp(x + o, y + p, count) == 0
            }
        }
    }

    /// The legacy records of `legacy` as image records into `image` (`legacy` inverted by the caller): an all-zero
    /// record, erased to the IOP, becomes a hole.
    static func encode(_ legacy: [UInt8], into image: inout [UInt8], records: Int, stride: Int, zeros: [UInt8]) {
        for r in 0..<records where same(legacy, r * stride, zeros, 0, stride) {
            image.replaceSubrange(r * stride..<(r + 1) * stride, with: zeros[..<stride])
        }
    }

    /// The image record at `o` (already inverted) reads as the legacy one: erased where the legacy record is all zero.
    static func reads(_ image: [UInt8], as legacy: [UInt8], at o: Int, stride: Int, zeros: [UInt8], erased: [UInt8])
        -> Bool
    {
        same(legacy, o, zeros, 0, stride) ? same(image, o, erased, 0, stride) : same(image, o, legacy, o, stride)
    }

    /// `base` (a legacy store) and `overlay` as image stores: `baseOut`, the base alone, and `liveOut` (when the
    /// overlay serves pages), a clone of `baseOut` with every owned overlay record applied, as the IOP reads them.
    static func convert(base: URL, overlay: URL?, baseOut: URL, liveOut: URL?, step: () -> Void = {}) throws {
        let geo = try K48NAND.geometry(store: base)
        guard try K48NAND.storeFormat(base) == .legacy else {
            throw FirmwareError(.unsupported, "\(base.path): not a legacy NAND store")
        }
        let stride = geo.pageSize + geo.spareBytes
        let blockBytes = geo.pagesPerBlock * stride
        let fm = FileManager.default
        try fm.createDirectory(at: baseOut, withIntermediateDirectories: false)
        try Data(geo.json(.image).utf8).write(to: baseOut.appendingPathComponent("geometry.json"))
        let zeros = [UInt8](repeating: 0, count: blockBytes)
        var buffer = zeros
        for i in 0..<geo.numCS {
            defer { step() }  // a chip select done: the migration's progress
            let chip = try Chip(base: base, overlay: nil, index: i, geo: geo)
            defer { chip.close() }
            let path = baseOut.appendingPathComponent(name(i, geo, "pages")).path
            let fd = Darwin.open(path, O_RDWR | O_CREAT | O_EXCL, 0o644)
            guard fd >= 0, ftruncate(fd, off_t(chip.size)) == 0 else {
                throw FirmwareError(.internal, "\(path): \(String(cString: strerror(errno)))")
            }
            defer { Darwin.close(fd) }
            for block in dataBlocks(chip.base, blockBytes: blockBytes).sorted() {
                try read(chip.base, &buffer, at: block * blockBytes)
                var out = buffer
                invert(&out)
                encode(buffer, into: &out, records: geo.pagesPerBlock, stride: stride, zeros: zeros)
                // ponytail: a block with any record is written whole (zeros for its erased records); sparse per block.
                if !same(out, 0, zeros, 0, blockBytes) { try write(fd, out[...], at: block * blockBytes) }
            }
            try compact(fd, path: path)
        }
        guard let liveOut, overlayServes(overlay, geo) else { return }
        // file by file (clonefile(2) discourages directories); baseOut isn't locked yet, so the clones are writable
        try fm.createDirectory(at: liveOut, withIntermediateDirectories: false)
        for file in try fm.contentsOfDirectory(atPath: baseOut.path) {
            let source = baseOut.appendingPathComponent(file)
            guard clonefile(source.path, liveOut.appendingPathComponent(file).path, 0) == 0 else {
                throw FirmwareError(.internal, "clone \(source.path): \(String(cString: strerror(errno)))")
            }
        }
        var record = [UInt8](repeating: 0, count: stride)
        for i in 0..<geo.numCS {
            defer { step() }  // a chip select done: the migration's progress
            let chip = try Chip(base: base, overlay: overlay, index: i, geo: geo)
            defer { chip.close() }
            guard let source = chip.overlay else { continue }
            let path = liveOut.appendingPathComponent(name(i, geo, "pages")).path
            let fd = Darwin.open(path, O_RDWR)
            guard fd >= 0 else { throw FirmwareError(.internal, "\(path): \(String(cString: strerror(errno)))") }
            defer { Darwin.close(fd) }
            for page in 0..<geo.pagesPerCE where chip.owned(page) {
                try read(source, &record, at: page * stride)
                var out = record
                invert(&out)
                encode(record, into: &out, records: 1, stride: stride, zeros: zeros)
                try write(fd, out[...], at: page * stride)
            }
            try compact(fd, path: path)
        }
    }

    /// Every page of every chip select of `baseOut` reads as `base` alone did, and of `liveOut` as `base` under
    /// `overlay` did, byte for byte (data and spare), as the IOP serves them; pages in no file's data read erased in
    /// all of them. Independent of `convert`: it reads both formats back.
    static func verify(base: URL, overlay: URL?, baseOut: URL, liveOut: URL?, step: () -> Void = {}) throws {
        let geo = try K48NAND.geometry(store: base)
        guard try K48NAND.storeFormat(baseOut) == .image, try K48NAND.geometry(store: baseOut).json == geo.json else {
            throw FirmwareError(.internal, "\(baseOut.path): not an image store of \(base.path)'s geometry")
        }
        let serves = overlayServes(overlay, geo)
        guard (liveOut != nil) == serves else {
            throw FirmwareError(.internal, "the live NAND must exist exactly when the overlay serves pages")
        }
        let stride = geo.pageSize + geo.spareBytes
        let blockBytes = geo.pagesPerBlock * stride
        let erased = [UInt8](repeating: 0xFF, count: stride)
        let zeros = [UInt8](repeating: 0, count: stride)
        var legacyBase = [UInt8](repeating: 0, count: blockBytes)
        var legacyOverlay = legacyBase
        var imageBase = legacyBase
        var imageLive = legacyBase
        for i in 0..<geo.numCS {
            defer { step() }  // a chip select done: the migration's progress
            let chip = try Chip(base: base, overlay: serves ? overlay : nil, index: i, geo: geo)
            defer { chip.close() }
            let newBase = try open(baseOut.appendingPathComponent(name(i, geo, "pages")), size: chip.size)
            defer { Darwin.close(newBase) }
            let newLive = try liveOut.map {
                try open($0.appendingPathComponent(name(i, geo, "pages")), size: chip.size)
            }
            defer { if let newLive { Darwin.close(newLive) } }
            var blocks = dataBlocks(chip.base, blockBytes: blockBytes).union(
                dataBlocks(newBase, blockBytes: blockBytes)
            )
            if let newLive { blocks.formUnion(dataBlocks(newLive, blockBytes: blockBytes)) }
            for page in 0..<geo.pagesPerCE where chip.owned(page) { blocks.insert(page / geo.pagesPerBlock) }
            for block in blocks.sorted() {
                let at = block * blockBytes
                try read(chip.base, &legacyBase, at: at)
                try read(newBase, &imageBase, at: at)
                invert(&imageBase)
                if let source = chip.overlay { try read(source, &legacyOverlay, at: at) }
                if let newLive {
                    try read(newLive, &imageLive, at: at)
                    invert(&imageLive)
                }
                for p in 0..<geo.pagesPerBlock {
                    let page = block * geo.pagesPerBlock + p
                    let o = p * stride
                    guard reads(imageBase, as: legacyBase, at: o, stride: stride, zeros: zeros, erased: erased) else {
                        throw FirmwareError(.internal, "\(name(i, geo, "pages")) page \(page): the base image differs")
                    }
                    guard newLive != nil else { continue }
                    let guest = chip.owned(page) ? legacyOverlay : legacyBase
                    guard reads(imageLive, as: guest, at: o, stride: stride, zeros: zeros, erased: erased) else {
                        throw FirmwareError(.internal, "\(name(i, geo, "pages")) page \(page): the live image differs")
                    }
                }
            }
        }
    }
}
