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
        "7E18": (files.appendingPathComponent("ipod-ipsw/scratch/stock-7E18.img"), true, "dyld_shared_cache_armv6"),
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
        #expect(AppSyncCachePatch.looksLikeThumbEntry([0x80, 0xb5, 0x00, 0xaf]))
        #expect(AppSyncCachePatch.looksLikeThumbEntry([0x2d, 0xe9, 0xf0, 0x4f]))
        #expect(!AppSyncCachePatch.looksLikeThumbEntry([0x2d, 0xe9, 0xf0, 0x0f]))
        #expect(!AppSyncCachePatch.looksLikeThumbEntry([0x00, 0x20, 0x70, 0x47]))
    }

    /// Byte-identical patched cache vs appsync_cachepatch.py --patch, and the same status lines.
    @Test(arguments: ["7B500", "8C148", "7E18", "7B367"])
    func patchMatchesPython(build: String) throws {
        guard Fixtures.hasRootfs(build), Fixtures.hasPython else { return }
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
