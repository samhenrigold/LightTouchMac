import Foundation
import Testing
@testable import FirmwareKit

struct IMG3Tests {
    /// ipad1_fw.selfcheck: an odd-length payload through encrypt -> img3 -> decrypt, both tail conventions.
    @Test func partialBlockRoundTrip() throws {
        let iv = Data(count: 16), key = Data(0..<32), plain = Data(0..<37)
        func img3(_ payload: Data) -> Data {
            let le = { (v: Int) in DeviceTree.Value.le([UInt32(v)]) }
            let tag = Data("ATAD".utf8) + le(12 + payload.count) + le(plain.count) + payload   // magics are byte-reversed
            return Data("3gmI".utf8) + le(0x14 + tag.count) + Data(count: 12) + tag
        }
        // 3.x+: the tail block is encrypted into the tag's padding.
        let padded = try AESCBC.crypt(plain + Data(count: 11), iv: iv, key: key, decrypt: false)
        #expect(try IMG3.decrypt(img3(padded), iv: iv, key: key) == plain)
        // 2.x: whole blocks encrypted, the last 5 bytes left in plaintext.
        let whole = try AESCBC.crypt(plain.prefix(32), iv: iv, key: key, decrypt: false) + plain.suffix(5)
        #expect(try IMG3.decrypt(img3(whole), iv: iv, key: key, plainTail: true) == plain)
        #expect(try IMG3.tags(img3(padded))["DATA"] == IMG3.Tag(offset: 0x14, dataLength: 37))
        #expect(throws: FirmwareError.self) { try IMG3.tags(Data("nope".utf8)) }
    }

    /// Every ipad1_fw.py output but rootfs.dmg (VFDecryptTests), byte for byte.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"), arguments: Oracle.firmwares)
    func decryptMatchesPython(_ fw: Oracle.Firmware) throws {
        guard fw.available else { try FixtureRequirements.missing(fw.ipsw.path) }
        try Oracle.withTemp { dir in
            let r = try Oracle.time("decrypt components \(fw.entryID)") {
                try FirmwareDecryptor.decrypt(ipsw: fw.ipsw, entry: Oracle.entry(fw.entryID), into: dir, rootfs: false)
            }
            #expect(r.plainTail == (fw.entryID == "n72ap-5F138"))
            #expect(Set(r.files) == Set(fw.components.keys))
            for (name, sha) in fw.components {
                #expect(try Oracle.sha256(file: dir.appendingPathComponent(name)) == sha, "\(fw.entryID) \(name)")
            }
        }
    }
}
