import Foundation
import Testing

@testable import FirmwareKit

struct A6GuestAssetsTests {
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["FK_A6_RESTORE_SYSTEM"] != nil,
            "Set native iOS 10 System, restore RAM disk and original kernel paths"))
    func includesStagedRestoreExecutables() throws {
        let env = ProcessInfo.processInfo.environment
        let system = URL(fileURLWithPath: try #require(env["FK_A6_RESTORE_SYSTEM"]))
        let ramdisk = URL(fileURLWithPath: try #require(env["FK_A6_RESTORE_RAMDISK"]))
        let kernel = try Data(contentsOf: URL(fileURLWithPath: #require(env["FK_A6_ORIGINAL_KERNEL"])))
        let prepared = try A6GuestAssets.prepare(kernel: kernel, system: system, restoreRAMDisk: ramdisk)
        let restore = try HFSPlusVolume(ramdisk)
        let helpers = prepared.assets.filter { $0.path.hasPrefix("restore:/") }
        #expect(helpers.count == 2)
        for row in helpers {
            let path = String(row.path.dropFirst("restore:/".count))
            let bytes = try restore.contents(restore.record(at: path))
            #expect(row.sha256 == Preparer.sha256(bytes))
            #expect(try row.codeDirectories == A6GuestAssets.verifiedCodeDirectories(bytes).map(\.hexString))
        }
        let systemVolume = try HFSPlusVolume(system)
        if let record = try? systemVolume.record(at: A6Sealing.executable) {
            let bytes = try systemVolume.contents(record)
            let row = try #require(prepared.assets.first { $0.path == A6Sealing.executable })
            #expect(row.sha256 == Preparer.sha256(bytes))
            #expect(try row.codeDirectories == A6GuestAssets.verifiedCodeDirectories(bytes).map(\.hexString))
        }
        #expect(prepared.kernel != kernel)
        // The original kernel's native set and lookup instructions are checked
        // inside registering(); only its two metadata allocations may change.
        #expect(prepared.kernel.prefix(0x790000) == kernel.prefix(0x790000))
        #expect(prepared.kernel.suffix(from: 0x7b6000) == kernel.suffix(from: 0x7b6000))
    }
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["FK_A6_IOS9_KERNEL"] != nil,
            "Optional native-qualified 13A344 cache preparation fixture"))
    func matchesQualifiedIOS9CachePreparation() throws {
        let env = ProcessInfo.processInfo.environment
        let kernelPath = try #require(env["FK_A6_IOS9_KERNEL"])
        let cachePath = try #require(env["FK_A6_IOS9_CACHE"])
        let kbootPath = try #require(env["FK_A6_IOS9_KBOOT"])
        let kernel = try Data(contentsOf: URL(fileURLWithPath: kernelPath), options: .alwaysMapped)
        let cache = try Data(contentsOf: URL(fileURLWithPath: cachePath), options: .alwaysMapped)
        let expected = try Data(contentsOf: URL(fileURLWithPath: kbootPath), options: .alwaysMapped)
        #expect(Preparer.sha256(cache) == "d4357d9ce3eac673900f20eda1ae949175725c37d685be1bf19033fc4e88d8dc")
        #expect(Preparer.sha256(expected) == "aec03fecec31e16c57e11416fbdf964abb669ed6e414bdccc8cdbc7a7bb96b48")
        let hashes = try A6GuestAssets.verifiedCodeDirectories(cache)
        #expect(hashes.map(\.hexString) == ["bdde8a7c018c77cd0556f78b893278c75cc81ce7"])
        let prepared = try A6GuestAssets.registering(Set(hashes), in: kernel)
        func word(_ b: Data, _ at: Int, count: Int = 4) -> Int {
            (0..<count).reduce(0) { $0 | Int(b[at + $1]) << (8 * $1) }
        }
        let file = 0x70c000
        let size = 0x22000
        let load = word(expected, expected.count - 16)
        let at = 0x8075_5000 - load
        try #require(at >= 0 && at <= expected.count - size)
        #expect(prepared.subdata(in: file..<(file + size)) == expected.subdata(in: at..<(at + size)))
        #expect(prepared.prefix(file) == kernel.prefix(file))
        #expect(prepared.suffix(from: file + size) == kernel.suffix(from: file + size))
        // An identity already present in the stock table needs no extension.
        for first in 0..<256 {
            let header = file + 0x6eb0 + first * 4
            if word(kernel, header, count: 2) > 0 {
                let index = word(kernel, header + 2, count: 2)
                let suffix = file + 0x72b0 + index * 19
                let native = Data([UInt8(first)]) + kernel.subdata(in: suffix..<(suffix + 19))
                #expect(try A6GuestAssets.registering([native], in: kernel) == kernel)
                break
            }
        }
        var unsupported = kernel
        unsupported[0] ^= 1
        #expect(throws: FirmwareError.self) { try A6GuestAssets.registering(Set(hashes), in: unsupported) }
    }

    @Test func verifiesPagesBeforeAcceptingAssetIdentities() throws {
        var bytes = ActivationTests.syntheticMachO()
        bytes[4] = 12
        bytes[8] = 9
        let signed = try Activation.signed(Data(bytes))
        #expect(try A6GuestAssets.verifiedCodeDirectories(signed).count == 1)
        var corrupt = signed
        corrupt[44] ^= 1
        #expect(throws: FirmwareError.self) { try A6GuestAssets.verifiedCodeDirectories(corrupt) }
        #expect(throws: FirmwareError.self) {
            try A6GuestAssets.registering([Data(repeating: 0, count: 20)], in: signed)
        }
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["FK_A6_ASSET_INVENTORY"] != nil,
            "Optional qualified 14G61 native preparation fixture"))
    func matchesQualifiedNativePreparation() throws {
        let env = ProcessInfo.processInfo.environment
        let inventory = try #require(env["FK_A6_ASSET_INVENTORY"])
        let kernelPath = try #require(env["FK_A6_ORIGINAL_KERNEL"])
        let expectedPath = try #require(env["FK_A6_EXPECTED_KERNEL"])
        let rows = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: inventory))) as? [[String: Any]])
        var hashes = Set<Data>()
        for row in rows {
            let path = try #require(row["path"] as? String)
            let expected = try #require(row["directories"] as? [[String: Any]])
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
            let verified = try A6GuestAssets.verifiedCodeDirectories(bytes)
            #expect(verified.map(\.hexString) == expected.compactMap { $0["cdhash"] as? String })
            hashes.formUnion(verified)
        }
        #expect(hashes.count == 7)
        let kernel = try Data(contentsOf: URL(fileURLWithPath: kernelPath), options: .alwaysMapped)
        let expected = try Data(contentsOf: URL(fileURLWithPath: expectedPath), options: .alwaysMapped)
        #expect(try A6GuestAssets.registering(hashes, in: kernel) == expected)
        // Exercise an inventory whose expanded buckets cannot fit separately.
        // The complete stock set must survive compaction, with lookup code
        // and all bytes outside the two metadata allocations unchanged.
        var extra = Set<Data>()
        for first in 0..<32 { extra.insert(Data([UInt8(first)]) + Data(repeating: 0, count: 19)) }
        let compact = try A6GuestAssets.registering(extra, in: kernel)
        let old = kernel.subdata(in: 0x790000..<0x7b6000)
        let new = compact.subdata(in: 0x790000..<0x7b6000)
        func word(_ b: Data, _ off: Int, _ size: Int) -> Int {
            (0..<size).reduce(0) { $0 | Int(b[off + $1]) << (8 * $1) }
        }
        func catalog(_ b: Data, header: Int, base: Int) -> Set<Data> {
            var entries = Set<Data>()
            for first in 0..<256 {
                let count = word(b, header + first * 4, 2)
                let index = word(b, header + first * 4 + 2, 2)
                for i in 0..<count {
                    let start = base + (index + i) * 19
                    entries.insert(Data([UInt8(first)]) + b.subdata(in: start..<(start + 19)))
                }
            }
            return entries
        }
        #expect((word(new, 0x23b0, 4) + 0x2360) & 0xffff_ffff == 0x484)
        #expect((word(new, 0x23b4, 4) + 0x236e) & 0xffff_ffff == 0x6fd4)
        #expect(catalog(new, header: 0x484, base: 0x6fd4) == catalog(old, header: 0x6fd4, base: 0x73d4).union(extra))
        #expect(new[0x234c..<0x23b0] == old[0x234c..<0x23b0])
        for i in old.indices where old[i] != new[i] {
            #expect((0x484..<0x884).contains(i) || (0x6fd4..<0x2160d).contains(i) || (0x23b0..<0x23b8).contains(i))
        }
    }
}
