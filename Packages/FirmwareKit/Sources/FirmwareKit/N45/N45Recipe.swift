// N45Board: the iPod touch 1G (n45ap, recipe "n45") side of Recipe.create, for iPhone OS 1.x.
//
// Boot files: iBoot.bin (the IPSW's iBoot-204 IMG2 payload, which the machine enters at 0x18000000) and nor.bin
// (N45NOR over the IPSW's all_flash IMG2s). The bootrom (bootrom_s5l8900) is a boot input, like the 2G's.
// Volume: the IPSW rootfs grown to the recipe, then the 1.x bake of devos50's qemu-ios-generate-nand
// changes through SystemEdits: fstab rw with no /private/var line (one partition), the kernelcache (the
// IPSW's 8900 container, which the machine's 8900 engine decrypts) where iBoot loads it, the LaunchDaemons
// that changes.md keeps (and 1.1.3+'s lockbot), and the /var/root/Library skeleton; then ipod1g_device.bake:
// when the stock OpenGLES exports exactly
// opengles-1x.exports (a guest helper), the seed package's n45-ios1 hook (OpenGLES-1x, the GL front end) replaces it
// (the stock binary kept as OpenGLES.baked) and SpringBoard gets LK_ENABLE_OGL=1 LK_AUTO_ENABLE_OGL=0 (else
// LK_ENABLE_OGL stays unset: software LayerKit); the loader and the seed package go in either way, as on every board
// (the legacy-linked it_boot runs under 1.x launchd); an itpack without the hook is refused. The volume journaled (it
// is also /private/var); activation as every board has it; owners patched in the catalog. Store: N45NAND.
// No other guest tools on 1.x, no keybag, no seal.
//
// The recipe: storage "8g" (MA623; the only NAND geometry modeled), system_mib = the volume.
//
// The original iPhone (m68ap, recipe "m68", iPhone OS 1.0 1A543a) is this board with its own data: storage "4g"
// (MA501: the four chip enables its DT's flash disk names, reg 0x0f, of the same chips), an iPhone identity (an IMEI,
// a Bluetooth MAC; the UDID hashes both), btaddr beside wifiaddr in the nvram (iBoot fills arm-io/uart3/bluetooth from
// it), the NAND signature its iBoot-159 carries (C000). The LaunchDaemons kept are the same list (1.0 ships no
// AddressBook job), plus BTServer (qemu-ios models the M68's Bluetooth chip on UART3; without BTServer SpringBoard's
// BluetoothManager sleeps on its main thread through MobileBluetooth's attach retries, seconds per app launch);
// iapd goes (no accessory model).

import Foundation

final class N45Board: Board {
    static let models = ["8g": "MA623"]
    static let iPhoneModels = ["4g": "MA501"]
    /// changes.md: every other job is removed (the rest wait on hardware this machine does not have). Plus ptpd
    /// (usbptpd): USBDeviceConfiguration's iPod1,1 configurations all carry PTP, and IOIpodUSBDevice starts no USB
    /// stack ("can't start! Need functions") until every function has registered, so without it there is no usbmux.
    /// Plus coreaudiod.plist (the job is mediaserverd): it serves com.apple.audio.systemsoundserver2, so every system
    /// sound, keyboard clicks and lock included, and on N45 each is played as Beep + Buzz (Celestial's
    /// N45/SystemSoundBehaviour.plist), the Buzz on the piezo behind timer 1. It needs the WM8758 codec to answer
    /// on I2C (qemu-ios ipod1g-buzzer); without one it crash-loops on an empty audio device list.
    /// Plus mDNSResponder: 1.x's libSystem resolves every host name through it (unicast DNS included), so without it
    /// Safari, joined and leased, sent no DNS query at all and answered "can't find the server" for any named host
    /// while an IP literal loaded. It waits on no hardware.
    static let keptDaemons: Set = [
        "com.apple.AddressBook.plist", "com.apple.CommCenter.plist", "com.apple.configd.plist",
        "com.apple.mDNSResponder.plist", "com.apple.mobile.lockdown.plist", "com.apple.notifyd.plist",
        "com.apple.SpringBoard.plist", "com.apple.usbptpd.plist", "coreaudiod.plist"
    ]
    /// Kept where the firmware ships them, not required of every 1.x: 1.1.3+ lockdownd starts each service (AFC among
    /// them) through lockbot ("spawn_service_agent: Could not spawn service agent via lockbot" without it); 1.1-1.1.2
    /// have no lockbot and spawn their own.
    static let keptWhenShipped: Set = ["com.apple.mobile.lockbot.plist"]
    /// Kept on the iPhone (m68ap) only: the machine answers BTServer's HCI there; the iPod touch has no Bluetooth.
    static let iPhoneDaemons: Set = ["com.apple.BTServer.plist"]
    /// The jobs the bake removes from this firmware's LaunchDaemons.
    static func removedDaemons(_ jobs: [String], iPhone: Bool = false) -> [String] {
        jobs.filter {
            !keptDaemons.contains($0) && !keptWhenShipped.contains($0) && !(iPhone && iPhoneDaemons.contains($0))
        }.sorted()
    }
    /// The directories of the kept jobs' StandardOutPath/StandardErrorPath that the image lacks, made (volume-relative,
    /// to own as root). 1.x's launchd does not start a job whose log file it cannot open: 1.0's BTServer
    /// (/var/logs/BTServer/stderr) never ran, and SpringBoard stalled on Bluetooth as if it were removed.
    static func makeLogDirs(_ v: any VolumeFiles, jobs: [String]) throws -> [String] {
        var made: [String] = []
        for job in jobs.sorted() {
            guard
                let d = (try? v.contents(at: SystemEdits.daemons + "/" + job)).flatMap({
                    try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
                })
            else { continue }
            for key in ["StandardOutPath", "StandardErrorPath"] {
                guard let path = d[key] as? String, path.hasPrefix("/") else { continue }
                var dir = ((path as NSString).deletingLastPathComponent as NSString).substring(from: 1)
                if dir.hasPrefix("var/") { dir = "private/" + dir }
                guard !dir.isEmpty, !made.contains(dir), !v.exists(dir) else { continue }
                try v.makeDirectory(dir)
                made.append(dir)
            }
        }
        return made
    }

    /// 1.x's SpringBoard puts the system to deep sleep (pmu go hib) when the lock screen idles, seconds after boot,
    /// and the machine has no resume path (qemu-ios docs/ipod1g, debt 9). SBDisableIdleSleep keeps it to a display
    /// sleep, which Home or Hold wakes. Set in `prefs` (volume-relative) when SpringBoard names it; true if set.
    static func bakeNoIdleSleep(_ v: any VolumeFiles, prefs: String) throws -> Bool {
        let key = "SBDisableIdleSleep"
        guard let sb = try? v.contents(at: N72Board.springBoard), sb.range(of: Data((key + "\0").utf8)) != nil
        else { return false }
        try SystemEdits.seedPlist(v, prefs) { $0[key] = true }
        return true
    }

    static let rootLibrary = "private/var/root/Library"
    /// Whose Library SpringBoard reads its preferences from: mobile (501) when its launchd job says so (1.1.3 on), else root.
    static func springBoardUser(_ v: any VolumeFiles) -> (library: String, uid: UInt32) {
        let plist = (try? v.contents(at: SystemEdits.springBoardJob)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        return plist?["UserName"] as? String == "mobile" ? ("private/var/mobile/Library", 501) : (rootLibrary, 0)
    }
    static let openGLESExports = "opengles-1x.exports"
    /// Where configd keeps its SCPreferences. While everything runs as root (1.0 to 1.1.2), SystemConfiguration opens
    /// ~/Library/Preferences/SystemConfiguration, root's home. From 1.1.3, where SpringBoard and the apps run as mobile
    /// (springBoardUser), it opens /Library/Preferences/SystemConfiguration, which the root links to
    /// /private/var/preferences, and never looks in root's home: 1.1.4's configd creates that directory at its first
    /// boot, next to a seeded one in root's home, and joins nothing.
    static func scPrefs(_ v: any VolumeFiles) -> String {
        springBoardUser(v).uid == 0
            ? rootLibrary + "/Preferences/SystemConfiguration" : "private/var/preferences/SystemConfiguration"
    }
    /// configd's Aeropuerto plug-in (AirPort-53 on 1.0, -63 on 1.1) keeps the Wi-Fi power preference (AllowEnable)
    /// and the networks it has joined ("List of known networks", entries keyed by SSID_STR) in this file.
    static func wifiPrefs(_ v: any VolumeFiles) -> String { scPrefs(v) + "/com.apple.wifi.plist" }
    /// The PAC, the en0 AirPort service carrying it (preferences.plist) and the known network (wifiPrefs) in scPrefs.
    /// Returns the paths to make root-owned. The recipe writes them on a fresh volume; its admission step
    /// (N45Migration) on a device whose configd has already written both files there: the PAC goes on configd's own
    /// en0 service (not a second one) and qemu-ios joins its known networks, the rest of each file kept.
    static func seedSystemConfiguration(_ v: any VolumeFiles) throws -> [String] {
        let scPrefs = scPrefs(v)
        let wifiPrefs = wifiPrefs(v)
        let owned = try SystemEdits.installPAC(v, dirs: [scPrefs])
        try SystemEdits.seedPlist(v, scPrefs + "/preferences.plist") { d in
            let en0 = ((d["NetworkServices"] as? NSDictionary)?.allValues ?? []).compactMap {
                $0 as? NSMutableDictionary
            }
            .filter { ($0["Interface"] as? NSDictionary)?["DeviceName"] as? String == "en0" }
            if en0.isEmpty {
                SystemEdits.wifiProxyPrefs(d)
            } else {
                for s in en0 { s["Proxies"] = SystemEdits.pacProxies }
            }
            // 1.0's cellular data service is CommCenter's, made at run time with no setup entry of its own; configd
            // applies the set's global Proxies to it (without them EDGE went DIRECT to :443; with them, CONNECT to the proxy).
            SystemEdits.dict(SystemEdits.currentNetwork(d), "Global")["Proxies"] = SystemEdits.pacProxies
        }
        var known =
            (try? v.contents(at: wifiPrefs)).flatMap {
                try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
            } ?? [:]
        if known["AllowEnable"] == nil { known["AllowEnable"] = wifiKnownNetwork["AllowEnable"] }
        let list = known["List of known networks"] as? [[String: Any]] ?? []
        if !list.contains(where: { $0["SSID_STR"] as? String == "qemu-ios" }) {
            known["List of known networks"] = list + [qemuNetwork]
        }
        try v.put(
            try PropertyListSerialization.data(fromPropertyList: known, format: .xml, options: 0),
            at: wifiPrefs,
            mode: 0o644
        )
        return owned + [scPrefs + "/preferences.plist", wifiPrefs]
    }

    /// A device that has joined the emulator's access point before (the 88W8686 model's open "qemu-ios", channel 6):
    /// Wi-Fi on, and the network remembered as the join left it, so configd auto-joins at boot.
    static var wifiKnownNetwork: [String: Any] { ["AllowEnable": true, "List of known networks": [qemuNetwork]] }

    /// The emulator's access point as a known-networks entry.
    static var qemuNetwork: [String: Any] {
        [
            "SSID_STR": "qemu-ios", "SSID": Data("qemu-ios".utf8), "AP_MODE": 2, "CAPABILITIES": 1, "CHANNEL": 6,
            "CHANNEL_FLAGS": 8, "BEACON_INT": 10, "HIDDEN_NETWORK": false
        ]
    }

    let arch = "armv6"
    var seedPrefix: String { iPhone ? "iphone2g" : "ipod1g" }
    let bootStep = "Writing the identity, NOR and boot files", volumesStep = "Building the system volume",
        keybagStep = ""
    let dataProtection = false, needsSeal = false
    let shipped = ["nor.bin", "iBoot.bin"]
    let recipe: FirmwareEntry.Recipe, model: String, bytes: Int
    /// The original iPhone (m68ap): its identity, its NAND's chip enables.
    let iPhone: Bool
    var banks: Int { iPhone ? 4 : N45NAND.banks }
    var ident: UnitIdentity?, volume: URL?
    var kcPath = "", kcMember = "", prefix = ""
    var derived: [String: Any] = [:]

    init(_ o: Preparer.Options) throws {
        iPhone = o.entry.board == "m68ap"
        guard let recipe = o.entry.recipe, let model = (iPhone ? Self.iPhoneModels : Self.models)[recipe.storage] else {
            throw FirmwareError(
                .unsupported,
                "\(o.entry.id): no \(o.entry.recipe?.name ?? "n45") recipe for storage \(o.entry.recipe?.storage ?? "none")"
            )
        }
        self.recipe = recipe
        self.model = model
        bytes = recipe.systemMiB << 20
    }

    /// The piece a 2.0-or-later entry is refused for (PreparationJob words it for the user).
    static let onePiece = "iPhone OS 1.x boot chain"

    func check(_ c: Recipe.Context) throws {
        // 2.0 and later boot an IMG3 chain (LLB, iBoot-385+, IMG3 all_flash) that qemu-ios's ipod_touch_1g doesn't
        // model, nor their kernels' drivers: refused here, before the IPSW is hashed, instead of at N45NOR's IMG2 read.
        guard (Int(c.e.version.prefix { $0 != "." }) ?? 1) < 2 else {
            throw FirmwareError(
                .unsupported,
                "\(c.e.id): this machine boots iPhone OS 1.x only (\(c.e.version) is an IMG3 firmware)",
                piece: Self.onePiece
            )
        }
        // 1.0's lockdownd starts an afc2 entry but its afcd answers no path (AFC object not found): no jailbreak on 1.x.
        guard recipe.options["jailbreak"] != true else {
            throw FirmwareError(.unsupported, "\(c.e.id): the jailbreak option needs iPhone OS 2.0 or later")
        }
    }

    /// An IPSW kernelcache that is the restore environment's, not the system's.
    static func restoreOnly(_ member: String) -> Bool { (member as NSString).lastPathComponent.contains(".restore.") }

    /// The jobs this machine keeps must all be among the firmware's (usbptpd: no usbmux without it).
    static func keptDaemonsFit(_ jobs: [String]) -> FitCheck.Fit {
        let absent = keptDaemons.subtracting(jobs).sorted()
        return FitCheck.Fit(
            "LaunchDaemons kept on 1.x (\(keptDaemons.count))",
            fits: absent.isEmpty,
            absent.isEmpty ? "all shipped by this firmware" : "this firmware ships no \(absent.joined(separator: ", "))"
        )
    }

    func identity(seed: String) throws -> UnitIdentity {
        let ident =
            iPhone
            ? try UnitIdentity.synthesizeIPhone(seed: seed, modelNumber: model, regionInfo: UnitIdentity.iPadRegion)
            : try UnitIdentity.synthesizeIPod(
                seed: seed,
                modelNumber: model,
                regionInfo: UnitIdentity.iPadRegion,
                bluetooth: false
            )
        self.ident = ident
        return ident
    }

    func bootFiles(_ c: Recipe.Context) throws {
        let ipsw = c.ipsw
        let iboot = try Data(contentsOf: c.decFile("iBoot.bin"))  // host file
        kcPath = try N72Board.kernelcachePath(iboot)
        guard let kc = try BuildComponents.load(ipsw, board: c.e.board)["KernelCache"] else {
            throw FirmwareError(.unsupported, "\(c.e.id): the IPSW names no KernelCache")
        }
        kcMember = kc
        prefix = "Firmware/all_flash/all_flash.\(c.e.board).production/"
        var images: [String: Data] = [:]
        for n in try ipsw.names() where n.hasPrefix(prefix) && n.hasSuffix(".img2") {
            let body = try Apple8900.body(ipsw.read(n))
            images[try IMG2.Header(body).type] = body
        }
        let nor = try N45NOR.build(identity: ident.filled("the identity"), images: images)
        try nor.write(to: c.file("nor.bin"))  // host file
        try iboot.write(to: c.file("iBoot.bin"))  // host file
        derived = [
            "kernelcache_path": kcPath, "kernelcache_member": kcMember, "nor_images": N45NOR.order,
            "boot_args": N45NOR.bootArgs,
            "kernel": N72Board.firstMatch(
                try Data(contentsOf: c.decFile("kernelcache.mach")),  // host file
                /Darwin Kernel Version [^\x00]+/
            ) ?? NSNull(),
            "iboot": N72Board.firstMatch(iboot, /iBoot-[0-9.]+/) ?? "?"
        ]
    }

    nonisolated(nonsending) func volumes(_ c: Recipe.Context) async throws {
        let volume = c.work.appendingPathComponent("volume.img")
        self.volume = volume
        try await UDIF.extractRootfs(dmg: c.decFile("rootfs.dmg"), to: volume)
        try await VolumeMount.grow(volume, toBytes: bytes)
        // Modern HFS checks reject the stock 1.x catalog's legacy folder counts.
        // Normalize the private working volume before mounting/editing it, then verify it. (The offline writer
        // keeps the counts as the catalog has them.)
        if VolumeMount.backend == .kernel {
            let device = try await VolumeMount.attach(volume)
            let check: (ok: Bool, output: String)
            do {
                c.log(try await VolumeMount.run("/sbin/fsck_hfs", ["-fy", device]))
                check = try await VolumeMount.check(device)
            } catch {
                await VolumeMount.cleanupDetach(device)
                throw error
            }
            try await VolumeMount.detach(device)
            guard check.ok else { throw FirmwareError(.internal, "1.x root filesystem repair failed: \(check.output)") }
        }
        let newest: UInt32
        do {
            let v = try HFSPlusVolume(volume)
            c.log(
                "\(v.signature) blocksize=\(v.blockSize) total=\(v.totalBlocks) free=\(v.freeBlocks) files=\(v.fileCount) dirs=\(v.folderCount)"
            )
            guard Int(v.totalBlocks) * Int(v.blockSize) == bytes else {
                throw FirmwareError(.internal, "resize produced \(v.totalBlocks) x \(v.blockSize) B, wanted \(bytes) B")
            }
            newest = try v.newestDate()
        }
        var owners: [(UInt32, String)] = [(0, kcPath), (0, SystemEdits.lockdownd)]
        let (activation, removed) = try await Self.withJournaledRoot(
            volume,
            at: c.work.appendingPathComponent("mnt"),
            date: newest
        ) { v -> (Activation.Result, [String]) in
            try v.put(Data(N72Board.fstabRW.utf8), at: SystemEdits.fstab)
            try v.makeDirectory((kcPath as NSString).deletingLastPathComponent)
            // 1.0 ships only the restore kernelcache in the IPSW (RestoreKernelCaches "kernelcache.restore.*");
            // its system volume carries the one iBoot boots, where iBoot loads it: kept.
            if !(Self.restoreOnly(kcMember) && v.exists(kcPath)) {
                try v.put(member: kcMember, of: c.ipsw, at: kcPath)
            }
            let jobs = try v.contentsOfDirectory(at: SystemEdits.daemons)  // no link followed
                .filter { $0.hasSuffix(".plist") }.sorted()
            try c.fit.check(Self.keptDaemonsFit(jobs), required: false, outcome: "the rest removed as planned")
            c.fit.notInstalled(
                "AppSync",
                recipe.options["appsync"] == true ? "the 1.x recipe has no AppSync" : "appsync off"
            )
            let removed = Self.removedDaemons(jobs, iPhone: iPhone)
            for n in removed { try v.remove(SystemEdits.daemons + "/" + n) }
            owners += try Self.makeLogDirs(v, jobs: jobs.filter { !removed.contains($0) }).map { (0, $0) }
            for d in ["", "/AddressBook", "/Lockdown", "/Preferences"] {
                try v.makeDirectory(Self.rootLibrary + d)
                owners.append((0, Self.rootLibrary + d))
            }
            // An iPod's first iTunes handshake clears BrickState independently of activation.
            // The 1G has no host USB transport yet. Seed the same persistent boolean on its fresh
            // data volume; lockdownd owns the rest of this dictionary and preserves it on reboot.
            let ark = Self.rootLibrary + "/Lockdown/data_ark.plist"
            try v.put(
                try PropertyListSerialization.data(fromPropertyList: ["-BrickState": false], format: .xml, options: 0),
                at: ark,
                mode: 0o600
            )
            owners.append((0, ark))
            // Wi-Fi as a device that has joined the emulator's network before: the en0 AirPort service in the current
            // set (configd's auto-join skips an interface with none: "AirPort interface en0 not active"), carrying the
            // web proxy's PAC as on the 2G, and Wi-Fi on with qemu-ios among the known networks.
            try c.fit.check(
                FitCheck.webProxy(FitCheck.Firmware(volume: v, arch: "armv6")),
                required: false,
                outcome: "kept: the PAC is unused"
            )
            owners += try Self.seedSystemConfiguration(v).map { (UInt32(0), $0) }
            derived["wifi"] =
                "en0 AirPort service (PAC /\(SystemEdits.pacPath)); known network qemu-ios, Wi-Fi on (/\(Self.wifiPrefs(v)))"
            // 1.x runs no guest helpers (it_prefs): its SpringBoard preferences, in the home of the user SpringBoard
            // runs as (root's on 1.0 and 1.1.2; mobile's from 1.1.3, its launchd job's UserName)
            let user = Self.springBoardUser(v)
            let sbPrefs = user.library + "/Preferences/com.apple.springboard.plist"
            let prefs = try N72Board.bakePrefs(v, dir: user.library + "/Preferences")
            derived["prefs"] =
                try Self.bakeNoIdleSleep(v, prefs: sbPrefs) ? prefs + "; SBDisableIdleSleep (no deep sleep)" : prefs
            if v.exists(sbPrefs) { owners.append((user.uid, sbPrefs)) }
            if let l = try SystemEdits.seedLanguage(
                v,
                "private/var",
                tag: c.o.language,
                keyboards: c.o.keyboards,
                catalog: SystemEdits.KeyboardCatalog(v),
                formats: SystemEdits.regionFormats(v)
            ) {
                derived["language"] = "\(l.language), region \(l.locale), keyboards \(l.keyboards)"
            }
            let (report, record, owned) = try Self.bake(
                v,
                helpers: c.o.guestTools,
                gles: recipe.options["gles_shim"] ?? true,
                fit: c.fit,
                log: c.log
            )
            for (k, v) in report { derived[k] = v }
            c.guestPackage = record
            owners += owned.map { (0, $0) }
            return (try SystemEdits.activate(v, log: c.log), removed)
        }
        c.activation = activation
        derived["launch_daemons_removed"] = removed
        let hfs = try HFSPlusVolume(volume, writable: true)
        for (uid, paths) in Dictionary(grouping: owners, by: \.0) {
            c.log("\(uid):\(uid) patched \(try hfs.setOwner(paths.map(\.1), uid: uid, gid: uid)) catalog record(s)")
        }
        c.log("\(try hfs.normalize(after: newest, to: newest)) catalog records dated as of the IPSW's newest file")
    }

    /// `body` over the 1.x root (VolumeMount.withVolume), journaled first. One partition, so the root holds what a
    /// device keeps in its journaled /private/var: journaled, so a hard power-off is replayed at mount (the stock root
    /// is unjournaled and 1.x runs no fsck or update). FirmwareKit places the journal on the unmounted volume
    /// (HFSPlusWriter.enableJournal, left for the device's first mount to initialize), not `diskutil enableJournal`
    /// on the mount: the kernel put that journal after whatever it had allocated by then, fseventsd's event logs
    /// included (removed with the junk before unmounting), and how many fseventsd had written varied by host and run,
    /// so the journal moved a block or two. A mount keeps the journal where it is and puts its bytes back
    /// (VolumeMount.withMounted).
    nonisolated(nonsending) static func withJournaledRoot<T>(
        _ volume: URL,
        at mountPoint: URL,
        date: UInt32,
        _ body: (any VolumeFiles) async throws -> T
    ) async throws -> T {
        let w = try HFSPlusWriter(volume)
        try w.enableJournal()
        try w.close()
        return try await VolumeMount.withVolume(volume, at: mountPoint, date: date, body)
    }

    /// ipod1g_device.bake over the 1.x system volume `v`: the GL front end if the stock OpenGLES exports exactly
    /// opengles-1x.exports (and `gles`), the seed package (GuestPackage.seed of armv6.itpack: the loader and n45-ios1),
    /// SpringBoard's LK_* environment. Returns (the lock's derived gles/gles_engine, the guest_package record, the
    /// volume-relative paths to make root-owned).
    static func bake(
        _ v: any VolumeFiles,
        helpers: URL,
        gles: Bool,
        fit: FitCheck.Log = FitCheck.Log(),
        log: (String) -> Void
    )
        throws -> ([String: Any], GuestPackage.Record, [String])
    {
        var front = false
        var report: [String: Any] = [:]
        if gles {
            let (ok, line) = try N72Board.frontEnd(
                try? v.contents(at: N72Board.openGLES),
                exports: helpers.appendingPathComponent(openGLESExports)
            )
            front = ok
            report["gles"] = line + (ok ? "; LayerKit composites through it (LK_ENABLE_OGL=1)" : "; software LayerKit")
        } else {
            report["gles"] = "gles off; software LayerKit"
        }
        let (seeded, record) = try SystemEdits.seedGuestPackage(
            v,
            helpers: helpers,
            arch: "armv6",
            gles: front,
            fit: fit,
            log: log
        )
        if front, !record.hooks.contains("/" + N72Board.openGLES) {
            // LK_ENABLE_OGL=1 over the stock IMG driver drives the MBX's tile accelerator, which qemu-ios doesn't
            // model: fail rather than wedge
            throw FirmwareError(
                .internal,
                "\(SystemEdits.Helpers.itpack("armv6")) has no OpenGLES hook for this build; rebuild the guest package"
            )
        }
        if front {
            try fit.check(
                FitCheck.environment(
                    FitCheck.Firmware(volume: v, arch: "armv6"),
                    [["LK_ENABLE_OGL"], ["LK_AUTO_ENABLE_OGL"]]
                ),
                required: false,
                outcome: "kept: a switch nothing reads is inert"
            )
        }
        try SystemEdits.editSpringBoardJob(v) { env, _ in
            if front {
                env["LK_ENABLE_OGL"] = "1"
                env["LK_AUTO_ENABLE_OGL"] = "0"
            } else {
                env.removeObjects(forKeys: ["LK_ENABLE_OGL", "LK_AUTO_ENABLE_OGL"])
            }
        }
        report["gles_engine"] = front ? "OpenGLES" : NSNull()
        log("bake: \(report)")
        return (report, record, [SystemEdits.springBoardJob] + seeded)
    }

    nonisolated(nonsending) func store(_ c: Recipe.Context) async throws {
        let volume = try self.volume.filled("the system volume")
        let fil = try N45NAND.filID(iBoot: Data(contentsOf: c.file("iBoot.bin")))  // host file
        let (written, meta) = try N45NAND.write(volume: volume, out: c.nand, filID: fil, banks: banks, bbtMap: iPhone)
        c.log(
            "\(written) filesystem pages, \(meta) metadata pages generated (NAND signature 0x\(String(fil, radix: 16)))"
        )
        try FileManager.default.removeItem(at: volume)  // host file
    }

    func lock(_ c: Recipe.Context) throws -> [String: Any] {
        let ident = try self.ident.filled("the identity")
        return [
            "inputs": [
                "kernelcache": kcMember, "iboot": prefix + "iBoot.\(c.e.board).RELEASE.img2", "all_flash": prefix
            ],
            "outputs": [
                "nand": ["pages": c.nandHashes.count], "nor": try Recipe.fileRecord(c, "nor.bin"),
                "iboot": try Recipe.fileRecord(c, "iBoot.bin")
            ],
            "derived": derived,
            // The 88W8686's EEPROM MAC (qemu-ios iPod-Touch-1G wifi-mac): the card the driver reads it from is
            // the same unit whose nvram wifiaddr iBoot copies into the DT (N45NOR), so both carry the identity's.
            "machine": ["wifi-mac": ident["wifi-mac"] ?? ""].merging(iPhone ? ["imei": ident["imei"] ?? ""] : [:]) {
                a,
                _ in a
            }
        ]
    }
}
