// VolumeExport: the offline read-only path (docs/filesystem-f0-findings.md, "Export"). For a STOPPED device:
//
//   1. clonefile the overlay into <out>/overlay (APFS clone: O(1), the source is only read);
//   2. rebuild each volume into <out>/<name>.img (VolumeRebuild), then drop the clone;
//   3. a volume that was not cleanly unmounted gets `fsck_hfs -fy` (staging copy only);
//   4. mount it read-write, privately (nobrowse), to add .metadata_never_index; unmount + fsck -fn;
//   5. mount: `hdiutil attach -readonly` with browsing on, so the stock HFS driver serves it in Finder.
//
// Base and overlay files are never opened for writing. <out>/export.json records what is attached;
// unmount(out:) detaches it and deletes <out>. The caller (the app's lease, F0) guarantees the device is
// stopped; nothing here can tell a running device's overlay from a stopped one.

import Foundation

public enum VolumeExport {
    public struct Source: Sendable {
        public let base: URL
        public let overlay: URL?
        public init(base: URL, overlay: URL?) { self.base = base; self.overlay = overlay }

        /// A device directory: an app instance (device.json; paths relative to the state root two levels up),
        /// or an imgtools device (nand/ or base/, with overlay/ beside it). A base holding nand/ uses that.
        public init(device dir: URL) throws {
            let fm = FileManager.default
            var base: URL, overlay: URL
            let json = dir.appendingPathComponent("device.json")
            if fm.fileExists(atPath: json.path) {
                struct Instance: Decodable {
                    struct Base: Decodable { var path: String }
                    struct Storage: Decodable { var overlay: String }
                    var base: Base, storage: Storage
                }
                let i = try JSONDecoder().decode(Instance.self, from: Data(contentsOf: json))
                let state = dir.deletingLastPathComponent().deletingLastPathComponent()
                func url(_ p: String) -> URL { p.hasPrefix("/") ? URL(fileURLWithPath: p) : state.appendingPathComponent(p) }
                base = url(i.base.path); overlay = url(i.storage.overlay)
            } else {
                base = fm.fileExists(atPath: dir.appendingPathComponent("nand").path) ? dir.appendingPathComponent("nand")
                    : dir.appendingPathComponent("base")
                overlay = dir.appendingPathComponent("overlay")
            }
            if fm.fileExists(atPath: base.appendingPathComponent("nand").path) { base = base.appendingPathComponent("nand") }
            self.init(base: base, overlay: fm.fileExists(atPath: overlay.path) ? overlay : nil)
        }
    }

    public struct Exported: Sendable, Codable {
        public var volume: String
        public var image: String
        /// The guest had unmounted it cleanly (HFS+ kHFSVolumeUnmountedBit, not inconsistent).
        public var clean: Bool
        /// fsck_hfs -fy ran on the staging image.
        public var repaired: Bool
        public var device: String?
        public var mountPoint: String?
        public var seconds: Double
    }

    public static func manifest(_ out: URL) -> URL { out.appendingPathComponent("export.json") }

    /// Steps 1-4: images in `out` (created; must not exist or be empty), ready to attach or keep.
    public static func export(_ src: Source, volumes: Set<String>? = nil, out: URL, log: (String) -> Void = { _ in }) throws -> [Exported] {
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: out.path), !names.isEmpty {
            throw FirmwareError(.internal, "\(out.path) is not empty")
        }
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        var t = Date()
        var overlay: URL?
        if let o = src.overlay {
            let clone = out.appendingPathComponent("overlay")
            guard clonefile(o.path, clone.path, 0) == 0 else {
                throw FirmwareError(.internal, "clonefile \(o.path) -> \(clone.path): \(String(cString: strerror(errno))) (out must be on the overlay's APFS volume)")
            }
            overlay = clone
            log(String(format: "cloned overlay in %.1f s", Date().timeIntervalSince(t)))
        }
        defer { if let overlay { try? fm.removeItem(at: overlay) } }
        t = Date()
        let vols = try VolumeRebuild.rebuild(base: src.base, overlay: overlay, into: out, only: volumes)
        let rebuildTime = Date().timeIntervalSince(t)
        log(String(format: "rebuilt %@ in %.1f s", vols.map { "\($0.name) (\($0.pagesWritten) pages)" }.joined(separator: ", "), rebuildTime))
        var result: [Exported] = []
        for v in vols {
            t = Date()
            let clean = try isClean(v.image)
            var repaired = false
            if !clean {
                let dev = try VolumeMount.attach(v.image)
                let (status, output) = VolumeMount.exec("/sbin/fsck_hfs", ["-fy", dev])
                VolumeMount.detach(dev)
                log("\(v.name): not cleanly unmounted; fsck_hfs -fy exit \(status): \(output.suffix(300))")
                repaired = true
            }
            let mnt = out.appendingPathComponent(".mnt-\(v.name)")
            try VolumeMount.withMounted(v.image, at: mnt) { root in
                _ = fm.createFile(atPath: root.appendingPathComponent(".metadata_never_index").path, contents: nil)
            }
            try? fm.removeItem(at: mnt)
            result.append(Exported(volume: v.name, image: v.image.path, clean: clean, repaired: repaired, device: nil, mountPoint: nil,
                                   seconds: rebuildTime / Double(vols.count) + Date().timeIntervalSince(t)))
        }
        try write(result, out)
        return result
    }

    /// Export, then attach every image read-only where Finder shows it.
    public static func mount(_ src: Source, volumes: Set<String>? = nil, out: URL, log: (String) -> Void = { _ in }) throws -> [Exported] {
        var vols = try export(src, volumes: volumes, out: out, log: log)
        do {
            for i in vols.indices {
                let t = Date()
                let o = try VolumeMount.run("/usr/bin/hdiutil", ["attach", "-readonly", "-owners", "off", "-noverify", "-noautoopen",
                                                                 "-imagekey", "diskimage-class=CRawDiskImage", vols[i].image])
                // "/dev/disk8\t<tab>/Volumes/Name" (a bare volume has no partition-map line)
                guard let line = o.split(separator: "\n").first(where: { $0.hasPrefix("/dev/disk") }) else {
                    throw FirmwareError(.internal, "hdiutil attach \(vols[i].image): no device in \(o)")
                }
                let fields = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
                vols[i].device = fields.first
                vols[i].mountPoint = fields.last.flatMap { $0.hasPrefix("/") ? $0 : nil }
                vols[i].seconds += Date().timeIntervalSince(t)
                try write(vols, out)
            }
        } catch {
            try? unmount(out: out)
            throw error
        }
        return vols
    }

    /// Detaches what `out`'s export.json says is attached, then deletes `out`.
    public static func unmount(out: URL) throws {
        if let d = try? Data(contentsOf: manifest(out)), let vols = try? JSONDecoder().decode([Exported].self, from: d) {
            let attached = VolumeMount.exec("/usr/bin/hdiutil", ["info"]).1     // skip what Finder already ejected
            for v in vols where attached.contains(v.image) { v.device.map { VolumeMount.detach($0, force: true) } }
            let still = VolumeMount.exec("/usr/bin/hdiutil", ["info"]).1
            for v in vols where v.device != nil && still.contains(v.image) {
                throw FirmwareError(.internal, "\(v.image) is still attached (\(v.device!)); close what uses \(v.mountPoint ?? "it")")
            }
        }
        try FileManager.default.removeItem(at: out)
    }

    static func write(_ vols: [Exported], _ out: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(vols).write(to: manifest(out), options: .atomic)
    }

    /// kHFSVolumeUnmountedBit (8) set and kHFSVolumeInconsistentBit (11) clear.
    public static func isClean(_ image: URL) throws -> Bool {
        let f = try FileHandle(forReadingFrom: image)
        defer { try? f.close() }
        try f.seek(toOffset: 1024)
        let vh = [UInt8](try f.read(upToCount: 8) ?? Data())
        guard vh.count == 8, vh[0] == 0x48 else { throw FirmwareError(.unsupported, "\(image.lastPathComponent): no HFS+ volume header") }
        let attrs = VolumeRebuild.be32(vh, 4)
        return attrs & (1 << 8) != 0 && attrs & (1 << 11) == 0
    }
}
