import Foundation
import Testing
@testable import FirmwareKit

/// The n72 NOR and NAND bookkeeping against the Python oracle (qemu-ios imgtools build_nor.py, ipod2g_nand.py).
@Suite struct N72Tests {
    /// ipod2g_nand.selfcheck.
    @Test func metadataSelfcheck() throws {
        let p = N72NAND.metadataPages(blocks: 128000, epoch: 1)
        #expect(p.count == 50 && p.values.allSatisfy { $0.count == 4096 + 64 })
        let hdr = try #require(p[.init(cs: 1, page: 256)])
        #expect(N72NAND.crc(hdr[0..<0x10] + [0, 0, 0, 0] + hdr[0x14..<0x5C]) == UInt32(hdr[0x10]) | UInt32(hdr[0x11]) << 8 | UInt32(hdr[0x12]) << 16 | UInt32(hdr[0x13]) << 24)
        #expect(p[.init(cs: 2, page: 256)]![0x28..<0x30].reversed().reduce(0) { $0 << 8 | Int($1) } == 128013)
        #expect(N72NAND.predict(0) == .init(cs: 3, page: 256) && N72NAND.predict(1) == .init(cs: 0, page: 384))
    }

    /// Every metadata page, byte for byte, for the 7E18 volume and epoch.
    @Test func metadataMatchesPython() throws {
        guard HFSOracle.available else { return }
        let out = try HFSOracle.python("""
            import hashlib, ipod2g_nand
            for (cs, pg), d in sorted(ipod2g_nand.metadata_pages(1835008, 4).items()):
                print(cs, pg, hashlib.sha256(d).hexdigest())
            """, [])
        let want = String(decoding: out, as: UTF8.self).split(separator: "\n").map(String.init)
        let got = N72NAND.metadataPages(blocks: 1835008, epoch: 4).sorted { ($0.key.cs, $0.key.page) < ($1.key.cs, $1.key.page) }
            .map { "\($0.key.cs) \($0.key.page) \(Oracle.sha256(Data($0.value)))" }
        #expect(got == want)
    }

    /// build_nor.py --identity over the 7E18 IPSW's all_flash: the same 1 MiB.
    @Test func norMatchesPython() throws {
        let fw = Oracle.firmware("n72ap-7E18")
        guard fw.available, HFSOracle.available else { return }
        try Oracle.withTemp { dir in
            let ipsw = IPSWArchive(fw.ipsw), prefix = "Firmware/all_flash/all_flash.n72ap.production/"
            let af = dir.appendingPathComponent("all_flash")
            try FileManager.default.createDirectory(at: af, withIntermediateDirectories: true)
            var images: [String: Data] = [:]
            for n in try ipsw.names() where n.hasPrefix(prefix) && !n.hasSuffix("/") {
                let d = try ipsw.read(n)
                try d.write(to: af.appendingPathComponent((n as NSString).lastPathComponent))
                if n.hasSuffix(".img3") { images[try N72NOR.type(of: d)] = d }
            }
            let id = try UnitIdentity.synthesizeIPod(seed: "n72-test", modelNumber: "MB528", regionInfo: "LL/A")
            let idURL = dir.appendingPathComponent("identity.json"), py = dir.appendingPathComponent("nor-py.bin")
            try id.write(to: idURL)
            _ = try HFSOracle.python("import build_nor, runpy; sys.argv = ['build_nor.py'] + sys.argv[1:]; runpy.run_path(build_nor.__file__, run_name='__main__')",
                                     ["--identity", idURL.path, "--all-flash", af.path, "--out", py.path])
            let got = try N72NOR.build(identity: id, images: images, types: N72NOR.order, wrapTypes: nil)
            #expect(got == (try Data(contentsOf: py)))
        }
    }
}
