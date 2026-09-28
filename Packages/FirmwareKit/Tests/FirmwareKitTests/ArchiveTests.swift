import Foundation
import Testing
@testable import FirmwareKit

struct ArchiveTests {
    @Test func wildcardsAreBracketed() {
        #expect(IPSWArchive.literal("a[1]*?.dmg") == "a[[]1][*][?].dmg")
        #expect(IPSWArchive.literal("Firmware/dfu/iBSS.k48ap.RELEASE.dfu") == "Firmware/dfu/iBSS.k48ap.RELEASE.dfu")
    }

    static let fw = Oracle.firmware("k48ap-7B500")

    @Test(.enabled(if: fw.available)) func membersReadAndExtract() throws {
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
    }
}
