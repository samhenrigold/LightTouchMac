import Foundation
import Testing
@testable import FirmwareKit

struct IdentityTests {
    // sha256 of json.dumps(ipad1_kboot.synth_identity(seed), indent=1).
    static let python: [(String, String)] = [
        ("ipad1-7B500-default", "4d379949478173c02768a25adbd7e91c02f63daccd0e65c0e6506b81da61e861"),
        ("x", "40db97bd11bf40b3734a6d5a9fde47e7c0ad135178b25c48bb28553a19d4e2b4"),
        ("y", "0a0ef7113474b96bf46f646f4fb74c0fa01260f800a3f6c791170f796ff4101f"),
        ("", "e78717179783745bef5ecf24f96391e07bb9a9b1ccd97ccc31b231889d04005f"),
        ("caf\u{e9} \u{2713} \"q\"\\\n\t\u{7f}\u{1F600}", "bd4f2ab2194d18d4c25738444a4ba831213ffa0b362bbac56e1bffaedab49dc7"),
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
              "0xe7e35db5",
              "0x686525db"
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
