// K48Board: the iPad 1 (k48ap, recipe "k48") side of Recipe.create. Ports ipad1_device.build's board steps,
// ipad1_keybag.py and ipad1_seal.py over the other modules; the build-time boots run through
// `LightTouchDevice --oneshot`.
//
// Boot files by strategy: `iboot` (default) iBoot.bin (pattern-patched), nor.bin (packed, writable) and
// gid-blobs.bin; `kboot` (debugging, recipe.boot) kboot.bin and, for 4.x data protection, a blank nor.bin.
// Volumes: SystemEdits.buildK48 (system + data, the shared bake). Store: K48NAND. The keybag one-shot (4.x)
// is retried from copies; the seal is one clean halt and a check boot on a throwaway overlay.

import CryptoKit
import Foundation

final class K48Board: Board {
    let arch = "armv7", seedPrefix = "ipad1"
    let volumesStep = "Building the system and data volumes", keybagStep = "Creating the data-protection keybag"
    var bootStep: String { iboot ? "Writing the identity and boot chain" : "Writing the identity and boot image" }
    let needsSeal = true
    let recipe: FirmwareEntry.Recipe, strategy: String, iboot: Bool, dataProtection: Bool
    var helper: URL!, patcher: URL!, mbr: URL!, vols: SystemEdits.Result!
    var gidComponents: [String] = [], ramdisk: String?
    var shipped: [String] { iboot ? ["iBoot.bin", "nor.bin", "gid-blobs.bin"] : ["kboot.bin"] + (dataProtection ? ["nor.bin"] : []) }
    var dieID: String { (ident.dieID ?? []).joined(separator: ":") }
    var ident: UnitIdentity!

    init(_ o: Preparer.Options) throws {
        recipe = o.entry.recipe!
        strategy = recipe.boot ?? "iboot"
        guard strategy == "iboot" || strategy == "kboot" else { throw FirmwareError(.unsupported, "\(o.entry.id): unknown boot strategy \(strategy)") }
        iboot = strategy == "iboot"
        dataProtection = recipe.options["writable_nor"] == true
    }

    func check(_ c: Recipe.Context) throws {
        guard recipe.storage == "16g", recipe.dataSize == "partition" else {
            throw FirmwareError(.unsupported, "\(c.e.id): storage \(recipe.storage), data_size \(recipe.dataSize)")
        }
        guard let helper = c.o.helper, FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw FirmwareError(.internal, "the seal boots need --helper (LightTouchDevice); got \(c.o.helper?.path ?? "none")")
        }
        self.helper = helper
        patcher = K48IBoot.patcher(helper: helper)
    }

    func identity(seed: String) throws -> UnitIdentity {
        ident = try UnitIdentity.synthesize(seed: seed, storage: recipe.storage)
        return ident
    }

    /// iboot: iBoot.bin, nor.bin, gid-blobs.bin; kboot: kboot.bin.
    func bootFiles(_ c: Recipe.Context) throws {
        let e = c.e, ipsw = c.ipsw, bootArgs = KBoot.defaultBootArgs
        try FitCheck.checkBootArgs(c.fit, kernel: try Data(contentsOf: c.decFile("kernelcache.mach"), options: .alwaysMapped), args: bootArgs)
        if iboot {
            // The real iBoot chain: catalog GID records, a re-encrypted hsic-enabled DeviceTree, the pattern-patched
            // iBoot, and the packed NOR (ipad1_device build's "iBoot + NOR" step; ipad1_gid + ipad1_iboot).
            let (blobs, names) = try K48IBoot.gidBlobs(ipsw, entry: e)
            gidComponents = names
            try blobs.write(to: c.file("gid-blobs.bin"))
            let prefix = "Firmware/all_flash/all_flash.\(e.board).production/"
            var allFlash: [String: Data] = [:]
            for m in try ipsw.names() where m.hasPrefix(prefix) && m.hasSuffix(".img3") {
                let d = try ipsw.read(m), t = try N72NOR.type(of: d)
                guard allFlash[t] == nil else { throw FirmwareError(.unsupported, "duplicate img3 type \(t) in all_flash") }
                allFlash[t] = d
            }
            guard let dtImg3 = allFlash["dtre"] else { throw FirmwareError(.unsupported, "\(e.id): all_flash has no DeviceTree") }
            allFlash["dtre"] = try K48IBoot.hostUSBDeviceTree(img3: dtImg3, plaintext: try Data(contentsOf: c.decFile("DeviceTree.bin")), gidBlobs: blobs)
            let manifest = String(decoding: try ipsw.read(prefix + "manifest"), as: UTF8.self).split(whereSeparator: \.isWhitespace)
            let order = try manifest.map { try N72NOR.type(of: ipsw.read(prefix + String($0))) }
            let patched = try K48IBoot.patchIBoot(try Data(contentsOf: c.decFile("iBoot.bin")), patcher: patcher, bootArgs: bootArgs, log: c.log)
            try patched.write(to: c.file("iBoot.bin"))
            try K48IBoot.buildNOR(identity: ident, allFlash: allFlash, order: order, bootArgs: bootArgs).write(to: c.file("nor.bin"))
        } else {
            try KBoot.write(decrypted: c.dec, to: c.file("kboot.bin"), identity: ident, bootArgs: bootArgs)
        }
    }

    /// MBR, system + data volumes (+ activation); the iBoot fsboot kernelcache goes in the system volume.
    func volumes(_ c: Recipe.Context) throws {
        mbr = c.work.appendingPathComponent("mbr.bin")
        try K48NAND.makeMBR(geometry: .k48_16g, systemMiB: recipe.systemMiB).write(to: mbr)
        let parts = K48NAND.partitions(mbr: [UInt8](try Data(contentsOf: mbr)))
        var kernelcacheImg3: Data?
        if iboot {
            guard let kc = try BuildComponents.load(c.ipsw)["KernelCache"] else { throw FirmwareError(.unsupported, "\(c.e.id): the IPSW names no KernelCache") }
            kernelcacheImg3 = try c.ipsw.read(kc)
        }
        vols = try SystemEdits.buildK48(rootfs: c.decFile("rootfs.dmg"), work: c.work, systemBytes: parts[0].count * 4096,
                                        dataBytes: Int64(parts[1].count) * 4096, options: .init(recipe: recipe),
                                        helpers: c.o.guestTools, kernelcache: kernelcacheImg3,
                                        kernel: try Data(contentsOf: c.decFile("kernelcache.mach"), options: .alwaysMapped),
                                        dataVolumeUUID: Array(SHA256.hash(data: Data("k48 data volume \(c.seed)".utf8)).prefix(8)), fit: c.fit, log: c.log)
        for n in vols.notes { c.emit(.warning(n)) }
        c.activation = vols.activation; c.guestPackage = vols.guestPackage; c.engine = vols.engine
    }

    func store(_ c: Recipe.Context) throws {
        let epoch = try K48NAND.signatureEpoch(kernelcache: c.decFile("kernelcache.mach"))
        c.log("NAND signature epoch \(epoch) (this kernel's FIL)")
        try K48NAND.build(geometry: .k48_16g, mbr: mbr, kernelVersion: K48NAND.kernelVersion(kernelcache: c.decFile("kernelcache.mach")),
                          epoch: epoch, system: vols.system, data: .image(vols.data), out: c.nand, log: c.log)
        try? FileManager.default.removeItem(at: vols.system); try? FileManager.default.removeItem(at: vols.data)
    }

    func norURL(_ c: Recipe.Context) -> URL? { iboot || dataProtection ? c.file("nor.bin") : nil }

    /// 4.x data protection: effaceable + system keybag from the IPSW's own Update ramdisk (ipad1_keybag): the
    /// ramdisk with it_keybag as restored_external, booted once as md0 on the store + NOR; retried (from copies
    /// taken before the first) when it panics or does not halt.
    func keybag(_ c: Recipe.Context) throws {
        let fm = FileManager.default, nor = norURL(c)!
        if !iboot { try Data(repeating: 0xFF, count: 1 << 20).write(to: nor) }   // iboot already built the packed NOR
        let (source, name) = try Recipe.keybagRamdisk(c)
        ramdisk = name
        let work = c.work, store = c.nand
        let rd = try Preparer.ramdiskWithHelper(source, helper: c.o.guestTools.appendingPathComponent(SystemEdits.Helpers.name("it_keybag", arch)), work: work)
        let kboot = work.appendingPathComponent("kboot-restore.bin")
        try KBoot.write(decrypted: c.dec, to: kboot, identity: ident, ramdisk: rd)
        let norBefore = try Data(contentsOf: nor)
        let pre = work.appendingPathComponent("store.pre")
        try fm.copyItem(at: store, to: pre)   // ponytail: clonefile on APFS; a non-APFS staging volume copies in full
        let attempts = 3
        for attempt in 1...attempts {
            let serial = work.appendingPathComponent("keybag-\(attempt).log")
            let (r, text) = try Preparer.oneshot(helper, boot: "kboot=\(Preparer.esc(kboot))", machine: "nand=\(Preparer.esc(store)),nor-rw=\(Preparer.esc(nor)),die-id=\(dieID)",
                                                 serial: serial, stop: "panic(", timeout: 300, work: work, log: c.log)
            for line in text.split(separator: "\n") where line.contains("it_keybag:") { c.log(String(line)) }
            if r.exited, text.contains(Preparer.keybagDone) { break }
            let why = text.split(separator: "\n").first { $0.contains("panic(") }
                .map { String($0[$0.range(of: "panic(")!.lowerBound...].prefix(160)) } ?? (r.exited ? "halted without the keybag" : "no halt")
            guard attempt < attempts else { throw FirmwareError(.oneshotFailed, "keybag boot: \(why)") }
            c.emit(.warning("keybag boot attempt \(attempt)/\(attempts) failed after \(Int(r.seconds)) s: \(why); retrying"))
            try fm.removeItem(at: store)
            try fm.copyItem(at: pre, to: store)
            try norBefore.write(to: nor)
        }
        guard try Data(contentsOf: nor) != norBefore else { throw FirmwareError(.oneshotFailed, "keybag boot: effaceable was not written to the NOR") }
        for u in [pre, rd, kboot] { try? fm.removeItem(at: u) }
    }

    /// ipad1_seal: boot the store until the guest halts (it_seal), then check a boot on an overlay opens the FTL
    /// without the full R/O restore.
    func seal(_ c: Recipe.Context) throws {
        let work = c.work, store = c.nand, nor = norURL(c)
        let boot: String, extra: String
        if iboot {
            // ipad1_seal.py --iboot: enter the patched iBoot with the catalog keys; the writable NOR is where this
            // boot's effaceable/NVRAM writes land (no base nor=). die-id must be non-zero or iBoot rejects it.
            boot = "iboot=\(Preparer.esc(c.file("iBoot.bin"))),gid-blobs=\(Preparer.esc(c.file("gid-blobs.bin")))"
            extra = ",die-id=\(dieID),nor-rw=\(Preparer.esc(nor!))"
        } else {
            boot = "kboot=\(Preparer.esc(c.file("kboot.bin")))"
            extra = ",die-id=\(dieID)" + (nor.map { ",nor-rw=\(Preparer.esc($0))" } ?? "")
        }
        let serial = work.appendingPathComponent("seal.log")
        let (r, text) = try Preparer.oneshot(helper, boot: boot, machine: "nand=\(Preparer.esc(store))" + extra, serial: serial, stop: nil,
                                             timeout: 300, work: work, log: c.log)
        guard r.exited, text.contains(Preparer.halting) else {
            throw FirmwareError(.oneshotFailed, "seal boot: \(r.exited ? "QEMU exited without it_seal" : "no clean halt") after \(Int(r.seconds)) s")
        }
        let overlay = work.appendingPathComponent("seal-overlay")
        try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
        let (ck, check) = try Preparer.oneshot(helper, boot: boot, machine: "nand=\(Preparer.esc(store)),nand-overlay=\(Preparer.esc(overlay))" + extra,
                                               serial: work.appendingPathComponent("check.log"), stop: nil, stopPattern: Preparer.ftlOpen, timeout: 120,
                                               work: work, log: c.log)
        guard ck.marker, Preparer.ftlOpened(check), !check.contains(Preparer.rescan) else {
            throw FirmwareError(.oneshotFailed, "check boot: \(check.contains(Preparer.rescan) ? "the store still rescans" : "no FTL_Open")")
        }
        try? FileManager.default.removeItem(at: overlay)
        c.log(check.split(separator: "\n").first { $0.contains("FTL_Open") }.map(String.init) ?? "FTL_Open [OK]")
    }

    func lock(_ c: Recipe.Context) throws -> [String: Any] {
        func opt(_ v: Any?) -> Any { v ?? NSNull() }
        var outputs: [String: Any] = ["nand": ["files": c.nandHashes]]
        if iboot {
            for (k, n) in [("iboot", "iBoot.bin"), ("gid_blobs", "gid-blobs.bin"), ("nor", "nor.bin")] { outputs[k] = try Recipe.fileRecord(c, n) }
        } else {
            outputs["kboot"] = try Recipe.fileRecord(c, "kboot.bin")
            outputs["nor"] = opt(dataProtection ? try Recipe.fileRecord(c, "nor.bin") : nil)
        }
        return [
            "boot_strategy": strategy,
            "gid_components": iboot ? gidComponents : NSNull(),
            "iboot_signature_checks": iboot ? "pattern-patched" : NSNull(),
            "tool": ["helper": helper.path, "helper_sha256": try Preparer.digest(helper, SHA256()),
                     "iboot32patcher": opt(iboot ? ["path": patcher.path, "sha256": try Preparer.digest(patcher, SHA256())] as [String: Any] : nil),
                     "built": ["GLEngine": opt(vols.engine)]],
            "inputs": ["kernelcache": "kernelcache.mach", "devicetree": "DeviceTree.bin", "restore_ramdisk": opt(ramdisk),
                       "mbr": ["sha256": try Preparer.digest(mbr, SHA256())], "stash": NSNull()],
            "identity": ["die_id": dieID],
            "outputs": outputs,
            "gl_test": false,
        ]
    }
}
