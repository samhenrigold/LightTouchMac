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
import HostRuntime

public enum VolumeExport {
    public enum Source: Sendable {
        case raw(base: URL, overlay: URL?)
        case device(URL, policy: StorageRecordPolicy)

        /// Raw sources must already be isolated or retained by an explicit owner.
        public init(base: URL, overlay: URL?) { self = .raw(base: base, overlay: overlay) }
        /// Declarative selection: device.json is never inspected before exclusion.
        public init(device: URL, policy: StorageRecordPolicy = .standalone) throws {
            self = .device(device, policy: policy)
        }
        func admit() throws -> (StoppedRecordOwner?, ResolvedSource) {
            switch self {
            case let .raw(base, overlay): return (nil, ResolvedSource(base: base, overlay: overlay))
            case let .device(device, policy):
                let owner = try OwnedStorageRecord.acquire(device: device, policy: policy, allowRaw: true)
                return (owner, ResolvedSource(owner: owner))
            }
        }
    }

    struct ResolvedSource {
        let base: URL
        let overlay: URL?
        init(base: URL, overlay: URL?) { self.base = base; self.overlay = overlay }
        init(owner: StoppedRecordOwner) {
            let fm = FileManager.default
            var base = owner.paths?.base ?? (fm.fileExists(atPath: owner.device.appendingPathComponent("nand").path)
                ? owner.device.appendingPathComponent("nand") : owner.device.appendingPathComponent("base"))
            let overlay = owner.paths?.overlay ?? owner.device.appendingPathComponent("overlay")
            if fm.fileExists(atPath: base.appendingPathComponent("nand").path) { base.appendPathComponent("nand") }
            self.base = base
            self.overlay = fm.fileExists(atPath: overlay.path) ? overlay : nil
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
    nonisolated(nonsending) public static func export(_ src: Source, volumes: Set<String>? = nil, out: URL, log: (String) -> Void = { _ in }) async throws -> [Exported] {
        let (owner, resolved) = try src.admit()
        defer { owner?.lease.close() }
        let fm = FileManager.default
        let dest = out.resolvingSymlinksInPath().standardizedFileURL.path
        for source in [resolved.base, resolved.overlay].compactMap({ $0 }) {
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
        do {
            var t = Date()
            var overlay: URL?
            if let o = resolved.overlay {
                let clone = out.appendingPathComponent("overlay")
                guard clonefile(o.path, clone.path, 0) == 0 else {
                    throw FirmwareError(.internal, "clonefile \(o.path) -> \(clone.path): \(String(cString: strerror(errno))) (out must be on the overlay's APFS volume)")
                }
                overlay = clone
                log(String(format: "cloned overlay in %.1f s", Date().timeIntervalSince(t)))
            }
            defer { if let overlay { try? fm.removeItem(at: overlay) } }
            t = Date()
            let vols = try VolumeRebuild.rebuild(base: resolved.base, overlay: overlay, into: out, only: volumes)
            let rebuildTime = Date().timeIntervalSince(t)
            log(String(format: "rebuilt %@ in %.1f s", vols.map { "\($0.name) (\($0.pagesWritten) pages)" }.joined(separator: ", "), rebuildTime))
            var result: [Exported] = []
            for v in vols {
                t = Date()
                let clean = try isClean(v.image)
                var repaired = false
                if !clean {
                    let dev = try await VolumeMount.attach(v.image)
                    let status: Int32, output: String
                    do { (status, output) = try await VolumeMount.exec("/sbin/fsck_hfs", ["-fy", dev]) }
                    catch { await VolumeMount.cleanupDetach(dev); throw error }
                    try await VolumeMount.detach(dev)
                    log("\(v.name): not cleanly unmounted; fsck_hfs -fy exit \(status): \(output.suffix(300))")
                    repaired = true
                    guard status == 0 else {
                        throw FirmwareError(.internal, "\(v.name): filesystem repair failed: \(output.suffix(600))")
                    }
                }
                let mnt = out.appendingPathComponent(".mnt-\(v.name)")
                try await VolumeMount.withMounted(v.image, at: mnt) { root in
                    _ = fm.createFile(atPath: root.appendingPathComponent(".metadata_never_index").path, contents: nil)
                }
                try? fm.removeItem(at: mnt)
                result.append(Exported(volume: v.name, image: v.image.path, clean: clean, repaired: repaired, device: nil, mountPoint: nil,
                                       seconds: rebuildTime / Double(vols.count) + Date().timeIntervalSince(t)))
            }
            try write(result, out)
            return result
        } catch {
            let original = error
            do { try await Task.detached { try await removeDetachedOutput(out) }.value }
            catch { log("export staging retained at \(out.path): \(error)") }
            throw original
        }
    }

    /// Export, then attach every image read-only where Finder shows it.
    nonisolated(nonsending) public static func mount(_ src: Source, volumes: Set<String>? = nil, out: URL, log: (String) -> Void = { _ in }) async throws -> [Exported] {
        var vols = try await export(src, volumes: volumes, out: out, log: log)
        do {
            for i in vols.indices {
                let t = Date()
                let a = try await DiskImage.attach(URL(fileURLWithPath: vols[i].image), readOnly: true, mount: true)
                vols[i].device = a.device
                vols[i].mountPoint = a.mountPoint
                vols[i].seconds += Date().timeIntervalSince(t)
                try write(vols, out)
            }
        } catch {
            // `vols` includes an attachment even if publishing export.json failed.
            for v in vols { if let device = v.device { await VolumeMount.cleanupDetach(device) } }
            do { try await Task.detached { try await unmount(out: out) }.value }
            catch { log("export staging retained at \(out.path): \(error)") }
            throw error
        }
        return vols
    }

    /// Detaches what `out`'s export.json says is attached, then deletes `out`.
    nonisolated(nonsending) public static func unmount(out: URL) async throws {
        let vols = try readManifest(out)
        let paths = Set(vols.map { URL(fileURLWithPath: $0.image).resolvingSymlinksInPath().path })
        for attached in try await DiskImage.checkedAttachedImages() where paths.contains(URL(fileURLWithPath: attached.image).resolvingSymlinksInPath().path) {
            // Query the current device node: a manifest's old /dev/diskN may have been reused.
            try await VolumeMount.detach(attached.device)
        }
        for attached in try await DiskImage.checkedAttachedImages() where paths.contains(URL(fileURLWithPath: attached.image).resolvingSymlinksInPath().path) {
            throw FirmwareError(.internal, "\(attached.image) is still attached; close its files before unmounting")
        }
        try await removeDetachedOutput(out)
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
    nonisolated(nonsending) static func removeDetachedOutput(_ out: URL) async throws {
        let root = out.resolvingSymlinksInPath().path + "/"
        guard try await DiskImage.checkedAttachedImages().allSatisfy({
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
