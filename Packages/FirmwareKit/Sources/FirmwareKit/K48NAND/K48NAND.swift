// The iPad 1 (K48AP) NAND store, written offline in the state a 7B500 restore leaves a device in after a
// power cut before the FTL context flush: special pages (BBT, NANDDRIVERSIGN), VSVFL contexts, closed
// YaFTL user/index blocks with BTOCs, no CX01 context. Port of imgtools/ipad1_nand.py (the oracle;
// its docstring and comments carry the kernel addresses each structure was checked against).
//
// Store: geometry.json + one SPARSE file per chip select (bus<b>-ce<c>.pages), a page record every
// page_bytes+spare_bytes, stored XOR 0xFF (StoreFormat.image, nand-xor-ff-v2): unwritten pages are holes, which read
// as erased. Stores made before it (legacy-zero-blank-v1) hold records as programmed; the image migration
// (K48NANDImage) converts them.
import BinaryParsing
import Foundation

public enum K48NAND {
    static let meta = 12
    /// NANDDRIVERSIGN nSig: "C11" + the epoch digit in the low byte (the FIL reads it as '0' + epoch); epoch 1 for
    /// IOFlashStorage up to 410.3 (iOS 4.3.0), 2 from 410.4 (4.3.5), see signatureEpoch(kernelcache:).
    /// flags 5, + 0x10000 (metadata whitening) where the DT asks for it; the S5L8920 boards' DTs don't, and their WMR
    /// refuses a whitened store ("Metadata whitening not supported"). Their plain stores carry flags 4: what their own FIL
    /// writes when it formats (3.1.3 N88), the only value 3.1.3 accepts (flags > 4 is "Incompatible Signature"); 4.x
    /// and 5.x take it too (as qemu-ios ipad1_nand.py --no-whitening).
    static let nsigBase: UInt32 = 0x4331_3130, sigFlags: UInt32 = 0x0001_0005, plainSigFlags: UInt32 = 0x4
    static func nsig(epoch: UInt8) -> UInt32 { nsigBase + UInt32(epoch) }
    static let tIndex: UInt8 = 0x4, tClosed: UInt8 = 0x8, tUser: UInt8 = 0x10, tVFL: UInt8 = 0x80
    static let unmapped: UInt32 = 0xFFFF_FFFF

    static let lcgTable: [UInt32] = {
        var t: [UInt32] = []
        var v: UInt32 = 0x50F4_546A
        for _ in 0..<256 {
            for _ in 0..<763 { v = 0x19660D &* v &+ 0x3C6E_F35F }
            t.append(v)
        }
        return t
    }()

    /// XOR of the three meta words with the page-indexed LCG table; bytes 10-11 stay 00 on flash.
    static func whiten(_ m: [UInt8], _ ppage: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 12)
        for i in 0..<3 {
            let w = ((try? le32(m, 4 * i)) ?? 0) ^ lcgTable[(i + ppage) % 256]
            for k in 0..<4 { out[4 * i + k] = UInt8(truncatingIfNeeded: w >> (8 * k)) }
        }
        out[10] = 0
        out[11] = 0
        return out
    }

    // MARK: - Geometry

    public struct Geometry: Sendable {
        public let name: String
        public let chipID: UInt32
        public let buses, cePerBus, blocksPerCE, pagesPerBlock, pageSize, spareBytes: Int
        public let vendorType: UInt32
        // derived exactly as the kernel does (VSVFL_Init / VSVFL_Format / YAFTL_Init)
        public let numCS, pagesPerCE, vflBanks, banksTotal, blocksPerBank, ppsublk, usable, pool: Int
        public let numBlocks, toc, tocEntries, dataPages, numIBlocks, totalPages, exportedPages: Int
        let cand: [[Int]], bbtLen: Int
        let vflBlocks = [1, 2, 3, 4], ctrlBlocks = [0, 1, 2]
        let remap: [Int: (bank: Int, slot: Int)], replacedCount: [Int]

        init(
            name: String,
            chipID: UInt32,
            buses: Int,
            cePerBus: Int,
            blocksPerCE: Int,
            pagesPerBlock: Int,
            pageSize: Int,
            spareBytes: Int,
            vendorType: UInt32 = 0x100014
        ) {
            self.name = name
            self.chipID = chipID
            self.buses = buses
            self.cePerBus = cePerBus
            self.blocksPerCE = blocksPerCE
            self.pagesPerBlock = pagesPerBlock
            self.pageSize = pageSize
            self.spareBytes = spareBytes
            self.vendorType = vendorType
            numCS = buses * cePerBus
            pagesPerCE = blocksPerCE * pagesPerBlock
            // VSVFL: two banks per CE for vendor type 0x100014, one for 0x10001 (3.0's own table for this part on 2x4 CEs)
            vflBanks = vendorType == 0x100014 ? 2 : 1
            banksTotal = numCS * vflBanks
            blocksPerBank = blocksPerCE / vflBanks
            ppsublk = pagesPerBlock * banksTotal
            let s = (Int.bitWidth - blocksPerBank.leadingZeroBitCount) - 1 - 10
            usable = s >= 0 ? 0x3D0 << s : 0x3D0 >> -s
            pool = blocksPerBank - usable
            numBlocks = usable
            toc = (4 * ppsublk + pageSize - 1) / pageSize
            tocEntries = pageSize / 4
            dataPages = ppsublk - toc
            let n = (numBlocks - 8) * dataPages
            let d = dataPages * tocEntries
            numIBlocks = 3 * ((n + d - 1) / d)
            totalPages = n - numIBlocks * ppsublk
            exportedPages = (totalPages - 1) / 100 * 99
            let top = blocksPerCE - 1
            cand = (0..<numCS).map { cs in (0..<(cs == 0 ? 5 : 2)).map { top - $0 } }
            bbtLen = (blocksPerCE + 7) / 8
            var remap: [Int: (Int, Int)] = [:]
            var slots = [Int](repeating: 0, count: vflBanks)
            for pbn in 0...vflBlocks[3] {
                let bank = pbn % vflBanks
                remap[pbn] = (bank, slots[bank])
                slots[bank] += 1
            }
            self.remap = remap
            replacedCount = slots
        }

        /// iBoot-817.29's 0xB614D5AD row: 2 buses x 4 CE x 4096 blocks x 128 pages x 4 KiB; the captured 16 GB unit.
        public static let k48With16GB = Geometry(
            name: "k48-16g",
            chipID: 0xB614_D5AD,
            buses: 2,
            cePerBus: 4,
            blocksPerCE: 0x1000,
            pagesPerBlock: 128,
            pageSize: 4096,
            spareBytes: 0x80
        )
        /// The same part as 3.0's AppleS5L8920XIOPFMI table lists it on 2x4 CEs: vendor type 0x10001, one VFL bank per CE,
        /// 1024-page superblocks whose block TOC fits one page. 3.0's yaFTL assumes one TOC page (YAFTL_Init 0xc05c74ec on
        /// N88 7A341; fixed in 3.1), so k48With16GB's 2048-page superblocks restore a garbage map there. ipad1_nand k48-16g-v1.
        public static let k48With16GBV1 = Geometry(
            name: "k48-16g-v1",
            chipID: 0xB614_D5AD,
            buses: 2,
            cePerBus: 4,
            blocksPerCE: 0x1000,
            pagesPerBlock: 128,
            pageSize: 4096,
            spareBytes: 0x80,
            vendorType: 0x10001
        )
        /// ipad1_nand.py's tiny synthetic geometry (--selfcheck): same math, 16-page blocks.
        public static let selfcheck = Geometry(
            name: "selfcheck",
            chipID: 0xB614_D5AD,
            buses: 2,
            cePerBus: 2,
            blocksPerCE: 0x1000,
            pagesPerBlock: 16,
            pageSize: 4096,
            spareBytes: 0x80
        )
        static let known = [k48With16GB, k48With16GBV1, selfcheck]

        func poolPBlock(_ bank: Int, _ slot: Int) -> Int { vflBanks * (usable + slot) + bank }
        func busCE(_ cs: Int) -> (Int, Int) { (cs / cePerBus, cs % cePerBus) }
        func ppage(_ pblock: Int, _ page: Int) -> Int { pblock * pagesPerBlock + page }
        func phys(_ cs: Int, _ pblock: Int, _ page: Int) -> Int {
            if let r = remap[pblock] { return ppage(poolPBlock(r.bank, r.slot), page) }
            return ppage(pblock, page)
        }
        /// YaFTL vpn -> (cs, physical page).
        func vpnToPhys(_ vpn: Int) -> (cs: Int, ppage: Int) {
            let (vblock, j) = vpn.quotientAndRemainder(dividingBy: ppsublk)
            let bank = j % banksTotal
            let page = j / banksTotal
            let cs = bank % numCS
            let bit = bank / numCS
            return (cs, phys(cs, vflBanks * vblock + bit, page))
        }

        /// geometry.json exactly as Python's json.dump(..., indent=1) writes it.
        var json: String {
            "{\n \"page_bytes\": \(pageSize),\n \"spare_bytes\": \(spareBytes),\n \"pages_per_block\": \(pagesPerBlock),\n"
                + " \"blocks_per_ce\": \(blocksPerCE),\n \"ce_per_bus\": \(cePerBus),\n \"buses\": \(buses),\n"
                + " \"chip_id\": \"0x\(String(format: "%08X", chipID))\""
                // only off the default, as ipad1_nand
                + (vendorType == 0x100014 ? "" : ",\n \"vendor_type\": \(vendorType)") + "\n}"
        }

        /// geometry.json for a store of `format`: an image store also names its format and FirmwareKit's layout.
        func json(_ format: StoreFormat) -> String {
            guard format == .image else { return json }
            return String(json.dropLast(2)) + ",\n \"storage_format\": \"\(format.rawValue)\""
                + ",\n \"layout\": \"\(generatedLayout)\"\n}"
        }
    }

    // MARK: - Store

    final class Store {
        let geo: Geometry, stride: Int
        var fds: [Int32] = []
        var records = 0
        var rec: [UInt8]

        /// Meta written as is (no whitening): the S5L8920 boards.
        let plain: Bool
        let format: StoreFormat

        init(create dir: URL, geo: Geometry, plain: Bool = false, format: StoreFormat = .image) throws {
            self.geo = geo
            self.plain = plain
            self.format = format
            stride = geo.pageSize + geo.spareBytes
            rec = [UInt8](repeating: 0, count: stride)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(geo.json(format).utf8).write(to: dir.appendingPathComponent("geometry.json"))
            for b in 0..<geo.buses {
                for c in 0..<geo.cePerBus {
                    let p = dir.appendingPathComponent("bus\(b)-ce\(c).pages").path
                    let fd = open(p, O_RDWR | O_CREAT | O_TRUNC, 0o644)
                    guard fd >= 0, ftruncate(fd, off_t(geo.pagesPerCE * stride)) == 0 else {
                        throw FirmwareError(.internal, "\(p): \(String(cString: strerror(errno)))")
                    }
                    fds.append(fd)
                }
            }
        }

        /// One page record: data, then the (whitened unless raw) meta, spare[12...] = 0.
        func write(_ cs: Int, _ ppage: Int, _ data: UnsafeRawBufferPointer, _ meta: [UInt8], raw: Bool = false) throws {
            precondition(data.count == geo.pageSize && meta.count == K48NAND.meta)
            // plain as whitened: bytes 10-11 never travel through the meta DMA, so 00 00 on flash (ipad1_nand.whiten)
            let m = raw ? meta : plain ? Array(meta.prefix(10)) + [0, 0] : K48NAND.whiten(meta, ppage)
            precondition(m.contains { $0 != 0 }, "spare must not be all zero (hole == blank)")
            rec.withUnsafeMutableBytes { r in
                r.copyMemory(from: data)
                for i in 0..<geo.spareBytes { r[geo.pageSize + i] = i < 12 ? m[i] : 0 }
                // Inverted a word at a time: a byte loop over each record was nine tenths of a Debug build's
                // "Writing the NAND" (100-200 s for an A4 store).
                if format == .image {
                    let words = stride / 8
                    for i in 0..<words {
                        let word = r.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)
                        r.storeBytes(of: ~word, toByteOffset: i * 8, as: UInt64.self)
                    }
                    for i in words * 8..<stride { r[i] ^= 0xFF }
                }
            }
            let (b, c) = geo.busCE(cs)
            let n = rec.withUnsafeBytes {
                pwrite(fds[b * geo.cePerBus + c], $0.baseAddress, stride, off_t(ppage * stride))
            }
            guard n == stride else {
                throw FirmwareError(.internal, "NAND store write: \(String(cString: strerror(errno)))")
            }
            records += 1
        }

        func write(_ cs: Int, _ ppage: Int, _ data: [UInt8], _ meta: [UInt8], raw: Bool = false) throws {
            try data.withUnsafeBytes { try write(cs, ppage, $0, meta, raw: raw) }
        }

        func close() {
            for fd in fds { Darwin.close(fd) }
            fds = []
        }
        deinit { close() }
    }

    // MARK: - On-flash structures

    static func spare(_ lpn: UInt32, _ usn: UInt32, _ typ: UInt8) -> [UInt8] {
        var s = [UInt8](repeating: 0, count: 12)
        put32(&s, 0, lpn)
        put32(&s, 4, usn)
        s[8] = 0
        s[9] = typ
        s[10] = 0xFF
        s[11] = 0xFF
        return s
    }

    static func specialPage(_ geo: Geometry, _ magic: String, _ hdrVer: UInt32, _ cands: [Int], _ payload: [UInt8]) -> (
        data: [UInt8], meta: [UInt8]
    ) {
        let c = (cands.map { UInt32($0) } + [UInt32](repeating: 0xFFFF_FFFF, count: 8)).prefix(8)
        var page = [UInt8](repeating: 0, count: geo.pageSize)
        for (i, ch) in magic.utf8.enumerated() { page[i] = ch }
        put32(&page, 16, hdrVer)
        for (i, v) in c.enumerated() { put32(&page, 20 + 4 * i, v) }
        put32(&page, 0x34, UInt32(payload.count))
        precondition(0x38 + payload.count <= geo.pageSize)
        page.replaceSubrange(0x38..<0x38 + payload.count, with: payload)
        return (page, [UInt8](repeating: 0xA5, count: 10) + [0, 0])
    }

    static func bbtBitmap(_ geo: Geometry, _ cs: Int) -> [UInt8] {
        var bits = [UInt8](repeating: 0xFF, count: geo.bbtLen)
        for b in Set([0] + geo.cand[cs]) where b < geo.blocksPerCE { bits[b / 8] &= ~UInt8(1 << (b % 8)) }
        return bits
    }

    static func vflContext(_ geo: Geometry, _ cs: Int) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 0x800)
        put32(&c, 0, UInt32(cs + 1))
        put32(&c, 4, 0xFFFF_FFFF)
        put32(&c, 8, 2)
        put16(&c, 12, 0)
        put16(&c, 14, 8)
        put16(&c, 0x10, 1 + geo.cand[cs].count)
        for (bank, n) in geo.replacedCount.enumerated() { put16(&c, 0x16 + 2 * bank, n) }
        var pool = [Int](repeating: 0xFFF0, count: geo.vflBanks * geo.pool)
        for pbn in Set([0] + geo.cand[cs]) where pbn >= geo.vflBanks * geo.usable {
            pool[(pbn % geo.vflBanks) * geo.pool + pbn / geo.vflBanks - geo.usable] = 0xFFFF
        }
        for (pbn, r) in geo.remap { pool[r.bank * geo.pool + r.slot] = pbn }
        for (i, v) in pool.enumerated() { put16(&c, 0x26 + 2 * i, v) }
        for (i, v) in geo.vflBlocks.enumerated() { put16(&c, 0x68e + 2 * i, v) }
        put16(&c, 0x696, geo.usable)
        put16(&c, 0x698, geo.usable)
        for (i, v) in geo.ctrlBlocks.enumerated() { put16(&c, 0x69a + 2 * i, v) }
        put32(&c, 0x6da, geo.vendorType)
        put32(&c, 0x7f4, 2)
        return vflChecksum(c)
    }

    /// The VFL context `c0` (0x800 bytes: its writers' own, the check's page prefix) with its keyed word sum and xor at
    /// 0x7F8.
    static func vflChecksum(_ c0: [UInt8]) -> [UInt8] {
        var c = c0
        var sum: UInt32 = 0
        var x: UInt32 = 0
        for i in 0..<(0x7f8 / 4) {
            let w = (try? le32(c, 4 * i)) ?? 0
            sum &+= w
            x ^= w
        }
        put32(&c, 0x7f8, sum &+ 0xAABB_CCDD)
        put32(&c, 0x7fc, x ^ 0xAABB_CCDD)
        return c
    }

    static func writeMetadata(
        _ st: Store,
        _ geo: Geometry,
        kernelVersion: [UInt8],
        epoch: UInt8,
        sigFlags flags: UInt32? = nil
    ) throws {
        for cs in 0..<geo.numCS {
            let pg = specialPage(geo, "DEVICEINFOBBT", 4, geo.cand[cs], bbtBitmap(geo, cs))
            for blk in geo.cand[cs].prefix(2) {
                for p in 0..<geo.pagesPerBlock { try st.write(cs, geo.ppage(blk, p), pg.data, pg.meta, raw: true) }
            }
            var ctx = vflContext(geo, cs)
            ctx += [UInt8](repeating: 0, count: geo.pageSize - ctx.count)
            let m: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x80, 0xFF, 0xFF]
            for p in 0..<8 { try st.write(cs, geo.ppage(geo.vflBlocks[0], p), ctx, m) }
        }
        var payload = [UInt8](repeating: 0, count: 8 + 0x100)
        put32(&payload, 0, nsig(epoch: epoch))
        put32(&payload, 4, flags ?? (st.plain ? plainSigFlags : sigFlags))
        payload.replaceSubrange(8..<8 + kernelVersion.count, with: kernelVersion)
        let sig = specialPage(geo, "NANDDRIVERSIGN", 0, [Int](repeating: 0, count: 8), payload)
        for p in 0..<geo.pagesPerBlock { try st.write(0, geo.ppage(geo.cand[0][4], p), sig.data, sig.meta, raw: true) }
    }

    /// Lays out user pages (then index pages) into consecutive YaFTL vblocks.
    final class FTLWriter {
        let st: Store, geo: Geometry
        var vblock = 3, j = 0, usn: UInt32 = 1
        var btoc: [UInt32] = []
        var toc: [Int: [UInt32]] = [:]
        init(_ st: Store, _ geo: Geometry) {
            self.st = st
            self.geo = geo
        }

        func put(_ lpn: UInt32, _ data: UnsafeRawBufferPointer, _ typ: UInt8) throws -> Int {
            if j == 0 {
                guard vblock < geo.numBlocks else {
                    throw FirmwareError(.unsupported, "image does not fit: needs more than \(geo.numBlocks) vblocks")
                }
                btoc = []
            }
            let vpn = vblock * geo.ppsublk + j
            let (cs, pp) = geo.vpnToPhys(vpn)
            try st.write(cs, pp, data, spare(lpn, usn, typ))
            btoc.append(lpn)
            j += 1
            if j == geo.dataPages { try closeBlock(typ) }
            return vpn
        }

        func closeBlock(_ typ: UInt8) throws {
            var table = [UInt8](repeating: 0xFF, count: geo.toc * geo.pageSize)
            for (i, l) in btoc.enumerated() { put32(&table, 4 * i, l) }
            for i in 0..<geo.toc {
                let (cs, pp) = geo.vpnToPhys(vblock * geo.ppsublk + j + i)
                try st.write(
                    cs,
                    pp,
                    Array(table[i * geo.pageSize..<(i + 1) * geo.pageSize]),
                    spare(unmapped, usn, tClosed | (typ == tIndex ? tIndex : 0))
                )
            }
            vblock += 1
            usn += 1
            j = 0
        }

        func nextBlock() {
            if j != 0 {
                vblock += 1
                usn += 1
                j = 0
            }
        }

        func user(_ lpn: Int, _ data: UnsafeRawBufferPointer) throws {
            let vpn = try put(UInt32(lpn), data, tUser)
            let (t, i) = lpn.quotientAndRemainder(dividingBy: geo.tocEntries)
            toc[t, default: [UInt32](repeating: unmapped, count: geo.tocEntries)][i] = UInt32(vpn)
        }

        func indexPages() throws {
            nextBlock()
            for (t, entries) in toc.sorted(by: { $0.key < $1.key }) {
                try entries.withUnsafeBytes { _ = try put(UInt32(t), $0, tIndex) }
            }
            nextBlock()
        }
    }

    // MARK: - Inputs

    /// The logical disk's head as a 7B500 restore leaves it on a K48, up to partition 1 (LBA 63): p1 Apple_HFS
    /// system at 63, p3 an 8-sector 0xAF stub one sector past its end, p2 0xAE data to 45 sectors before the
    /// exported end (make_mbr; the gaps are measured on one 16 GB unit).
    public static func makeMBR(geometry geo: Geometry = .k48With16GB, systemMiB: Int = 1280) -> Data {
        let ps = geo.pageSize
        let n = systemMiB * (1 << 20) / ps
        var head = [UInt8](repeating: 0, count: 63 * ps)
        let p3 = 63 + n + 1
        for (i, (typ, lba, cnt)) in [(0xAF, 63, n), (0xAE, p3 + 45, geo.exportedPages - (p3 + 45) - 45), (0xAF, p3, 8)]
            .enumerated()
        {
            let o = 0x1be + 16 * i
            let chs: [UInt8] = lba == 63 ? [0x01, 0x01, 0x00] : [0xFE, 0xFF, 0xFF]
            head.replaceSubrange(o..<o + 8, with: [0] + chs + [UInt8(typ), 0xFE, 0xFF, 0xFF])
            put32(&head, o + 8, UInt32(lba))
            put32(&head, o + 12, UInt32(cnt))
        }
        head[510] = 0x55
        head[511] = 0xAA
        return Data(head)
    }

    public struct Partition: Equatable, Sendable {
        public let type: UInt8
        public let lba: Int
        public let count: Int
    }

    /// The MBR's four entries at 0x1BE: status, CHS start, type, CHS end, then the first LBA and the count
    /// (little-endian u32s).
    public static func partitions(mbr: [UInt8]) throws -> [Partition] {
        try parsing(mbr, "MBR") { s in
            try s.seek(toAbsoluteOffset: 0x1BE)
            return try [Partition](parsing: &s, count: 4) { e in
                try e.seek(toRelativeOffset: 4)
                let type = try UInt8(parsing: &e)
                try e.seek(toRelativeOffset: 3)
                return Partition(
                    type: type,
                    lba: try Int(parsing: &e, storedAsLittleEndian: UInt32.self),
                    count: try Int(parsing: &e, storedAsLittleEndian: UInt32.self)
                )
            }
        }
    }

    /// The "Darwin Kernel Version ..." string (up to 0xff bytes) out of a decrypted kernelcache.
    public static func kernelVersion(kernelcache: URL) throws -> [UInt8] {
        let d = try Data(contentsOf: kernelcache, options: .alwaysMapped)
        guard let r = d.range(of: Data("Darwin Kernel Version ".utf8)) else {
            throw FirmwareError(.unsupported, "\(kernelcache.path): no Darwin Kernel Version string")
        }
        let end = d[r.lowerBound...].firstIndex(of: 0) ?? d.endIndex
        return Array(d[r.lowerBound..<end].prefix(0xff))
    }

    /// The NAND-signature epoch this kernel's FIL wants (nSig's low byte, '0' + epoch). IOFlashStorage-410.4 (4.3.5)
    /// wants 2 and parks a '1' store in "AppleNANDLegacyFTL: epoch roll wait" until a restore rolls it; 410.3
    /// (4.3.0) and earlier have no such getter and take '1'. Read off the getter's own shape in the FIL,
    /// `ldr rN, [pc, #imm]; blx rN; adds r0, #0x30; uxtb r0, r0; pop {r7, pc}` (r3 on 4.3.5, r0 on the 5.0 betas),
    /// whose literal names `movs r0, #N; bx lr` (8F190 -> 1, 8L1 -> 2, 9A5288d -> 2; 5.0 GM on have no such getter
    /// and take 1).
    public static func signatureEpoch(kernelcache: URL) throws -> UInt8 {
        let d = try Data(contentsOf: kernelcache, options: .alwaysMapped)
        let m = try MachO(d)
        let shape = Data([0x30, 0x30, 0xC0, 0xB2, 0x80, 0xBD])
        var from = 0
        while let r = d.range(of: shape, in: from..<d.count) {
            let i = r.lowerBound
            from = i + 1
            // ldr rN, [pc, #imm] (0x48 | N); blx rN (0x47, 0x80 | N << 3), N a low register
            guard i >= 4, d[i - 3] & 0xF8 == 0x48, d[i - 2] == 0x80 | (d[i - 3] & 7) << 3, d[i - 1] == 0x47 else {
                continue
            }
            let pool = ((i - 4) & ~3) + 4 + Int(d[i - 4]) * 4
            guard pool + 4 <= d.count else { continue }
            let target = try MachO.u32(d, pool) & ~1
            guard let seg = m.segments.first(where: { $0.vmaddr <= target && target - $0.vmaddr < $0.vmsize }) else {
                continue
            }
            let o = Int(seg.fileoff) + Int(target - seg.vmaddr)
            guard o + 2 <= d.count, d[o + 1] == 0x20 else { continue }  // movs r0, #N
            return d[o]
        }
        return 1
    }

    /// Restore.plist's DeviceMap SCEP for `board` (the NAND epoch a restore would write), nil when it names none.
    static func restoreEpoch(_ ipsw: IPSWArchive, board: String) throws -> UInt8? {
        let rp =
            try PropertyListSerialization.propertyList(from: try ipsw.read("Restore.plist"), format: nil)
            as? [String: Any]
        let maps = rp?["DeviceMap"] as? [[String: Any]] ?? []
        let map = maps.first { ($0["BoardConfig"] as? String)?.lowercased() == board.lowercased() } ?? maps.first
        return (map?["SCEP"] as? NSNumber).map { UInt8(truncatingIfNeeded: $0.intValue) }
    }

    /// A page-granular reader over a (possibly sparse) raw image, with in-place byte patches.
    final class FilePages {
        let fd: Int32, size: Int, page: Int, pages: Int
        let patch: [Int: [(Int, [UInt8])]]
        var buf: [UInt8]
        init(_ url: URL, page: Int, patch: [Int: [(Int, [UInt8])]] = [:]) throws {
            fd = open(url.path, O_RDONLY)
            guard fd >= 0 else { throw FirmwareError(.internal, "\(url.path): \(String(cString: strerror(errno)))") }
            var st = stat()
            fstat(fd, &st)
            size = Int(st.st_size)
            self.page = page
            self.patch = patch
            pages = (size + page - 1) / page
            buf = [UInt8](repeating: 0, count: page)
        }
        deinit { close(fd) }

        /// Page numbers inside the file's data extents (SEEK_DATA/SEEK_HOLE), in order, as FilePages.written().
        func written() -> [Int] {
            K48NANDImage.dataExtents(fd).flatMap {
                Int($0.lowerBound) / page..<(Int($0.upperBound) + page - 1) / page
            }
        }

        func get<R>(_ n: Int, _ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
            try buf.withUnsafeMutableBytes { b in
                let got = pread(fd, b.baseAddress, page, off_t(n * page))
                guard got >= 0 else { throw FirmwareError(.internal, "read: \(String(cString: strerror(errno)))") }
                if got < page, let start = b.baseAddress { memset(start + got, 0, page - got) }
                for (o, new) in patch[n] ?? [] { for (k, v) in new.enumerated() { b[o + k] = v } }
            }
            return try buf.withUnsafeBytes(body)
        }
    }

    /// In-place, same-length /dev/disk0s2s1 -> /dev/disk0s2 rewrite of every etc/fstab copy on the volume.
    static func fstabPatch(_ system: URL, page: Int) throws -> [Int: [(Int, [UInt8])]] {
        let old = Data("/dev/disk0s2s1 /private/var".utf8)
        let new = Array("/dev/disk0s2   /private/var".utf8)
        let d = try Data(contentsOf: system, options: .alwaysMapped)
        var patch: [Int: [(Int, [UInt8])]] = [:]
        d.withUnsafeBytes { b in
            guard let base = b.baseAddress else { return }
            var off = 0
            while off < b.count,
                let hit = old.withUnsafeBytes({ memmem(base + off, b.count - off, $0.baseAddress, old.count) })
            {
                let at = base.distance(to: UnsafeRawPointer(hit))
                let (pg, o) = at.quotientAndRemainder(dividingBy: page)
                precondition(o + new.count <= page)
                patch[pg, default: []].append((o, new))
                off = at + 1
            }
        }
        return patch
    }

    /// A bare case-sensitive journaled HFS+ volume (like iOS's data partition) in a sparse raw file.
    nonisolated(nonsending) public static func makeHFSImage(at url: URL, size: Int64) async throws {
        try await VolumeMount.makeHFS(url, size: size)
    }

    // MARK: - Build

    public enum DataVolume: Sendable {
        case none
        case image(URL)
        /// A fresh HFS+ volume of this many bytes (sparse), made with makeHFSImage.
        case size(Int64)
    }

    public struct BuildResult: Sendable {
        public let records: Int, vblocksUsed: Int, tocPages: Int
    }

    /// ipad1_nand.py build: the store for `system` (+ `s3` + the data volume) at the MBR's partitions, into `out`.
    @discardableResult
    nonisolated(nonsending) public static func build(
        geometry geo: Geometry = .k48With16GB,
        mbr: URL,
        kernelVersion: [UInt8],
        epoch: UInt8 = 1,
        system: URL,
        s3: URL? = nil,
        data: DataVolume,
        out: URL,
        force: Bool = false,
        whitening: Bool = true,
        sigFlags: UInt32? = nil,
        format: StoreFormat = .image,
        log: (String) -> Void = { _ in }
    ) async throws -> BuildResult {
        let fm = FileManager.default
        if fm.fileExists(atPath: out.appendingPathComponent("geometry.json").path) && !force {
            throw FirmwareError(.internal, "\(out.path) exists; pass force to overwrite")
        }
        if force, let names = try? fm.contentsOfDirectory(atPath: out.path) {
            for n in names where n == "geometry.json" || n.hasSuffix(".pages") {
                try fm.removeItem(at: out.appendingPathComponent(n))
            }
        }
        let ps = geo.pageSize
        guard ps == 4096 else {
            throw FirmwareError(
                .unsupported,
                "\(geo.name) has \(ps)-byte pages; the device MBR/partitions are 4 KiB-sectored"
            )
        }
        var head = [UInt8](try Data(contentsOf: mbr))
        guard head.count >= 512, head[510] == 0x55, head[511] == 0xAA else {
            throw FirmwareError(.unsupported, "\(mbr.path): no MBR signature")
        }
        let parts = try partitions(mbr: head)
        let p1 = parts[0]
        let p3 = parts[2]
        var p2 = parts[1]
        let sys = try FilePages(
            system,
            page: ps,
            patch: {
                if case .none = data { return [:] }
                return try fstabPatch(system, page: ps)
            }()
        )
        if sys.pages != p1.count { log("warning: system image is \(sys.pages) pages, partition 1 is \(p1.count)") }

        var work: URL?
        defer { if let w = work { try? fm.removeItem(at: w) } }
        var dataPages: FilePages?
        switch data {
        case .none: break
        case .image(let u): dataPages = try FilePages(u, page: ps)
        case .size(let n):
            let w = fm.temporaryDirectory.appendingPathComponent("k48nand.\(UUID().uuidString)")
            work = w
            try fm.createDirectory(at: w, withIntermediateDirectories: true)
            let u = w.appendingPathComponent("data.dmg")
            log("creating \(n)-byte HFS+ data volume")
            try await makeHFSImage(at: u, size: n)
            dataPages = try FilePages(u, page: ps)
        }
        if let d = dataPages {
            // EncryptedMediaFilter refuses an 0xAE partition without a key block: plain Apple_HFS at /dev/disk0s2
            head[0x1be + 16 + 4] = 0xAF
            put32(&head, 0x1be + 16 + 12, UInt32(d.pages))
            p2 = Partition(type: 0xAF, lba: p2.lba, count: d.pages)
        }
        guard p2.lba + p2.count <= geo.exportedPages else {
            throw FirmwareError(
                .unsupported,
                "partition 2 ends at \(p2.lba + p2.count) > exported \(geo.exportedPages) sectors"
            )
        }

        let st = try Store(create: out, geo: geo, plain: !whitening, format: format)
        try writeMetadata(st, geo, kernelVersion: kernelVersion, epoch: epoch, sigFlags: sigFlags)
        let ftl = FTLWriter(st, geo)
        // LPN == 4 KiB LBA, segments in ascending LBA order
        for n in 0..<min(p1.lba, head.count / ps) {
            try head.withUnsafeBytes { try ftl.user(n, UnsafeRawBufferPointer(rebasing: $0[n * ps..<(n + 1) * ps])) }
        }
        for n in 0..<sys.pages { try sys.get(n) { try ftl.user(p1.lba + n, $0) } }
        if let s3, p3.count > 0 {
            let f = try FilePages(s3, page: ps)
            for n in 0..<min(p3.count, f.pages) { try f.get(n) { try ftl.user(p3.lba + n, $0) } }
        }
        if let d = dataPages {
            let w = d.written()
            log("data partition: \(d.pages) pages, \(w.count) written (the rest are holes)")
            for n in w { try d.get(n) { try ftl.user(p2.lba + n, $0) } }
        }
        try ftl.indexPages()
        st.close()
        log(
            "wrote \(out.path): \(st.records) pages, \(ftl.vblock) user/index vblocks used of \(geo.numBlocks), \(ftl.toc.count) TOC pages"
        )
        return BuildResult(records: st.records, vblocksUsed: ftl.vblock, tocPages: ftl.toc.count)
    }

    /// A stopped edit's store: `system` and `data` laid out fresh into `out` as `build` lays out a prepared store,
    /// with the MBR, the third partition and the signature (epoch, flags, kernel version, whitening) that `store`
    /// plus `overlay` hold now. Whatever YaFTL state the guest left goes; the device restores its map on boot as it
    /// does from a prepared store. `work` keeps the MBR and third partition read back.
    nonisolated(nonsending) static func rebuild(
        store: URL,
        overlay: URL?,
        system: URL,
        data: URL?,
        out: URL,
        work: URL,
        log: (String) -> Void = { _ in }
    ) async throws {
        let geo = try geometry(store: store)
        let st = try StoreReader(store, geo: geo, overlay: overlay)
        guard let sig = st.signature() else { throw FirmwareError(.unsupported, "\(store.path): no NAND signature") }
        let map = VolumeRebuild.yaftlMap(st)
        func page(_ lpn: Int) -> [UInt8] {
            guard lpn < map.count, map[lpn] != 0, let d = st.readVPN(Int(map[lpn] - 1))?.data else {
                return [UInt8](repeating: 0, count: geo.pageSize)
            }
            return d
        }
        let parts = try partitions(mbr: page(0))
        // the guest's MBR says where its partitions are: the pages read back for them must be exported ones
        guard parts[0].lba <= geo.exportedPages, parts[2].lba + parts[2].count <= geo.exportedPages else {
            throw FirmwareError(.unsupported, "\(store.path): the MBR's partitions run past the exported pages")
        }
        let mbr = work.appendingPathComponent("mbr.bin")
        try Data((0..<parts[0].lba).flatMap(page)).write(to: mbr)
        var s3: URL?
        if parts[2].type != 0, parts[2].count > 0 {
            let url = work.appendingPathComponent("s3.img")
            try Data((parts[2].lba..<parts[2].lba + parts[2].count).flatMap(page)).write(to: url)
            s3 = url
        }
        try await build(
            geometry: geo,
            mbr: mbr,
            kernelVersion: sig.kernelVersion,
            epoch: sig.epoch,
            system: system,
            s3: s3,
            data: data.map { .image($0) } ?? .none,
            out: out,
            whitening: !st.plain,
            sigFlags: sig.flags,
            log: log
        )
    }
}
