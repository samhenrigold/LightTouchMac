// VolumeMount: file-level edits of a raw HFS+ image through the stock tools, as an ordinary user (no root).
// Ports ipad1_rootfs.Mounted / grow_to_partition, build_nand.attach / resize and ipad1_nand.make_hfs_image.
// The disk-image operations (attach, detach, resize) go through DiskImage; mount/unmount, newfs_hfs and
// fsck_hfs are run here.
//
//   try await VolumeMount.withVolume(image, at: mountPoint) { v in ... }       // VolumeFiles: the mount below, or
//                                                                        // HFSPlusWriter (--hfs writer)
//   try await VolumeMount.withMounted(image, at: mountPoint) { root in ... }   // attach + diskutil mount (nobrowse,
//                                                                        // nosuid, nodev); then junk removed, unmount
//                                                                        // (retried), fsck_hfs -fn, detach
//   try await VolumeMount.makeHFS(image, size: bytes, name: "Data")            // sparse, case-sensitive, journaled
//   try await VolumeMount.grow(image, toBytes: n)                              // resize + alternate header fix
//
// The mount is noowners: everything written lands as the host user and chown is refused, so owners are
// patched offline afterwards with HFSPlusVolume.setOwner. Write files in place (never replace them by
// rename) so an existing file keeps its catalog record and Apple's owner. A device's volume holds what the device
// wrote, links included: files on it are read and written through DevicePath, from the root these hand out (its
// real path), and it is mounted nosuid and nodev.

import FirmwareSchema
import Foundation

public enum VolumeMount {
    /// How volumes are edited: `kernel`, attached and mounted through the stock tools (the default), or `writer`,
    /// offline through HFSPlusWriter and UDIFReader.
    public typealias Backend = HFSRoute

    /// FIRMWAREKIT_HFS=writer|kernel, else kernel; create and unpack-base bind their --hfs here for the run.
    @TaskLocal public static var backend: Backend =
        ProcessInfo.processInfo.environment["FIRMWAREKIT_HFS"].flatMap(Backend.init) ?? .kernel

    /// What macOS drops on a mounted volume; removed from its root before unmounting.
    public static let junk = [".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems", ".DS_Store"]

    /// Mounts `image` read-write at `mountPoint` (created if needed), runs `body` with the mount root, then
    /// removes `junk`, unmounts (retrying while Spotlight or fseventsd hold the volume), checks it with
    /// `fsck_hfs -fn` and detaches (findings that are only folder counts are set offline and rechecked:
    /// `repairingFolderCounts`). A volume that would not unmount is never fsck'd (a mounted volume
    /// reports bogus damage); it is force-detached and the call throws. When `body` throws, its error wins.
    nonisolated(nonsending) public static func withMounted<T>(
        _ image: URL,
        at mountPoint: URL,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let mountPoint = try DevicePath.real(mountPoint)
        let journal = (try? HFSPlusVolume(image).journalSnapshot()) ?? nil
        try silenceFSEvents(image)
        let dev = try await attach(image)
        let value: T
        do {
            try await run(
                "/usr/sbin/diskutil",
                ["mount", "-mountOptions", "nobrowse,nosuid,nodev", "-mountPoint", mountPoint.path, dev]
            )
            try Task.checkCancellation()
            value = try await body(mountPoint)
            try Task.checkCancellation()
        } catch {
            // Original body/cancellation diagnostic wins; cleanup failure is explicit.
            do { _ = try await finish(dev: dev, mountPoint: mountPoint, check: false) } catch {
                FirmwareDiagnostics.write(Data("mount cleanup: \(error)\n".utf8))
            }
            throw error
        }
        let fsck = try await repairingFolderCounts(
            image,
            try await finish(dev: dev, mountPoint: mountPoint, check: true)
        )
        guard fsck.ok else {
            throw FirmwareError(
                .internal,
                "fsck_hfs is not happy with \(image.lastPathComponent): \(fsck.output.suffix(600))"
            )
        }
        if let journal { try HFSPlusVolume(image, writable: true).restore(journal) }
        return value
    }

    /// Puts `.fseventsd/no_log` on the unmounted `image` (HFSPlusWriter), so the host's fseventsd logs nothing on it
    /// once mounted; the junk removal takes it away again. Its uuid file and event logs took a block each on the mount,
    /// how many and when varying by host and run, and the kernel put everything allocated after them that much further
    /// on (the 1.x root's journal moved with them). A volume the writer refuses is mounted as it is.
    static func silenceFSEvents(_ image: URL) throws {
        let w: HFSPlusWriter
        do { w = try HFSPlusWriter(image) } catch let refusal as FirmwareError where refusal.code == .unsupported {
            // shortcut: case-insensitive HFS+ (the restore ramdisks) or a journal to replay mounts with fseventsd on;
            // none is in a recorded listing, so upgrade if one has to be deterministic
            return
        }
        guard !w.exists(".fseventsd/no_log") else { return }
        w.recountsFolders = false  // what fsck_hfs finds after the mount is the volume's own
        try w.makeDirectory(".fseventsd")
        try w.put(Data(), at: ".fseventsd/no_log")
        try w.close()
    }

    /// `body` with the files of `image` through `backend`: kernel, `withMounted` at `mountPoint` (a MountedVolume);
    /// writer, an HFSPlusWriter dating what it writes `date` (default: the volume's modify date), `junk` removed
    /// from its root and closed (its B-trees, bitmap and headers written) after `body` returns. When `body` throws,
    /// the writer's edits are left unwritten in the catalog and the error wins.
    nonisolated(nonsending) public static func withVolume<T>(
        _ image: URL,
        at mountPoint: URL,
        date: UInt32? = nil,
        backend: Backend = backend,
        _ body: (any VolumeFiles) async throws -> T
    ) async throws -> T {
        switch backend {
        case .kernel: return try await withMounted(image, at: mountPoint) { try await body(MountedVolume(root: $0)) }
        case .writer:
            try Task.checkCancellation()
            let w = try HFSPlusWriter(image)
            if let date { w.date = date }
            let value = try await body(w)
            try Task.checkCancellation()
            // what a mount removes before unmounting, so both backends leave the same volume (the IPSW root
            // filesystems ship a .fseventsd)
            for name in junk where w.exists(name) { try w.remove(name) }
            try w.close()
            return value
        }
    }

    private static func finish(dev: String, mountPoint: URL, check shouldCheck: Bool) async throws -> (
        ok: Bool, output: String
    ) {
        try await Task.detached {
            for name in junk { try? FileManager.default.removeItem(at: mountPoint.appendingPathComponent(name)) }
            var unmounted = false
            for _ in 0..<20 {
                if (try? await run("/usr/sbin/diskutil", ["unmount", dev])) != nil {
                    unmounted = true
                    break
                }
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
        do { try await detach(dev, force: force) } catch {
            FirmwareDiagnostics.write(Data("detach cleanup: \(error)\n".utf8))
        }
    }

    /// Attaches a raw image without mounting it; returns its /dev/diskN.
    public static func attach(_ image: URL) async throws -> String { try await DiskImage.attach(image).device }

    /// The device writes these volumes and is untrusted: a mount for Finder is quarantined (Gatekeeper checks what is
    /// opened from it, and a file copied out carries the quarantine), and its setuid bits and device nodes mean nothing
    /// on the Mac.
    static let finderOptions = "noowners,quarantine,nosuid,nodev"
    static let hiddenOptions = "nobrowse," + finderOptions

    /// Attaches `image` and mounts it where Finder shows it (diskutil's /Volumes/<name>), with finderOptions.
    public static func attachVisible(_ image: URL, readOnly: Bool = false) async throws -> DiskImage.Attached {
        let dev = try await DiskImage.attach(image, readOnly: readOnly).device
        do {
            try await run(
                "/usr/sbin/diskutil",
                ["mount"] + (readOnly ? ["readOnly"] : []) + ["-mountOptions", finderOptions, dev]
            )
            let info = try await run("/usr/sbin/diskutil", ["info", "-plist", dev])
            let plist = info.range(of: "<?xml").flatMap {
                try? PropertyListSerialization.propertyList(from: Data(info[$0.lowerBound...].utf8), format: nil)
            }
            guard let mountPoint = (plist as? [String: Any])?["MountPoint"] as? String, !mountPoint.isEmpty else {
                throw FirmwareError(.internal, "diskutil mounted \(dev) nowhere: \(info.suffix(600))")
            }
            return DiskImage.Attached(device: dev, mountPoint: mountPoint)
        } catch {
            await cleanupDetach(dev, force: true)
            throw error
        }
    }

    /// Attaches `image` and mounts it at `mountPoint` (created if needed) out of Finder's sidebar and Desktop
    /// (nobrowse), owners ignored, for a Finder window opened on the folder (hiddenOptions). Detaching the device
    /// unmounts it. The mount point it returns is the folder's real path (DevicePath).
    public static func attachHidden(_ image: URL, at mountPoint: URL, readOnly: Bool = false) async throws
        -> DiskImage.Attached
    {
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let mountPoint = try DevicePath.real(mountPoint)
        let dev = try await DiskImage.attach(image, readOnly: readOnly).device
        do {
            do {
                try await run(
                    "/usr/sbin/diskutil",
                    ["mount"] + (readOnly ? ["readOnly"] : [])
                        + ["-mountOptions", hiddenOptions, "-mountPoint", mountPoint.path, dev]
                )
            } catch {
                // macOS 15's diskutil fails a mount point inside a volume mounted noowners (the data volume on the
                // system volume's private/var: "Volume on diskN failed to mount"); mount(8) takes it.
                try await run(
                    "/sbin/mount",
                    ["-t", "hfs", "-o", hiddenOptions + (readOnly ? ",rdonly" : ""), dev, mountPoint.path]
                )
            }
        } catch {
            await cleanupDetach(dev, force: true)
            throw error
        }
        return DiskImage.Attached(device: dev, mountPoint: mountPoint.path)
    }

    /// `image` attached hidden on the folder `path` of the device volume mounted at `volume` (a data volume on its
    /// system volume's private/var): a folder on that volume, reached without following a link, never one a link
    /// there leads to.
    public static func attachHidden(_ image: URL, on volume: String, at path: String, readOnly: Bool = false)
        async throws -> DiskImage.Attached
    {
        let folder = URL(fileURLWithPath: volume).appendingPathComponent(path)
        guard DevicePath.isDirectory(folder) else {
            throw FirmwareError(.unsupported, "\(folder.path): not a folder on the volume (links are not followed)")
        }
        return try await attachHidden(image, at: folder, readOnly: readOnly)
    }

    /// Detaches `dev`, retrying; with `force`, the retries force it.
    /// Failure remains observable so callers cannot release ownership as if detached.
    public static func detach(_ dev: String, force: Bool = false) async throws {
        try await DiskImage.detach(dev, force: force)
    }

    /// `fsck_hfs -fn` (check only; -f because the data volume is journaled) of an attached, unmounted device.
    public static func check(_ dev: String) async throws -> (ok: Bool, output: String) {
        let (status, out) = try await exec("/sbin/fsck_hfs", ["-fn", dev])
        return (status == 0 && out.contains("appears to be OK"), out)
    }

    /// smoke #36: macOS 27's HFS driver now and then writes a directory's HFSX folder count as 0 at the unmount
    /// (seen on directories the edit only read, e.g. 7B500's private/var/log, and on fresh data volumes), so
    /// fsck finds "Incorrect folder count in a directory". When those are fsck's only findings, set the counts
    /// it names in the detached image and check again; the result of that check is what counts. Any other
    /// finding is returned as is.
    static func repairingFolderCounts(_ image: URL, _ fsck: (ok: Bool, output: String)) async throws -> (
        ok: Bool, output: String
    ) {
        guard !fsck.ok, let counts = folderCountFindings(fsck.output) else { return fsck }
        FirmwareDiagnostics.write(
            Data("\(image.lastPathComponent): fsck_hfs found only folder counts, set offline: \(counts)\n".utf8)
        )
        try HFSPlusVolume(image, writable: true).setFolderCounts(counts)
        let dev = try await attach(image)
        let again: (ok: Bool, output: String)
        do { again = try await check(dev) } catch {
            await cleanupDetach(dev)
            throw error
        }
        try await detach(dev)
        return again.ok ? again : (false, fsck.output + "\nafter setting the folder counts:\n" + again.output)
    }

    /// CNID -> the count fsck_hfs wants, when every finding in `output` is "Incorrect folder count in a directory
    /// (id = N)" + "(It should be X instead of Y)"; nil when there is any other finding (or none).
    static func folderCountFindings(_ output: String) -> [UInt32: UInt32]? {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter {
                !$0.isEmpty && !$0.hasPrefix("** ") && !$0.hasPrefix("Executing fsck_hfs")
                    && !$0.hasPrefix("The volume name is ")
            }
        guard !lines.isEmpty, lines.count % 2 == 0 else { return nil }
        var counts: [UInt32: UInt32] = [:]
        for i in stride(from: 0, to: lines.count, by: 2) {
            guard
                let id = lines[i].wholeMatch(of: /Incorrect folder count in a directory \(id = (\d+)\)/).flatMap({
                    UInt32($0.1)
                }),
                let n = lines[i + 1].wholeMatch(of: /\(It should be (\d+) instead of \d+\)/).flatMap({ UInt32($0.1) })
            else { return nil }
            counts[id] = n
        }
        return counts
    }

    /// A bare (no partition map) case-sensitive journaled HFS+ volume in a sparse raw file of `size` bytes
    /// (rounded down to 4 KiB): newfs_hfs writes only metadata, so a 14.7 GB data volume costs ~40 MB.
    /// `date`: the writer's dates for the volume and its journal files (newfs_hfs dates them "now", which the recipes
    /// normalize afterwards).
    public static func makeHFS(
        _ image: URL,
        size: Int64,
        name: String = "Data",
        journaled: Bool = true,
        date: UInt32 = 0
    ) async throws {
        if backend == .writer {
            return try HFSPlusWriter.makeHFS(image, size: size, name: name, journaled: journaled, date: date)
        }
        guard FileManager.default.createFile(atPath: image.path, contents: nil),
            truncate(image.path, off_t(size / 4096 * 4096)) == 0
        else {
            throw FirmwareError(.internal, "cannot create \(image.path)")
        }
        let dev = try await attach(image)
        do { try await run("/sbin/newfs_hfs", ["-s"] + (journaled ? ["-J"] : []) + ["-v", name, dev]) } catch {
            await cleanupDetach(dev)
            throw error
        }
        try await detach(dev)
    }

    /// Grows the volume in `image` to `bytes` (a multiple of 4096). The resize grows the file and the file
    /// system, but keeps the file's slack past the volume (the iPad IPSW volumes: one 4 KiB sector), so the file
    /// system stops that short; pad the file and move the alternate volume header to the new end - 1024, where
    /// fsck_hfs and the kernel look for it.
    public static func grow(
        _ image: URL,
        toBytes bytes: Int,
        volumes: Backend = backend,
        backend: DiskImage.Backend = DiskImage.backend
    ) async throws {
        guard try size(image) != bytes else { return }
        if volumes == .writer { return try HFSPlusWriter.grow(image, toBytes: bytes) }
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
    static func exec(_ tool: String, _ args: [String]) async throws -> (Int32, String) {
        try await DiskImage.exec([tool] + args)
    }
}
