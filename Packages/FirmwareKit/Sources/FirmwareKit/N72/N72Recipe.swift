// N72Board: the iPod touch 2G (n72ap, recipe "n72") side of Recipe.create. Ports ipod2g_device.build/bake +
// build_nand.py (--epoch) over the other modules.
//
// Boot files: nor.bin, iBoot.bin (3.x+: the machine's direct-iboot), gid-blobs.bin. Volume: the IPSW rootfs
// grown to the recipe, fstab, the kernelcache at the path iBoot names, the shared bake (SystemEdits) plus the
// iPod's own pieces (sound defaults, guest-tools markers), owners patched in the catalog.
// Store: N72NAND's page directory. There is no seal boot: the legacy FTL store needs no clean halt.
// options.data_protection (4.x) adds the restore-ramdisk keybag one-shot (N72Keybag) through --helper.
//
// The recipe: storage "8g" (model MB528; 16g MB531, 32g MB533; region LL/A), system_mib = the volume
// (7168 MiB = 1835008 blocks), options gles_shim / appsync / web_proxy / data_protection. --guest-tools
// holds OpenGLES (the GL front end, qemu-ios contrib/gles-public: every build, 2.x to 4.x) and gles-names.h, sblaunch,
// sbdlicon (optional), it_agent, it_typein.dylib, com.qemu.it-agent.plist, libappsync.dylib, armv6.itpack (the
// guest-package loader and seed package, as ipod2g_device.py bakes them), it_prefs-armv6 + com.qemu.it-prefs.plist
// (3.1+: no first-run "Edit Home Screen" tip; 2.x/3.0 get its SBDidShowReorderText baked instead) and it_keybag-armv6
// (data protection). With gles_shim the front end replaces OpenGLES once FitCheck.glesFrontEnd fits (else the prepare
// fails) and SpringBoard gets CA_ENABLE_OGL=1.

import CryptoKit
import Foundation

final class N72Board: Board {
    static let models = ["8g": "MB528", "16g": "MB531", "32g": "MB533"]
    static let kcPrefix = "/System/Library/Caches/com.apple.kernelcaches/"
    static let mbx = "System/Library/Frameworks/OpenGLES.framework/MBXGLEngine.bundle/MBXGLEngine"
    static let openGLES = "System/Library/Frameworks/OpenGLES.framework/OpenGLES"
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
        // the machine boots every n72 device with the AMFI pair (qemu-ios ipod_touch_2g.c; N72Keybag.bootArgs)
        let kernel = try Data(contentsOf: c.decFile("kernelcache.mach"), options: .alwaysMapped)
        try FitCheck.checkBootArgs(c.fit, kernel: kernel, args: FitCheck.amfiArgs.sorted().map { $0 + "=1" }.joined(separator: " "))
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
        // Whose SHSH is wrapped under the emulated UID, as a restore leaves the NOR: 3.x+ every image (the machine
        // enters iBoot directly). 2.x boots SecureROM -> LLB -> iBoot, and the SecureROM verifies the LLB raw; past
        // it, the epoch-1 chain (iBoot-385.22, 2.1.1) unwraps only iBoot (its LLB does) and verifies the rest raw,
        // while the epoch-2 chain (385.49, 2.2/2.2.1) unwraps every image it loads ("load_macho_image: failed to
        // load device tree" with a raw DeviceTree). The epoch is Restore.plist SCEP, as for the NAND.
        let wrap = major >= 3 ? norTypes : epoch >= 2 ? norTypes.filter { $0 != "illb" } : ["ibot"]
        derived["wrap_shsh_types"] = wrap
        try N72NOR.build(identity: ident, images: images, types: norTypes, wrapTypes: major >= 3 ? nil : wrap).write(to: c.file("nor.bin"))
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
            // 3.x+ enters its decrypted iBoot directly (the bootrom rejects a personalised LLB); 2.x runs the real
            // bootrom -> NOR LLB -> iBoot chain and ships no iBoot.bin (ipod2g_device.py direct_iboot)
            "boot_strategy": major >= 3 ? "iboot" : "bootrom",
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
        let fm = FileManager.default, opt = recipe.options, helpers = c.o.guestTools
        let cache = SystemEdits.dyldCache(arch)
        let at = { (rel: String) in m.appendingPathComponent(rel) }
        // The guest helpers (it_agent, it_typein DYLD_INSERTed into SpringBoard, sblaunch, it_prefs, the loader and
        // its seed package) are linked for the dyld that ships the shared cache (3.1+); 2.x's and 3.0's refuse
        // LC_DYLD_INFO_ONLY ("dyld: unknown required load command 0x80000022") and SpringBoard never comes up with
        // it_typein inserted (qemu-ios ipod2g_device.py 4074277e42). Proven from the volume (guestToolsFit), not
        // assumed from the version or the cache: where they do not load they are left out with a warning.
        func helper(_ n: String) throws -> Data {
            let u = helpers.appendingPathComponent(n)
            guard fm.fileExists(atPath: u.path) else { throw FirmwareError(.internal, "guest helper \(n) missing from \(helpers.path)") }
            return try Data(contentsOf: u)
        }
        let fw = FitCheck.Firmware(root: m, arch: arch)
        let toolsFit = try Self.guestToolsFit(fw, helpers: helpers)
        let tools = try c.fit.check(toolsFit, required: false)
        if opt["appsync"] == true { try FitCheck.checkAppSync(c.fit, fw, helpers: helpers) } else { c.fit.notInstalled("AppSync", "appsync off") }
        // the reorder tip's key: set by it_prefs at boot (tools) or baked below; either way only if SpringBoard reads it
        try c.fit.check(FitCheck.prefs(fw, [FitCheck.itPrefs[0]])[0], required: false, outcome: tools ? "kept: it_prefs skips the key at boot" : "not baked")
        // the GL front end (qemu-ios contrib/gles-public): one OpenGLES.framework/OpenGLES for every build, 2.x's EGL
        // compositor and 3.x/4.x's EAGL one alike, once FitCheck.glesFrontEnd proves this firmware has what it looks up
        var report: [String: Any] = [:]
        var gles = false
        if opt["gles_shim"] ?? true {
            let (engine, owned) = try SystemEdits.installCAOGL(m, helpers: helpers, arch: arch, fw: fw, fit: c.fit, log: c.log)
            gles = true
            owners += owned.map { (UInt32(0), $0) }
            report["gles"] = "GL front end \(engine) as OpenGLES; CoreAnimation composites through it (CA_ENABLE_OGL=1)"
        } else {
            report["gles"] = "stock OpenGLES, software CA: options.gles_shim off"
        }
        report["gles_shim"] = gles
        report["gles_engine"] = gles ? SystemEdits.Helpers.openGLES : NSNull() as Any
        report["guest_tools"] = tools ? "installed" : "omitted: " + toolsFit.proof

        // bake-guest-tools.sh
        if tools {
            try SystemEdits.mkdirs(at("usr/local/bin"))
            try SystemEdits.put(helper("sblaunch"), at("usr/local/bin/sblaunch"), mode: 0o755)
            if fm.fileExists(atPath: helpers.appendingPathComponent("sbdlicon").path) {
                try SystemEdits.put(helper("sbdlicon"), at("usr/local/bin/sbdlicon"), mode: 0o755)
            }
            try SystemEdits.put(helper("it_agent"), at("usr/local/bin/it_agent"), mode: 0o755)
            try SystemEdits.put(helper("it_typein.dylib"), at("usr/lib/it_typein.dylib"), mode: 0o755)
        }
        try c.fit.check(FitCheck.environment(fw, Self.sbSwitches),
                        required: false, outcome: "kept: a switch nothing reads is inert")
        try SystemEdits.editSpringBoardJob(m) { env, _ in
            for k in ["CA_ENABLE_OGL", "LK_ENABLE_OGL"] { env[k] = gles ? "1" : "0" }
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

        if opt["appsync"] == true {   // patch-appsync-dylib.sh
            let (line, job) = try SystemEdits.installAppSync(m, helper: helpers.appendingPathComponent(SystemEdits.Helpers.appsync), cache: cache, log: c.log)
            report["appsync"] = [line, "installation service (\(job)) DYLD_INSERT_LIBRARIES += /\(SystemEdits.appsyncPath)"]
            owners.append((0, SystemEdits.appsyncPath))
            if FileManager.default.fileExists(atPath: m.appendingPathComponent(SystemEdits.appsyncLauncherPath).path) { owners.append((0, SystemEdits.appsyncLauncherPath)) }
        }
        if tools {   // ipod2g_device.PREFS: the iPad's it_prefs, SpringBoard tip only (contrib/it-prefs/build-ipod.sh)
            try SystemEdits.put(helper(SystemEdits.Helpers.name("it_prefs", arch)), at("usr/local/bin/it_prefs"), mode: 0o755)
            try SystemEdits.put(helper("com.qemu.it-prefs.plist"), at(Self.prefsJob), mode: 0o644)
            owners += [(0, "usr/local/bin/it_prefs"), (0, Self.prefsJob)]
            report["prefs"] = "it_prefs: SBDidShowReorderText at first boot"
        } else {   // 2.x/3.0 get no helpers: the key it_prefs sets, baked into mobile's SpringBoard preferences
            report["prefs"] = try Self.bakeReorderTip(m)
        }
        if opt["web_proxy"] ?? true {   // install_web_proxy: the PAC, and the Wi-Fi service on the system volume's /private/var
            try c.fit.check(FitCheck.webProxy(fw), required: false, outcome: "kept: the PAC is unused")
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
        // On 2.x and 3.0 the package carries only the GL front end's hook.
        if tools || gles {
            let (seeded, record) = try SystemEdits.seedGuestPackage(m, helpers: helpers, arch: arch, gles: gles,
                                                                     omitted: opt["appsync"] == true ? [] : ["/" + SystemEdits.appsyncPath], fit: c.fit, log: c.log)
            report["guest_package"] = record
            owners += seeded.map { (UInt32(0), $0) }
        }
        owners += Self.guestToolOwners.filter { (try? fm.destinationOfSymbolicLink(atPath: at($0.1).path)) != nil || fm.fileExists(atPath: at($0.1).path) }
        c.log("bake: \(report.filter { $0.key != "activation" && $0.key != "guest_package" })")
        return report
    }
}

extension N72Board {
    /// The switches the bake sets in SpringBoard's job, each under its 3.x+ (CoreAnimation) and 1.x/2.x (LayerKit) name.
    static let sbSwitches = [["CA_ENABLE_OGL", "LK_ENABLE_OGL"], ["CA_AUTO_ENABLE_OGL", "LK_AUTO_ENABLE_OGL"], ["CA_ENABLE_MBX2D", "LK_ENABLE_MBX2D"]]

    /// The baked guest tools (and it_typein in SpringBoard) that must all load for any to be installed.
    static let guestTools = ["it_agent", "it_typein.dylib", "sblaunch", "sbdlicon", SystemEdits.Helpers.name("it_prefs", "armv6")]

    /// One Fit for the iPod's baked guest tools: each proven with FitCheck.loads (sbdlicon only if the helpers have it).
    static func guestToolsFit(_ fw: FitCheck.Firmware, helpers: URL) throws -> FitCheck.Fit {
        var fits: [FitCheck.Fit] = []
        for n in guestTools {
            let u = helpers.appendingPathComponent(n)
            guard FileManager.default.fileExists(atPath: u.path) else {
                if n == "sbdlicon" { continue }
                throw FirmwareError(.internal, "guest helper \(n) missing from \(helpers.path)")
            }
            fits.append(FitCheck.loads(n, try Data(contentsOf: u), on: fw, host: n == "it_typein.dylib" ? "/" + springBoard : nil))
        }
        let piece = "guest tools (\(fits.map(\.piece).joined(separator: ", ")))", lost = fits.filter { !$0.fits }
        guard lost.isEmpty else { return FitCheck.Fit(piece, fits: false, lost.map { "\($0.piece): \($0.proof)" }.joined(separator: "; ")) }
        return FitCheck.Fit(piece, fits: true, "each loads (\(fits[0].piece): \(fits[0].proof))")
    }

    /// SpringBoard's first-run "Edit Home Screen" tip stays down once com.apple.springboard SBDidShowReorderText is true.
    static let reorderTip = "SBDidShowReorderText"
    static let springBoard = "System/Library/CoreServices/SpringBoard.app/SpringBoard"

    /// contrib/it-prefs (IT_PREFS_TIP_ONLY) offline: SBDidShowReorderText = true in mobile's com.apple.springboard.plist,
    /// only if SpringBoard names the key (it_prefs checks first too); the report line says which.
    static func bakeReorderTip(_ m: URL) throws -> String {
        guard let sb = try? Data(contentsOf: m.appendingPathComponent(springBoard), options: .alwaysMapped),
              sb.range(of: Data(reorderTip.utf8)) != nil else { return "SpringBoard does not name \(reorderTip): left alone" }
        try SystemEdits.seedPlist(m.appendingPathComponent(prefs + "/com.apple.springboard.plist")) { $0[reorderTip] = true }
        return "\(reorderTip) baked (no helpers)"
    }

    /// ipod2g_device.gles2x_front_end (ipod1g_device's for 1.x): (true, line) if the stock OpenGLES exports exactly
    /// the names in `exports` (contrib/it-gles/opengles-<1x|2x>.exports), so the package's hook may replace it;
    /// else (false, why), stock kept.
    static func frontEnd(_ stock: URL, exports: URL) throws -> (Bool, String) {
        guard FileManager.default.fileExists(atPath: stock.path) else { return (false, "no \(openGLES)") }
        guard let list = try? String(contentsOf: exports, encoding: .utf8) else {
            throw FirmwareError(.internal, "guest helper \(exports.lastPathComponent) missing from \(exports.deletingLastPathComponent().path)")
        }
        let want = Set(list.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        let got = Set(try exportedSymbols(Data(contentsOf: stock)))
        guard want == got else {
            return (false, "stock OpenGLES exports differ from \(exports.lastPathComponent) (missing \(want.subtracting(got).sorted().prefix(4)), extra \(got.subtracting(want).sorted().prefix(4))): stock kept")
        }
        return (true, "GL front end replaces OpenGLES (\(got.count) exports, the firmware's own)")
    }

    /// gles2x_exports.scan: the defined external symbols of a thin (or the first ARM slice of a fat) 32-bit
    /// Mach-O, from its classic symbol table (the dysymtab's extdef range when present), without the leading _.
    static func exportedSymbols(_ data: Data) throws -> [String] {
        var b = [UInt8](data)
        func be32(_ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }
        func u32(_ o: Int) -> Int { Int(le32(b, o)) }
        if b.count >= 8, be32(0) == 0xCAFEBABE {
            for i in 0..<be32(4) where be32(8 + 20 * i) == 12 {
                let off = be32(16 + 20 * i), size = be32(20 + 20 * i)
                b = Array(b[off..<off + size])
                break
            }
        }
        guard b.count >= 28, u32(0) == 0xFEEDFACE else { throw FirmwareError(.unsupported, "OpenGLES: not a 32-bit Mach-O") }
        var off = 28, symtab: (Int, Int, Int)?, extdef: (Int, Int)?
        for _ in 0..<u32(16) {
            switch u32(off) {
            case 2: symtab = (u32(off + 8), u32(off + 12), u32(off + 16))
            case 0xB: extdef = (u32(off + 16), u32(off + 20))
            default: break
            }
            off += u32(off + 4)
        }
        guard let (symoff, nsyms, stroff) = symtab else { throw FirmwareError(.unsupported, "OpenGLES: no symbol table") }
        let (first, count) = extdef ?? (0, nsyms)
        return (first..<first + count).compactMap { k in
            let e = symoff + 12 * k, type = b[e + 4], start = stroff + u32(e)
            guard type & 0x01 != 0, type & 0x0E != 0, let end = b[start...].firstIndex(of: 0) else { return nil }
            let n = String(decoding: b[start..<end], as: UTF8.self)
            return n.hasPrefix("_") ? String(n.dropFirst()) : n
        }.sorted()
    }
}

fileprivate func le32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
