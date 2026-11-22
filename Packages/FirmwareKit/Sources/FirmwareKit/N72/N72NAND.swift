// N72NAND: the iPod touch 2G's NAND (4096 data + 64 spare bytes a page) in the generated FTL layout
// hw/arm/ipod_touch_fmss.c serves: one HFSX volume striped by a closed formula, plus the ~50 bookkeeping pages the
// formula does not cover, written as an image store (N72NANDImage). Ports imgtools/ftlmap.predict,
// ipod2g_nand.metadata_pages and build_nand.write_pages (zero blocks are not written: they read blank).
//
//   N72NAND.predict(block)                                   // (cs, page) of an allocation block
//   N72NAND.metadataPages(blocks: n, epoch: e)               // [(cs, page): data + spare]
//   try N72NAND.write(volume: img, blocks: n, epoch: e, out: dir)   // (volume pages, metadata pages)

import FirmwareSchema
import Foundation
import HostRuntime
import zlib

public enum N72NAND {
    public static let page = 4096, spare = 64, pagesPerBlock = 128
    static let bbtPage = 4095 * 128, mapPages = 18
    static let blankSpare: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0, 0xFF, 0] + [UInt8](repeating: 0, count: 52)
    static let vflSpare: [UInt8] = [1] + [UInt8](repeating: 0, count: 8) + [0x80] + [UInt8](repeating: 0, count: 54)
    static let metaSpare: [UInt8] = [UInt8](repeating: 0, count: 9) + [0x43] + [UInt8](repeating: 0, count: 54)
    static let hfsType = [UInt8](Data(hexLiteral: "005346480000aa11aa1100306543ecac"))
    static let ftlLog = Array("Writing FTL Meta to physical page 255 @ cs 3\nto physical page 130 @ cs 2\n".utf8)

    public struct Page: Hashable, Sendable { public let cs: Int, page: Int }

    /// Four consecutive blocks form a row over the chip selects; rows alternate between two erase blocks and
    /// erase blocks are used in pairs from 2 on.
    public static func predict(_ n: Int) -> Page {
        let r = (n + 3) / 4
        return Page(cs: (n + 3) % 4, page: (2 * (r / 256) + 2 + r % 2) * pagesPerBlock + (r % 256) / 2)
    }

    static func u16s(_ w: [Int]) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: page)
        for (i, v) in w.enumerated() {
            b[2 * i] = UInt8(v & 0xFF)
            b[2 * i + 1] = UInt8(v >> 8 & 0xFF)
        }
        return b
    }

    /// (cs, page) of the k-th FTL map page: the volume's interleave over erase blocks 0/1.
    static func stripe(_ k: Int) -> Page {
        let m = k + 1
        let r = m / 4
        return Page(cs: m % 4, page: ((r + 1) % 2) * pagesPerBlock + (r + 1) / 2)
    }

    static func vflPage(_ cs: Int, first: Bool) -> [UInt8] {
        var w = [Int](repeating: 0, count: 2048)
        w[0] = cs
        w[6] = 1
        for i in 19..<839 { w[i] = 0xFFF0 }
        w.replaceSubrange(839..<848, with: [0, 1, 2, 3, 0x800, 0x800, 0, 1, 2])
        w[877] = 0x14
        w[878] = 0x10
        w[1018] = 2
        if first {
            w[1024] = 1
            w[1028] = 0x8000
        }
        let p = u16s(w)
        // The VFL writer's checksum over the 0x7f8-byte context: word sum and word xor, each keyed with 0xaabbccdd
        // (4.x iBoot verifies it; 3.x's verifier is a stub).
        return K48NAND.vflChecksum(p)
    }

    static func ftlContext() -> [UInt8] {
        var w = [Int](repeating: 0, count: 2048)
        w[4] = 20
        for (i, v) in (3..<23).enumerated() { w[7 + i] = v }  // free pool VBNs
        for (i, v) in (5..<23).enumerated() { w[28 + 2 * i] = v }
        for i in 0..<18 { w[212 + 10 * i] = 0xFFFF }
        w.replaceSubrange(1021..<1024, with: [0x4656, 0xFFFF, 0xB9A9])
        var d = u16s(w)
        d.replaceSubrange(2048..<2048 + ftlLog.count, with: ftlLog)
        return d
    }

    static func put(_ b: inout [UInt8], _ o: Int, _ v: UInt64, _ n: Int) {
        for k in 0..<n { b[o + k] = UInt8(truncatingIfNeeded: v >> (8 * k)) }
    }

    /// Device LBA 0-2: protective MBR, GPT header, one Apple_HFS entry sized
    /// exactly to the filesystem. `blocks` is the validated HFS extent in 4 KiB
    /// pages supplied by the preparer, not a rounded backing-file length.
    /// Older HFS disables alternate-header writes
    /// when the partition extends more than one allocation block beyond it.
    /// `slack`: recipe 1 (every base before 0b43f26) ended the partition 11 blocks past the volume.
    static func gptPages(_ blocks: Int, slack: Int = 0) -> [[UInt8]] {
        var mbr = [UInt8](repeating: 0, count: page)
        mbr[8] = 0xFF
        mbr[10] = 0xFF  // as generated: a spare pattern in the data area
        mbr[0x1BE + 4] = 0xEE
        put(&mbr, 0x1BE + 8, 3, 4)
        put(&mbr, 0x1BE + 12, UInt64(blocks + 10), 4)
        mbr[0x1FE] = 0x55
        mbr[0x1FF] = 0xAA
        var ent = [UInt8](repeating: 0, count: page)
        ent.replaceSubrange(0..<16, with: hfsType)
        put(&ent, 0x20, 3, 8)
        put(&ent, 0x28, UInt64(3 + blocks - 1 + slack), 8)
        var hdr = [UInt8](repeating: 0, count: page)
        hdr.replaceSubrange(0..<8, with: Array("EFI PART".utf8))
        put(&hdr, 8, 0x0001_0000, 4)
        put(&hdr, 12, 0x5C, 4)
        put(&hdr, 0x48, 2, 8)
        put(&hdr, 0x50, 1, 4)
        put(&hdr, 0x54, 0x80, 4)
        put(&hdr, 0x58, UInt64(crc(ent[0..<0x80])), 4)
        put(&hdr, 0x10, UInt64(crc(hdr[0..<0x5C])), 4)
        return [mbr, hdr, ent]
    }

    /// NANDDRIVERSIGN: '0' + the NAND epoch (Restore.plist SCEP) | 0x43313100, flags 4.
    static func signature(_ epoch: Int) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: page)
        d.replaceSubrange(0..<14, with: Array("NANDDRIVERSIGN".utf8))
        put(&d, 0x34, 4, 4)
        put(&d, 0x38, UInt64(0x4331_3100 | (0x30 + epoch)), 4)
        return d
    }

    /// Every page the volume formula does not cover.
    public static func metadataPages(blocks: Int, epoch: Int) -> [Page: [UInt8]] {
        let zeroSpare = [UInt8](repeating: 0, count: spare)
        var pages: [Page: [UInt8]] = [
            Page(cs: 0, page: 0): [UInt8](repeating: 0, count: page) + metaSpare,
            Page(cs: 3, page: 255): ftlContext() + metaSpare
        ]
        let maps = Set((0..<mapPages).map(stripe))
        for k in 0..<mapPages { pages[stripe(k)] = u16s((0..<2048).map { k * 2048 + $0 + 1 }) + zeroSpare }
        let bbt = Array("DEVICEINFOBBT".utf8) + [0, 0, 0] + [UInt8](repeating: 0xFF, count: 4080)
        for cs in 0..<4 {
            for pg in pagesPerBlock..<pagesPerBlock + 8 where !maps.contains(Page(cs: cs, page: pg)) {
                pages[Page(cs: cs, page: pg)] = vflPage(cs, first: cs == 0 && pg > pagesPerBlock) + vflSpare
            }
            pages[Page(cs: cs, page: bbtPage + 1)] = bbt + zeroSpare
        }
        for (cs, d) in gptPages(blocks).enumerated() { pages[Page(cs: cs, page: 2 * pagesPerBlock)] = d + blankSpare }
        pages[Page(cs: 0, page: bbtPage)] = signature(epoch) + zeroSpare
        return pages
    }

    /// The image store (N72NANDImage) for a flat volume of `blocks` 4 KiB blocks: metadata pages, then every
    /// non-zero block. Callers supply the actual HFS extent; this low-level writer does not parse
    /// arbitrary backing-file padding or repair a malformed filesystem.
    @discardableResult
    public static func write(volume: URL, blocks: Int, epoch: Int, out: URL) throws -> (volume: Int, metadata: Int) {
        let store = try N72NANDImage.create(out)
        let meta = metadataPages(blocks: blocks, epoch: epoch)
        for (p, d) in meta { try store.write(p, d) }
        let f = try FileHandle(forReadingFrom: volume)
        defer { try? f.close() }
        var n = 0
        var written = 0
        let chunk = 1024
        while n < blocks {
            var data = try f.read(upToCount: chunk * page) ?? Data()
            if data.count < chunk * page { data.append(Data(count: chunk * page - data.count)) }
            let bytes = [UInt8](data)
            for i in 0..<min(chunk, blocks - n) {
                let blk = bytes[i * page..<(i + 1) * page]
                if blk.allSatisfy({ $0 == 0 }) { continue }
                try store.write(predict(n + i), Array(blk) + blankSpare)
                written += 1
            }
            n += chunk
        }
        try store.sync()
        return (written, meta.count)
    }

    // MARK: - Recipe 1 -> 2 in place

    /// The recipe whose GPT ends at the HFS extent (0b43f26), as FirmwareWire.admissionRecipeSteps declares it.
    public static let exactGPTRecipe: Int = {
        guard let step = FirmwareWire.admissionRecipeSteps["n72ap"]?[1] else {
            preconditionFailure("FirmwareWire.admissionRecipeSteps has no n72ap 1 -> 2 step")
        }
        return step
    }()
    static let legacyGPTSlack = 11

    /// A stopped device whose base still has recipe 1's overlong GPT gets recipe 2's two GPT pages (header, entry;
    /// this layout has no backup GPT) in its overlay, byte for byte what `metadataPages` writes today, and, if its
    /// lock names an older recipe, `marker` records exactGPTRecipe. Pages that are neither layout (a guest rewrote
    /// the GPT, an erased block) are left alone. The base is never written; qemu sizes its FTL from the base's GPT,
    /// so the emulated flash geometry is unchanged. The caller holds the device's stopped storage lease.
    ///
    /// Under the overlong GPT the guest never wrote the alternate volume header, so on a device whose catalog
    /// grew it still describes the prepared B-trees and fsck_hfs (Open in Finder) refuses the volume. The guest
    /// rewrites it only when a B-tree grows again, not on a later boot or clean shutdown (measured on 7E18), so
    /// the alternate becomes a copy of the primary, as the guest's own alternate flush writes it.
    ///
    /// Order for crash safety: alternate, GPT, marker. Until the GPT pages land the device still reads as recipe 1
    /// and the next run redoes the (idempotent) alternate; exact pages without a marker are only marked.
    /// Returns whether anything was written.
    public static func migrateLegacyGPT(base: URL, overlay: URL, storageKey: String?, marker: URL) throws -> Bool {
        let fm = FileManager.default
        // an image store (format 2) is written by a recipe with the exact GPT, or migrated after this step
        guard !N72NANDImage.isImage(base.appendingPathComponent("nand")) else { return false }
        func path(_ p: Page) -> String { "cs\(p.cs)/\(p.page).page" }
        func current(_ p: Page) -> [UInt8]? {
            if let d = try? Data(contentsOf: overlay.appendingPathComponent(path(p))) { return [UInt8](d.prefix(page)) }
            if fm.fileExists(
                atPath: overlay.appendingPathComponent("cs\(p.cs)/blk\(p.page / pagesPerBlock).erased").path
            ) {
                return nil
            }
            return (try? Data(contentsOf: base.appendingPathComponent("nand/\(path(p))"))).map {
                [UInt8]($0.prefix(page))
            }
        }
        func write(_ data: [UInt8], _ p: Page) throws {
            try writeDurably(Data(data + blankSpare), to: overlay.appendingPathComponent(path(p)))
        }
        // Header and entry only say where the partition ends (recipe 1's B blocks end where recipe 2's B + 11
        // do); the protective MBR, which neither recipe changed, says the volume's B.
        let gpt = (0..<3).map { Page(cs: $0, page: 2 * pagesPerBlock) }
        guard let mbr = current(gpt[0]), let header = current(gpt[1]), let entry = current(gpt[2]), mbr.count == page
        else { return false }
        let blocks = try K48NAND.partitions(mbr: mbr)[0].count - 10
        guard blocks > 0 else { return false }
        var changed = false
        if gptPages(blocks, slack: legacyGPTSlack) == [mbr, header, entry] {
            // The volume the GPT was made for: HFS+/HFSX at block 0, `blocks` 4 KiB long.
            guard let first = current(predict(0)), first.count == page,
                let bytes = try? HFSPlusVolume.headerBytes(first, at: 1024), bytes == blocks * page
            else { return false }
            if let storageKey, try !PreparedDeviceBoot.pinOverlay(overlay, toBase: storageKey) { return false }
            let primary = first[1024..<1536]
            let end = predict(blocks - 1)
            let offset = page - 1024
            var last = current(end) ?? []
            last += [UInt8](repeating: 0, count: page - last.count)
            if last[offset..<offset + 512] != primary {
                last.replaceSubrange(offset..<offset + 512, with: primary)
                try write(last, end)
            }
            for (cs, data) in gptPages(blocks).enumerated() where cs > 0 { try write(data, gpt[cs]) }
            changed = true
        } else if gptPages(blocks) != [mbr, header, entry] {
            return false
        }
        let marked = (try? Data(contentsOf: marker)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        if let version = (try? DeviceLock.read(base: base))??.recipeVersion, version < exactGPTRecipe,
            (marked?["recipe"] as? Int ?? 0) < exactGPTRecipe
        {
            try writeDurably(
                JSONSerialization.data(
                    withJSONObject: ["recipe": exactGPTRecipe, "step": "n72-exact-gpt"],
                    options: [.sortedKeys]
                ),
                to: marker
            )
            changed = true
        }
        return changed
    }

    /// As qemu's fmss_store_page: a synced temporary renamed over the target, then the directory synced.
    static func writeDurably(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp")
        // The overlay is the helper's to write: a leftover, or a link planted at this name, goes, never written through.
        try? FileManager.default.removeItem(at: tmp)
        try data.write(to: tmp, options: .withoutOverwriting)
        let fd = open(tmp.path, O_RDONLY)
        defer { if fd >= 0 { close(fd) } }
        guard fd >= 0, fsync(fd) == 0, rename(tmp.path, url.path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        let dfd = open(dir.path, O_RDONLY)
        if dfd >= 0 {
            fsync(dfd)
            close(dfd)
        }
    }
}
