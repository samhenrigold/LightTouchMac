// UDIF: the raw HFS+ volume out of a (decrypted) IPSW rootfs DMG. Ports ipad1_rootfs.extract_rootfs and
// apm_hfs_slice: DiskImage.convertToRaw (hdiutil UDTO / diskutil RAW) makes the raw disk, then the Apple_HFS(X) partition of its
// Apple Partition Map is copied out. A source that already is a bare HFS volume is copied as is.
//
//   try UDIF.extractRootfs(dmg: rootfsDMG, to: rawVolume)             // work files go next to `to`
//   try APM.hfsSlice(headerBytes)                                     // (offset, length) in bytes

import Foundation

public enum UDIF {
    public static func extractRootfs(dmg src: URL, to out: URL) throws {
        let fm = FileManager.default
        if let h = try? FileHandle(forReadingFrom: src) {
            defer { try? h.close() }
            try h.seek(toOffset: 1024)
            if let sig = try h.read(upToCount: 2), sig == Data("H+".utf8) || sig == Data("HX".utf8) {
                try? fm.removeItem(at: out)
                try fm.copyItem(at: src, to: out)   // clonefile on APFS
                return
            }
        }
        let work = out.deletingLastPathComponent().appendingPathComponent(".udif-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let raw = work.appendingPathComponent("raw")
        try DiskImage.convertToRaw(src, to: raw)
        let f = try FileHandle(forReadingFrom: raw)
        defer { try? f.close() }
        let (off, len) = try APM.hfsSlice(f.read(upToCount: 64 * 512) ?? Data())
        try f.seek(toOffset: UInt64(off))
        guard fm.createFile(atPath: out.path, contents: nil), let o = FileHandle(forWritingAtPath: out.path) else {
            throw FirmwareError(.internal, "cannot create \(out.path)")
        }
        defer { try? o.close() }
        var left = len
        while left > 0 {
            guard let chunk = try f.read(upToCount: min(left, 1 << 24)), !chunk.isEmpty else {
                throw FirmwareError(.unsupported, "\(raw.lastPathComponent) ends inside its HFS partition")
            }
            try o.write(contentsOf: chunk)
            left -= chunk.count
        }
    }
}

public enum APM {
    /// (byte offset, byte length) of the Apple_HFS(X) partition in an Apple Partition Map.
    public static func hfsSlice(_ raw: Data) throws -> (offset: Int, length: Int) {
        let r = [UInt8](raw)
        let be16 = { (o: Int) in Int(r[o]) << 8 | Int(r[o + 1]) }
        let be32 = { (o: Int) in Int(r[o]) << 24 | Int(r[o + 1]) << 16 | Int(r[o + 2]) << 8 | Int(r[o + 3]) }
        guard r.count >= 4, r[0] == 0x45, r[1] == 0x52 else { throw FirmwareError(.unsupported, "not an Apple partition map") }
        let bs = be16(2)
        guard bs > 0, r.count >= bs + 8 else { throw FirmwareError(.unsupported, "truncated Apple partition map") }
        let n = be32(bs + 4)
        for i in 1...max(n, 1) where bs * (i + 1) <= r.count {
            let e = bs * i
            let type = r[e + 48..<e + 80].split(separator: 0, omittingEmptySubsequences: false).first ?? []
            if type.elementsEqual("Apple_HFSX".utf8) || type.elementsEqual("Apple_HFS".utf8) {
                return (be32(e + 8) * bs, be32(e + 12) * bs)
            }
        }
        throw FirmwareError(.unsupported, "no Apple_HFS(X) partition")
    }
}
