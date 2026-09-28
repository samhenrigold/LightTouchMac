// Recipe: `firmwarekit create` for the k48 (iPad 1) recipe, the preparer contract of docs/multi-device-plan.md.
// Ports imgtools/device.py create + ipad1_device.build (step order, identity, lock, read-only outputs),
// ipad1_keybag.py and ipad1_seal.py over the other modules. The build-time boots run through
// `LightTouchDevice --oneshot`.
//
//   let o = Preparer.Options(entry: e, ipsw: ipsw, out: staging, helper: helper, guestTools: dir, cache: cache)
//   try Preparer.create(o) { event in print(event.json) }     // throws; Preparer.errorEvent(error) is the last line
//   Preparer.cancel(staging:)                                  // SIGTERM: descendants killed, images under staging detached
//
// STAGING_DIR gets kboot.bin, nand/ (sparse), nor.bin (writable_nor), identity.json (600), device.lock.json;
// scratch goes to STAGING_DIR/work and is removed before `done`. Decrypted components are cached as
// CACHE/<ipsw sha1>/ (a .done marker makes an entry valid).

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
        public init(entry: FirmwareEntry, ipsw: URL, out: URL, seed: String? = nil, helper: URL?,
                    guestTools: URL, cache: URL? = nil) {
            self.entry = entry; self.ipsw = ipsw; self.out = out; self.seed = seed
            self.helper = helper; self.guestTools = guestTools; self.cache = cache
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

    public static func create(_ o: Options, emit: @escaping @Sendable (PrepareEvent) -> Void) throws {
        let fm = FileManager.default, e = o.entry
        func log(_ s: String) {
            if s.hasPrefix("warning: ") { emit(.warning(String(s.dropFirst(9)))) }
            FileHandle.standardError.write(Data((s + "\n").utf8))
        }
        if e.board == "n72ap" { return try N72Recipe.create(o, emit: emit) }
        guard e.board == "k48ap", let recipe = e.recipe, recipe.name == "k48" else {
            throw FirmwareError(.unsupported, "\(e.id): no preparer for board \(e.board) recipe \(e.recipe?.name ?? "none")")
        }
        guard let sha1 = e.source.sha1 else { throw FirmwareError(.unsupported, "\(e.id) pins no IPSW sha1") }
        guard recipe.storage == "16g", recipe.dataSize == "partition" else {
            throw FirmwareError(.unsupported, "\(e.id): storage \(recipe.storage), data_size \(recipe.dataSize)")
        }
        guard (try? fm.contentsOfDirectory(atPath: o.out.path))?.isEmpty == true else {
            throw FirmwareError(.internal, "\(o.out.path) is not an empty directory")
        }
        guard let helper = o.helper, fm.isExecutableFile(atPath: helper.path) else {
            throw FirmwareError(.internal, "the seal boots need --helper (LightTouchDevice); got \(o.helper?.path ?? "none")")
        }
        if e.estimates.peakBytes > 0, let free = try? o.out.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < e.estimates.peakBytes - (e.source.bytes ?? 0) {
            throw FirmwareError(.diskFull, "needs \(e.estimates.peakBytes - (e.source.bytes ?? 0)) bytes, \(free) available")
        }
        let nor = recipe.options["writable_nor"] == true
        let steps = ["Verifying the IPSW", "Decrypting the firmware", "Writing the identity and boot image",
                     "Building the system and data volumes", "Writing the NAND"]
            + (nor ? ["Creating the data-protection keybag"] : []) + ["Sealing the NAND", "Writing the lock"]
        emit(.begin(steps: steps.count, seconds: steps.map { StepPlan.plan($0).seconds }))
        let progress = StepProgress(work: o.out.appendingPathComponent("work"), emit: emit)
        defer { progress.stop() }
        var index = 0
        func step() { index += 1; progress.next(index: index, name: steps[index - 1]); log("[\(index)/\(steps.count)] \(steps[index - 1])") }
        let file = { (n: String) in o.out.appendingPathComponent(n) }
        let work = file("work")

        step()   // verify
        let ipswBytes = ByteCount(total: (try? fm.attributesOfItem(atPath: o.ipsw.path)[.size] as? Int) ?? 0)
        progress.measure = { ipswBytes.fraction }
        let got = try digest(o.ipsw, Insecure.SHA1(), count: ipswBytes.add)
        guard got == sha1.lowercased() else { throw FirmwareError(.shaMismatch, "\(o.ipsw.lastPathComponent): sha1 \(got), \(e.id) pins \(sha1)") }
        let ipsw = IPSWArchive(o.ipsw)
        let restore = try RestoreInfo(ipsw)
        try restore.verify(against: e)

        step()   // decrypt, once per IPSW
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let cacheRoot = o.cache ?? work.appendingPathComponent("cache")
        let dec = cacheRoot.appendingPathComponent(sha1)
        if !fm.fileExists(atPath: dec.appendingPathComponent(".done").path) {
            let tmp = cacheRoot.appendingPathComponent(sha1 + ".tmp")
            try? fm.removeItem(at: tmp)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            _ = try FirmwareDecryptor.decrypt(ipsw: o.ipsw, entry: e, into: tmp)
            try JSONSerialization.data(withJSONObject: ["ipsw": o.ipsw.path, "entry": e.id, "tool": FirmwareKit.version])
                .write(to: tmp.appendingPathComponent(".done"))
            try? fm.removeItem(at: dec)
            try fm.moveItem(at: tmp, to: dec)
        } else {
            log("decrypted components cached in \(dec.path)")
        }
        let decFile = { (n: String) in dec.appendingPathComponent(n) }

        step()   // identity.json + kboot.bin
        let seed = o.seed ?? "ipad1-\(e.build)-default"
        let ident = try UnitIdentity.synthesize(seed: seed, storage: recipe.storage)
        try ident.write(to: file("identity.json"))
        try KBoot.write(decrypted: dec, to: file("kboot.bin"), identity: ident)
        let dieID = (ident.dieID ?? []).joined(separator: ":")

        step()   // MBR, system + data volumes (+ activation)
        let mbr = work.appendingPathComponent("mbr.bin")
        try K48NAND.makeMBR(geometry: .k48_16g, systemMiB: recipe.systemMiB).write(to: mbr)
        let parts = K48NAND.partitions(mbr: [UInt8](try Data(contentsOf: mbr)))
        let vols = try SystemEdits.buildK48(rootfs: decFile("rootfs.dmg"), work: work, systemBytes: parts[0].count * 4096,
                                            dataBytes: Int64(parts[1].count) * 4096, options: .init(recipe: recipe),
                                            helpers: o.guestTools, gliDispatch: recipe.gliDispatch, log: log)
        for n in vols.notes { emit(.warning(n)) }

        step()   // NAND store
        let nand = file("nand")
        try K48NAND.build(geometry: .k48_16g, mbr: mbr, kernelVersion: K48NAND.kernelVersion(kernelcache: decFile("kernelcache.mach")),
                          system: vols.system, data: .image(vols.data), out: nand, log: log)
        try? fm.removeItem(at: vols.system); try? fm.removeItem(at: vols.data)

        var ramdisk: String?
        let norURL = nor ? file("nor.bin") : nil
        if let norURL {
            step()   // 4.x data protection: effaceable + system keybag from the IPSW's own Update ramdisk
            try Data(repeating: 0xFF, count: 1 << 20).write(to: norURL)
            guard let update = try BuildComponents.load(ipsw)["UpdateRamDisk"] else { throw FirmwareError(.unsupported, "\(e.id): no Update ramdisk") }
            ramdisk = String(update.dropLast(4)) + "-ramdisk.dmg"
            try keybag(store: nand, nor: norURL, ramdisk: decFile(ramdisk!), dec: dec, identity: ident, dieID: dieID,
                       helper: helper, tools: o.guestTools, work: work, emit: emit, log: log)
        }

        step()   // seal: one clean halt, then a check boot on a throwaway overlay
        try seal(store: nand, kboot: file("kboot.bin"), dieID: dieID, nor: norURL, helper: helper, work: work, log: log)

        step()   // read-only outputs, lock
        for u in [nand, file("kboot.bin")] + (norURL.map { [$0] } ?? []) { try readOnly(u) }
        let tools = try fm.contentsOfDirectory(atPath: o.guestTools.path).sorted()
        let nandFiles = try fm.contentsOfDirectory(atPath: nand.path).sorted()
        let nandBytes = ByteCount(total: nandFiles.reduce(0) { $0 + ((try? fm.attributesOfItem(atPath: nand.appendingPathComponent($1).path)[.size] as? Int) ?? 0) })
        progress.measure = { nandBytes.fraction }
        final class Hashes: @unchecked Sendable { let lock = NSLock(); var sha: [String: String] = [:]; var error: Error? }
        let hashes = Hashes()
        DispatchQueue.concurrentPerform(iterations: nandFiles.count) { i in   // 16.5 GB of sparse files: one core each
            do { let h = try digest(nand.appendingPathComponent(nandFiles[i]), SHA256(), count: nandBytes.add); hashes.lock.withLock { hashes.sha[nandFiles[i]] = h } }
            catch { hashes.lock.withLock { hashes.error = error } }
        }
        if let error = hashes.error { throw error }
        func opt(_ v: Any?) -> Any { v ?? NSNull() }
        let null = NSNull()
        let lock: [String: Any] = [
            "format": 1, "created": ISO8601DateFormatter().string(from: Date()),
            "entry": ["id": e.id, "sha256": sha256(try JSONEncoder().encode(e)), "content": try JSONSerialization.jsonObject(with: JSONEncoder().encode(e))],
            "build": e.build, "product_version": restore.productVersion, "product_type": e.productType, "board": e.board,
            "storage": recipe.storage,
            "tool": ["name": "firmwarekit", "version": FirmwareKit.version, "helper": helper.path,
                     "helper_sha256": try digest(helper, SHA256()),
                     "built": ["guest tools": Dictionary(uniqueKeysWithValues: try tools.map { ($0, try digest(o.guestTools.appendingPathComponent($0), SHA256())) }),
                               "GLEngine": opt(vols.engine)]],
            "inputs": ["ipsw": ["path": o.ipsw.path, "sha1": got], "decrypted": dec.path, "identity": "identity.json",
                       "activation": opt(vols.activation.map { ["input_sha256": $0.inputSHA256, "output_sha256": $0.outputSHA256] }),
                       "rootfs": "rootfs.dmg", "kernelcache": "kernelcache.mach", "devicetree": "DeviceTree.bin",
                       "restore_ramdisk": opt(ramdisk), "mbr": ["sha256": try digest(mbr, SHA256())],
                       "guest_tools": o.guestTools.path, "lockdown": null, "stash": null],
            "identity": ["seed": seed, "udid": ident.udid ?? "", "die_id": dieID, "sha256": try digest(file("identity.json"), SHA256())],
            "outputs": ["kboot": ["path": "kboot.bin", "sha256": try digest(file("kboot.bin"), SHA256())],
                        "nand": ["path": "nand", "files": hashes.sha],
                        "nor": opt(try norURL.map { ["path": "nor.bin", "sha256": try digest($0, SHA256())] })],
            "gl_test": false, "guest_package": opt(vols.guestPackage?.object),
        ]
        try fm.removeItem(at: work)
        try JSONSerialization.data(withJSONObject: lock, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: file("device.lock.json"))
        log("\(o.out.path): UDID \(ident.udid ?? "-")")
        progress.finish()
        emit(.done(lock: "device.lock.json"))
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

    /// One `LightTouchDevice --oneshot` boot of the ipad1 machine; `machine` follows kboot= in -machine.
    static func oneshot(_ helper: URL, kboot: URL, machine: String, serial: URL, stop: String?, stopPattern: String? = nil, timeout: Double,
                        work: URL, log: (String) -> Void) throws -> (OneShot, String) {
        let argv = ["LightTouchDevice", "-machine", "ipad1,kboot=\(esc(kboot)),\(machine)", "-display", "none", "-audio", "driver=none",
                    "-monitor", "none", "-serial", "file:\(serial.path)"]
        var config: [String: Any] = ["boot": ["argv": argv, "environment": [String: String](), "machine": "ipad1"],
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
        let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let text = (try? String(contentsOf: serial, encoding: .isoLatin1)) ?? ""
        guard let line = lines.split(separator: "\n").last(where: { $0.contains("\"oneshot\"") }),
              let r = try? JSONDecoder().decode(OneShot.self, from: Data(line.utf8)) else {
            throw FirmwareError(.oneshotFailed, "\(helper.lastPathComponent) --oneshot exited \(p.terminationStatus) without a result")
        }
        log(String(format: "one-shot: %@ after %.0f s (exit %d)", r.marker ? "marker" : r.exited ? "halted" : "timed out", r.seconds, r.exitCode))
        return (r, text)
    }

    /// ipad1_seal: boot the store until the guest halts (it_seal), then check a boot on an overlay opens the FTL
    /// without the full R/O restore.
    static func seal(store: URL, kboot: URL, dieID: String, nor: URL?, helper: URL, work: URL, log: (String) -> Void) throws {
        let extra = ",die-id=\(dieID)" + (nor.map { ",nor-rw=\(esc($0))" } ?? "")
        let serial = work.appendingPathComponent("seal.log")
        let (r, text) = try oneshot(helper, kboot: kboot, machine: "nand=\(esc(store))" + extra, serial: serial, stop: nil,
                                    timeout: 300, work: work, log: log)
        guard r.exited, text.contains(halting) else {
            throw FirmwareError(.oneshotFailed, "seal boot: \(r.exited ? "QEMU exited without it_seal" : "no clean halt") after \(Int(r.seconds)) s")
        }
        let overlay = work.appendingPathComponent("seal-overlay")
        try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
        let (c, check) = try oneshot(helper, kboot: kboot, machine: "nand=\(esc(store)),nand-overlay=\(esc(overlay))" + extra,
                                     serial: work.appendingPathComponent("check.log"), stop: nil, stopPattern: ftlOpen, timeout: 120,
                                     work: work, log: log)
        guard c.marker, ftlOpened(check), !check.contains(rescan) else {
            throw FirmwareError(.oneshotFailed, "check boot: \(check.contains(rescan) ? "the store still rescans" : "no FTL_Open")")
        }
        try? FileManager.default.removeItem(at: overlay)
        log(check.split(separator: "\n").first { $0.contains("FTL_Open") }.map(String.init) ?? "FTL_Open [OK]")
    }

    /// ipad1_keybag: the restore ramdisk with it_keybag as restored_external, booted once as md0 on the store +
    /// NOR; retried (from copies taken before the first) when it panics or does not halt.
    static func keybag(store: URL, nor: URL, ramdisk src: URL, dec: URL, identity: UnitIdentity, dieID: String, helper: URL, tools: URL,
                       work: URL, emit: (PrepareEvent) -> Void, log: (String) -> Void) throws {
        let fm = FileManager.default
        let rd = work.appendingPathComponent("keybag-ramdisk.dmg"), kboot = work.appendingPathComponent("kboot-restore.bin")
        try fm.copyItem(at: src, to: rd)
        try VolumeMount.grow(rd, toBytes: (VolumeMount.size(rd) + (1 << 20) + 4095) / 4096 * 4096)
        let it = try Data(contentsOf: tools.appendingPathComponent("it_keybag"))
        try VolumeMount.withMounted(rd, at: work.appendingPathComponent("mnt-keybag")) { m in
            let dst = m.appendingPathComponent(keybagHelper)
            try it.write(to: dst)
            guard chmod(dst.path, 0o755) == 0 else { throw FirmwareError(.internal, "chmod \(dst.path)") }
        }
        try? fm.removeItem(at: work.appendingPathComponent("mnt-keybag"))
        _ = try HFSPlusVolume(rd, writable: true).setOwner([keybagHelper], uid: 0, gid: 0)
        try KBoot.write(decrypted: dec, to: kboot, identity: identity, ramdisk: rd)
        let norBefore = try Data(contentsOf: nor)
        let pre = work.appendingPathComponent("store.pre")
        try fm.copyItem(at: store, to: pre)   // ponytail: clonefile on APFS; a non-APFS staging volume copies in full
        let attempts = 3
        for attempt in 1...attempts {
            let serial = work.appendingPathComponent("keybag-\(attempt).log")
            let (r, text) = try oneshot(helper, kboot: kboot, machine: "nand=\(esc(store)),nor-rw=\(esc(nor)),die-id=\(dieID)", serial: serial,
                                        stop: "panic(", timeout: 300, work: work, log: log)
            for line in text.split(separator: "\n") where line.contains("it_keybag:") { log(String(line)) }
            if r.exited, text.contains(keybagDone) { break }
            let why = text.split(separator: "\n").first { $0.contains("panic(") }
                .map { String($0[$0.range(of: "panic(")!.lowerBound...].prefix(160)) } ?? (r.exited ? "halted without the keybag" : "no halt")
            guard attempt < attempts else { throw FirmwareError(.oneshotFailed, "keybag boot: \(why)") }
            emit(.warning("keybag boot attempt \(attempt)/\(attempts) failed after \(Int(r.seconds)) s: \(why); retrying"))
            try fm.removeItem(at: store)
            try fm.copyItem(at: pre, to: store)
            try norBefore.write(to: nor)
        }
        guard try Data(contentsOf: nor) != norBefore else { throw FirmwareError(.oneshotFailed, "keybag boot: effaceable was not written to the NOR") }
        for u in [pre, rd, kboot] { try? fm.removeItem(at: u) }
    }

    // MARK: cancel

    /// SIGTERM: every descendant gets SIGTERM (SIGKILL after 1 s), then disk images under `staging` are
    /// force-detached, so the app can delete the staging directory. Bounded to well under 2 s.
    public static func cancel(staging: URL) {
        terminateDescendants(of: getpid(), grace: 1)
        let root = staging.resolvingSymlinksInPath().path + "/"
        let (status, out) = VolumeMount.exec("/usr/bin/hdiutil", ["info", "-plist"])
        guard status == 0, let info = try? PropertyListSerialization.propertyList(from: Data(out.utf8), format: nil) as? [String: Any] else { return }
        for image in info["images"] as? [[String: Any]] ?? [] {
            guard let path = image["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(root),
                  let dev = (image["system-entities"] as? [[String: Any]])?.compactMap({ $0["dev-entry"] as? String }).min(by: { $0.count < $1.count })
            else { continue }
            VolumeMount.detach(dev, force: true)
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
