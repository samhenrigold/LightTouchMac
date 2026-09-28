// VolumeRebuild: a stopped device's logical HFS+ volumes, rebuilt from its read-only base plus its NAND
// overlay into sparse raw images (docs/filesystem-f0-findings.md, F1). Nothing here opens a store for writing.
//
//   let vols = try VolumeRebuild.rebuild(base: nand, overlay: ovl, into: dir)          // every volume
//   try VolumeRebuild.rebuild(base: nand, overlay: ovl, into: dir, only: ["system"])
//
// iPod (n72, base = cs<N>/<page>.page): the emulator stores every guest write where its logical block lives
// in the generated layout (ipod_touch_fmss.c fmss_generated_layout, ftlmap.predict), so the volume is
// dumpvol.py with overlay/cs<N>/<page>.page over the base and blk<B>.erased markers (written and honoured
// only under FMSS_ERASE) reading as blank.
// One volume, "system" (the generated image keeps /private/var on it).
//
// iPad (k48, base = geometry.json + bus<b>-ce<c>.pages): a YaFTL read-only restore over base + overlay
// (the .dirty bitmap picks the source): every vblock is walked through the VFL until its first blank
// page; each user page's copy with the highest (USN, vpn) wins; index pages, BTOCs and the control
// vblocks (the CX01 context) are ignored. MBR partition 1 is "system", 2 is "data".

import Foundation

public enum VolumeRebuild {
    public struct Volume: Sendable, Codable, Equatable {
        public let name: String
        public let image: URL
        public let bytes: Int
        /// 4 KiB pages written into the (otherwise sparse) image.
        public let pagesWritten: Int
    }

    public enum Board: String, Sendable { case ipod, ipad }

    public static func board(of base: URL) throws -> Board {
        let fm = FileManager.default
        if fm.fileExists(atPath: base.appendingPathComponent("geometry.json").path) { return .ipad }
        if fm.fileExists(atPath: base.appendingPathComponent("cs0").path) { return .ipod }
        throw FirmwareError(.unsupported, "\(base.path): neither an iPad store (geometry.json) nor an iPod page directory (cs0/)")
    }

    /// Rebuilds the volumes named in `only` (all when nil) into `<dir>/<name>.img`.
    public static func rebuild(base: URL, overlay: URL?, into dir: URL, only: Set<String>? = nil) throws -> [Volume] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        switch try board(of: base) {
        case .ipod: return try iPod(base: base, overlay: overlay, into: dir, only: only)
        case .ipad: return try iPad(base: base, overlay: overlay, into: dir, only: only)
        }
    }

    // MARK: iPod

    static let page = 4096

    /// ftlmap.predict: HFS+ allocation block n (device LBA n + 3) -> physical (cs, page).
    static func predict(_ n: Int) -> (cs: Int, page: Int) {
        let (r, cs) = (n + 3).quotientAndRemainder(dividingBy: 4)
        let eb = 2 * (r / 256) + 2 + (r % 2)
        return (cs, eb * 128 + (r % 256) / 2)
    }

    static func iPod(base: URL, overlay: URL?, into dir: URL, only: Set<String>?) throws -> [Volume] {
        guard only.map({ $0.contains("system") }) ?? true else {
            throw FirmwareError(.unsupported, "the iPod has one volume, system (/private/var is on it)")
        }
        let fm = FileManager.default
        func names(_ d: URL?, _ cs: Int) -> Set<String> {
            guard let d else { return [] }
            return Set((try? fm.contentsOfDirectory(atPath: d.appendingPathComponent("cs\(cs)").path)) ?? [])
        }
        let baseNames = (0..<4).map { names(base, $0) }, ovlNames = (0..<4).map { names(overlay, $0) }
        func source(_ cs: Int, _ pg: Int) -> URL? {
            let n = "\(pg).page"
            if let overlay, ovlNames[cs].contains(n) { return overlay.appendingPathComponent("cs\(cs)/\(n)") }
            if ovlNames[cs].contains("blk\(pg / 128).erased") { return nil }
            return baseNames[cs].contains(n) ? base.appendingPathComponent("cs\(cs)/\(n)") : nil
        }
        var buf = [UInt8](repeating: 0, count: page)
        func read(_ n: Int) throws -> Bool {
            let (cs, pg) = predict(n)
            guard let u = source(cs, pg) else { return false }
            let fd = open(u.path, O_RDONLY)
            guard fd >= 0 else { throw FirmwareError(.internal, "\(u.path): \(String(cString: strerror(errno)))") }
            defer { close(fd) }
            let got = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, page, 0) }
            guard got >= 0 else { throw FirmwareError(.internal, "\(u.path): \(String(cString: strerror(errno)))") }
            for i in max(got, 0)..<page { buf[i] = 0 }
            return buf.contains { $0 != 0 }
        }

        // The volume's own size, not the GPT partition's (11 blocks longer as generated): macOS looks for the
        // alternate volume header 1 KiB before the end of the device.
        guard try read(0), buf[1024] == 0x48, buf[1025] == 0x2B || buf[1025] == 0x58 else {
            throw FirmwareError(.unsupported, "\(base.path): no HFS+ volume header at block 0")
        }
        let blocks = Int(be32(buf, 1024 + 44)) * Int(be32(buf, 1024 + 40)) / page

        let out = dir.appendingPathComponent("system.img")
        let fd = try create(out, bytes: blocks * page)
        defer { close(fd) }
        var written = 0
        for n in 0..<blocks where try read(n) {
            try pwriteAll(fd, buf, n * page, out)
            written += 1
        }
        return [Volume(name: "system", image: out, bytes: blocks * page, pagesWritten: written)]
    }

    // MARK: iPad

    static func iPad(base: URL, overlay: URL?, into dir: URL, only: Set<String>?) throws -> [Volume] {
        let geo = try K48NAND.geometry(store: base)
        let st = try K48NAND.StoreReader(base, geo: geo, overlay: overlay)
        let map = yaftlMap(st)
        func data(_ lpn: Int) -> [UInt8]? {
            guard lpn < map.count, map[lpn] != 0 else { return nil }
            let (cs, pp) = geo.vpnToPhys(Int(map[lpn] - 1))
            return st.read(cs, pp)?.data
        }
        guard let mbr = data(0), mbr[510] == 0x55, mbr[511] == 0xAA else {
            throw FirmwareError(.unsupported, "\(base.path): LBA 0 carries no MBR")
        }
        let parts = K48NAND.partitions(mbr: mbr)
        var vols: [Volume] = []
        for (name, p) in [("system", parts[0]), ("data", parts[1])] where p.type != 0 && only.map({ $0.contains(name) }) ?? true {
            let out = dir.appendingPathComponent("\(name).img")
            let fd = try create(out, bytes: p.count * geo.pageSize)
            defer { close(fd) }
            var written = 0
            for i in 0..<p.count {
                guard let d = data(p.lba + i), d.contains(where: { $0 != 0 }) else { continue }
                try pwriteAll(fd, d, i * geo.pageSize, out)
                written += 1
            }
            vols.append(Volume(name: name, image: out, bytes: p.count * geo.pageSize, pagesWritten: written))
        }
        return vols
    }

    /// lpn -> vpn + 1 (0 = unmapped) of the newest copy of every user page.
    static func yaftlMap(_ st: K48NAND.StoreReader) -> [UInt32] {
        let geo = st.geo
        var vpnOf = [UInt32](repeating: 0, count: geo.totalPages), usnOf = [UInt32](repeating: 0, count: geo.totalPages)
        for v in 0..<geo.numBlocks where !geo.ctrlBlocks.contains(v) {
            for j in 0..<geo.ppsublk {
                let vpn = v * geo.ppsublk + j
                let (cs, pp) = geo.vpnToPhys(vpn)
                guard let m = st.meta(cs, pp) else { break }      // pages of a vblock are programmed in order
                let typ = m[9]
                guard typ & K48NAND.tUser != 0, typ & (K48NAND.tIndex | K48NAND.tClosed) == 0 else { continue }
                let lpn = Int(K48NAND.le32(m, 0)), usn = K48NAND.le32(m, 4)
                guard lpn < geo.totalPages else { continue }
                // equal USN: the later vpn (a later page of the same block) wins
                if vpnOf[lpn] == 0 || usn > usnOf[lpn] || (usn == usnOf[lpn] && UInt32(vpn + 1) > vpnOf[lpn]) {
                    vpnOf[lpn] = UInt32(vpn + 1); usnOf[lpn] = usn
                }
            }
        }
        return vpnOf
    }

    // MARK: helpers

    /// A new sparse file of `bytes`, open for writing.
    static func create(_ u: URL, bytes: Int) throws -> Int32 {
        let fd = open(u.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0, ftruncate(fd, off_t(bytes)) == 0 else {
            if fd >= 0 { close(fd) }
            throw FirmwareError(errno == ENOSPC ? .diskFull : .internal, "\(u.path): \(String(cString: strerror(errno)))")
        }
        return fd
    }

    static func pwriteAll(_ fd: Int32, _ b: [UInt8], _ off: Int, _ u: URL) throws {
        let n = b.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, off_t(off)) }
        guard n == b.count else {
            throw FirmwareError(errno == ENOSPC ? .diskFull : .internal, "\(u.path): \(String(cString: strerror(errno)))")
        }
    }

    static func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }
}
