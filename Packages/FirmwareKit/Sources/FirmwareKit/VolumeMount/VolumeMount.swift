// VolumeMount: file-level edits of a raw HFS+ image through the stock tools, as an ordinary user (no root).
// Ports ipad1_rootfs.Mounted / grow_to_partition, build_nand.attach / resize and ipad1_nand.make_hfs_image.
//
//   try VolumeMount.withMounted(image, at: mountPoint) { root in ... }   // attach + diskutil mount (noowners,
//                                                                        // nobrowse); then junk removed, unmount
//                                                                        // (retried), fsck_hfs -fn, detach
//   try VolumeMount.makeHFS(image, size: bytes, name: "Data")            // sparse, case-sensitive, journaled
//   try VolumeMount.grow(image, toBytes: n)                              // hdiutil resize + alternate header fix
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
    public static func withMounted<T>(_ image: URL, at mountPoint: URL, _ body: (URL) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let dev = try attach(image)
        let result: Result<T, Error>
        do {
            try run("/usr/sbin/diskutil", ["mount", "-mountOptions", "nobrowse", "-mountPoint", mountPoint.path, dev])
            result = Result { try body(mountPoint) }
        } catch {
            detach(dev)
            throw error
        }
        for j in junk { try? FileManager.default.removeItem(at: mountPoint.appendingPathComponent(j)) }
        var unmounted = false
        for _ in 0..<20 {
            if (try? run("/usr/sbin/diskutil", ["unmount", dev])) != nil { unmounted = true; break }
            usleep(500_000)
        }
        var fsck: (ok: Bool, output: String) = (false, "")
        if unmounted, case .success = result { fsck = check(dev) }
        detach(dev, force: !unmounted)
        let value = try result.get()
        guard unmounted else { throw FirmwareError(.internal, "could not unmount \(mountPoint.path) (\(dev))") }
        guard fsck.ok else {
            throw FirmwareError(.internal, "fsck_hfs is not happy with \(image.lastPathComponent): \(fsck.output.suffix(600))")
        }
        return value
    }

    /// `hdiutil attach -nomount` of a raw image; returns its /dev/diskN.
    public static func attach(_ image: URL) throws -> String {
        let out = try run("/usr/bin/hdiutil", ["attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", "-nobrowse", image.path])
        guard let dev = out.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("/dev/disk") }) else {
            throw FirmwareError(.internal, "hdiutil attach \(image.lastPathComponent): no device in \(out)")
        }
        return String(dev)
    }

    /// Detaches `dev`, retrying; with `force`, falls back to `hdiutil detach -force`. Never throws: it is cleanup.
    public static func detach(_ dev: String, force: Bool = false) {
        for i in 0..<10 {
            if (try? run("/usr/bin/hdiutil", ["detach", dev] + (force && i > 0 ? ["-force"] : []))) != nil { return }
            usleep(500_000)
        }
    }

    /// `fsck_hfs -fn` (check only; -f because the data volume is journaled) of an attached, unmounted device.
    public static func check(_ dev: String) -> (ok: Bool, output: String) {
        let (status, out) = exec("/sbin/fsck_hfs", ["-fn", dev])
        return (status == 0 && out.contains("appears to be OK"), out)
    }

    /// A bare (no partition map) case-sensitive journaled HFS+ volume in a sparse raw file of `size` bytes
    /// (rounded down to 4 KiB): newfs_hfs writes only metadata, so a 14.7 GB data volume costs ~40 MB.
    public static func makeHFS(_ image: URL, size: Int64, name: String = "Data") throws {
        guard FileManager.default.createFile(atPath: image.path, contents: nil), truncate(image.path, off_t(size / 4096 * 4096)) == 0 else {
            throw FirmwareError(.internal, "cannot create \(image.path)")
        }
        let dev = try attach(image)
        defer { detach(dev) }
        try run("/sbin/newfs_hfs", ["-s", "-J", "-v", name, dev])
    }

    /// Grows the volume in `image` to `bytes` (a multiple of 4096). hdiutil grows the file and the file
    /// system, but with 8 KiB HFS blocks it stops one 4 KiB sector short; pad the file and move the
    /// alternate volume header to the new end - 1024, where fsck_hfs and the kernel look for it.
    public static func grow(_ image: URL, toBytes bytes: Int) throws {
        guard try size(image) != bytes else { return }
        try run("/usr/bin/hdiutil", ["resize", "-sectors", String(bytes / 512), "-imagekey", "diskimage-class=CRawDiskImage", image.path])
        let old = try size(image)
        guard old <= bytes else { throw FirmwareError(.internal, "hdiutil resize overshot \(bytes) bytes (\(old))") }
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
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let (status, out) = exec(tool, args)
        guard status == 0 else {
            throw FirmwareError(.internal, "\((tool as NSString).lastPathComponent) \(args.first ?? "") failed (\(status)): \(out)")
        }
        return out
    }

    /// (status, stdout and stderr interleaved): one pipe, so a chatty tool never blocks on the other one.
    static func exec(_ tool: String, _ args: [String]) -> (Int32, String) {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "\(error)") }
        try? out.fileHandleForWriting.close()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self))
    }
}
