// DiskImage: raw disk images through the stock tools, one backend per process (docs/sweep/PLAN.md C8).
// `diskutil image` where the running macOS has it (27+, where hdiutil is deprecated), else hdiutil (the floor
// is 14.4). Every attach/detach/resize/convert of FirmwareKit goes through here; mount/unmount, newfs_hfs and
// fsck_hfs are not disk-image operations and stay with VolumeMount.
//
//   let dev = try DiskImage.attach(image)                       // -nomount, nobrowse: "/dev/diskN"
//   let a = try DiskImage.attach(image, readOnly: true, mount: true)   // browsable, for Finder: a.mountPoint
//   DiskImage.detach(dev, force: true)                          // never throws: cleanup
//   try DiskImage.resize(image, toBytes: n)                     // grows the image and its volume
//   try DiskImage.convertToRaw(dmg, to: raw)                    // UDIF -> raw disk (hdiutil UDTO / diskutil RAW)
//   DiskImage.attachedImages()                                  // [(image path, /dev/diskN)] (hdiutil info: no
//                                                               // diskutil equivalent lists image paths)
//
// The argv of each operation is a pure function of (backend, arguments), so both backends are unit-tested on
// every macOS; the real calls are tested on the backend the host has. Tools run through swift-subprocess.
// FIRMWAREKIT_DISK_IMAGE=hdiutil|diskutil overrides the choice (tests, and a host where one misbehaves).

import Foundation
import Subprocess
import System

public enum DiskImage {
    public enum Backend: String, Sendable { case diskutil, hdiutil }

    /// `diskutil image` exists on macOS 27+; hdiutil still works there (deprecated) and is the floor's tool.
    public static let backend: Backend = {
        if let b = ProcessInfo.processInfo.environment["FIRMWAREKIT_DISK_IMAGE"].flatMap(Backend.init) { return b }
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? .diskutil : .hdiutil
    }()

    public struct Attached: Sendable, Equatable {
        public let device: String       // "/dev/diskN"
        public let mountPoint: String?  // where the volume was mounted, if the attach mounted it
    }

    static let raw = ["-imagekey", "diskimage-class=CRawDiskImage"]

    // MARK: argv (pure)

    /// `mount` false: attach the device only (nobrowse). `mount` true: mount where Finder shows it, owners off.
    static func attachCommand(_ image: URL, readOnly: Bool, mount: Bool, backend: Backend) -> [String] {
        switch backend {
        case .hdiutil:
            return ["/usr/bin/hdiutil", "attach", "-plist"] + raw + (readOnly ? ["-readonly"] : [])
                + (mount ? ["-owners", "off", "-noverify", "-noautoopen"] : ["-nomount", "-nobrowse"]) + [image.path]
        case .diskutil:
            return ["/usr/sbin/diskutil", "image", "attach", "--plist"] + (readOnly ? ["--readOnly"] : [])
                + (mount ? ["--mountOptions", "noowners"] : ["--noMount", "--nobrowse"]) + [image.path]
        }
    }

    static func detachCommand(_ dev: String, force: Bool, backend: Backend) -> [String] {
        switch backend {
        case .hdiutil: return ["/usr/bin/hdiutil", "detach", dev] + (force ? ["-force"] : [])
        case .diskutil: return ["/usr/sbin/diskutil", force ? "unmountDisk" : "eject"] + (force ? ["force", dev] : [dev])
        }
    }

    /// hdiutil grows a volume to the size rounded down to whole allocation blocks, less one block when the image
    /// file's end is not block-aligned (the iPad IPSW system volumes: 8 KiB blocks, the file 4 KiB past the last
    /// block); diskutil fills whatever size it is asked for, so it is asked for size - (slack mod block size). Both
    /// then give the same bytes (DiskImageTests.backendsAgree, measured for 4 KiB and 8 KiB blocks with 0-12 KiB of
    /// slack), which keeps a store's built_listing_sha256 the same on every macOS.
    static func resizeCommand(_ image: URL, bytes: Int, slack: Int, backend: Backend) -> [String] {
        switch backend {
        case .hdiutil: return ["/usr/bin/hdiutil", "resize", "-sectors", String(bytes / 512)] + raw + [image.path]
        case .diskutil: return ["/usr/sbin/diskutil", "image", "resize", "--size", String(bytes - slack), image.path]
        }
    }

    /// Both tools name the output themselves: hdiutil appends `.cdr`, diskutil `.dmg` unless the path has an
    /// extension; convertToRaw moves the result to `out`.
    static func convertCommand(_ src: URL, raw out: URL, backend: Backend) -> [String] {
        switch backend {
        case .hdiutil: return ["/usr/bin/hdiutil", "convert", src.path, "-format", "UDTO", "-quiet", "-o", out.path]
        case .diskutil: return ["/usr/sbin/diskutil", "image", "create", "from", "--format", "RAW", src.path, out.path + ".raw"]
        }
    }

    // MARK: operations

    public static func attach(_ image: URL, readOnly: Bool = false, mount: Bool = false, backend: Backend = backend) throws -> Attached {
        let out = try run(attachCommand(image, readOnly: readOnly, mount: mount, backend: backend))
        guard let a = parseAttach(out) else { throw FirmwareError(.internal, "attach \(image.lastPathComponent): no device in \(out.suffix(600))") }
        return a
    }

    /// The whole-disk entry (shortest dev-entry) of an attach plist, and the mount point of whichever entity has one.
    static func parseAttach(_ text: String) -> Attached? {
        guard let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>", options: .backwards),
              let plist = try? PropertyListSerialization.propertyList(from: Data(text[start.lowerBound..<end.upperBound].utf8), format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        let devs = entities.compactMap { $0["dev-entry"] as? String }.map { $0.hasPrefix("/dev/") ? $0 : "/dev/" + $0 }
        guard let dev = devs.min(by: { $0.count < $1.count }) else { return nil }
        return Attached(device: dev, mountPoint: entities.compactMap { $0["mount-point"] as? String }.first)
    }

    /// Detaches `dev`, retrying for 5 s; with `force`, the retries force it. Never throws: it is cleanup.
    public static func detach(_ dev: String, force: Bool = false, backend: Backend = backend) {
        for i in 0..<10 {
            if exec(detachCommand(dev, force: force && i > 0, backend: backend)).0 == 0 {
                if backend == .diskutil, force, i > 0 { _ = exec(["/usr/sbin/diskutil", "eject", dev]) }
                return
            }
            usleep(500_000)
        }
    }

    /// Grows the image file and its HFS+ volume to `bytes` (a multiple of 4096) the way hdiutil does (see resizeCommand).
    public static func resize(_ image: URL, toBytes bytes: Int, backend: Backend = backend) throws {
        var slack = 0
        if backend == .diskutil, let v = try? HFSPlusVolume(image),
           let size = (try? FileManager.default.attributesOfItem(atPath: image.path)[.size] as? Int) {
            slack = max(0, size - v.totalBlocks * v.blockSize) % v.blockSize
        }
        try run(resizeCommand(image, bytes: bytes, slack: slack, backend: backend))
    }

    /// The raw disk (partition map and all) of a UDIF image, at `out`.
    public static func convertToRaw(_ src: URL, to out: URL, backend: Backend = backend) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: out)
        do { try run(convertCommand(src, raw: out, backend: backend)) }
        catch let e as FirmwareError { throw FirmwareError(.unsupported, "convert \(src.lastPathComponent): \(e.message.suffix(600))") }
        try fm.moveItem(at: URL(fileURLWithPath: out.path + (backend == .hdiutil ? ".cdr" : ".raw")), to: out)
    }

    /// Every attached disk image: (image path, its whole-disk /dev entry). `hdiutil info` (deprecated, still
    /// functional on 27) is the only listing that names the image file; diskutil's info has no path.
    public static func attachedImages() -> [(image: String, device: String)] {
        let (status, out) = exec(["/usr/bin/hdiutil", "info", "-plist"])
        guard status == 0, let start = out.range(of: "<?xml"),
              let info = try? PropertyListSerialization.propertyList(from: Data(out[start.lowerBound...].utf8), format: nil) as? [String: Any] else { return [] }
        return (info["images"] as? [[String: Any]] ?? []).compactMap { image in
            guard let path = image["image-path"] as? String,
                  let dev = (image["system-entities"] as? [[String: Any]])?.compactMap({ $0["dev-entry"] as? String }).min(by: { $0.count < $1.count })
            else { return nil }
            return (path, dev)
        }
    }

    // MARK: running tools

    /// Runs a tool; throws with its output on a non-zero exit. Returns its output.
    @discardableResult
    static func run(_ argv: [String]) throws -> String {
        let (status, out) = exec(argv)
        guard status == 0 else {
            throw FirmwareError(.internal, "\((argv[0] as NSString).lastPathComponent) \(argv.dropFirst().prefix(2).joined(separator: " ")) failed (\(status)): \(out)")
        }
        return out
    }

    /// (status, stdout then stderr), stdin closed. Synchronous over swift-subprocess: the callers are the
    /// synchronous recipe and mount paths, run on their own threads.
    static func exec(_ argv: [String]) -> (Int32, String) {
        final class Box: @unchecked Sendable { var result: (Int32, String) = (-1, "") }
        let box = Box(), done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let r = try await Subprocess.run(.path(FilePath(argv[0])), arguments: Arguments(Array(argv.dropFirst())),
                                                 output: .string(limit: 1 << 24), error: .string(limit: 1 << 24))
                let status: Int32 = switch r.terminationStatus { case .exited(let c): c; case .signaled(let s): -s }
                box.result = (status, r.standardOutput + r.standardError)
            } catch { box.result = (-1, "\(error)") }
            done.signal()
        }
        done.wait()
        return box.result
    }
}
