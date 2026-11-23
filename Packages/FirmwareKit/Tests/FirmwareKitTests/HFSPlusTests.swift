import Crypto
import Foundation
import Testing

@testable import FirmwareKit

/// Oracle plumbing for the HFS+ tests: an independent listing through hdiutil mounts, run on temp copies.
enum HFSOracle {
    /// One path as the mounted volume shows it; uid/gid only where the owners-on mount could read them, sha256 only
    /// for readable regular files, link only for symlinks.
    struct Walked {
        var uid: Int?
        var gid: Int?
        var mode = 0
        var flags = 0
        var size = 0
        var sha256: String?
        var link: String?
    }

    /// A listing through two read-only mounts of IMG (-owners on for uid/gid where reachable, off for the
    /// rest), keyed by path relative to the volume root ("" for the root). Independent of the catalog reader.
    static func walk(_ img: URL) async throws -> [String: Walked] {
        var owners: [String: (Int, Int)] = [:]
        try await mounted(img, owners: "on") { rel, _, st in owners[rel] = (Int(st.st_uid), Int(st.st_gid)) }
        var out: [String: Walked] = [:]
        try await mounted(img, owners: "off") { rel, p, st in
            var e = Walked(uid: owners[rel]?.0, gid: owners[rel]?.1)
            e.mode = Int(st.st_mode)
            e.flags = Int(st.st_flags)
            let type = st.st_mode & S_IFMT
            e.size = type == S_IFDIR ? 0 : Int(st.st_size)
            if type == S_IFLNK {
                e.link = try FileManager.default.destinationOfSymbolicLink(atPath: p)
            } else if type == S_IFREG, access(p, R_OK) == 0 {
                e.sha256 = try sha256(of: p)
            }
            out[rel] = e
        }
        return out
    }

    /// Attaches IMG read-only at a temp mount point and calls BODY(relative path, path, lstat) for the root and
    /// everything under it (symlinked directories not followed, unreadable directories skipped), then detaches.
    static func mounted(
        _ img: URL,
        owners: String,
        _ body: (String, String, stat) throws -> Void
    ) async throws {
        let mnt = FileManager.default.temporaryDirectory.appendingPathComponent("fk-walk.\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: mnt, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: mnt) }
        let attach = try await DiskImage.run([
            "/usr/bin/hdiutil", "attach", "-readonly", "-owners", owners, "-nobrowse", "-noverify", "-imagekey",
            "diskimage-class=CRawDiskImage", "-mountpoint", mnt, img.path
        ])
        let dev = String(attach.split(whereSeparator: \.isWhitespace).first ?? "")
        do {
            func visit(_ rel: String) throws {
                let p = rel.isEmpty ? mnt : mnt + "/" + rel
                var st = stat()
                guard lstat(p, &st) == 0 else { throw FirmwareError(.internal, "lstat \(p): errno \(errno)") }
                try body(rel, p, st)
            }
            try visit("")
            let e = FileManager.default.enumerator(atPath: mnt)!
            while let rel = e.nextObject() as? String { try visit(rel) }
        } catch {
            _ = try? await DiskImage.run(["/usr/bin/hdiutil", "detach", dev])
            throw error
        }
        _ = try await DiskImage.run(["/usr/bin/hdiutil", "detach", dev])
    }

    static func sha256(of path: String) throws -> String {
        let f = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? f.close() }
        var h = SHA256()
        while let c = try f.read(upToCount: 1 << 22), !c.isEmpty { h.update(data: c) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The raw system volume of a firmware (UDIF slice of the decrypted cache's rootfs.dmg), in `dir`.
    static func rawSystem(_ fw: Oracle.Firmware, in dir: URL) async throws -> URL? {
        guard let dmg = fw.cache?.appendingPathComponent("rootfs.dmg"), Oracle.exists(dmg) else { return nil }
        let raw = dir.appendingPathComponent("rootfs.hfs")
        try await UDIF.extractRootfs(dmg: dmg, to: raw)
        return raw
    }

    static let ipads = ["k48ap-7B500", "k48ap-8C148"].map(Oracle.firmware)
}

@Suite(.serialized, .detachesItsImages) struct HFSPlusTests {
    /// Every catalog path, owner, mode, flags, size, content sha256 and symlink target against a listing of
    /// the same image through hdiutil mounts.
    @Test(
        .enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"),
        arguments: HFSOracle.ipads
    ) func readerMatchesMount(_ fw: Oracle.Firmware) async throws {
        try await Oracle.withTemp { dir in
            guard let raw = try await HFSOracle.rawSystem(fw, in: dir) else {
                try FixtureRequirements.missing(
                    #"HFSPlusTests.swift: let raw = try await HFSOracle.rawSystem(fw, in: dir)"#
                )
            }
            let vol = try HFSPlusVolume(raw)
            #expect(vol.signature == "HX" && vol.blockSize == 8192)
            let mine = try Oracle.time("HFSPlus listing \(fw.entryID)") { try vol.listing() }
            let walked = try await HFSOracle.walk(raw)
            #expect(mine.count == walked.count)
            var diffs: [String] = []
            for e in mine {
                guard let w = walked[e.path] else {
                    diffs.append("only in the catalog: \(e.path)")
                    continue
                }
                if let uid = w.uid, let gid = w.gid, (uid, gid) != (Int(e.uid), Int(e.gid)) {
                    diffs.append("\(e.path): owner \(e.uid):\(e.gid) vs \(uid):\(gid)")
                }
                if w.mode != Int(e.mode) {
                    diffs.append("\(e.path): mode \(String(e.mode, radix: 8)) vs \(String(w.mode, radix: 8))")
                }
                if w.flags != Int(e.flags) { diffs.append("\(e.path): flags \(e.flags) vs \(w.flags)") }
                if w.size != Int(e.size) { diffs.append("\(e.path): size \(e.size) vs \(w.size)") }
                if let s = w.sha256, s != e.sha256 { diffs.append("\(e.path): sha256") }
                if w.link != e.link { diffs.append("\(e.path): link \(e.link ?? "-") vs \(w.link ?? "-")") }
            }
            #expect(diffs.isEmpty, "\(diffs.prefix(20))")
        }
    }

    /// In-place owner and mode edits land in the catalog records; an unknown path throws.
    @Test(
        .enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"),
        arguments: HFSOracle.ipads
    ) func ownershipEdits(_ fw: Oracle.Firmware) async throws {
        try await Oracle.withTemp { dir in
            guard let raw = try await HFSOracle.rawSystem(fw, in: dir) else {
                try FixtureRequirements.missing(
                    #"HFSPlusTests.swift: let raw = try await HFSOracle.rawSystem(fw, in: dir)"#
                )
            }
            let specs = [
                "private/var/mobile:0:0", "System/Library/LaunchDaemons/com.apple.SpringBoard.plist:501:20",
                "usr/libexec/lockdownd:0:0:4755", "private/var/Keychains:64:0:700", "Applications:0:80"
            ]
            let vol = try HFSPlusVolume(raw, writable: true)
            var changed = 0
            for s in specs {
                let p = s.split(separator: ":").map(String.init)
                changed += try vol.setOwner(
                    [p[0]],
                    uid: UInt32(p[1])!,
                    gid: UInt32(p[2])!,
                    mode: p.count > 3 ? UInt16(p[3], radix: 8) : nil
                )
            }
            #expect(changed >= 3)
            let back = try HFSPlusVolume(raw)
            for s in specs {
                let p = s.split(separator: ":").map(String.init)
                let r = try back.record(at: p[0])
                #expect(r.uid == UInt32(p[1])! && r.gid == UInt32(p[2])!, "\(s)")
                if p.count > 3 { #expect(r.mode & 0o7777 == UInt16(p[3], radix: 8)!, "\(s)") }
            }
            #expect(try back.record(at: "usr/libexec/lockdownd").mode == 0o104755)
            #expect(throws: FirmwareError.self) { try vol.setOwner(["no/such/path"], uid: 0, gid: 0) }
        }
    }
}

@Suite(.detachesItsImages) struct HFSPlusNameTests {
    /// A name holding ":" on the host is stored with "/" in the catalog (1.0's zoneinfo/Etc/GMT-0:15): paths
    /// and lookups use the host's form, so the stopped edit can restore its metadata.
    @Test func slashInCatalogName() async throws {
        let dir = try Fixtures.tempDir("hfs-colon")
        defer { TemporaryTrees.remove(dir) }
        let image = dir.appendingPathComponent("v.img")
        try await VolumeMount.makeHFS(image, size: 8 << 20, name: "Colon")
        try await VolumeMount.withMounted(image, at: dir.appendingPathComponent("m")) { root in
            try Data("x".utf8).write(to: root.appendingPathComponent("GMT-0:15"))
        }
        let v = try HFSPlusVolume(image)
        #expect(try v.catalog().contains { $0.name == "GMT-0/15" })
        #expect(try v.paths().contains { $0.path == "GMT-0:15" })
        #expect(try v.contents(v.record(at: "GMT-0:15")) == Data("x".utf8))
    }
}
