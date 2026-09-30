import Foundation
import Testing
@testable import FirmwareKit

struct ArchiveTests {
    static let fw = Oracle.firmware("k48ap-7B500")

    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func membersReadAndExtract() throws {
        let ipsw = IPSWArchive(Self.fw.ipsw)
        let names = try ipsw.names()
        #expect(names.contains("Restore.plist") && names.contains("kernelcache.release.k48"))
        let dt = "Firmware/all_flash/all_flash.k48ap.production/DeviceTree.k48ap.img3"
        let bytes = try ipsw.read(dt)
        #expect(bytes.prefix(4) == Data("3gmI".utf8))
        try Oracle.withTemp { dir in
            let out = dir.appendingPathComponent("dt.img3")
            try ipsw.extract(dt, to: out)
            #expect(try Data(contentsOf: out) == bytes)
            let streamed = try ipsw.stream(dt) { try $0.readToEnd() ?? Data() }
            #expect(streamed == bytes)
        }
        #expect(throws: FirmwareError.self) { try ipsw.read("no-such-member") }
        #expect(try ipsw.contains("Restore.plist") && !ipsw.contains("no-such-member"))
    }

    /// The largest cached IPSW (the biggest central directory; zip64 once a member passes 4 GiB, which none does
    /// yet): names, a large member and its stream match /usr/bin/unzip.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func largestIPSWMatchesUnzip() throws {
        let cache = Oracle.path("Library/Caches/gold.samhenri.LightTouchMac/IPSW")
        func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        let files = ((try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.fileSizeKey])) ?? []).filter { $0.pathExtension == "ipsw" }
        guard let largest = files.max(by: { size($0) < size($1) }) else { try FixtureRequirements.missing(#"ArchiveTests.swift: let largest = files.max(by: { size($0) < size($1) })"#) }
        let ipsw = IPSWArchive(largest)
        let names = try ipsw.names()
        let unzip = try Fixtures.run(["/usr/bin/unzip", "-Z1", largest.path])
        #expect(names == String(decoding: unzip.out, as: UTF8.self).split(separator: "\n").map(String.init))
        let big = try #require(names.filter { $0.hasSuffix(".dmg") }.sorted().last)
        let theirs = try Fixtures.run(["/usr/bin/unzip", "-p", largest.path, big]).out
        #expect(try ipsw.read(big) == theirs)
        #expect(try ipsw.stream(big) { try $0.readToEnd() ?? Data() } == theirs)
        print("largest IPSW \(largest.lastPathComponent): \(size(largest)) bytes, \(names.count) members; \(big) \(theirs.count) bytes")
    }
}
