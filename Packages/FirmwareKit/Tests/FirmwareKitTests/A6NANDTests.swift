import Foundation
import Testing
@testable import FirmwareKit

struct A6NANDTests {
    @Test func matchesQualifiedFactoryAllocation() throws {
        // Frozen from the native-qualified 10A405 factory-allocation header.
        #expect(Preparer.sha256(A6NAND.factoryHeader()) == "e78a752b1f3402c36510ffdffa24f90460eb7b513ad6c7b2162240688b339f15")
    }
    @Test func createsErasedSparseBanksAndRefusesOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try A6NAND.create(at: root)
        let h = try FileHandle(forReadingFrom: root.appendingPathComponent("bus1-ce0.pages"))
        defer { try? h.close() }
        let record = try #require(try h.read(upToCount: A6NAND.pageBytes + A6NAND.spareBytes))
        #expect(Data(record.prefix(1536).map { $0 ^ 255 }) == A6NAND.factoryHeader())
        try h.seek(toOffset: 1024 * 1024)
        #expect(try h.read(upToCount: 4096) == Data(repeating: 0, count: 4096))
        #expect(throws: FirmwareError.self) { try A6NAND.create(at: root) }
    }
}
