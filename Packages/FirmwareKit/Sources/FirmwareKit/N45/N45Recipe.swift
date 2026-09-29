// N45Board: the iPod touch 1G (n45ap, recipe "n45") side of Recipe.create, for iPhone OS 1.x.
//
// Boot files: iBoot.bin (the IPSW's iBoot-204 IMG2 payload, which the machine enters at 0x18000000) and nor.bin
// (N45NOR over the IPSW's all_flash IMG2s). The bootrom (bootrom_s5l8900) is a boot input, like the 2G's.
// Volume: the IPSW rootfs grown to the recipe, then the 1.x bake of devos50's qemu-ios-generate-nand
// docs/changes.md through SystemEdits: fstab rw with no /private/var line (one partition), the kernelcache (the
// IPSW's 8900 container, which the machine's 8900 engine decrypts) where iBoot loads it, SpringBoard's
// LK_ENABLE_MBX2D=0 (no MBX 2D on this machine), the six LaunchDaemons that changes.md keeps, and the
// /var/root/Library skeleton; the volume journaled (it is also /private/var); activation as every board has it;
// owners patched in the catalog. Store: N45NAND.
// No guest tools on 1.x yet, no keybag, no seal.
//
// The recipe: storage "8g" (MA623; the only NAND geometry modelled), system_mib = the volume.

import Foundation

final class N45Board: Board {
    static let models = ["8g": "MA623"]
    /// changes.md: every other job is removed (the rest wait on hardware this machine does not have).
    static let keptDaemons: Set = ["com.apple.AddressBook.plist", "com.apple.CommCenter.plist", "com.apple.configd.plist",
                                   "com.apple.mobile.lockdown.plist", "com.apple.notifyd.plist", "com.apple.SpringBoard.plist"]
    static let rootLibrary = "private/var/root/Library"

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
            try SystemEdits.editSpringBoardJob(m) { env, _ in env["LK_ENABLE_MBX2D"] = "0" }
            let removed = try fm.contentsOfDirectory(atPath: at(SystemEdits.daemons).path)
                .filter { $0.hasSuffix(".plist") && !Self.keptDaemons.contains($0) }.sorted()
            for n in removed { try fm.removeItem(at: at(SystemEdits.daemons + "/" + n)) }
            for d in ["", "/AddressBook", "/Lockdown", "/Preferences"] {
                try SystemEdits.mkdirs(at(Self.rootLibrary + d))
                owners.append((0, Self.rootLibrary + d))
            }
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
