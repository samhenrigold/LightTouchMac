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

    /// iBoot-204 fills arm-io/sdio's local-mac-address only from nvram wifiaddr (its SysCfg fallback returns 0):
    /// the NOR's nvram carries the identity's Wi-Fi MAC, and none when the identity has none (devos50's set).
    @Test func nvramCarriesTheWiFiMAC() throws {
        var body = Data(count: IMG2.headerSize + 16)
        body[0x10] = 16
        let images = Dictionary(uniqueKeysWithValues: N45NOR.order.map { ($0, body) })
        let id = try UnitIdentity.synthesizeIPod(seed: "n45-nvram", modelNumber: "MA623", regionInfo: "LL/A", bluetooth: false)
        let nvram = { (nor: Data) in String(decoding: nor[N45NOR.nvram + 0x30..<N45NOR.nvram + 0x830], as: UTF8.self) }
        let text = nvram(try N45NOR.build(identity: id, images: images))
        #expect(text.contains("\0wifiaddr=\(id["wifi-mac"]!.uppercased())\0") && !text.contains("btaddr"))
        #expect(!nvram(try N45NOR.build(identity: Self.devos50, images: images)).contains("wifiaddr"))
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
        let (written, meta) = try N45NAND.write(volume: volume, out: out, filID: 0x4330_3032)
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

    /// The NAND signature off each build's iBoot: C002 for 3A101a (so its store is today's), C003 for 4B1 (in the
    /// app's IPSW cache, smoke #52), and only that word differs between the two stores' metadata.
    @Test func nandSignatureFromIBoot() throws {
        let iboot = { (ipsw: URL) in try IMG2.payload(Apple8900.body(IPSWArchive(ipsw).read(Self.prefix + "iBoot.n45ap.RELEASE.img2"))) }
        let b4B1 = Oracle.path("Library/Caches/gold.samhenri.LightTouchMac/IPSW/1b818911316e4248ee01d3ec67f9d39afc3db240.ipsw")
        if Self.available { #expect(try N45NAND.filID(iBoot: iboot(Self.ipsw)) == 0x4330_3032) }
        if Oracle.exists(b4B1) { #expect(try N45NAND.filID(iBoot: iboot(b4B1)) == 0x4330_3033) }
        #expect(throws: FirmwareError.self) { try N45NAND.filID(iBoot: Data(count: 64)) }
        let c2 = N45NAND.metadataPages(fsPages: 100, filID: 0x4330_3032), c3 = N45NAND.metadataPages(fsPages: 100, filID: 0x4330_3033)
        let page0 = N45NAND.Page(bank: 0, page: 0)
        #expect(c2.keys == c3.keys && c2.filter { $0.key != page0 }.allSatisfy { c3[$0.key] == $0.value })
        #expect(Array(c2[page0]![0..<4]) == [0x32, 0x30, 0x30, 0x43] && Array(c3[page0]![0..<4]) == [0x33, 0x30, 0x30, 0x43])
    }

    /// 3A101a's rootfs vfdecrypt key (022-3601-4.dmg).
    static let rootfsKey = "6f021b478cc21ff77f775850c0efc2e66fd015f6a6894be079ee1351dce9af069f915f3d"

    @Test func stockUnsignedActivation() throws {
        guard Self.available else { return }
        try Oracle.withTemp { dir in
            let enc = dir.appendingPathComponent("enc.dmg"), dmg = dir.appendingPathComponent("rootfs.dmg"), raw = dir.appendingPathComponent("rootfs.hfs")
            try IPSWArchive(Self.ipsw).extract("022-3601-4.dmg", to: enc)
            try VFDecrypt.decrypt(input: enc, output: dmg, key: Data(hex: Self.rootfsKey)!)
            try UDIF.extractRootfs(dmg: dmg, to: raw)
            let volume = try HFSPlusVolume(raw)
            let stock = try volume.contents(volume.record(at: "usr/libexec/lockdownd"))
            let target = dir.appendingPathComponent("lockdownd")
            try stock.write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: target.path)
            #expect(MachOSignature.codeSignature(in: stock) == nil)
            let result = try Activation.run(on: target)
            #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue == 0o555)
            #expect(result.inputSHA256 != result.outputSHA256)
            #expect(MachOSignature.codeSignature(in: try Data(contentsOf: target)) == nil)
        }
    }

    /// 1.x GL front end against the oracle on the stock 3A101a IPSW's OpenGLES: the export scan as
    /// gles2x_exports.scan, the check against opengles-1x.exports (and its refusal of a list that differs), and, with
    /// an armv6.itpack at hand, N45Board.bake as ipod1g_device.bake on the same three stock files (OpenGLES,
    /// SpringBoard's job, SystemVersion), with the GL front end and without: the same paths written (all to be
    /// root-owned, the loader among them), the same record, the hook's and OpenGLES.baked's bytes and modes, the same LK_* job.
    @Test func frontEndAndBakeMatchPython() throws {
        let it = Oracle.qemuIOS.appendingPathComponent("contrib/it-gles"), list = it.appendingPathComponent(N45Board.openGLESExports)
        let itpack = Oracle.guestPackages.appendingPathComponent("armv6.itpack")
        guard Self.available, Oracle.exists(list) else { return }
        try Oracle.withTemp { dir in
            let fm = FileManager.default
            let enc = dir.appendingPathComponent("enc.dmg"), dmg = dir.appendingPathComponent("rootfs.dmg"), raw = dir.appendingPathComponent("rootfs.hfs")
            try IPSWArchive(Self.ipsw).extract("022-3601-4.dmg", to: enc)
            try VFDecrypt.decrypt(input: enc, output: dmg, key: Data(hex: Self.rootfsKey)!)
            try UDIF.extractRootfs(dmg: dmg, to: raw)
            var stock: [String: Data] = [:]
            do {
                let v = try HFSPlusVolume(raw)
                for p in [N72Board.openGLES, SystemEdits.springBoardJob, GuestPackage.systemVersion] { stock[p] = try v.contents(v.record(at: p)) }
                // what the seed's load checks read: 1.x's own executables and libSystem
                for p in FitCheck.Firmware.precedentBinaries + ["usr/lib/libSystem.B.dylib"] { stock[p] = try? v.contents(v.record(at: p)) }
            }
            for u in [enc, dmg, raw] { try fm.removeItem(at: u) }
            let stockGL = stock[N72Board.openGLES]!, gl = dir.appendingPathComponent("OpenGLES")
            try stockGL.write(to: gl)

            let scan = dir.appendingPathComponent("scan.txt")
            try K48Oracle.sh(["python3", "-c", "import sys; sys.path.insert(0, sys.argv[1]); import gles2x_exports; open(sys.argv[3], 'w').write('\\n'.join(gles2x_exports.scan(sys.argv[2])))",
                              it.path, gl.path, scan.path], cwd: dir)
            let names = try N72Board.exportedSymbols(stockGL)
            let pyNames = try String(contentsOf: scan, encoding: .utf8).split(separator: "\n").map(String.init)
            #expect(names.count == 186 && names == pyNames)
            let (ok, line) = try N72Board.frontEnd(gl, exports: list)
            #expect(ok, "\(line)")
            let short = dir.appendingPathComponent("short.exports")
            try (String(contentsOf: list, encoding: .utf8).replacingOccurrences(of: "\nglFlush\n", with: "\n")).write(to: short, atomically: true, encoding: .utf8)
            #expect(try N72Board.frontEnd(gl, exports: short).0 == false)
            #expect(try N72Board.frontEnd(gl, exports: it.appendingPathComponent("opengles-2x.exports")).0 == false)   // 2.x's list is not 1.x's

            guard Oracle.exists(itpack) else { return }
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
                let a = try volume("swift"), b = try volume("python"), out = dir.appendingPathComponent("py-\(gles).json")
                let log = FitCheck.Log()
                let (report, record, owned) = try N45Board.bake(a, helpers: helpers, gles: gles, fit: log, log: { _ in })
                // the seed's loader proof and the LayerKit switches' readers are on the record
                #expect(log.fits.contains { $0.piece.hasPrefix("it_boot") && $0.fits })
                #expect(log.fits.contains { $0.piece == "SpringBoard environment (\(gles ? "LK_ENABLE_OGL, LK_AUTO_ENABLE_OGL, " : "")LK_ENABLE_MBX2D)" })
                try K48Oracle.sh(["python3", "-c", """
                    import json, sys; sys.path.insert(0, sys.argv[1]); import ipod1g_device
                    report, owned = ipod1g_device.bake(sys.argv[2], sys.argv[3], sys.argv[4] == "1")
                    json.dump({"report": report, "owned": owned}, open(sys.argv[5], "w"))
                    """, Oracle.qemuIOS.appendingPathComponent("imgtools").path, b.path, itpack.path, gles ? "1" : "0", out.path], cwd: dir)
                let py = try JSONSerialization.jsonObject(with: Data(contentsOf: out)) as! [String: Any], pyReport = py["report"] as! [String: Any]
                #expect(owned == py["owned"] as? [String])
                var pyRecord = pyReport["guest_package"] as! [String: Any], rec = record.object
                #expect((pyRecord["itpack"] as? [String: Any])?["sha256"] as? String == record.itpackSHA256)
                pyRecord["itpack"] = nil; rec["itpack"] = nil   // the paths differ (a copy); the sha256 is the same
                #expect(NSDictionary(dictionary: rec) == NSDictionary(dictionary: pyRecord))
                #expect(record.family == "n45-ios1" && record.hooks == (gles ? ["/" + N72Board.openGLES] : []))
                #expect(report["gles_engine"] as? String == pyReport["gles_engine"] as? String && (report["gles_engine"] is NSNull) != gles)
                #expect(owned.contains(GuestPackage.loader.0) && owned.contains(GuestPackage.loader.1))
                for rel in owned {   // the modes, bytes and symlinks of everything written
                    let (x, y) = (a.appendingPathComponent(rel), b.appendingPathComponent(rel))
                    if let t = try? fm.destinationOfSymbolicLink(atPath: x.path) { #expect(t == (try? fm.destinationOfSymbolicLink(atPath: y.path)), "\(rel)"); continue }
                    #expect(try SystemEdits.permissions(x) == SystemEdits.permissions(y), "\(rel)")
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: x.path, isDirectory: &isDir), !isDir.boolValue, rel != SystemEdits.springBoardJob {
                        #expect(try Data(contentsOf: x) == Data(contentsOf: y), "\(rel)")
                    }
                }
                let env = { (m: URL) in (NSDictionary(contentsOf: m.appendingPathComponent(SystemEdits.springBoardJob))?["EnvironmentVariables"] as? [String: String]) ?? [:] }
                #expect(env(a) == env(b))
                #expect(env(a)["LK_ENABLE_OGL"] == (gles ? "1" : nil) && env(a)["LK_AUTO_ENABLE_OGL"] == (gles ? "0" : nil) && env(a)["LK_ENABLE_MBX2D"] == "0")
                let hooked = try Data(contentsOf: a.appendingPathComponent(N72Board.openGLES)), baked = a.appendingPathComponent(N72Board.openGLES + ".baked")
                if gles {
                    #expect(try Data(contentsOf: baked) == stockGL && hooked != stockGL)
                    #expect(try N72Board.exportedSymbols(hooked) == names)   // the front end exports the firmware's own names
                } else {
                    #expect(hooked == stockGL && !fm.fileExists(atPath: baked.path))
                }
            }
        }
    }

    @Test func components() throws {
        guard Self.available else { return }
        let c = try BuildComponents.load(IPSWArchive(Self.ipsw), board: "n45ap")
        #expect(c["iBoot"] == Self.prefix + "iBoot.n45ap.RELEASE.img2" && c["AppleLogo"] == Self.prefix + "applelogo.img2")
        #expect(c["KernelCache"] == "kernelcache.release.s5l8900xrb" && c["OS"] == "022-3601-4.dmg")
    }
    /// 1.1.3+ (4A93, 4B1) ship com.apple.mobile.lockbot, through which their lockdownd starts every service (AFC):
    /// the bake keeps it; 1.1.1 (3A110a) has none. Read off the real system volumes.
    @Test(arguments: [("n45ap-4A93", true), ("n45ap-4B1", true), ("n45ap-3A110a", false)])
    func lockbotKeptWhereShipped(_ id: String, _ ships: Bool) throws {
        guard let url = try K48IBootTests.cachedIPSW(id) else { return }
        try Oracle.withTemp { dir in
            let ipsw = IPSWArchive(url), e = try Oracle.entry(id), os = try BuildComponents.load(ipsw, board: e.board)["OS"]!
            let key = try #require(Data(hex: e.key(forPath: os).key))
            let dmg = dir.appendingPathComponent("rootfs.dmg"), raw = dir.appendingPathComponent("rootfs.hfs")
            try ipsw.stream(os) { try VFDecrypt.decrypt(from: $0.fileDescriptor, output: dmg, key: key) }
            try UDIF.extractRootfs(dmg: dmg, to: raw)
            let jobs = try HFSPlusVolume(raw).listing(under: SystemEdits.daemons, hashes: false)
                .map { ($0.path as NSString).lastPathComponent }.filter { $0.hasSuffix(".plist") }
            let lockbot = "com.apple.mobile.lockbot.plist", removed = N45Board.removedDaemons(jobs)
            #expect(jobs.contains(lockbot) == ships, "\(id): \(jobs)")
            #expect(!removed.contains(lockbot) && removed.contains("com.apple.syslogd.plist"), "\(id): \(removed)")
            #expect(N45Board.keptDaemonsFit(jobs).fits)
        }
    }
}
