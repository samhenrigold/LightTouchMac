// ipad1_nand.py check: reads a store back the way the kernel would (special pages, VFL contexts, a
// YaFTL R/O-restore walk over every vblock, the index pages, then the MBR and HFS headers).
import Foundation

extension K48NAND {
    final class StoreReader {
        let geo: Geometry, stride: Int
        let files: [Data]
        init(_ dir: URL, geo: Geometry) throws {
            self.geo = geo
            stride = geo.pageSize + geo.spareBytes
            files = try (0..<geo.buses).flatMap { b in
                try (0..<geo.cePerBus).map { c in try Data(contentsOf: dir.appendingPathComponent("bus\(b)-ce\(c).pages"), options: .alwaysMapped) }
            }
        }

        /// (data, 12-byte meta, un-whitened unless raw), nil if the page is blank.
        func read(_ cs: Int, _ ppage: Int, raw: Bool = false) -> (data: [UInt8], meta: [UInt8])? {
            let (b, c) = geo.busCE(cs)
            let f = files[b * geo.cePerBus + c], o = ppage * stride
            guard o + stride <= f.count else { return nil }
            let rec = [UInt8](f[o..<o + stride])
            let sp = rec[geo.pageSize...]
            if sp.allSatisfy({ $0 == 0 }) || (sp.allSatisfy { $0 == 0xFF } && rec[..<geo.pageSize].allSatisfy { $0 == 0xFF }) { return nil }
            let m = Array(sp.prefix(K48NAND.meta))
            return (Array(rec[..<geo.pageSize]), raw ? m : K48NAND.whiten(m, ppage))
        }
        func readVPN(_ vpn: Int) -> (data: [UInt8], meta: [UInt8])? { let (cs, p) = geo.vpnToPhys(vpn); return read(cs, p) }
    }

    /// Checks a store; `log` gets every "ok"/"FAIL" line. Returns true when nothing failed.
    public static func check(store dir: URL, mbr: URL? = nil, system: URL? = nil, log: (String) -> Void = { _ in }) throws -> Bool {
        guard let g = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("geometry.json"))) as? [String: Any],
              let geo = Geometry.known.first(where: {
                  ($0.buses, $0.cePerBus, $0.blocksPerCE, $0.pagesPerBlock, $0.pageSize)
                      == (g["buses"] as? Int, g["ce_per_bus"] as? Int, g["blocks_per_ce"] as? Int, g["pages_per_block"] as? Int, g["page_bytes"] as? Int)
              }) else { throw FirmwareError(.unsupported, "\(dir.path): no known geometry matches geometry.json") }
        let st = try StoreReader(dir, geo: geo)
        var fails: [String] = []
        func ok(_ cond: Bool, _ what: @autoclosure () -> String) {
            if cond { log("ok   " + what()) } else { fails.append("FAIL " + what()) }
        }
        func bit(_ bbt: [UInt8], _ b: Int) -> Bool { bbt[b / 8] >> (b % 8) & 1 != 0 }
        func magic(_ d: [UInt8], _ m: String) -> Bool { Array(d.prefix(16)) == Array(m.utf8) + [UInt8](repeating: 0, count: 16 - m.utf8.count) }

        // special pages: _ReadSpecialBlock's scan window, top block down
        var sigBlock: Int?
        for cs in 0..<geo.numCS {
            var found: (blk: Int, cands: [Int], bbt: [UInt8])?
            for blk in stride(from: geo.blocksPerCE - 1, to: geo.blocksPerCE - geo.blocksPerCE / 10 - 1, by: -1) {
                if let (d, _) = st.read(cs, geo.ppage(blk, 0)), magic(d, "DEVICEINFOBBT") {
                    let n = Int(le32(d, 0x34))
                    found = (blk, (0..<8).map { Int(le32(d, 0x14 + 4 * $0)) }, Array(d[0x38..<0x38 + n]))
                    break
                }
            }
            ok(found != nil && found!.bbt.count == geo.bbtLen, "cs\(cs) DEVICEINFOBBT at block \(hex(found?.blk ?? 0))")
            guard let (_, c, bbt) = found else { continue }
            ok(!bit(bbt, 0) && geo.cand[cs].allSatisfy { !bit(bbt, $0) }, "cs\(cs) BBT marks block 0 and candidates bad")
            ok(bit(bbt, geo.vflBlocks[0]), "cs\(cs) BBT block 1 good")
            let d2 = st.read(cs, geo.ppage(c[1], 0))
            ok(d2.map { magic($0.data, "DEVICEINFOBBT") } ?? false, "cs\(cs) second BBT copy at \(hex(c[1]))")
            if cs == 0 { sigBlock = c[4] }
        }
        let sig = st.read(0, geo.ppage(sigBlock ?? 0, 0))
        ok(sig.map { magic($0.data, "NANDDRIVERSIGN") } ?? false, "NANDDRIVERSIGN at cs0 block \(hex(sigBlock ?? 0)) (BBT hdr+0x24)")
        if let (d, _) = sig {
            ok(le32(d, 0x38) == nsig && le32(d, 0x3c) == sigFlags, "signature nSig=\(String(format: "%08x", le32(d, 0x38))) flags=\(String(format: "%08x", le32(d, 0x3c))) (VSVFL, epoch 1, whitening on)")
        }

        // VFL contexts
        for cs in 0..<geo.numCS {
            let copies = (0..<8).map { st.read(cs, geo.ppage(geo.vflBlocks[0], $0)) }
            guard let first = copies[0] else { fails.append("FAIL cs\(cs) VFLCxt missing"); continue }
            let ctx = Array(first.data.prefix(0x800))
            ok(copies.allSatisfy { $0.map { Array($0.data.prefix(0x800)) == ctx } ?? false }, "cs\(cs) VFLCxt 8 identical copies")
            ok(ctx == vflChecksum(ctx), "cs\(cs) VFLCxt checksums")
            ok(copies.allSatisfy { $0.map { $0.meta[8] == 0 && $0.meta[9] == tVFL } ?? false }, "cs\(cs) VFLCxt spare type 0x80")
            func u16(_ o: Int) -> Int { Int(ctx[o]) | Int(ctx[o + 1]) << 8 }
            let ver = le32(ctx, 0x7f4), ftlType = le32(ctx, 8), usable = u16(0x696), pstart = u16(0x698)
            let cb = [u16(0x69a), u16(0x69c), u16(0x69e)]
            ok(ver <= 2 && ftlType == 2 && usable == geo.usable && pstart == geo.usable && cb == geo.ctrlBlocks,
               "cs\(cs) VFLCxt version \(ver) ftl_type \(ftlType) usable \(usable) ctrl \(cb)")
            ok(geo.remap.allSatisfy { pbn, r in u16(0x26 + 2 * (r.bank * geo.pool + r.slot)) == pbn },
               "cs\(cs) pool map remaps blocks \(geo.remap.keys.sorted())")
        }

        // FTL walk: every vblock's page 0 classifies it
        var tocFromIndex: [Int: [UInt32]] = [:], tocFromUser: [Int: Int] = [:]
        var nuser = 0, nindex = 0, nfree = 0
        for v in 0..<geo.numBlocks {
            let base = v * geo.ppsublk
            guard let (_, m) = st.readVPN(base) else { nfree += 1; continue }
            let typ = m[9]
            if geo.ctrlBlocks.contains(v) { fails.append("FAIL ctrl vblock \(v) is programmed") }
            if typ == tIndex { nindex += 1 } else if typ == tUser { nuser += 1 } else {
                fails.append("FAIL vblock \(v) page 0 has spare type \(hex(typ))"); continue
            }
            var lpns: [UInt32] = []
            for j in 0..<geo.ppsublk {
                guard let (pd, pm) = st.readVPN(base + j), pm[9] & tClosed == 0 else { break }
                let lpn = le32(pm, 0)
                lpns.append(lpn)
                if typ == tIndex {
                    tocFromIndex[Int(lpn)] = (0..<geo.tocEntries).map { le32(pd, 4 * $0) }
                } else { tocFromUser[Int(lpn)] = base + j }
            }
            if lpns.count == geo.dataPages {
                let table = (0..<geo.toc).flatMap { st.readVPN(base + geo.dataPages + $0)?.data ?? [] }
                let got = (0..<geo.dataPages).map { 4 * $0 + 4 <= table.count ? le32(table, 4 * $0) : 0 }
                if v % 25 == 0 || got != lpns { ok(got == lpns, "vblock \(v) closed, BTOC matches \(lpns.count) page spares") }
            }
        }
        log("ok    \(nuser) user, \(nindex) index, \(nfree) free vblocks")
        var rebuilt: [Int: Int] = [:]
        for (t, arr) in tocFromIndex { for (i, vpn) in arr.enumerated() where vpn != unmapped { rebuilt[t * geo.tocEntries + i] = Int(vpn) } }
        ok(rebuilt == tocFromUser, "index pages map exactly the \(tocFromUser.count) user pages")
        func lpnData(_ lpn: Int) -> [UInt8]? { rebuilt[lpn].flatMap { st.readVPN($0)?.data } }

        let m0 = lpnData(0)
        ok(m0.map { $0[510] == 0x55 && $0[511] == 0xAA } ?? false, "LBA 0 carries an MBR")
        if let m0 {
            let parts = partitions(mbr: m0)
            for (i, p) in parts.enumerated() where p.type != 0 {
                ok(p.lba + p.count <= geo.exportedPages, "partition \(i + 1) type \(String(format: "%02x", p.type)) lba \(p.lba) count \(p.count) inside exported size")
                if p.type == 0xAF && p.count > 256 {
                    let sig = lpnData(p.lba).map { Array($0[1024..<1026]) }
                    ok(sig == Array("H+".utf8) || sig == Array("HX".utf8), "partition \(i + 1) has an HFS+ volume header")
                }
            }
            if let mbr {
                let src = [UInt8](try Data(contentsOf: mbr).prefix(512))
                ok(Array(m0[..<0x1be]) == Array(src[..<0x1be]) && parts[0] == partitions(mbr: src)[0],
                   "LBA 0 matches \(mbr.lastPathComponent) (boot code + partition 1)")
            }
            if let system {
                let (lba, cnt) = (parts[0].lba, parts[0].count)
                let f = try FileHandle(forReadingFrom: system)
                defer { try? f.close() }
                let sample = Array(0..<64) + Array(stride(from: 0, to: cnt, by: max(1, cnt / 512)))
                var bad = 0
                for n in sample {
                    try f.seek(toOffset: UInt64(n * geo.pageSize))
                    var want = [UInt8](try f.read(upToCount: geo.pageSize) ?? Data())
                    want += [UInt8](repeating: 0, count: geo.pageSize - want.count)
                    let got = lpnData(lba + n)
                    if got != want && !(got.map { Data($0).range(of: Data("/dev/disk0s2".utf8)) != nil } ?? false) { bad += 1 }
                }
                ok(bad == 0, "\(sample.count) sampled system pages match \(system.lastPathComponent)")
            }
        }
        fails.forEach(log)
        log("\(dir.path): " + (fails.isEmpty ? "all checks passed" : "FAILED (\(fails.count))"))
        return fails.isEmpty
    }
}
