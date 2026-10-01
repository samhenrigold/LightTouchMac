// VolumeExport: the offline read-only path (docs/filesystem-f0-findings.md, "Export"). For a STOPPED device:
//
//   1. clonefile the overlay into <out>/overlay (APFS clone: O(1), the source is only read);
//   2. rebuild each volume into <out>/<name>.img (VolumeRebuild), then drop the clone;
//   3. a volume that was not cleanly unmounted gets `fsck_hfs -fy` (staging copy only);
//   4. mount it read-write, privately (nobrowse), to add .metadata_never_index; unmount + fsck -fn;
//   5. mount: a read-only attach (DiskImage) with browsing on, so the stock HFS driver serves it in Finder.
//
// Base and overlay files are never opened for writing. <out>/export.json records what is attached;
// unmount(out:) detaches it and deletes <out>. Device-directory sources acquire the helper's
// exclusive storage lease. Direct base/overlay sources are for already isolated research fixtures.

import Foundation

public enum VolumeExport {
    public struct Source: Sendable {
        public let base: URL
        public let overlay: URL?
        let lease: URL?
        public init(base: URL, overlay: URL?) { self.base = base; self.overlay = overlay; lease = nil }

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
            self.base = base
            self.overlay = fm.fileExists(atPath: overlay.path) ? overlay : nil
            lease = dir.appendingPathComponent("work/lease")
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

    /// Steps 1-4: images in a fresh `out` directory, ready to attach or keep.
    public static func export(_ src: Source, volumes: Set<String>? = nil, out: URL, log: (String) -> Void = { _ in }) throws -> [Exported] {
        let lease = try src.lease.map { try StoppedStorageLease($0) }
        defer { withExtendedLifetime(lease) {} }
        let fm = FileManager.default
        let dest = out.resolvingSymlinksInPath().standardizedFileURL.path
        for source in [src.base, src.overlay].compactMap({ $0 }) {
            let path = source.resolvingSymlinksInPath().standardizedFileURL.path
            guard dest != path, !dest.hasPrefix(path + "/"), !path.hasPrefix(dest + "/") else {
                throw FirmwareError(.internal, "export destination must be separate from source storage")
            }
        }
        // Own a fresh directory; never remove a caller's pre-existing files on failure.
        guard !fm.fileExists(atPath: out.path) else {
            throw FirmwareError(.internal, "\(out.path) already exists; choose a fresh export directory")
        }
        try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: false)
        var completed = false
        defer {
            if !completed {
                do { try removeDetachedOutput(out) }
                catch { log("export staging retained at \(out.path): \(error)") }
            }
        }
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
                guard status == 0 else {
                    throw FirmwareError(.internal, "\(v.name): filesystem repair failed: \(output.suffix(600))")
                }
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
        completed = true
        return result
    }

    /// Export, then attach every image read-only where Finder shows it.
    public static func mount(_ src: Source, volumes: Set<String>? = nil, out: URL, log: (String) -> Void = { _ in }) throws -> [Exported] {
        var vols = try export(src, volumes: volumes, out: out, log: log)
        do {
            for i in vols.indices {
                let t = Date()
                let a = try DiskImage.attach(URL(fileURLWithPath: vols[i].image), readOnly: true, mount: true)
                vols[i].device = a.device
                vols[i].mountPoint = a.mountPoint
                vols[i].seconds += Date().timeIntervalSince(t)
                try write(vols, out)
            }
        } catch {
            // `vols` includes an attachment even if publishing export.json failed.
            for v in vols { if let device = v.device { VolumeMount.detach(device) } }
            try? unmount(out: out)
            throw error
        }
        return vols
    }

    /// Detaches what `out`'s export.json says is attached, then deletes `out`.
    public static func unmount(out: URL) throws {
        let vols = try readManifest(out)
        let paths = Set(vols.map { URL(fileURLWithPath: $0.image).resolvingSymlinksInPath().path })
        for attached in try DiskImage.checkedAttachedImages() where paths.contains(URL(fileURLWithPath: attached.image).resolvingSymlinksInPath().path) {
            // Query the current device node: a manifest's old /dev/diskN may have been reused.
            VolumeMount.detach(attached.device)
        }
        for attached in try DiskImage.checkedAttachedImages() where paths.contains(URL(fileURLWithPath: attached.image).resolvingSymlinksInPath().path) {
            throw FirmwareError(.internal, "\(attached.image) is still attached; close its files before unmounting")
        }
        try removeDetachedOutput(out)
    }

    static func readManifest(_ out: URL) throws -> [Exported] {
        let vols = try JSONDecoder().decode([Exported].self, from: Data(contentsOf: manifest(out)))
        let root = out.resolvingSymlinksInPath().path + "/"
        guard !vols.isEmpty, vols.allSatisfy({ URL(fileURLWithPath: $0.image).resolvingSymlinksInPath().path.hasPrefix(root) }) else {
            throw FirmwareError(.internal, "invalid export manifest; image paths must belong to the export directory")
        }
        return vols
    }

    /// Used only for staging directories created by this operation. On failed
    /// eject or image discovery, retain the artifact rather than unlink a live disk.
    static func removeDetachedOutput(_ out: URL) throws {
        let root = out.resolvingSymlinksInPath().path + "/"
        guard try DiskImage.checkedAttachedImages().allSatisfy({
            !URL(fileURLWithPath: $0.image).resolvingSymlinksInPath().path.hasPrefix(root)
        }) else {
            throw FirmwareError(.internal, "export still has attached disk images")
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
