import Crypto
import Foundation
import Testing
@testable import FirmwareKit

struct SharedCacheSignatureTests {
    private func fixture(scatter: Bool, sha256: Bool = false) -> Data {
        let width = sha256 ? 32 : 20, identifier = scatter ? 96 : 44
        let special = (identifier + 6 + 3) & ~3, hashes = special + width
        let size = hashes + width
        var cache = Data(repeating: 0, count: 4096 + 20 + size)
        cache.replaceSubrange(0..<16, with: Data("dyld_v1  armv7s\0".utf8))
        func put(_ value: Int, _ at: Int, count: Int = 4, big: Bool = true) {
            for i in 0..<count { cache[at + i] = UInt8(truncatingIfNeeded: value >> (8 * (big ? count - 1 - i : i))) }
        }
        put(128, 16, big: false); put(128, 24, big: false)
        put(4096, 40, count: 8, big: false) // legacy zero signature-size field
        put(0xfade0cc0, 4096); put(20 + size, 4100); put(1, 4104); put(20, 4112)
        let cd = 4116
        put(0xfade0c02, cd); put(size, cd + 4); put(scatter ? 0x20100 : 0x20001, cd + 8)
        put(hashes, cd + 16); put(identifier, cd + 20); put(1, cd + 24); put(1, cd + 28); put(4096, cd + 32)
        cache[cd + 36] = UInt8(width); cache[cd + 37] = sha256 ? 2 : 1; cache[cd + 39] = 12
        if scatter {
            put(48, cd + 44); put(1, cd + 48); put(0x20000000, cd + 56, count: 8)
        }
        cache.replaceSubrange((cd + identifier)..<(cd + identifier + 6), with: Data("cache\0".utf8))
        cache.replaceSubrange((cd + special)..<(cd + hashes), with: Data(repeating: 0x6d, count: width))
        return cache
    }

    @Test func refreshesOnlyCodeHashSlots() throws {
        for (scatter, sha256) in [(false, false), (true, false), (true, true)] {
            let source = fixture(scatter: scatter, sha256: sha256)
            let result = try DyldSharedCache(data: source).rehashingCodeSignature()
            let width = sha256 ? 32 : 20, hash = source.count - width
            let digest = sha256 ? Data(SHA256.hash(data: source.prefix(4096))) : Data(Insecure.SHA1.hash(data: source.prefix(4096)))
            #expect(result.prefix(hash) == source.prefix(hash))
            #expect(result.suffix(width) == digest)
            #expect(try DyldSharedCache(data: result).rehashingCodeSignature() == result)
        }
    }

    @Test func rejectsTruncatedAndOverlappingMetadata() throws {
        let source = fixture(scatter: true)
        var badHashOffset = source
        badHashOffset.replaceSubrange(4132..<4136, with: Data([0, 0, 0, 8]))
        #expect(throws: FirmwareError.self) { try DyldSharedCache(data: badHashOffset).rehashingCodeSignature() }
        #expect(throws: FirmwareError.self) { try DyldSharedCache(data: source.dropLast()).rehashingCodeSignature() }
        var badScatter = source
        badScatter.replaceSubrange(4160..<4164, with: Data([0, 0, 0, 8]))
        #expect(throws: FirmwareError.self) { try DyldSharedCache(data: badScatter).rehashingCodeSignature() }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FK_A6_IOS9_CACHE_INPUT"] != nil,
                   "Optional native-qualified 13A344 cache fixture"))
    func matchesQualifiedIOS9CacheRehash() throws {
        let env = ProcessInfo.processInfo.environment
        let input = try #require(env["FK_A6_IOS9_CACHE_INPUT"]), expectedPath = try #require(env["FK_A6_IOS9_CACHE"])
        let source = try Data(contentsOf: URL(fileURLWithPath: input), options: .alwaysMapped)
        let expected = try Data(contentsOf: URL(fileURLWithPath: expectedPath), options: .alwaysMapped)
        #expect(Preparer.sha256(source) == "2e77444ca59aa34e658d4bfab34f129099a2bae86a8cd34baebf011c4f676281")
        let result = try DyldSharedCache(data: source).rehashingCodeSignature()
        let matches = result == expected
        #expect(matches)
        #expect(try A6GuestAssets.verifiedCodeDirectories(result).map(\.hexString) == ["bdde8a7c018c77cd0556f78b893278c75cc81ce7"])
    }
}
