import Foundation
import Testing
@testable import FirmwareKit

/// The n45 (iPod touch 1G) pieces against devos50's public n45ap_v1 set, which is built from the 3A101a IPSW
/// (~/Developer/qemu-ios-files/ipod1g: nor_n45ap.bin, iboot_204_n45ap.bin, the IPSW). Skips when absent.
@Suite struct N45Tests {
    static let files = Oracle.path("Developer/qemu-ios-files/ipod1g")
    static let ipsw = files.appendingPathComponent("iPod1,1_1.1_3A101a_Restore.ipsw")
    static var available: Bool { Oracle.exists(ipsw) && Oracle.exists(files.appendingPathComponent("nor_n45ap.bin")) }
    static let prefix = "Firmware/all_flash/all_flash.n45ap.production/"

    /// generate_nor.c's SysCfg values, so the whole 1 MiB compares.
    static let devos50 = UnitIdentity(fields: [("model-number", .string("MA623")), ("region-info", .string("B/LL")),
                                               ("serial-number", .string("ABCDEFG")), ("battery-serial", .string("690476146348"))])

    @Test func norMatchesDevos50() throws {
        guard Self.available else { return }
        let a = IPSWArchive(Self.ipsw)
        var images: [String: Data] = [:]
        for n in try a.names() where n.hasPrefix(Self.prefix) && n.hasSuffix(".img2") {
            let body = try Apple8900.body(a.read(n))
            images[try IMG2.Header(body).type] = body
        }
        let got = try N45NOR.build(identity: Self.devos50, images: images)
        let want = try Data(contentsOf: Self.files.appendingPathComponent("nor_n45ap.bin"))
        let diff = zip(got, want).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(got.count == want.count && diff.isEmpty, "\(diff.count) bytes differ, first at \(diff.prefix(8).map { String($0, radix: 16) })")
    }

    @Test func iBootIsTheDecryptedComponent() throws {
        guard Self.available else { return }
        let body = try Apple8900.body(IPSWArchive(Self.ipsw).read(Self.prefix + "iBoot.n45ap.RELEASE.img2"))
        let h = try IMG2.Header(body)
        #expect(h.type == "ibot" && h.loadAddress == 0x1800_0000)
        #expect(try IMG2.payload(body) == Data(contentsOf: Self.files.appendingPathComponent("iboot_204_n45ap.bin")))
    }

    @Test func components() throws {
        guard Self.available else { return }
        let c = try BuildComponents.load(IPSWArchive(Self.ipsw))
        #expect(c["iBoot"] == Self.prefix + "iBoot.n45ap.RELEASE.img2" && c["AppleLogo"] == Self.prefix + "applelogo.img2")
        #expect(c["KernelCache"] == "kernelcache.release.s5l8900xrb" && c["OS"] == "022-3601-4.dmg")
    }
}
