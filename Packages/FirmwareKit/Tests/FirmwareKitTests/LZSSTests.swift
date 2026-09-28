import Foundation
import Testing
@testable import FirmwareKit

struct LZSSTests {
    @Test func vectors() {
        #expect(LZSS.decompress([0xFF] + Array("abcdefgh".utf8)) == Data("abcdefgh".utf8))
        // an overlapping match: literal "ab", then 6 bytes from 2 back -> "abababab"
        #expect(LZSS.decompress([0b011, 0x61, 0x62, 0xEE, 0xF3], windowFill: 0) == Data("abababab".utf8))
        // a match before any output reads the window's fill: spaces (kernelcache) or zeros (iBootIm)
        #expect(LZSS.decompress([0x00, 0x00, 0x00]) == Data("   ".utf8))
        #expect(LZSS.decompress([0x00, 0x00, 0x00], windowFill: 0) == Data(count: 3))
        #expect(Adler32.checksum(Data("Wikipedia".utf8)) == 0x11E6_0398)
        #expect(Adler32.checksum(Data(repeating: 0xFF, count: 100_000)) == 0x149A_302C)   // zlib.adler32
    }

    @Test func complzssChecksLengthAndAdler() throws {
        let plain = Data("hello hello".utf8)
        let be = { (v: UInt32) in Data([UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
        let stream = Data([0xFF] + Array("hello he".utf8) + [0x07] + Array("llo".utf8))
        func payload(_ adler: UInt32) -> Data {
            var p = Data("complzss".utf8) + be(adler) + be(UInt32(plain.count)) + be(UInt32(stream.count))
            p += Data(count: 0x180 - p.count)
            return p + stream + Data(count: 32)   // trailing padding is ignored (clen bounds the stream)
        }
        #expect(try LZSS.complzss(payload(Adler32.checksum(plain))) == plain)
        #expect(throws: FirmwareError.self) { try LZSS.complzss(payload(1)) }
    }

    /// ipad1_kboot.selfcheck's logo: a 2x1 iBootIm, left pixel opaque white, right transparent.
    @Test func logoIsCentredAndTurned() throws {
        var blob = Data("iBootIm\0".utf8) + Data(count: 4) + Data("sszlyerg".utf8) + Data([2, 0, 1, 0])
        blob += Data(count: 0x40 - blob.count)
        blob += Data([0xFF, 255, 0, 255, 255])
        let segs = try BootLogo.segments(iBootIm: blob, framebufferPA: 0x4F70_0000)
        #expect(segs.count == 2)
        #expect(segs[0] == KBoot.Segment(pa: 0x4F70_0000, length: 1024 * 768 * 4, data: nil))
        let x0 = (1024 - 1) / 2, y0 = (768 - 2) / 2
        #expect(segs[1].pa == 0x4F70_0000 + UInt32(y0 * 4096) && segs[1].length == 1024 * 4 * 2)
        let rows = [UInt8](segs[1].data!)
        // turned a quarter counter-clockwise: the logo's top row becomes its left column, its left end the bottom
        #expect(Array(rows[x0 * 4..<x0 * 4 + 4]) == [0x00, 0x00, 0x00, 0xFF])               // row 0 <- logo x 1 (clear)
        #expect(Array(rows[4096 + x0 * 4..<4096 + x0 * 4 + 4]) == [0xFF, 0xFF, 0xFF, 0xFF])  // row 1 <- logo x 0 (white)
    }
}
