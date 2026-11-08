// UDIF: the raw HFS+ volume out of a (decrypted) IPSW rootfs DMG. Ports ipad1_rootfs.extract_rootfs and
// apm_hfs_slice: UDIFReader (the offline volume backend) or DiskImage.convertToRaw (hdiutil UDTO / diskutil RAW)
// makes the raw disk, then its HFS partition (Apple Partition Map or GPT) is copied out. A source that
// already is a bare HFS volume is copied as is.
//
//   try await UDIF.extractRootfs(dmg: rootfsDMG, to: rawVolume)             // work files go next to `to`
//   try APM.hfsSlice(headerBytes)                                     // (offset, length) in bytes

import BinaryParsing
import Foundation

public enum UDIF {
    public static func extractRootfs(
        dmg src: URL,
        to out: URL,
        backend: VolumeMount.Backend = VolumeMount.backend
    ) async throws {
        let fm = FileManager.default
        if let h = try? FileHandle(forReadingFrom: src) {
            defer { try? h.close() }
            try h.seek(toOffset: 1024)
            if let sig = try h.read(upToCount: 2), sig == Data("H+".utf8) || sig == Data("HX".utf8) {
                try? fm.removeItem(at: out)
                try fm.copyItem(at: src, to: out)  // clonefile on APFS
                return
            }
        }
        let work = out.deletingLastPathComponent().appendingPathComponent(".udif-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let raw = work.appendingPathComponent("raw")
        if backend == .writer {
            try UDIFReader.convertToRaw(src, to: raw)
        } else {
            try await DiskImage.convertToRaw(src, to: raw)
        }
        let f = try FileHandle(forReadingFrom: raw)
        defer { try? f.close() }
        let size = try f.seekToEnd()
        try f.seek(toOffset: 0)
        let header = try f.read(upToCount: 1 << 20) ?? Data()
        let (off, len) = header.count >= 520 && header[512..<520] == Data("EFI PART".utf8)
            ? try GPT.hfsSlice(header, diskBytes: size)
            : try APM.hfsSlice(header)
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
        // the driver descriptor ("ER", the block size); from block 1 a map entry a block: "PM", a pad, the map's entry
        // count, the partition's start block and block count, its name and type (32 bytes each, from 16)
        try parsing(raw, "Apple partition map") { s in
            guard s.count >= 4, try s.bytes(at: 0, 2) == [0x45, 0x52] else {
                throw FirmwareError(.unsupported, "not an Apple partition map")
            }
            try s.seek(toRelativeOffset: 2)
            let bs = Int(try UInt16(parsingBigEndian: &s))
            guard bs >= 80 else { throw FirmwareError(.unsupported, "Apple partition map block size \(bs)") }
            var map = try s.seeking(toAbsoluteOffset: bs)
            let n = Int(try map.be32(at: 4))
            for _ in 1...max(n, 1) {
                guard var entry = try? map.sliceSpan(byteCount: bs) else { break }
                try entry.seek(toRelativeOffset: 8)
                let start = Int(try UInt32(parsingBigEndian: &entry))
                let count = Int(try UInt32(parsingBigEndian: &entry))
                try entry.seek(toRelativeOffset: 32)
                let type = try [UInt8](parsing: &entry, byteCount: 32).prefix { $0 != 0 }
                if type.elementsEqual("Apple_HFSX".utf8) || type.elementsEqual("Apple_HFS".utf8) {
                    return (start * bs, count * bs)
                }
            }
            throw FirmwareError(.unsupported, "no Apple_HFS(X) partition")
        }
    }
}
