import Crypto
import Foundation
import Testing

@testable import FirmwareKit

@Suite(.serialized) struct VFDecryptTests {
    /// An encrcdsa v2 image whose plaintext ends inside its last chunk: two chunks, and 600 (three of
    /// VFDecrypt's batches, the last one short).
    @Test(arguments: [(0x100, 2), (0x2000, 2), (0x100, 600)]) func synthetic(dataOffset: Int, chunks: Int) throws {
        let key = Data((0..<36).map { UInt8($0 * 7 & 0xFF) })
        let bs = 4096
        let size = (chunks - 1) * bs + 100
        let plain = Data((0..<chunks * bs).map { UInt8(truncatingIfNeeded: $0 &* 31 ^ $0 >> 12) })
        let be = { (v: UInt64, n: Int) in Data((0..<n).reversed().map { UInt8(v >> (8 * UInt64($0)) & 0xFF) }) }
        var img =
            Data("encrcdsa".utf8) + Data(count: 44) + be(UInt64(bs), 4) + be(UInt64(size), 8)
            + be(UInt64(dataOffset), 8)
        img += Data(count: dataOffset - img.count)
        for n in 0..<chunks {
            let mac = HMAC<Insecure.SHA1>.authenticationCode(
                for: be(UInt64(n), 4),
                using: SymmetricKey(data: key.suffix(20))
            )
            img += try AESCBC.crypt(
                plain[n * bs..<(n + 1) * bs],
                iv: Data(mac).prefix(16),
                key: key.prefix(16),
                decrypt: false
            )
        }
        try Oracle.withTemp { dir in
            let src = dir.appendingPathComponent("enc.dmg")
            let out = dir.appendingPathComponent("plain.dmg")
            try img.write(to: src)
            try VFDecrypt.decrypt(input: src, output: out, key: key)
            #expect(try Data(contentsOf: out) == plain.prefix(size))
            let input = try FileHandle(forReadingFrom: src)
            defer { try? input.close() }
            try RootFilesystemImage.extract(from: input.fileDescriptor, output: out) { key }
            #expect(try Data(contentsOf: out) == plain.prefix(size))
        }
    }

    /// The chunk IVs' HMAC-SHA1, against RFC 2202's test cases 1 and 2.
    @Test func hmacSHA1MatchesRFC2202() throws {
        let cases: [(key: Data, data: String, mac: String)] = [
            (Data(repeating: 0x0b, count: 20), "Hi There", "b617318655057264e28bc0b6fb378c8ef146be00"),
            (Data("Jefe".utf8), "what do ya want for nothing?", "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79")
        ]
        for c in cases {
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(c.data.utf8), using: SymmetricKey(data: c.key))
            #expect(Data(mac) == Data(hex: c.mac))
        }
    }

    /// rootfs.dmg straight off `unzip -p`, against the recorded digest of ipad1_fw.py's (vfdecrypt.c).
    @Test(
        .enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"),
        arguments: Oracle.firmwares
    )
    func rootfsMatchesRecordedDigest(_ fw: Oracle.Firmware) throws {
        guard fw.available else { try FixtureRequirements.missing(fw.ipsw.path) }
        let entry = try Oracle.entry(fw.entryID)
        let ipsw = IPSWArchive(fw.ipsw)
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
