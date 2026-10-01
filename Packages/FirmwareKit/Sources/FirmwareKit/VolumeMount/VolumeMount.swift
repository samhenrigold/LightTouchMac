// VolumeMount: file-level edits of a raw HFS+ image through the stock tools, as an ordinary user (no root).
// Ports ipad1_rootfs.Mounted / grow_to_partition, build_nand.attach / resize and ipad1_nand.make_hfs_image.
// The disk-image operations (attach, detach, resize) go through DiskImage; mount/unmount, newfs_hfs and
// fsck_hfs are run here.
//
//   try await VolumeMount.withMounted(image, at: mountPoint) { root in ... }   // attach + diskutil mount (noowners,
//                                                                        // nobrowse); then junk removed, unmount
//                                                                        // (retried), fsck_hfs -fn, detach
//   try await VolumeMount.makeHFS(image, size: bytes, name: "Data")            // sparse, case-sensitive, journaled
//   try await VolumeMount.grow(image, toBytes: n)                              // resize + alternate header fix
//
// The mount is noowners: everything written lands as the host user and chown is refused, so owners are
// patched offline afterwards with HFSPlusVolume.setOwner. Write files in place (never replace them by
// rename) so an existing file keeps its catalog record and Apple's owner.

import Foundation

public enum VolumeMount {
    /// What macOS drops on a mounted volume; removed from its root before unmounting.
    public static let junk = [".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems", ".DS_Store"]

    /// Mounts `image` read-write at `mountPoint` (created if needed), runs `body` with the mount root, then
    /// removes `junk`, unmounts (retrying while Spotlight or fseventsd hold the volume), checks it with
    /// `fsck_hfs -fn` and detaches. A volume that would not unmount is never fsck'd (a mounted volume
    /// reports bogus damage); it is force-detached and the call throws. When `body` throws, its error wins.
    nonisolated(nonsending) public static func withMounted<T>(_ image: URL, at mountPoint: URL,
        _ body: (URL) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let journal = (try? HFSPlusVolume(image).journalSnapshot()) ?? nil
        let dev = try await attach(image)
        let value: T
        do {
            try await run("/usr/sbin/diskutil", ["mount", "-mountOptions", "nobrowse", "-mountPoint", mountPoint.path, dev])
            try Task.checkCancellation()
            value = try await body(mountPoint)
            try Task.checkCancellation()
        } catch {
            // Original body/cancellation diagnostic wins; cleanup failure is explicit.
            do { _ = try await finish(dev: dev, mountPoint: mountPoint, check: false) }
            catch { FirmwareDiagnostics.write(Data("mount cleanup: \(error)\n".utf8)) }
            throw error
        }
        let fsck = try await finish(dev: dev, mountPoint: mountPoint, check: true)
        guard fsck.ok else { throw FirmwareError(.internal, "fsck_hfs is not happy with \(image.lastPathComponent): \(fsck.output.suffix(600))") }
        if let journal { try HFSPlusVolume(image, writable: true).restore(journal) }
        return value
    }

    private static func finish(dev: String, mountPoint: URL, check shouldCheck: Bool) async throws -> (ok: Bool, output: String) {
        try await Task.detached {
            for name in junk { try? FileManager.default.removeItem(at: mountPoint.appendingPathComponent(name)) }
            var unmounted = false
            for _ in 0..<20 {
                if (try? await run("/usr/sbin/diskutil", ["unmount", dev])) != nil { unmounted = true; break }
                try await Task.sleep(for: .milliseconds(500))
            }
            var checked: (ok: Bool, output: String) = (false, "")
            do {
                if unmounted && shouldCheck { checked = try await check(dev) }
            } catch {
                await cleanupDetach(dev)
                throw error
            }
            try await detach(dev, force: !unmounted)
            guard unmounted else { throw FirmwareError(.internal, "could not unmount \(mountPoint.path) (\(dev))") }
            return checked
        }.value
    }

    /// Awaited independent teardown; callers retain their resource owner until it returns.
    static func cleanupDetach(_ dev: String, force: Bool = false) async {
        do { try await detach(dev, force: force) }
        catch { FirmwareDiagnostics.write(Data("detach cleanup: \(error)\n".utf8)) }
    }

    /// Attaches a raw image without mounting it; returns its /dev/diskN.
    public static func attach(_ image: URL) async throws -> String { try await DiskImage.attach(image).device }

    /// Detaches `dev`, retrying; with `force`, the retries force it.
    /// Failure remains observable so callers cannot release ownership as if detached.
    public static func detach(_ dev: String, force: Bool = false) async throws { try await DiskImage.detach(dev, force: force) }

    /// `fsck_hfs -fn` (check only; -f because the data volume is journaled) of an attached, unmounted device.
    public static func check(_ dev: String) async throws -> (ok: Bool, output: String) {
        let (status, out) = try await exec("/sbin/fsck_hfs", ["-fn", dev])
        return (status == 0 && out.contains("appears to be OK"), out)
    }

    /// A bare (no partition map) case-sensitive journaled HFS+ volume in a sparse raw file of `size` bytes
    /// (rounded down to 4 KiB): newfs_hfs writes only metadata, so a 14.7 GB data volume costs ~40 MB.
    public static func makeHFS(_ image: URL, size: Int64, name: String = "Data") async throws {
        guard FileManager.default.createFile(atPath: image.path, contents: nil), truncate(image.path, off_t(size / 4096 * 4096)) == 0 else {
            throw FirmwareError(.internal, "cannot create \(image.path)")
        }
        let dev = try await attach(image)
        do { try await run("/sbin/newfs_hfs", ["-s", "-J", "-v", name, dev]) }
        catch { await cleanupDetach(dev); throw error }
        try await detach(dev)
    }

    /// Grows the volume in `image` to `bytes` (a multiple of 4096). The resize grows the file and the file
    /// system, but keeps the file's slack past the volume (the iPad IPSW volumes: one 4 KiB sector), so the file
    /// system stops that short; pad the file and move the alternate volume header to the new end - 1024, where
    /// fsck_hfs and the kernel look for it.
    public static func grow(_ image: URL, toBytes bytes: Int, backend: DiskImage.Backend = DiskImage.backend) async throws {
        guard try size(image) != bytes else { return }
        try await DiskImage.resize(image, toBytes: bytes, backend: backend)
        let old = try size(image)
        guard old <= bytes else { throw FirmwareError(.internal, "resize overshot \(bytes) bytes (\(old))") }
        let f = try FileHandle(forUpdating: image)
        defer { try? f.close() }
        try f.seek(toOffset: UInt64(old - 1024))
        let avh = try f.read(upToCount: 512) ?? Data()
        try f.truncate(atOffset: UInt64(bytes))
        try f.seek(toOffset: UInt64(bytes - 1024))
        try f.write(contentsOf: avh)
    }

    static func size(_ u: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Runs a tool; throws with its output on a non-zero exit. Returns its output.
    @discardableResult
    static func run(_ tool: String, _ args: [String]) async throws -> String { try await DiskImage.run([tool] + args) }

    /// (status, stdout and stderr).
    static func exec(_ tool: String, _ args: [String]) async throws -> (Int32, String) { try await DiskImage.exec([tool] + args) }
}
