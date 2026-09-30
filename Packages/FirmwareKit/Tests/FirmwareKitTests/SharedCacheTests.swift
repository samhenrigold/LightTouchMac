import Foundation
import Testing
@testable import FirmwareKit

/// Fixture plumbing shared by the wave-A2 tests: firmware lives in ~/Developer/qemu-ios-files and
/// ~/Downloads, the Python oracle in ~/Developer/qemu-ios-ipad1. Nothing is written there; every
/// output goes to a temp dir that the test deletes.
enum Fixtures {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let files = home.appendingPathComponent("Developer/qemu-ios-files")
    static let qemu = home.appendingPathComponent("Developer/qemu-ios-ipad1")
    static let imgtools = qemu.appendingPathComponent("imgtools")

    static func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }
    static var hasPython: Bool { exists(imgtools.appendingPathComponent("ipad1_nand.py")) }

    /// Decrypted system volumes carrying the shared caches.
    static let rootfs: [String: (image: URL, raw: Bool, cache: String)] = [
        "7B500": (files.appendingPathComponent("ipad1/7B500/dec/rootfs.dmg"), false, "dyld_shared_cache_armv7"),
        "8C148": (files.appendingPathComponent("ipad1/repro-8C148/dec/rootfs.dmg"), false, "dyld_shared_cache_armv7"),
        "9B206": (files.appendingPathComponent("ipad1/repro/cache/ad9b607439250f2337fe132890dadc4c487beca8/rootfs.dmg"), false,
                  "dyld_shared_cache_armv7"),
        "7E18": (files.appendingPathComponent("ipod-ipsw/scratch/stock-7E18.img"), true, "dyld_shared_cache_armv6"),
        "8C148-ipod": (files.appendingPathComponent("ipod-ipsw/cache/b9efddc7bb4350c237a8d3846af61bbfc8a2f647/rootfs.dmg"), false,
                       "dyld_shared_cache_armv6"),
        // no persistent decrypted 7B367 rootfs; point FK_7B367_ROOTFS at one (ipad1_fw.py output) to include it
        "7B367": (URL(fileURLWithPath: ProcessInfo.processInfo.environment["FK_7B367_ROOTFS"] ?? "/nonexistent"), false,
                  "dyld_shared_cache_armv7"),
    ]
    static func hasRootfs(_ b: String) -> Bool { rootfs[b].map { exists($0.image) } ?? false }

    static func tempDir(_ tag: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("fk-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @discardableResult
    static func run(_ args: [String], env: [String: String] = [:]) throws -> (status: Int32, out: Data, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, o, String(decoding: e, as: UTF8.self))
    }

    /// Copies `paths` (relative to the volume root) out of a read-only attach of the build's volume into `dir`.
    /// Attaches are serialized and each file is extracted once per test run (into `shared`, removed at exit);
    /// a volume someone already has mounted is read where it is, and left mounted.
    static func extract(build: String, paths: [String], to dir: URL) throws -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        var missing = paths.filter { !exists(sharedFile(build, $0)) }
        if !missing.isEmpty {
            let fs = rootfs[build]!
            var mnt = mountedAt(fs.image)
            let ours = mnt == nil
            if ours {
                let m = shared.appendingPathComponent("mnt-\(build)")
                try FileManager.default.createDirectory(at: m, withIntermediateDirectories: true)
                var args = ["hdiutil", "attach", "-readonly", "-nobrowse", "-noverify", "-mountpoint", m.path]
                if fs.raw { args += ["-imagekey", "diskimage-class=CRawDiskImage"] }
                let r = try run(args + [fs.image.path])
                guard r.status == 0 else { throw FirmwareError(.internal, "hdiutil attach: \(r.err)") }
                mnt = m
            }
            defer {
                if ours {
                    _ = try? run(["hdiutil", "detach", mnt!.path])
                    try? FileManager.default.removeItem(at: mnt!)
                }
            }
            for rel in missing { try FileManager.default.copyItem(at: mnt!.appendingPathComponent(rel), to: sharedFile(build, rel)) }
            missing = []
        }
        return try paths.map { rel in
            let dst = dir.appendingPathComponent("\(build)-" + (rel as NSString).lastPathComponent)
            try FileManager.default.copyItem(at: sharedFile(build, rel), to: dst)
            return dst
        }
    }

    static let lock = NSLock()
    static let shared: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("fk-fixtures-\(getpid())")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: Fixtures.shared) }
        return u
    }()
    static func sharedFile(_ build: String, _ rel: String) -> URL {
        shared.appendingPathComponent(build + "-" + rel.replacingOccurrences(of: "/", with: "_"))
    }

    /// Where `image` is already attached and mounted, if it is.
    static func mountedAt(_ image: URL) -> URL? {
        guard let r = try? run(["hdiutil", "info", "-plist"]), r.status == 0,
              let info = try? PropertyListSerialization.propertyList(from: r.out, format: nil) as? [String: Any],
              let images = info["images"] as? [[String: Any]] else { return nil }
        let want = image.resolvingSymlinksInPath().path
        for img in images where (img["image-path"] as? String).map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) == want {
            for e in img["system-entities"] as? [[String: Any]] ?? [] {
                if let m = e["mount-point"] as? String { return URL(fileURLWithPath: m) }
            }
        }
        return nil
    }

    static func cache(_ build: String, to dir: URL) throws -> URL {
        try extract(build: build, paths: ["System/Library/Caches/com.apple.dyld/" + rootfs[build]!.cache], to: dir)[0]
    }
}

struct SharedCacheTests {
    @Test func thumbEntryCheck() {
        #expect(AppSyncCachePatch.looksLikeThumbEntry([0x80, 0xb5, 0x00, 0xaf]))   // push {r7,lr}  (3.x/4.x/5.0b)
        #expect(AppSyncCachePatch.looksLikeThumbEntry([0x2d, 0xe9, 0xf0, 0x4f]))   // push.w with lr
        #expect(AppSyncCachePatch.looksLikeThumbEntry([0x00, 0x22, 0xff, 0xf7]))   // 5.x thunk: movs r2,#0 ; b.w
        #expect(!AppSyncCachePatch.looksLikeThumbEntry([0x2d, 0xe9, 0xf0, 0x0f]))  // push.w without lr
        #expect(!AppSyncCachePatch.looksLikeThumbEntry([0x00, 0x20, 0x70, 0x47]))  // movs r0,#0 ; bx lr (no branch)
        #expect(!AppSyncCachePatch.looksLikeThumbEntry([0x00, 0x22, 0x00, 0x22]))  // movs ; movs (no branch)
        #expect(!AppSyncCachePatch.looksLikeThumbEntry([0x00, 0x00, 0x00, 0x00]))  // data
    }

    /// The 5.x finder end to end: on a real 5.x cache MISValidateSignature is a `movs;b.w` thunk (0022 fff7);
    /// the patch locates it by symbol and rewrites its first word, and a second run reports it done.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"), arguments: ["9B206"])
    func patches5x(build: String) throws {
        guard Fixtures.hasRootfs(build) else { try FixtureRequirements.missing(#"SharedCacheTests.swift: Fixtures.hasRootfs(build)"#) }
        let dir = try Fixtures.tempDir("dsc5")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try Fixtures.cache(build, to: dir)
        let dry = try AppSyncCachePatch.patchCache(at: cache, apply: false)
        #expect(dry.contains("0022fff7 -> 00207047"))   // the thunk word, becoming movs r0,#0 ; bx lr
        let (va, _) = try DyldSharedCache(contentsOf: cache).findSymbol(AppSyncCachePatch.target)
        #expect(try AppSyncCachePatch.patchCache(at: cache).hasPrefix("patched"))
        let dsc = try DyldSharedCache(contentsOf: cache)
        let off = dsc.fileOffset(of: va)!
        #expect([UInt8](dsc.data[off..<off + 4]) == AppSyncCachePatch.patch)
        #expect(try AppSyncCachePatch.patchCache(at: cache).contains("already patched"))
    }

    /// Must refuse: when the symbol's first word is not a Thumb function entry (here clobbered to data), the
    /// patch throws rather than scribble on the wrong bytes — the guard that lets 5.x through must still
    /// reject a cache whose entry it cannot recognise.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func refusesNonEntry() throws {
        guard Fixtures.hasRootfs("9B206") else { try FixtureRequirements.missing(#"SharedCacheTests.swift: Fixtures.hasRootfs("9B206")"#) }
        let dir = try Fixtures.tempDir("dsc-refuse")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try Fixtures.cache("9B206", to: dir)
        let (va, _) = try DyldSharedCache(contentsOf: cache).findSymbol(AppSyncCachePatch.target)
        let off = try DyldSharedCache(contentsOf: cache).fileOffset(of: va)!
        let fh = try FileHandle(forUpdating: cache)
        try fh.seek(toOffset: UInt64(off)); try fh.write(contentsOf: Data([0, 0, 0, 0])); try fh.close()
        #expect(throws: FirmwareError.self) { try AppSyncCachePatch.patchCache(at: cache) }
    }

    /// The prepare-time fit (FitCheck.appSyncCache, required in checkAppSync): a volume holding 9B206's cache fits
    /// with the thunk named as its entry; the same cache with the entry clobbered misfits; no cache, no piece.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func cacheFitCheck() throws {
        guard Fixtures.hasRootfs("9B206") else { try FixtureRequirements.missing(#"SharedCacheTests.swift: Fixtures.hasRootfs("9B206")"#) }
        let dir = try Fixtures.tempDir("dsc-fit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("root"), rel = SystemEdits.dyldCache("armv7")
        #expect(FitCheck.appSyncCache(FitCheck.Firmware(root: root, arch: "armv7")) == nil)
        let cache = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: try Fixtures.cache("9B206", to: dir), to: cache)
        let fit = try #require(FitCheck.appSyncCache(FitCheck.Firmware(root: root, arch: "armv7")))
        #expect(fit.fits && fit.proof.hasPrefix("entry 0022fff7"), "\(fit.proof)")
        let (_, off, _) = try AppSyncCachePatch.locate(DyldSharedCache(contentsOf: cache))
        let fh = try FileHandle(forUpdating: cache)
        try fh.seek(toOffset: UInt64(off)); try fh.write(contentsOf: Data([0, 0, 0, 0])); try fh.close()
        let bad = try #require(FitCheck.appSyncCache(FitCheck.Firmware(root: root, arch: "armv7")))
        #expect(!bad.fits && bad.proof.contains("refusing"), "\(bad.proof)")
    }

    /// Byte-identical patched cache vs appsync_cachepatch.py --patch, and the same status lines.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"), arguments: ["7B500", "8C148", "7E18", "7B367"])
    func patchMatchesPython(build: String) throws {
        guard Fixtures.hasRootfs(build), Fixtures.hasPython else { try FixtureRequirements.missing(#"SharedCacheTests.swift: Fixtures.hasRootfs(build), Fixtures.hasPython"#) }
        let dir = try Fixtures.tempDir("dsc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mine = try Fixtures.cache(build, to: dir)
        let theirs = dir.appendingPathComponent("python-cache")
        try FileManager.default.copyItem(at: mine, to: theirs)

        let script = Fixtures.imgtools.appendingPathComponent("appsync_cachepatch.py").path
        let dry = try Fixtures.run(["python3", script, mine.path])
        #expect(try AppSyncCachePatch.patchCache(at: mine, apply: false) + "\n" == String(decoding: dry.out, as: UTF8.self))
        let t0 = Date()
        let status = try AppSyncCachePatch.patchCache(at: mine)
        let swiftTime = Date().timeIntervalSince(t0)
        let t1 = Date()
        let py = try Fixtures.run(["python3", script, theirs.path, "--patch"])
        let pyTime = Date().timeIntervalSince(t1)
        print("\(build): swift \(String(format: "%.2f", swiftTime)) s, python \(String(format: "%.2f", pyTime)) s: \(status)")
        #expect(py.status == 0)
        #expect(status + "\n" == String(decoding: py.out, as: UTF8.self))
        #expect(try Fixtures.run(["cmp", mine.path, theirs.path]).status == 0)
        #expect(try AppSyncCachePatch.patchCache(at: mine).contains("already patched"))
    }
}
