// The per-piece fit checks (FitCheck.swift has the core and the Mach-O load check). Each reads the firmware and
// returns a Fit; the recipes decide what a misfit means for their board.

import Foundation

extension FitCheck {
    /// The C string `s` as it sits in a binary's string section: NUL on both sides.
    static func cString(_ s: String) -> Data { Data(("\0" + s + "\0").utf8) }

    /// Undefined external symbols a Mach-O imports.
    static func imports(_ m: MachO32) -> Set<String> {
        Set(m.symbols().filter { MachO32.isImport($0.type) }.map(\.name))
    }

    // MARK: it_msmquiet

    /// The keys the "USB device is not supported" notice uses (contrib/it-msmquiet keys[]: 3.2.x UNSUPPORTED_FAILURE,
    /// 4.x UNSUPPORTED_FAILURE_BODY; 5.x's USBDeviceArbitrator the 4.x keys) and the calls it_msmquiet interposes.
    static let msmKeys = ["UNSUPPORTED_FAILURE", "UNSUPPORTED_FAILURE_BODY"]
    static let msmCalls = ["_CFUserNotificationDisplayNotice", "_CFUserNotificationCreate"]

    /// it_msmquiet fits when the mounter (`program`, the stock job's) raises the notice it recognises: its binary
    /// names one of the notice's keys and imports one of the calls it interposes, and the dylib loads in it.
    public static func msmQuiet(_ fw: Firmware, program: String, dylib: Data) -> Fit {
        let name = (program as NSString).lastPathComponent, piece = "it_msmquiet (\(name)'s USB \"not supported\" notice)"
        guard let bin = fw.data(program), let m = MachO32.slice(bin, arch: fw.arch)?.image else {
            return Fit(piece, fits: false, "no \(program) on this firmware")
        }
        let keys = msmKeys.filter { bin.range(of: cString($0)) != nil }, calls = msmCalls.filter(imports(m).contains)
        guard !keys.isEmpty else {
            return Fit(piece, fits: false, "\(name) names neither \(msmKeys.joined(separator: " nor ")): whatever raises this firmware's notice, it_msmquiet cannot recognise it")
        }
        guard !calls.isEmpty else { return Fit(piece, fits: false, "\(name) imports neither \(msmCalls.joined(separator: " nor ")), the calls it_msmquiet interposes") }
        let l = loads(piece, dylib, on: fw, host: program)
        guard l.fits else { return l }
        return Fit(piece, fits: true, "\(name) raises \(keys.joined(separator: ", ")) through \(calls.map { String($0.dropFirst()) }.joined(separator: ", ")); \(l.proof)")
    }

    // MARK: USB Ethernet

    /// it_ethlink and the USB Ethernet interface pinned to en1 (usb_net) fit when the kernel has every class the
    /// pinned IOPathMatch names (it_ethlink's AppleUSBEthernetDevice among them) and names LinkStatus, the property
    /// it_ethlink sets.
    public static func usbEthernet(_ fw: Firmware, path: String) -> Fit {
        let piece = "USB Ethernet (it_ethlink, en1 pinned by IOPathMatch)"
        guard let k = fw.kernelcache else { return Fit(piece, fits: false, "no decrypted kernelcache to check the classes against") }
        let classes = path.split(separator: ":", maxSplits: 1).last.map(String.init)?.split(separator: "/")
            .map { String($0.prefix { $0 != "@" }) }.filter { $0.first?.isUppercase == true } ?? []
        let missing = classes.filter { k.range(of: cString($0)) == nil }
        guard !classes.isEmpty else { return Fit(piece, fits: false, "no classes in \(path)") }
        guard missing.isEmpty else { return Fit(piece, fits: false, "the kernel has no \(missing.joined(separator: ", ")), which the en1 IOPathMatch names") }
        guard k.range(of: cString("LinkStatus")) != nil else { return Fit(piece, fits: false, "the kernel names no LinkStatus property (it_ethlink raises the link through it)") }
        return Fit(piece, fits: true, "the kernel has \(classes.joined(separator: ", ")) and names LinkStatus")
    }

    // MARK: it_prefs

    /// it_prefs' settings (contrib/it-prefs SETTINGS): the key and the binary that reads it. The iPod build
    /// (IT_PREFS_TIP_ONLY), and the bake that stands in for it on 2.x/3.0, set only the first.
    public static let itPrefs = [("SBDidShowReorderText", "System/Library/CoreServices/SpringBoard.app/SpringBoard"),
                                 ("AppleLocationServer", "usr/libexec/locationd"), ("AppleLocationServerRequiresCert", "usr/libexec/locationd")]

    /// One Fit per setting: the reader names the key, by it_prefs' own rule (the key and its NUL anywhere in the
    /// file), so the prepare knows what it_prefs will set at boot instead of finding out on the guest console.
    public static func prefs(_ fw: Firmware, _ settings: [(String, String)]) -> [Fit] {
        settings.map { key, reader in
            let piece = "it_prefs \(key)", name = (reader as NSString).lastPathComponent
            guard fw.resolve(reader) != nil else { return Fit(piece, fits: false, "no \(reader) on this firmware") }
            return fw.file(reader, contains: Data((key + "\0").utf8)) ? Fit(piece, fits: true, "\(name) names \(key)")
                : Fit(piece, fits: false, "\(name) does not name \(key): the setting reaches nothing")
        }
    }

    // MARK: SpringBoard's environment

    static let frameworkDirs = ["System/Library/Frameworks", "System/Library/PrivateFrameworks"]

    /// memmem over mapped bytes (the shared cache is hundreds of MB).
    static func contains(_ d: Data, _ needle: Data) -> Bool {
        d.withUnsafeBytes { b in needle.withUnsafeBytes { n in
            guard let base = b.baseAddress, let nb = n.baseAddress, b.count >= n.count else { return false }
            return memmem(base, b.count, nb, n.count) != nil
        } }
    }

    /// Every framework binary on the volume (<dir>/<Name>.framework/<Name>), the shared cache and SpringBoard: the images
    /// that could read an environment variable SpringBoard's job sets.
    static func readers(_ fw: Firmware) -> [(String, Data)] {
        var out: [(String, Data)] = []
        if let c = fw.cache { out.append(("the shared cache", c.data)) }
        for dir in frameworkDirs {
            for f in ((try? FileManager.default.contentsOfDirectory(atPath: fw.root.appendingPathComponent(dir).path)) ?? []).sorted() where f.hasSuffix(".framework") {
                let rel = dir + "/" + f + "/" + f.dropLast(".framework".count)
                if let d = fw.data(rel) { out.append(((rel as NSString).lastPathComponent, d)) }
            }
        }
        if let sb = fw.data(itPrefs[0].1) { out.append(("SpringBoard", sb)) }
        return out
    }

    /// SpringBoard's environment edits fit when every switch (a name, or the same switch under its CoreAnimation and
    /// LayerKit names) is read by an image of this firmware (readers) or by a binary the bake injects with it (`also`:
    /// the GL shim reads GLI_ACCELERATED). A switch nothing reads has no effect: the firmware's default decides.
    public static func environment(_ fw: Firmware, _ switches: [[String]], also: [(String, Data)] = []) -> Fit {
        named("SpringBoard environment", fw, switches, also: also)
    }

    /// The keys the web-proxy edit writes into the Wi-Fi service's Proxies (the PAC's), which SystemConfiguration and
    /// CFNetwork must name for the PAC to be used.
    public static let proxyKeys = ["ProxyAutoConfigEnable", "ProxyAutoConfigURLString", "ExceptionsList", "FTPPassive"]

    /// The web proxy's PAC fits when the firmware names every key the edit sets.
    public static func webProxy(_ fw: Firmware) -> Fit { named("web proxy PAC", fw, proxyKeys.map { [$0] }) }

    /// `piece (a, b/c, ...)` fits when each group of names (one name, or alternatives) is named as a C string by an
    /// image of this firmware (readers) or by `also`.
    static func named(_ label: String, _ fw: Firmware, _ switches: [[String]], also: [(String, Data)] = []) -> Fit {
        let piece = "\(label) (\(switches.map { $0.joined(separator: "/") }.joined(separator: ", ")))"
        let images = readers(fw) + also
        var read: [String] = [], unread: [String] = []
        for names in switches {
            let hits = names.compactMap { n in images.first { contains($0.1, cString(n)) }.map { "\(n) by \($0.0)" } }
            if let first = hits.first { read.append(first) } else { unread.append(names.joined(separator: "/")) }
        }
        guard unread.isEmpty else { return Fit(piece, fits: false, "nothing in this firmware reads \(unread.joined(separator: ", ")): the firmware's default decides") }
        return Fit(piece, fits: true, "read: " + read.joined(separator: "; "))
    }

    // MARK: boot-args

    /// The code-signing boot-args the injected binaries are booted with: they are ad-hoc signed, so AMFI must allow any
    /// signature (required: without it none of them runs), and the kernel should not enforce code signing (the AppSync
    /// cache patch and the DYLD_INSERT hooks change signed pages).
    public static let amfiArgs: Set<String> = ["amfi_allow_any_signature", "cs_enforcement_disable"]
    static let requiredArgs: Set<String> = ["amfi_allow_any_signature"]

    /// One Fit per boot-arg in `args` (flags like -v aside): fits when the kernel names it. A code-signing arg the kernel
    /// does not read does not fit; any other is inert there (no effect), which is recorded, not assumed.
    public static func bootArgs(_ kernel: Data?, _ args: String) -> [Fit] {
        args.split(separator: " ").map { String($0.prefix { $0 != "=" }) }.filter { !$0.hasPrefix("-") }.map { name in
            let piece = "boot-arg \(name)"
            guard let kernel else { return Fit(piece, fits: false, "no decrypted kernelcache to check it against") }
            if contains(kernel, cString(name)) { return Fit(piece, fits: true, "read by the kernel") }
            return amfiArgs.contains(name) ? Fit(piece, fits: false, "the kernel does not read it as a boot-arg")
                : Fit(piece, fits: true, "not read by this kernel: no effect here")
        }
    }

    /// A DeviceTree property the boot chain adds (hsic-enabled on arm-io/usb-complex): read when the kernel names it,
    /// else inert there. Recorded, never required: which kernels need it is what the record shows.
    public static func deviceTreeProperty(_ kernel: Data?, _ node: String, _ name: String) -> Fit {
        let piece = "DeviceTree \(node)/\(name)"
        guard let kernel else { return Fit(piece, fits: false, "no decrypted kernelcache to check it against") }
        return contains(kernel, cString(name)) ? Fit(piece, fits: true, "read by the kernel") : Fit(piece, fits: true, "not read by this kernel: no effect here")
    }

    /// bootArgs, recorded in `log`: amfi_allow_any_signature is required; an unread cs_enforcement_disable is a warning.
    static func checkBootArgs(_ log: Log, kernel: Data?, args: String) throws {
        for f in bootArgs(kernel, args) {
            try log.check(f, required: requiredArgs.contains(String(f.piece.dropFirst("boot-arg ".count))), outcome: "kept: inert here")
        }
    }
}

extension FitCheck {
    // MARK: AppSync

    /// What libappsync hooks in its host (contrib/appsync appsync.c): it interposes libmis's signature checks (one of
    /// the two is the host's), and the two Security calls installd's verify_signer_identity makes on the signer
    /// certificate; it fills the info dict under the two libmis keys the host reads. Each group: alternatives.
    static let appSyncCalls = [["_MISValidateSignatureAndCopyInfo", "_MISValidateSignature"], ["_SecCertificateCreateWithData"],
                               ["_SecCertificateCopySubjectSummary"], ["_kMISValidationInfoSignerCertificate"], ["_kMISValidationInfoValidatedByProfile"]]

    /// libappsync fits the installation service `host` when the host's process (it, and every image it links)
    /// imports what the dylib hooks (appSyncCalls), the dylib's getprogname gate names the host's program (the
    /// Security interposes act only there), and the dylib loads in it.
    public static func appSync(_ fw: Firmware, host: String, dylib: Data) -> Fit {
        let name = (host as NSString).lastPathComponent, piece = "\(SystemEdits.Helpers.appsync) (in \(name))"
        guard fw.resolve(host) != nil else { return Fit(piece, fits: false, "no \(host) on this firmware") }
        var why: [String] = []
        if !contains(dylib, cString(name)) { why.append("its getprogname gate does not name \(name): the Security interposes would pass through there") }
        let images = fw.loaded(host)
        var hooked: [String] = [], unhooked: [String] = []
        for group in appSyncCalls {
            let hit = group.lazy.compactMap { s in images.first { fw.imports($0)?.contains(s) == true }.map { "\(s.dropFirst()) by \(($0 as NSString).lastPathComponent)" } }.first
            if let hit { hooked.append(hit) } else { unhooked.append(group.map { String($0.dropFirst()) }.joined(separator: " or ")) }
        }
        if !unhooked.isEmpty { why.append("nothing in \(name)'s process imports \(unhooked.joined(separator: ", ")), which the dylib hooks") }
        let l = loads(piece, dylib, on: fw, host: host)
        if !l.fits { why.append(l.proof) }
        guard why.isEmpty else { return Fit(piece, fits: false, why.joined(separator: "; ")) }
        return Fit(piece, fits: true, "hooks " + hooked.joined(separator: ", ") + "; gate names \(name); " + l.proof)
    }

    /// appsync-launch (2.x: Lockbot passes ProgramArguments only, so it sets DYLD_INSERT_LIBRARIES and execs the
    /// service) fits when it loads, names the dylib where the bake puts it, and the service `program` it execs is a
    /// Mach-O this CPU runs.
    public static func appSyncLauncher(_ fw: Firmware, program: String, launcher: Data) -> Fit {
        let piece = SystemEdits.Helpers.appsyncLauncher + " (Lockbot's installation_proxy service)"
        guard let bin = fw.data(program), MachO32.slice(bin, arch: fw.arch) != nil else {
            return Fit(piece, fits: false, "the service it execs, \(program), is not a Mach-O this CPU runs on this firmware")
        }
        guard contains(launcher, cString("/" + SystemEdits.appsyncPath)) else {
            return Fit(piece, fits: false, "it does not insert /\(SystemEdits.appsyncPath), where the bake puts the dylib")
        }
        let l = loads(piece, launcher, on: fw)
        guard l.fits else { return l }
        return Fit(piece, fits: true, "execs \((program as NSString).lastPathComponent) with /\(SystemEdits.appsyncPath) inserted; " + l.proof)
    }

    /// The shared-cache half of AppSync fits when the cache's MISValidateSignature is a Thumb entry the patch
    /// recognises (a framed function, or 5.x's movs;b.w thunk): AppSyncCachePatch.locate, the patch's own finder.
    /// Nil without a shared cache (2.x/3.0: no cache half, installAppSync interposes only).
    public static func appSyncCache(_ fw: Firmware) -> Fit? {
        guard let cache = fw.cache else { return nil }
        let piece = "AppSync shared-cache patch (\(AppSyncCachePatch.target))"
        do {
            let (va, _, word) = try AppSyncCachePatch.locate(cache)
            return Fit(piece, fits: true, "entry \(word.map { String(format: "%02x", $0) }.joined()) at \(hex(va))")
        } catch { return Fit(piece, fits: false, "\(error)") }
    }

    /// AppSync's pieces where installAppSync puts them, recorded in `log`, required: the shared-cache patch target where
    /// there is a cache, libappsync in installd's job's program, else (2.x) in Lockbot's installation_proxy service with
    /// appsync-launch.
    static func checkAppSync(_ log: Log, _ fw: Firmware, helpers: URL) throws {
        if let c = appSyncCache(fw) { try log.check(c, required: true) }
        func piece(_ n: String) throws -> Data {
            let u = helpers.appendingPathComponent(n)
            guard FileManager.default.fileExists(atPath: u.path) else { throw FirmwareError(.internal, "guest helper \(n) missing from \(helpers.path)") }
            return try Data(contentsOf: u)
        }
        let dylib = try piece(SystemEdits.Helpers.appsync)
        let program: (NSDictionary?) -> String? = { d in (d?["ProgramArguments"] as? [String])?.first ?? d?["Program"] as? String }
        if let job = ["com.apple.mobile.installd.plist", "com.apple.installd.plist"].map({ SystemEdits.daemons + "/" + $0 }).first(where: { fw.resolve($0) != nil }) {
            guard let host = program(NSDictionary(contentsOf: fw.resolve(job)!)) else {
                try log.check(Fit(SystemEdits.Helpers.appsync, fits: false, "\(job) names no program"), required: true); return
            }
            try log.check(appSync(fw, host: host, dylib: dylib), required: true)
            return
        }
        let services = fw.resolve("System/Library/Lockdown/Services.plist").flatMap { NSDictionary(contentsOf: $0) }
        guard let host = program(services?["com.apple.mobile.installation_proxy"] as? NSDictionary) else {
            try log.check(Fit(SystemEdits.Helpers.appsync, fits: false, "no installd job and no Lockbot installation_proxy service"), required: true); return
        }
        try log.check(appSync(fw, host: host, dylib: dylib), required: true)
        try log.check(appSyncLauncher(fw, program: host, launcher: piece(SystemEdits.Helpers.appsyncLauncher)), required: true)
    }
}
