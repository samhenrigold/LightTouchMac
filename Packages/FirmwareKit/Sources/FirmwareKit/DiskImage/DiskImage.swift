// DiskImage: raw disk images through the stock tools, one backend per process (docs/sweep/PLAN.md C8): hdiutil
// while macOS ships it (deprecated on 27, functional), `diskutil image` otherwise (see `backend` for why not the
// other way round). Every attach/detach/resize/convert of FirmwareKit goes through here; mount/unmount, newfs_hfs
// and fsck_hfs are not disk-image operations and stay with VolumeMount.
//
//   let dev = try await DiskImage.attach(image)                       // -nomount, nobrowse: "/dev/diskN"
//   let a = try await DiskImage.attach(image, readOnly: true, mount: true)   // browsable, for Finder: a.mountPoint
//   try await DiskImage.detach(dev, force: true)                // checked cleanup
//   try await DiskImage.resize(image, toBytes: n)                     // grows the image and its volume
//   try await DiskImage.convertToRaw(dmg, to: raw)                    // UDIF -> raw disk (hdiutil UDTO / diskutil RAW)
//   try await DiskImage.attachedImages()                                  // [(image path, /dev/diskN)] (hdiutil info: no
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

    /// hdiutil while the running macOS still has it (deprecated on 27, functional), else `diskutil image`. Not
    /// diskutil first: its attach presents the image as a solid-state device ("Solid State: Yes" in diskutil info,
    /// hdiutil's says "Info not available"), and the HFS+ driver lays a volume out differently on one (no metadata
    /// zone), so a store edited through a diskutil attach differs from the golden hashes; resize and convert are
    /// byte-identical on both. FIRMWAREKIT_DISK_IMAGE=hdiutil|diskutil overrides.
    public static let backend: Backend = {
        if let b = ProcessInfo.processInfo.environment["FIRMWAREKIT_DISK_IMAGE"].flatMap(Backend.init) { return b }
        return FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil") ? .hdiutil : .diskutil
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

    /// The caller must serialize attachment of this image (managed storage owns
    /// its lease). Compensation cannot distinguish a simultaneous raw attach of
    /// the same image from a newly attached device owned by this operation.
    public static func attach(_ image: URL, readOnly: Bool = false, mount: Bool = false, backend: Backend = backend) async throws -> Attached {
        try await attach(image, readOnly: readOnly, mount: mount, backend: backend, execute: run)
    }
    /// Internal executor boundary lets fixtures pause after an actual OS attach
    /// but before its result is delivered; production always uses the same runner.
    static func attach(_ image: URL, readOnly: Bool = false, mount: Bool = false, backend: Backend = backend,
                       execute: @Sendable ([String]) async throws -> String) async throws -> Attached {
        let prior = Set(try await checkedAttachedImages().map(\.device))
        do {
            let out = try await execute(attachCommand(image, readOnly: readOnly, mount: mount, backend: backend))
            guard let attached = parseAttach(out) else {
                throw FirmwareError(.internal, "attach \(image.lastPathComponent): no device in \(out.suffix(600))")
            }
            try Task.checkCancellation()
            return attached
        } catch {
            // An attach can take effect before its interrupted tool returns a
            // plist. Only detach newly observed devices for this exact image.
            do {
                try await Task.detached {
                    let path = image.resolvingSymlinksInPath().path
                    for item in try await checkedAttachedImages()
                        where !prior.contains(item.device)
                        && URL(fileURLWithPath: item.image).resolvingSymlinksInPath().path == path {
                        try await detach(item.device, force: true, backend: backend)
                    }
                }.value
            } catch {
                FirmwareDiagnostics.write(Data("attach cleanup failed; image retained: \(error)\n".utf8))
            }
            throw error
        }
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

    /// Detaches `dev`, retrying for 5 s; failed cleanup remains an explicit error.
    public static func detach(_ dev: String, force: Bool = false, backend: Backend = backend) async throws {
        // Cleanup is awaited, but independent of the operation's cancellation.
        try await Task.detached {
            for i in 0..<10 {
                let (status, _) = try await exec(detachCommand(dev, force: force && i > 0, backend: backend))
                if status == 0 {
                    if backend == .diskutil, force, i > 0 { try await run(["/usr/sbin/diskutil", "eject", dev]) }
                    return
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw FirmwareError(.internal, "could not detach \(dev); attached image retained")
        }.value
    }

    /// Grows the image file and its HFS+ volume to `bytes` (a multiple of 4096) the way hdiutil does (see resizeCommand).
    public static func resize(_ image: URL, toBytes bytes: Int, backend: Backend = backend) async throws {
        var slack = 0
        if backend == .diskutil, let v = try? HFSPlusVolume(image),
           let size = (try? FileManager.default.attributesOfItem(atPath: image.path)[.size] as? Int) {
            slack = max(0, size - v.totalBlocks * v.blockSize) % v.blockSize
        }
        try await run(resizeCommand(image, bytes: bytes, slack: slack, backend: backend))
    }

    /// The raw disk (partition map and all) of a UDIF image, at `out`.
    public static func convertToRaw(_ src: URL, to out: URL, backend: Backend = backend) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: out)
        do { try await run(convertCommand(src, raw: out, backend: backend)) }
        catch let e as FirmwareError { throw FirmwareError(.unsupported, "convert \(src.lastPathComponent): \(e.message.suffix(600))") }
        try fm.moveItem(at: URL(fileURLWithPath: out.path + (backend == .hdiutil ? ".cdr" : ".raw")), to: out)
    }

    /// Every attached disk image: (image path, its whole-disk /dev entry). `hdiutil info` (deprecated, still
    /// functional on 27) is the only listing that names the image file; diskutil's info has no path.
    public static func attachedImages() async throws -> [(image: String, device: String)] {
        try await checkedAttachedImages()
    }

    /// Cleanup must distinguish an empty attachment list from a failed query.
    public static func checkedAttachedImages() async throws -> [(image: String, device: String)] {
        let (status, out) = try await exec(["/usr/bin/hdiutil", "info", "-plist"])
        return try parseAttachments(status: status, output: out)
    }
    static func parseAttachments(status: Int32, output out: String) throws -> [(image: String, device: String)] {
        guard status == 0, let start = out.range(of: "<?xml"),
              let info = try? PropertyListSerialization.propertyList(from: Data(out[start.lowerBound...].utf8), format: nil) as? [String: Any],
              let images = info["images"] as? [[String: Any]] else {
            throw FirmwareError(.internal, "could not inspect mounted disk images: \(out.suffix(600))")
        }
        return images.compactMap { image in
            guard let path = image["image-path"] as? String,
                  let dev = (image["system-entities"] as? [[String: Any]])?.compactMap({ $0["dev-entry"] as? String }).min(by: { $0.count < $1.count })
            else { return nil }
            return (path, dev)
        }
    }

    // MARK: running tools

    /// Runs a tool; throws with its output on a non-zero exit. Returns its output.
    @discardableResult
    static func run(_ argv: [String]) async throws -> String {
        let (status, out) = try await exec(argv)
        guard status == 0 else {
            throw FirmwareError(.internal, "\((argv[0] as NSString).lastPathComponent) \(argv.dropFirst().prefix(2).joined(separator: " ")) failed (\(status)): \(out)")
        }
        return out
    }

    /// (status, stdout then stderr), stdin closed. Suspends while the actual
    /// library owns and reaps the child; cancellation/spawn failure stay errors.
    static func exec(_ argv: [String]) async throws -> (Int32, String) {
        let result = try await Subprocess.run(.path(FilePath(argv[0])), arguments: Arguments(Array(argv.dropFirst())),
            input: .none, output: .string(limit: 1 << 24), error: .string(limit: 1 << 24))
        try Task.checkCancellation()
        let status: Int32 = switch result.terminationStatus {
        case .exited(let code): code
        case .signaled(let signal): -signal
        }
        return (status, result.standardOutput + result.standardError)
    }
}
