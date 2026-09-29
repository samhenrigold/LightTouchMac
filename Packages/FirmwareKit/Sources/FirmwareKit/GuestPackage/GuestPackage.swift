// GuestPackage: the guest-package loader and seed package a prepared device starts with
// (docs/guest-package-bootstrap.md, P4). Ports qemu-ios contrib/guest-package/mkpkg.py read_pack, offer_text
// and seed.
//
//   let (written, record) = try GuestPackage.seed(volume: mnt, itpack: helpers/armv7.itpack, gles: true)
//   // written: volume-relative paths to make root-owned; record: the lock's guest_package
//
// An .itpack is "ITPACK01", a little-endian u32 index length, a JSON index {entries: [{name, size}]} and one
// zlib stream of the entries' bytes in index order.

import Compression
import CryptoKit
import Foundation

public enum GuestPackage {
    static let magic = Data("ITPACK01".utf8)
    static let root = "usr/local/lighttouch"
    static let loader = ("usr/local/bin/it_boot", "System/Library/LaunchDaemons/com.qemu.it-boot.plist")
    static let systemVersion = "System/Library/CoreServices/SystemVersion.plist"
    /// The GL engines' stock paths (mkpkg GL_TARGETS: MBX, GLENGINE, GLD, and 2.x's OPENGLES front end): hooks kept
    /// only when the preparer installed the shim or the front end.
    static let glTargets: Set<String> = ["/" + N72Board.mbx, "/" + SystemEdits.glEngine, "/" + SystemEdits.gldPath, "/" + N72Board.openGLES]

    /// What was baked: device.lock.json's guest_package (the same keys as the Python preparers').
    public struct Record: Sendable, Equatable {
        public var family: String, seed: Int, version: String, gles: Bool
        public var itpackPath: String, itpackSHA256: String
        public var hooks: [String], jobs: [String]
        public var object: [String: Any] {
            ["family": family, "seed": seed, "version": version, "gles": gles,
             "itpack": ["path": itpackPath, "sha256": itpackSHA256], "hooks": hooks, "jobs": jobs]
        }
    }

    /// The .itpack's entries by name.
    public static func read(_ url: URL) throws -> [String: Data] {
        let blob = try Data(contentsOf: url)
        guard blob.count >= 12, blob.prefix(8) == magic else { throw FirmwareError(.internal, "\(url.path): not an .itpack") }
        let n = Int(blob[8]) | Int(blob[9]) << 8 | Int(blob[10]) << 16 | Int(blob[11]) << 24
        guard blob.count >= 12 + n,
              let index = try JSONSerialization.jsonObject(with: blob[12..<12 + n]) as? [String: Any],
              let items = index["entries"] as? [[String: Any]] else { throw FirmwareError(.internal, "\(url.path): bad index") }
        let sizes = items.map { ($0["size"] as? NSNumber)?.intValue ?? -1 }, total = sizes.reduce(0, +)
        let z = [UInt8](blob[(12 + n + 2)...])      // the zlib header; COMPRESSION_ZLIB is raw deflate
        var data = [UInt8](repeating: 0, count: max(total, 1))
        guard sizes.allSatisfy({ $0 >= 0 }), compression_decode_buffer(&data, data.count, z, z.count, nil, COMPRESSION_ZLIB) == total else {
            throw FirmwareError(.internal, "\(url.path): the stream does not match the index")
        }
        var out: [String: Data] = [:], off = 0
        for (item, size) in zip(items, sizes) {
            guard let name = item["name"] as? String, !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else {
                throw FirmwareError(.internal, "\(url.path): bad entry name")
            }
            out[name] = Data(data[off..<off + size])
            off += size
        }
        return out
    }

    /// it_boot's record of a package: the offer text for `build` (mkpkg.offer_text, no verdicts).
    static func offerText(_ m: [String: Any], build: String) -> String {
        let files = m["files"] as? [[String: Any]] ?? [], jobs = m["jobs"] as? [String] ?? []
        var hooks: [String: [String: Any]] = [:]
        for h in m["hooks"] as? [[String: Any]] ?? [] { hooks[h["file"] as? String ?? ""] = h }
        var lines = ["ltpkg 1", "build " + build, "serial \(m["serial"] as? Int ?? 0) \(m["version"] as? String ?? "")"]
        for (i, f) in files.enumerated() {
            let name = f["name"] as? String ?? ""
            let kind = hooks[name] != nil ? "hook" : jobs.contains(name) ? "job" : "file"
            var line = "\(kind) \(i) \(name) \(f["mode"] as? String ?? "") \((f["size"] as? NSNumber)?.intValue ?? 0) \(f["sha256"] as? String ?? "")"
            if let h = hooks[name] { line += " " + (h["target"] as? String ?? "") + (h["respring"] as? Bool == true ? " respring" : "") }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Bakes the loader and the seed package into the system volume mounted at `volume` (mkpkg.seed): the
    /// itpack's package for the volume's ProductBuildVersion as it_boot installs one (pkgs/<serial>/ with its
    /// `offer`, `current` -> it, `state` "seed N"); the hooks whose target is on the volume (the GL engines' only
    /// when the preparer installed the shim: `gles`), target with the package's bytes and <target>.baked with what the volume had; the baked jobs the package provides
    /// removed. Returns (volume-relative paths written, all root-owned; the lock's guest_package record).
    /// mkpkg's requires.builds: an exact build id, or "<major>*" for every build of that iOS major (2.x = 5*,
    /// 3.x = 7*, 4.x = 8*).
    public static func buildMatches(_ builds: [String], _ build: String) -> Bool {
        let major = build.prefix { $0.isNumber }
        return builds.contains { $0 == build || ($0.hasSuffix("*") && $0.dropLast() == major) }
    }

    /// Every Mach-O it bakes (the loader, the package's binaries and hooks) is first proven to load on this firmware
    /// (FitCheck.loads, recorded in `fit`; one that does not fails the seed), except the GL engines' and AppSync's
    /// hooks, which their own installers check.
    public static func seed(volume m: URL, itpack: URL, gles: Bool, fit: FitCheck.Log = FitCheck.Log()) throws -> (written: [String], record: Record) {
        let fm = FileManager.default
        let entries = try read(itpack)
        let at = { (rel: String) in m.appendingPathComponent(rel) }
        guard let build = (NSDictionary(contentsOf: at(systemVersion)))?["ProductBuildVersion"] as? String else {
            throw FirmwareError(.unsupported, "no ProductBuildVersion in /\(systemVersion)")
        }
        func json(_ n: String) -> [String: Any]? { entries[n].flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
        let families = entries.keys.filter { $0.hasSuffix("/manifest.json") }.sorted().filter {
            buildMatches(((json($0)?["requires"] as? [String: Any])?["builds"] as? [String]) ?? [], build)
        }
        guard families.count == 1, var man = json(families[0]) else {
            throw FirmwareError(.unsupported, "\(itpack.lastPathComponent): \(families.count) packages for build \(build)")
        }
        let family = String(families[0].dropLast("/manifest.json".count))
        let allHooks = man["hooks"] as? [[String: Any]] ?? []
        let hooks = allHooks.filter { h in
            let target = h["target"] as? String ?? ""
            return (gles || !glTargets.contains(target)) && fm.fileExists(atPath: at(String(target.dropFirst())).path)
        }
        let dropped = Set(allHooks.compactMap { $0["file"] as? String }).subtracting(hooks.compactMap { $0["file"] as? String })
        man["hooks"] = hooks
        man["files"] = (man["files"] as? [[String: Any]] ?? []).filter { !dropped.contains($0["name"] as? String ?? "") }
        let files = man["files"] as! [[String: Any]]
        var written: [String] = []

        // the loader and the package's own binaries must load on this firmware's dyld, with this firmware's images
        let fw = FitCheck.Firmware(root: m, arch: itpack.deletingPathExtension().lastPathComponent)
        guard let loaderBytes = entries["loader/it_boot"] else { throw FirmwareError(.internal, "\(itpack.lastPathComponent): no loader/it_boot") }
        try fit.check(FitCheck.loads("it_boot (guest-package loader)", loaderBytes, on: fw), required: true)
        let hookTargets = Dictionary(hooks.map { ($0["file"] as? String ?? "", $0["target"] as? String ?? "") }, uniquingKeysWith: { a, _ in a })
        for f in files {
            let name = f["name"] as? String ?? "", target = hookTargets[name]
            guard let bytes = entries[family + "/" + name], FitCheck.isMachO(bytes),
                  !(target.map { glTargets.contains($0) || $0 == "/" + SystemEdits.appsyncPath } ?? false) else { continue }
            try fit.check(FitCheck.loads("\(family)/\(name)", bytes, on: fw, host: target.flatMap { FitCheck.host(of: $0, on: fw) }), required: true)
        }

        func payload(_ n: String) throws -> Data {
            guard let d = entries[n] else { throw FirmwareError(.internal, "\(itpack.lastPathComponent): no \(n)") }
            return d
        }
        func put(_ rel: String, _ data: Data, _ mode: mode_t) throws {
            var missing: [String] = [], parent = (rel as NSString).deletingLastPathComponent
            var isDir: ObjCBool = false
            while !parent.isEmpty, !(fm.fileExists(atPath: at(parent).path, isDirectory: &isDir) && isDir.boolValue) {
                missing.insert(parent, at: 0)
                parent = (parent as NSString).deletingLastPathComponent
            }
            for d in missing where mkdir(at(d).path, 0o777) != 0 {
                throw FirmwareError(.internal, "mkdir \(d): \(String(cString: strerror(errno)))")
            }
            try SystemEdits.put(data, at(rel), mode: mode)   // in place: an existing file keeps its catalog record
            written += missing + [rel]
        }
        let mode = { (s: Any?) in mode_t(strtoul(s as? String ?? "0", nil, 8)) }

        try put(loader.0, payload("loader/it_boot"), 0o755)
        try put(loader.1, payload("loader/com.qemu.it-boot.plist"), 0o644)
        let serial = man["serial"] as? Int ?? 0, pkg = "\(root)/pkgs/\(serial)"
        for f in files { try put(pkg + "/" + (f["name"] as! String), payload(family + "/" + (f["name"] as! String)), mode(f["mode"])) }
        try put(pkg + "/offer", Data(offerText(man, build: build).utf8), 0o644)
        try fm.createSymbolicLink(atPath: at(root + "/current").path, withDestinationPath: "pkgs/\(serial)")
        try put(root + "/state", Data("seed \(serial)\n".utf8), 0o644)
        written.append(root + "/current")
        let modes = Dictionary(files.map { ($0["name"] as! String, mode($0["mode"])) }, uniquingKeysWith: { a, _ in a })
        for h in hooks {
            let file = h["file"] as! String, target = String((h["target"] as! String).dropFirst())
            // <target>.baked keeps what the volume had (the stock file, or what the preparer put there), so a
            // package without the hook puts it back
            if !fm.fileExists(atPath: at(target + ".baked").path) {
                try put(target + ".baked", Data(contentsOf: at(target)), try SystemEdits.permissions(at(target)))
            }
            try put(target, payload(family + "/" + file), modes[file] ?? 0o755)
        }
        let jobs = (man["jobs"] as? [String] ?? []).map { ($0 as NSString).lastPathComponent }
        for j in jobs {
            let rel = "System/Library/LaunchDaemons/" + j
            if (try? fm.attributesOfItem(atPath: at(rel).path)) != nil { try fm.removeItem(at: at(rel)) }
        }
        let sha = SHA256.hash(data: try Data(contentsOf: itpack)).map { String(format: "%02x", $0) }.joined()
        return (written, Record(family: family, seed: serial, version: man["version"] as? String ?? "", gles: gles, itpackPath: itpack.path,
                                itpackSHA256: sha, hooks: hooks.map { $0["target"] as! String }, jobs: jobs))
    }
}
