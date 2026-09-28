import Foundation
import Testing
@testable import FirmwareKit

struct BuildIdentityTests {
    @Test func everyCatalogEntryDecodes() throws {
        let data = try Data(contentsOf: Oracle.catalog)
        let raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for e in raw["entries"] as! [[String: Any]] {
            let entry = try JSONDecoder().decode(FirmwareEntry.self, from: JSONSerialization.data(withJSONObject: e))
            #expect(entry.id == e["id"] as? String)
            #expect(!entry.keys.isEmpty)
        }
        let e = try Oracle.entry("k48ap-7B500")
        #expect(try e.key(forPath: "kernelcache.release.k48").iv == "f89438cd21803ce315d98c032c4e6c27")
        #expect(try e.key(forPath: "018-8370-001.dmg").iv == nil)
        #expect(throws: FirmwareError.self) { try e.key(forPath: "nope.img3") }
    }

    // ipad1_fw.components on the same IPSWs.
    static let ipad = Oracle.firmware("k48ap-7B500"), ios2 = Oracle.firmware("n72ap-5F138")

    @Test(.enabled(if: ipad.available)) func buildManifestComponents() throws {
        let ipsw = IPSWArchive(Self.ipad.ipsw)
        let c = try BuildComponents.load(ipsw)
        let af = "Firmware/all_flash/all_flash.k48ap.production/"
        #expect(c == [
            "AppleLogo": af + "applelogo.s5l8930x.img3", "BatteryCharging": af + "glyphcharging.s5l8930x.img3",
            "BatteryCharging0": af + "batterycharging0.s5l8930x.img3", "BatteryCharging1": af + "batterycharging1.s5l8930x.img3",
            "BatteryFull": af + "batteryfull.s5l8930x.img3", "BatteryLow0": af + "batterylow0.s5l8930x.img3",
            "BatteryLow1": af + "batterylow1.s5l8930x.img3", "BatteryPlugin": af + "glyphplugin.s5l8930x.img3",
            "DeviceTree": af + "DeviceTree.k48ap.img3", "KernelCache": "kernelcache.release.k48", "LLB": af + "LLB.k48ap.RELEASE.img3",
            "NeedService": af + "needservice.s5l8930x.img3", "OS": "018-8370-001.dmg",
            "RecoveryMode": af + "recoverymode-768x1024.s5l8930x.img3", "RestoreDeviceTree": af + "DeviceTree.k48ap.img3",
            "RestoreKernelCache": "kernelcache.release.k48", "RestoreLogo": af + "applelogo.s5l8930x.img3",
            "RestoreRamDisk": "018-8375-001.dmg", "iBEC": "Firmware/dfu/iBEC.k48ap.RELEASE.dfu",
            "iBSS": "Firmware/dfu/iBSS.k48ap.RELEASE.dfu", "iBoot": af + "iBoot.k48ap.RELEASE.img3",
            "UpdateRamDisk": "018-8374-001.dmg"])
        let r = try RestoreInfo(ipsw)
        #expect((r.productType, r.productBuildVersion, r.productVersion, r.boardConfig) == ("iPad1,1", "7B500", "3.2.2", "k48ap"))
        try r.verify(against: Oracle.entry("k48ap-7B500"))
        #expect(throws: FirmwareError.self) { try r.verify(against: Oracle.entry("k48ap-7B367")) }
    }

    @Test(.enabled(if: ios2.available)) func restorePlistFallbackOn2x() throws {
        let ipsw = IPSWArchive(Self.ios2.ipsw)
        #expect(try !ipsw.contains("BuildManifest.plist"))
        let af = "Firmware/all_flash/all_flash.n72ap.production/"
        #expect(try BuildComponents.load(ipsw) == [
            "iBSS": "Firmware/dfu/iBSS.n72ap.RELEASE.dfu", "iBEC": "Firmware/dfu/iBEC.n72ap.RELEASE.dfu",
            "iBoot": af + "iBoot.n72ap.RELEASE.img3", "LLB": af + "LLB.n72ap.RELEASE.img3",
            "DeviceTree": af + "DeviceTree.n72ap.img3", "AppleLogo": af + "applelogo.s5l8720x.img3",
            "KernelCache": "kernelcache.release.s5l8720x", "OS": "018-4160-1.dmg",
            "RestoreRamDisk": "018-4166-1.dmg", "UpdateRamDisk": "018-4177-1.dmg"])
        try RestoreInfo(ipsw).verify(against: Oracle.entry("n72ap-5F138"))
    }
}
