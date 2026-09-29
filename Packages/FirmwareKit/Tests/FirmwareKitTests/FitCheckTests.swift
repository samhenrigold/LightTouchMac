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
        "n72ap-5F138": Oracle.ipodCache.appendingPathComponent("c3c700be49ad227d1152188e7c1e46b8958fd1e4/rootfs.dmg"),
        "n72ap-7A341": Oracle.ipodCache.appendingPathComponent("0f7fc76d9b9aa826b5ab14be9821a315d3d9dc42/rootfs.dmg"),
        "n72ap-7E18": Oracle.ipodCache.appendingPathComponent("5f4f5c01eda2f811f73167e7d1f82dbeed82367b/rootfs.dmg"),
        "n72ap-8C148": Oracle.ipodCache.appendingPathComponent("b9efddc7bb4350c237a8d3846af61bbfc8a2f647/rootfs.dmg"),
    ]
    static func arch(_ id: String) -> String { id.hasPrefix("k48") ? "armv7" : "armv6" }
    static let springBoard = "System/Library/CoreServices/SpringBoard.app/SpringBoard"
    static let mounter = "System/Library/CoreServices/MobileStorageMounter.app/MobileStorageMounter"
    /// What a guest binary's load check reads: the precedent executables, libSystem, the shared cache, SystemVersion.
    static func stock(_ id: String) -> [String] {
        FitCheck.Firmware.precedentBinaries + ["usr/lib/libSystem.B.dylib", SystemEdits.dyldCache(arch(id)), GuestPackage.systemVersion]
    }

    /// `files` (those the image has; re-exported libraries of the on-disk ones too) under `dir`/`name`; nil when the
    /// fixture is absent.
    static func volume(_ id: String, _ files: [String], in dir: URL, name: String = "stock") throws -> URL? {
        guard let dmg = dmgs[id], Oracle.exists(dmg) else { return nil }
        let raw = dir.appendingPathComponent("\(name).hfs"), out = dir.appendingPathComponent(name)
        try UDIF.extractRootfs(dmg: dmg, to: raw)
        defer { try? FileManager.default.removeItem(at: raw) }
        let v = try HFSPlusVolume(raw)
        var queue = files, seen = Set<String>()
        while let rel = queue.popLast() {
            guard seen.insert(rel).inserted, let r = try? v.record(at: rel), r.kind == .file, !r.isSymlink else { continue }
            let data = try v.contents(r), to = out.appendingPathComponent(rel)
            try SystemEdits.mkdirs(to.deletingLastPathComponent())
            try SystemEdits.put(data, to, mode: r.mode & 0o7777)
            if let m = MachO32.slice(data, arch: arch(id))?.image { queue += m.reexported().map { String($0.drop { $0 == "/" }) } }
        }
        return out
    }

    /// `dylib` appended to the job's DYLD_INSERT_LIBRARIES in the fixture volume `v`, as the bake does.
    static func insert(_ dylib: String, into job: String, at v: URL) throws {
        try SystemEdits.rewritePlist(v.appendingPathComponent(job)) { SystemEdits.dyldInsert($0, dylib) }
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
    @Test func iPodAgentNeedsTheShippingCacheDyld() throws {
        guard let agent = try FitFixture.payload("armv6", "n72-ios3/bin/it_agent"), let loader = try FitFixture.payload("armv6", "loader/it_boot") else { return }
        for (id, fits) in [("n72ap-7E18", true), ("n72ap-8C148", true), ("n72ap-7A341", false), ("n72ap-5F138", false)] {
            try Oracle.withTemp { dir in
                guard let v = try FitFixture.volume(id, FitFixture.stock(id), in: dir) else { return }
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
    @Test func importsAndHosts() throws {
        guard let agent = try FitFixture.payload("armv7", "k48-ios4/bin/it_agent"),
              let quiet = try FitFixture.payload("armv7", "k48-ios4/hooks/it_msmquiet.dylib") else { return }
        for id in ["k48ap-7B500", "k48ap-8C148", "k48ap-9B206"] {
            try Oracle.withTemp { dir in
                guard let v = try FitFixture.volume(id, FitFixture.stock(id) + [FitFixture.mounter], in: dir) else { return }
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

    /// The seed refuses a loader that does not load here: armv6.itpack with its legacy-linked it_boot swapped for the
    /// modern-linked iPod agent, seeded onto 2.1.1, throws and records the misfit; the real itpack seeds and records
    /// the loader's proof.
    @Test func seedChecksTheLoader() throws {
        let itpack = Oracle.guestPackages.appendingPathComponent("armv6.itpack")
        guard Oracle.exists(itpack) else { return }
        try Oracle.withTemp { dir in
            guard let v = try FitFixture.volume("n72ap-5F138", FitFixture.stock("n72ap-5F138") + [N72Board.openGLES], in: dir) else { return }
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
    @Test func k48BakeChecksItsHelpers() throws {
        let fw = Oracle.firmware("k48ap-7B500")
        guard let dmg = fw.cache?.appendingPathComponent("rootfs.dmg"), Oracle.exists(dmg) else { return }
        try Oracle.withTemp { dir in
            guard let helpers = try FitFixture.helpers(in: dir, replacing: "it_ethlink", with: { FitFixture.renaming($0, "_dlopen", "_dlopex") }) else { return }
            let recipe = try #require(try Oracle.entry(fw.entryID).recipe), log = FitCheck.Log()
            let work = dir.appendingPathComponent("work")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            #expect(throws: FirmwareError.self) {
                try SystemEdits.buildK48(rootfs: dmg, work: work, systemBytes: 1_500_000_000, dataBytes: 1 << 30, options: .init(recipe: recipe),
                                         helpers: helpers, fit: log)
            }
            let f = log.fits.first { $0.piece == "it_ethlink" }
            #expect(f.map { !$0.fits && $0.proof.contains("_dlopex") } == true, "\(log.fits)")
            #expect(log.fits.contains { $0.piece == "it_pbd" && $0.fits })
        }
    }

    /// it_msmquiet fits where the mounter raises the notice it hides: 3.2.2 (UNSUPPORTED_FAILURE through
    /// CFUserNotificationDisplayNotice), 4.2.1 (UNSUPPORTED_FAILURE_BODY through CFUserNotificationCreate); not 5.1.1,
    /// whose MobileStorageMounter names neither key (its strings file still has them).
    @Test func msmQuietFitsWhereTheMounterRaisesTheNotice() throws {
        guard let quiet = try FitFixture.payload("armv7", "k48-ios4/hooks/it_msmquiet.dylib") else { return }
        for (id, fits, key) in [("k48ap-7B500", true, "UNSUPPORTED_FAILURE through CFUserNotificationDisplayNotice"),
                                ("k48ap-8C148", true, "UNSUPPORTED_FAILURE_BODY"), ("k48ap-9B206", false, "names neither")] {
            try Oracle.withTemp { dir in
                guard let v = try FitFixture.volume(id, FitFixture.stock(id) + [FitFixture.mounter], in: dir) else { return }
                let f = FitCheck.msmQuiet(FitCheck.Firmware(root: v, arch: "armv7"), program: "/" + FitFixture.mounter, dylib: quiet)
                #expect(f.fits == fits && f.proof.contains(key), "\(id): \(f.proof)")
            }
        }
    }

    /// The whole K48 bake on 5.1.1 (9B206), where it_msmquiet does not fit: SystemEdits.buildK48 leaves the dylib out,
    /// leaves storage_mounter's job as shipped, seeds no hook for it, and records the misfit in `fit`.
    @Test func k48BakeLeavesOutWhatDoesNotFit() throws {
        guard let dmg = FitFixture.dmgs["k48ap-9B206"], Oracle.exists(dmg), let helpers = K48Oracle.guestTools else { return }
        try Oracle.withTemp { dir in
            let recipe = try #require(try Oracle.entry("k48ap-9B206").recipe), log = FitCheck.Log()
            let parts = K48NAND.partitions(mbr: [UInt8](try K48NAND.makeMBR(systemMiB: recipe.systemMiB)))
            let kernel = try Data(contentsOf: dmg.deletingLastPathComponent().appendingPathComponent("kernelcache.mach"), options: .alwaysMapped)
            let r = try SystemEdits.buildK48(rootfs: dmg, work: dir, systemBytes: parts[0].count * 4096, dataBytes: Int64(parts[1].count) * 4096,
                                             options: .init(recipe: recipe), helpers: helpers, kernel: kernel, fit: log)
            #expect(log.fits.contains { $0.piece.hasPrefix("USB Ethernet") && $0.fits }, "\(log.fits.map(\.piece))")
            let sv = try HFSPlusVolume(r.system)
            #expect((try? sv.record(at: SystemEdits.Helpers.tools[3].path)) == nil)
            let job = try #require(PropertyListSerialization.propertyList(from: sv.contents(sv.record(at: SystemEdits.msmJob)), format: nil) as? [String: Any])
            #expect((job["EnvironmentVariables"] as? [String: Any])?["DYLD_INSERT_LIBRARIES"] == nil)
            #expect(r.guestPackage.map { !$0.hooks.contains("/" + SystemEdits.Helpers.tools[3].path) } == true)
            #expect(log.fits.contains { $0.piece.hasPrefix("it_msmquiet") && !$0.fits })
            #expect(!log.fits.contains { $0.piece.hasSuffix("(hook)") }, "left out on purpose, so not a dropped hook")
        }
    }

    /// A seeded hook whose target the firmware lacks is a recorded misfit, unless the preparer left the target out on
    /// purpose: armv7.itpack onto 7B500's files without it_msmquiet or libappsync installed records two dropped hooks;
    /// with both named as omitted it records none.
    @Test func seedRecordsDroppedHooks() throws {
        let itpack = Oracle.guestPackages.appendingPathComponent("armv7.itpack")
        guard Oracle.exists(itpack) else { return }
        for omitted in [Set<String>(), ["/usr/local/lib/it_msmquiet.dylib", "/" + SystemEdits.appsyncPath]] {
            try Oracle.withTemp { dir in
                guard let v = try FitFixture.volume("k48ap-7B500", FitFixture.stock("k48ap-7B500"), in: dir) else { return }
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
    @Test func iPodToolsOnlyWhereTheyLoad() throws {
        guard let helpers = K48Oracle.guestTools else { return }
        for (id, fits) in [("n72ap-7E18", true), ("n72ap-8C148", true), ("n72ap-7A341", false), ("n72ap-5F138", false)] {
            try Oracle.withTemp { dir in
                guard let v = try FitFixture.volume(id, FitFixture.stock(id), in: dir) else { return }
                let f = try N72Board.guestToolsFit(FitCheck.Firmware(root: v, arch: "armv6"), helpers: helpers)
                #expect(f.fits == fits && f.piece.contains("it_typein.dylib"), "\(id): \(f.proof)")
                if !fits { #expect(f.proof.contains("it_agent: load command 0x80000022")) }
            }
        }
        guard let dmg = FitFixture.dmgs["n72ap-7E18"], Oracle.exists(dmg) else { return }
        try Oracle.withTemp { dir in
            guard let bad = try FitFixture.helpers(in: dir, replacing: "it_agent", with: { FitFixture.renaming($0, "_reboot2", "_rebooz2") }) else { return }
            let entry = try Oracle.entry("n72ap-7E18"), o = Preparer.Options(entry: entry, ipsw: dir, out: dir, helper: nil, guestTools: bad)
            final class Events: @unchecked Sendable { var warnings: [String] = [] }
            let events = Events()
            let c = Recipe.Context(o, recipe: try #require(entry.recipe)) { if case .warning(let w) = $0 { events.warnings.append(w) } }
            let raw = dir.appendingPathComponent("volume.img")
            try UDIF.extractRootfs(dmg: dmg, to: raw)
            try VolumeMount.grow(raw, toBytes: try #require(entry.recipe).systemMiB << 20)
            var owners: [(UInt32, String)] = []
            let report = try VolumeMount.withMounted(raw, at: dir.appendingPathComponent("mnt")) { m -> [String: Any] in
                let r = try N72Board(o).bake(m, c, owners: &owners)
                #expect(!FileManager.default.fileExists(atPath: m.appendingPathComponent("usr/local/bin/it_agent").path))
                return r
            }
            #expect((report["guest_tools"] as? String)?.hasPrefix("omitted: it_agent") == true, "\(report["guest_tools"] ?? "-")")
            #expect(events.warnings.contains { $0.hasPrefix("guest tools (") && $0.contains("_rebooz2") }, "\(events.warnings)")
            #expect(c.fit.fits.contains { $0.piece.hasPrefix("guest tools") && !$0.fits })
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
}
