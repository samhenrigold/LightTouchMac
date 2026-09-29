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

    /// The oracle, inline: the ipod-1g-fires agent's scratch tools that proved the layout on the emulator.
    /// logical.py's reading of the store (per logical page, the newest type-0x40 copy by the spare's lpn and age)
    /// as a flat image from LBA 3, and mkstore.py's VFL context (usnDec, next page, checksums; no reserved pool).
    static let oracle = """
        import hashlib, json, os, struct, sys
        store = sys.argv[1]
        best = {}
        for b in range(8):
            for f in os.listdir(f'{store}/bank{b}'):
                p = int(f.split('.')[0]); raw = open(f'{store}/bank{b}/{f}', 'rb').read()
                if raw[2048 + 9] != 0x40: continue
                lpn, age = struct.unpack('<II', raw[2048:2056]); key = (age, (p % 128) * 8 + b)
                if lpn not in best or key > best[lpn][0]: best[lpn] = (key, raw[:2048])
        img = b''.join(best[l][1] if l in best else bytes(2048) for l in range(3, max(best) + 1))
        d = bytearray(2048)
        def put(o, v, n): d[o:o + n] = (v & ((1 << (8 * n)) - 1)).to_bytes(n, 'little')
        for i in range(3): put(4 + 2 * i, i, 2)
        for i in range(1672, 1672 + 281): d[i] = 0xFF
        put(1954, 35, 2); put(0xC, 0xFFFFFFFF, 4); put(0x12, 8, 2)
        w = struct.unpack('<510I', bytes(d[:0x7F8])); x = 0
        for v in w: x ^= v
        put(0x7F8, (sum(w) + 0xAABBCCDD) & 0xFFFFFFFF, 4); put(0x7FC, x ^ 0xAABBCCDD, 4)
        print(json.dumps({"image": hashlib.sha256(img).hexdigest(), "pages": len(img) // 2048, "vfl": bytes(d).hex()}))
        """

    /// A volume with data in its first and third logical blocks and none in its second: every page of all three
    /// is written (the FTL fails the read of a mapped page left erased), the VFL context is VFL_Format's, and the
    /// oracle's reading of the store is the volume.
    @Test func storeLayout() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("n45-store-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let pp = N45NAND.page, ps = N45NAND.pagesPerSuperblock, fsPages = 3 * ps - 3 - 100   // ends inside block 2
        var vol = Data(count: fsPages * pp)
        for (i, v) in [(0, 0x48), (2 * ps, 0x11), (fsPages - 1, 0x7F)] { vol.replaceSubrange(i * pp..<i * pp + 4, with: [UInt8](repeating: UInt8(v), count: 4)) }
        let volume = dir.appendingPathComponent("volume.img"), out = dir.appendingPathComponent("nand")
        try vol.write(to: volume)
        let (written, meta) = try N45NAND.write(volume: volume, out: out)
        #expect(written == 3 * ps - 3 && meta == 1 + 8 + 8 * 8 + 1 + 18 + 1 + 3)
        let file = { (p: N45NAND.Page) in out.appendingPathComponent("bank\(p.bank)/\(p.page).page") }
        let absent = (0..<3 * ps).filter { !fm.fileExists(atPath: file(N45NAND.location(lpn: $0)).path) }
        #expect(absent.isEmpty && !fm.fileExists(atPath: file(N45NAND.location(lpn: 3 * ps)).path), "absent lpns \(absent.prefix(8))")

        let r = try Fixtures.run(["python3", "-c", Self.oracle, out.path])
        #expect(r.status == 0, "\(r.err)")
        let o = try JSONSerialization.jsonObject(with: r.out) as! [String: Any]
        #expect(o["pages"] as? Int == 3 * ps - 3 && o["image"] as? String == Preparer.sha256(vol + Data(count: 100 * pp)))

        let theirs = [UInt8](Data(hex: o["vfl"] as! String)!)
        let le = { (b: [UInt8], o: Int, n: Int) in (0..<n).reduce(UInt64(0)) { $0 | UInt64(b[o + $1]) << (8 * $1) } }
        for bank in 0..<N45NAND.banks {
            let first = [UInt8](try Data(contentsOf: file(N45NAND.Page(bank: bank, page: 35 * 128))))
            for c in 1..<8 { #expect([UInt8](try Data(contentsOf: file(N45NAND.Page(bank: bank, page: 35 * 128 + c)))) == first) }
            #expect(!fm.fileExists(atPath: file(N45NAND.Page(bank: bank, page: 35 * 128 + 8)).path))
            let d = Array(first[0..<pp])
            #expect(Array(first[pp...]) == [UInt8](repeating: 0xFF, count: 8) + [0, 0x80] + [UInt8](repeating: 0xFF, count: 54))
            #expect(le(d, 0, 4) == UInt64(bank) && le(d, 0xC, 4) == 0xFFFF_FFFF && le(d, 0x12, 2) == 8)
            #expect(le(d, 0x14, 2) == 1 && le(d, 0x1A, 2) == 1 && le(d, 0x1C, 2) == 39 && le(d, 0x1E, 2) == 162 && le(d, 0x20, 2) == 4095)
            #expect(d[0x688 + 63] == 0xFE && (0..<4).map { le(d, 0x7A2 + 2 * $0, 2) } == [35, 36, 37, 38] && le(d, 0x7AA, 2) == 820)
            let words = stride(from: 0, to: 0x7F8, by: 4).map { UInt32(le(d, $0, 4)) }
            #expect(le(d, 0x7F8, 4) == UInt64(words.reduce(0, &+) &+ 0xAABB_CCDD) && le(d, 0x7FC, 4) == UInt64(words.reduce(0, ^) ^ 0xAABB_CCDD))
            // Against mkstore.py's context only the bank's age, the reserved pool, the other info blocks, the last
            // aBadMark byte it leaves 0 and the checksums differ.
            let diff = Set((0..<pp).filter { d[$0] != theirs[$0] })
            let allowed = Set(0..<4).union(0x14..<0x22).union([0x688 + 63, 0x7A1]).union(0x7A4..<0x7AC).union(0x7F8..<0x800)
            #expect(diff.isSubset(of: allowed), "bank \(bank): \(diff.subtracting(allowed).sorted().map { String($0, radix: 16) })")
        }
    }

    @Test func components() throws {
        guard Self.available else { return }
        let c = try BuildComponents.load(IPSWArchive(Self.ipsw))
        #expect(c["iBoot"] == Self.prefix + "iBoot.n45ap.RELEASE.img2" && c["AppleLogo"] == Self.prefix + "applelogo.img2")
        #expect(c["KernelCache"] == "kernelcache.release.s5l8900xrb" && c["OS"] == "022-3601-4.dmg")
    }
}
