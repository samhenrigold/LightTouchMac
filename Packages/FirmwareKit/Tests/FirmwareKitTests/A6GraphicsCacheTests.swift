import Foundation
import Testing

@testable import FirmwareKit

struct A6GraphicsCacheTests {
    @Test func rejectsUnknownIOS10CacheAndLeavesOtherBuildsAlone() throws {
        let bytes = Data(repeating: 1, count: 112)
        #expect(throws: FirmwareError.self) { try A6GraphicsCache.prepare(bytes, build: "14G61") }
        #expect(try A6GraphicsCache.prepare(bytes, build: "13A344") == bytes)
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["FK_A6_GRAPHICS_CACHE_14G61"] != nil,
            "Set path to the original 14G61 cache; no Apple fixture is distributed"))
    func changesOnlyCacheTypeAndExistingSignatureHashes() throws {
        let path = try #require(ProcessInfo.processInfo.environment["FK_A6_GRAPHICS_CACHE_14G61"])
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let prepared = try A6GraphicsCache.prepare(original, build: "14G61")
        let signature = (0..<8).reduce(0) { $0 | Int(original[40 + $1]) << ($1 * 8) }
        #expect(prepared[104..<112] == Data(count: 8))
        #expect(prepared.prefix(104) == original.prefix(104))
        #expect(prepared[112..<signature] == original[112..<signature])
        #expect(prepared.count == original.count)
        #expect(try DyldSharedCache(data: prepared).rehashingCodeSignature() == prepared)
        #expect(try A6GraphicsCache.prepare(prepared, build: "14G61") == prepared)
        #expect(try A6GuestAssets.verifiedCodeDirectories(prepared).count > 0)
    }
}
