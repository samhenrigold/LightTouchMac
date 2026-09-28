// LZSS: Apple's LZSS (4 KiB window, 18-byte matches), the complzss kernelcache wrapper, Adler-32, and
// the iBootIm boot logo. Ports ipad1_fw.lzss/complzss and ipad1_kboot.lzss/logo_segments.
//
//   LZSS.decompress(bytes, windowFill: 0x20)    // raw LZSS stream
//   try LZSS.complzss(payload)                  // "complzss" header; length and Adler-32 checked
//   Adler32.checksum(data)
//   try BootLogo.segments(iBootIm: blob, framebufferPA: KBoot.vramPA)   // [KBoot.Segment], centred on black

import Foundation

public enum LZSS {
    /// `windowFill` is the window's initial byte: spaces for kernelcaches (ipad1_fw), zeros for iBootIm
    /// (ipad1_kboot); it shows through only when a match reaches back before the first output byte.
    public static func decompress<C: Collection>(_ src: C, windowFill: UInt8 = 0x20) -> Data where C.Element == UInt8 {
        let s = Array(src)
        var ring = [UInt8](repeating: windowFill, count: 4096), r = 4096 - 18
        var out = [UInt8](), flags = 0, i = 0
        out.reserveCapacity(s.count * 2)
        while i < s.count {
            flags >>= 1
            if flags & 0x100 == 0 {
                flags = Int(s[i]) | 0xFF00
                i += 1
            }
            if flags & 1 != 0, i < s.count {
                let c = s[i]
                i += 1
                out.append(c); ring[r] = c; r = (r + 1) & 0xFFF
            } else if flags & 1 == 0, i + 1 < s.count {
                let pos = Int(s[i]) | (Int(s[i + 1]) & 0xF0) << 4, n = (Int(s[i + 1]) & 0x0F) + 3
                i += 2
                for k in 0..<n {   // byte by byte: a match may overlap what it is writing
                    let c = ring[(pos + k) & 0xFFF]
                    out.append(c); ring[r] = c; r = (r + 1) & 0xFFF
                }
            } else {
                break
            }
        }
        return Data(out)
    }

    /// A complzss payload (decrypted kernelcache): header "complzss", adler32, ulen, clen (big-endian); data at 0x180.
    public static func complzss(_ payload: Data) throws -> Data {
        let p = [UInt8](payload.prefix(0x180))
        guard p.count >= 20, p[0..<8].elementsEqual("complzss".utf8) else { throw FirmwareError(.unsupported, "not complzss") }
        let be = { (o: Int) in UInt32(p[o]) << 24 | UInt32(p[o + 1]) << 16 | UInt32(p[o + 2]) << 8 | UInt32(p[o + 3]) }
        let adler = be(8), ulen = Int(be(12)), clen = Int(be(16))
        let body = payload.dropFirst(0x180).prefix(clen)
        let out = decompress(body)
        guard out.count == ulen, Adler32.checksum(out) == adler else {
            throw FirmwareError(.unsupported, "kernelcache checksum mismatch")
        }
        return out
    }
}

public enum Adler32 {
    public static func checksum(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var i = 0
            while i < buf.count {
                let end = Swift.min(i + 5552, buf.count)   // zlib's NMAX: no UInt32 overflow before the modulo
                while i < end { a &+= UInt32(buf[i]); b &+= a; i += 1 }
                a %= 65521; b %= 65521
            }
        }
        return b << 16 | a
    }
}

public enum BootLogo {
    /// Framebuffer segments that put an iBootIm logo where iBoot puts it: centred on black.
    ///
    /// iBootIm: "iBootIm\0", adler32, "lzss", format tag (only "grey": grey + inverted alpha, composited
    /// over black), u16 width, height; LZSS data at 0x40. The panel scans out landscape with portrait UI
    /// turned a quarter counter-clockwise into it (its top along the panel's left edge; the app turns the
    /// panel a quarter clockwise to stand it up), so the logo is turned the same way.
    public static func segments(iBootIm blob: Data, framebufferPA fb: UInt32,
                                width fbW: Int = KBoot.fbWidth, height fbH: Int = KBoot.fbHeight) throws -> [KBoot.Segment] {
        let b = [UInt8](blob)
        guard b.count >= 0x40, b[0..<8].elementsEqual("iBootIm\0".utf8), b[12..<16].elementsEqual("sszl".utf8) else {
            throw FirmwareError(.unsupported, "not an LZSS iBootIm")
        }
        guard b[16..<20].elementsEqual("yerg".utf8) else { throw FirmwareError(.unsupported, "only the grey iBootIm format is handled") }
        let w = Int(b[20]) | Int(b[21]) << 8, h = Int(b[22]) | Int(b[23]) << 8
        let px = [UInt8](LZSS.decompress(b[0x40...], windowFill: 0))
        guard px.count >= w * h * 2 else { throw FirmwareError(.unsupported, "short iBootIm") }
        let x0 = (fbW - h) / 2, y0 = (fbH - w) / 2, stride = fbW * 4
        guard x0 >= 0, y0 >= 0 else { throw FirmwareError(.unsupported, "iBootIm larger than the framebuffer") }
        var rows = [UInt8](repeating: 0, count: stride * w)
        for ly in 0..<h {
            for lx in 0..<w {
                let grey = UInt32(px[(ly * w + lx) * 2]), clear = UInt32(px[(ly * w + lx) * 2 + 1])
                let v = grey * (255 - clear) / 255, pixel = 0xFF00_0000 | v * 0x010101
                let at = (w - 1 - lx) * stride + (x0 + ly) * 4
                rows[at] = UInt8(pixel & 0xFF); rows[at + 1] = UInt8(pixel >> 8 & 0xFF)
                rows[at + 2] = UInt8(pixel >> 16 & 0xFF); rows[at + 3] = 0xFF
            }
        }
        return [KBoot.Segment(pa: fb, length: UInt32(stride * fbH), data: nil),
                KBoot.Segment(pa: fb + UInt32(y0 * stride), length: UInt32(rows.count), data: Data(rows))]
    }
}
