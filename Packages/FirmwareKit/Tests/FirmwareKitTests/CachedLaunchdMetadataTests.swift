import Foundation
import Testing

@testable import FirmwareKit

struct CachedLaunchdMetadataTests {
    @Test func nativePaddingRoundTripsAndRejectsOverflow() throws {
        let plist: [String: Any] = ["VersionNumber": 4, "LaunchDaemons": ["example": ["RunAtLoad": true]]]
        let padded = try LaunchdCache.paddedMetadata(plist, capacity: 4096)
        #expect(padded.count == 4096)
        let parsed = try PropertyListSerialization.propertyList(from: padded, format: nil) as? NSDictionary
        #expect(parsed == plist as NSDictionary)
        #expect(throws: FirmwareError.self) { try LaunchdCache.paddedMetadata(plist, capacity: 40) }
        #expect(throws: FirmwareError.self) {
            try LaunchdCache.updatingCached(Data(count: 112), jobs: [:], removing: [])
        }
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["FK_NATIVE_13A344_CACHE"] != nil,
            "Set FK_NATIVE_13A344_CACHE to original shared cache"))
    func changesOnlyNativeMetadataCacheTypeAndSignatureHashes() throws {
        let source = try #require(ProcessInfo.processInfo.environment["FK_NATIVE_13A344_CACHE"])
        let before = try Data(contentsOf: URL(fileURLWithPath: source))
        let key = "/System/Library/LaunchDaemons/com.qemu.it-agent.plist"
        let job = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.qemu.it-agent", "ExecuteAllowed": true], format: .binary, options: 0)
        let after = try LaunchdCache.updatingCached(before, jobs: [key: job], removing: [])
        #expect(after.count == before.count)
        #expect(after.subdata(in: 104..<112) == Data(count: 8))
        let metadata = 1_874_536..<(1_874_536 + 439704)
        let old = try #require(
            PropertyListSerialization.propertyList(from: before.subdata(in: metadata), format: nil) as? [String: Any])
        let new = try #require(
            PropertyListSerialization.propertyList(from: after.subdata(in: metadata), format: nil) as? [String: Any])
        var expected = old
        var daemons = try #require(old["LaunchDaemons"] as? [String: Any])
        daemons[key] = try PropertyListSerialization.propertyList(from: job, format: nil)
        expected["LaunchDaemons"] = daemons
        #expect(new as NSDictionary == expected as NSDictionary)
        let signature = (0..<8).reduce(0) { $0 | Int(before[40 + $1]) << (8 * $1) }
        #expect(before.prefix(104) == after.prefix(104))
        #expect(before.subdata(in: 112..<metadata.lowerBound) == after.subdata(in: 112..<metadata.lowerBound))
        #expect(
            before.subdata(in: metadata.upperBound..<signature) == after.subdata(in: metadata.upperBound..<signature))
        // Every existing signature page hash is current; no external rehasher.
        #expect(try DyldSharedCache(data: after).rehashingCodeSignature() == after)
    }
}
