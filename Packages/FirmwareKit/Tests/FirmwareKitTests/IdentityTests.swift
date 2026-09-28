import Foundation
import Testing
@testable import FirmwareKit

struct IdentityTests {
    // sha256 of json.dumps(ipad1_kboot.synth_identity(seed), indent=1).
    static let python: [(String, String)] = [
        ("ipad1-7B500-default", "595d9cbe1639ee298432b45df61d9db799eb9a63687002f5c349603631971b5a"),
        ("x", "4c6a3fb839c497921b43c49d0f61aade4290eafb34f559bb83804e6d2b565f51"),
        ("y", "5b6f01f2286a02ff6c8224e97de52e0dc28554962966d58ab4f0ac57473b93db"),
        ("", "916229c01499fefdd555f59559c00eb92624582aa639ca40fc1a815bdf28e086"),
        ("caf\u{e9} \u{2713} \"q\"\\\n\t\u{7f}\u{1F600}", "f3bdaa8749c8216500055c2590c72c2269e9a4b4cb80f4ca76bd2b670bf34135"),
    ]

    @Test(arguments: python) func jsonMatchesPython(seed: String, sha: String) throws {
        #expect(Oracle.sha256(try UnitIdentity.synthesize(seed: seed).json()) == sha)
    }

    @Test func defaultSeed() throws {
        let id = try UnitIdentity.synthesize(seed: "ipad1-7B500-default")
        #expect(String(decoding: id.json(), as: UTF8.self) == """
            {
             "serial-number": "0Y2ZETGRCJB",
             "mlb-serial-number": "83FGZ84AP5CMG",
             "unique-chip-id": "0x6bb6bf76e7",
             "die-id": [
              "0x03ba0042",
              "0x68659681"
             ],
             "wifi-mac": "02:ea:75:42:31:de",
             "bt-mac": "02:ea:75:42:31:df",
             "model-number": "MB292",
             "region-info": "LL/A",
             "seed": "ipad1-7B500-default",
             "udid": "144707f35769dad502241e7df06a757d8eeea130"
            }
            """)
        #expect(id.udid == UnitIdentity.udid(serial: "0Y2ZETGRCJB", wifiMAC: "02:EA:75:42:31:DE", btMAC: "02:ea:75:42:31:df"))
        #expect(throws: FirmwareError.self) { try UnitIdentity.synthesize(seed: "s", storage: "64g") }
    }

    /// ipod2g_device.identity(seed, {"model_number": "MC086", "region_info": "LL/A"}).
    @Test func iPod() throws {
        let id = try UnitIdentity.synthesizeIPod(seed: "ipod2g-8C148-default", modelNumber: "MC086", regionInfo: "LL/A")
        #expect(Oracle.sha256(id.json()) == "cdd30a95a8297be0b8cd336e28311f604e64409d60849323ced09695165c34d0")
        #expect(id["battery-serial"] == "142503116299" && id.udid == "0129500823c3921495fbea0555169adc11312b63")
    }

    @Test func writeIsExclusiveAndPrivate() throws {
        try Oracle.withTemp { dir in
            let id = try UnitIdentity.synthesize(seed: "x"), url = dir.appendingPathComponent("identity.json")
            try id.write(to: url)
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
            #expect(throws: FirmwareError.self) { try id.write(to: url) }
            let back = try UnitIdentity.load(from: url)
            #expect(back["udid"] == id.udid && back.dieID == id.dieID)
        }
    }
}
