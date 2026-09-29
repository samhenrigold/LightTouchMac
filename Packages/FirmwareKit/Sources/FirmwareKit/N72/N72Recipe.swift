// N72Board: the iPod touch 2G (n72ap, recipe "n72") side of Recipe.create. Ports ipod2g_device.build/bake +
// build_nand.py (--epoch) over the other modules.
//
// Boot files: nor.bin, iBoot.bin (3.x+: the machine's direct-iboot), gid-blobs.bin. Volume: the IPSW rootfs
// grown to the recipe, fstab, the kernelcache at the path iBoot names, the shared bake (SystemEdits) plus the
// iPod's own pieces (MBXGLEngine shim, sound defaults, guest-tools markers), owners patched in the catalog.
// Store: N72NAND's page directory. There is no seal boot: the legacy FTL store needs no clean halt.
// options.data_protection (4.x) adds the restore-ramdisk keybag one-shot (N72Keybag) through --helper.
//
// The recipe: storage "8g" (model MB528; 16g MB531, 32g MB533; region LL/A), system_mib = the volume
// (7168 MiB = 1835008 blocks), options gles_shim / appsync / web_proxy / data_protection, gli_dispatch
// optionally pins the shim's ABI table (else every gli-dispatch-<BUILD>.tsv with an MBXGLEngine-<BUILD> is
// tried, as ipod2g_device.gli_engine does). --guest-tools holds those MBXGLEngine-<BUILD> and TSVs, sblaunch,
// sbdlicon (optional), it_agent, it_typein.dylib, com.qemu.it-agent.plist, libappsync.dylib, armv6.itpack (the
// guest-package loader and seed package, as ipod2g_device.py bakes them), it_prefs-armv6 + com.qemu.it-prefs.plist
// (3.x+: no first-run "Edit Home Screen" tip) and it_keybag-armv6 (data protection).

import CryptoKit
import Foundation

final class N72Board: Board {
    static let models = ["8g": "MB528", "16g": "MB531", "32g": "MB533"]
    static let kcPrefix = "/System/Library/Caches/com.apple.kernelcaches/"
    static let mbx = "System/Library/Frameworks/OpenGLES.framework/MBXGLEngine.bundle/MBXGLEngine"
    static let prefs = "private/var/mobile/Library/Preferences"
    static let agentJob = "System/Library/LaunchDaemons/com.qemu.it-agent.plist"
    static let prefsJob = "System/Library/LaunchDaemons/com.qemu.it-prefs.plist"
    static let fstabRW = "/dev/disk0s1 / hfs rw 0 1\n"
    /// set-sound-defaults.py: the five Sounds switches of a new device.
    static var soundDefaults: [(String, [String: Any])] { [
        ("com.apple.mobilemail.plist", ["PlayNewMailSound": true, "PlaySentMailSound": true]),
        ("com.apple.springboard.plist", ["calendar-alarm": "/Applications/MobileCal.app/alarm.aiff", "lock-unlock": true]),
        ("com.apple.preferences.sounds.plist", ["keyboard": true])] }
    /// Paths the guest-tools bake creates (ipod2g_device.GUEST_TOOL_OWNERS), owner set in the catalog if present.
    static let guestToolOwners: [(UInt32, String)] = [
        (0, "usr/local"), (0, "usr/local/bin"), (0, "usr/local/bin/it_agent"), (0, "usr/local/bin/sblaunch"),
        (0, "usr/local/bin/sbdlicon"), (0, "usr/lib/it_typein.dylib"), (0, agentJob), (0, mbx + ".stock"),
        (501, prefs + "/com.apple.mobilemail.plist"), (501, prefs + "/com.apple.springboard.plist"),
        (501, prefs + "/com.apple.preferences.sounds.plist"), (501, "private/var/mobile/Media/.lt-guest-tools-v1"),
        (501, "private/var/mobile/Media/.lt-guest-tools-v2"), (501, "private/var/mobile/Media/.lt-guest-tools-v3")]

    /// The -machine options every device this recipe builds boots with (device.lock.json "machine").
    public static let machine = ["aes-uid": "engine"]

    let arch = "armv6", seedPrefix = "ipod2g"
    let bootStep = "Writing the identity, NOR and boot files", volumesStep = "Building the system volume", keybagStep = "Booting the restore ramdisk"
    let needsSeal = false
    let recipe: FirmwareEntry.Recipe, model: String, blocks: Int, dataProtection: Bool
    var helper: URL?, bootrom: URL?, ident: UnitIdentity!
    var epoch = 0, major = 0, kcPath = "", kcMember = "", prefix = ""
    var derived: [String: Any] = [:]
    var shipped: [String] { ["nor.bin", "gid-blobs.bin"] + (major >= 3 ? ["iBoot.bin"] : []) }
    var itKeybag: String { SystemEdits.Helpers.name("it_keybag", arch) }

    init(_ o: Preparer.Options) throws {
        guard let recipe = o.entry.recipe, let model = Self.models[recipe.storage] else {
            throw FirmwareError(.unsupported, "\(o.entry.id): no n72 recipe for storage \(o.entry.recipe?.storage ?? "none")")
        }
        self.recipe = recipe; self.model = model
        blocks = recipe.systemMiB * 256
        dataProtection = recipe.options["data_protection"] == true
    }

    func check(_ c: Recipe.Context) throws {
        let fm = FileManager.default
        helper = c.o.helper
        bootrom = Self.bootromPath(helper: helper)
        if dataProtection {
            guard let helper, fm.isExecutableFile(atPath: helper.path) else {
                throw FirmwareError(.internal, "the keybag boot needs --helper (LightTouchDevice); got \(c.o.helper?.path ?? "none")")
            }
            guard bootrom != nil else { throw FirmwareError(.internal, "the keybag boot needs the iPod bootrom (bootrom_240_4) next to the helper") }
            guard fm.fileExists(atPath: c.o.guestTools.appendingPathComponent(itKeybag).path) else {
                throw FirmwareError(.internal, "guest helper \(itKeybag) missing from \(c.o.guestTools.path)")
            }
        }
    }

    /// Restore.plist: the NAND epoch (DeviceMap SCEP) and the iOS major.
    func inspect(_ c: Recipe.Context) throws {
        guard let rp = try PropertyListSerialization.propertyList(from: try c.ipsw.read("Restore.plist"), format: nil) as? [String: Any],
              let epoch = ((rp["DeviceMap"] as? [[String: Any]])?.first?["SCEP"] as? NSNumber)?.intValue,
              let major = Int(c.restore.productVersion.prefix { $0 != "." }) else {
            throw FirmwareError(.unsupported, "Restore.plist has no DeviceMap SCEP (NAND epoch)")
        }
        self.epoch = epoch; self.major = major
    }

    func identity(seed: String) throws -> UnitIdentity {
        ident = try UnitIdentity.synthesizeIPod(seed: seed, modelNumber: model, regionInfo: UnitIdentity.iPadRegion)
        return ident
    }

    /// nor.bin, gid-blobs.bin, iBoot.bin (3.x+), and the derived facts the lock records.
    func bootFiles(_ c: Recipe.Context) throws {
        let e = c.e, ipsw = c.ipsw
        let iboot = try Data(contentsOf: c.decFile("iBoot.bin"))
        kcPath = try Self.kernelcachePath(iboot)
        guard let kc = try BuildComponents.load(ipsw)["KernelCache"] else { throw FirmwareError(.unsupported, "\(e.id): the IPSW names no KernelCache") }
        kcMember = kc
        derived = ["nand_epoch": epoch, "wrap_shsh": major >= 3, "kernelcache_path": kcPath, "kernelcache_member": kcMember,
                   "kernel": Self.firstMatch(try Data(contentsOf: c.decFile("kernelcache.mach")), /Darwin Kernel Version [^\x00]+/) ?? NSNull(),
                   "iboot": Self.firstMatch(iboot, /iBoot-[0-9.]+/) ?? "?", "direct_iboot": major >= 3]
        prefix = "Firmware/all_flash/all_flash.\(e.board).production/"
        let img3Members = try ipsw.names().filter { $0.hasPrefix(prefix) && $0.hasSuffix(".img3") }
        var images: [String: Data] = [:]
        for n in img3Members {
            let d = try ipsw.read(n), t = try N72NOR.type(of: d)
            guard images[t] == nil else { throw FirmwareError(.unsupported, "duplicate img3 type \(t) in all_flash") }
            images[t] = d
        }
        let manifest = String(decoding: try ipsw.read(prefix + "manifest"), as: UTF8.self).split(whereSeparator: \.isWhitespace)
        let shipped = Set(try manifest.map { try N72NOR.type(of: ipsw.read(prefix + $0)) })
        let norTypes = N72NOR.order.filter(shipped.contains)
        derived["nor_images"] = norTypes
        derived["wrap_shsh_types"] = major >= 3 ? norTypes : ["ibot"]
        try N72NOR.build(identity: ident, images: images, types: norTypes, wrapTypes: major >= 3 ? nil : ["ibot"]).write(to: c.file("nor.bin"))
        let (blobs, blobNames) = try Self.gidBlobs(ipsw, members: img3Members + [kcMember], entry: e)
        derived["gid_blobs"] = blobNames
        try blobs.write(to: c.file("gid-blobs.bin"))
        if major >= 3 { try iboot.write(to: c.file("iBoot.bin")) }
    }

    var volume: URL!

    /// The system volume: IPSW rootfs grown to the recipe, fstab, kernelcache, the bake; owners and dates patched.
    func volumes(_ c: Recipe.Context) throws {
        volume = c.work.appendingPathComponent("volume.img")
        try UDIF.extractRootfs(dmg: c.decFile("rootfs.dmg"), to: volume)
        try VolumeMount.grow(volume, toBytes: blocks * 4096)
        let newest: UInt32   // the IPSW's newest file: everything the recipe writes gets dated as of it
        do {
            let v = try HFSPlusVolume(volume)
            c.log("\(v.signature) blocksize=\(v.blockSize) total=\(v.totalBlocks) free=\(v.freeBlocks) files=\(v.fileCount) dirs=\(v.folderCount)")
            guard v.totalBlocks == blocks, v.blockSize == 4096 else { throw FirmwareError(.internal, "resize produced \(v.totalBlocks) x \(v.blockSize) B blocks, wanted \(blocks) x 4096") }
            newest = try v.newestDate()
        }
        var owners: [(UInt32, String)] = [(0, kcPath)]
        let report = try VolumeMount.withMounted(volume, at: c.work.appendingPathComponent("mnt")) { m -> [String: Any] in
            try SystemEdits.put(Data(Self.fstabRW.utf8), m.appendingPathComponent(SystemEdits.fstab))
            let kc = m.appendingPathComponent(kcPath)
            try SystemEdits.mkdirs(kc.deletingLastPathComponent())
            try c.ipsw.extract(kcMember, to: kc)
            return try bake(m, c, owners: &owners)
        }
        c.activation = report["activation"] as? Activation.Result
        c.guestPackage = report["guest_package"] as? GuestPackage.Record
        for (k, v) in report where k != "guest_package" && k != "activation" { derived[k] = v }
        let hfs = try HFSPlusVolume(volume, writable: true)
        for uid in Set(owners.map(\.0)).sorted() {
            let n = try hfs.setOwner(owners.filter { $0.0 == uid }.map(\.1), uid: uid, gid: uid)
            c.log("\(uid):\(uid) patched \(n) catalog record(s)")
        }
        c.log("\(try hfs.normalize(after: newest, to: newest)) catalog records dated as of the IPSW's newest file")
    }

    func store(_ c: Recipe.Context) throws {
        let (written, meta) = try N72NAND.write(volume: volume, blocks: blocks, epoch: epoch, out: c.nand)
        c.log("\(written) filesystem pages, \(meta) metadata pages generated (epoch \(epoch))")
        try FileManager.default.removeItem(at: volume)
    }

    /// 4.x data protection: effaceable + system keybag from the IPSW's own Update ramdisk (a restore-only build such
    /// as 8A293 ships just the Restore one; restored_external runs first on either).
    func keybag(_ c: Recipe.Context) throws {
        let (source, name) = try Recipe.keybagRamdisk(c)
        _ = try N72Keybag.run(out: c.o.out, dec: c.dec, ramdisk: source,
                              itKeybag: c.o.guestTools.appendingPathComponent(itKeybag), bootrom: bootrom!, helper: helper!, work: c.work, log: c.log)
        derived["keybag_ramdisk"] = name
    }

    func lock(_ c: Recipe.Context) throws -> [String: Any] {
        [
            "inputs": ["kernelcache": kcMember, "iboot": "iBoot.bin", "all_flash": prefix],
            "outputs": ["nand": ["pages": c.nandHashes.count],
                        "nor": try Recipe.fileRecord(c, "nor.bin"), "iboot": major >= 3 ? try Recipe.fileRecord(c, "iBoot.bin") as Any : NSNull(),
                        "gid_blobs": try Recipe.fileRecord(c, "gid-blobs.bin")],
            "derived": derived,
            // machine options the device must boot with (ipod2g_device.py): every device built here uses the
            // engine UID path; adopted and shipping images keep the legacy default
            "machine": Self.machine,
        ]
    }

    /// The iPod bootrom the keybag boot's machine loads: LTM_FILES, then the app bundle's Resources/device next to
    /// the helper (Contents/MacOS), then the development assets.
    static func bootromPath(helper: URL?) -> URL? {
        let env = ProcessInfo.processInfo.environment["LTM_FILES"].map { URL(fileURLWithPath: $0) }
        let bundled = helper?.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("../Resources/device").standardizedFileURL
        let dev = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/qemu-ios-files")
        return [env, bundled, dev].compactMap { $0?.appendingPathComponent("bootrom_240_4") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func firstMatch(_ d: Data, _ r: Regex<Substring>) -> String? {
        String(decoding: d, as: UTF8.self).firstMatch(of: r).map { String($0.output) }   // ponytail: lossy decode, ASCII targets only
    }

    /// The volume path the decrypted iBoot loads the kernelcache from (its one kcPrefix string), without the "/".
    static func kernelcachePath(_ iboot: Data) throws -> String {
        let b = [UInt8](iboot), p = Array(kcPrefix.utf8)
        var hits = Set<String>(), i = 0
        while let r = b[i...].firstRange(of: p) {
            var j = r.upperBound
            while j < b.count, (0x21...0x7E).contains(b[j]) { j += 1 }
            if j > r.upperBound { hits.insert(String(decoding: b[r.lowerBound + 1..<j], as: UTF8.self)) }
            i = r.upperBound
        }
        guard hits.count == 1 else { throw FirmwareError(.unsupported, "iBoot names \(hits.count) kernelcache paths (\(hits.sorted())); expected exactly one") }
        return hits.first!
    }

    /// KBAG || IV-key for every img3 the entry has a 16+16-byte IV/key for (the emulated AES engine's GID table).
    static func gidBlobs(_ ipsw: IPSWArchive, members: [String], entry: FirmwareEntry) throws -> (Data, [String]) {
        var out = Data(), names: [String] = []
        for n in members {
            let name = (n as NSString).lastPathComponent
            guard let k = entry.keys.values.first(where: { $0.file == name }), let iv = k.iv.flatMap({ Data(hex: $0) }),
                  let key = Data(hex: k.key), iv.count + key.count == 32 else { continue }
            let d = try ipsw.read(n)
            guard let t = try IMG3.tags(d)["KBAG"], t.dataLength >= 40 else { continue }
            let b = [UInt8](d)
            guard le32(b, t.offset + 12) == 1, le32(b, t.offset + 16) == 128 else { continue }   // production, AES-128
            out += b[t.offset + 20..<t.offset + 52] + iv + key
            names.append(name)
        }
        return (out, names)
    }

    /// ipod2g_device.bake over the mounted volume `m` (bake-guest-tools.sh, patch-appsync-dylib.sh,
    /// install_web_proxy, activation) with the shared pieces of SystemEdits. Appends the owners to patch;
    /// returns the report (the lock's `derived`, plus activation and guest_package).
    func bake(_ m: URL, _ c: Recipe.Context, owners: inout [(UInt32, String)]) throws -> [String: Any] {
        let fm = FileManager.default, opt = recipe.options, helpers = c.o.guestTools, mbx = Self.mbx
        let cache = SystemEdits.dyldCache(arch)
        let at = { (rel: String) in m.appendingPathComponent(rel) }
        // The guest helpers (it_agent, it_typein DYLD_INSERTed into SpringBoard, sblaunch, it_prefs, the loader and
        // its seed package) are linked for the dyld that ships the shared cache (3.1+); 2.x's and 3.0's refuse
        // LC_DYLD_INFO_ONLY ("dyld: unknown required load command 0x80000022") and SpringBoard never comes up with
        // it_typein inserted (qemu-ios ipod2g_device.py 4074277e42). Detected from the volume, not the version: a
        // firmware without the cache gets a stock SpringBoard, no AppSync cache patch and no GL shim.
        let tools = fm.fileExists(atPath: at(cache).path)
        func helper(_ n: String) throws -> Data {
            let u = helpers.appendingPathComponent(n)
            guard fm.fileExists(atPath: u.path) else { throw FirmwareError(.internal, "guest helper \(n) missing from \(helpers.path)") }
            return try Data(contentsOf: u)
        }
        var report: [String: Any] = [:]
        // ipod2g_device.gli_engine: the MBXGLEngine-<BUILD> whose TSV is this firmware's dispatch table
        var gli: String?
        let problem: String? = try {
            guard opt["gles_shim"] ?? true else { return "options.gles_shim off" }
            guard fm.fileExists(atPath: at(cache).path) else { return "no dyld shared cache (2.x, 3.0)" }
            let tsvs = try recipe.gliDispatch.map { [helpers.appendingPathComponent($0)] } ?? fm.contentsOfDirectory(at: helpers, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.wholeMatch(of: /gli-dispatch-\w+\.tsv/) != nil && fm.fileExists(atPath: helpers.appendingPathComponent(engine($0)).path) }
            let (tsv, why) = try GLIDispatch.engine(cache: try Data(contentsOf: at(cache), options: .alwaysMapped), cachePath: at(cache).path, tsvs: tsvs)
            gli = tsv.map { String(engine($0).dropFirst("MBXGLEngine-".count)) }
            return tsv == nil ? why ?? "no dispatch tables" : nil
        }()
        report["gles"] = gli.map { "shim MBXGLEngine-" + $0 } ?? "stock engine, software CA: " + (problem ?? "")
        report["gli"] = gli.map { $0 as Any } ?? NSNull()
        report["guest_tools"] = tools ? "installed" : "omitted: current helpers require the iOS 3.1+ dyld (no shared cache)"

        // bake-guest-tools.sh
        if let gli {
            try SystemEdits.mkdirs(at(mbx).deletingLastPathComponent())
            let stock = at(mbx + ".stock")   // 4.x has no stock file to keep: its MBXGLEngine is in the shared cache
            if !fm.fileExists(atPath: stock.path), fm.fileExists(atPath: at(mbx).path) {
                try SystemEdits.put(Data(contentsOf: at(mbx)), stock, mode: try SystemEdits.permissions(at(mbx)) & ~0o022)
            }
            try SystemEdits.put(helper("MBXGLEngine-" + gli), at(mbx), mode: 0o755)
        }
        if tools {
            try SystemEdits.mkdirs(at("usr/local/bin"))
            try SystemEdits.put(helper("sblaunch"), at("usr/local/bin/sblaunch"), mode: 0o755)
            if fm.fileExists(atPath: helpers.appendingPathComponent("sbdlicon").path) {
                try SystemEdits.put(helper("sbdlicon"), at("usr/local/bin/sbdlicon"), mode: 0o755)
            }
            try SystemEdits.put(helper("it_agent"), at("usr/local/bin/it_agent"), mode: 0o755)
            try SystemEdits.put(helper("it_typein.dylib"), at("usr/lib/it_typein.dylib"), mode: 0o755)
        }
        try SystemEdits.editSpringBoardJob(m) { env, _ in
            for k in ["CA_ENABLE_OGL", "LK_ENABLE_OGL"] { env[k] = problem == nil ? "1" : "0" }
            for k in ["CA_AUTO_ENABLE_OGL", "LK_AUTO_ENABLE_OGL", "CA_ENABLE_MBX2D", "LK_ENABLE_MBX2D"] { env[k] = "0" }
            let old = (env["DYLD_INSERT_LIBRARIES"] as? String ?? "").split(separator: ":").map(String.init)
            let libs = old.filter { !["/usr/lib/it_kbd_agent.dylib", "/usr/lib/it_typein.dylib"].contains($0) } + (tools ? ["/usr/lib/it_typein.dylib"] : [])
            env["DYLD_INSERT_LIBRARIES"] = libs.isEmpty ? nil : libs.joined(separator: ":")
        }
        if tools { try SystemEdits.put(helper("com.qemu.it-agent.plist"), at(Self.agentJob), mode: 0o644) }
        try? fm.removeItem(at: at("System/Library/LaunchDaemons/com.qemu.it-pbd.plist"))
        let sbp = at(Self.prefs + "/com.apple.springboard.plist")
        if fm.fileExists(atPath: sbp.path),
           let d = try PropertyListSerialization.propertyList(from: Data(contentsOf: sbp), format: nil) as? [String: Any],
           d["SBDontLockEver"] != nil || d["SBDisableCABlanking"] != nil {
            try SystemEdits.rewritePlist(sbp) { $0.removeObjects(forKeys: ["SBDontLockEver", "SBDisableCABlanking"]) }
        }
        for (name, changes) in Self.soundDefaults {
            try SystemEdits.seedPlist(at(Self.prefs + "/" + name)) { $0.addEntries(from: changes) }
        }
        let media = at("private/var/mobile/Media")
        if tools {
            try SystemEdits.mkdirs(media)
            for v in 1...3 { try SystemEdits.put(Data("v\(v)\n".utf8), media.appendingPathComponent(".lt-guest-tools-v\(v)")) }
        } else {
            for rel in [Self.agentJob] + (1...3).map({ "private/var/mobile/Media/.lt-guest-tools-v\($0)" }) { try? fm.removeItem(at: at(rel)) }
        }

        if gli != nil {   // ipad1_rootfs.gli_uncache: 4.x caches MBXGLEngine, so dyld must prefer the file
            let status = try autoreleasepool { try SystemEdits.overrideCachedImage(m, image: mbx, cache: cache) }
            report["gles_cache"] = status
            if status.contains("overridden") { owners.append((0, SystemEdits.dyldOverride)) }
        }
        if opt["appsync"] == true {   // patch-appsync-dylib.sh
            let (line, job) = try SystemEdits.installAppSync(m, helper: helpers.appendingPathComponent(SystemEdits.Helpers.appsync), cache: cache, log: c.log)
            report["appsync"] = [line, "installd (\(job)) DYLD_INSERT_LIBRARIES += /\(SystemEdits.appsyncPath)"]
            owners.append((0, SystemEdits.appsyncPath))
        }
        if tools {   // ipod2g_device.PREFS: the iPad's it_prefs, SpringBoard tip only (contrib/it-prefs/build-ipod.sh)
            try SystemEdits.put(helper(SystemEdits.Helpers.name("it_prefs", arch)), at("usr/local/bin/it_prefs"), mode: 0o755)
            try SystemEdits.put(helper("com.qemu.it-prefs.plist"), at(Self.prefsJob), mode: 0o644)
            owners += [(0, "usr/local/bin/it_prefs"), (0, Self.prefsJob)]
            report["prefs"] = "it_prefs: SBDidShowReorderText at first boot"
        }
        if opt["web_proxy"] ?? true {   // install_web_proxy: the PAC, and the Wi-Fi service on the system volume's /private/var
            let sc = "private/var/preferences/SystemConfiguration"
            owners += try SystemEdits.installPAC(m, dirs: [sc]).map { (UInt32(0), $0) }
            try SystemEdits.seedPlist(at(sc + "/preferences.plist"), SystemEdits.wifiProxyPrefs)
            owners.append((0, sc + "/preferences.plist"))
            report["web_proxy"] = "PAC /\(SystemEdits.pacPath) on the en0 Wi-Fi service"
        }
        report["activation"] = try SystemEdits.activate(m, log: c.log)
        owners.append((0, SystemEdits.lockdownd))
        // mkpkg.seed: the loader and the seed package; it_boot loads the package's jobs (com.qemu.it-agent), so
        // the baked copies it provides are removed. Owners after it, for only what is left.
        if tools {
            let (seeded, record) = try SystemEdits.seedGuestPackage(m, helpers: helpers, arch: arch, gli: gli, log: c.log)
            report["guest_package"] = record
            owners += seeded.map { (UInt32(0), $0) }
        }
        owners += Self.guestToolOwners.filter { (try? fm.destinationOfSymbolicLink(atPath: at($0.1).path)) != nil || fm.fileExists(atPath: at($0.1).path) }
        c.log("bake: \(report.filter { $0.key != "activation" && $0.key != "guest_package" })")
        return report
    }
}

/// gli-dispatch-<BUILD>.tsv -> MBXGLEngine-<BUILD>
fileprivate func engine(_ tsv: URL) -> String {
    "MBXGLEngine-" + tsv.deletingPathExtension().lastPathComponent.dropFirst("gli-dispatch-".count)
}

fileprivate func le32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
