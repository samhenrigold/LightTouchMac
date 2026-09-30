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

    /// The GL front end on 2.x against the oracle, 5F138's stock OpenGLES: the export scan as gles2x_exports.scan and,
    /// with an armv6.itpack at hand, GuestPackage.seed as mkpkg.seed: n72-ios2's hook puts the one front end
    /// (contrib/gles-public) over OpenGLES, the stock binary kept as OpenGLES.baked, every stock name still exported.
    @Test func frontEndMatchesPython() throws {
        let fw = Oracle.firmware("n72ap-5F138"), dmg = fw.cache?.appendingPathComponent("rootfs.dmg")
        let it = Oracle.qemuIOS.appendingPathComponent("contrib/it-gles")
        guard let dmg, Oracle.exists(dmg) else { return }
        try Oracle.withTemp { dir in
            let raw = dir.appendingPathComponent("rootfs.hfs"), stock = dir.appendingPathComponent("OpenGLES")
            try UDIF.extractRootfs(dmg: dmg, to: raw)
            let v = try HFSPlusVolume(raw)
            try v.contents(v.record(at: N72Board.openGLES)).write(to: stock)
            try FileManager.default.removeItem(at: raw)
            let scan = dir.appendingPathComponent("scan.txt")
            try K48Oracle.sh(["python3", "-c", "import sys; sys.path.insert(0, sys.argv[1]); import gles2x_exports; open(sys.argv[3], 'w').write('\\n'.join(gles2x_exports.scan(sys.argv[2])))",
                              it.path, stock.path, scan.path], cwd: dir)
            let names = try N72Board.exportedSymbols(Data(contentsOf: stock))
            let pyNames = try String(contentsOf: scan, encoding: .utf8).split(separator: "\n").map(String.init)
            #expect(names.count > 200 && names == pyNames)

            let itpack = Oracle.guestPackages.appendingPathComponent("armv6.itpack")
            guard Oracle.exists(itpack) else { return }
            // the firmware the seed's load checks read (5F138's own executables and libSystem)
            guard let base = try FitFixture.volume("n72ap-5F138", FitFixture.stock("n72ap-5F138"), in: dir) else { return }
            func volume(_ name: String) throws -> URL {
                let m = dir.appendingPathComponent(name), sv = m.appendingPathComponent(GuestPackage.systemVersion)
                try FileManager.default.copyItem(at: base, to: m)
                try SystemEdits.mkdirs(m.appendingPathComponent(N72Board.openGLES).deletingLastPathComponent())
                try SystemEdits.put(Data(contentsOf: stock), m.appendingPathComponent(N72Board.openGLES), mode: 0o755)
                try SystemEdits.mkdirs(sv.deletingLastPathComponent())
                try (["ProductBuildVersion": "5F138"] as NSDictionary).write(to: sv)
                return m
            }
            let a = try volume("swift"), b = try volume("python"), out = dir.appendingPathComponent("py.json")
            let (written, record) = try GuestPackage.seed(volume: a, itpack: itpack, gles: true)
            try K48Oracle.sh(["python3", "-c", """
                import json, sys; sys.path.insert(0, sys.argv[1]); import mkpkg
                made, rec = mkpkg.seed(sys.argv[2], sys.argv[3], True)
                json.dump({"written": made, "record": rec}, open(sys.argv[4], "w"))
                """, Oracle.qemuIOS.appendingPathComponent("contrib/guest-package").path, b.path, itpack.path, out.path], cwd: dir)
            let pyOut = try JSONSerialization.jsonObject(with: Data(contentsOf: out)) as! NSDictionary
            #expect(written == pyOut["written"] as? [String])
            #expect(NSDictionary(dictionary: record.object) == pyOut["record"] as? NSDictionary)
            #expect(record.family == "n72-ios2" && record.hooks == ["/" + N72Board.openGLES])
            let file = { (m: URL, s: String) in try Data(contentsOf: m.appendingPathComponent(N72Board.openGLES + s)) }
            let hooked = try file(a, ""), pyHooked = try file(b, ""), baked = try file(a, ".baked"), stockBytes = try Data(contentsOf: stock)
            #expect(hooked == pyHooked && hooked != stockBytes && baked == stockBytes)
            let modes = try [a, b].map { try SystemEdits.permissions($0.appendingPathComponent(N72Board.openGLES + ".baked")) }
            #expect(modes[0] == modes[1])
            #expect(Set(try N72Board.exportedSymbols(hooked)).isSuperset(of: names))   // every stock name, and 3.x-5.x's
        }
    }

    /// Smoke #45: without helpers (2.x/3.0) the bake writes it_prefs' key itself, SBDidShowReorderText = <true/> in
    /// mobile's com.apple.springboard.plist, keeping the Sounds defaults already there; a SpringBoard that doesn't name
    /// the key is left alone. With the 5F138 cache at hand, its real SpringBoard names it.
    @Test func reorderTipBakedWithoutHelpers() throws {
        try Oracle.withTemp { m in
            let sb = m.appendingPathComponent(N72Board.springBoard), plist = m.appendingPathComponent(N72Board.prefs + "/com.apple.springboard.plist")
            try SystemEdits.mkdirs(sb.deletingLastPathComponent())
            try Data("\0SBDidShowReorderTextX".utf8).write(to: sb)
            try SystemEdits.seedPlist(plist) { $0["lock-unlock"] = true }
            #expect(try N72Board.bakeReorderTip(m) == "SBDidShowReorderText baked (no helpers)")
            let d = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
            #expect(d[N72Board.reorderTip] as? Bool == true && d["lock-unlock"] as? Bool == true)
            #expect(try String(contentsOf: plist, encoding: .utf8).contains("<key>SBDidShowReorderText</key>\n\t<true/>"))

            try FileManager.default.removeItem(at: plist)
            try Data("SpringBoard".utf8).write(to: sb)
            #expect(try N72Board.bakeReorderTip(m).hasSuffix("left alone") && !Oracle.exists(plist))
        }
        let fw = Oracle.firmware("n72ap-5F138")
        guard let dmg = fw.cache?.appendingPathComponent("rootfs.dmg"), Oracle.exists(dmg) else { return }
        try Oracle.withTemp { dir in
            let raw = dir.appendingPathComponent("rootfs.hfs")
            try UDIF.extractRootfs(dmg: dmg, to: raw)
            let v = try HFSPlusVolume(raw)
            #expect(try v.contents(v.record(at: N72Board.springBoard)).range(of: Data(N72Board.reorderTip.utf8)) != nil)
        }
    }
}
