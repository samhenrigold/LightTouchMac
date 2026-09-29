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
}
