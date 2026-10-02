import Foundation
import Testing
@testable import FirmwareKit

/// Real firmware for the fit checks: the Python decrypt caches' rootfs.dmg (skipped when absent), with a chosen set of
/// the system volume's files copied out of the HFS image into a plain directory (a stand-in for the mounted volume).
enum FitFixture {
    static let dmgs: [String: URL] = [
        "k48ap-7B500": Oracle.ipadCache.appendingPathComponent("68b613f78581d36eab96aa5a007001dff142baa3/rootfs.dmg"),
        "k48ap-8C148": Oracle.ipadCache.appendingPathComponent("8717b3bedc925b587566442ad375aa65d857e79a/rootfs.dmg"),
        "k48ap-9B206": Oracle.ipadCache.appendingPathComponent("ad9b607439250f2337fe132890dadc4c487beca8/rootfs.dmg"),
        "k48ap-9A5220p": Oracle.ipadCache.appendingPathComponent("006bd8859e534e6cf68d6a72e7c7086dbb675dae/rootfs.dmg"),
        "n72ap-5F138": Oracle.ipodCache.appendingPathComponent("c3c700be49ad227d1152188e7c1e46b8958fd1e4/rootfs.dmg"),
        "n72ap-7A341": Oracle.ipodCache.appendingPathComponent("0f7fc76d9b9aa826b5ab14be9821a315d3d9dc42/rootfs.dmg"),
        "n72ap-7E18": Oracle.ipodCache.appendingPathComponent("5f4f5c01eda2f811f73167e7d1f82dbeed82367b/rootfs.dmg"),
        "n72ap-8C148": Oracle.ipodCache.appendingPathComponent("b9efddc7bb4350c237a8d3846af61bbfc8a2f647/rootfs.dmg"),
    ]
    static func arch(_ id: String) -> String { id.hasPrefix("k48") ? "armv7" : "armv6" }
    static let springBoard = "System/Library/CoreServices/SpringBoard.app/SpringBoard"
    static let mounter = "System/Library/CoreServices/MobileStorageMounter.app/MobileStorageMounter"
    static let usbArbitrator = "System/Library/CoreServices/USBDeviceArbitrator.app/USBDeviceArbitrator"
    /// What a guest binary's load check reads: the precedent executables, libSystem, the shared cache, SystemVersion.
    static func stock(_ id: String) -> [String] {
        FitCheck.Firmware.precedentBinaries + ["usr/lib/libSystem.B.dylib", SystemEdits.dyldCache(arch(id)), GuestPackage.systemVersion]
    }

    /// `files` (those the image has, and listed directories as empty ones; re-exported libraries of the on-disk ones too,
    /// and with `links` every linked one) under `dir`/`name`; nil when the fixture is absent.
    static func volume(_ id: String, _ files: [String], in dir: URL, name: String = "stock", links: Bool = false) async throws -> URL? {
        guard let dmg = dmgs[id], Oracle.exists(dmg) else { return nil }
        let raw = dir.appendingPathComponent("\(name).hfs"), out = dir.appendingPathComponent(name)
        try await UDIF.extractRootfs(dmg: dmg, to: raw)
        defer { try? FileManager.default.removeItem(at: raw) }
        let v = try HFSPlusVolume(raw)
        var queue = files, seen = Set<String>()
        while let rel = queue.popLast() {
            guard seen.insert(rel).inserted, let r = try? v.record(at: rel), !r.isSymlink else { continue }
            if r.kind == .folder { try SystemEdits.mkdirs(out.appendingPathComponent(rel)); continue }   // a listed directory, as it is
            let data = try v.contents(r), to = out.appendingPathComponent(rel)
            try SystemEdits.mkdirs(to.deletingLastPathComponent())
            try SystemEdits.put(data, to, mode: r.mode & 0o7777)
            if let m = MachO32.slice(data, arch: arch(id))?.image { queue += (links ? m.dylibs().map(\.name) : m.reexported()).map { String($0.drop { $0 == "/" }) } }
        }
        return out
    }

    /// `dylib` appended to the job's DYLD_INSERT_LIBRARIES in the fixture volume `v`, as the bake does.
    static func insert(_ dylib: String, into job: String, at v: URL) throws {
        try SystemEdits.rewritePlist(v.appendingPathComponent(job)) { SystemEdits.dyldInsert($0, dylib) }
    }

    /// The volume's framework binaries (<dir>/<Name>.framework/<Name>), for FitCheck.readers.
    static func frameworks(_ id: String, in dir: URL) async throws -> [String] {
        guard let dmg = dmgs[id], Oracle.exists(dmg) else { return [] }
        let raw = dir.appendingPathComponent("list.hfs")
        try await UDIF.extractRootfs(dmg: dmg, to: raw)
        defer { try? FileManager.default.removeItem(at: raw) }
        return try HFSPlusVolume(raw).paths().map(\.path).filter { p in
            let c = p.split(separator: "/")
            return c.count == 5 && FitCheck.frameworkDirs.contains(c[0..<3].joined(separator: "/")) && c[3] == c[4] + ".framework"
        }
    }

    /// A copy of the flat guest-tools directory (FIRMWAREKIT_GUEST_TOOLS) with `name` replaced by `bytes`.
    static func helpers(in dir: URL, replacing name: String, with bytes: (Data) -> Data) throws -> URL? {
        guard let src = K48Oracle.guestTools else { return nil }
        let h = dir.appendingPathComponent("helpers")
        try FileManager.default.copyItem(at: src, to: h)
        let u = h.appendingPathComponent(name), d = bytes(try Data(contentsOf: u))
        try FileManager.default.removeItem(at: u)
        try SystemEdits.put(d, u, mode: 0o755)
        return h
    }

    /// `bin` with the string-table symbol `from` renamed to `to` (the same length): an import no firmware exports.
    static func renaming(_ bin: Data, _ from: String, _ to: String) -> Data {
        var b = [UInt8](bin)
        if let at = b.firstRange(of: Array("\0\(from)\0".utf8)) { b.replaceSubrange(at, with: Array("\0\(to)\0".utf8)) }
        return Data(b)
    }

    /// The itpack's entry `name` (armv6 or armv7 .itpack from the guest-package build or FIRMWAREKIT_GUEST_TOOLS).
    static func payload(_ arch: String, _ name: String) throws -> Data? {
        let itpack = Oracle.guestPackages.appendingPathComponent(arch + ".itpack")
        guard Oracle.exists(itpack) else { return nil }
        return try GuestPackage.read(itpack)[name]
    }
}

@Suite(.serialized) struct FitCheckTests {
    /// FitCheck.loads on real firmware: the iPod agent (linked for 3.1's dyld, LC_DYLD_INFO_ONLY) fits 3.1.3 and 4.2.1,
    /// and does not fit 3.0 or 2.1.1, whose own executables carry no such command (the dyld that refused it with
    /// "unknown required load command 0x80000022"); the legacy-linked loader fits all four.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func iPodAgentNeedsTheShippingCacheDyld() async throws {
        guard let agent = try FitFixture.payload("armv6", "n72-ios3/bin/it_agent"), let loader = try FitFixture.payload("armv6", "loader/it_boot") else { try FixtureRequirements.missing(#"FitCheckTests.swift: let agent = try FitFixture.payload("armv6", "n72-ios3/bin/it_agent"), let loader = try FitFixture.payload("armv6", "loader/it_boot")"#) }
        for (id, fits) in [("n72ap-7E18", true), ("n72ap-8C148", true), ("n72ap-7A341", false), ("n72ap-5F138", false)] {
            try await Oracle.withTemp { dir in
                guard let v = try await FitFixture.volume(id, FitFixture.stock(id), in: dir) else { try FixtureRequirements.missing(#"FitCheckTests.swift: let v = try await FitFixture.volume(id, FitFixture.stock(id), in: dir)"#) }
                let fw = FitCheck.Firmware(root: v, arch: "armv6")
                let f = FitCheck.loads("it_agent", agent, on: fw)
                #expect(f.fits == fits, "\(id): \(f.proof)")
                if !fits { #expect(f.proof.contains("0x80000022")) } else { #expect(f.proof.contains("imports resolved")) }
                let l = FitCheck.loads("it_boot", loader, on: fw)
                #expect(l.fits, "\(id): \(l.proof)")
            }
        }
    }

    /// Imports are checked against what the firmware exports: an armv7 binary whose import this firmware lacks does
    /// not fit (a copy of the agent with one import renamed to a name no image exports), and a DYLD_INSERT dylib that
    /// imports by dynamic lookup fits only in its host process (it_msmquiet: CoreFoundation comes from the mounter).
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func importsAndHosts() async throws {
        guard let agent = try FitFixture.payload("armv7", "k48-ios4/bin/it_agent"),
              let quiet = try FitFixture.payload("armv7", "k48-ios4/hooks/it_msmquiet.dylib") else { return }
        for id in ["k48ap-7B500", "k48ap-8C148", "k48ap-9B206"] {
            try await Oracle.withTemp { dir in
                guard let v = try await FitFixture.volume(id, FitFixture.stock(id) + [FitFixture.mounter], in: dir) else { try FixtureRequirements.missing(#"FitCheckTests.swift: let v = try await FitFixture.volume(id, FitFixture.stock(id) + [FitFixture.mounter], in: dir)"#) }
                let fw = FitCheck.Firmware(root: v, arch: "armv7")
                #expect(FitCheck.loads("it_agent", agent, on: fw).fits, "\(id)")
                // the string table's _write -> _wrizz: same length, so the table stays valid; no image exports it
                let broken = FitFixture.renaming(agent, "_write", "_wrizz")
                #expect(broken != agent)
                let f = FitCheck.loads("it_agent", broken, on: fw)
                #expect(!f.fits && f.proof.contains("_wrizz"), "\(id): \(f.proof)")
                let alone = FitCheck.loads("it_msmquiet", quiet, on: fw)
                #expect(!alone.fits && alone.proof.contains("_CFUserNotificationCreate"), "\(id): \(alone.proof)")
                let hosted = FitCheck.loads("it_msmquiet", quiet, on: fw, host: "/" + FitFixture.mounter)
                #expect(hosted.fits, "\(id): \(hosted.proof)")
            }
        }
    }

    /// The GL front end (qemu-ios contrib/gles-public: one fat OpenGLES for every build) fits the iPad's 3.2.2, 4.2.1,
    /// 5.0 beta 1 and 5.1.1 and the iPod's 2.1.1, 3.1.3 and 4.2.1, and each lookup decides: an export renamed away fails every build,
    /// and a dispatch field the name table lacks fails 5.1.1 alone (the one compositor that asks for a macro context).
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func glesFrontEndFits() async throws {
        let bin = Oracle.guestPackages.appendingPathComponent(SystemEdits.Helpers.openGLES)
        let table = Oracle.guestPackages.appendingPathComponent(SystemEdits.Helpers.glesNames)
        guard Oracle.exists(bin), Oracle.exists(table) else { try FixtureRequirements.missing(#"FitCheckTests.swift: Oracle.exists(bin), Oracle.exists(table)"#) }
        let front = try Data(contentsOf: bin), names = try String(contentsOf: table, encoding: .utf8)
        func renamingAll(_ d: Data, _ from: String, _ to: String) -> Data {
            var b = [UInt8](d)
            while let at = b.firstRange(of: Array("\0\(from)\0".utf8)) { b.replaceSubrange(at, with: Array("\0\(to)\0".utf8)) }
            return Data(b)
        }
        let files = [FitCheck.openGLES, FitCheck.quartzCore, FitCheck.coreImage, FitCheck.ioSurface, FitCheck.ioMobileFramebuffer,
                     FitCheck.sgxEngine, "System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
                     "System/Library/Frameworks/Foundation.framework/Foundation", "usr/lib/libobjc.A.dylib"] + FitCheck.coreSurfaces
        for id in ["k48ap-7B500", "k48ap-8C148", "k48ap-9A5220p", "k48ap-9B206", "n72ap-5F138", "n72ap-7E18", "n72ap-8C148"] {
            try await Oracle.withTemp { dir in
                guard let v = try await FitFixture.volume(id, FitFixture.stock(id) + files, in: dir) else { try FixtureRequirements.missing(#"FitCheckTests.swift: let v = try await FitFixture.volume(id, FitFixture.stock(id) + files, in: dir)"#) }
                let fw = { FitCheck.Firmware(root: v, arch: FitFixture.arch(id)) }
                let f = FitCheck.glesFrontEnd(fw(), binary: front, names: names)
                #expect(f.fits, "\(id): \(f.proof)")
                #expect(f.proof.contains(id.hasPrefix("k48") ? "ES 1.1 + 2.0" : "ES 1.1 only"), "\(id): \(f.proof)")
                let lost = FitCheck.glesFrontEnd(fw(), binary: renamingAll(front, "_glClear", "_glClxar"), names: names)
                #expect(!lost.fits && lost.proof.contains("_glClear"), "\(id): \(lost.proof)")
                let unnamed = FitCheck.glesFrontEnd(fw(), binary: front, names: names.replacingOccurrences(of: "bind_framebuffer_EXT,", with: "bind_framebuffer_XXX,"))
                #expect(unnamed.fits == (id != "k48ap-9B206"), "\(id): \(unnamed.proof)")
                if id == "k48ap-9B206" { #expect(unnamed.proof.contains("bind_framebuffer_EXT") && f.proof.contains("macro context: 905")) }
                // 5.0 beta 1 exports the ...EXT set as ...APPLE: a front end without one of those names (the pin before
                // 9A5220p's 43) does not fit it, and every other build does not look it up
                let noApple = FitCheck.glesFrontEnd(fw(), binary: renamingAll(front, "_glBeginQueryAPPLE", "_glBeginQueryAPPLX"), names: names)
                #expect(noApple.fits == (id != "k48ap-9A5220p"), "\(id): \(noApple.proof)")
            }
        }
    }

    /// The seed refuses a loader that does not load here: armv6.itpack with its legacy-linked it_boot swapped for the
    /// modern-linked iPod agent, seeded onto 2.1.1, throws and records the misfit; the real itpack seeds and records
    /// the loader's proof.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func seedChecksTheLoader() async throws {
        let itpack = Oracle.guestPackages.appendingPathComponent("armv6.itpack")
        guard Oracle.exists(itpack) else { try FixtureRequirements.missing(#"FitCheckTests.swift: Oracle.exists(itpack)"#) }
        try await Oracle.withTemp { dir in
            guard let v = try await FitFixture.volume("n72ap-5F138", FitFixture.stock("n72ap-5F138") + [N72Board.openGLES], in: dir) else { try FixtureRequirements.missing(#"FitCheckTests.swift: let v = try await FitFixture.volume("n72ap-5F138", FitFixture.stock("n72ap-5F138") + [N72Board.openGLES], in: dir)"#) }
            let bad = dir.appendingPathComponent("armv6.itpack")
            try K48Oracle.sh(["python3", "-c", """
                import sys; sys.path.insert(0, sys.argv[1]); import mkpkg
                e = mkpkg.read_pack(sys.argv[2]); d = dict(e)
                e = [(n, d["n72-ios3/bin/it_agent"] if n == "loader/it_boot" else b) for n, b in e]
                mkpkg.pack(e, sys.argv[3])
                """, Oracle.qemuIOS.appendingPathComponent("contrib/guest-package").path, itpack.path, bad.path], cwd: dir)
            let log = FitCheck.Log()
            #expect(throws: FirmwareError.self) { try GuestPackage.seed(volume: v, itpack: bad, gles: true, fit: log) }
            #expect(log.fits.first.map { !$0.fits && $0.piece.hasPrefix("it_boot") } == true)
            let good = FitCheck.Log()
            _ = try GuestPackage.seed(volume: v, itpack: itpack, gles: true, fit: good)
            #expect(good.fits.first.map { $0.fits && $0.piece.hasPrefix("it_boot") } == true, "\(good.fits)")
        }
    }

    /// The K48 bake proves every baked helper before it writes one: a helpers directory whose it_ethlink imports a
    /// name 3.2.2 does not export fails SystemEdits.buildK48 on 7B500 with that helper's misfit recorded.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func k48BakeChecksItsHelpers() async throws {
        let fw = Oracle.firmware("k48ap-7B500")
        guard let dmg = fw.cache?.appendingPathComponent("rootfs.dmg"), Oracle.exists(dmg) else { try FixtureRequirements.missing(#"FitCheckTests.swift: let dmg = fw.cache?.appendingPathComponent("rootfs.dmg"), Oracle.exists(dmg)"#) }
        try await Oracle.withTemp { dir in
            guard let helpers = try FitFixture.helpers(in: dir, replacing: "it_ethlink", with: { FitFixture.renaming($0, "_dlopen", "_dlopex") }) else { try FixtureRequirements.missing(#"FitCheckTests.swift: let helpers = try FitFixture.helpers(in: dir, replacing: "it_ethlink", with: { FitFixture.renaming($0, "_dlopen", "_dlopex") })"#) }
            let recipe = try #require(try Oracle.entry(fw.entryID).recipe), log = FitCheck.Log()
            let work = dir.appendingPathComponent("work")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            await #expect(throws: FirmwareError.self) {
                try await SystemEdits.buildK48(rootfs: dmg, work: work, systemBytes: 1_500_000_000, dataBytes: 1 << 30, options: .init(recipe: recipe),
                                         helpers: helpers, fit: log)
            }
            let f = log.fits.first { $0.piece == "it_ethlink" }
            #expect(f.map { !$0.fits && $0.proof.contains("_dlopex") } == true, "\(log.fits)")
            #expect(log.fits.contains { $0.piece == "it_pbd" && $0.fits })
        }
    }

    /// it_msmquiet fits where the notice it hides is raised: 3.2.2's mounter (UNSUPPORTED_FAILURE through
    /// CFUserNotificationDisplayNotice), 4.2.1's (UNSUPPORTED_FAILURE_BODY through CFUserNotificationCreate); on 5.1.1
    /// not the mounter, which names neither key (its strings file still has them), but USBDeviceArbitrator, the 5.x
    /// catch-all for an unclaimed IOUSBDevice (the emulated keyboard; LightTouchMac smoke #49).
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func msmQuietFitsWhereTheNoticeIsRaised() async throws {
        guard let quiet = try FitFixture.payload("armv7", "k48-ios4/hooks/it_msmquiet.dylib") else { try FixtureRequirements.missing(#"FitCheckTests.swift: let quiet = try FitFixture.payload("armv7", "k48-ios4/hooks/it_msmquiet.dylib")"#) }
        for (id, program, fits, key) in [("k48ap-7B500", FitFixture.mounter, true, "UNSUPPORTED_FAILURE through CFUserNotificationDisplayNotice"),
                                         ("k48ap-8C148", FitFixture.mounter, true, "UNSUPPORTED_FAILURE_BODY"),
                                         ("k48ap-9B206", FitFixture.mounter, false, "names neither"),
                                         ("k48ap-9B206", FitFixture.usbArbitrator, true, "UNSUPPORTED_FAILURE_BODY through CFUserNotificationCreate")] {
            try await Oracle.withTemp { dir in
                guard let v = try await FitFixture.volume(id, FitFixture.stock(id) + [program], in: dir) else { try FixtureRequirements.missing(#"FitCheckTests.swift: let v = try await FitFixture.volume(id, FitFixture.stock(id) + [program], in: dir)"#) }
                let f = FitCheck.msmQuiet(FitCheck.Firmware(root: v, arch: "armv7"), program: "/" + program, dylib: quiet)
                #expect(f.fits == fits && f.proof.contains(key), "\(id) \(program): \(f.proof)")
            }
        }
    }

    /// The whole K48 bake on 5.1.1 (9B206): it_msmquiet does not fit the mounter, so storage_mounter's job stays as
    /// shipped with the misfit recorded, and it fits USBDeviceArbitrator, whose job loads it; the dylib is installed
    /// and the guest package keeps its hook.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func k48BakeQuietsTheNoticeWhereItFits() async throws {
        guard let dmg = FitFixture.dmgs["k48ap-9B206"], Oracle.exists(dmg), let helpers = K48Oracle.guestTools else { try FixtureRequirements.missing(#"FitCheckTests.swift: let dmg = FitFixture.dmgs["k48ap-9B206"], Oracle.exists(dmg), let helpers = K48Oracle.guestTools"#) }
        try await Oracle.withTemp { dir in
            let recipe = try #require(try Oracle.entry("k48ap-9B206").recipe), log = FitCheck.Log()
            let parts = K48NAND.partitions(mbr: [UInt8](try K48NAND.makeMBR(systemMiB: recipe.systemMiB)))
            let kernel = try Data(contentsOf: dmg.deletingLastPathComponent().appendingPathComponent("kernelcache.mach"), options: .alwaysMapped)
            let r = try await SystemEdits.buildK48(rootfs: dmg, work: dir, systemBytes: parts[0].count * 4096, dataBytes: Int64(parts[1].count) * 4096,
                                             options: .init(recipe: recipe), helpers: helpers, kernel: kernel, fit: log)
            #expect(log.fits.contains { $0.piece.hasPrefix("USB Ethernet") && $0.fits }, "\(log.fits.map(\.piece))")
            #expect(log.fits.filter { $0.piece.hasPrefix("it_prefs ") && $0.fits }.count == 3)
            #expect(log.fits.contains { $0.piece.hasPrefix("SpringBoard environment") && $0.fits })
            #expect(log.fits.contains { $0.piece.hasPrefix("web proxy PAC") && $0.fits })
            let sv = try HFSPlusVolume(r.system)
            let env = { (job: String) in
                ((try PropertyListSerialization.propertyList(from: sv.contents(sv.record(at: job)), format: nil) as? [String: Any])?["EnvironmentVariables"]
                    as? [String: Any])?["DYLD_INSERT_LIBRARIES"] as? String
            }
            #expect((try? sv.record(at: SystemEdits.Helpers.tools[3].path)) != nil)
            #expect(try env(SystemEdits.msmJob) == nil)
            #expect(try env(SystemEdits.daemons + "/com.apple.mobile.usb_device_arbitrator.plist") == "/" + SystemEdits.Helpers.tools[3].path)
            #expect(r.guestPackage.map { $0.hooks.contains("/" + SystemEdits.Helpers.tools[3].path) } == true)
            #expect(log.fits.contains { $0.piece.hasPrefix("it_msmquiet (MobileStorageMounter") && !$0.fits })
            #expect(log.fits.contains { $0.piece.hasPrefix("it_msmquiet (USBDeviceArbitrator") && $0.fits })
            #expect(!log.fits.contains { $0.piece.hasSuffix("(hook)") && !$0.fits }, "\(log.fits.filter { $0.piece.hasSuffix("(hook)") })")
            // 9B206 has AppSync on: libappsync fits installd, and the stock shared cache is left alone (appsync-upstream).
            #expect(!log.fits.contains { $0.piece.hasPrefix("AppSync shared-cache patch") }, "\(log.fits.map(\.piece))")
            #expect(log.fits.contains { $0.piece.hasPrefix(SystemEdits.Helpers.appsync) && $0.fits })
        }
    }

    /// A seeded hook whose target the firmware lacks is a recorded misfit, unless the preparer left the target out on
    /// purpose: armv7.itpack onto 7B500's files without it_msmquiet or libappsync installed records two dropped hooks;
    /// with both named as omitted it records none.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func seedRecordsDroppedHooks() async throws {
        let itpack = Oracle.guestPackages.appendingPathComponent("armv7.itpack")
        guard Oracle.exists(itpack) else { try FixtureRequirements.missing(#"FitCheckTests.swift: Oracle.exists(itpack)"#) }
        for omitted in [Set<String>(), ["/usr/local/lib/it_msmquiet.dylib", "/" + SystemEdits.appsyncPath]] {
            try await Oracle.withTemp { dir in
                guard let v = try await FitFixture.volume("k48ap-7B500", FitFixture.stock("k48ap-7B500"), in: dir) else { try FixtureRequirements.missing(#"FitCheckTests.swift: let v = try await FitFixture.volume("k48ap-7B500", FitFixture.stock("k48ap-7B500"), in: dir)"#) }
                let log = FitCheck.Log()
                let (_, record) = try GuestPackage.seed(volume: v, itpack: itpack, gles: false, omitted: omitted, fit: log)
                let drops = log.fits.filter { $0.piece.hasSuffix("(hook)") }
                #expect(record.hooks.isEmpty)
                #expect(drops.count == (omitted.isEmpty ? 2 : 0) && drops.allSatisfy { !$0.fits && $0.proof.contains("is not on this firmware") }, "\(drops)")
            }
        }
    }

    /// The iPod's guest tools go in only where they load: they fit 3.1.3 and 4.2.1, not 3.0 or 2.1.1 (no firmware
    /// executable there carries LC_DYLD_INFO_ONLY); and the bake follows the proof, not the shared cache: 7E18 baked
    /// with an it_agent that imports a name 3.1.3 lacks leaves every tool out with a warning, the cache notwithstanding.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func iPodToolsOnlyWhereTheyLoad() async throws {
        guard let helpers = K48Oracle.guestTools else { try FixtureRequirements.missing(#"FitCheckTests.swift: let helpers = K48Oracle.guestTools"#) }
        for (id, fits) in [("n72ap-7E18", true), ("n72ap-8C148", true), ("n72ap-7A341", false), ("n72ap-5F138", false)] {
            try await Oracle.withTemp { dir in
                guard let v = try await FitFixture.volume(id, FitFixture.stock(id), in: dir) else { try FixtureRequirements.missing(#"FitCheckTests.swift: let v = try await FitFixture.volume(id, FitFixture.stock(id), in: dir)"#) }
                let f = try N72Board.guestToolsFit(FitCheck.Firmware(root: v, arch: "armv6"), helpers: helpers)
                #expect(f.fits == fits && f.piece.contains("it_typein.dylib"), "\(id): \(f.proof)")
                if !fits { #expect(f.proof.contains("it_agent: load command 0x80000022")) }
            }
        }
        guard let dmg = FitFixture.dmgs["n72ap-7E18"], Oracle.exists(dmg) else { try FixtureRequirements.missing(#"FitCheckTests.swift: let dmg = FitFixture.dmgs["n72ap-7E18"], Oracle.exists(dmg)"#) }
        try await Oracle.withTemp { dir in
            guard let bad = try FitFixture.helpers(in: dir, replacing: "it_agent", with: { FitFixture.renaming($0, "_reboot2", "_rebooz2") }) else { try FixtureRequirements.missing(#"FitCheckTests.swift: let bad = try FitFixture.helpers(in: dir, replacing: "it_agent", with: { FitFixture.renaming($0, "_reboot2", "_rebooz2") })"#) }
            let entry = try Oracle.entry("n72ap-7E18"), o = Preparer.Options(entry: entry, ipsw: dir, out: dir, helper: nil, guestTools: bad)
            final class Events: @unchecked Sendable { var warnings: [String] = [] }
            let events = Events()
            let c = Recipe.Context(o, recipe: try #require(entry.recipe)) { if case .warning(let w) = $0 { events.warnings.append(w) } }
            let raw = dir.appendingPathComponent("volume.img")
            try await UDIF.extractRootfs(dmg: dmg, to: raw)
            try await VolumeMount.grow(raw, toBytes: try #require(entry.recipe).systemMiB << 20)
            var owners: [(UInt32, String)] = []
            let report = try await VolumeMount.withMounted(raw, at: dir.appendingPathComponent("mnt")) { m -> [String: Any] in
                let r = try N72Board(o).bake(m, c, owners: &owners)
                #expect(!FileManager.default.fileExists(atPath: m.appendingPathComponent("usr/local/bin/it_agent").path))
                return r
            }
            #expect((report["guest_tools"] as? String)?.hasPrefix("omitted: it_agent") == true, "\(report["guest_tools"] ?? "-")")
            #expect(events.warnings.contains { $0.hasPrefix("guest tools (") && $0.contains("_rebooz2") }, "\(events.warnings)")
            #expect(c.fit.fits.contains { $0.piece.hasPrefix("guest tools") && !$0.fits })
            #expect(c.fit.fits.contains { $0.piece == "it_prefs SBDidShowReorderText" && $0.fits })
            #expect(c.fit.fits.contains { $0.piece.hasPrefix("SpringBoard environment (CA_ENABLE_OGL/LK_ENABLE_OGL") && $0.fits })
            #expect(c.fit.fits.contains { $0.piece.hasPrefix("web proxy PAC") && $0.fits })
            #expect(c.fit.fits.contains { $0.piece == "libappsync.dylib (in installd)" && $0.fits }, "\(c.fit.fits)")
        }
    }

    /// USB Ethernet fits every iPad kernel at hand (3.2 to 5.1.1 have the pinned path's classes and LinkStatus); a
    /// kernel copy with AppleSynopsysOTGDevice renamed, or no kernel at all, does not fit.
    @Test func usbEthernetNeedsThePinnedClasses() throws {
        let caches = ["172e8297af74b91971a802e6ad137c891f553099", "68b613f78581d36eab96aa5a007001dff142baa3",
                      "8717b3bedc925b587566442ad375aa65d857e79a", "ad9b607439250f2337fe132890dadc4c487beca8"]
        let root = FileManager.default.temporaryDirectory
        for sha in caches {
            let u = Oracle.ipadCache.appendingPathComponent(sha + "/kernelcache.mach")
            guard Oracle.exists(u) else { continue }
            let k = try Data(contentsOf: u, options: .alwaysMapped)
            let f = FitCheck.usbEthernet(FitCheck.Firmware(root: root, arch: "armv7", kernelcache: k), path: SystemEdits.usbEthPath)
            #expect(f.fits && f.proof.contains("AppleUSBEthernetDevice"), "\(sha): \(f.proof)")
            var b = [UInt8](k)
            while let at = b.firstRange(of: Array("\0AppleSynopsysOTGDevice\0".utf8)) { b.replaceSubrange(at, with: Array("\0AppleSynopsysOTGDevicX\0".utf8)) }
            let broken = FitCheck.usbEthernet(FitCheck.Firmware(root: root, arch: "armv7", kernelcache: Data(b)), path: SystemEdits.usbEthPath)
            #expect(!broken.fits && broken.proof.contains("AppleSynopsysOTGDevice"), "\(broken.proof)")
        }
        #expect(!FitCheck.usbEthernet(FitCheck.Firmware(root: root, arch: "armv7"), path: SystemEdits.usbEthPath).fits)
    }

    /// it_prefs' keys are named by their readers on the iPad (3.2.2 to 5.1.1: all three) and the reorder tip on every
    /// iPod build at hand; 2.1.1 and 3.1.3 locationd name neither location key, 4.2.1 both (the iPod sets only the tip).
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func prefsKeysNamedByTheirReaders() async throws {
        let readers = Set(FitCheck.itPrefs.map(\.1))
        for (id, fits) in [("k48ap-7B500", [true, true, true]), ("k48ap-8C148", [true, true, true]), ("k48ap-9B206", [true, true, true]),
                           ("n72ap-5F138", [true, false, false]), ("n72ap-7E18", [true, false, false]), ("n72ap-8C148", [true, true, true])] {
            try await Oracle.withTemp { dir in
                guard let v = try await FitFixture.volume(id, Array(readers), in: dir) else { try FixtureRequirements.missing(#"FitCheckTests.swift: let v = try await FitFixture.volume(id, Array(readers), in: dir)"#) }
                let f = FitCheck.prefs(FitCheck.Firmware(root: v, arch: FitFixture.arch(id)), FitCheck.itPrefs)
                #expect(f.map(\.fits) == fits, "\(id): \(f.map(\.proof))")
            }
        }
    }

    /// Every switch SpringBoard's job gets has a reader: the iPad's GL set (MBX2D_PAGE_FLIP, read by the firmware
    /// itself: the GL front end needs no switch of its own) on 3.2.2 and 5.1.1; the iPod's
    /// CoreAnimation/LayerKit pairs on 2.1.1 (frameworks on disk), 3.1.3 and 4.2.1; not a LayerKit-only switch on
    /// the iPad's 4.2.1, which reads no LK_ name.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func springBoardSwitchesHaveReaders() async throws {
        let ipad = SystemEdits.sbEnvCAOGL.keys.sorted().map { [$0] }
        let cases: [(String, [[String]], [(String, Data)], Bool)] = [
            ("k48ap-7B500", ipad, [], true), ("k48ap-9B206", ipad, [], true),
            ("k48ap-8C148", [["LK_ENABLE_OGL"]], [], false),
            ("n72ap-5F138", N72Board.sbSwitches, [], true), ("n72ap-7E18", N72Board.sbSwitches, [], true), ("n72ap-8C148", N72Board.sbSwitches, [], true)]
        for (id, switches, also, fits) in cases {
            try await Oracle.withTemp { dir in
                let files = FitFixture.stock(id) + [FitCheck.itPrefs[0].1] + (try await FitFixture.frameworks(id, in: dir))
                guard let v = try await FitFixture.volume(id, files, in: dir) else { try FixtureRequirements.missing(#"FitCheckTests.swift: let v = try await FitFixture.volume(id, files, in: dir)"#) }
                let fw = FitCheck.Firmware(root: v, arch: FitFixture.arch(id))
                let f = FitCheck.environment(fw, switches, also: also)
                #expect(f.fits == fits, "\(id) \(switches): \(f.proof)")
                if !fits { #expect(f.proof.contains("LK_ENABLE_OGL")) }
                // the web proxy's keys are named by every firmware at hand (SystemConfiguration / CFNetwork)
                let pac = FitCheck.webProxy(fw)
                #expect(pac.fits, "\(id): \(pac.proof)")
                #expect(!FitCheck.named("web proxy PAC", fw, [["ProxyAutoConfigURLStrinX"]]).fits)
            }
        }
    }

    /// The kernels read the boot-args the boards boot with: every iPad kernel at hand the code-signing pair (enable-hsic
    /// only 4.2.1's); every iPod kernel amfi_allow_any_signature, but only 3.1.3's and 4.2.1's read cs_enforcement_disable
    /// (2.x and 3.0 have just the _cs_enforcement_disable global): a recorded misfit, not a failure. A kernel copy with
    /// amfi_allow_any_signature renamed does not fit and fails.
    @Test func bootArgsReadByTheKernel() throws {
        let pair = FitCheck.amfiArgs.sorted().map { $0 + "=1" }.joined(separator: " ")
        let cases: [(URL, String, Bool?)] = [
            ("172e8297af74b91971a802e6ad137c891f553099", false), ("68b613f78581d36eab96aa5a007001dff142baa3", false),
            ("8717b3bedc925b587566442ad375aa65d857e79a", true), ("ad9b607439250f2337fe132890dadc4c487beca8", false)].map {
                (Oracle.ipadCache.appendingPathComponent($0.0 + "/kernelcache.mach"), KBoot.defaultBootArgs, $0.1) }
            + [("c3c700be49ad227d1152188e7c1e46b8958fd1e4", false), ("9af5625ea34acdd8abeb6fce71a72651d0c815d5", false), ("0f7fc76d9b9aa826b5ab14be9821a315d3d9dc42", false),
               ("5f4f5c01eda2f811f73167e7d1f82dbeed82367b", true), ("b9efddc7bb4350c237a8d3846af61bbfc8a2f647", true)].map {
                (Oracle.ipodCache.appendingPathComponent($0.0 + "/kernelcache.mach"), pair, $0.1 ? nil : false) }
        for (u, args, hsic) in cases where Oracle.exists(u) {
            let k = try Data(contentsOf: u, options: .alwaysMapped), f = FitCheck.bootArgs(k, args)
            let cs = args == pair && hsic == false   // an iPod kernel without the cs_enforcement_disable boot-arg
            #expect(f.first { $0.piece == "boot-arg amfi_allow_any_signature" }?.proof == "read by the kernel", "\(u.path)")
            #expect(f.first { $0.piece == "boot-arg cs_enforcement_disable" }?.fits == !cs, "\(u.path): \(f)")
            #expect(f.filter { !$0.fits }.count == (cs ? 1 : 0), "\(u.path): \(f)")
            let quiet = FitCheck.Log()
            try FitCheck.checkBootArgs(quiet, kernel: k, args: args)   // an unread cs_enforcement_disable does not fail
            let hsic = args == pair ? nil : hsic
            if let hsic {
                #expect(f.first { $0.piece == "boot-arg enable-hsic" }?.proof == (hsic ? "read by the kernel" : "not read by this kernel: no effect here"))
                // the DeviceTree property: 4.2.1 and 5.1.1 read it, 3.2.x do not
                let dt = FitCheck.deviceTreeProperty(k, "arm-io/usb-complex", "hsic-enabled")
                #expect(dt.fits)
                #expect(dt.proof == ((u.path.contains("/172e") || u.path.contains("/68b6")) ? "not read by this kernel: no effect here" : "read by the kernel"), "\(u.path)")
            }
            var b = [UInt8](k)
            while let at = b.firstRange(of: Array("\0amfi_allow_any_signature\0".utf8)) { b.replaceSubrange(at, with: Array("\0amfi_allow_any_signaturX\0".utf8)) }
            let log = FitCheck.Log()
            #expect(throws: FirmwareError.self) { try FitCheck.checkBootArgs(log, kernel: Data(b), args: args) }
            #expect(log.fits.contains { $0.piece == "boot-arg amfi_allow_any_signature" && !$0.fits })
        }
    }

    /// Both boards' boot-file steps record the boot-args' readers: N72Board.bootFiles on 7E18 and K48Board.bootFiles
    /// (kboot) on 7B500, from the Python decrypt caches.
    @Test func bootFilesRecordTheBootArgs() throws {
        for (id, cache, ipsw) in [("n72ap-7E18", Oracle.ipodCache.appendingPathComponent("5f4f5c01eda2f811f73167e7d1f82dbeed82367b"), Oracle.firmware("n72ap-7E18").ipsw),
                                  ("k48ap-7B500", Oracle.ipadCache.appendingPathComponent("68b613f78581d36eab96aa5a007001dff142baa3"), Oracle.firmware("k48ap-7B500").ipsw)] {
            guard Oracle.exists(cache.appendingPathComponent("kernelcache.mach")), Oracle.exists(ipsw) else { continue }
            try Oracle.withTemp { dir in
                var entry = try Oracle.entry(id)
                if id.hasPrefix("k48") { entry.recipe?.boot = "kboot" }
                let o = Preparer.Options(entry: entry, ipsw: ipsw, out: dir, helper: nil, guestTools: dir)
                let c = Recipe.Context(o, recipe: try #require(entry.recipe)) { _ in }
                c.restore = try RestoreInfo(c.ipsw)
                c.dec = cache
                let board: Board = id.hasPrefix("k48") ? try K48Board(o) : try N72Board(o)
                try board.inspect(c)
                _ = try board.identity(seed: "fit")
                try board.bootFiles(c)
                #expect(c.fit.fits.filter { FitCheck.amfiArgs.contains(String($0.piece.dropFirst("boot-arg ".count))) }.count == 2, "\(id): \(c.fit.fits)")
                #expect(c.fit.fits.contains { $0.piece == "boot-arg amfi_allow_any_signature" && $0.fits })
                if id.hasPrefix("k48") { #expect(c.fit.fits.contains { $0.piece == "DeviceTree arm-io/usb-complex/hsic-enabled" }) }
            }
        }
    }

    /// The 1.x recipe through `create --stop-after volumes` on 3A101a (the survey mode): fit.json records the kept
    /// LaunchDaemons present, the loader and the LayerKit switches; without usbptpd's job the keep-list does not fit.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func n45SurveyRecordsTheKeptJobs() async throws {
        let ipsw = N45Tests.ipsw
        guard Oracle.exists(ipsw), let helpers = K48Oracle.guestTools else { try FixtureRequirements.missing(#"FitCheckTests.swift: Oracle.exists(ipsw), let helpers = K48Oracle.guestTools"#) }
        try await Oracle.withTemp { dir in
            var o = Preparer.Options(entry: try Oracle.entry("n45ap-3A101a"), ipsw: ipsw, out: dir.appendingPathComponent("out"), helper: nil,
                                     guestTools: helpers, cache: dir.appendingPathComponent("cache"))
            o.stopAfterVolumes = true
            try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
            try await Preparer.create(o) { _ in }
            let survey = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: o.out.appendingPathComponent("fit.json"))) as? [String: Any])
            let fits = try #require(survey["fit"] as? [[String: Any]])
            #expect(fits.contains { ($0["piece"] as? String)?.hasPrefix("LaunchDaemons kept on 1.x") == true && $0["fits"] as? Bool == true }, "\(fits)")
            #expect(fits.contains { ($0["piece"] as? String)?.hasPrefix("it_boot") == true && $0["fits"] as? Bool == true })
            #expect(!FileManager.default.fileExists(atPath: o.out.appendingPathComponent("nand").path))
        }
        let all = Array(N45Board.keptDaemons)
        #expect(N45Board.keptDaemonsFit(all).fits)
        let f = N45Board.keptDaemonsFit(all.filter { $0 != "com.apple.usbptpd.plist" })
        #expect(!f.fits && f.proof.contains("usbptpd"))
    }

    /// The iPad's iBoots (3.2, 3.2.2, 4.2.1, 5.1.1) load the kernelcache from the path the bake installs it to; an
    /// iBoot copy naming another does not fit, and the iboot strategy's boot-file step refuses it.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func iPadKernelcacheWhereIBootLoadsIt() throws {
        for sha in ["172e8297af74b91971a802e6ad137c891f553099", "68b613f78581d36eab96aa5a007001dff142baa3",
                    "8717b3bedc925b587566442ad375aa65d857e79a", "ad9b607439250f2337fe132890dadc4c487beca8"] {
            let u = Oracle.ipadCache.appendingPathComponent(sha + "/iBoot.bin")
            guard Oracle.exists(u) else { continue }
            let d = try Data(contentsOf: u)
            #expect(K48Board.kernelcacheFit(iboot: d).fits, "\(sha)")
            var b = [UInt8](d)
            let from = Array("com.apple.kernelcaches/kernelcache".utf8), to = Array("com.apple.kernelcaches/kernelcachX".utf8)
            while let at = b.firstRange(of: from) { b.replaceSubrange(at, with: to) }
            let f = K48Board.kernelcacheFit(iboot: Data(b))
            #expect(!f.fits && f.proof.contains("kernelcachX"), "\(f.proof)")
        }
        // the iboot strategy's boot-file step on 7B500 records it (the patcher from FIRMWAREKIT_IBOOT_PATCHER)
        let patcher = Oracle.path("Downloads/Legacy-iOS-Kit_complete_v25.09.01/bin/macos/arm64/iBoot32Patcher")
        let cache = Oracle.ipadCache.appendingPathComponent("68b613f78581d36eab96aa5a007001dff142baa3"), ipsw = Oracle.firmware("k48ap-7B500").ipsw
        guard Oracle.exists(patcher), Oracle.exists(ipsw), Oracle.exists(cache) else { try FixtureRequirements.missing(#"FitCheckTests.swift: Oracle.exists(patcher), Oracle.exists(ipsw), Oracle.exists(cache)"#) }
        setenv("FIRMWAREKIT_IBOOT_PATCHER", patcher.path, 1)
        try Oracle.withTemp { dir in
            let entry = try Oracle.entry("k48ap-7B500")
            let o = Preparer.Options(entry: entry, ipsw: ipsw, out: dir, helper: URL(fileURLWithPath: "/usr/bin/true"), guestTools: dir)
            let c = Recipe.Context(o, recipe: try #require(entry.recipe)) { _ in }
            c.restore = try RestoreInfo(c.ipsw)
            c.dec = cache
            let board = try K48Board(o)
            try board.check(c)
            _ = try board.identity(seed: "fit")
            try board.bootFiles(c)
            #expect(c.fit.fits.contains { $0.piece == "kernelcache at the path iBoot loads" && $0.fits }, "\(c.fit.fits)")
        }
    }

    // MARK: AppSync

    static let appSyncFiles = ["usr/libexec/installd", "usr/libexec/mobile_installation_proxy", SystemEdits.installdJob,
                               SystemEdits.daemons + "/com.apple.installd.plist",
                               "System/Library/Lockdown/Services.plist"]

    /// The installation service's volume for `id`: its program, everything it links, the jobs, the precedent binaries.
    static func appSyncVolume(_ id: String, in dir: URL) async throws -> URL? {
        try await FitFixture.volume(id, FitFixture.stock(id) + appSyncFiles, in: dir, links: true)
    }

    /// AppSync fits every AppSync-on family at hand, in the service installAppSync puts it in: installd on 3.0
    /// (prebound imports), 3.1.3, 3.2.2 and 4.2.1 (iPod and iPad), and on 2.1.1 mobile_installation_proxy, whose
    /// MobileInstallation framework makes the libmis and Security calls, with appsync-launch in front of it.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func appSyncFitsEveryAppSyncFamily() async throws {
        guard let helpers = K48Oracle.guestTools else { try FixtureRequirements.missing(#"FitCheckTests.swift: let helpers = K48Oracle.guestTools"#) }
        for id in ["k48ap-7B500", "k48ap-8C148", "n72ap-5F138", "n72ap-7A341", "n72ap-7E18", "n72ap-8C148"] {
            try await Oracle.withTemp { dir in
                guard let v = try await Self.appSyncVolume(id, in: dir) else { try FixtureRequirements.missing(#"FitCheckTests.swift: let v = try await Self.appSyncVolume(id, in: dir)"#) }
                let log = FitCheck.Log()
                try FitCheck.checkAppSync(log, FitCheck.Firmware(root: v, arch: FitFixture.arch(id)), helpers: helpers)
                let lockbot = id == "n72ap-5F138"
                // The shared-cache patch target (appsync-5x) is its own piece where the build has a cache.
                #expect(log.fits.allSatisfy { $0.fits }, "\(id): \(log.fits)")
                let fits = log.fits.filter { !$0.piece.hasPrefix("AppSync shared-cache patch") }
                #expect(fits.count == (lockbot ? 2 : 1), "\(id): \(log.fits)")
                let dylib = try #require(fits.first)
                #expect(dylib.piece == "libappsync.dylib (in \(lockbot ? "mobile_installation_proxy" : "installd"))", "\(id)")
                #expect(dylib.proof.contains("SecCertificateCreateWithData by ") && dylib.proof.contains("imports resolved"), "\(id): \(dylib.proof)")
                #expect(dylib.proof.contains(lockbot ? "by MobileInstallation" : "by installd"), "\(id): \(dylib.proof)")
                if lockbot { #expect(fits[1].piece.hasPrefix("appsync-launch") && fits[1].proof.contains("execs mobile_installation_proxy")) }
            }
        }
    }

    /// `bin` with every C string `from` renamed to `to` (the same length): both slices of a fat binary.
    static func renamingAll(_ bin: Data, _ from: String, _ to: String) -> Data {
        var b = [UInt8](bin), start = 0
        let f = Array("\0\(from)\0".utf8), t = Array("\0\(to)\0".utf8)
        while let at = b[start...].firstRange(of: f) { b.replaceSubrange(at, with: t); start = at.upperBound }
        return Data(b)
    }

    /// Real misfits: the dylib in a real service that makes none of the calls it hooks and that its gate does not name
    /// (3.2.2's MobileStorageMounter); the libappsync of 2026-09-28 (qemu-ios build/appsync, before LEGACY_LINK and
    /// the 2.x gate; its armv6 slice carries LC_DYLD_INFO_ONLY) in 2.1.1's and 3.0's installation services, while it
    /// still fits 3.1.3's installd. Corrupted copies: 3.2.2's installd with its libmis check renamed (only the hook
    /// misses), the dylib with its gate renamed (only the gate misses), the launcher inserting another path.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func appSyncDoesNotFitWhereItCannotWork() async throws {
        guard let helpers = K48Oracle.guestTools else { try FixtureRequirements.missing(#"FitCheckTests.swift: let helpers = K48Oracle.guestTools"#) }
        let dylib = try Data(contentsOf: helpers.appendingPathComponent(SystemEdits.Helpers.appsync))
        let launcher = try Data(contentsOf: helpers.appendingPathComponent(SystemEdits.Helpers.appsyncLauncher))
        try await Oracle.withTemp { dir in
            guard let v = try await FitFixture.volume("k48ap-7B500", FitFixture.stock("k48ap-7B500") + Self.appSyncFiles + [FitFixture.mounter], in: dir, links: true) else { try FixtureRequirements.missing(#"FitCheckTests.swift: let v = try await FitFixture.volume("k48ap-7B500", FitFixture.stock("k48ap-7B500") + Self.appSyncFiles + [FitFixture.mounter], in: dir, links: true)"#) }
            let f = FitCheck.appSync(FitCheck.Firmware(root: v, arch: "armv7"), host: "/" + FitFixture.mounter, dylib: dylib)
            #expect(!f.fits && f.proof.contains("gate does not name MobileStorageMounter")
                    && f.proof.contains("imports MISValidateSignatureAndCopyInfo or MISValidateSignature, SecCertificateCreateWithData"), "\(f.proof)")
            let gateless = Self.renamingAll(dylib, "installd", "installx")
            #expect(gateless != dylib)
            let g = FitCheck.appSync(FitCheck.Firmware(root: v, arch: "armv7"), host: "/usr/libexec/installd", dylib: gateless)
            #expect(!g.fits && g.proof == "its getprogname gate does not name installd: the Security interposes would pass through there", "\(g.proof)")
            let installd = v.appendingPathComponent("usr/libexec/installd")
            let blind = Self.renamingAll(try Data(contentsOf: installd), "_MISValidateSignatureAndCopyInfo", "_MISValidateSignatureAndCopyInfX")
            try FileManager.default.removeItem(at: installd)
            try SystemEdits.put(blind, installd, mode: 0o755)
            let h = FitCheck.appSync(FitCheck.Firmware(root: v, arch: "armv7"), host: "/usr/libexec/installd", dylib: dylib)
            #expect(!h.fits && h.proof == "nothing in installd's process imports MISValidateSignatureAndCopyInfo or MISValidateSignature, which the dylib hooks", "\(h.proof)")
        }
        try await Oracle.withTemp { dir in
            guard let v = try await Self.appSyncVolume("n72ap-5F138", in: dir) else { try FixtureRequirements.missing(#"FitCheckTests.swift: let v = try await Self.appSyncVolume("n72ap-5F138", in: dir)"#) }
            let fw = FitCheck.Firmware(root: v, arch: "armv6"), proxy = "/usr/libexec/mobile_installation_proxy"
            let elsewhere = Self.renamingAll(launcher, "/" + SystemEdits.appsyncPath, "/usr/lib/libappsynX.dylib")
            let l = FitCheck.appSyncLauncher(fw, program: proxy, launcher: elsewhere)
            #expect(!l.fits && l.proof.contains("does not insert /usr/lib/libappsync.dylib"), "\(l.proof)")
            let m = FitCheck.appSyncLauncher(fw, program: "/usr/libexec/mobile_installation_proxX", launcher: launcher)
            #expect(!m.fits && m.proof.contains("is not a Mach-O this CPU runs"), "\(m.proof)")
        }
        let old = Oracle.qemuIOS.appendingPathComponent("build/appsync/libappsync.dylib")
        guard Oracle.exists(old), let modern = MachO32.slice(try Data(contentsOf: old), arch: "armv6"),
              modern.image.commands.contains(where: { $0.cmd == 0x8000_0022 }) else { return }
        for (id, fits) in [("n72ap-5F138", false), ("n72ap-7A341", false), ("n72ap-7E18", true)] {
            try await Oracle.withTemp { dir in
                guard let v = try await Self.appSyncVolume(id, in: dir) else { try FixtureRequirements.missing(#"FitCheckTests.swift: let v = try await Self.appSyncVolume(id, in: dir)"#) }
                let host = id == "n72ap-5F138" ? "/usr/libexec/mobile_installation_proxy" : "/usr/libexec/installd"
                let f = FitCheck.appSync(FitCheck.Firmware(root: v, arch: "armv6"), host: host, dylib: try Data(contentsOf: old))
                #expect(f.fits == fits, "\(id): \(f.proof)")
                if !fits { #expect(f.proof.contains("load command 0x80000022"), "\(id): \(f.proof)") }
                if id == "n72ap-5F138" { #expect(f.proof.contains("gate does not name mobile_installation_proxy"), "\(f.proof)") }
            }
        }
    }

    /// The K48 bake checks AppSync before it installs it: 7B500 (appsync on) with a libappsync whose gate names no
    /// installd fails SystemEdits.buildK48 with that misfit recorded; the 9B206 bake (appsync off) records
    /// "not installed (appsync off)" (k48BakeLeavesOutWhatDoesNotFit).
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func k48BakeChecksAppSync() async throws {
        let fw = Oracle.firmware("k48ap-7B500")
        guard let dmg = fw.cache?.appendingPathComponent("rootfs.dmg"), Oracle.exists(dmg) else { try FixtureRequirements.missing(#"FitCheckTests.swift: let dmg = fw.cache?.appendingPathComponent("rootfs.dmg"), Oracle.exists(dmg)"#) }
        try await Oracle.withTemp { dir in
            guard let helpers = try FitFixture.helpers(in: dir, replacing: SystemEdits.Helpers.appsync, with: { Self.renamingAll($0, "installd", "installx") }) else { try FixtureRequirements.missing(#"FitCheckTests.swift: let helpers = try FitFixture.helpers(in: dir, replacing: SystemEdits.Helpers.appsync, with: { Self.renamingAll($0, "installd", "installx") })"#) }
            let recipe = try #require(try Oracle.entry(fw.entryID).recipe), log = FitCheck.Log()
            #expect(recipe.options["appsync"] == true)
            let work = dir.appendingPathComponent("work")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let error = await #expect(throws: FirmwareError.self) {
                try await SystemEdits.buildK48(rootfs: dmg, work: work, systemBytes: 1_500_000_000, dataBytes: 1 << 30, options: .init(recipe: recipe),
                                         helpers: helpers, fit: log)
            }
            #expect(error?.message.contains("libappsync.dylib (in installd) does not fit this firmware: its getprogname gate does not name installd") == true, "\(String(describing: error))")
            #expect(log.fits.last.map { $0.piece == "libappsync.dylib (in installd)" && !$0.fits } == true, "\(log.fits)")
        }
    }
}
