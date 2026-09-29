// N45NAND: the iPod touch 1G page directory (bank{0..7}/<page>.page, 2048 data + 64 spare bytes each) that
// qemu-ios s5l8900_fmc.c serves: the legacy VFL/FTL layout of devos50's qemu-ios-generate-nand (main, the 1G
// generate_nand.c: FIL id, DEVICEINFOBBT, VFL context at block 35, the FTL from physical block 201 on, one HFS+
// partition behind an MBR + GPT), with what that tool left for later:
//
// - Real spares. Every page carries the 12 bytes the 1.x FTL itself writes (read off its own programs through
//   the ADM): data  [lpn u32][write age u32 = 0][ff][0x40][ff][ff], context [age u32][index u16][ff ff][ff]
//   [type][ff][ff] (0x43 index/meta, 0x46 map). A page never programmed reads erased (all ones), as on NAND,
//   so every page of the volume's blocks is written, zeros included (docs/smoke.md #12).
// - The FTL's own blocks kept out of the data. The FTL context is virtual blocks 0-2 and its free pool 3-22
//   (FTLCxt.awFreeVbList); the filesystem starts at virtual block 23. generate_nand.c mapped logical block n to
//   virtual block n + 1, so the first log block the FTL took from its pool overwrote filesystem pages.
// - A VFL context as VFL_Format stores it (vflContext): the context age, the next context page, the reserved
//   pool and its remap of the BBT block, both checksums; without the next page the VFL's next store programs
//   page 0 again.
// - The FIL id (the NAND signature) the build's driver wants, read off its iBoot (filID): generate_nand.c's
//   C002 is 3A101a-3B48b's; 4A93-4B1's driver is C003 and refuses C002 (docs/smoke.md #52).
//
//   try N45NAND.write(volume: img, out: dir, filID: N45NAND.filID(iBoot: ib))   // (filesystem pages, metadata pages)
//   N45NAND.location(lpn:)                         // (bank, page) of a logical page

import Foundation
import zlib

public enum N45NAND {
    public static let page = 2048, spare = 64, banks = 8, pagesPerBlock = 128, blocksPerBank = 4096
    static let pagesPerSuperblock = pagesPerBlock * banks
    /// The first physical block (all banks) the FTL's virtual block 0 lives in.
    static let ftlStart = 201
    static let cxtBlocks = 3, freeBlocks = 20, dataStart = 23
    static let vflCxtBlock = 35, vflCxtCopies = 8, mapTables = 18, logCxts = 18
    /// The reserved (bad-block replacement) pool: after the four VFL info blocks, up to the FTL.
    static let reservedStart = vflCxtBlock + 4, maxReserved = 820
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

    /// VFLMeta (Whimory VFLTypes.h: VFLCxt, then the version and two checksums) as VFL_Format leaves bank `bank`:
    /// the FTL context blocks, the four info blocks (35-38, the context in the first, eight copies on pages 0-7,
    /// so the next store goes to page 8), the reserved pool after them up to the FTL (39-200), and the BBT's own
    /// block 4095 (a special block, bad in the factory table) remapped to the pool's first block so the FTL,
    /// whose virtual block 3894 it is, finds that erased block and never the table.
    static func vflContext(bank: Int) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: page)
        put(&d, 0, UInt64(bank), 4)                                            // dwGlobalCxtAge
        for i in 0..<cxtBlocks { put(&d, 4 + 2 * i, UInt64(i), 2) }            // aFTLCxtVbn
        put(&d, 0xC, 0xFFFF_FFFF, 4)                                           // dwCxtAge: 0, less the one store
        put(&d, 0x12, UInt64(vflCxtCopies), 2)                                 // wNextCxtPOffset (wCxtLocation 0)
        put(&d, 0x14, 1, 2)                                                    // wNumOfInitBadBlk: the BBT block
        put(&d, 0x1A, 1, 2)                                                    // wBadMapTableMaxIdx
        put(&d, 0x1C, UInt64(reservedStart), 2)                                // wReservedSecStart
        put(&d, 0x1E, UInt64(ftlStart - reservedStart), 2)                     // wReservedSecSize
        put(&d, 0x20, UInt64(blocksPerBank - 1), 2)                            // aBadMapTable[0]: 4095 -> 39
        for i in 0x688..<0x7A2 { d[i] = 0xFF }                                 // aBadMark, one bit per 8 blocks
        d[0x688 + (blocksPerBank - 1) / 64] &= ~UInt8(1 << (7 - ((blocksPerBank - 1) / 8) % 8))
        for i in 0..<4 { put(&d, 0x7A2 + 2 * i, UInt64(vflCxtBlock + i), 2) }  // awInfoBlk
        put(&d, 0x7AA, UInt64(maxReserved), 2)                                 // wBadMapTableScrubIdx
        var sum: UInt32 = 0, xor: UInt32 = 0
        for o in stride(from: 0, to: 0x7F8, by: 4) {
            let w = UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
            sum &+= w; xor ^= w
        }
        put(&d, 0x7F8, UInt64(sum &+ 0xAABB_CCDD), 4); put(&d, 0x7FC, UInt64(xor ^ 0xAABB_CCDD), 4)
        return d
    }

    /// VFLSpare as the VFL writes its context pages: dwCxtAge, dwReserved, status mark 0 (valid), type 0x80.
    static let vflSpare: [UInt8] = [UInt8](repeating: 0xFF, count: 8) + [0x00, 0x80] + [UInt8](repeating: 0xFF, count: spare - 10)

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

    /// The NAND signature WMR_Init wants: the driver's own version, the word it prints as "Apple NAND Driver (AND)
    /// 0x%X" and then looks for as the first word of one of bank 0's first pages ("no signature or no production
    /// format" without it). 'C00N' little-endian; the one such literal in the iBoot (the kernel's FTL carries the
    /// same one): C002 in 3A101a-3B48b, C003 in 4A93-4B1.
    public static func filID(iBoot: Data) throws -> UInt32 {
        let ids = Set(stride(from: iBoot.startIndex, to: iBoot.endIndex - 3, by: 4).compactMap { o -> UInt32? in
            let w = UInt32(iBoot[o]) | UInt32(iBoot[o + 1]) << 8 | UInt32(iBoot[o + 2]) << 16 | UInt32(iBoot[o + 3]) << 24
            return w & 0xFFFF_FFF0 == 0x4330_3030 && w & 0xF <= 9 ? w : nil
        })
        guard ids.count == 1, let id = ids.first else {
            throw FirmwareError(.unsupported, "iBoot: \(ids.count) NAND driver versions ('C00N' literals), wanted one")
        }
        return id
    }

    /// Every page besides the filesystem's: FIL id (the NAND signature `filID`), bad block tables, VFL contexts,
    /// the FTL context block, and LBA 0-2.
    public static func metadataPages(fsPages: Int, filID: UInt32) -> [Page: [UInt8]] {
        let zero = [UInt8](repeating: 0, count: spare)
        var fil = [UInt8](repeating: 0, count: page)
        put(&fil, 0, UInt64(filID), 4)
        var pages: [Page: [UInt8]] = [Page(bank: 0, page: 0): fil + zero]
        let bbt = Array("DEVICEINFOBBT".utf8) + [UInt8](repeating: 0, count: page - 13)
        for b in 0..<banks {
            pages[Page(bank: b, page: (blocksPerBank - 1) * pagesPerBlock)] = bbt + zero
            let cxt = vflContext(bank: b) + vflSpare
            for c in 0..<vflCxtCopies { pages[Page(bank: b, page: vflCxtBlock * pagesPerBlock + c)] = cxt }
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

    /// The page directory for a flat HFS+ volume: metadata pages, then every page of every logical block the
    /// volume spans, zeros included, as a restore writes the whole image. The model reads a page never
    /// programmed as erased, and the FTL fails the read of an erased page it maps (the kernel probes the
    /// volume's last pages, zeros in a fresh image).
    @discardableResult
    public static func write(volume: URL, out: URL, filID: UInt32) throws -> (volume: Int, metadata: Int) {
        let fm = FileManager.default
        let size = try fm.attributesOfItem(atPath: volume.path)[.size] as? Int ?? 0
        let fsPages = (size + page - 1) / page
        let blocks = (firstLBA + fsPages + pagesPerSuperblock - 1) / pagesPerSuperblock
        guard blocks <= mappedLBNs else {
            throw FirmwareError(.unsupported, "a \(size)-byte volume is larger than the NAND's mapped logical blocks")
        }
        for b in 0..<banks { try fm.createDirectory(at: out.appendingPathComponent("bank\(b)"), withIntermediateDirectories: true) }
        let meta = metadataPages(fsPages: fsPages, filID: filID)
        for (p, d) in meta { try Data(d).write(to: path(out, p)) }
        let f = try FileHandle(forReadingFrom: volume)
        defer { try? f.close() }
        var written = 0
        for lbn in 0..<blocks {   // logical block 0 starts with the partition pages (LBA 0-2), written above
            let first = lbn * pagesPerSuperblock, skip = max(0, firstLBA - first)
            try f.seek(toOffset: UInt64((first + skip - firstLBA) * page))
            var data = try f.read(upToCount: (pagesPerSuperblock - skip) * page) ?? Data()
            data.append(Data(count: (pagesPerSuperblock - skip) * page - data.count))
            for i in 0..<pagesPerSuperblock - skip {
                let lpn = first + skip + i
                try (data[data.startIndex + i * page..<data.startIndex + (i + 1) * page] + dataSpare(lpn)).write(to: path(out, location(lpn: lpn)))
                written += 1
            }
        }
        return (written, meta.count)
    }
}
