// Preparer: the entry point of `firmwarekit create` (the preparer contract of docs/multi-device-plan.md) and the
// helpers every board's recipe shares: the `LightTouchDevice --oneshot` boots, the ramdisk-with-helper copy,
// cancel, hashing, the lock's bytes. The steps themselves are Recipe.create; a board (K48Board, N72Board, N45Board)
// contributes only what differs.
//
//   let o = Preparer.Options(entry: e, ipsw: ipsw, out: staging, helper: helper, guestTools: dir, cache: cache)
//   try Preparer.create(o) { event in print(event.json) }     // throws; Preparer.errorEvent(error) is the last line
//   Preparer.cancel(staging:)                                  // SIGTERM: descendants killed, images under staging detached
//
// STAGING_DIR gets the board's boot files, nand/ (sparse), identity.json (600), device.lock.json; scratch goes
// to STAGING_DIR/work and is removed before `done`. Decrypted components are cached as CACHE/<ipsw sha1>/ (a
// .done marker makes an entry valid).

import CryptoKit
import Foundation

/// One line of the preparer's stdout.
public enum PrepareEvent: Equatable, Sendable {
    /// `seconds`: each step's expected duration, for weighting the overall bar (omitted when empty).
    case begin(steps: Int, seconds: [Double] = []), step(index: Int, name: String), progress(Double, detail: String? = nil), warning(String)
    case done(lock: String), error(code: String, message: String)

    public var json: String {
        let o: [String: Any] = switch self {
        case .begin(let n, let seconds): ["event": "begin", "steps": n].merging(seconds.isEmpty ? [:] : ["seconds": seconds]) { a, _ in a }
        case .step(let i, let name): ["event": "step", "index": i, "name": name]
        case .progress(let f, let detail): ["event": "progress", "fraction": f].merging(detail.map { ["detail": $0] } ?? [:]) { a, _ in a }
        case .warning(let m): ["event": "warning", "message": m]
        case .done(let lock): ["event": "done", "lock": lock]
        case .error(let code, let m): ["event": "error", "code": code, "message": m]
        }
        return String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}

public enum Preparer {
    public struct Options: Sendable {
        public var entry: FirmwareEntry, ipsw: URL, out: URL
        public var seed: String?, helper: URL?, cache: URL?
        /// The flat guest-helpers directory SystemEdits reads (+ it_keybag).
        public var guestTools: URL
        /// The entry named by recipe.keybag_ramdisk_from and its IPSW: its restore ramdisk boots the keybag one-shot.
        public var sibling: (entry: FirmwareEntry, ipsw: URL)?
        /// Stop after the volumes step and write fit.json (the fit checks, the seed record, the warnings) instead of a
        /// device: the offline survey of what each firmware gets (`create --stop-after volumes`); no boot, no store.
        public var stopAfterVolumes = false
        public init(entry: FirmwareEntry, ipsw: URL, out: URL, seed: String? = nil, helper: URL?,
                    guestTools: URL, cache: URL? = nil, sibling: (entry: FirmwareEntry, ipsw: URL)? = nil) {
            self.entry = entry; self.ipsw = ipsw; self.out = out; self.seed = seed
            self.helper = helper; self.guestTools = guestTools; self.cache = cache; self.sibling = sibling
        }
    }

    static let halting = "it_seal: halting", rescan = "CXT is not valid"
    /// Matched over the serial log with its newlines removed: other kernel messages interleave with this line
    /// (qemu-ios imgtools/ipad1_seal.py FTL_OPEN_RE).
    static let ftlOpen = #"FTL_Open\s*\[OK\]"#
    static func ftlOpened(_ serial: String) -> Bool {
        serial.replacingOccurrences(of: "\n", with: "").range(of: ftlOpen, options: .regularExpression) != nil
    }
    static let keybagDone = "it_keybag: effaceable formatted, system keybag created", keybagHelper = "usr/local/bin/restored_external"

    /// The board's recipe, by the entry's board and recipe name.
    public static func create(_ o: Options, emit: @escaping @Sendable (PrepareEvent) -> Void) throws {
        let e = o.entry
        let board: Board = switch (e.board, e.recipe?.name) {
        case ("k48ap", "k48"): try K48Board(o)
        case ("n72ap", "n72"): try N72Board(o)
        case ("n45ap", "n45"): try N45Board(o)
        default: throw FirmwareError(.unsupported, "\(e.id): no preparer for board \(e.board) recipe \(e.recipe?.name ?? "none")")
        }
        try Recipe.create(o, board: board, emit: emit)
    }

    /// The contract's error event for anything `create` throws.
    public static func errorEvent(_ error: Error) -> PrepareEvent {
        switch error {
        case let f as FirmwareError:
            return .error(code: f.message.contains(String(cString: strerror(ENOSPC))) ? FirmwareError.Code.diskFull.rawValue : f.code.rawValue,
                          message: f.message)
        case let a as ActivationFailure: return .error(code: a.code, message: a.message)
        default:
            let ns = error as NSError
            let full = (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)) || (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
                || ((ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { $0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOSPC) } ?? false)
            return .error(code: full ? FirmwareError.Code.diskFull.rawValue : FirmwareError.Code.internal.rawValue, message: ns.localizedDescription)
        }
    }

    // MARK: one-shots

    struct OneShot: Decodable { var exited: Bool; var exitCode: Int32; var marker: Bool; var seconds: Double }

    static func esc(_ p: URL) -> String { p.path.replacingOccurrences(of: ",", with: ",,") }

    /// One `LightTouchDevice --oneshot` boot of the ipad1 machine; `boot` is the boot-source option ("kboot=…" or
    /// "iboot=…,gid-blobs=…") and `machine` the rest (nand=…, die-id=…, nor-rw=…).
    /// -no-reboot: the one-shot ends when the guest shuts down, and a restart is a shutdown too (4.3's launchd turns
    /// it_seal's reboot(RB_HALT) into its own clean reboot(RB_AUTOBOOT); 5.x's halt restarts through the PMU),
    /// as qemu-ios imgtools/ipad1_seal.py (8edc395979).
    static func oneshot(_ helper: URL, boot: String, machine: String, serial: URL, stop: String?, stopPattern: String? = nil, timeout: Double,
                        work: URL, log: (String) -> Void) throws -> (OneShot, String) {
        let argv = ["LightTouchDevice", "-machine", "ipad1,\(boot),\(machine)", "-display", "none", "-audio", "driver=none",
                    "-monitor", "none", "-serial", "file:\(serial.path)", "-no-reboot"]
        return try oneshot(helper, argv: argv, machine: "ipad1", serial: serial, stop: stop, stopPattern: stopPattern, timeout: timeout,
                           work: work, log: log)
    }

    /// One `LightTouchDevice --oneshot` boot of `argv` (which routes -serial to `serial`). `during` runs on its own
    /// thread once the helper is started (the iPod keybag's gdbstub handoff); if it throws, the helper is stopped
    /// and the error rethrown.
    static func oneshot(_ helper: URL, argv: [String], machine: String, serial: URL, stop: String?, stopPattern: String? = nil,
                        timeout: Double, work: URL, log: (String) -> Void,
                        during: (@Sendable () throws -> Void)? = nil) throws -> (OneShot, String) {
        var config: [String: Any] = ["boot": ["argv": argv, "environment": [String: String](), "machine": machine],
                                     "serialLog": serial.path, "timeout": timeout]
        if let stop { config["stopMarker"] = stop }
        if let stopPattern { config["stopPattern"] = stopPattern }
        let cfg = work.appendingPathComponent("oneshot.json")
        try JSONSerialization.data(withJSONObject: config).write(to: cfg)
        let p = Process(), out = Pipe()
        p.executableURL = helper
        p.arguments = ["--oneshot", cfg.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = FileHandle.standardError
        try p.run()
        final class Failure: @unchecked Sendable { var error: Error? }
        let failure = Failure(), finished = DispatchSemaphore(value: 0)
        if let during {
            Thread.detachNewThread {
                do { try during() } catch { failure.error = error; p.terminate() }
                finished.signal()
            }
        } else { finished.signal() }
        let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        finished.wait()
        if let error = failure.error { throw error }
        let text = (try? String(contentsOf: serial, encoding: .isoLatin1)) ?? ""
        guard let line = lines.split(separator: "\n").last(where: { $0.contains("\"oneshot\"") }),
              let r = try? JSONDecoder().decode(OneShot.self, from: Data(line.utf8)) else {
            throw FirmwareError(.oneshotFailed, "\(helper.lastPathComponent) --oneshot exited \(p.terminationStatus) without a result")
        }
        log(String(format: "one-shot: %@ after %.0f s (exit %d)", r.marker ? "marker" : r.exited ? "halted" : "timed out", r.seconds, r.exitCode))
        return (r, text)
    }

    /// The sibling entry's restore ramdisk (Update, else Restore), decrypted with that entry's key into `work`.
    static func siblingRamdisk(_ sib: FirmwareEntry, ipsw url: URL, work: URL) throws -> URL {
        let ipsw = IPSWArchive(url)
        let comp = try BuildComponents.load(ipsw, board: sib.board)
        guard let path = comp["UpdateRamDisk"] ?? comp["RestoreRamDisk"] else { throw FirmwareError(.unsupported, "\(sib.id): no ramdisk") }
        let k = try sib.key(forPath: path)
        guard let ivHex = k.iv, let iv = Data(hex: ivHex), let key = Data(hex: k.key) else {
            throw FirmwareError(.keyMissing, "\(sib.id): no IV/key for \(k.file)")
        }
        let out = work.appendingPathComponent("sibling-" + String(path.split(separator: "/").last!.dropLast(4)) + "-ramdisk.dmg")
        try IMG3.decrypt(try ipsw.read(path), iv: iv, key: key).write(to: out)
        return out
    }

    /// ipad1_keybag.ramdisk_with_helper: a private copy of the restore ramdisk, 1 MiB larger, with `helper` as
    /// root's restored_external (mode 755), which the ramdisk's rc.boot runs first.
    static func ramdiskWithHelper(_ src: URL, helper: URL, work: URL) throws -> URL {
        let fm = FileManager.default
        let rd = work.appendingPathComponent("keybag-ramdisk.dmg")
        try fm.copyItem(at: src, to: rd)
        try VolumeMount.grow(rd, toBytes: (VolumeMount.size(rd) + (1 << 20) + 4095) / 4096 * 4096)
        let it = try Data(contentsOf: helper)
        try VolumeMount.withMounted(rd, at: work.appendingPathComponent("mnt-keybag")) { m in
            let dst = m.appendingPathComponent(keybagHelper)
            try it.write(to: dst)
            guard chmod(dst.path, 0o755) == 0 else { throw FirmwareError(.internal, "chmod \(dst.path)") }
        }
        try? fm.removeItem(at: work.appendingPathComponent("mnt-keybag"))
        _ = try HFSPlusVolume(rd, writable: true).setOwner([keybagHelper], uid: 0, gid: 0)
        return rd
    }

    // MARK: cancel

    /// SIGTERM: every descendant gets SIGTERM (SIGKILL after 1 s), then disk images under `staging` are
    /// force-detached, so the app can delete the staging directory. Bounded to well under 2 s.
    public static func cancel(staging: URL) {
        terminateDescendants(of: getpid(), grace: 1)
        let root = staging.resolvingSymlinksInPath().path + "/"
        for (path, dev) in DiskImage.attachedImages() where URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(root) {
            DiskImage.detach(dev, force: true)
        }
    }

    /// Every process below `root` (depth first, children before their parent), as libproc sees it now.
    static func descendants(of root: pid_t) -> [pid_t] {
        var buf = [pid_t](repeating: 0, count: 512)
        let n = Int(proc_listchildpids(root, &buf, Int32(buf.count * MemoryLayout<pid_t>.size)))
        return buf.prefix(max(0, min(n, buf.count))).filter { $0 > 0 }.flatMap { descendants(of: $0) + [$0] }
    }

    static func terminateDescendants(of root: pid_t, grace: TimeInterval) {
        let all = descendants(of: root)
        for p in all { kill(p, SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, all.contains(where: { kill($0, 0) == 0 && !zombie($0) }) { usleep(20_000) }
        for p in all + descendants(of: root) where kill(p, 0) == 0 { kill(p, SIGKILL) }
    }

    static func zombie(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 && info.pbi_status == SZOMB
    }

    // MARK: files

    static func digest<H: HashFunction>(_ url: URL, _ h: H, count: ((Int) -> Void)? = nil) throws -> String {
        var h = h
        let f = try FileHandle(forReadingFrom: url)
        defer { try? f.close() }
        while let chunk = try f.read(upToCount: 1 << 22), !chunk.isEmpty { h.update(data: chunk); count?(chunk.count) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// device.lock.json's bytes. A value JSONSerialization cannot write (a Swift box, an Optional) is an error
    /// event, not an NSException abort with no event.
    static func lockData(_ lock: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(lock) else { throw FirmwareError(.internal, "the lock holds a value that is not JSON") }
        return try JSONSerialization.data(withJSONObject: lock, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// sha256 of each of `files` (relative to `nand`, in listing order) and the listing's sha256 over
    /// "path sha256\n" lines: what identifies a store. 16.5 GB of sparse files: one core each.
    static func nandListing(_ nand: URL, files: [String], count: ((Int) -> Void)? = nil) throws -> (files: [String: String], sha256: String) {
        final class Hashes: @unchecked Sendable { let lock = NSLock(); var sha: [String: String] = [:]; var error: Error? }
        let hashes = Hashes()
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            do { let h = try digest(nand.appendingPathComponent(files[i]), SHA256(), count: count); hashes.lock.withLock { hashes.sha[files[i]] = h } }
            catch { hashes.lock.withLock { hashes.error = error } }
        }
        if let error = hashes.error { throw error }
        var listing = SHA256()
        for n in files { listing.update(data: Data("\(n) \(hashes.sha[n]!)\n".utf8)) }
        return (hashes.sha, listing.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// chmod -R a-w: children first, so a directory is still writable while its entries change.
    static func readOnly(_ url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            for n in try fm.contentsOfDirectory(atPath: url.path) { try readOnly(url.appendingPathComponent(n)) }
        }
        var st = stat()
        guard lstat(url.path, &st) == 0, chmod(url.path, st.st_mode & 0o7777 & ~0o222) == 0 else {
            throw FirmwareError(.internal, "chmod a-w \(url.path): \(String(cString: strerror(errno)))")
        }
    }
}
