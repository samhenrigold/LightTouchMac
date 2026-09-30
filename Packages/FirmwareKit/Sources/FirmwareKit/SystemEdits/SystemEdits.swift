// SystemEdits: the edits a prepared system volume gets, shared by every board (the PAC, AppSync, the SpringBoard
// job, activation, the guest-package seed; helper names and the dyld cache by arch), and the k48 recipe's
// system and data volumes (buildK48). Ports ipad1_rootfs.py build (pristine base, no stash, no Lockdown) +
// bake --seal as ipad1_device.build drives them, in one mount of the system volume:
//
//   system.img  the IPSW rootfs, grown to partition 1; rw fstab; SpringBoard env (GL CoreAnimation or
//               CA_ENABLE_OGL=0) + stdio on /dev/console; [appsync] libappsync.dylib injected into installd +
//               the shared-cache MISValidateSignature patch; [ca_ogl] the GL shim as GLEngine (+ the gld plugin
//               and dyld's override switch on 4.x); [web_proxy] the PAC; the guest helpers; storage_mounter loads
//               it_msmquiet; BTServer Disabled; lockdownd activated (Activation); the guest-package loader and
//               seed package from armv7.itpack (GuestPackage.seed), whose jobs it_boot loads.
//   data.img    fresh journaled HFSX "Data" (sparse) seeded with the system volume's /private/var skeleton
//               (+ [usb_net] the en1 DHCP service, [web_proxy] the en0 AirPort service with the PAC), owners
//               from the source catalog, else root / mobile by rule.
//
// Owners: the mount is noowners, so every file written lands as the host user; the catalog records are
// patched offline afterwards (HFSPlusVolume.setOwner), as the oracle does.
//
//   let r = try SystemEdits.buildK48(rootfs: dmg, work: dir, systemBytes: p1 * 4096, dataBytes: p2 * 4096,
//                                    options: .init(recipe: entry.recipe!), helpers: guestTools) { print($0) }
//   r.system, r.data, r.activation
//
// `helpers` is a flat directory of prebuilt, signed files (the app bundles it; see `Helpers`).

import Foundation

public enum SystemEdits {
    /// The recipe options SystemEdits reads (FirmwareEntry.Recipe.options), plus bake's switches.
    public struct Options: Sendable, Equatable {
        public var caOGL = true, appsync = false, webProxy = true, usbNet = true
        /// bake --seal: the one-shot clean halt the seal step needs (always on for a prepared device).
        public var seal = true
        /// bake --gl-test: the GL fixture job (test devices only).
        public var glTest = false
        public init() {}
        public init(recipe: FirmwareEntry.Recipe) {
            let o = recipe.options
            caOGL = o["ca_ogl"] ?? true; appsync = o["appsync"] ?? false
            webProxy = o["web_proxy"] ?? true; usbNet = o["usb_net"] ?? true
        }
    }

    /// What the helpers directory holds, by file name (flat).
    public enum Helpers {
        /// guest tool -> (install path, mode); ipad1_rootfs.TOOLS (+ SEAL_TOOL, GLTEST_TOOL).
        public static let tools: [(name: String, path: String, mode: mode_t)] = [
            ("it_pbd", "usr/local/bin/it_pbd", 0o755), ("it_ethlink", "usr/local/bin/it_ethlink", 0o755),
            ("it_prefs", "usr/local/bin/it_prefs", 0o755), ("it_msmquiet.dylib", "usr/local/lib/it_msmquiet.dylib", 0o755)]
        public static let seal = ("it_seal", "usr/local/bin/it_seal", mode_t(0o755))
        public static let glTest = ("it_gltest", "usr/local/bin/it_gltest", mode_t(0o755))
        /// launchd job file names baked into System/Library/LaunchDaemons (mode 0644). The helpers' own jobs
        /// (it-pbd, it-ethlink, it-prefs) are the seed package's, loaded by it_boot.
        public static let jobs: [String] = []
        /// The guest packages and the loader (qemu-ios contrib/guest-package/build.sh), one per arch.
        public static let itpack = "armv7.itpack"
        public static func itpack(_ arch: String) -> String { arch + ".itpack" }
        /// A helper built for `arch`: the armv7 build keeps the bare name, the others carry the arch
        /// (it_prefs-armv6, it_keybag-armv6).
        public static func name(_ base: String, _ arch: String) -> String { arch == "armv7" ? base : base + "-" + arch }
        public static let sealJob = "com.qemu.it-seal.plist", glTestJob = "com.qemu.it-gltest.plist"
        /// The fat armv6+armv7 AppSync dylib.
        public static let appsync = "libappsync.dylib", appsyncLauncher = "appsync-launch"
        /// The GL shims, one per arch (they read the firmware's dispatch layout at load), and the name table
        /// they speak (a reference artifact: the install logs which of the firmware's fields it lacks).
        public static let glEngine = "GLEngine", mbxEngine = "MBXGLEngine", glesNames = "gles-names.h"
        /// The gld plugin 4.x's libGFXShared loads.
        public static let gld = "GLRendererFloatQEMU"
    }

    public struct Result: Sendable {
        public var system: URL, data: URL
        public var activation: Activation.Result?
        /// The GLEngine installed (helpers file name), if any.
        public var engine: String?
        /// The seed package baked (GuestPackage.seed's record: the lock's guest_package).
        public var guestPackage: GuestPackage.Record?
        public var notes: [String] = []
    }

    // Volume paths (ipad1_rootfs constants).
    static let fstab = "private/etc/fstab"
    static let fstabRW = "/dev/disk0s1 / hfs rw 0 1\n/dev/disk0s2 /private/var hfs rw,nosuid,nodev 0 2\n"
    static let daemons = "System/Library/LaunchDaemons"
    static let springBoardJob = daemons + "/com.apple.SpringBoard.plist"
    static let msmJob = daemons + "/com.apple.mobile.storage_mounter.plist"
    /// The stock jobs that raise the USB "not supported" notice for a device nothing claims (the emulated keyboard):
    /// MobileStorageMounter through 4.x; 5.x moved it to USBDeviceArbitrator, LaunchBuddy's catch-all for IOUSBDevice.
    static let noticeJobs = [(msmJob, "com.apple.mobile.storage_mounter"),
                             (daemons + "/com.apple.mobile.usb_device_arbitrator.plist", "com.apple.mobile.usb_device_arbitrator")]
    static let btJob = daemons + "/com.apple.BTServer.plist"
    static let installdJob = daemons + "/com.apple.mobile.installd.plist"
    static let appsyncPath = "usr/lib/libappsync.dylib", appsyncLauncherPath = "usr/libexec/appsync-launch"
    static let glEngine = "System/Library/Frameworks/OpenGLES.framework/GLEngine.bundle/GLEngine"
    static let gldPath = "System/Library/Frameworks/OpenGLES.framework/GLRendererFloatQEMU.bundle/GLRendererFloatQEMU"
    static func dyldCache(_ arch: String) -> String { "System/Library/Caches/com.apple.dyld/dyld_shared_cache_" + arch }
    static let dyldOverride = "System/Library/Caches/com.apple.dyld/enable-dylibs-to-override-cache"
    static let lockdownd = "usr/libexec/lockdownd"
    static let retired = ["usr/local/bin/it_notip", daemons + "/com.qemu.it-notip.plist"]
    static let pacPath = "usr/local/share/ltm/proxy.pac"
    static let pac = """
        function FindProxyForURL(url, host) {
            if (isPlainHostName(host)) return "DIRECT";
            if (/^\\d+\\.\\d+\\.\\d+\\.\\d+$/.test(host) &&
                (isInNet(host, "10.0.0.0", "255.0.0.0") || isInNet(host, "172.16.0.0", "255.240.0.0") ||
                 isInNet(host, "192.168.0.0", "255.255.0.0") || isInNet(host, "169.254.0.0", "255.255.0.0") ||
                 isInNet(host, "127.0.0.0", "255.0.0.0"))) return "DIRECT";
            return "PROXY 10.0.2.100:3128; DIRECT";
        }

        """
    static let sbEnv = ["CA_ENABLE_OGL": "0", "MBX2D_PAGE_FLIP": "0"]
    static let sbEnvCAOGL = ["MBX2D_PAGE_FLIP": "0", "GLI_ACCELERATED": "1"]
    static let mobileTop: Set<String> = ["mobile", "ea"]   // uid 501 on the real unit; the rest of /var is root

    /// The k48 system + data volumes into `work` (system.img, data.img; scratch next to them).
    /// `rootfs` is the decrypted rootfs DMG (or a bare HFS volume); `systemBytes`/`dataBytes` are partition
    /// 1 and 2 of the MBR in bytes. `kernel`: the decrypted kernelcache the fit checks read.
    /// The path the K48 iBoot loads the kernel from (fsboot); the raw IPSW img3 kernelcache is installed there
    /// for the real-iBoot chain (ipad1_rootfs.build --kernelcache). kboot omits it (the kernel is in the bundle).
    public static let kernelcachePath = "System/Library/Caches/com.apple.kernelcaches/kernelcache"

    public static func buildK48(rootfs: URL, work: URL, systemBytes: Int, dataBytes: Int64, options o: Options, helpers: URL,
                                kernelcache: Data? = nil, kernel: Data? = nil, dataVolumeUUID: [UInt8]? = nil, fit: FitCheck.Log = FitCheck.Log(),
                                log: (String) -> Void = { _ in }) throws -> Result {
        let fm = FileManager.default
        let system = work.appendingPathComponent("system.img"), data = work.appendingPathComponent("data.img")
        var result = Result(system: system, data: data)
        func helper(_ name: String) throws -> URL {
            let u = helpers.appendingPathComponent(name)
            guard fm.fileExists(atPath: u.path) else { throw FirmwareError(.internal, "guest helper \(name) missing from \(helpers.path)") }
            return u
        }

        // Check every helper before touching a volume.
        var tools = Helpers.tools, jobs = Helpers.jobs
        if o.seal { tools.append(Helpers.seal); jobs.append(Helpers.sealJob) }
        if o.glTest { tools.append(Helpers.glTest); jobs.append(Helpers.glTestJob) }
        for t in tools {
            if let why = MachOSignature.guestToolProblem(try helper(t.name)) {
                throw FirmwareError(.internal, "\(helpers.path)/\(t.name): \(why)")
            }
        }
        for j in jobs { _ = try helper(j) }
        _ = try helper(Helpers.itpack("armv7"))
        if o.appsync, let why = MachOSignature.appSyncProblem(try helper(Helpers.appsync)) {
            throw FirmwareError(.internal, "\(helpers.path)/\(Helpers.appsync): \(why)")
        }

        log("system volume from \(rootfs.lastPathComponent)")
        try UDIF.extractRootfs(dmg: rootfs, to: system)
        let newest: UInt32   // the IPSW's newest file: everything the recipe writes gets dated as of it
        do {
            let v = try HFSPlusVolume(system)
            guard v.totalBlocks * v.blockSize <= systemBytes else {
                throw FirmwareError(.unsupported, "system volume (\(v.totalBlocks * v.blockSize) bytes) is larger than partition 1 (\(systemBytes))")
            }
            log("\(v.signature) \(v.totalBlocks) x \(v.blockSize) B blocks, \(v.freeBlocks) free; partition 1 is \(systemBytes >> 20) MiB")
            newest = try v.newestDate()
        }
        try VolumeMount.grow(system, toBytes: systemBytes)

        log("editing the system volume")
        let skeleton = work.appendingPathComponent("var-skeleton")
        try? fm.removeItem(at: skeleton)
        var rootOwned: [String] = []
        try VolumeMount.withMounted(system, at: work.appendingPathComponent("mnt-system")) { m in
            let at = { (rel: String) in m.appendingPathComponent(rel) }
            // every baked helper proven to load on this firmware (FitCheck.loads), read before any edit
            let fw = FitCheck.Firmware(root: m, arch: "armv7", kernelcache: kernel)
            _ = fw.precedent
            // it_msmquiet only where the mounter raises the notice it recognises; else left out, job untouched
            let msm = Helpers.tools[3]
            var quietJobs: [(String, String)] = []
            for (job, label) in noticeJobs where job == msmJob || fm.fileExists(atPath: at(job).path) {
                if try fit.check(FitCheck.msmQuiet(fw, program: try stockProgram(m, job, label: label),
                                                   dylib: Data(contentsOf: try helper(msm.name))), required: false) {
                    quietJobs.append((job, label))
                }
            }
            let quiet = !quietJobs.isEmpty
            if !quiet { tools.removeAll { $0.name == msm.name } }
            for f in FitCheck.prefs(fw, FitCheck.itPrefs) { try fit.check(f, required: false, outcome: "kept: it_prefs skips the key at boot") }
            if o.usbNet { try fit.check(FitCheck.usbEthernet(fw, path: usbEthPath), required: false, outcome: "kept: the link stays down and en1 unpinned") }
            for t in tools where t.name != msm.name {
                try fit.check(FitCheck.loads(t.name, Data(contentsOf: try helper(t.name)), on: fw), required: true)
            }
            if o.appsync { try FitCheck.checkAppSync(fit, fw, helpers: helpers) } else { fit.notInstalled("AppSync", "appsync off") }
            if let kernelcache {   // real-iBoot fsboot: the raw IPSW img3 kernelcache in the system volume
                try mkdirs(at(kernelcachePath).deletingLastPathComponent())
                try put(kernelcache, at(kernelcachePath), mode: 0o644)
            }
            try put(Data(fstabRW.utf8), at(fstab))
            if o.webProxy {
                try fit.check(FitCheck.webProxy(FitCheck.Firmware(root: m, arch: "armv7")), required: false, outcome: "kept: the PAC is unused")
                rootOwned += try installPAC(m)
            }
            if o.caOGL {   // GL first
                let (engine, owned) = try installCAOGL(m, helpers: helpers, log: log)
                result.engine = engine
                rootOwned += owned
            }
            let env = o.caOGL ? sbEnvCAOGL : sbEnv
            try fit.check(FitCheck.environment(fw, env.keys.sorted().map { [$0] },
                                               also: result.engine != nil ? [(Helpers.glEngine, try Data(contentsOf: helper(Helpers.glEngine)))] : []),
                          required: false, outcome: "kept: a switch nothing reads is inert")
            try editSpringBoardJob(m) { env, d in
                env.addEntries(from: o.caOGL ? sbEnvCAOGL : sbEnv)
                d["StandardOutPath"] = "/dev/console"; d["StandardErrorPath"] = "/dev/console"
            }
            if o.appsync {
                _ = try installAppSync(m, helper: try helper(Helpers.appsync), cache: dyldCache("armv7"), log: log)
                rootOwned.append(appsyncPath)
            }
            // bake
            for rel in retired where (try? fm.destinationOfSymbolicLink(atPath: at(rel).path)) != nil || fm.fileExists(atPath: at(rel).path) {
                try fm.removeItem(at: at(rel))
            }
            for t in tools {
                try mkdirs(at(t.path).deletingLastPathComponent())
                try put(Data(contentsOf: try helper(t.name)), at(t.path), mode: t.mode)
            }
            for j in jobs { try put(Data(contentsOf: try helper(j)), at(daemons + "/" + j), mode: 0o644) }
            for (job, label) in quietJobs {
                try rewritePlist(at(job)) { d in
                    guard d["Label"] as? String == label else { throw FirmwareError(.unsupported, "\(job): not \(label)'s job") }
                    dict(d, "EnvironmentVariables")["DYLD_INSERT_LIBRARIES"] = "/" + msm.path
                }
            }
            try rewritePlist(at(btJob)) { $0["Disabled"] = true }
            result.activation = try activate(m, log: log)
            rootOwned.append(lockdownd)
            // what this bake left out on purpose: AppSync when off, it_msmquiet where it does not fit
            let omitted = Set((o.appsync ? [] : ["/" + appsyncPath]) + (quiet ? [] : ["/" + msm.path]))
            let (seeded, record) = try seedGuestPackage(m, helpers: helpers, arch: "armv7", gles: result.engine != nil, omitted: omitted, fit: fit, log: log)
            result.guestPackage = record
            rootOwned += seeded
            rootOwned += ["usr/local", "usr/local/bin", "usr/local/lib"].filter { fm.fileExists(atPath: at($0).path) } + jobs.map { daemons + "/" + $0 } + tools.map(\.path)

            // /private/var skeleton for the data volume
            try copyTree(at("private/var"), skeleton)
        }
        let sys = try HFSPlusVolume(system, writable: true)
        let n = try sys.setOwner(rootOwned, uid: 0, gid: 0)
        let owners = try sys.owners(under: "private/var")
        let dated = try sys.normalize(after: newest, to: newest)
        log("system volume: \(n) catalog records set to root, \(dated) dated as of the IPSW's newest file")

        log("data volume (\(dataBytes / 1_000_000) MB, sparse) seeded from /private/var")
        defer { try? fm.removeItem(at: skeleton) }
        let sc = skeleton.appendingPathComponent("preferences/SystemConfiguration")
        // USB Ethernet first, then Wi-Fi: each moves its service to the head of the order, and the Wi-Fi
        // service (carrying the PAC) must stay primary.
        if o.usbNet {
            try seedPlist(sc.appendingPathComponent("NetworkInterfaces.plist"), usbNetInterfaces)
            try seedPlist(sc.appendingPathComponent("preferences.plist"), usbNetPrefs)
        }
        if o.webProxy { try seedPlist(sc.appendingPathComponent("preferences.plist"), wifiProxyPrefs) }
        try? fm.removeItem(at: data)
        try VolumeMount.makeHFS(data, size: dataBytes)
        var byOwner: [[UInt32]: [String]] = [:]
        try VolumeMount.withMounted(data, at: work.appendingPathComponent("mnt-data")) { m in
            try copyTree(skeleton, m)   // merges into the root, which takes /private/var's mode
            try walk(m) { rel in
                let own: [UInt32] = owners[rel].map { [$0.uid, $0.gid] } ?? (mobileTop.contains(String(rel.prefix { $0 != "/" })) ? [501, 501] : [0, 0])
                byOwner[own, default: []].append(rel)
            }
        }
        let dv = try HFSPlusVolume(data, writable: true)
        var patched = 0
        for (own, paths) in byOwner.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
            patched += try dv.setOwner(paths, uid: own[0], gid: own[1])
        }
        let summary = byOwner.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map { "\($0.key[0]):\($0.key[1]) x\($0.value.count)" }
        log("owners from the skeleton, else root / mobile by rule: \(summary.joined(separator: ", ")) (\(patched) catalog records patched)")
        try dv.normalize(after: newest, to: newest, uuid: dataVolumeUUID)
        for d in ["mnt-system", "mnt-data"] { try? fm.removeItem(at: work.appendingPathComponent(d)) }
        return result
    }

    // MARK: the shared bake (every board's system volume)

    /// The web-proxy PAC at /usr/local/share/ltm/proxy.pac; `dirs` are created too (the iPod's SystemConfiguration
    /// on the system volume). Returns the paths to make root-owned.
    static func installPAC(_ m: URL, dirs: [String] = []) throws -> [String] {
        var owned: [String] = []
        for rel in ["usr/local", "usr/local/share", "usr/local/share/ltm"] + dirs {
            try mkdirs(m.appendingPathComponent(rel))
            owned.append(rel)
        }
        try put(Data(pac.utf8), m.appendingPathComponent(pacPath))
        return owned + [pacPath]
    }

    /// Patch cached signature validation where available, then inject the
    /// helper into the firmware's installation service (installd or mobile_installation_proxy).
    static func installAppSync(_ m: URL, helper: URL, cache: String, log: (String) -> Void) throws -> (status: String, job: String) {
        let fm = FileManager.default
        let cached = fm.fileExists(atPath: m.appendingPathComponent(cache).path)
        if !cached, let why = MachOSignature.earlyARMProblem(helper) {
            throw FirmwareError(.unsupported, "AppSync: \(why)")
        }
        let line = cached ? try AppSyncCachePatch.patchCache(at: m.appendingPathComponent(cache))
            : "standalone libmis retained; installation-service interposition"
        log(line)
        try mkdirs(m.appendingPathComponent(appsyncPath).deletingLastPathComponent())
        try put(Data(contentsOf: helper), m.appendingPathComponent(appsyncPath), mode: 0o644)
        let job = ["com.apple.mobile.installd.plist", "com.apple.installd.plist"].map { m.appendingPathComponent(daemons + "/" + $0) }
            .first { fm.fileExists(atPath: $0.path) }
        if let job {
            try rewritePlist(job) { dyldInsert($0, "/" + appsyncPath) }
            return (line, job.lastPathComponent)
        }
        // 2.x installs in the Lockdown-launched mobile_installation_proxy, before installd existed.
        let services = m.appendingPathComponent("System/Library/Lockdown/Services.plist")
        try rewritePlist(services) { root in
            guard let service = root["com.apple.mobile.installation_proxy"] as? NSMutableDictionary,
                  let arguments = service["ProgramArguments"] as? [String], arguments.first == "/usr/libexec/mobile_installation_proxy" else {
                throw FirmwareError(.unsupported, "no supported installation service")
            }
            let launcher = helper.deletingLastPathComponent().appendingPathComponent(Helpers.appsyncLauncher)
            if let why = MachOSignature.earlyARMProblem(launcher) {
                throw FirmwareError(.unsupported, "AppSync launcher: \(why)")
            }
            try put(Data(contentsOf: launcher), m.appendingPathComponent(appsyncLauncherPath), mode: 0o755)
            service["ProgramArguments"] = ["/" + appsyncLauncherPath] + arguments
        }
        return (line, "Services.plist:com.apple.mobile.installation_proxy")
    }

    /// The program of the stock job `job` (volume-relative), checked by label.
    static func stockProgram(_ m: URL, _ job: String, label: String) throws -> String {
        guard let d = NSDictionary(contentsOf: m.appendingPathComponent(job)), d["Label"] as? String == label,
              let program = (d["ProgramArguments"] as? [String])?.first ?? d["Program"] as? String else {
            throw FirmwareError(.unsupported, "\(job): not \(label)'s job")
        }
        return program
    }

    /// SpringBoard's launchd job, checked by label: `edit` gets its EnvironmentVariables and the job.
    static func editSpringBoardJob(_ m: URL, _ edit: (NSMutableDictionary, NSMutableDictionary) throws -> Void) throws {
        try rewritePlist(m.appendingPathComponent(springBoardJob)) { d in
            guard d["Label"] as? String == "com.apple.SpringBoard" else { throw FirmwareError(.unsupported, "\(springBoardJob): not SpringBoard's job") }
            try edit(dict(d, "EnvironmentVariables"), d)
        }
    }

    /// lockdownd activated in place (Activation); the caller makes it root-owned.
    static func activate(_ m: URL, log: (String) -> Void) throws -> Activation.Result {
        log("Activating device")
        return try Activation.run(on: m.appendingPathComponent(lockdownd))
    }

    /// The guest-package loader and the arch's seed package (GuestPackage.seed of <arch>.itpack).
    static func seedGuestPackage(_ m: URL, helpers: URL, arch: String, gles: Bool, omitted: Set<String> = [], fit: FitCheck.Log, log: (String) -> Void) throws -> ([String], GuestPackage.Record) {
        let (seeded, record) = try GuestPackage.seed(volume: m, itpack: helpers.appendingPathComponent(Helpers.itpack(arch)), gles: gles,
                                                     omitted: omitted, fit: fit)
        log("seed package \(record.family) serial \(record.seed), hooks \(record.hooks)")
        return (seeded, record)
    }

    /// [ca_ogl] installGL for a recipe that asks SpringBoard to composite through the GL bridge; returns the engine
    /// and the files to own by root. A firmware the shim cannot serve (a gld plugin that does not fit) fails the
    /// prepare, as ipad1_rootfs.py build does, rather than quietly producing a software-CoreAnimation device.
    static func installCAOGL(_ m: URL, helpers: URL, log: (String) -> Void) throws -> (engine: String, owned: [String]) {
        do {
            let (engine, gld, overridden) = try installGL(m, helpers: helpers, log: log)
            return (engine, [glEngine] + (overridden ? [dyldOverride] : [])
                            + (gld ? [(gldPath as NSString).deletingLastPathComponent, gldPath] : []))
        } catch let e as FirmwareError where e.code == .unsupported {
            throw FirmwareError(.unsupported, "the recipe asks for GL CoreAnimation (ca_ogl) and this firmware cannot "
                                + "composite through the GL bridge: \(e.message)")
        }
    }

    /// The GL shim as GLEngine (+ the gld plugin when this firmware's EAGL needs one, + dyld's override switch
    /// when GLEngine is in the shared cache). Returns (engine helper name, gld installed, override switch set).
    static func installGL(_ m: URL, helpers: URL, log: (String) -> Void) throws -> (String, Bool, Bool) {
        let fm = FileManager.default
        let (gld, cached): (Bool, Bool) = try autoreleasepool {
            let cache = try DyldSharedCache(contentsOf: m.appendingPathComponent(dyldCache("armv7")))
            log(glesSanity(cache.data, helpers: helpers))
            let (needed, gwhy) = GLIDispatch.gldProblem(cache, plugin: helpers.appendingPathComponent(Helpers.gld))
            if let gwhy { throw FirmwareError(.unsupported, "gld plugin does not fit this firmware: \(gwhy)") }
            return (needed, cache.image("/" + glEngine) != nil)
        }
        let engine = Helpers.glEngine, src = helpers.appendingPathComponent(engine)
        guard fm.fileExists(atPath: src.path) else { throw FirmwareError(.internal, "\(src.path) missing") }
        var overridden = false
        if cached {   // 4.x: dyld's own switch lets the file on disk win over the cached image
            try setOverrideSwitch(m, image: glEngine)
            overridden = true
        }
        log("GL engine \(engine)\(gld ? " + gld plugin" : ""); \(overridden ? "cached GLEngine overridden by the file" : "no cached GLEngine")")
        try put(Data(contentsOf: src), m.appendingPathComponent(glEngine), mode: try permissions(src))
        if gld {
            let plugin = helpers.appendingPathComponent(Helpers.gld)
            try mkdirs(m.appendingPathComponent(gldPath).deletingLastPathComponent())
            try put(Data(contentsOf: plugin), m.appendingPathComponent(gldPath), mode: try permissions(plugin))
        }
        return (engine, gld, overridden)
    }

    /// ipad1_rootfs.gli_dispatch_info: the sanity line about what the shim will find at load (the firmware's
    /// dispatch slot count, and the fields the shipped name table, gles-names.h in the helpers, does not name).
    static func glesSanity(_ cache: Data, helpers: URL) -> String {
        guard let have = GLIDispatch.fields(in: cache) else {
            return "no __GLIFunctionDispatchRec @encode in the shared cache: the shim will read OpenGLES's trampolines"
        }
        let names = (try? String(contentsOf: helpers.appendingPathComponent(Helpers.glesNames), encoding: .utf8)) ?? ""
        let known = Set(names.matches(of: /(?m)^GLES_FN\(\w+,\s*(\w+),/).map { String($0.1) })
        let unknown = have.filter { !known.contains($0) }
        return "GLI dispatch: \(have.count) slots, \(unknown.count) unknown to the name table"
            + (unknown.isEmpty ? "" : " (\(unknown.prefix(8).joined(separator: ", ")))")
    }

    /// ipad1_rootfs.gli_uncache: when `image` is in the volume's shared cache `cache`, create dyld's
    /// enable-dylibs-to-override-cache switch so the file installed over it loads. Returns the status line.
    static func overrideCachedImage(_ m: URL, image: String, cache: String) throws -> String {
        let name = (image as NSString).lastPathComponent
        guard try DyldSharedCache(contentsOf: m.appendingPathComponent(cache)).image("/" + image) != nil else { return "no cached \(name)" }
        try setOverrideSwitch(m, image: image)
        return "cached \(name) overridden by the file (enable-dylibs-to-override-cache)"
    }

    /// Fails closed if this dyld has no such switch.
    static func setOverrideSwitch(_ m: URL, image: String) throws {
        let dyld = try Data(contentsOf: m.appendingPathComponent("usr/lib/dyld"))
        guard dyld.range(of: Data(("/" + dyldOverride + "\0").utf8)) != nil else {
            throw FirmwareError(.unsupported, "\((image as NSString).lastPathComponent) is in the shared cache and this dyld has no enable-dylibs-to-override-cache switch: the GL shim cannot load")
        }
        let dir = m.appendingPathComponent(dyldOverride).deletingLastPathComponent().path
        var st = stat()
        guard stat(dir, &st) == 0, chmod(dir, st.st_mode & 0o7777 | 0o200) == 0 else { throw FirmwareError(.internal, "chmod \(dir)") }
        try put(Data(), m.appendingPathComponent(dyldOverride))
        chmod(dir, st.st_mode & 0o7777)
    }

    // MARK: plist edits (ipad1_rootfs.springboard_env, dyld_insert, usb_net_*, wifi_proxy_prefs)

    /// d[k] as a mutable dictionary, inserting `def` when absent (Python's setdefault).
    @discardableResult
    static func dict(_ d: NSMutableDictionary, _ k: String, _ def: @autoclosure () -> NSMutableDictionary = NSMutableDictionary()) -> NSMutableDictionary {
        if let v = d[k] as? NSMutableDictionary { return v }
        let v = (d[k] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary ?? def()
        d[k] = v
        return v
    }

    static func moveFirst(_ d: NSMutableDictionary, _ k: String, _ item: String) {
        d[k] = [item] + ((d[k] as? [Any]) ?? []).filter { ($0 as? String) != item }
    }

    static func dyldInsert(_ d: NSMutableDictionary, _ lib: String) {
        let env = dict(d, "EnvironmentVariables")
        var libs = ((env["DYLD_INSERT_LIBRARIES"] as? String) ?? "").split(separator: ":").map(String.init)
        if !libs.contains(lib) { libs.append(lib) }
        env["DYLD_INSERT_LIBRARIES"] = libs.joined(separator: ":")
    }

    static let usbEthService = "4C54E7A1-0B5E-4D6B-9A1C-5553424E4554", netSet = "4C54E7A1-0B5E-4D6B-9A1C-534554000001"
    static let wifiService = "4C54E7A1-0B5E-4D6B-9A1C-574946490000"
    static let usbEthPath = "IOService:/AppleARMPE/arm-io@BFC00000/AppleS5L8930XIO/usb-complex@3F108000/"
        + "AppleS5L8930XUSBArbitrator/usb-device/AppleSynopsysOTGDevice/IOUSBDeviceInterface@5/AppleUSBEthernetDevice/IOEthernetInterface"

    /// NetworkInterfaces.plist: the USB Ethernet interface pinned to en1.
    static func usbNetInterfaces(_ d: NSMutableDictionary) {
        let usb: NSDictionary = ["Active": true, "BSD Name": "en1", "IOBuiltin": false, "IOInterfaceType": 6, "IOInterfaceUnit": 1,
                                 "IOMACAddress": Data([0x0a, 0x0b, 0xad, 0x0b, 0xab, 0xe0]), "SCNetworkInterfaceType": "Ethernet",
                                 "IOPathMatch": usbEthPath]
        let ifs = ((d["Interfaces"] as? [Any]) ?? []).filter { (($0 as? NSDictionary)?["IOPathMatch"] as? String) != usbEthPath } + [usb]
        let unit = { (i: Any) in ((i as? NSDictionary)?["IOInterfaceUnit"] as? NSNumber)?.intValue ?? 0 }
        d["Interfaces"] = ifs.enumerated().sorted { (unit($0.element), $0.offset) < (unit($1.element), $1.offset) }.map(\.element)
    }

    /// The current set's Network dict, creating CurrentSet / Sets / the set as Python's setdefault chain does.
    static func currentNetwork(_ d: NSMutableDictionary) -> NSMutableDictionary {
        if d["CurrentSet"] == nil { d["CurrentSet"] = "/Sets/" + netSet }
        let cur = String((d["CurrentSet"] as? String ?? "").split(separator: "/", omittingEmptySubsequences: false).last ?? "")
        return dict(dict(dict(d, "Sets"), cur, NSMutableDictionary(dictionary: ["UserDefinedName": "Automatic"])), "Network")
    }

    /// preferences.plist: a DHCP service on en1, first in the current set's service order.
    static func usbNetPrefs(_ d: NSMutableDictionary) {
        dict(d, "NetworkServices")[usbEthService] = [
            "Interface": ["DeviceName": "en1", "Hardware": "Ethernet", "Type": "Ethernet", "UserDefinedName": "USB Ethernet"],
            "IPv4": ["ConfigMethod": "DHCP"], "DNS": [String: Any](), "UserDefinedName": "USB Ethernet"] as NSDictionary
        let net = currentNetwork(d)
        dict(net, "Service")[usbEthService] = ["__LINK__": "/NetworkServices/" + usbEthService]
        moveFirst(dict(dict(net, "Global"), "IPv4"), "ServiceOrder", usbEthService)
    }

    /// preferences.plist: the AirPort service on en0 (the unit's own shape) carrying the proxy PAC, first.
    static func wifiProxyPrefs(_ d: NSMutableDictionary) {
        let svc = dict(dict(d, "NetworkServices"), wifiService, NSMutableDictionary(dictionary: [
            "Interface": ["DeviceName": "en0", "Hardware": "AirPort", "Type": "Ethernet", "UserDefinedName": "AirPort"],
            "IPv4": ["ConfigMethod": "DHCP"], "IPv6": ["ConfigMethod": "Automatic"], "DNS": [String: Any](), "UserDefinedName": "AirPort"]))
        svc["Proxies"] = ["ExceptionsList": ["*.local", "169.254/16"], "FTPPassive": 1,
                          "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "file:///" + pacPath] as NSDictionary
        let net = currentNetwork(d)
        dict(net, "Service")[wifiService] = ["__LINK__": "/NetworkServices/" + wifiService]
        dict(dict(net, "Interface"), "en0", NSMutableDictionary(dictionary: ["AirPort": ["JoinMode": "Automatic"]]))
        moveFirst(dict(dict(net, "Global"), "IPv4"), "ServiceOrder", wifiService)
    }

    /// Applies `edit` to the plist at `url` in place (keeping its binary/XML format and its catalog record).
    static func rewritePlist(_ url: URL, _ edit: (NSMutableDictionary) throws -> Void) throws {
        var fmt = PropertyListSerialization.PropertyListFormat.xml
        guard let d = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: .mutableContainersAndLeaves,
                                                                 format: &fmt) as? NSMutableDictionary else {
            throw FirmwareError(.unsupported, "\(url.lastPathComponent) is not a dictionary plist")
        }
        try edit(d)
        try put(PropertyListSerialization.data(fromPropertyList: d, format: fmt == .binary ? .binary : .xml, options: 0), url)
    }

    /// Edits the plist in place, or creates it (XML, as configd writes) from an empty dictionary.
    static func seedPlist(_ url: URL, _ edit: (NSMutableDictionary) throws -> Void) throws {
        if FileManager.default.fileExists(atPath: url.path) { return try rewritePlist(url, edit) }
        try mkdirs(url.deletingLastPathComponent())
        let d = NSMutableDictionary()
        try edit(d)
        try put(PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0), url)
    }

    // MARK: files (in place, umask-default modes, as the oracle's open()/makedirs())

    /// Writes `data` into `url` in place (truncating an existing file, so it keeps its catalog record), creating
    /// it 0666 & ~umask if absent; with `mode`, then sets the permission bits.
    static func put(_ data: Data, _ url: URL, mode: mode_t? = nil) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o666)
        guard fd >= 0 else { throw FirmwareError(.internal, "open \(url.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        let n = data.withUnsafeBytes { data.isEmpty ? 0 : write(fd, $0.baseAddress, $0.count) }
        guard n == data.count else { throw FirmwareError(.internal, "write \(url.path): \(String(cString: strerror(errno)))") }
        if let mode, fchmod(fd, mode) != 0 { throw FirmwareError(.internal, "chmod \(url.path)") }
    }

    /// mkdir -p with 0777 & ~umask for each directory created.
    static func mkdirs(_ url: URL) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) { return }
        try mkdirs(url.deletingLastPathComponent())
        guard mkdir(url.path, 0o777) == 0 || errno == EEXIST else { throw FirmwareError(.internal, "mkdir \(url.path): \(String(cString: strerror(errno)))") }
    }

    static func permissions(_ url: URL) throws -> mode_t {
        var st = stat()
        guard stat(url.path, &st) == 0 else { throw FirmwareError(.internal, "stat \(url.path)") }
        return st.st_mode & 0o7777
    }

    /// shutil.copytree(symlinks=True, dirs_exist_ok=True) with copy2: symlinks as symlinks, file content
    /// written plainly (an HFS-compressed source lands uncompressed), then mode and mtime. No xattrs or flags.
    static func copyTree(_ src: URL, _ dst: URL) throws {
        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: src.path)
        let keep: [FileAttributeKey: Any] = [.posixPermissions: attrs[.posixPermissions] ?? 0o644, .modificationDate: attrs[.modificationDate] ?? Date()]
        switch attrs[.type] as? FileAttributeType {
        case .typeSymbolicLink?:
            try fm.createSymbolicLink(atPath: dst.path, withDestinationPath: fm.destinationOfSymbolicLink(atPath: src.path))
            return
        case .typeDirectory?:
            if !fm.fileExists(atPath: dst.path) {
                guard mkdir(dst.path, 0o777) == 0 else { throw FirmwareError(.internal, "mkdir \(dst.path): \(String(cString: strerror(errno)))") }
            }
            for n in try fm.contentsOfDirectory(atPath: src.path) { try copyTree(src.appendingPathComponent(n), dst.appendingPathComponent(n)) }
        default:
            try put(Data(contentsOf: src), dst)
        }
        try fm.setAttributes(keep, ofItemAtPath: dst.path)
    }

    /// Every path under `root` (relative, directories and symlinks included), skipping macOS junk at any level.
    static func walk(_ root: URL, _ body: (String) throws -> Void) throws {
        guard let e = FileManager.default.enumerator(atPath: root.path) else { return }
        while let rel = e.nextObject() as? String {
            if VolumeMount.junk.contains((rel as NSString).lastPathComponent) {
                if (e.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory { e.skipDescendants() }
                continue
            }
            try body(rel)
        }
    }
}
