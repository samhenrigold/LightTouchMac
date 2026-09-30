import CryptoKit
import Foundation
import Testing
@testable import FirmwareKit

@Suite(.serialized) struct VFDecryptTests {
    /// A two-chunk encrcdsa v2 image whose plaintext ends inside the second chunk.
    @Test(arguments: [0x100, 0x2000]) func synthetic(dataOffset: Int) throws {
        let key = Data((0..<36).map { UInt8($0 * 7 & 0xFF) }), bs = 4096, size = bs + 100
        let plain = Data((0..<2 * bs).map { UInt8($0 * 31 & 0xFF) })
        let be = { (v: UInt64, n: Int) in Data((0..<n).reversed().map { UInt8(v >> (8 * UInt64($0)) & 0xFF) }) }
        var img = Data("encrcdsa".utf8) + Data(count: 44) + be(UInt64(bs), 4) + be(UInt64(size), 8) + be(UInt64(dataOffset), 8)
        img += Data(count: dataOffset - img.count)
        for n in 0..<2 {
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: be(UInt64(n), 4), using: SymmetricKey(data: key.suffix(20)))
            img += try AESCBC.crypt(plain[n * bs..<(n + 1) * bs], iv: Data(mac).prefix(16), key: key.prefix(16), decrypt: false)
        }
        try Oracle.withTemp { dir in
            let src = dir.appendingPathComponent("enc.dmg"), out = dir.appendingPathComponent("plain.dmg")
            try img.write(to: src)
            try VFDecrypt.decrypt(input: src, output: out, key: key)
            #expect(try Data(contentsOf: out) == plain.prefix(size))
        }
    }

    /// rootfs.dmg straight off `unzip -p`, against ipad1_fw.py's (vfdecrypt.c).
    @Test(arguments: Oracle.firmwares.filter(\.available))
    func rootfsMatchesPython(_ fw: Oracle.Firmware) throws {
        let entry = try Oracle.entry(fw.entryID), ipsw = IPSWArchive(fw.ipsw)
        let os = try BuildComponents.load(ipsw, board: entry.board)["OS"]!
        let key = try #require(Data(hex: entry.key(forPath: os).key))
        try Oracle.withTemp { dir in
            let out = dir.appendingPathComponent("rootfs.dmg")
            try Oracle.time("vfdecrypt (streamed from the IPSW) \(fw.entryID)") {
                try ipsw.stream(os) { try VFDecrypt.decrypt(from: $0.fileDescriptor, output: out, key: key) }
            }
            #expect(try Oracle.sha256(file: out) == fw.rootfsDMG)
        }
    }
}
