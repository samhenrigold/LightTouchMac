// N45Board: the iPod touch 1G (n45ap, recipe "n45") side of Recipe.create, for iPhone OS 1.x.
//
// Boot files: iBoot.bin (the IPSW's iBoot-204 IMG2 payload, which the machine enters at 0x18000000) and nor.bin
// (N45NOR over the IPSW's all_flash IMG2s). The bootrom (bootrom_s5l8900) is a boot input, like the 2G's.
// Volume: the IPSW rootfs grown to the recipe, then the 1.x bake of devos50's qemu-ios-generate-nand
// docs/changes.md through SystemEdits: fstab rw with no /private/var line (one partition), the kernelcache (the
// IPSW's 8900 container, which the machine's 8900 engine decrypts) where iBoot loads it, SpringBoard's
// LK_ENABLE_MBX2D=0 (no MBX 2D on this machine), the six LaunchDaemons that changes.md keeps, and the
// /var/root/Library skeleton; then ipod1g_device.bake: when the stock OpenGLES exports exactly
// opengles-1x.exports (a guest helper), the seed package's n45-ios1 hook (OpenGLES-1x, the GL front end) replaces it
// (the stock binary kept as OpenGLES.baked) and SpringBoard gets LK_ENABLE_OGL=1 LK_AUTO_ENABLE_OGL=0 (else
// LK_ENABLE_OGL stays unset: software LayerKit); the loader and the seed package go in either way, as on every board
// (the legacy-linked it_boot runs under 1.x launchd); an itpack without the hook is refused. The volume journaled (it
// is also /private/var); activation as every board has it; owners patched in the catalog. Store: N45NAND.
// No other guest tools on 1.x, no keybag, no seal.
//
// The recipe: storage "8g" (MA623; the only NAND geometry modelled), system_mib = the volume.

import Foundation

final class N45Board: Board {
    static let models = ["8g": "MA623"]
    /// changes.md: every other job is removed (the rest wait on hardware this machine does not have).
    static let keptDaemons: Set = ["com.apple.AddressBook.plist", "com.apple.CommCenter.plist", "com.apple.configd.plist",
                                   "com.apple.mobile.lockdown.plist", "com.apple.notifyd.plist", "com.apple.SpringBoard.plist"]
    static let rootLibrary = "private/var/root/Library"
    static let openGLESExports = "opengles-1x.exports"

    let arch = "armv6", seedPrefix = "ipod1g"
    let bootStep = "Writing the identity, NOR and boot files", volumesStep = "Building the system volume", keybagStep = ""
    let dataProtection = false, needsSeal = false
    let shipped = ["nor.bin", "iBoot.bin"]
    let recipe: FirmwareEntry.Recipe, model: String, bytes: Int
    var ident: UnitIdentity!, volume: URL!
    var kcPath = "", kcMember = "", prefix = ""
    var derived: [String: Any] = [:]

    init(_ o: Preparer.Options) throws {
        guard let recipe = o.entry.recipe, let model = Self.models[recipe.storage] else {
            throw FirmwareError(.unsupported, "\(o.entry.id): no n45 recipe for storage \(o.entry.recipe?.storage ?? "none")")
        }
        self.recipe = recipe; self.model = model
        bytes = recipe.systemMiB << 20
    }

    func check(_ c: Recipe.Context) throws {}

    func identity(seed: String) throws -> UnitIdentity {
        ident = try UnitIdentity.synthesizeIPod(seed: seed, modelNumber: model, regionInfo: UnitIdentity.iPadRegion)
        return ident
    }

    func bootFiles(_ c: Recipe.Context) throws {
        let ipsw = c.ipsw
        let iboot = try Data(contentsOf: c.decFile("iBoot.bin"))
        kcPath = try N72Board.kernelcachePath(iboot)
        guard let kc = try BuildComponents.load(ipsw)["KernelCache"] else { throw FirmwareError(.unsupported, "\(c.e.id): the IPSW names no KernelCache") }
        kcMember = kc
        prefix = "Firmware/all_flash/all_flash.\(c.e.board).production/"
        var images: [String: Data] = [:]
        for n in try ipsw.names() where n.hasPrefix(prefix) && n.hasSuffix(".img2") {
            let body = try Apple8900.body(ipsw.read(n))
            images[try IMG2.Header(body).type] = body
        }
        try N45NOR.build(identity: ident, images: images).write(to: c.file("nor.bin"))
        try iboot.write(to: c.file("iBoot.bin"))
        derived = ["kernelcache_path": kcPath, "kernelcache_member": kcMember, "nor_images": N45NOR.order, "boot_args": N45NOR.bootArgs,
                   "kernel": N72Board.firstMatch(try Data(contentsOf: c.decFile("kernelcache.mach")), /Darwin Kernel Version [^\x00]+/) ?? NSNull(),
                   "iboot": N72Board.firstMatch(iboot, /iBoot-[0-9.]+/) ?? "?"]
    }

    func volumes(_ c: Recipe.Context) throws {
        volume = c.work.appendingPathComponent("volume.img")
        try UDIF.extractRootfs(dmg: c.decFile("rootfs.dmg"), to: volume)
        try VolumeMount.grow(volume, toBytes: bytes)
        // Modern HFS checks reject the stock 1.x catalog's legacy folder counts.
        // Normalize the private working volume before mounting/editing it, then verify it.
        let device = try VolumeMount.attach(volume)
        do {
            defer { VolumeMount.detach(device) }
            c.log(try VolumeMount.run("/sbin/fsck_hfs", ["-fy", device]))
            let check = VolumeMount.check(device)
            guard check.ok else { throw FirmwareError(.internal, "1.x root filesystem repair failed: \(check.output)") }
        }
        let newest: UInt32
        do {
            let v = try HFSPlusVolume(volume)
            c.log("\(v.signature) blocksize=\(v.blockSize) total=\(v.totalBlocks) free=\(v.freeBlocks) files=\(v.fileCount) dirs=\(v.folderCount)")
            guard Int(v.totalBlocks) * Int(v.blockSize) == bytes else { throw FirmwareError(.internal, "resize produced \(v.totalBlocks) x \(v.blockSize) B, wanted \(bytes) B") }
            newest = try v.newestDate()
        }
        var owners: [(UInt32, String)] = [(0, kcPath), (0, SystemEdits.lockdownd)]
        let (activation, removed) = try VolumeMount.withMounted(volume, at: c.work.appendingPathComponent("mnt")) { m -> (Activation.Result, [String]) in
            let fm = FileManager.default, at = { (rel: String) in m.appendingPathComponent(rel) }
            try SystemEdits.put(Data(N72Board.fstabRW.utf8), at(SystemEdits.fstab))
            try SystemEdits.mkdirs(at(kcPath).deletingLastPathComponent())
            try c.ipsw.extract(kcMember, to: at(kcPath))
            let removed = try fm.contentsOfDirectory(atPath: at(SystemEdits.daemons).path)
                .filter { $0.hasSuffix(".plist") && !Self.keptDaemons.contains($0) }.sorted()
            for n in removed { try fm.removeItem(at: at(SystemEdits.daemons + "/" + n)) }
            for d in ["", "/AddressBook", "/Lockdown", "/Preferences"] {
                try SystemEdits.mkdirs(at(Self.rootLibrary + d))
                owners.append((0, Self.rootLibrary + d))
            }
            // An iPod's first iTunes handshake clears BrickState independently of activation.
            // The 1G has no host USB transport yet. Seed the same persistent boolean on its fresh
            // data volume; lockdownd owns the rest of this dictionary and preserves it on reboot.
            let ark = Self.rootLibrary + "/Lockdown/data_ark.plist"
            try SystemEdits.put(try PropertyListSerialization.data(fromPropertyList: ["-BrickState": false], format: .xml, options: 0), at(ark), mode: 0o600)
            owners.append((0, ark))
            let (report, record, owned) = try Self.bake(m, helpers: c.o.guestTools, gles: recipe.options["gles_shim"] ?? true, log: c.log)
            for (k, v) in report { derived[k] = v }
            c.guestPackage = record
            owners += owned.map { (0, $0) }
            // One partition, so the root holds what a device keeps in its journaled /private/var: journaled, so a
            // hard power-off is replayed at mount (the stock root is unjournaled and 1.x runs no fsck or update);
            // the journal itself is left for the device's first mount to initialize (leaveJournalToDevice).
            try VolumeMount.run("/usr/sbin/diskutil", ["enableJournal", m.path])
            return (try SystemEdits.activate(m, log: c.log), removed)
        }
        c.activation = activation
        derived["launch_daemons_removed"] = removed
        let hfs = try HFSPlusVolume(volume, writable: true)
        try hfs.leaveJournalToDevice()
        c.log("0:0 patched \(try hfs.setOwner(owners.map(\.1), uid: 0, gid: 0)) catalog record(s)")
        c.log("\(try hfs.normalize(after: newest, to: newest)) catalog records dated as of the IPSW's newest file")
    }

    /// ipod1g_device.bake over the mounted 1.x volume `m`: the GL front end if the stock OpenGLES exports exactly
    /// opengles-1x.exports (and `gles`), the seed package (GuestPackage.seed of armv6.itpack: the loader and n45-ios1),
    /// SpringBoard's LK_* environment. Returns (the lock's derived gles/gles_engine, the guest_package record, the
    /// volume-relative paths to make root-owned).
    static func bake(_ m: URL, helpers: URL, gles: Bool, log: (String) -> Void) throws -> ([String: Any], GuestPackage.Record, [String]) {
        var front = false, report: [String: Any] = [:]
        if gles {
            let (ok, line) = try N72Board.frontEnd(m.appendingPathComponent(N72Board.openGLES), exports: helpers.appendingPathComponent(openGLESExports))
            front = ok
            report["gles"] = line + (ok ? "; LayerKit composites through it (LK_ENABLE_OGL=1)" : "; software LayerKit")
        } else {
            report["gles"] = "gles off; software LayerKit"
        }
        let (seeded, record) = try SystemEdits.seedGuestPackage(m, helpers: helpers, arch: "armv6", gles: front, log: log)
        if front, !record.hooks.contains("/" + N72Board.openGLES) {
            // LK_ENABLE_OGL=1 over the stock IMG driver drives the unemulated MBX: fail rather than wedge
            throw FirmwareError(.internal, "\(SystemEdits.Helpers.itpack("armv6")) has no OpenGLES hook for this build; rebuild the guest package")
        }
        try SystemEdits.editSpringBoardJob(m) { env, _ in
            if front { env["LK_ENABLE_OGL"] = "1"; env["LK_AUTO_ENABLE_OGL"] = "0" } else { env.removeObjects(forKeys: ["LK_ENABLE_OGL", "LK_AUTO_ENABLE_OGL"]) }
            env["LK_ENABLE_MBX2D"] = "0"   // never the unemulated MBX 2D path
        }
        report["gles_engine"] = front ? "OpenGLES" : NSNull()
        log("bake: \(report)")
        return (report, record, [SystemEdits.springBoardJob] + seeded)
    }

    func store(_ c: Recipe.Context) throws {
        let (written, meta) = try N45NAND.write(volume: volume, out: c.nand)
        c.log("\(written) filesystem pages, \(meta) metadata pages generated")
        try FileManager.default.removeItem(at: volume)
    }

    func lock(_ c: Recipe.Context) throws -> [String: Any] {
        [
            "inputs": ["kernelcache": kcMember, "iboot": prefix + "iBoot.\(c.e.board).RELEASE.img2", "all_flash": prefix],
            "outputs": ["nand": ["pages": c.nandHashes.count], "nor": try Recipe.fileRecord(c, "nor.bin"), "iboot": try Recipe.fileRecord(c, "iBoot.bin")],
            "derived": derived,
        ]
    }
}
