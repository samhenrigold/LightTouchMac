import Foundation
import Testing

@testable import FirmwareKit

struct A6StorageLayoutTests {
    private func word(_ bytes: Data, _ offset: Int) -> UInt64 {
        (0..<4).reduce(0) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
    }

    @Test func sixteenGBMediaIsCompletelyPartitioned() throws {
        let plan = try A6StorageLayout()
        #expect(plan.systemOffset == 16_777_216)
        #expect(plan.systemBytes == 3_221_225_472)
        #expect(plan.dataOffset == 3_238_002_688)
        #expect(plan.dataBytes == 12_761_997_312)
        #expect(plan.dataOffset + plan.dataBytes == plan.mediaBytes)
        let table = plan.partitionTable()
        #expect(table.count == 4096 && table[510] == 0x55 && table[511] == 0xaa)
        #expect(table[450] == 0xaf && table[466] == 0xaf)
        #expect(word(table, 454) == 4096 && word(table, 458) == 786432)
        #expect(word(table, 470) == 790528 && word(table, 474) == 3_115_722)
        #expect(table[478..<510] == Data(repeating: 0, count: 32))
        #expect((word(table, 470) + word(table, 474)) * 4096 == plan.mediaBytes)
    }

    @Test func smallerSystemAndDifferentMediaStillFillData() throws {
        let older = try A6StorageLayout(systemBytes: 2 << 30)
        #expect(older.dataBytes == 13_835_739_136)
        let binaryCapacity = try A6StorageLayout(mediaBytes: 16 << 30)
        #expect(binaryCapacity.dataOffset + binaryCapacity.dataBytes == 16 << 30)
    }

    @Test func refusesTruncationOverlapAndInvalidSectorGeometry() {
        for (media, system) in [
            (UInt64(16_000_000_000), UInt64(0)),
            (16_000_000_000, 4097), (16_000_000_001, 3 << 30),
            (16 << 20, 4096), (16_000_000_000, UInt64.max),
            (UInt64.max - 4095, 3 << 30)
        ] {
            #expect(throws: FirmwareError.self) { try A6StorageLayout(mediaBytes: media, systemBytes: system) }
        }
    }
}
