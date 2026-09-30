// N45NOR: the iPod touch 1G (n45ap) 1 MiB NOR. Port of devos50's qemu-ios-generate-nor (branch ipod_touch_1g,
// generate_nor.c + aes.c): SysCfg at 0x4000 (N72NOR's block), the IMG2 directory header at 0x8400, the IPSW's
// all_flash IMG2 images from block 1040 on (0x40-byte blocks, five spare blocks after each), each re-signed the
// way a restore does on the device, and the nvram bank at 0xfc000 (boot-args).
//
//   let nor = try N45NOR.build(identity: id, images: ["dtre": img2Body, ...])   // IMG2 bodies (8900 payloads)
//
// Re-signing: the header and data hashes are SHA-1s encrypted under the IMG2 verify key, which the device
// derives from its UID. The emulated S5L8900's UID engine (qemu-ios ipod_touch_aes.c `s5l8900-compat`, docs/
// smoke.md #11) keeps devos50's convention: key 0123456789ABCDEF x2, and encryption run with the *decryption*
// key schedule (OpenSSL AES_set_decrypt_key + AES_cbc_encrypt(..., AES_ENCRYPT)), so CommonCrypto cannot do it
// and S5L8900UID below carries a small AES core.

import CryptoKit
import Foundation
import zlib

public enum N45NOR {
    static let size = 0x100000, block = 0x40, directory = 0x8400, firstBlock = 1040, nvram = 0xFC000
    /// generate_nor.c's image order. LLB and iBoot stay out: the machine enters iBoot-204 itself.
    public static let order = ["dtre", "batC", "logo", "nsrv", "batl", "batL", "recm"]
    /// generate_nor.c's nvram boot-args (the kernel's serial console, root on the NAND's first partition).
    public static let bootArgs = "debug=0x8 kextlog=0xfff cpus=1 rd=disk0s1 serial=1 io=0xffff8fff"
    static let hashPadding = [UInt8](Data(hex: "ad2ee38d2d9be43599044433653df07498d8563b4ff96a5545ce82f29a5ac2bc47616d654f766572a6a09913")!)

    /// `images`: IMG2 bodies by type (every `order` type must be there).
    public static func build(identity id: UnitIdentity, images: [String: Data], bootArgs: String = bootArgs) throws -> Data {
        var nor = [UInt8](repeating: 0, count: size)
        try N72NOR.writeSysCfg(&nor, id)
        nor.replaceSubrange(directory..<directory + 4, with: Array("2GMI".utf8))
        put32(&nor, directory + 4, UInt32(block)); put32(&nor, directory + 8, UInt32(firstBlock)); put32(&nor, directory + 16, 512 * 1024)
        put32(&nor, directory + 0x30, crc(nor[directory..<directory + 0x30]))
        var off = firstBlock * block
        for t in order {
            guard let body = images[t] else { throw FirmwareError(.unsupported, "all_flash has no IMG2 of type \(t)") }
            let img = try sign([UInt8](body))
            guard off + img.count <= nvram else { throw FirmwareError(.unsupported, "NOR image area overflows the nvram partition (\(t))") }
            nor.replaceSubrange(off..<off + img.count, with: img)
            off += (img.count / block + 5) * block
        }
        // iBoot-204 fills arm-io/sdio's local-mac-address from nvram wifiaddr (its SysCfg fallback is a stub
        // returning 0, so without it the DT keeps zeros and lockdownd hashes 00:00:00:00:00:00 into the UDID).
        nor.replaceSubrange(nvram..<nvram + N72NOR.nvramBank, with: try N72NOR.nvramBank([("boot-args", bootArgs)]
            + (id["wifi-mac"].map { [("wifiaddr", $0.uppercased())] } ?? [])))
        return Data(nor)
    }

    /// add_img2: block count, the trusted-write and encrypted flags, data hash, header CRC, extension CRC, header hash.
    static func sign(_ b: [UInt8]) throws -> [UInt8] {
        var b = b
        guard b.count >= IMG2.headerSize else { throw FirmwareError(.unsupported, "IMG2 shorter than its header") }
        let padded = Int(le32(b, 0x10))
        guard IMG2.headerSize + padded <= b.count else { throw FirmwareError(.unsupported, "IMG2 data runs past the image") }
        put32(&b, 0x18, UInt32(b.count / block + 5))
        let flags = le32(b, 0x1C) | 1 << 24 | 1 << 1
        put32(&b, 0x1C, flags)
        let dataHash = Array(Insecure.SHA1.hash(data: b[IMG2.headerSize..<IMG2.headerSize + padded])) + hashPadding.prefix(44)
        b.replaceSubrange(0x20..<0x60, with: S5L8900UID.img2VerifyEncrypt(dataHash))
        put32(&b, 0x64, crc(b[0..<0x64]))
        if flags & 1 << 30 != 0 {
            let next = Int(le32(b, 0x60))
            guard 0x6C + next <= IMG2.headerSize else { throw FirmwareError(.unsupported, "IMG2 extension runs past the header") }
            put32(&b, 0x68, crc(b[0x6C..<0x6C + next]))
        }
        let headerHash = Array(Insecure.SHA1.hash(data: b[0..<0x3E0])) + hashPadding.prefix(12)
        b.replaceSubrange(0x3E0..<0x400, with: S5L8900UID.img2VerifyEncrypt(headerHash))
        return b
    }

    static func crc(_ b: ArraySlice<UInt8>) -> UInt32 { UInt32(b.withUnsafeBufferPointer { zlib.crc32(0, $0.baseAddress, uInt($0.count)) }) }
}

/// The emulated S5L8900 UID engine's convention (see N45NOR), for the IMG2 verify key only.
enum S5L8900UID {
    static let uid = [UInt8](Data(hex: "0123456789ABCDEF0123456789ABCDEF")!)
    static let verifySeed = [UInt8](Data(hex: "CDF345B312E748858BBE2147F0E58088")!)
    static let verifyIV = [UInt8](Data(hex: "115D7041824B986FBB996C9C6978F1A5")!)

    /// aes_setup: the verify key is the seed run through the UID (CBC, verifyIV), each word byte-swapped.
    static let verifyKey: [UInt8] = {
        let k = AESCore(key: uid).cbcEncrypt(verifySeed, iv: verifyIV)
        return stride(from: 0, to: 16, by: 4).flatMap { k[$0..<$0 + 4].reversed() }
    }()
    /// aes_img2verify_encrypt: a 256-bit custom key of 16 zero bytes then the verify key, zero IV.
    static let verify = AESCore(key: [UInt8](repeating: 0, count: 16) + verifyKey)

    static func img2VerifyEncrypt(_ d: [UInt8]) -> [UInt8] { verify.cbcEncrypt(d, iv: [UInt8](repeating: 0, count: 16)) }
}

/// AES encryption rounds over the *decryption* key schedule (OpenSSL's AES_set_decrypt_key: the encryption
/// round keys reversed, InvMixColumns on all but the first and last). Byte-oriented; only NOR signing uses it.
struct AESCore {
    static let sbox: [UInt8] = {
        var s = [UInt8](repeating: 0, count: 256)
        for x in 0..<256 {
            var inv: UInt8 = 0
            if x != 0 { for y in 1..<256 where mul(UInt8(x), UInt8(y)) == 1 { inv = UInt8(y); break } }
            var r = inv
            for i in 1...4 { r ^= inv << i | inv >> (8 - i) }
            s[x] = r ^ 0x63
        }
        return s
    }()

    static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var a = a, b = b, p: UInt8 = 0
        while b != 0 {
            if b & 1 != 0 { p ^= a }
            a = a << 1 ^ (a & 0x80 != 0 ? 0x1B : 0)
            b >>= 1
        }
        return p
    }

    /// Round keys, 16 bytes each, rounds + 1 of them.
    let keys: [[UInt8]]

    init(key: [UInt8]) {
        let nk = key.count / 4, rounds = nk + 6
        var w = stride(from: 0, to: key.count, by: 4).map { Array(key[$0..<$0 + 4]) }
        var rcon: UInt8 = 1
        for i in nk..<4 * (rounds + 1) {
            var t = w[i - 1]
            if i % nk == 0 {
                t = [t[1], t[2], t[3], t[0]].map { Self.sbox[Int($0)] }
                t[0] ^= rcon
                rcon = Self.mul(rcon, 2)
            } else if nk > 6, i % nk == 4 {
                t = t.map { Self.sbox[Int($0)] }
            }
            w.append(zip(w[i - nk], t).map { $0 ^ $1 })
        }
        let enc = (0...rounds).map { Array(w[4 * $0..<4 * $0 + 4].joined()) }
        keys = enc.reversed().enumerated().map { r, k in
            r == 0 || r == rounds ? k : stride(from: 0, to: 16, by: 4).flatMap { Self.invMix(Array(k[$0..<$0 + 4])) }
        }
    }

    static func invMix(_ c: [UInt8]) -> [UInt8] {
        (0..<4).map { i in mul(c[i], 14) ^ mul(c[(i + 1) % 4], 11) ^ mul(c[(i + 2) % 4], 13) ^ mul(c[(i + 3) % 4], 9) }
    }

    func encryptBlock(_ input: [UInt8]) -> [UInt8] {
        let rounds = keys.count - 1
        var s = zip(input, keys[0]).map { $0 ^ $1 }
        for r in 1...rounds {
            s = s.map { Self.sbox[Int($0)] }
            s = (0..<16).map { s[($0 + 4 * ($0 % 4)) % 16] }   // ShiftRows over column-major state
            if r != rounds {
                s = stride(from: 0, to: 16, by: 4).flatMap { c -> [UInt8] in
                    let a = Array(s[c..<c + 4])
                    return (0..<4).map { i in Self.mul(a[i], 2) ^ Self.mul(a[(i + 1) % 4], 3) ^ a[(i + 2) % 4] ^ a[(i + 3) % 4] }
                }
            }
            s = zip(s, keys[r]).map { $0 ^ $1 }
        }
        return s
    }

    func cbcEncrypt(_ d: [UInt8], iv: [UInt8]) -> [UInt8] {
        var prev = iv, out: [UInt8] = []
        for o in stride(from: 0, to: d.count, by: 16) {
            prev = encryptBlock(zip(d[o..<o + 16], prev).map { $0 ^ $1 })
            out += prev
        }
        return out
    }
}

fileprivate func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
    for k in 0..<4 { b[o + k] = UInt8(truncatingIfNeeded: v >> (8 * k)) }
}

fileprivate func le32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
