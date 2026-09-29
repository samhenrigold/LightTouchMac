// N45NAND: the iPod touch 1G page directory (bank{0..7}/<page>.page, 2048 data + 64 spare bytes each) that
// qemu-ios s5l8900_fmc.c serves: the legacy VFL/FTL layout of devos50's qemu-ios-generate-nand (main, the 1G
// generate_nand.c: FIL id, DEVICEINFOBBT, VFL context at block 35, the FTL from physical block 201 on, one HFS+
// partition behind an MBR + GPT), with two things that tool left for later:
//
// - Real spares. Every page carries the 12 bytes the 1.x FTL itself writes (read off its own programs through
//   the ADM): data  [lpn u32][write age u32 = 0][ff][0x40][ff][ff], context [age u32][index u16][ff ff][ff]
//   [type][ff][ff] (0x43 index/meta, 0x46 map). A page that was never written reads as the machine's blank
//   (zeros, 0xff at byte 10: type 0), so free and used pages are told apart (docs/smoke.md #12).
// - The FTL's own blocks kept out of the data. The FTL context is virtual blocks 0-2 and its free pool 3-22
//   (FTLCxt.awFreeVbList); the filesystem starts at virtual block 23. generate_nand.c mapped logical block n to
//   virtual block n + 1, so the first log block the FTL took from its pool overwrote filesystem pages.
//
//   try N45NAND.write(volume: img, out: dir)       // (filesystem pages, metadata pages); zero pages are not written
//   N45NAND.location(lpn:)                         // (bank, page) of a logical page

import Foundation
import zlib

public enum N45NAND {
    public static let page = 2048, spare = 64, banks = 8, pagesPerBlock = 128, blocksPerBank = 4096
    static let pagesPerSuperblock = pagesPerBlock * banks
    /// The first physical block (all banks) the FTL's virtual block 0 lives in.
    static let ftlStart = 201
    static let cxtBlocks = 3, freeBlocks = 20, dataStart = 23
    static let vflCxtBlock = 35, mapTables = 18, logCxts = 18
    /// Logical blocks mapped (2 MiB each); the rest are 0xffff. Below the FTL's share of a 4096-block bank.
    static let mappedLBNs = 3800
    static let firstLBA = 3

    public struct Page: Hashable, Sendable { public let bank: Int, page: Int }

    /// A virtual page (FTL numbering, virtual block 0 = physical block 201) on its bank and physical page.
    static func location(vpn: Int) -> Page {
        let v = vpn + ftlStart * pagesPerSuperblock
        return Page(bank: v % banks, page: v / pagesPerSuperblock * pagesPerBlock + (v / banks) % pagesPerBlock)
    }

    public static func location(lpn: Int) -> Page { location(vpn: dataStart * pagesPerSuperblock + lpn) }

    static func dataSpare(_ lpn: Int) -> [UInt8] {
        var s = [UInt8](repeating: 0, count: spare)
        put(&s, 0, UInt64(lpn), 4)
        s[8] = 0xFF; s[9] = 0x40; s[10] = 0xFF; s[11] = 0xFF
        return s
    }

    static func cxtSpare(type: UInt8, index: Int, age: UInt32 = 0xFFFF_FFFF) -> [UInt8] {
        var s = [UInt8](repeating: 0, count: spare)
        put(&s, 0, UInt64(age), 4); put(&s, 4, UInt64(index), 2)
        s[6] = 0xFF; s[7] = 0xFF; s[8] = 0xFF; s[9] = type; s[10] = 0xFF; s[11] = 0xFF
        return s
    }

    static func put(_ b: inout [UInt8], _ o: Int, _ v: UInt64, _ n: Int) {
        for k in 0..<n { b[o + k] = UInt8(truncatingIfNeeded: v >> (8 * k)) }
    }

    static func crc(_ b: ArraySlice<UInt8>) -> UInt32 { UInt32(b.withUnsafeBufferPointer { zlib.crc32(0, $0.baseAddress, uInt($0.count)) }) }

    /// VFLMeta (vfl.h): the FTL context blocks, the info block, every block good.
    static func vflContext() -> [UInt8] {
        var d = [UInt8](repeating: 0, count: page)
        for i in 0..<cxtBlocks { put(&d, 4 + 2 * i, UInt64(i), 2) }         // aFTLCxtVbn
        for i in 1672..<1672 + 281 { d[i] = 0xFF }                            // aBadMark
        put(&d, 1954, UInt64(vflCxtBlock), 2)                                  // awInfoBlk[0]
        return d
    }

    /// FTLMeta (ftl.h, FTLCxt2): a flushed, valid context with an empty log and the free pool 3-22.
    static func ftlMeta() -> [UInt8] {
        var d = [UInt8](repeating: 0, count: page)
        put(&d, 0, 0xFFFF_FFFE, 4); put(&d, 4, 1, 4)                          // dwAge, dwWriteAge (data pages are 0)
        put(&d, 8, UInt64(freeBlocks), 2)                                      // wNumOfFreeVb
        for i in 0..<freeBlocks { put(&d, 14 + 2 * i, UInt64(cxtBlocks + i), 2) }
        for i in 0..<mapTables { put(&d, 56 + 4 * i, UInt64(1 + i), 4) }       // adwMapTablePtrs: pages 1-18 of block 0
        for i in 0..<logCxts { put(&d, 420 + 20 * i + 4, 0xFFFF, 2) }          // aLOGCxtTable[].wVbn: no log
        for i in 0..<cxtBlocks { put(&d, 786 + 2 * i, UInt64(i), 2) }          // awMapCxtVbn
        put(&d, 792, UInt64(pagesPerSuperblock - 1), 4)                        // dwCurrMapCxtPage: this page
        put(&d, 796, 1, 4)                                                     // boolFlashCxtIsValid
        put(&d, 2040, 0x4656_0000, 4); put(&d, 2044, UInt64(~UInt32(0x4656_0000)), 4)
        return d
    }

    /// LBA 0-2: an MBR whose one partition (type 0xEE) covers the filesystem (iBoot mounts it), the GPT header
    /// and its one Apple_HFS entry ("System").
    static func partitionPages(_ fsPages: Int) -> [[UInt8]] {
        var mbr = [UInt8](repeating: 0, count: page)
        mbr[0x1BE + 4] = 0xEE
        put(&mbr, 0x1BE + 8, UInt64(firstLBA), 4); put(&mbr, 0x1BE + 12, UInt64(fsPages), 4)
        mbr[0x1FE] = 0x55; mbr[0x1FF] = 0xAA
        var ent = [UInt8](repeating: 0, count: page)
        ent.replaceSubrange(0..<16, with: N72NAND.hfsType)
        ent.replaceSubrange(16..<32, with: [UInt8](Data(hex: "3c1f8e52067d4b0a9b612f0e8814c35d")!))
        put(&ent, 0x20, UInt64(firstLBA), 8); put(&ent, 0x28, UInt64(firstLBA + fsPages - 1), 8)
        for (i, c) in "System".utf16.enumerated() { put(&ent, 0x38 + 2 * i, UInt64(c), 2) }
        var hdr = [UInt8](repeating: 0, count: page)
        hdr.replaceSubrange(0..<8, with: Array("EFI PART".utf8))
        put(&hdr, 8, 0x00010000, 4); put(&hdr, 12, 0x5C, 4)
        put(&hdr, 0x18, 1, 8); put(&hdr, 0x28, UInt64(firstLBA), 8); put(&hdr, 0x30, UInt64(firstLBA + fsPages - 1), 8)
        hdr.replaceSubrange(0x38..<0x48, with: [UInt8](Data(hex: "6a2e5c109f3b4e418d271c44a510e701")!))
        put(&hdr, 0x48, 2, 8); put(&hdr, 0x50, 1, 4); put(&hdr, 0x54, 0x80, 4); put(&hdr, 0x58, UInt64(crc(ent[0..<0x80])), 4)
        put(&hdr, 0x10, UInt64(crc(hdr[0..<0x5C])), 4)
        return [mbr, hdr, ent]
    }

    /// Every page besides the filesystem's: FIL id, bad block tables, VFL contexts, the FTL context block,
    /// and LBA 0-2.
    public static func metadataPages(fsPages: Int) -> [Page: [UInt8]] {
        let zero = [UInt8](repeating: 0, count: spare)
        var fil = [UInt8](repeating: 0, count: page)
        put(&fil, 0, 0x4330_3032, 4)
        var pages: [Page: [UInt8]] = [Page(bank: 0, page: 0): fil + zero]
        let bbt = Array("DEVICEINFOBBT".utf8) + [UInt8](repeating: 0, count: page - 13)
        var vflSpare = zero
        vflSpare[0] = 1; vflSpare[9] = 0x80
        for b in 0..<banks {
            pages[Page(bank: b, page: (blocksPerBank - 1) * pagesPerBlock)] = bbt + zero
            pages[Page(bank: b, page: vflCxtBlock * pagesPerBlock)] = vflContext() + vflSpare
        }
        pages[location(vpn: 0)] = [UInt8](repeating: 0, count: page) + cxtSpare(type: 0x43, index: 0)
        for i in 0..<mapTables {
            let map = (0..<page / 2).map { j -> Int in let lbn = i * page / 2 + j; return lbn < mappedLBNs ? lbn + dataStart : 0xFFFF }
            var d = [UInt8](repeating: 0, count: page)
            for (j, v) in map.enumerated() { put(&d, 2 * j, UInt64(v), 2) }
            pages[location(vpn: 1 + i)] = d + cxtSpare(type: 0x46, index: i)
        }
        pages[location(vpn: pagesPerSuperblock - 1)] = ftlMeta() + cxtSpare(type: 0x43, index: 0, age: 0xFFFF_FFFE)
        for (lba, d) in partitionPages(fsPages).enumerated() { pages[location(lpn: lba)] = d + dataSpare(lba) }
        return pages
    }

    static func path(_ out: URL, _ p: Page) -> URL { out.appendingPathComponent("bank\(p.bank)/\(p.page).page") }

    /// The page directory for a flat HFS+ volume: metadata pages, then every non-zero filesystem page, plus the
    /// last page of each written block (the FTL recognises a data block by its last page when it rebuilds).
    @discardableResult
    public static func write(volume: URL, out: URL) throws -> (volume: Int, metadata: Int) {
        let fm = FileManager.default
        let size = try fm.attributesOfItem(atPath: volume.path)[.size] as? Int ?? 0
        let fsPages = (size + page - 1) / page
        guard (firstLBA + fsPages + pagesPerSuperblock - 1) / pagesPerSuperblock <= mappedLBNs else {
            throw FirmwareError(.unsupported, "a \(size)-byte volume is larger than the NAND's mapped logical blocks")
        }
        for b in 0..<banks { try fm.createDirectory(at: out.appendingPathComponent("bank\(b)"), withIntermediateDirectories: true) }
        let meta = metadataPages(fsPages: fsPages)
        for (p, d) in meta { try Data(d).write(to: path(out, p)) }
        let f = try FileHandle(forReadingFrom: volume)
        defer { try? f.close() }
        var n = 0, written = 0, blockUsed = true   // logical block 0 holds the partition pages
        let chunk = pagesPerSuperblock
        while n < fsPages {
            var data = try f.read(upToCount: chunk * page) ?? Data()
            if data.count < chunk * page { data.append(Data(count: chunk * page - data.count)) }
            for i in 0..<min(chunk, fsPages - n) {
                let lpn = firstLBA + n + i
                let pg = data[data.startIndex + i * page..<data.startIndex + (i + 1) * page]
                let last = (lpn + 1) % pagesPerSuperblock == 0, empty = pg.allSatisfy { $0 == 0 }
                blockUsed = blockUsed || !empty
                if !empty || (last && blockUsed) {
                    try (Data(pg) + dataSpare(lpn)).write(to: path(out, location(lpn: lpn)))
                    written += 1
                }
                if last { blockUsed = false }
            }
            n += chunk
        }
        let end = firstLBA + fsPages
        if blockUsed, end % pagesPerSuperblock != 0 {   // the volume ends inside a block: close it with its last page
            let lpn = (end / pagesPerSuperblock + 1) * pagesPerSuperblock - 1
            try (Data(count: page) + dataSpare(lpn)).write(to: path(out, location(lpn: lpn)))
            written += 1
        }
        return (written, meta.count)
    }
}
