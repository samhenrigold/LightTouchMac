// N72Recipe: `firmwarekit create` for the iPod touch 2G (n72ap, recipe "n72"). Ports imgtools/device.py create +
// ipod2g_device.build/bake + build_nand.py (--epoch) over the other modules; Preparer.create hands n72ap here.
//
// STAGING_DIR gets nor.bin, iBoot.bin (3.x+: the machine's direct-iboot), gid-blobs.bin, nand/ (page directory),
// identity.json (600) and device.lock.json; all but the lock and identity are made read-only (the seal).
// There is no seal boot: the legacy FTL store needs no clean halt. Scratch goes to STAGING_DIR/work.
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

public enum N72Recipe {
    static let models = ["8g": "MB528", "16g": "MB531", "32g": "MB533"]
    static let kcPrefix = "/System/Library/Caches/com.apple.kernelcaches/"
    static let armv6Cache = "System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv6"
    static let mbx = "System/Library/Frameworks/OpenGLES.framework/MBXGLEngine.bundle/MBXGLEngine"
    static let itKeybag = "it_keybag-armv6", keybagStep = "Booting the restore ramdisk"
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

    public static func create(_ o: Preparer.Options, emit: @escaping @Sendable (PrepareEvent) -> Void) throws {
        let fm = FileManager.default, e = o.entry
        func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
        guard let recipe = e.recipe, recipe.name == "n72", let model = models[recipe.storage] else {
            throw FirmwareError(.unsupported, "\(e.id): no n72 recipe for storage \(e.recipe?.storage ?? "none")")
        }
        guard let sha1 = e.source.sha1 else { throw FirmwareError(.unsupported, "\(e.id) pins no IPSW sha1") }
        guard (try? fm.contentsOfDirectory(atPath: o.out.path))?.isEmpty == true else {
            throw FirmwareError(.internal, "\(o.out.path) is not an empty directory")
        }
        let blocks = recipe.systemMiB * 256
        let dataProtection = recipe.options["data_protection"] == true
        let bootrom = bootromPath(helper: o.helper)
        if dataProtection {
            guard let helper = o.helper, fm.isExecutableFile(atPath: helper.path) else {
                throw FirmwareError(.internal, "the keybag boot needs --helper (LightTouchDevice); got \(o.helper?.path ?? "none")")
            }
            guard let bootrom else { throw FirmwareError(.internal, "the keybag boot needs the iPod bootrom (bootrom_240_4) next to the helper") }
            guard fm.fileExists(atPath: o.guestTools.appendingPathComponent(itKeybag).path) else {
                throw FirmwareError(.internal, "guest helper \(itKeybag) missing from \(o.guestTools.path)")
            }
        }
        let steps = ["Verifying the IPSW", "Decrypting the firmware", "Writing the identity, NOR and boot files",
                     "Building the system volume", "Writing the NAND"] + (dataProtection ? [keybagStep] : []) + ["Writing the lock"]
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
        let got = try Preparer.digest(o.ipsw, Insecure.SHA1(), count: ipswBytes.add)
        guard got == sha1.lowercased() else { throw FirmwareError(.shaMismatch, "\(o.ipsw.lastPathComponent): sha1 \(got), \(e.id) pins \(sha1)") }
        let ipsw = IPSWArchive(o.ipsw)
        let restorePlist = try ipsw.read("Restore.plist")
        let restore = try RestoreInfo(plistData: restorePlist)
        try restore.verify(against: e)
        guard let rp = try PropertyListSerialization.propertyList(from: restorePlist, format: nil) as? [String: Any],
              let epoch = ((rp["DeviceMap"] as? [[String: Any]])?.first?["SCEP"] as? NSNumber)?.intValue,
              let major = Int(restore.productVersion.prefix { $0 != "." }) else {
            throw FirmwareError(.unsupported, "Restore.plist has no DeviceMap SCEP (NAND epoch)")
        }

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
        let iboot = try Data(contentsOf: dec.appendingPathComponent("iBoot.bin"))
        let kcPath = try kernelcachePath(iboot)
        guard let kcMember = try BuildComponents.load(ipsw)["KernelCache"] else { throw FirmwareError(.unsupported, "\(e.id): the IPSW names no KernelCache") }
        var derived: [String: Any] = ["nand_epoch": epoch, "wrap_shsh": major >= 3, "kernelcache_path": kcPath, "kernelcache_member": kcMember,
                                      "kernel": firstMatch(try Data(contentsOf: dec.appendingPathComponent("kernelcache.mach")), /Darwin Kernel Version [^\x00]+/) ?? NSNull(),
                                      "iboot": firstMatch(iboot, /iBoot-[0-9.]+/) ?? "?", "direct_iboot": major >= 3]

        step()   // identity.json, nor.bin, gid-blobs.bin, iBoot.bin
        let seed = o.seed ?? "ipod2g-\(e.build)-default"
        let ident = try UnitIdentity.synthesizeIPod(seed: seed, modelNumber: model, regionInfo: UnitIdentity.iPadRegion)
        try ident.write(to: file("identity.json"))
        let prefix = "Firmware/all_flash/all_flash.\(e.board).production/"
        let names = try ipsw.names()
        let img3Members = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".img3") }
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
        try N72NOR.build(identity: ident, images: images, types: norTypes, wrapTypes: major >= 3 ? nil : ["ibot"]).write(to: file("nor.bin"))
        let (blobs, blobNames) = try gidBlobs(ipsw, members: img3Members + [kcMember], entry: e)
        derived["gid_blobs"] = blobNames
        try blobs.write(to: file("gid-blobs.bin"))
        if major >= 3 { try iboot.write(to: file("iBoot.bin")) }

        step()   // the system volume: IPSW rootfs grown to the recipe, fstab, kernelcache, bake
        let volume = work.appendingPathComponent("volume.img")
        try UDIF.extractRootfs(dmg: dec.appendingPathComponent("rootfs.dmg"), to: volume)
        try VolumeMount.grow(volume, toBytes: blocks * 4096)
        do {
            let v = try HFSPlusVolume(volume)
            log("\(v.signature) blocksize=\(v.blockSize) total=\(v.totalBlocks) free=\(v.freeBlocks) files=\(v.fileCount) dirs=\(v.folderCount)")
            guard v.totalBlocks == blocks, v.blockSize == 4096 else { throw FirmwareError(.internal, "resize produced \(v.totalBlocks) x \(v.blockSize) B blocks, wanted \(blocks) x 4096") }
        }
        var owners: [(UInt32, String)] = [(0, kcPath)]
        let baked = try VolumeMount.withMounted(volume, at: work.appendingPathComponent("mnt")) { m -> [String: Any] in
            try SystemEdits.put(Data(fstabRW.utf8), m.appendingPathComponent(SystemEdits.fstab))
            let kc = m.appendingPathComponent(kcPath)
            try SystemEdits.mkdirs(kc.deletingLastPathComponent())
            try ipsw.extract(kcMember, to: kc)
            return try bake(m, options: recipe.options, tools: major >= 3, helpers: o.guestTools, gliDispatch: recipe.gliDispatch,
                            owners: &owners, log: log)
        }
        for (k, v) in baked where k != "guest_package" { derived[k] = v }
        let guestPackage = baked["guest_package"] as? GuestPackage.Record
        let hfs = try HFSPlusVolume(volume, writable: true)
        for uid in Set(owners.map(\.0)).sorted() {
            let n = try hfs.setOwner(owners.filter { $0.0 == uid }.map(\.1), uid: uid, gid: uid)
            log("\(uid):\(uid) patched \(n) catalog record(s)")
        }

        step()   // the page directory
        let nand = file("nand")
        let (written, meta) = try N72NAND.write(volume: volume, blocks: blocks, epoch: epoch, out: nand)
        log("\(written) filesystem pages, \(meta) metadata pages generated (epoch \(epoch))")
        try fm.removeItem(at: volume)

        if dataProtection, let helper = o.helper, let bootrom {
            step()   // 4.x data protection: effaceable + system keybag from the IPSW's own Update ramdisk (a
            // restore-only build such as 8A293 ships just the Restore one; restored_external runs first on either)
            let comp = try BuildComponents.load(ipsw)
            guard let update = comp["UpdateRamDisk"] ?? comp["RestoreRamDisk"] else { throw FirmwareError(.unsupported, "\(e.id): no ramdisk") }
            let ramdisk = String(update.dropLast(4)) + "-ramdisk.dmg"
            _ = try N72Keybag.run(out: o.out, dec: dec, ramdisk: ramdisk, itKeybag: o.guestTools.appendingPathComponent(itKeybag),
                                  bootrom: bootrom, helper: helper, work: work, log: log)
            derived["keybag_ramdisk"] = ramdisk
        }

        step()   // read-only outputs (the seal), lock
        let ship = ["nand", "nor.bin", "gid-blobs.bin"] + (major >= 3 ? ["iBoot.bin"] : [])
        for n in ship { try Preparer.readOnly(file(n)) }
        let pages = try (0..<4).flatMap { cs in try fm.contentsOfDirectory(atPath: nand.appendingPathComponent("cs\(cs)").path).map { "cs\(cs)/\($0)" } }.sorted()
        final class Hashes: @unchecked Sendable { let lock = NSLock(); var sha: [String: String] = [:]; var error: Error? }
        let hashes = Hashes()
        DispatchQueue.concurrentPerform(iterations: pages.count) { i in
            do { let h = try Preparer.digest(nand.appendingPathComponent(pages[i]), SHA256()); hashes.lock.withLock { hashes.sha[pages[i]] = h } }
            catch { hashes.lock.withLock { hashes.error = error } }
        }
        if let error = hashes.error { throw error }
        var listing = SHA256()
        for p in pages { listing.update(data: Data("\(p) \(hashes.sha[p]!)\n".utf8)) }
        let activation = baked["activation"] as? Activation.Result
        derived["activation"] = nil
        let used = try fm.contentsOfDirectory(atPath: o.guestTools.path).sorted()
        func sha(_ n: String) throws -> [String: String] { ["path": n, "sha256": try Preparer.digest(file(n), SHA256())] }
        let lock: [String: Any] = [
            "format": 1, "created": ISO8601DateFormatter().string(from: Date()),
            "entry": ["id": e.id, "sha256": Preparer.sha256(try JSONEncoder().encode(e)), "content": try JSONSerialization.jsonObject(with: JSONEncoder().encode(e))],
            "build": e.build, "product_version": restore.productVersion, "product_type": e.productType, "board": e.board,
            "storage": recipe.storage,
            "tool": ["name": "firmwarekit", "version": FirmwareKit.version, "helper": o.helper.map { $0.path as Any } ?? NSNull(),
                     "built": ["guest tools": Dictionary(uniqueKeysWithValues: try used.map { ($0, try Preparer.digest(o.guestTools.appendingPathComponent($0), SHA256())) })]],
            "inputs": ["ipsw": ["path": o.ipsw.path, "sha1": got], "decrypted": dec.path, "identity": "identity.json",
                       "activation": activation.map { ["input_sha256": $0.inputSHA256, "output_sha256": $0.outputSHA256] as Any } ?? NSNull(),
                       "rootfs": "rootfs.dmg", "kernelcache": kcMember, "iboot": "iBoot.bin", "all_flash": prefix,
                       "guest_tools": o.guestTools.path, "lockdown": NSNull()],
            "identity": ["seed": seed, "udid": ident.udid ?? "", "sha256": try Preparer.digest(file("identity.json"), SHA256())],
            "outputs": ["nand": ["path": "nand", "pages": pages.count, "listing_sha256": listing.finalize().map { String(format: "%02x", $0) }.joined()],
                        "nor": try sha("nor.bin"), "iboot": major >= 3 ? try sha("iBoot.bin") as Any : NSNull(), "gid_blobs": try sha("gid-blobs.bin")],
            "derived": derived, "guest_package": guestPackage?.object ?? NSNull(),
            // machine options the device must boot with (ipod2g_device.py): every device built here uses the
            // engine UID path; adopted and shipping images keep the legacy default
            "machine": machine,
        ]
        try fm.removeItem(at: work)
        try JSONSerialization.data(withJSONObject: lock, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: file("device.lock.json"))
        log("\(o.out.path): UDID \(ident.udid ?? "-")")
        progress.finish()
        emit(.done(lock: "device.lock.json"))
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
    /// install_web_proxy, activation). Appends the owners to patch; returns the report.
    static func bake(_ m: URL, options opt: [String: Bool], tools: Bool, helpers: URL, gliDispatch: String?,
                     owners: inout [(UInt32, String)], log: (String) -> Void) throws -> [String: Any] {
        let fm = FileManager.default
        let at = { (rel: String) in m.appendingPathComponent(rel) }
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
            guard fm.fileExists(atPath: at(armv6Cache).path) else { return "no dyld shared cache (2.x, 3.0)" }
            let tsvs = try gliDispatch.map { [helpers.appendingPathComponent($0)] } ?? fm.contentsOfDirectory(at: helpers, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.wholeMatch(of: /gli-dispatch-\w+\.tsv/) != nil && fm.fileExists(atPath: helpers.appendingPathComponent(engine($0)).path) }
            let (tsv, why) = try GLIDispatch.engine(cache: try Data(contentsOf: at(armv6Cache), options: .alwaysMapped), cachePath: at(armv6Cache).path, tsvs: tsvs)
            gli = tsv.map { String(engine($0).dropFirst("MBXGLEngine-".count)) }
            return tsv == nil ? why ?? "no dispatch tables" : nil
        }()
        report["gles"] = gli.map { "shim MBXGLEngine-" + $0 } ?? "stock engine, software CA: " + (problem ?? "")
        report["gli"] = gli.map { $0 as Any } ?? NSNull()
        report["guest_tools"] = tools ? "installed" : "omitted: current helpers require iOS 3+ dyld"

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
        try SystemEdits.rewritePlist(at(SystemEdits.springBoardJob)) { d in
            guard d["Label"] as? String == "com.apple.SpringBoard" else { throw FirmwareError(.unsupported, "\(SystemEdits.springBoardJob): not SpringBoard's job") }
            let env = SystemEdits.dict(d, "EnvironmentVariables")
            for k in ["CA_ENABLE_OGL", "LK_ENABLE_OGL"] { env[k] = problem == nil ? "1" : "0" }
            for k in ["CA_AUTO_ENABLE_OGL", "LK_AUTO_ENABLE_OGL", "CA_ENABLE_MBX2D", "LK_ENABLE_MBX2D"] { env[k] = "0" }
            let old = (env["DYLD_INSERT_LIBRARIES"] as? String ?? "").split(separator: ":").map(String.init)
            let libs = old.filter { !["/usr/lib/it_kbd_agent.dylib", "/usr/lib/it_typein.dylib"].contains($0) } + (tools ? ["/usr/lib/it_typein.dylib"] : [])
            env["DYLD_INSERT_LIBRARIES"] = libs.isEmpty ? nil : libs.joined(separator: ":")
        }
        if tools { try SystemEdits.put(helper("com.qemu.it-agent.plist"), at(agentJob), mode: 0o644) }
        try? fm.removeItem(at: at("System/Library/LaunchDaemons/com.qemu.it-pbd.plist"))
        let sbp = at(prefs + "/com.apple.springboard.plist")
        if fm.fileExists(atPath: sbp.path),
           let d = try PropertyListSerialization.propertyList(from: Data(contentsOf: sbp), format: nil) as? [String: Any],
           d["SBDontLockEver"] != nil || d["SBDisableCABlanking"] != nil {
            try SystemEdits.rewritePlist(sbp) { $0.removeObjects(forKeys: ["SBDontLockEver", "SBDisableCABlanking"]) }
        }
        for (name, changes) in soundDefaults {
            try SystemEdits.seedPlist(at(prefs + "/" + name)) { $0.addEntries(from: changes) }
        }
        let media = at("private/var/mobile/Media")
        if tools {
            try SystemEdits.mkdirs(media)
            for v in 1...3 { try SystemEdits.put(Data("v\(v)\n".utf8), media.appendingPathComponent(".lt-guest-tools-v\(v)")) }
        } else {
            for rel in [agentJob] + (1...3).map({ "private/var/mobile/Media/.lt-guest-tools-v\($0)" }) { try? fm.removeItem(at: at(rel)) }
        }

        if gli != nil {   // ipad1_rootfs.gli_uncache: 4.x caches MBXGLEngine, so dyld must prefer the file
            let status = try autoreleasepool { try SystemEdits.overrideCachedImage(m, image: mbx, cache: armv6Cache) }
            report["gles_cache"] = status
            if status.contains("overridden") { owners.append((0, SystemEdits.dyldOverride)) }
        }
        if opt["appsync"] == true {   // patch-appsync-dylib.sh
            // 2.x and 3.0 have no dyld shared cache (libmis is its own dylib): only installd's interposer then,
            // so amfid and SpringBoard's launch gate stay stock (docs/matrix.md).
            let line = fm.fileExists(atPath: at(armv6Cache).path) ? try AppSyncCachePatch.patchCache(at: at(armv6Cache))
                : "warning: no dyld shared cache: MISValidateSignature unpatched (installd interposer only)"
            log(line)
            try SystemEdits.put(helper(SystemEdits.Helpers.appsync), at(SystemEdits.appsyncPath), mode: 0o644)
            let job = ["com.apple.mobile.installd.plist", "com.apple.installd.plist"].map { at("System/Library/LaunchDaemons/" + $0) }
                .first { fm.fileExists(atPath: $0.path) }
            guard let job else { throw FirmwareError(.unsupported, "no installd launchd plist") }
            try SystemEdits.rewritePlist(job) { SystemEdits.dyldInsert($0, "/" + SystemEdits.appsyncPath) }
            report["appsync"] = [line, "installd (\(job.lastPathComponent)) DYLD_INSERT_LIBRARIES += /\(SystemEdits.appsyncPath)"]
            owners.append((0, SystemEdits.appsyncPath))
        }
        if tools {   // ipod2g_device.PREFS: the iPad's it_prefs, SpringBoard tip only (contrib/it-prefs/build-ipod.sh)
            try SystemEdits.put(helper("it_prefs-armv6"), at("usr/local/bin/it_prefs"), mode: 0o755)
            try SystemEdits.put(helper("com.qemu.it-prefs.plist"), at(prefsJob), mode: 0o644)
            owners += [(0, "usr/local/bin/it_prefs"), (0, prefsJob)]
            report["prefs"] = "it_prefs: SBDidShowReorderText at first boot"
        }
        if opt["web_proxy"] ?? true {   // install_web_proxy
            let sc = "private/var/preferences/SystemConfiguration"
            for rel in ["usr/local", "usr/local/share", "usr/local/share/ltm", sc] where !fm.fileExists(atPath: at(rel).path) {
                try SystemEdits.mkdirs(at(rel))
                owners.append((0, rel))
            }
            try SystemEdits.put(Data(SystemEdits.pac.utf8), at(SystemEdits.pacPath))
            try SystemEdits.seedPlist(at(sc + "/preferences.plist"), SystemEdits.wifiProxyPrefs)
            owners += [(0, SystemEdits.pacPath), (0, sc + "/preferences.plist")]
            report["web_proxy"] = "PAC /\(SystemEdits.pacPath) on the en0 Wi-Fi service"
        }
        log("Activating device")
        report["activation"] = try Activation.run(on: at(SystemEdits.lockdownd))
        owners.append((0, SystemEdits.lockdownd))
        // mkpkg.seed: the loader and the seed package; it_boot loads the package's jobs (com.qemu.it-agent), so
        // the baked copies it provides are removed. Owners after it, for only what is left.
        let (seeded, record) = try GuestPackage.seed(volume: m, itpack: helpers.appendingPathComponent("armv6.itpack"), gli: gli)
        log("seed package \(record.family) serial \(record.seed), hooks \(record.hooks)")
        report["guest_package"] = record
        owners += seeded.map { (UInt32(0), $0) }
        owners += guestToolOwners.filter { (try? fm.destinationOfSymbolicLink(atPath: at($0.1).path)) != nil || fm.fileExists(atPath: at($0.1).path) }
        log("bake: \(report.filter { $0.key != "activation" && $0.key != "guest_package" })")
        return report
    }
}

/// gli-dispatch-<BUILD>.tsv -> MBXGLEngine-<BUILD>
fileprivate func engine(_ tsv: URL) -> String {
    "MBXGLEngine-" + tsv.deletingPathExtension().lastPathComponent.dropFirst("gli-dispatch-".count)
}

fileprivate func le32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
