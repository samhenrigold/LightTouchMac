import CryptoKit
import Foundation
import Testing
@testable import FirmwareKit

struct VolumeRebuildTests {
    // MARK: synthetic

    /// iPad: a small selfcheck-geometry store round-trips its system/data images; then an overlay block with a
    /// higher USN supersedes one system page, a lower-USN copy elsewhere does not, and the base is untouched.
    @Test func iPadStoreAndOverlay() throws {
        let dir = try Fixtures.tempDir("rebuild-ipad")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ps = 4096, geo = K48NAND.Geometry.selfcheck
        var mbr = [UInt8](repeating: 0, count: ps * 63)
        mbr[510] = 0x55; mbr[511] = 0xAA
        for (i, (typ, lba, cnt)) in [(0xAF, 63, 700), (0xAF, 800, 400)].enumerated() {
            let o = 0x1be + 16 * i
            mbr[o + 4] = UInt8(typ)
            K48NAND.put32(&mbr, o + 8, UInt32(lba)); K48NAND.put32(&mbr, o + 12, UInt32(cnt))
        }
        var rng = SystemRandomNumberGenerator()
        var sys = (0..<ps * 700).map { _ in UInt8.random(in: 0...255, using: &rng) }
        sys[1024] = UInt8(ascii: "H"); sys[1025] = UInt8(ascii: "X")
        var data = [UInt8](repeating: 0, count: ps * 400)
        data[1024] = UInt8(ascii: "H"); data[1025] = UInt8(ascii: "+")
        for i in ps * 100..<ps * 103 { data[i] = UInt8(truncatingIfNeeded: i) }
        let paths = ["mbr", "system.img", "data.img"].map { dir.appendingPathComponent($0) }
        try Data(mbr).write(to: paths[0]); try Data(sys).write(to: paths[1]); try Data(data).write(to: paths[2])
        let base = dir.appendingPathComponent("base")
        try K48NAND.build(geometry: geo, mbr: paths[0], kernelVersion: Array("Darwin Kernel Version selfcheck".utf8),
                          system: paths[1], data: .image(paths[2]), out: base)
        let baseDigest = try digest(base)

        let out1 = dir.appendingPathComponent("out1")
        let vols = try VolumeRebuild.rebuild(base: base, overlay: nil, into: out1)
        #expect(vols.map(\.name) == ["system", "data"])
        #expect(try Data(contentsOf: vols[0].image) == Data(sys))
        #expect(try Data(contentsOf: vols[1].image) == Data(data))
        #expect(vols[1].pagesWritten == 4)       // header page + 3 data pages; the rest stays a hole

        // overlay: vblock N-2 holds system page 5 at USN 1000 (wins), vblock N-3 page 6 at USN 0 (loses)
        let ovl = dir.appendingPathComponent("overlay")
        let st = try K48NAND.Store(create: ovl, geo: geo)
        var dirty = [[UInt8]](repeating: [UInt8](repeating: 0, count: geo.pagesPerCE / 8), count: geo.numCS)
        func put(vblock: Int, lpn: Int, usn: UInt32, fill: UInt8) throws {
            let (cs, pp) = geo.vpnToPhys(vblock * geo.ppsublk)
            try st.write(cs, pp, [UInt8](repeating: fill, count: ps), K48NAND.spare(UInt32(lpn), usn, K48NAND.tUser))
            dirty[cs][pp / 8] |= 1 << (pp % 8)
        }
        try put(vblock: geo.numBlocks - 2, lpn: 63 + 5, usn: 1000, fill: 0xA1)
        try put(vblock: geo.numBlocks - 3, lpn: 63 + 6, usn: 0, fill: 0xB2)
        st.close()
        for cs in 0..<geo.numCS {
            let (b, c) = geo.busCE(cs)
            try Data(dirty[cs]).write(to: ovl.appendingPathComponent("bus\(b)-ce\(c).dirty"))
        }
        let out2 = dir.appendingPathComponent("out2")
        let sys2 = [UInt8](try Data(contentsOf: try VolumeRebuild.rebuild(base: base, overlay: ovl, into: out2, only: ["system"])[0].image))
        #expect(sys2[5 * ps..<6 * ps].allSatisfy { $0 == 0xA1 })
        #expect(sys2[6 * ps..<7 * ps] == sys[6 * ps..<7 * ps])
        #expect(sys2[..<(5 * ps)] == sys[..<(5 * ps)] && sys2[(7 * ps)...] == sys[(7 * ps)...])
        #expect(try digest(base) == baseDigest)
    }

    /// iPod: the overlay's page wins over the base's, an erased block reads blank, and absent pages are holes.
    @Test func iPodOverlay() throws {
        let dir = try Fixtures.tempDir("rebuild-ipod")
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = dir.appendingPathComponent("base"), ovl = dir.appendingPathComponent("overlay")
        let blocks = 600
        func page(_ root: URL, _ n: Int, _ bytes: [UInt8]) throws {
            let (cs, pg) = VolumeRebuild.predict(n)
            let d = root.appendingPathComponent("cs\(cs)")
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try Data(bytes + [UInt8](repeating: 0, count: 64)).write(to: d.appendingPathComponent("\(pg).page"))
        }
        var vh = [UInt8](repeating: 0, count: 4096)
        vh[1024] = UInt8(ascii: "H"); vh[1025] = UInt8(ascii: "X")
        K48NAND.put32(&vh, 1024 + 40, UInt32(4096).byteSwapped)       // big-endian
        K48NAND.put32(&vh, 1024 + 44, UInt32(blocks).byteSwapped)
        try page(base, 0, vh)
        for n in 1..<400 { try page(base, n, [UInt8](repeating: UInt8(n % 251 + 1), count: 4096)) }
        try page(ovl, 7, [UInt8](repeating: 0xEE, count: 4096))
        let (cs9, pg9) = VolumeRebuild.predict(9)
        try FileManager.default.createDirectory(at: ovl.appendingPathComponent("cs\(cs9)"), withIntermediateDirectories: true)
        try Data().write(to: ovl.appendingPathComponent("cs\(cs9)/blk\(pg9 / 128).erased"))

        let v = try VolumeRebuild.rebuild(base: base, overlay: ovl, into: dir.appendingPathComponent("out"))[0]
        let img = [UInt8](try Data(contentsOf: v.image))
        #expect(img.count == blocks * 4096)
        func blk(_ n: Int) -> ArraySlice<UInt8> { img[n * 4096..<(n + 1) * 4096] }
        #expect(blk(7).allSatisfy { $0 == 0xEE })
        #expect(blk(9).allSatisfy { $0 == 0 })                         // its whole erase block reads blank
        #expect(blk(8).allSatisfy { $0 == 9 } && blk(399).allSatisfy { $0 == 149 })
        #expect(blk(450).allSatisfy { $0 == 0 })
    }

    // MARK: fixtures

    /// The shipped bases rebuild into volumes fsck_hfs accepts (skips without them).
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"), arguments: ["nand-current", "ipad1/userland/golden-pristine"])
    func baseRebuildsClean(_ name: String) throws {
        let base = Fixtures.files.appendingPathComponent(name)
        guard Fixtures.exists(base) else { try FixtureRequirements.missing(#"VolumeRebuildTests.swift: Fixtures.exists(base)"#) }
        let dir = try Fixtures.tempDir("rebuild-base")
        defer { try? FileManager.default.removeItem(at: dir) }
        let t0 = Date()
        let vols = try VolumeRebuild.rebuild(base: base, overlay: nil, into: dir)
        print("\(name): rebuilt \(vols.map { "\($0.name) \($0.pagesWritten) pages" }) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        for v in vols {
            let dev = try VolumeMount.attach(v.image)
            let r = VolumeMount.exec("/sbin/fsck_hfs", ["-fn", dev])
            VolumeMount.detach(dev)
            #expect(r.0 == 0, "\(v.name): \(r.1.suffix(400))")
        }
    }

    /// The pipeline on the iPod base: mount read-only (never-index marker, writes refused), unmount cleans up.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func mountAndUnmount() throws {
        let base = Fixtures.files.appendingPathComponent("nand-current")
        guard Fixtures.exists(base) else { try FixtureRequirements.missing(#"VolumeRebuildTests.swift: Fixtures.exists(base)"#) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("fk-mount-\(UUID().uuidString)")
        defer { try? VolumeExport.unmount(out: out) }
        let vols = try VolumeExport.mount(.init(base: base, overlay: nil), out: out)
        #expect(vols.count == 1 && vols[0].clean && !vols[0].repaired)
        let mnt = try #require(vols[0].mountPoint.map(URL.init(fileURLWithPath:)))
        #expect(Fixtures.exists(mnt.appendingPathComponent(".metadata_never_index")))
        #expect(Fixtures.exists(mnt.appendingPathComponent("System/Library/CoreServices/SpringBoard.app")))
        #expect(!FileManager.default.createFile(atPath: mnt.appendingPathComponent("x").path, contents: Data()))
        try VolumeExport.unmount(out: out)
        #expect(!Fixtures.exists(out) && !VolumeMount.exec("/usr/bin/hdiutil", ["info"]).1.contains(out.path))
    }

    /// U1 (FK_U1=DIR, written by tests/volume-rebuild-oracle.py or by hand for the iPod): the rebuilt volumes
    /// hold exactly the files the guest reported (size + sha256), none of the deleted ones, and each installed
    /// IPA's Payload; fsck_hfs -n passes; base and overlay are untouched.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func guestOracle() throws {
        guard let u1 = ProcessInfo.processInfo.environment["FK_U1"] else { try FixtureRequirements.missing(#"VolumeRebuildTests.swift: let u1 = ProcessInfo.processInfo.environment["FK_U1"]"#) }
        struct Guest: Decodable {
            struct File: Decodable { var size: UInt64; var sha256: String }
            struct IPA: Decodable { var ipa: String; var app: String }
            var base: String, overlay: String, clean: Bool
            var files: [String: File], deleted: [String], ipas: [IPA]
            var volume: String?          // the volume the paths are on; default data
            var reference: String?       // an independent image of that volume (tests/ipod/regress.py's fsck compose)
        }
        let root = URL(fileURLWithPath: u1)
        let g = try JSONDecoder().decode(Guest.self, from: Data(contentsOf: root.appendingPathComponent("guest.json")))
        let base = URL(fileURLWithPath: g.base), overlay = URL(fileURLWithPath: g.overlay)
        let before = try digest(base).merging(try digest(overlay)) { a, _ in a }
        let out = root.appendingPathComponent("rebuild")
        try? FileManager.default.removeItem(at: out)
        defer { try? FileManager.default.removeItem(at: out) }
        let t0 = Date()
        // After an unclean stop the journal must be replayed first: the export pipeline's fsck -fy + mount.
        let vols = g.clean ? try VolumeRebuild.rebuild(base: base, overlay: overlay, into: out)
            : try VolumeExport.export(.init(base: base, overlay: overlay), out: out) { print($0) }.map {
                VolumeRebuild.Volume(name: $0.volume, image: URL(fileURLWithPath: $0.image), bytes: 0, pagesWritten: -1)
            }
        print("U1 rebuild: \(vols.map { "\($0.name) \($0.pagesWritten) pages" }) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        for v in vols {
            let dev = try VolumeMount.attach(v.image)
            let r = VolumeMount.exec("/sbin/fsck_hfs", ["-fn", dev])
            VolumeMount.detach(dev)
            print("fsck_hfs -n \(v.name): exit \(r.0); \(r.1.split(separator: "\n").suffix(2).joined(separator: " | "))")
            #expect(r.0 == 0 || !g.clean, "\(v.name) (clean shutdown): \(r.1.suffix(400))")
        }
        guard let data = vols.first(where: { $0.name == (g.volume ?? "data") }) else { Issue.record("no \(g.volume ?? "data") volume"); return }
        if let ref = g.reference {
            #expect(try Fixtures.run(["cmp", ref, data.image.path]).status == 0, "\(data.name) differs from \(ref)")
        }
        let vol = try HFSPlusVolume(data.image)
        let listing = Dictionary(try vol.listing().map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var bad: [String] = []
        for (p, f) in g.files where listing[p]?.size != f.size || listing[p]?.sha256 != f.sha256 {
            bad.append("\(p): guest \(f.size) \(f.sha256.prefix(12)), rebuilt \(listing[p].map { "\($0.size) \($0.sha256?.prefix(12) ?? "-")" } ?? "missing")")
        }
        print("U1: \(g.files.count - bad.count)/\(g.files.count) guest files identical")
        #expect(bad.isEmpty, "\(bad.prefix(20))")
        #expect(g.deleted.allSatisfy { listing[$0] == nil }, "deleted files present")
        for ipa in g.ipas {
            let dir = try Fixtures.tempDir("ipa")
            defer { try? FileManager.default.removeItem(at: dir) }
            _ = try Fixtures.run(["/usr/bin/unzip", "-q", ipa.ipa, "-d", dir.path])
            let payload = dir.appendingPathComponent("Payload/\(ipa.app)")
            let installed = listing.keys.filter { $0.contains("mobile/Applications/") && $0.hasSuffix("/\(ipa.app)") }
            #expect(installed.count == 1, "\(ipa.app) installed \(installed.count) times")
            guard let appDir = installed.first else { continue }
            var n = 0, mismatched: [String] = []
            let e = FileManager.default.enumerator(at: payload, includingPropertiesForKeys: [.isRegularFileKey])!
            for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let rel = String(u.resolvingSymlinksInPath().path.dropFirst(payload.resolvingSymlinksInPath().path.count + 1))
                let want = SHA256.hash(data: try Data(contentsOf: u)).map { String(format: "%02x", $0) }.joined()
                n += 1
                if listing["\(appDir)/\(rel)"]?.sha256 != want { mismatched.append(rel) }
            }
            print("U1: \(ipa.app): \(n - mismatched.count)/\(n) Payload files identical; differ: \(mismatched.prefix(8))")
            #expect(n > 0 && mismatched.count <= 2, "\(ipa.app): \(mismatched)")     // installd may rewrite Info.plist / sign
        }
        #expect(try digest(base).merging(try digest(overlay)) { a, _ in a } == before, "base or overlay changed")
    }

    /// path -> (size, mtime) of every file under `dir`: cheap evidence nothing wrote there.
    func digest(_ dir: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])!
        for case let u as URL in e {
            let v = try u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            out[u.path] = "\(v.fileSize ?? -1) \(v.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return out
    }
}
