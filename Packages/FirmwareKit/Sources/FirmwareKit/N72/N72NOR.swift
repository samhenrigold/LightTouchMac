// N72NOR: the iPod touch 2G (n72ap) 1 MiB SPI NOR, synthesized from an identity. Port of imgtools/build_nor.py
// (synth_base + build, --identity): IMG2 superblock, SysCfg (Mod#, Regn, SrNm, Batt), the IPSW's all_flash img3s
// packed at 0x8000 (padded to the 0x40 granularity, fullSize rewritten, SHSH wrapped under the emulated UID so
// iBoot's in-place unwrap recovers it), and an nvram bank at 0xfc000 (debug-uarts, btaddr, wifiaddr).
//
//   let nor = try N72NOR.build(identity: id, images: [(type, img3)], wrapTypes: nil)   // nil: wrap every image
//   N72NOR.order                       // the stock image set, in the stock order
//   try N72NOR.type(of: img3)          // "illb", "ibot", ...

import Foundation
import zlib

public enum N72NOR {
    static let size = 0x100000, sysCfg = 0x4000, nvram = 0xFC000, nvramBank = 0x2000, img3Header = 0x14
    /// The image types the stock 5F138 NOR carries, in its order (build_nor.DEFAULT_ORDER).
    public static let order = ["illb", "ibot", "dtre", "logo", "nsrv", "bat0", "bat1", "recm", "glyC", "glyP"]
    /// What iBoot runs through the UID key to get the SHSH wrapping key.
    static let kdfConst = Data(hex: "db1f5b33606c5f1c1934aa66589c0661")!
    /// The emulated S5L8720's UID (key_uid in hw/arm/ipod_touch_aes.h).
    static let uidKey = Data(hex: "0123456789ABCDEF0123456789ABCDEF")!

    /// An img3's type tag ("illb", ...), as the header stores it reversed at 0x10.
    public static func type(of img3: Data) throws -> String {
        let d = [UInt8](img3.prefix(img3Header))
        guard d.count == img3Header, d[0..<4] == [0x33, 0x67, 0x6D, 0x49] else { throw FirmwareError(.unsupported, "not an img3") }
        return String(decoding: d[16..<20].reversed(), as: UTF8.self)
    }

    /// build_nor.build over synth_base(identity): the whole NOR. `images` are the all_flash img3s by type;
    /// `wrapTypes` nil wraps every packed image's SHSH (3.x+), ["ibot"] only iBoot's (2.x).
    public static func build(identity id: UnitIdentity, images: [String: Data], types: [String], wrapTypes: [String]?) throws -> Data {
        var nor = try base(id)
        let gran = 0x40, start = gran * 0x200
        if let w = wrapTypes, !Set(w).isSubset(of: types) { throw FirmwareError(.internal, "SHSH wrap types must belong to the selected image set") }
        let key = try AESCBC.crypt(kdfConst, iv: Data(count: 16), key: uidKey, decrypt: true)
        var off = start
        for t in types {
            guard var img = images[t].map({ [UInt8]($0) }) else { throw FirmwareError(.unsupported, "all_flash has no img3 of type \(t)") }
            if wrapTypes?.contains(t) ?? true {
                guard try wrapSHSH(&img, key: key) else { throw FirmwareError(.unsupported, "\(t): no SHSH tag to wrap, or its length is not a multiple of 16") }
            }
            let padded = (img.count + gran - 1) & ~(gran - 1)
            img += [UInt8](repeating: 0, count: padded - img.count)
            put32(&img, 4, UInt32(padded))
            guard off + padded <= nvram else { throw FirmwareError(.unsupported, "NOR image area overflows the nvram partition (\(t))") }
            nor.replaceSubrange(off..<off + padded, with: img)
            off += padded
        }
        put32(&nor, 0x10, UInt32((off + gran - 1) / gran))   // the stock span over-counts by image_start; kept
        put32(&nor, 0x30, crc(nor[0..<0x30]))
        return Data(nor)
    }

    /// Encrypts the SHSH tag (past sigCheckArea, so no digest covers it) under the UID-derived key.
    static func wrapSHSH(_ b: inout [UInt8], key: Data) throws -> Bool {
        let nopack = Int(le32(b, 8))
        var off = img3Header
        while off + 12 <= img3Header + nopack {
            let total = Int(le32(b, off + 4)), dlen = Int(le32(b, off + 8))
            if total == 0 { break }
            if b[off..<off + 4].elementsEqual("HSHS".utf8), dlen % 16 == 0 {
                let enc = try AESCBC.crypt(Data(b[off + 12..<off + 12 + dlen]), iv: Data(count: 16), key: key, decrypt: false)
                b.replaceSubrange(off + 12..<off + 12 + dlen, with: enc)
                return true
            }
            off += total
        }
        return false
    }

    /// synth_base: IMG2 + SysCfg + nvram for the identity, an empty image area.
    static func base(_ id: UnitIdentity) throws -> [UInt8] {
        var nor = [UInt8](repeating: 0, count: size)
        nor.replaceSubrange(0..<4, with: Array("2GMI".utf8))
        put32(&nor, 4, 0x40); put32(&nor, 8, 0); put32(&nor, 12, 0x200)
        nor.replaceSubrange(sysCfg..<sysCfg + 4, with: Array("gfCS".utf8))
        for (i, v) in [0xC8, 0x2000, 0x00010001, 0, 4].enumerated() { put32(&nor, sysCfg + 4 + 4 * i, UInt32(v)) }
        for (i, (tag, key)) in [("Mod#", "model-number"), ("Regn", "region-info"), ("SrNm", "serial-number"), ("Batt", "battery-serial")].enumerated() {
            let value = Array((id[key] ?? "").utf8)
            guard value.count <= 16 else { throw FirmwareError(.unsupported, "\(key) is longer than a SysCfg value") }
            let o = sysCfg + 0x18 + i * 0x14
            nor.replaceSubrange(o..<o + 20, with: Array(tag.utf8).reversed() + value + [UInt8](repeating: 0, count: 16 - value.count))
        }
        let bank = try nvramBank([("debug-uarts", "1"), ("btaddr", (id["bt-mac"] ?? "").uppercased()), ("wifiaddr", (id["wifi-mac"] ?? "").uppercased())])
        nor.replaceSubrange(nvram..<nvram + nvramBank, with: bank)
        put32(&nor, 0x30, crc(nor[0..<0x30]))
        return nor
    }

    /// A CHRP nvram partition header: signature, checksum, length in 16-byte units, 12-byte name.
    static func chrp(_ sig: UInt8, _ length: Int, _ name: String) -> [UInt8] {
        var h: [UInt8] = [sig, 0, UInt8((length / 16) & 0xFF), UInt8((length / 16) >> 8)] + Array(name.utf8) + [UInt8](repeating: 0, count: 12 - name.utf8.count)
        var s = 0
        for b in [h[0]] + h[2...] {
            s += Int(b)
            if s > 0xFF { s = (s & 0xFF) + 1 }
        }
        h[1] = UInt8(s)
        return h
    }

    /// One 8 KiB bank as iBoot writes it: "nvram" (adler32 of the rest, generation), "common", an empty
    /// "APL,OSXPanic" and the free-space partition.
    static func nvramBank(_ common: [(String, String)]) throws -> [UInt8] {
        var bank = [UInt8](repeating: 0, count: nvramBank)
        bank.replaceSubrange(0..<16, with: chrp(0x5A, 0x20, "nvram"))
        put32(&bank, 0x14, 0x10)
        let body: [UInt8] = common.flatMap { kv -> [UInt8] in Array("\(kv.0)=\(kv.1)".utf8) + [0] }
        guard body.count <= 0x800 - 16 else { throw FirmwareError(.unsupported, "nvram common partition overflows") }
        bank.replaceSubrange(0x20..<0x30, with: chrp(0x70, 0x800, "common"))
        bank.replaceSubrange(0x30..<0x30 + body.count, with: body)
        bank.replaceSubrange(0x820..<0x830, with: chrp(0xA1, 0x810, "APL,OSXPanic"))
        bank.replaceSubrange(0x1030..<0x1040, with: chrp(0x7F, nvramBank - 0x1030, String(repeating: "w", count: 12)))
        put32(&bank, 0x10, Adler32.checksum(Data(bank[0x14...])))
        return bank
    }

    static func crc(_ b: ArraySlice<UInt8>) -> UInt32 {
        UInt32(b.withUnsafeBufferPointer { zlib.crc32(0, $0.baseAddress, uInt($0.count)) })
    }
}

fileprivate func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
    for k in 0..<4 { b[o + k] = UInt8(truncatingIfNeeded: v >> (8 * k)) }
}

fileprivate func le32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
