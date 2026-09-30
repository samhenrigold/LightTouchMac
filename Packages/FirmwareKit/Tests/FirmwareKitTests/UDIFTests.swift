import Foundation
import Testing
@testable import FirmwareKit

@Suite(.serialized) struct UDIFTests {
    @Test func apmSlice() throws {
        var map = Data("ER".utf8) + Data([0x02, 0x00]) + Data(count: 508)   // block size 512
        func entry(_ type: String, start: UInt32, count: UInt32, total: UInt32) -> Data {
            let be = { (v: UInt32) in Data([UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
            var e = Data("PM".utf8) + Data(count: 2) + be(total) + be(start) + be(count) + Data(count: 32)
            e += Data(type.utf8) + Data(count: 32 - type.utf8.count)
            return e + Data(count: 512 - e.count)
        }
        map += entry("Apple_partition_map", start: 1, count: 63, total: 2)
        map += entry("Apple_HFSX", start: 64, count: 1000, total: 2)
        #expect(try APM.hfsSlice(map) == (64 * 512, 1000 * 512))
        #expect(throws: FirmwareError.self) { try APM.hfsSlice(Data("xx".utf8) + map.dropFirst(2)) }
    }

    /// The raw HFS volume against ipad1_rootfs.extract_rootfs. Input: the Python cache's rootfs.dmg (read
    /// only) when there is one, else our own vfdecrypt of the IPSW.
    @Test(arguments: Oracle.firmwares.filter(\.available))
    func rawVolumeMatchesPython(_ fw: Oracle.Firmware) throws {
        try Oracle.withTemp { dir in
            var dmg = fw.cache?.appendingPathComponent("rootfs.dmg")
            if dmg == nil || !Oracle.exists(dmg!) {
                let ipsw = IPSWArchive(fw.ipsw), os = try BuildComponents.load(ipsw, board: Oracle.entry(fw.entryID).board)["OS"]!
                let key = try #require(Data(hex: Oracle.entry(fw.entryID).key(forPath: os).key))
                dmg = dir.appendingPathComponent("rootfs.dmg")
                try ipsw.stream(os) { try VFDecrypt.decrypt(from: $0.fileDescriptor, output: dmg!, key: key) }
            }
            let raw = dir.appendingPathComponent("rootfs.hfs")
            try Oracle.time("UDIF convert + APM slice \(fw.entryID)") { try UDIF.extractRootfs(dmg: dmg!, to: raw) }
            #expect(try Oracle.sha256(file: raw) == fw.rawVolume)
        }
    }
}
