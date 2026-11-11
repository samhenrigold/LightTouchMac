import Foundation
import Testing

@testable import FirmwareKit

struct GPTTests {
    private func fixture(first: UInt64 = 40, last: UInt64 = 899) -> Data {
        var b = Data(count: 4096)
        func put(_ at: Int, _ value: UInt64, _ count: Int) {
            for i in 0..<count { b[at + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        b.replaceSubrange(512..<520, with: Data("EFI PART".utf8))
        put(520, 0x10000, 4)
        put(524, 92, 4)
        put(536, 1, 8)
        put(552, 34, 8)
        put(560, 966, 8)
        put(584, 2, 8)
        put(592, 2, 4)
        put(596, 128, 4)
        // Skip a different partition before the HFS entry.
        b[1024] = 1
        b.replaceSubrange(1152..<1168, with: GPT.hfsType)
        put(1184, first, 8)
        put(1192, last, 8)
        put(600, UInt64(GPT.checksum(b.subdata(in: 1024..<1280))), 4)
        put(528, UInt64(GPT.checksum(b.subdata(in: 512..<604))), 4)
        return b
    }

    @Test func selectsHFS() throws {
        #expect(try GPT.hfsSlice(fixture(), diskBytes: 1000 * 512) == (40 * 512, 860 * 512))
    }

    @Test(arguments: [0, 1, 2, 3, 4]) func rejectsDamagedTable(_ damage: Int) {
        var b = fixture()
        switch damage {
        case 0: b[540] ^= 1  // primary header checksum
        case 1: b[1152] ^= 1  // table checksum
        case 2: b = Data(b.prefix(1200))  // short table
        case 3: b = fixture(first: 10)  // overlaps table / reserved sectors
        default: b = fixture(last: 1001)  // beyond disk
        }
        #expect(throws: FirmwareError.self) { try GPT.hfsSlice(b, diskBytes: 1000 * 512) }
    }
}
