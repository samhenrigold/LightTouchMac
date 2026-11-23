import Crypto
import Foundation
import HostRuntime
import Testing

@testable import FirmwareKit

struct IdentityTests {
    // Recorded digests: sha256 of json.dumps(ipad1_kboot.synth_identity(seed), indent=1).
    static let recorded: [(String, String)] = [
        ("ipad1-7B500-default", "4d379949478173c02768a25adbd7e91c02f63daccd0e65c0e6506b81da61e861"),
        ("x", "40db97bd11bf40b3734a6d5a9fde47e7c0ad135178b25c48bb28553a19d4e2b4"),
        ("y", "0a0ef7113474b96bf46f646f4fb74c0fa01260f800a3f6c791170f796ff4101f"),
        ("", "e78717179783745bef5ecf24f96391e07bb9a9b1ccd97ccc31b231889d04005f"),
        (
            "caf\u{e9} \u{2713} \"q\"\\\n\t\u{7f}\u{1F600}",
            "bd4f2ab2194d18d4c25738444a4ba831213ffa0b362bbac56e1bffaedab49dc7"
        )
    ]

    @Test(arguments: recorded) func jsonMatchesRecordedDigests(seed: String, sha: String) throws {
        #expect(Oracle.sha256(try UnitIdentity.synthesize(seed: seed).json()) == sha)
    }

    @Test func defaultSeed() throws {
        let id = try UnitIdentity.synthesize(seed: "ipad1-7B500-default")
        #expect(
            String(decoding: id.json(), as: UTF8.self) == """
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
                """
        )
        #expect(
            id.udid
                == UnitIdentity.udid(serial: "0Y2ZETGRCJB", wifiMAC: "02:EA:75:42:31:DE", btMAC: "02:ea:75:42:31:df")
        )
        #expect(throws: FirmwareError.self) { try UnitIdentity.synthesize(seed: "s", storage: "64g") }
    }

    /// ipod2g_device.identity(seed, {"model_number": "MC086", "region_info": "LL/A"}).
    @Test func iPod() throws {
        let id = try UnitIdentity.synthesizeIPod(seed: "ipod2g-8C148-default", modelNumber: "MC086", regionInfo: "LL/A")
        let legacy = UnitIdentity(fields: id.fields.filter { $0.key != "unique-chip-id" })
        #expect(Oracle.sha256(legacy.json()) == "cdd30a95a8297be0b8cd336e28311f604e64409d60849323ced09695165c34d0")
        #expect(id["unique-chip-id"] == (try UnitIdentity.synthesize(seed: "ipod2g-8C148-default"))["unique-chip-id"])
        #expect(id["battery-serial"] == "142503116299" && id.udid == "0129500823c3921495fbea0555169adc11312b63")
    }

    /// The 1G has no Bluetooth: no bt-mac, and the UDID is lockdownd's SHA1(serial + Wi-Fi MAC + "").
    @Test func iPod1G() throws {
        let pod = try UnitIdentity.synthesizeIPod(seed: "ipod1g-test", modelNumber: "MA623", regionInfo: "LL/A")
        let id = try UnitIdentity.synthesizeIPod(
            seed: "ipod1g-test",
            modelNumber: "MA623",
            regionInfo: "LL/A",
            bluetooth: false
        )
        #expect(id["unique-chip-id"] == nil)
        #expect(id["bt-mac"] == nil && id["wifi-mac"] == pod["wifi-mac"])
        // Made in 2008 (PPYWW…), as lockdownd's load_nikita reads it: the January apps come with the unit.
        let serial = try #require(id["serial-number"])
        let other = try #require(pod["serial-number"])
        #expect(serial.prefix(2) == other.prefix(2) && serial.dropFirst(5) == other.dropFirst(5))
        #expect(Array(serial)[2] == "8" && (1...36).contains(Int(serial.dropFirst(3).prefix(2)) ?? 0))
        #expect(
            id.udid == Data(Insecure.SHA1.hash(data: Data((id["serial-number"]! + id["wifi-mac"]!).utf8))).hexString
        )
        #expect(id.udid != pod.udid)
    }

    /// The original iPhone: the iPod's fields plus an IMEI (the synthetic TAC 00000000, Luhn-checked); the UDID hashes all four.
    @Test func iPhone() throws {
        let id = try UnitIdentity.synthesizeIPhone(seed: "iphone2g-test", modelNumber: "MA501", regionInfo: "LL/A")
        let imei = try #require(id["imei"])
        #expect(
            imei.count == 15 && imei.hasPrefix("00000000") && UnitIdentity.syntheticTAC == "00000000"
                && UnitIdentity.luhn(String(imei.prefix(14))) == Int(String(imei.last!))
        )
        #expect(UnitIdentity.luhn("49015420323751") == 8)  // the classic example IMEI 490154203237518
        #expect(
            id["bt-mac"] != nil
                && id.udid
                    == Data(
                        Insecure.SHA1.hash(
                            data: Data((id["serial-number"]! + imei + id["wifi-mac"]! + id["bt-mac"]!).utf8)
                        )
                    ).hexString
        )
        #expect(id.fields.filter { $0.key == "udid" }.count == 1)
    }

    /// The A4 radio boards (n90ap, n88ap): the iPad-pipeline identity plus the IMEI after the serial, the UDID over
    /// all four; nothing else moves, and the boot's derivation for older bases (IPhoneIdentity.upgraded) agrees.
    @Test func a4IPhoneIdentityCarriesIMEI() throws {
        let base = try UnitIdentity.synthesize(seed: "iphone4-8C148-default", modelNumber: "MC603")
        let id = base.addingIMEI(seed: "iphone4-8C148-default")
        let imei = try #require(id["imei"])
        #expect(id.fields[1].key == "imei" && id.fields.last?.key == "udid" && id.fields.count == base.fields.count + 1)
        #expect(
            id.fields.filter { $0.key != "imei" && $0.key != "udid" }.map(\.key)
                == base.fields.filter { $0.key != "udid" }.map(\.key)
        )
        #expect(
            id.udid
                == Data(
                    Insecure.SHA1.hash(data: Data((id["serial-number"]! + imei + id["wifi-mac"]! + id["bt-mac"]!).utf8))
                ).hexString
        )
        #expect(id.udid != base.udid)
        let legacy = try JSONSerialization.jsonObject(with: base.json()) as! [String: Any]
        #expect(IPhoneIdentity.upgraded(legacy)?.imei == imei && IPhoneIdentity.upgraded(legacy)?.udid == id.udid)
    }

    @Test func writeIsExclusiveAndPrivate() throws {
        try Oracle.withTemp { dir in
            let id = try UnitIdentity.synthesize(seed: "x")
            let url = dir.appendingPathComponent("identity.json")
            try id.write(to: url)
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
            #expect(throws: FirmwareError.self) { try id.write(to: url) }
            let back = try UnitIdentity.load(from: url)
            #expect(back["udid"] == id.udid && back.dieID == id.dieID)
        }
    }

    /// The K48 lock's machine map boots the BCM4329 with the unit's own address (the one in its DT and NOR).
    @Test func k48LockCarriesWifiMAC() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { TemporaryTrees.remove(dir) }
        let any = dir.appendingPathComponent("file")
        for n in ["file", "iBoot.bin", "gid-blobs.bin", "nor.bin", "kboot.bin"] {
            try Data(n.utf8).write(to: dir.appendingPathComponent(n))
        }
        let o = Preparer.Options(
            entry: try Oracle.entry("k48ap-7B500"),
            ipsw: dir,
            out: dir,
            helper: nil,
            guestTools: dir
        )
        let board = try K48Board(o)
        board.helper = any
        board.patcher = any
        board.mbr = any
        board.vols = SystemEdits.Result(system: dir, data: dir)
        let id = try board.identity(seed: "k48-lock")
        let lock = try board.lock(Recipe.Context(o, recipe: o.entry.recipe!, emit: { _ in }))
        let machine = try #require(lock["machine"] as? [String: Any])
        #expect(machine["wifi-mac"] as? String == id["wifi-mac"])
        #expect(id["wifi-mac"]?.isEmpty == false)
    }
}
