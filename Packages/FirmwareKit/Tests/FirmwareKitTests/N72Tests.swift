import Foundation
import Testing
@testable import FirmwareKit

/// N72 format contracts, independent legacy digests, and optional stock-firmware bake checks.
@Suite struct N72Tests {
    /// Restore ramdisks are encrypted IMG3s outside all_flash. Omitting their
    /// KBAGs aborts the AES model during a stock USB restore, before bootx.
    @Test func restoreRamdiskKeysAreExported() throws {
        let entry = try Oracle.entry("n72ap-5F138")
        try Oracle.withTemp { dir in
            let plist: [String: Any] = [
                "ProductType": "iPod2,1", "ProductVersion": "2.1.1", "ProductBuildVersion": "5F138",
                "DeviceMap": [["BoardConfig": "n72ap", "Platform": "s5l8720x"]],
                "KernelCachesByPlatform": ["s5l8720x": ["Release": "kernelcache.release.s5l8720x"]],
                "SystemRestoreImages": ["User": "rootfs.dmg"],
                "RestoreRamDisks": ["User": "018-4166-1.dmg", "Update": "018-4177-1.dmg"],
            ]
            let metadata = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try metadata.write(to: dir.appendingPathComponent("Restore.plist"))
            let components = try BuildComponents.fromRestore(RestoreInfo(plistData: metadata))
            for member in Set(components.values) {
                let path = dir.appendingPathComponent(member)
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (Data("3gmI".utf8) + DeviceTree.Value.le([20, 0, 0, 0])).write(to: path)
            }
            var expected = Data()
            for (index, component) in ["RestoreRamDisk", "UpdateRamDisk"].enumerated() {
                let kbag = Data((0..<32).map { UInt8($0 + index * 32) })
                let le = { (words: [UInt32]) in DeviceTree.Value.le(words) }
                let tag = Data("GABK".utf8) + le([52, 40, 1, 128]) + kbag
                let image = Data("3gmI".utf8) + le([UInt32(20 + tag.count), UInt32(tag.count), 0, 0]) + tag
                try image.write(to: dir.appendingPathComponent(try #require(components[component])))
                let key = try #require(entry.keys[component])
                let ivHex = try #require(key.iv)
                let iv = try #require(Data(hex: ivHex))
                let aesKey = try #require(Data(hex: key.key))
                expected += kbag + iv + aesKey
            }
            try K48Oracle.sh(["/usr/bin/zip", "-q", "-r", "fixture.ipsw", "Restore.plist", "Firmware",
                              "rootfs.dmg", "kernelcache.release.s5l8720x", "018-4166-1.dmg", "018-4177-1.dmg"], cwd: dir)
            let (blobs, names) = try N72Board.gidBlobs(IPSWArchive(dir.appendingPathComponent("fixture.ipsw")), entry: entry)
            #expect(blobs == expected)
            #expect(names == ["018-4166-1.dmg", "018-4177-1.dmg"])
        }
    }

    /// ipod2g_nand.selfcheck.
    @Test func metadataSelfcheck() throws {
        let p = N72NAND.metadataPages(blocks: 128000, epoch: 1)
        #expect(p.count == 50 && p.values.allSatisfy { $0.count == 4096 + 64 })
        let hdr = try #require(p[.init(cs: 1, page: 256)])
        #expect(N72NAND.crc(hdr[0..<0x10] + [0, 0, 0, 0] + hdr[0x14..<0x5C]) == UInt32(hdr[0x10]) | UInt32(hdr[0x11]) << 8 | UInt32(hdr[0x12]) << 16 | UInt32(hdr[0x13]) << 24)
        #expect(p[.init(cs: 2, page: 256)]![0x28..<0x30].reversed().reduce(0) { $0 << 8 | Int($1) } == 128002)
        #expect(N72NAND.predict(0) == .init(cs: 3, page: 256) && N72NAND.predict(1) == .init(cs: 0, page: 384))
    }

    @Test(arguments: [1, 127, 128, 129, 255, 256, 257, 1023, 1024, 1025, 128000, 1835008])
    func partitionAndFilesystemHaveTheSameAlternateHeader(_ blocks: Int) throws {
        let pages = N72NAND.gptPages(blocks)
        func le(_ data: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(0) { $0 | UInt64(data[offset + $1]) << (8 * $1) }
        }
        let first = le(pages[2], 0x20, 8), last = le(pages[2], 0x28, 8)
        #expect(first == 3)
        // Covers small/unaligned geometries too: even a one-block excess moves
        // the device-end alternate away from the filesystem's actual header.
        #expect(last - first + 1 == UInt64(blocks))
        #expect((last - first + 1) * 4096 - 1024 == UInt64(blocks) * 4096 - 1024)
        #expect(UInt64(N72NAND.crc(pages[2][0..<0x80])) == le(pages[1], 0x58, 4))
        var header = pages[1]; header.replaceSubrange(0x10..<0x14, with: [0, 0, 0, 0])
        #expect(UInt64(N72NAND.crc(header[0..<0x5C])) == le(pages[1], 0x10, 4))
        // Protective MBR geometry is deliberately outside this correction.
        #expect(le(pages[0], 0x1BE + 8, 4) == 3)
        #expect(le(pages[0], 0x1BE + 12, 4) == UInt64(blocks + 10))
    }

    /// Preserve48 historical metadata pages and qualify exactly the two GPT
    /// geometry replacements from independently captured Python output.
    @Test func metadataPreservesLegacyExceptExactPartitionGPT() throws {
        let want = LegacyPreparationGoldens.n72Metadata.map { line in
            let fields = line.split(separator: " ")
            let key = "\(fields[0]) \(fields[1])"
            return LegacyPreparationGoldens.n72ExactPartitionGPT[key].map { "\(key) \($0)" } ?? line
        }
        let got = N72NAND.metadataPages(blocks: 1835008, epoch: 4).sorted { ($0.key.cs, $0.key.page) < ($1.key.cs, $1.key.page) }
            .map { "\($0.key.cs) \($0.key.page) \(Oracle.sha256(Data($0.value)))" }
        #expect(got == want)
    }

    /// build_nor.py --identity over the 7E18 IPSW's all_flash: the same 1 MiB.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func norMatchesLegacyReference() throws {
        let fw = Oracle.firmware("n72ap-7E18")
        guard fw.available else { try FixtureRequirements.missing(#"N72Tests.swift: fw.available"#) }
        try Oracle.withTemp { dir in
            let ipsw = IPSWArchive(fw.ipsw), prefix = "Firmware/all_flash/all_flash.n72ap.production/"
            var images: [String: Data] = [:]
            for n in try ipsw.names() where n.hasPrefix(prefix) && n.hasSuffix(".img3") {
                images[try N72NOR.type(of: ipsw.read(n))] = try ipsw.read(n)
            }
            let id = try UnitIdentity.synthesizeIPod(seed: "n72-test", modelNumber: "MB528", regionInfo: "LL/A")
            let got = try N72NOR.build(identity: id, images: images, types: N72NOR.order, wrapTypes: nil)
            #expect(Oracle.sha256(got) == LegacyPreparationGoldens.n72NOR)
        }
    }

    /// The GL front end on 2.x against the oracle, 5F138's stock OpenGLES: the export scan as gles2x_exports.scan and,
    /// with an armv6.itpack at hand, GuestPackage.seed as mkpkg.seed: n72-ios2's hook puts the one front end
    /// (contrib/gles-public) over OpenGLES, the stock binary kept as OpenGLES.baked, every stock name still exported.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func frontEndMatchesPython() async throws {
        let fw = Oracle.firmware("n72ap-5F138"), dmg = fw.cache?.appendingPathComponent("rootfs.dmg")
        let it = Oracle.qemuIOS.appendingPathComponent("contrib/it-gles")
        guard let dmg, Oracle.exists(dmg) else { try FixtureRequirements.missing(#"N72Tests.swift: let dmg, Oracle.exists(dmg)"#) }
        try await Oracle.withTemp { dir in
            let raw = dir.appendingPathComponent("rootfs.hfs"), stock = dir.appendingPathComponent("OpenGLES")
            try await UDIF.extractRootfs(dmg: dmg, to: raw)
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
            guard Oracle.exists(itpack) else { try FixtureRequirements.missing(#"N72Tests.swift: Oracle.exists(itpack)"#) }
            // the firmware the seed's load checks read (5F138's own executables and libSystem)
            guard let base = try await FitFixture.volume("n72ap-5F138", FitFixture.stock("n72ap-5F138"), in: dir) else { try FixtureRequirements.missing(#"N72Tests.swift: let base = try await FitFixture.volume("n72ap-5F138", FitFixture.stock("n72ap-5F138"), in: dir)"#) }
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
    }

    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"))
    func stock2xSpringBoardReadsReorderTip() async throws {
        let fw = Oracle.firmware("n72ap-5F138")
        guard let dmg = fw.cache?.appendingPathComponent("rootfs.dmg"), Oracle.exists(dmg) else { try FixtureRequirements.missing(#"N72Tests.swift: let dmg = fw.cache?.appendingPathComponent("rootfs.dmg"), Oracle.exists(dmg)"#) }
        try await Oracle.withTemp { dir in
            let raw = dir.appendingPathComponent("rootfs.hfs")
            try await UDIF.extractRootfs(dmg: dmg, to: raw)
            let v = try HFSPlusVolume(raw)
            #expect(try v.contents(v.record(at: N72Board.springBoard)).range(of: Data(N72Board.reorderTip.utf8)) != nil)
        }
    }
}
