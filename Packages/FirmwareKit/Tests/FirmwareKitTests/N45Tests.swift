import Foundation
import Testing

@testable import FirmwareKit

/// The n45 (iPod touch 1G) pieces against devos50's public n45ap_v1 set, which is built from the 3A101a IPSW
/// (~/Developer/qemu-ios-files/ipod1g: nor_n45ap.bin, iboot_204_n45ap.bin, the IPSW). Skips when absent.
@Suite(.detachesItsImages) struct N45Tests {
    static let files = Oracle.path("Developer/qemu-ios-files/ipod1g")
    static let ipsw = files.appendingPathComponent("iPod1,1_1.1_3A101a_Restore.ipsw")
    static var available: Bool { Oracle.exists(ipsw) && Oracle.exists(files.appendingPathComponent("nor_n45ap.bin")) }
    static let prefix = "Firmware/all_flash/all_flash.n45ap.production/"

    /// generate_nor.c's SysCfg values, so the whole 1 MiB compares.
    static let devos50 = UnitIdentity(fields: [
        ("model-number", .string("MA623")), ("region-info", .string("B/LL")),
        ("serial-number", .string("ABCDEFG")), ("battery-serial", .string("690476146348"))
    ])

    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"))
    func norMatchesDevos50() throws {
        guard Self.available else { try FixtureRequirements.missing(#"N45Tests.swift: Self.available"#) }
        let a = IPSWArchive(Self.ipsw)
        var images: [String: Data] = [:]
        for n in try a.names() where n.hasPrefix(Self.prefix) && n.hasSuffix(".img2") {
            let body = try Apple8900.body(a.read(n))
            images[try IMG2.Header(body).type] = body
        }
        let got = try N45NOR.build(identity: Self.devos50, images: images)
        let want = try Data(contentsOf: Self.files.appendingPathComponent("nor_n45ap.bin"))
        let diff = zip(got, want).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(
            got.count == want.count && diff.isEmpty,
            "\(diff.count) bytes differ, first at \(diff.prefix(8).map { String($0, radix: 16) })"
        )
    }

    /// 2.0 and later (IMG3 firmware) are refused by the board check, naming the piece, before the IPSW is read; 1.x passes.
    @Test func refusesIMG3Firmware() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func check(_ id: String) throws {
            let o = Preparer.Options(entry: try Oracle.entry(id), ipsw: dir, out: dir, helper: nil, guestTools: dir)
            try N45Board(o).check(Recipe.Context(o, recipe: o.entry.recipe!, emit: { _ in }))
        }
        for id in ["m68ap-5A345", "m68ap-7E18", "n45ap-5A347", "n45ap-7E18"] {
            let error = #expect(throws: FirmwareError.self, "\(id)") { try check(id) }
            #expect(error?.piece == N45Board.onePiece, "\(id)")
        }
        for id in ["m68ap-1A543a", "m68ap-4A102", "n45ap-4A102"] { try check(id) }
    }

    /// iBoot-204 fills arm-io/sdio's local-mac-address only from nvram wifiaddr (its SysCfg fallback returns 0):
    /// the NOR's nvram carries the identity's Wi-Fi MAC, and none when the identity has none (devos50's set).
    @Test func nvramCarriesTheWiFiMAC() throws {
        var body = Data(count: IMG2.headerSize + 16)
        body[0x10] = 16
        let images = Dictionary(uniqueKeysWithValues: N45NOR.order.map { ($0, body) })
        let id = try UnitIdentity.synthesizeIPod(
            seed: "n45-nvram",
            modelNumber: "MA623",
            regionInfo: "LL/A",
            bluetooth: false
        )
        let nvram = { (nor: Data) in String(decoding: nor[N45NOR.nvram + 0x30..<N45NOR.nvram + 0x830], as: UTF8.self) }
        let text = nvram(try N45NOR.build(identity: id, images: images))
        #expect(text.contains("\0wifiaddr=\(id["wifi-mac"]!.uppercased())\0") && !text.contains("btaddr"))
        #expect(!nvram(try N45NOR.build(identity: Self.devos50, images: images)).contains("wifiaddr"))
    }

    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"))
    func iBootIsTheDecryptedComponent() throws {
        guard Self.available else { try FixtureRequirements.missing(#"N45Tests.swift: Self.available"#) }
        let body = try Apple8900.body(IPSWArchive(Self.ipsw).read(Self.prefix + "iBoot.n45ap.RELEASE.img2"))
        let h = try IMG2.Header(body)
        #expect(h.type == "ibot" && h.loadAddress == 0x1800_0000)
        #expect(try IMG2.payload(body) == Data(contentsOf: Self.files.appendingPathComponent("iboot_204_n45ap.bin")))
    }

    /// The oracle, ported from the ipod-1g-fires agent's scratch tools that proved the layout on the emulator:
    /// logical.py's reading of the store (per logical page, the newest type-0x40 copy by the spare's lpn and age)
    /// as a flat image from LBA 3, and mkstore.py's VFL context (usnDec, next page, checksums; no reserved pool).
    static func oracle(_ store: URL) throws -> (image: Data, vfl: [UInt8]) {
        var best: [UInt32: (key: (UInt32, Int), page: Data)] = [:]
        let nand = try PageNANDImage.Store(store)
        for b in 0..<8 {
            for p in nand.dataBlocks(b).flatMap({ $0 * 128..<($0 + 1) * 128 }) {
                let raw = try nand.read(b, p)
                guard raw[2048 + 9] == 0x40 else { continue }
                let u32 = { (o: Int) in (0..<4).reduce(UInt32(0)) { $0 | UInt32(raw[o + $1]) << (8 * $1) } }
                let (lpn, key) = (u32(2048), (u32(2052), (p % 128) * 8 + b))
                if let old = best[lpn], old.key >= key { continue }
                best[lpn] = (key, Data(raw[0..<2048]))
            }
        }
        let image = (3...best.keys.max()!).reduce(into: Data()) { $0 += best[$1]?.page ?? Data(count: 2048) }
        var d = [UInt8](repeating: 0, count: 2048)
        let put = { (o: Int, v: UInt32, n: Int) in for i in 0..<n { d[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) }
        }
        for i in 0..<3 { put(4 + 2 * i, UInt32(i), 2) }
        for i in 1672..<1672 + 281 { d[i] = 0xFF }
        put(1954, 35, 2)
        put(0xC, 0xFFFF_FFFF, 4)
        put(0x12, 8, 2)
        let w = stride(from: 0, to: 0x7F8, by: 4).map { o in
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(d[o + $1]) << (8 * $1) }
        }
        put(0x7F8, w.reduce(0, &+) &+ 0xAABB_CCDD, 4)
        put(0x7FC, w.reduce(0, ^) ^ 0xAABB_CCDD, 4)
        return (image, d)
    }

    /// A volume with data in its first and third logical blocks and none in its second: every page of all three
    /// is written (the FTL fails the read of a mapped page left erased), the VFL context is VFL_Format's, and the
    /// oracle's reading of the store is the volume.
    @Test func storeLayout() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("n45-store-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let pp = N45NAND.page
        let ps = N45NAND.pagesPerSuperblock
        let fsPages = 3 * ps - 3 - 100  // ends inside block 2
        var vol = Data(count: fsPages * pp)
        for (i, v) in [(0, 0x48), (2 * ps, 0x11), (fsPages - 1, 0x7F)] {
            vol.replaceSubrange(i * pp..<i * pp + 4, with: [UInt8](repeating: UInt8(v), count: 4))
        }
        let volume = dir.appendingPathComponent("volume.img")
        let out = dir.appendingPathComponent("nand")
        try vol.write(to: volume)
        let (written, meta) = try N45NAND.write(volume: volume, out: out, filID: 0x4330_3032)
        #expect(written == 3 * ps - 3 && meta == 1 + 8 + 8 * 8 + 1 + 4 + 1 + 3)
        // a page the store holds (not erased: a hole, or every bit set)
        let store = try PageNANDImage.Store(out)
        let file = { (p: N45NAND.Page) -> [UInt8]? in
            let r = try? store.read(p)
            return r == PageNANDImage.s5l8900(banks: 8).blankRecord ? nil : r
        }
        let absent = (0..<3 * ps).filter { file(N45NAND.location(lpn: $0)) == nil }
        #expect(
            absent.isEmpty && file(N45NAND.location(lpn: 3 * ps)) == nil,
            "absent lpns \(absent.prefix(8))"
        )
        // The map pages as _FTLRestore finds them (it scans the context blocks and copies each type-0x46 page to
        // its in-RAM map at index * 2 KiB): one bank's 4096 entries, indices 0-3 only. An index past 3 overruns
        // the kernel's 8 KiB map (smoke #70: a hard-Stopped 1.x device panicked on its next boot).
        var maps: [Int: [UInt8]] = [:]
        for bank in 0..<N45NAND.banks {
            for blockPage in 0..<N45NAND.pagesPerBlock {
                let raw = file(N45NAND.Page(bank: bank, page: N45NAND.ftlStart * N45NAND.pagesPerBlock + blockPage))
                guard let b = raw, b[pp + 9] == 0x46 else { continue }
                maps[Int(b[pp + 4]) | Int(b[pp + 5]) << 8] = Array(b[0..<pp])
            }
        }
        #expect(maps.keys.sorted() == [0, 1, 2, 3], "map page indices \(maps.keys.sorted())")
        let entry = { (lbn: Int) -> Int in
            maps[lbn / 1024].map { Int($0[2 * (lbn % 1024)]) | Int($0[2 * (lbn % 1024) + 1]) << 8 } ?? -1
        }
        #expect(entry(0) == 23 && entry(3799) == 3799 + 23 && entry(3800) == 0xFFFF && entry(4095) == 0xFFFF)

        let (image, theirs) = try Self.oracle(out)
        #expect(image.count / pp == 3 * ps - 3 && image == vol + Data(count: 100 * pp))

        let le = { (b: [UInt8], o: Int, n: Int) in (0..<n).reduce(UInt64(0)) { $0 | UInt64(b[o + $1]) << (8 * $1) } }
        for bank in 0..<N45NAND.banks {
            let first = try #require(file(N45NAND.Page(bank: bank, page: 35 * 128)))
            for c in 1..<8 {
                #expect(file(N45NAND.Page(bank: bank, page: 35 * 128 + c)) == first)
            }
            #expect(file(N45NAND.Page(bank: bank, page: 35 * 128 + 8)) == nil)
            let d = Array(first[0..<pp])
            #expect(
                Array(first[pp...]) == [UInt8](repeating: 0xFF, count: 8) + [0, 0x80]
                    + [UInt8](repeating: 0xFF, count: 54)
            )
            #expect(le(d, 0, 4) == UInt64(bank) && le(d, 0xC, 4) == 0xFFFF_FFFF && le(d, 0x12, 2) == 8)
            #expect(
                le(d, 0x14, 2) == 1 && le(d, 0x1A, 2) == 1 && le(d, 0x1C, 2) == 39 && le(d, 0x1E, 2) == 162
                    && le(d, 0x20, 2) == 4095
            )
            #expect(
                d[0x688 + 63] == 0xFE && (0..<4).map { le(d, 0x7A2 + 2 * $0, 2) } == [35, 36, 37, 38]
                    && le(d, 0x7AA, 2) == 820
            )
            let words = stride(from: 0, to: 0x7F8, by: 4).map { UInt32(le(d, $0, 4)) }
            #expect(
                le(d, 0x7F8, 4) == UInt64(words.reduce(0, &+) &+ 0xAABB_CCDD)
                    && le(d, 0x7FC, 4) == UInt64(words.reduce(0, ^) ^ 0xAABB_CCDD)
            )
            // Against mkstore.py's context only the bank's age, the reserved pool, the other info blocks, the last
            // aBadMark byte it leaves 0 and the checksums differ.
            let diff = Set((0..<pp).filter { d[$0] != theirs[$0] })
            let allowed = Set(0..<4).union(0x14..<0x22).union([0x688 + 63, 0x7A1]).union(0x7A4..<0x7AC).union(
                0x7F8..<0x800
            )
            #expect(
                diff.isSubset(of: allowed),
                "bank \(bank): \(diff.subtracting(allowed).sorted().map { String($0, radix: 16) })"
            )
        }
    }

    /// The NAND signature off each build's iBoot: C002 for 3A101a (so its store is today's), C003 for 4B1 (in the
    /// app's IPSW cache, smoke #52), and only that word differs between the two stores' metadata.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"))
    func nandSignatureFromIBoot() throws {
        let iboot = { (ipsw: URL) in
            try IMG2.payload(Apple8900.body(IPSWArchive(ipsw).read(Self.prefix + "iBoot.n45ap.RELEASE.img2")))
        }
        let b4B1 = Oracle.path(
            "Library/Caches/gold.samhenri.LightTouchMac/IPSW/1b818911316e4248ee01d3ec67f9d39afc3db240.ipsw"
        )
        guard Self.available, Oracle.exists(b4B1) else { try FixtureRequirements.missing("N45 3A101a and 4B1 IPSWs") }
        #expect(try N45NAND.filID(iBoot: iboot(Self.ipsw)) == 0x4330_3032)
        #expect(try N45NAND.filID(iBoot: iboot(b4B1)) == 0x4330_3033)
    }

    @Test func nandSignatureMetadataAndRejection() throws {
        #expect(throws: FirmwareError.self) { try N45NAND.filID(iBoot: Data(count: 64)) }
        let c2 = N45NAND.metadataPages(fsPages: 100, filID: 0x4330_3032)
        let c3 = N45NAND.metadataPages(fsPages: 100, filID: 0x4330_3033)
        let page0 = N45NAND.Page(bank: 0, page: 0)
        #expect(c2.keys == c3.keys && c2.filter { $0.key != page0 }.allSatisfy { c3[$0.key] == $0.value })
        #expect(
            Array(c2[page0]![0..<4]) == [0x32, 0x30, 0x30, 0x43]
                && Array(c3[page0]![0..<4]) == [0x33, 0x30, 0x30, 0x43]
        )
    }

    /// 3A101a's rootfs vfdecrypt key (022-3601-4.dmg).
    static let rootfsKey = "6f021b478cc21ff77f775850c0efc2e66fd015f6a6894be079ee1351dce9af069f915f3d"

    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"))
    func stockUnsignedActivation() async throws {
        guard Self.available else { try FixtureRequirements.missing(#"N45Tests.swift: Self.available"#) }
        try await Oracle.withTemp { dir in
            let enc = dir.appendingPathComponent("enc.dmg")
            let dmg = dir.appendingPathComponent("rootfs.dmg")
            let raw = dir.appendingPathComponent("rootfs.hfs")
            try IPSWArchive(Self.ipsw).extract("022-3601-4.dmg", to: enc)
            try VFDecrypt.decrypt(input: enc, output: dmg, key: Data(hex: Self.rootfsKey)!)
            try await UDIF.extractRootfs(dmg: dmg, to: raw)
            let volume = try HFSPlusVolume(raw)
            let stock = try volume.contents(volume.record(at: "usr/libexec/lockdownd"))
            let target = dir.appendingPathComponent("lockdownd")
            try stock.write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: target.path)
            #expect(MachOSignature.codeSignature(in: stock) == nil)
            let result = try Activation.run(on: target)
            #expect(
                (try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?
                    .intValue == 0o555
            )
            #expect(result.inputSHA256 != result.outputSHA256)
            #expect(MachOSignature.codeSignature(in: try Data(contentsOf: target)) == nil)
        }
    }

    /// 1.x GL front end on the stock 3A101a IPSW's OpenGLES: the export scan, the check against opengles-1x.exports
    /// (and its refusal of a list that differs), and, with an armv6.itpack at hand, N45Board.bake on the three stock
    /// files (OpenGLES, SpringBoard's job, SystemVersion), with the GL front end and without: the paths written (the
    /// loader among them), the record, the hook's and OpenGLES.baked's bytes, the LK_* job.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"))
    func frontEndAndBake() async throws {
        let it = Oracle.qemuIOS.appendingPathComponent("contrib/it-gles")
        let list = it.appendingPathComponent(N45Board.openGLESExports)
        let itpack = Oracle.guestPackages.appendingPathComponent("armv6.itpack")
        guard Self.available, Oracle.exists(list) else {
            try FixtureRequirements.missing(#"N45Tests.swift: Self.available, Oracle.exists(list)"#)
        }
        try await Oracle.withTemp { dir in
            let fm = FileManager.default
            let enc = dir.appendingPathComponent("enc.dmg")
            let dmg = dir.appendingPathComponent("rootfs.dmg")
            let raw = dir.appendingPathComponent("rootfs.hfs")
            try IPSWArchive(Self.ipsw).extract("022-3601-4.dmg", to: enc)
            try VFDecrypt.decrypt(input: enc, output: dmg, key: Data(hex: Self.rootfsKey)!)
            try await UDIF.extractRootfs(dmg: dmg, to: raw)
            var stock: [String: Data] = [:]
            do {
                let v = try HFSPlusVolume(raw)
                for p in [N72Board.openGLES, SystemEdits.springBoardJob, GuestPackage.systemVersion] {
                    stock[p] = try v.contents(v.record(at: p))
                }
                // what the seed's load checks read: 1.x's own executables and libSystem
                for p in FitCheck.Firmware.precedentBinaries + ["usr/lib/libSystem.B.dylib"] {
                    stock[p] = try? v.contents(v.record(at: p))
                }
            }
            for u in [enc, dmg, raw] { try fm.removeItem(at: u) }
            let stockGL = stock[N72Board.openGLES]!
            let gl = dir.appendingPathComponent("OpenGLES")
            try stockGL.write(to: gl)

            let names = try N72Board.exportedSymbols(stockGL)
            #expect(names.count == 186)
            let (ok, line) = try N72Board.frontEnd(try? Data(contentsOf: gl), exports: list)
            #expect(ok, "\(line)")
            let short = dir.appendingPathComponent("short.exports")
            try (String(contentsOf: list, encoding: .utf8).replacingOccurrences(of: "\nglFlush\n", with: "\n")).write(
                to: short,
                atomically: true,
                encoding: .utf8
            )
            #expect(try N72Board.frontEnd(try? Data(contentsOf: gl), exports: short).0 == false)
            // 2.x's list is not 1.x's
            #expect(
                try N72Board.frontEnd(
                    try? Data(contentsOf: gl),
                    exports: it.appendingPathComponent("opengles-2x.exports")
                ).0 == false
            )

            guard Oracle.exists(itpack) else {
                try FixtureRequirements.missing(#"N45Tests.swift: Oracle.exists(itpack)"#)
            }
            let helpers = dir.appendingPathComponent("helpers")
            try SystemEdits.mkdirs(helpers)
            for u in [itpack, list] { try fm.copyItem(at: u, to: helpers.appendingPathComponent(u.lastPathComponent)) }
            for gles in [true, false] {
                func volume(_ name: String) throws -> URL {
                    let m = dir.appendingPathComponent("\(name)-\(gles)")
                    for (p, d) in stock {
                        try SystemEdits.mkdirs(m.appendingPathComponent(p).deletingLastPathComponent())
                        try SystemEdits.put(d, m.appendingPathComponent(p), mode: p.hasSuffix(".plist") ? 0o644 : 0o755)
                    }
                    return m
                }
                let a = try volume("swift")
                let log = FitCheck.Log()
                let (report, record, owned) = try N45Board.bake(
                    MountedVolume(root: a),
                    helpers: helpers,
                    gles: gles,
                    fit: log,
                    log: { _ in }
                )
                // the seed's loader proof and the LayerKit switches' readers are on the record
                #expect(log.fits.contains { $0.piece.hasPrefix("it_boot") && $0.fits })
                #expect(
                    log.fits.contains { $0.piece == "SpringBoard environment (LK_ENABLE_OGL, LK_AUTO_ENABLE_OGL)" }
                        == gles
                )
                #expect(record.family == "n45-ios1" && record.hooks == (gles ? ["/" + N72Board.openGLES] : []))
                #expect(record.itpackSHA256 == (try Oracle.sha256(file: itpack)))
                #expect((report["gles_engine"] is NSNull) != gles)
                #expect(owned.contains(GuestPackage.loader.0) && owned.contains(GuestPackage.loader.1))
                for rel in owned {  // everything written is there
                    var st = stat()
                    #expect(lstat(a.appendingPathComponent(rel).path, &st) == 0, "\(rel)")
                }
                let env = { (m: URL) in
                    (NSDictionary(contentsOf: m.appendingPathComponent(SystemEdits.springBoardJob))?[
                        "EnvironmentVariables"
                    ] as? [String: String]) ?? [:]
                }
                #expect(
                    env(a)["LK_ENABLE_OGL"] == (gles ? "1" : nil) && env(a)["LK_AUTO_ENABLE_OGL"] == (gles ? "0" : nil)
                        && env(a)["LK_ENABLE_MBX2D"] == nil
                )
                let hooked = try Data(contentsOf: a.appendingPathComponent(N72Board.openGLES))
                let baked = a.appendingPathComponent(N72Board.openGLES + ".baked")
                if gles {
                    #expect(try Data(contentsOf: baked) == stockGL && hooked != stockGL)
                    // the front end exports the firmware's own names
                    #expect(try N72Board.exportedSymbols(hooked) == names)
                } else {
                    #expect(hooked == stockGL && !fm.fileExists(atPath: baked.path))
                }
            }
        }
    }

    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"))
    func components() throws {
        guard Self.available else { try FixtureRequirements.missing(#"N45Tests.swift: Self.available"#) }
        let c = try BuildComponents.load(IPSWArchive(Self.ipsw), board: "n45ap")
        #expect(
            c["iBoot"] == Self.prefix + "iBoot.n45ap.RELEASE.img2" && c["AppleLogo"] == Self.prefix + "applelogo.img2"
        )
        #expect(c["KernelCache"] == "kernelcache.release.s5l8900xrb" && c["OS"] == "022-3601-4.dmg")
    }
    /// 1.0's BTServer logs to /var/logs/BTServer, which the image lacks: 1.x's launchd never started it until the
    /// directory was made. Made for a kept job's log paths (under private/var), not for paths already there or not absolute.
    @Test func logDirsMade() throws {
        try Oracle.withTemp { m in
            let jobs = m.appendingPathComponent(SystemEdits.daemons)
            try SystemEdits.mkdirs(jobs)
            try SystemEdits.mkdirs(m.appendingPathComponent("private/var/log"))
            func job(_ name: String, _ d: [String: Any]) throws {
                try PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0).write(
                    to: jobs.appendingPathComponent(name)
                )
            }
            try job(
                "com.apple.BTServer.plist",
                ["StandardOutPath": "/var/logs/BTServer/stdout", "StandardErrorPath": "/var/logs/BTServer/stderr"]
            )
            try job("present.plist", ["StandardErrorPath": "/var/log/present.log"])
            try job("relative.plist", ["StandardErrorPath": "logs/x"])
            #expect(
                try N45Board.makeLogDirs(
                    MountedVolume(root: m),
                    jobs: ["com.apple.BTServer.plist", "present.plist", "relative.plist"]
                ) == [
                    "private/var/logs/BTServer"
                ]
            )
            #expect(Oracle.exists(m.appendingPathComponent("private/var/logs/BTServer")))
        }
    }
    /// The 1.x root's journal is placed before the mount, so what the host writes on the mount and removes before
    /// unmounting doesn't move it: here a block of fseventsd's event log, which fseventsd writes before the recipe's
    /// edits on some hosts and runs and not on others. Journaled by `diskutil enableJournal` on the mount, the journal
    /// came after that block and moved with it.
    @Test func theRootJournalStaysWhereItIsWhateverTheHostWritesOnTheMount() async throws {
        try await Oracle.withTemp { dir in
            var journals: [Int?] = []
            for junk in [false, true] {
                let image = dir.appendingPathComponent("root-\(junk).img")
                try HFSPlusWriter.makeHFS(image, size: 64 << 20, name: "Root", journaled: false)
                try await N45Board.withJournaledRoot(image, at: dir.appendingPathComponent("mnt"), date: 0) { v in
                    if junk {
                        try v.makeDirectory(".fseventsd")
                        try v.put(Data(count: 4096), at: ".fseventsd/0000000000000001")
                    }
                    try v.put(Data(count: 3 * 4096), at: "a")
                }
                let journal = try HFSPlusVolume(image).journal()
                #expect(journal?.needsInit == true, "left for the device's first mount")
                journals.append(journal?.offset)
            }
            #expect(journals[0] != nil && journals[0] == journals[1], "journal offsets \(journals)")
        }
    }
    /// 1.x's lock screen deep-sleeps seconds after boot and the machine cannot resume: SBDisableIdleSleep in the user's
    /// SpringBoard preferences where SpringBoard names it, beside what is there; nothing where it does not.
    @Test func noIdleSleepBaked() throws {
        try Oracle.withTemp { m in
            let sb = m.appendingPathComponent(N72Board.springBoard)
            let rel = N45Board.rootLibrary + "/Preferences/com.apple.springboard.plist"
            let plist = m.appendingPathComponent(rel)
            try SystemEdits.mkdirs(sb.deletingLastPathComponent())
            try Data("\0SBDisableIdleSleepX\0".utf8).write(to: sb)
            #expect(try !N45Board.bakeNoIdleSleep(MountedVolume(root: m), prefs: rel) && !Oracle.exists(plist))
            try Data("\0SBAutoLockTime\0SBDisableIdleSleep\0".utf8).write(to: sb)
            try SystemEdits.seedPlist(plist) { $0["SBAutoLockTime"] = -1 }
            #expect(try N45Board.bakeNoIdleSleep(MountedVolume(root: m), prefs: rel))
            let d = try #require(
                PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
            )
            #expect(d["SBDisableIdleSleep"] as? Bool == true && d["SBAutoLockTime"] as? Int == -1)
        }
    }
    /// 1.1.3 moved SpringBoard to the mobile user (its launchd job's UserName): the baked preferences go to its home,
    /// mobile-owned; 1.0's job names no user and SpringBoard reads root's (1.1.4 sat at 0x5 brightness with root's).
    /// configd's SystemConfiguration preferences move with it, from root's home to /private/var/preferences (1.1.4
    /// joined nothing at boot with them in root's home).
    @Test func springBoardUserFollowsItsJob() throws {
        try Oracle.withTemp { m in
            let rootSC = N45Board.rootLibrary + "/Preferences/SystemConfiguration"
            #expect(N45Board.springBoardUser(MountedVolume(root: m)) == (N45Board.rootLibrary, 0))
            #expect(N45Board.scPrefs(MountedVolume(root: m)) == rootSC)
            let job = m.appendingPathComponent(SystemEdits.daemons + "/com.apple.SpringBoard.plist")
            try SystemEdits.mkdirs(job.deletingLastPathComponent())
            try PropertyListSerialization.data(
                fromPropertyList: ["Label": "com.apple.SpringBoard"],
                format: .xml,
                options: 0
            ).write(to: job)
            #expect(N45Board.springBoardUser(MountedVolume(root: m)) == (N45Board.rootLibrary, 0))
            #expect(N45Board.scPrefs(MountedVolume(root: m)) == rootSC)
            try PropertyListSerialization.data(
                fromPropertyList: ["Label": "com.apple.SpringBoard", "UserName": "mobile"],
                format: .xml,
                options: 0
            ).write(to: job)
            #expect(N45Board.springBoardUser(MountedVolume(root: m)) == ("private/var/mobile/Library", 501))
            let owned = try N45Board.seedSystemConfiguration(MountedVolume(root: m))
            let sc = "private/var/preferences/SystemConfiguration"
            #expect(owned.contains(sc + "/preferences.plist") && owned.contains(sc + "/com.apple.wifi.plist"))
            let known = try #require(
                PropertyListSerialization.propertyList(
                    from: Data(contentsOf: m.appendingPathComponent(sc + "/com.apple.wifi.plist")),
                    format: nil
                ) as? [String: Any]
            )
            #expect((known["List of known networks"] as? [[String: Any]])?.first?["SSID_STR"] as? String == "qemu-ios")
            #expect(!Oracle.exists(m.appendingPathComponent(rootSC)))
        }
    }
    /// 3A101a's LaunchDaemons: the bake keeps mDNSResponder, 1.x's only host-name resolver (without it Safari sent no
    /// DNS query and found no server), and still drops the jobs that wait on absent hardware.
    @Test func resolverKept() {
        let jobs = [
            "com.apple.AddressBook.plist", "com.apple.BTServer.plist", "com.apple.CommCenter.plist",
            "com.apple.configd.plist",
            "com.apple.DumpPanic.plist", "com.apple.crashreporterd.plist", "com.apple.daily.plist",
            "com.apple.iapd.plist",
            "com.apple.mDNSResponder.plist", "com.apple.mobile.lockdown.plist", "com.apple.notifyd.plist",
            "com.apple.SpringBoard.plist", "com.apple.syslogd.plist", "com.apple.update.plist",
            "com.apple.usbptpd.plist",
            "coreaudiod.plist"
        ]
        let removed = N45Board.removedDaemons(jobs)
        #expect(!removed.contains("com.apple.mDNSResponder.plist"), "\(removed)")
        #expect(
            removed == [
                "com.apple.BTServer.plist", "com.apple.DumpPanic.plist", "com.apple.crashreporterd.plist",
                "com.apple.daily.plist", "com.apple.iapd.plist", "com.apple.syslogd.plist", "com.apple.update.plist"
            ]
        )
        // The iPhone keeps BTServer (the M68's Bluetooth chip answers; without it SpringBoard stalls app launches).
        #expect(N45Board.removedDaemons(jobs, iPhone: true) == removed.filter { $0 != "com.apple.BTServer.plist" })
    }
    /// 1.1.3+ (4A93, 4B1) ship com.apple.mobile.lockbot, through which their lockdownd starts every service (AFC):
    /// the bake keeps it; 1.1.1 (3A110a) has none. Read off the real system volumes.
    @Test(
        .enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"),
        arguments: [("n45ap-4A93", true), ("n45ap-4B1", true), ("n45ap-3A110a", false)]
    )
    func lockbotKeptWhereShipped(_ id: String, _ ships: Bool) async throws {
        guard let url = try K48IBootTests.cachedIPSW(id) else {
            try FixtureRequirements.missing("cached IPSW for " + id)
        }
        try await Oracle.withTemp { dir in
            let ipsw = IPSWArchive(url)
            let e = try Oracle.entry(id)
            let os = try BuildComponents.load(ipsw, board: e.board)["OS"]!
            let key = try #require(Data(hex: e.key(forPath: os).key))
            let dmg = dir.appendingPathComponent("rootfs.dmg")
            let raw = dir.appendingPathComponent("rootfs.hfs")
            try ipsw.stream(os) { try VFDecrypt.decrypt(from: $0.fileDescriptor, output: dmg, key: key) }
            try await UDIF.extractRootfs(dmg: dmg, to: raw)
            let jobs = try HFSPlusVolume(raw).listing(under: SystemEdits.daemons, hashes: false)
                .map { ($0.path as NSString).lastPathComponent }.filter { $0.hasSuffix(".plist") }
            let lockbot = "com.apple.mobile.lockbot.plist"
            let removed = N45Board.removedDaemons(jobs)
            #expect(jobs.contains(lockbot) == ships, "\(id): \(jobs)")
            #expect(
                !removed.contains(lockbot) && !removed.contains("com.apple.mDNSResponder.plist")
                    && removed.contains("com.apple.syslogd.plist"),
                "\(id): \(removed)"
            )
            #expect(N45Board.keptDaemonsFit(jobs).fits)
        }
    }

    /// The M68's four chip enables: a superblock spans four banks, nothing lands on banks 4-7, and the factory
    /// table carries its good-block bitmap (iBoot-159 looks for the VFL context only in blocks it marks good).
    @Test func iPhoneStoreLayout() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("m68-store-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let pp = N45NAND.page
        let ps = N45NAND.superblock(4)
        let volume = dir.appendingPathComponent("volume.img")
        let out = dir.appendingPathComponent("nand")
        try Data(count: (2 * ps - 3) * pp).write(to: volume)
        let (written, _) = try N45NAND.write(volume: volume, out: out, filID: 0x4330_3030, banks: 4, bbtMap: true)
        #expect(written == 2 * ps - 3)
        let names = ["cs0.pages", "cs1.pages", "cs2.pages", "cs3.pages", "geometry.json"]
        #expect(try fm.contentsOfDirectory(atPath: out.path).sorted() == names)
        #expect(PageNANDImage.of(out) == .s5l8900(banks: 4))
        #expect(N45NAND.location(lpn: 5, banks: 4) == N45NAND.Page(bank: 1, page: (201 + 23) * 128 + 1))
        let store = try PageNANDImage.Store(out)
        let bbt = try store.read(N45NAND.Page(bank: 3, page: 4095 * 128))
        #expect(Array(bbt[0..<13]) == Array("DEVICEINFOBBT".utf8) && bbt[0x34] == 0x00 && bbt[0x35] == 0x02)
        #expect(bbt[0x38] == 0xFF && bbt[0x38 + 511] == 0x7F)
        let fil = try store.read(N45NAND.Page(bank: 0, page: 0))
        #expect(Array(fil[0..<4]) == Array("000C".utf8))
        // The N45's table stays as devos50 wrote it: no bitmap.
        let n45 = N45NAND.metadataPages(fsPages: 16, filID: 0x4330_3032)[N45NAND.Page(bank: 0, page: 4095 * 128)]!
        #expect(n45[0x34] == 0 && n45[0x38] == 0)
    }
}
