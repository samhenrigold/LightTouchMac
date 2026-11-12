// Preparer: the entry point of `firmwarekit create` and the
// helpers every board's recipe shares: the `LightTouchDevice` oneshot boots, the ramdisk-with-helper copy,
// cancel, hashing, the lock's bytes. The steps themselves are Recipe.create; a board (K48Board, N72Board, N45Board)
// contributes only what differs.
//
//   let o = Preparer.Options(entry: e, ipsw: ipsw, out: staging, helper: helper, guestTools: dir, cache: cache)
//   try await Preparer.create(o) { event in print(event.json) }     // throws; Preparer.errorEvent(error) is the last line
//   try await Preparer.cancel(staging:)                                  // SIGTERM: descendants killed, images under staging detached
//
// STAGING_DIR gets the board's boot files, nand/ (sparse), identity.json (600), device.lock.json; scratch goes
// to STAGING_DIR/work and is removed before `done`. Decrypted components are cached as CACHE/<ipsw sha1>/ (a
// version/key-specific manifest makes an entry valid).

import Crypto
import Foundation
import HostRuntime

/// One line of the preparer's stdout.
public enum PrepareEvent: Equatable, Sendable {
    /// `seconds`: each step's expected duration, for weighting the overall bar (omitted when empty).
    case begin(steps: Int, seconds: [Double] = [])
    case step(index: Int, name: String)
    case progress(Double, detail: String? = nil)
    case warning(String)
    case done(lock: String)
    case error(code: String, message: String, piece: String? = nil)

    public var json: String {
        let o: [String: Any] =
            switch self {
            case .begin(let n, let seconds):
                ["event": "begin", "steps": n].merging(seconds.isEmpty ? [:] : ["seconds": seconds]) { a, _ in a }
            case .step(let i, let name): ["event": "step", "index": i, "name": name]
            case .progress(let f, let detail):
                ["event": "progress", "fraction": f].merging(detail.map { ["detail": $0] } ?? [:]) { a, _ in a }
            case .warning(let m): ["event": "warning", "message": m]
            case .done(let lock): ["event": "done", "lock": lock]
            case .error(let code, let m, let piece):
                ["event": "error", "code": code, "message": m].merging(piece.map { ["piece": $0] } ?? [:]) { a, _ in a }
            }
        do {
            return String(
                decoding: try JSONSerialization.data(
                    withJSONObject: o,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                ),
                as: UTF8.self
            )
        } catch {
            preconditionFailure("an event of strings and numbers is always JSON: \(error)")
        }
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
        /// device: the offline survey of what each firmware gets (`create --stop-after volumes`), the volume images kept
        /// in volumes/; no boot, no store.
        public var stopAfterVolumes = false
        /// The device's language (`create --language`, SystemEdits.Options.language); nil: the Mac's.
        public var language: String?
        /// The device's keyboards (`create --keyboards`, SystemEdits.Options.keyboards); nil: the Mac's.
        public var keyboards: [String]?
        public init(
            entry: FirmwareEntry,
            ipsw: URL,
            out: URL,
            seed: String? = nil,
            helper: URL?,
            guestTools: URL,
            cache: URL? = nil,
            sibling: (entry: FirmwareEntry, ipsw: URL)? = nil
        ) {
            self.entry = entry
            self.ipsw = ipsw
            self.out = out
            self.seed = seed
            self.helper = helper
            self.guestTools = guestTools
            self.cache = cache
            self.sibling = sibling
        }
    }

    static let halting = "it_seal: halting", rescan = "CXT is not valid"
    /// Matched over the serial log with its newlines removed: other kernel messages interleave with this line
    /// (qemu-ios imgtools/ipad1_seal.py FTL_OPEN_RE).
    static let ftlOpen = #"FTL_Open\s*\[OK\]"#
    static func ftlOpened(_ serial: String) -> Bool {
        serial.replacingOccurrences(of: "\n", with: "").range(of: ftlOpen, options: .regularExpression) != nil
    }
    static let keybagDone = "it_keybag: effaceable formatted, system keybag created",
        keybagHelper = "usr/local/bin/restored_external"

    /// The board's recipe, by the entry's board and recipe name.
    @concurrent public static func create(_ o: Options, emit: @escaping @Sendable (PrepareEvent) -> Void) async throws {
        let e = o.entry
        let board: Board =
            switch (e.board, e.recipe?.name) {
            case ("k48ap", "k48"), ("n81ap", "n81"), ("n90ap", "n90"), ("n88ap", "n88"), ("n18ap", "n18"):
                try K48Board(o)
            case ("n72ap", "n72"): try N72Board(o)
            case ("n45ap", "n45"), ("m68ap", "m68"): try N45Board(o)
            case ("n42ap", "n42"): try N42Board(o)
            default:
                throw FirmwareError(
                    .unsupported,
                    "\(e.id): no preparer for board \(e.board) recipe \(e.recipe?.name ?? "none")"
                )
            }
        try await Recipe.create(o, board: board, emit: emit)
    }

    /// The contract's error event for anything `create` throws.
    public static func errorEvent(_ error: Error) -> PrepareEvent {
        switch error {
        case let f as FirmwareError:
            return .error(
                code: f.message.contains(String(cString: strerror(ENOSPC)))
                    ? FirmwareError.Code.diskFull.rawValue : f.code.rawValue,
                message: f.message,
                piece: f.piece
            )
        case let a as ActivationFailure: return .error(code: a.code, message: a.message)
        default:
            let ns = error as NSError
            let full =
                (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC))
                || (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
                || ((ns.userInfo[NSUnderlyingErrorKey] as? NSError).map {
                    $0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOSPC)
                } ?? false)
            return .error(
                code: full ? FirmwareError.Code.diskFull.rawValue : FirmwareError.Code.internal.rawValue,
                message: ns.localizedDescription
            )
        }
    }

    // MARK: - One-shots

    struct OneShot: Decodable {
        var exited: Bool
        var exitCode: Int32
        var marker: Bool
        var seconds: Double
    }

    static func esc(_ p: URL) -> String { p.path.replacingOccurrences(of: ",", with: ",,") }

    /// One `LightTouchDevice` oneshot boot of `argv` (which routes -serial to `serial`). `powerdown`: the guest is asked
    /// to shut down `delay` s after the serial log shows `marker`, and the boot ends at its halt. `during` runs on its own
    /// thread once the helper is started (the iPod keybag's gdbstub handoff); if it throws, the helper is stopped
    /// and the error rethrown. `grants`: what argv opens outside `work`, by role, for a sandboxed helper.
    static func oneshot(
        _ helper: URL,
        argv: [String],
        machine: String,
        serial: URL,
        stop: String?,
        stopPattern: String? = nil,
        powerdown: (marker: String, delay: Double)? = nil,
        timeout: Double,
        work: URL,
        grants: [SandboxExtension.Grant],
        inherit: [Int32: Int32] = [:],
        log: (String) -> Void,
        during: (@Sendable () throws -> Void)? = nil
    ) throws -> (OneShot, String) {
        var config: [String: Any] = [
            "boot": ["argv": argv, "environment": [String: String](), "machine": machine],
            "serialLog": serial.path, "timeout": timeout
        ]
        if let stop { config["stopMarker"] = stop }
        if let stopPattern { config["stopPattern"] = stopPattern }
        if let powerdown {
            config["powerdownMarker"] = powerdown.marker
            config["powerdownDelay"] = powerdown.delay
        }
        let cfg = work.appendingPathComponent("oneshot.json")
        try JSONSerialization.data(withJSONObject: config).write(to: cfg)
        let out = Pipe()
        // A sandboxed helper's files, issued to its pid once it runs (an unreaped child) and passed on its standard
        // input (SandboxExtension): the work folder (this config) and the serial log's read-write, `grants`, and a
        // Debug helper's emulator outside its bundle.
        let sandboxed = HelperSandbox.isSandboxed(helper)
        let grantPipe = sandboxed ? Pipe() : nil
        let pid = try spawn(
            helper,
            HelperLaunch(.oneshot(config: cfg.path)).arguments,
            stdin: grantPipe?.fileHandleForReading.fileDescriptor,
            stdout: out.fileHandleForWriting.fileDescriptor,
            inherit: inherit
        )
        try? out.fileHandleForWriting.close()
        try? grantPipe?.fileHandleForReading.close()
        if let grantPipe {
            let (tokens, refused) = SandboxExtension.issue(
                grants + [.init(work, .readWrite), .init(serial.deletingLastPathComponent(), .readWrite)]
                    + HelperSandbox.emulatorGrants(helper: helper),
                to: .pid(pid)
            )
            if !refused.isEmpty { log("one-shot: no sandbox grant for \(refused.joined(separator: ", "))") }
            try? grantPipe.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(tokens))
            try? grantPipe.fileHandleForWriting.close()
        }
        final class Failure: @unchecked Sendable { var error: Error? }
        let failure = Failure()
        let finished = DispatchSemaphore(value: 0)
        if let during {
            Thread.detachNewThread {
                do { try during() } catch {
                    failure.error = error
                    kill(pid, SIGTERM)
                }
                finished.signal()
            }
        } else {
            finished.signal()
        }
        let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        finished.wait()
        if let error = failure.error { throw error }
        let text = (try? String(contentsOf: serial, encoding: .isoLatin1)) ?? ""
        guard let line = lines.split(separator: "\n").last(where: { $0.contains("\"oneshot\"") }),
            let r = try? JSONDecoder().decode(OneShot.self, from: Data(line.utf8))
        else {
            throw FirmwareError(
                .oneshotFailed,
                "\(helper.lastPathComponent) oneshot exited \(status >> 8 & 0xff) without a result"
            )
        }
        log(
            String(
                format: "one-shot: %@ after %.0f s (exit %d)",
                r.marker ? "marker" : r.exited ? "halted" : "timed out",
                r.seconds,
                r.exitCode
            )
        )
        return (r, text)
    }

    /// `executable` with `arguments`, standard input `stdin` (/dev/null when nil), standard output `stdout`, this
    /// process's standard error, and `inherit`'s descriptors (child's number: this process's), nothing else; its pid.
    /// (Process passes no descriptor beyond the standard three: a sandboxed one-shot's gdbstub listener is one.)
    static func spawn(
        _ executable: URL,
        _ arguments: [String],
        stdin: Int32?,
        stdout: Int32,
        inherit: [Int32: Int32]
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        if let stdin {
            posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, 2, 2)
        for (child, parent) in inherit { posix_spawn_file_actions_adddup2(&actions, parent, child) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { for arg in argv { free(arg) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ)
        guard rc == 0 else {
            throw FirmwareError(
                .oneshotFailed, "can't start \(executable.lastPathComponent): \(String(cString: strerror(rc)))")
        }
        return pid
    }

    /// The sibling entry's restore ramdisk (Update, else Restore), decrypted with that entry's key into `work`.
    static func siblingRamdisk(_ sib: FirmwareEntry, ipsw url: URL, work: URL) throws -> URL {
        let ipsw = IPSWArchive(url)
        let comp = try BuildComponents.load(ipsw, board: sib.board)
        guard let path = comp["UpdateRamDisk"] ?? comp["RestoreRamDisk"] else {
            throw FirmwareError(.unsupported, "\(sib.id): no ramdisk")
        }
        let k = try sib.key(forPath: path)
        guard let ivHex = k.iv, let iv = Data(hex: ivHex), let key = Data(hex: k.key) else {
            throw FirmwareError(.keyMissing, "\(sib.id): no IV/key for \(k.file)")
        }
        guard let name = path.split(separator: "/").last else {
            throw FirmwareError(.unsupported, "\(sib.id): ramdisk path \(path) names no file")
        }
        let out = work.appendingPathComponent("sibling-" + String(name.dropLast(4)) + "-ramdisk.dmg")
        try IMG3.decrypt(try ipsw.read(path), iv: iv, key: key).write(to: out)
        return out
    }

    /// ipad1_keybag.ramdisk_with_helper: a private copy of the restore ramdisk, 1 MiB larger, with `helper` as
    /// root's restored_external (mode 755), which the ramdisk's rc.boot runs first.
    nonisolated(nonsending) static func ramdiskWithHelper(_ src: URL, helper: URL, work: URL) async throws -> URL {
        let fm = FileManager.default
        let rd = work.appendingPathComponent("keybag-ramdisk.dmg")
        try fm.copyItem(at: src, to: rd)
        // Through the kernel whatever the backend: every restore ramdisk is case-insensitive HFS+, which
        // HFSPlusWriter does not write.
        try await VolumeMount.grow(
            rd,
            toBytes: (VolumeMount.size(rd) + (1 << 20) + 4095) / 4096 * 4096,
            volumes: .kernel
        )
        let it = try Data(contentsOf: helper)
        try await VolumeMount.withVolume(rd, at: work.appendingPathComponent("mnt-keybag"), backend: .kernel) { v in
            try v.put(it, at: keybagHelper, mode: 0o755)
        }
        try? fm.removeItem(at: work.appendingPathComponent("mnt-keybag"))
        _ = try HFSPlusVolume(rd, writable: true).setOwner([keybagHelper], uid: 0, gid: 0)
        return rd
    }

    // MARK: - Cancel

    /// SIGTERM: every descendant gets SIGTERM (SIGKILL after 1 s), then disk images under `staging` are
    /// force-detached before successful return. Child termination is bounded; disk
    /// query/detach retries may take longer. Failure retains staging for inspection.
    /// Signal cancellation first stops owned recipe/helper descendants; no disk query is hidden.
    public struct ChildProcess: Sendable {
        let pid: pid_t
        let seconds: UInt64
        let microseconds: UInt64
    }
    /// Capture before cancelling the operation; cleanup tools spawned afterward
    /// are different work and must not be swept into a later kill pass.
    public static func childrenForCancellation() -> [ChildProcess] {
        childProcesses(of: getpid())
    }
    public static func stopChildren(_ children: [ChildProcess]) async {
        await Task.detached { await terminate(children, grace: 1) }.value
    }

    public static func cancel(staging: URL) async throws {
        await terminateDescendants(of: getpid(), grace: 1)
        try await DiskImage.detachAll(under: staging)
    }

    /// Every process below `root` (depth first, children before their parent), as libproc sees it now.
    static func descendants(of root: pid_t) -> [pid_t] {
        var buf = [pid_t](repeating: 0, count: 512)
        let n = Int(proc_listchildpids(root, &buf, Int32(buf.count * MemoryLayout<pid_t>.size)))
        return buf.prefix(max(0, min(n, buf.count))).filter { $0 > 0 }.flatMap { descendants(of: $0) + [$0] }
    }

    private static func childProcesses(of root: pid_t) -> [ChildProcess] {
        descendants(of: root).compactMap { pid in
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else {
                return nil
            }
            return ChildProcess(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
        }
    }
    private static func isSameProcess(_ process: ChildProcess) -> Bool {
        var info = proc_bsdinfo()
        return proc_pidinfo(process.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
            && info.pbi_start_tvsec == process.seconds && info.pbi_start_tvusec == process.microseconds
            && info.pbi_status != SZOMB
    }
    static func terminateDescendants(of root: pid_t, grace: TimeInterval) async {
        let children = childProcesses(of: root)
        await Task.detached { await terminate(children, grace: grace) }.value
    }
    private static func terminate(_ children: [ChildProcess], grace: TimeInterval) async {
        for process in children where isSameProcess(process) { kill(process.pid, SIGTERM) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(grace))
        while ContinuousClock.now < deadline, children.contains(where: isSameProcess) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        for process in children where isSameProcess(process) { kill(process.pid, SIGKILL) }
    }

    // MARK: - Files

    static func digest<H: HashFunction>(_ url: URL, _ h: H, count: ((Int) -> Void)? = nil) throws -> String {
        var h = h
        let f = try FileHandle(forReadingFrom: url)
        defer { try? f.close() }
        while let chunk = try f.read(upToCount: 1 << 22), !chunk.isEmpty {
            h.update(data: chunk)
            count?(chunk.count)
        }
        return h.finalize().hexString
    }

    /// A private copy of an IPSW in `work`, checked against the sha1 its entry pins, and the only file read after:
    /// the bytes hashed are the bytes parsed, whatever happens to the user's file (on another volume, or changed
    /// after the check). On the same APFS volume the copy is a clone, which takes no space and which a later write
    /// to the original doesn't reach.
    static func pinnedCopy(
        _ ipsw: URL,
        sha1: String,
        entry: String,
        into work: URL,
        count: ((Int) -> Void)? = nil
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = work.appendingPathComponent("\(sha1.lowercased()).ipsw")
        try? fm.removeItem(at: copy)
        try fm.copyItem(at: ipsw.resolvingSymlinksInPath(), to: copy)
        let actual = try digest(copy, Insecure.SHA1(), count: count)
        guard actual == sha1.lowercased() else {
            try? fm.removeItem(at: copy)
            throw FirmwareError(.shaMismatch, "\(ipsw.lastPathComponent): sha1 \(actual), \(entry) pins \(sha1)")
        }
        return copy
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        var sa = stat()
        var sb = stat()
        return stat(a.path, &sa) == 0 && stat(b.path, &sb) == 0 && sa.st_dev == sb.st_dev
    }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).hexString }

    /// fit.json's bytes (DeviceLock writes device.lock.json's). A value JSONSerialization cannot write (a Swift box, an Optional) is an error
    /// event, not an NSException abort with no event.
    static func lockData(_ lock: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(lock) else {
            throw FirmwareError(.internal, "the lock holds a value that is not JSON")
        }
        return try JSONSerialization.data(
            withJSONObject: lock,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// sha256 of each of `files` (relative to `nand`, in listing order) and the listing's sha256 over
    /// "path sha256\n" lines: what identifies a store. 16.5 GB of sparse files: one core each.
    static func nandListing(_ nand: URL, files: [String], count: (@Sendable (Int) -> Void)? = nil) throws -> (
        files: [String: String], sha256: String
    ) {
        final class Hashes: @unchecked Sendable {
            let lock = NSLock()
            var sha: [String: String] = [:]
            var error: Error?
        }
        let hashes = Hashes()
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            do {
                let h = try digest(nand.appendingPathComponent(files[i]), SHA256(), count: count)
                hashes.lock.withLock { hashes.sha[files[i]] = h }
            } catch { hashes.lock.withLock { hashes.error = error } }
        }
        if let error = hashes.error { throw error }
        var listing = SHA256()
        for n in files {
            guard let h = hashes.sha[n] else { throw FirmwareError(.internal, "\(n) was not hashed") }
            listing.update(data: Data("\(n) \(h)\n".utf8))
        }
        return (hashes.sha, listing.finalize().hexString)
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
