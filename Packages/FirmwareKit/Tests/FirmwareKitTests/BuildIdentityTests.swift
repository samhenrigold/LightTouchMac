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

    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func buildManifestComponents() throws {
        let ipsw = IPSWArchive(Self.ipad.ipsw)
        let c = try BuildComponents.load(ipsw, board: "k48ap")
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

    /// iOS 5.1.1: the Erase identity's components, the Update identity's ramdisk as UpdateRamDisk (the keybag
    /// one-shot's own, no sibling), and a catalog key for every component the k48 recipe decrypts.
    static let ios5 = Oracle.path("Developer/qemu-ios-files/ios5-spike/iPad1,1_5.1.1_9B206_Restore.ipsw")

    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func buildManifestComponentsOn5x() throws {
        let ipsw = IPSWArchive(Self.ios5)
        let e = try Oracle.entry("k48ap-9B206"), c = try BuildComponents.load(ipsw, board: e.board)
        #expect(c["KernelCache"] == "kernelcache.release.k48" && c["OS"] == "038-4291-006.dmg")
        #expect(c["RestoreRamDisk"] == "038-4361-021.dmg" && c["UpdateRamDisk"] == "038-4304-027.dmg")
        #expect(c["RecoveryMode"] == "Firmware/all_flash/all_flash.k48ap.production/recoverymode~ipad.s5l8930x.img3")
        for n in ["KernelCache", "OS", "RestoreRamDisk", "UpdateRamDisk", "iBoot", "LLB", "DeviceTree"] {
            #expect(throws: Never.self) { try e.key(forPath: c[n]!) }
        }
        #expect(e.recipe?.keybagRamdiskFrom == nil && e.recipe?.options["appsync"] == true)
        try RestoreInfo(ipsw).verify(against: e)
    }

    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func restorePlistFallbackOn2x() throws {
        let ipsw = IPSWArchive(Self.ios2.ipsw)
        #expect(try !ipsw.contains("BuildManifest.plist"))
        let af = "Firmware/all_flash/all_flash.n72ap.production/"
        #expect(try BuildComponents.load(ipsw, board: "n72ap") == [
            "iBSS": "Firmware/dfu/iBSS.n72ap.RELEASE.dfu", "iBEC": "Firmware/dfu/iBEC.n72ap.RELEASE.dfu",
            "iBoot": af + "iBoot.n72ap.RELEASE.img3", "LLB": af + "LLB.n72ap.RELEASE.img3",
            "DeviceTree": af + "DeviceTree.n72ap.img3", "AppleLogo": af + "applelogo.s5l8720x.img3",
            "KernelCache": "kernelcache.release.s5l8720x", "OS": "018-4160-1.dmg",
            "RestoreRamDisk": "018-4166-1.dmg", "UpdateRamDisk": "018-4177-1.dmg"])
        try RestoreInfo(ipsw).verify(against: Oracle.entry("n72ap-5F138"))
    }
    /// The 4.3 betas' BuildManifest lists the k48dev development board's identities first; the IPSW ships only
    /// k48ap's files. The components are the entry board's, every one an IPSW member.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"), arguments: ["k48ap-8F5148b", "k48ap-8F5153d", "k48ap-8F5166b"])
    func buildManifestPicksTheEntryBoard(_ id: String) throws {
        guard let url = try K48IBootTests.cachedIPSW(id) else { try FixtureRequirements.missing("cached IPSW for " + id) }
        let ipsw = IPSWArchive(url), e = try Oracle.entry(id), names = Set(try ipsw.names())
        let c = try BuildComponents.load(ipsw, board: e.board)
        #expect(c["iBSS"] == "Firmware/dfu/iBSS.k48ap.RELEASE.dfu" && c["iBoot"] == "Firmware/all_flash/all_flash.k48ap.production/iBoot.k48ap.RELEASE.img3")
        #expect(c["UpdateRamDisk"] != nil && c["UpdateRamDisk"] != c["RestoreRamDisk"])
        #expect(c.values.filter { !names.contains($0) }.isEmpty)
        #expect(throws: FirmwareError.self) { try BuildComponents.load(ipsw, board: "n72ap") }
        try RestoreInfo(ipsw).verify(against: e)
    }

    /// 1.1.2 (3B48b)'s Restore.plist gives ProductType as the board name, N45AP.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func boardNameProductTypeOn112() throws {
        guard let url = try K48IBootTests.cachedIPSW("n45ap-3B48b") else { try FixtureRequirements.missing("cached n45ap-3B48b IPSW") }
        let r = try RestoreInfo(IPSWArchive(url)), e = try Oracle.entry("n45ap-3B48b")
        #expect(r.productType == "N45AP" && e.productType == "iPod1,1")
        try r.verify(against: e)
        var other = e; other.board = "n72ap"
        #expect(throws: FirmwareError.self) { try r.verify(against: other) }   // BoardConfig still binds it
        #expect(throws: FirmwareError.self) { try r.verify(against: Oracle.entry("n45ap-4B1")) }
    }
}
