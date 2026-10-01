import Foundation
import Testing
@testable import FirmwareKit

/// Oracle plumbing for the HFS+ tests: the Python in Oracle.qemuIOS/imgtools, run on temp copies.
enum HFSOracle {
    static let imgtools = Oracle.qemuIOS.appendingPathComponent("imgtools")
    static var available: Bool { Oracle.exists(imgtools.appendingPathComponent("build_nand.py")) }

    /// python3 -c SCRIPT ARGS..., with imgtools importable; stdout.
    static func python(_ script: String, _ args: [String]) throws -> Data {
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", "import sys; sys.path.insert(0, \(String(reflecting: imgtools.path)))\n" + script] + args
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw FirmwareError(.internal, "python: \(String(decoding: e, as: UTF8.self))") }
        return o
    }

    /// A listing through two read-only mounts of IMG (-owners on for uid/gid where reachable, off for the
    /// rest): {path: [uid, gid, st_mode, st_flags, size, sha256, link]}. Independent of the catalog reader.
    static let walk = """
        import hashlib, json, os, subprocess, tempfile
        img = sys.argv[1]
        def walk(owners, body):
            mnt = tempfile.mkdtemp(prefix="fk-walk.")
            r = subprocess.run(["hdiutil", "attach", "-readonly", "-owners", owners, "-nobrowse", "-noverify", "-imagekey",
                                "diskimage-class=CRawDiskImage", "-mountpoint", mnt, img], capture_output=True, text=True, check=True)
            dev = r.stdout.split()[0]
            try:
                for root, dn, fn in os.walk(mnt):
                    for n in ([""] if root == mnt else []) + dn + fn:
                        p = os.path.join(root, n) if n else root
                        body(os.path.relpath(p, mnt) if n else "", p)
            finally:
                subprocess.run(["hdiutil", "detach", dev], capture_output=True)
                os.rmdir(mnt)
        out, own = {}, {}
        def meta(rel, p):
            st = os.lstat(p)
            own[rel] = (st.st_uid, st.st_gid)
        def content(rel, p):
            st = os.lstat(p)
            e = out[rel] = [None, None, st.st_mode, st.st_flags, 0 if os.path.isdir(p) and not os.path.islink(p) else st.st_size, None, None]
            if os.path.islink(p):
                e[6] = os.readlink(p)
            elif os.path.isfile(p) and os.access(p, os.R_OK):
                h = hashlib.sha256()
                with open(p, "rb") as f:
                    for c in iter(lambda: f.read(1 << 22), b""):
                        h.update(c)
                e[5] = h.hexdigest()
        walk("on", meta)
        walk("off", content)
        for k, v in out.items():
            v[0], v[1] = own.get(k, (None, None))
        json.dump(out, sys.stdout)
        """

    /// setowner.index_catalog over build_nand.FlatVolume: "parent/name" -> cnid.
    static let index = """
        import json, build_nand as bn, hfsvol, setowner
        v = bn.FlatVolume(sys.argv[1])
        idx = setowner.index_catalog(hfsvol.BTree(v.catalog))
        json.dump({"%d/%s" % k: h[3] for k, h in idx.items()}, sys.stdout)
        """

    /// build_nand.set_owner for PATH:uid:gid specs, and setowner.py's record edit for PATH:uid:gid:mode ones.
    static let setOwner = """
        import struct, build_nand as bn, hfsvol, setowner
        img, specs = sys.argv[1], sys.argv[2:]
        for s in specs:
            p = s.split(":")
            if len(p) == 3:
                bn.set_owner(img, [p[0]], int(p[1]), int(p[2]))
                continue
            v = bn.FlatVolume(img, writable=True)
            bt = hfsvol.BTree(v.catalog)
            node, off, _t, _c = setowner.resolve(setowner.index_catalog(bt), p[0])
            b = bytearray(bt.node(node))
            o = off + setowner.BSD_OFF
            struct.pack_into(">II", b, o, int(p[1]), int(p[2]))
            struct.pack_into(">H", b, o + 10, (struct.unpack_from(">H", b, o + 10)[0] & 0o170000) | int(p[3], 8))
            v.catalog.write(node * bt.node_size, bytes(b))
            v.flush()
            v.close()
        """

    /// The raw system volume of a firmware (UDIF slice of the Python cache's rootfs.dmg), in `dir`.
    static func rawSystem(_ fw: Oracle.Firmware, in dir: URL) async throws -> URL? {
        guard let dmg = fw.cache?.appendingPathComponent("rootfs.dmg"), Oracle.exists(dmg) else { return nil }
        let raw = dir.appendingPathComponent("rootfs.hfs")
        try await UDIF.extractRootfs(dmg: dmg, to: raw)
        return raw
    }

    static let ipads = ["k48ap-7B500", "k48ap-8C148"].map(Oracle.firmware)
}

@Suite(.serialized) struct HFSPlusTests {
    /// Every catalog path, owner, mode, flags, size, content sha256 and symlink target against a listing of
    /// the same image through hdiutil mounts, and the (parent, name) -> CNID index against setowner.py.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"), arguments: HFSOracle.ipads) func readerMatchesMountAndSetowner(_ fw: Oracle.Firmware) async throws {
        try await Oracle.withTemp { dir in
            guard HFSOracle.available, let raw = try await HFSOracle.rawSystem(fw, in: dir) else { try FixtureRequirements.missing(#"HFSPlusTests.swift: HFSOracle.available, let raw = try await HFSOracle.rawSystem(fw, in: dir)"#) }
            let vol = try HFSPlusVolume(raw)
            #expect(vol.signature == "HX" && vol.blockSize == 8192)
            let mine = try Oracle.time("HFSPlus listing \(fw.entryID)") { try vol.listing() }
            let walked = try JSONSerialization.jsonObject(with: HFSOracle.python(HFSOracle.walk, [raw.path])) as! [String: [Any]]
            #expect(mine.count == walked.count)
            var diffs: [String] = []
            for e in mine {
                guard let w = walked[e.path] else { diffs.append("only in the catalog: \(e.path)"); continue }
                let uid = w[0] as? Int, gid = w[1] as? Int
                if let uid, let gid, (uid, gid) != (Int(e.uid), Int(e.gid)) { diffs.append("\(e.path): owner \(e.uid):\(e.gid) vs \(uid):\(gid)") }
                if w[2] as? Int != Int(e.mode) { diffs.append("\(e.path): mode \(String(e.mode, radix: 8)) vs \(String(w[2] as! Int, radix: 8))") }
                if w[3] as? Int != Int(e.flags) { diffs.append("\(e.path): flags \(e.flags) vs \(w[3])") }
                if w[4] as? Int != Int(e.size) { diffs.append("\(e.path): size \(e.size) vs \(w[4])") }
                if let s = w[5] as? String, s != e.sha256 { diffs.append("\(e.path): sha256") }
                if w[6] as? String != e.link { diffs.append("\(e.path): link \(e.link ?? "-") vs \(w[6])") }
            }
            #expect(diffs.isEmpty, "\(diffs.prefix(20))")

            let py = try JSONSerialization.jsonObject(with: HFSOracle.python(HFSOracle.index, [raw.path])) as! [String: Int]
            let idx = try vol.index()
            #expect(py.count == idx.count)
            #expect(idx.allSatisfy { py["\($0.key.parent)/\($0.key.name)"] == Int($0.value.cnid) })
        }
    }

    /// In-place owner and mode edits: the image bytes after Swift's edits equal those after Python's.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"), arguments: HFSOracle.ipads) func ownershipEditsMatchPython(_ fw: Oracle.Firmware) async throws {
        try await Oracle.withTemp { dir in
            guard HFSOracle.available, let raw = try await HFSOracle.rawSystem(fw, in: dir) else { try FixtureRequirements.missing(#"HFSPlusTests.swift: HFSOracle.available, let raw = try await HFSOracle.rawSystem(fw, in: dir)"#) }
            let py = dir.appendingPathComponent("py.hfs")
            try FileManager.default.copyItem(at: raw, to: py)
            let specs = ["private/var/mobile:0:0", "System/Library/LaunchDaemons/com.apple.SpringBoard.plist:501:20",
                         "usr/libexec/lockdownd:0:0:4755", "private/var/Keychains:64:0:700", "Applications:0:80"]
            _ = try HFSOracle.python(HFSOracle.setOwner, [py.path] + specs)
            let vol = try HFSPlusVolume(raw, writable: true)
            var changed = 0
            for s in specs {
                let p = s.split(separator: ":").map(String.init)
                changed += try vol.setOwner([p[0]], uid: UInt32(p[1])!, gid: UInt32(p[2])!, mode: p.count > 3 ? UInt16(p[3], radix: 8) : nil)
            }
            #expect(changed >= 3)
            #expect(try Oracle.sha256(file: raw) == Oracle.sha256(file: py))
            let r = try HFSPlusVolume(raw).record(at: "usr/libexec/lockdownd")
            #expect(r.mode == 0o104755 && r.uid == 0)
            #expect(throws: FirmwareError.self) { try vol.setOwner(["no/such/path"], uid: 0, gid: 0) }
        }
    }
}
