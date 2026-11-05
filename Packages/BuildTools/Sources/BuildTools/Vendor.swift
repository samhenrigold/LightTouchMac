import BuildSupport
import Foundation

/// scripts/vendor: checks what a build needs, then builds what Xcode can't, from the pins, into a cached vendor
/// directory that Archive copies into the app (see `usage`).
public struct Vendor {
    public static let usage = """
            scripts/vendor               check, then build (or reuse) ~/Developer/ltm-vendor.noindex/<pin-hash>/
            scripts/vendor --check       only check: print each missing piece and where to get it (exit 1 on any)
            scripts/vendor --release     also the built-in iPod (scripts/ship; needs the n72ap-7E18 IPSW)
            scripts/vendor --print       print the vendor directory for the current pins

        The one setup command, on a fresh Mac and after a pin bump. The checks: an Apple Silicon Mac, the macOS SDK,
        the Homebrew build tools, the qemu-ios and usbmuxd checkouts holding their pinned commits, the iPhoneOS 3.1.3
        and 3.2 SDKs and the SecureROMs (and with --release the built-in iPod's IPSW). Nothing here downloads or copies
        Apple's software or firmware. Every run also writes HostRuntime's MachineOptions.swift from the vendored QEMU
        (commit it when it changed; scripts/vendor-check fails the build while it differs).

        The pin hash covers build-support/sources.json (qemu-ios and usbmuxd commits), dependencies.json,
        developer-disk-images.json, the patches, the recipes (build-support/recipes) and these tools
        (Packages/BuildTools). A run with the vendor directory complete only writes the
        machine options; with --release the built-in iPod is prepared again when FirmwareKit, the helper or the guest
        tools changed. Nothing here deletes a vendor directory. One run at a time: a second run waits for the first (a
        flock on <vendor root>/.lock).

        <vendor>/Frameworks/   libqemu-arm.dylib and its closure, ANGLE's libEGL and libGLESv2 (the emulator opens them
                               for its experimental ANGLE renderer), libimobiledevice-1.0 and libplist-2.0: universal,
                               @rpath install names, stripped, ad-hoc signed with the hardened runtime (Xcode re-signs)
        <vendor>/MacOS/        usbmuxd, iBoot32Patcher, inetcat, ipod-helper (the same)
        <vendor>/Resources/    Guest/guest.aar (the guest binaries and Developer Disk Images, packed: no nested code),
                               Device/ (SecureROMs and the built-in iPod), licenses/, usbmuxd-conf/, build-inputs.json
        <vendor>/include/      libimobiledevice and libplist headers (LightTouchServices links them)
        <vendor>/dSYMs/        symbols of what Frameworks and MacOS ship stripped
        <vendor>/work/         build trees and logs (reused by reruns)

        Inputs besides the pins: ARMV6_SDK (default ~/Developer/ipod2g-re/OldSDK/iPhoneOS3.1.3.sdk), IPAD_SDK (the
        iPhoneOS3.2.sdk), LTM_ASSETS (the SecureROMs, default ~/Developer/qemu-ios-files), with --release the
        n72ap-7E18 IPSW in the app's IPSW cache (or LTM_BUILT_IN_IPSW), network for the pinned source archives.
        QEMU_IOS_DIR and USBMUXD_SOURCE_DIR move the checkouts; LTM_VENDOR_ROOT moves the cache (default
        ~/Developer/ltm-vendor.noindex, which Spotlight leaves alone).
        """

    let root: URL
    let environment = ProcessInfo.processInfo.environment
    var home: URL { files.homeDirectoryForCurrentUser }
    var vendorRoot: URL {
        url(
            environment["LTM_VENDOR_ROOT"].map { ($0 as NSString).expandingTildeInPath }
                ?? home.appendingPathComponent("Developer/ltm-vendor.noindex").path
        )
    }
    var sdk: URL {
        url(
            environment["ARMV6_SDK"] ?? home.appendingPathComponent("Developer/ipod2g-re/OldSDK/iPhoneOS3.1.3.sdk").path
        )
    }
    var ipadSDK: URL {
        url(
            environment["IPAD_SDK"]
                ?? assets.appendingPathComponent(
                    "ipad1/sdk/x-iPhoneSDK3_2_2/Payload/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS3.2.sdk"
                ).path
        )
    }
    var assets: URL { url(environment["LTM_ASSETS"] ?? home.appendingPathComponent("Developer/qemu-ios-files").path) }
    var ipswCache: URL { home.appendingPathComponent("Library/Caches/gold.samhenri.LightTouchMac/IPSW") }
    var recipes: URL { root.appendingPathComponent("build-support/recipes") }
    static let archs = ["arm64", "x86_64"], minos = "14.4"
    static let bootROMs = ["bootrom_240_4", "ipod1g/bootrom_s5l8900"]  // the iPod touch 2G's and 1G's SecureROMs
    static let developerImages = "build-support/developer-disk-images.json"
    static let seed = "lighttouch-built-in"  // the unpack gives every copy its own identity
    /// The built-in iPod's catalog id: Packages/ReleaseChecks/boots.json's builtIn, which scripts/ship and
    /// ReleaseBootTests read too.
    var builtIn: String {
        get throws {
            let boots = root.appendingPathComponent("Packages/ReleaseChecks/boots.json")
            guard let id = try readJSON(boots)["builtIn"] as? String, !id.isEmpty else {
                throw ToolError("vendor: \(boots.path) names no builtIn")
            }
            return id
        }
    }
    // What the app and firmwarekit look for in the guest export (qemu-ios contrib/export-guest-artifacts.sh).
    static let ipodTools = ["itmedia", "itphoto"]
    static let guestTools = [
        "it_pbd", "it_prefs", "it_msmquiet.dylib", "it_seal", "it_keybag", "libappsync.dylib",
        "OpenGLES", "gles-names.h", "OpenGLES-1x", "opengles-1x.exports", "armv6.itpack", "armv7.itpack",
        "sblaunch", "sbdlicon", "it_agent", "it_typein.dylib", "it_keybag-armv6"
    ]
    static let guestPackageMinSerial = 16
    static let tools = [
        "Packages/BuildTools/Package.swift", "Packages/BuildTools/Sources"
    ]
    static let staticKeyed = [
        "build-support/recipes/build-static-deps.sh", "build-support/dependencies.json",
        "build-support/patches/libplist-bin-limits.patch", "build-support/patches/libusbmuxd-inetcat-writes.patch",
        "build-support/checks/inetcat-writes.c",
        "Packages/BuildTools/Sources/BuildTools/DependencySources.swift",
        "Packages/BuildTools/Sources/BuildTools/Records.swift"
    ]
    // The built-in iPod is prepared again when any of these change (firmwarekit, the helper it boots).
    static let deviceSources = [
        "Packages/FirmwareKit/Sources", "Packages/FirmwareKit/Package.swift", "Packages/HostRuntime/Sources",
        "LightTouchDevice", "Packages/DeviceRuntime"
    ]

    public init(root: URL) { self.root = root }

    /// Whether firmwarekit's device.lock.json records `guestTools`, as given or through symlinks either way.
    static func preparedWith(_ guestTools: URL, lock: URL) -> Bool {
        let inputs = (try? readJSON(lock))?["inputs"] as? [String: Any]
        guard let recorded = inputs?["guest_tools"] as? String else { return false }
        return MergeNative.real(recorded) == MergeNative.real(guestTools.path)
    }

    // MARK: pins and keys

    var pins: [String: Any] { (try? readJSON(root.appendingPathComponent("build-support/sources.json"))) ?? [:] }
    func pin(_ name: String) -> [String: String] {
        (pins[name] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
    }
    func checkout(_ name: String) -> URL {
        let override = environment[name == "qemu-ios" ? "QEMU_IOS_DIR" : "USBMUXD_SOURCE_DIR"].flatMap {
            $0.isEmpty ? nil : $0
        }
        return url(((override ?? pin(name)["path"] ?? "") as NSString).expandingTildeInPath).resolvingSymlinksInPath()
    }

    /// SHA-256 over every file (relative path and content) under the named files and directories.
    func treeHash(_ names: [String]) throws -> String {
        var text = ""
        for name in names {
            let item = root.appendingPathComponent(name)
            var directory: ObjCBool = false
            guard files.fileExists(atPath: item.path, isDirectory: &directory) else { continue }
            let paths =
                directory.boolValue
                ? walk(item).filter { !$0.split(separator: "/").contains(".build") }.map { "\(name)/\($0)" }
                : [name]
            for path in paths where !Records.isLinkToDirectory(root.appendingPathComponent(path)) {
                text += "\(path)\0\(try sha256(root.appendingPathComponent(path)))\0"
            }
        }
        return sha256Hex(Data(text.utf8))
    }

    /// `scripts/vendor-check --key`, the one implementation of the pin key (Xcode's first phase keys with it too).
    func pinKey() throws -> String {
        try output(["/bin/bash", root.appendingPathComponent("scripts/vendor-check").path, "--key", root.path])
    }

    public func directory() throws -> URL {
        vendorRoot.appendingPathComponent(try pinKey())
    }

    // MARK: steps

    func say(_ line: String) {
        print("vendor: \(line)")
        fflush(stdout)
    }

    /// The environment children run with: this tool for the recipes' `scripts/ltm-build` calls.
    func env(_ extra: [String: String] = [:]) -> [String: String] {
        environment.merging(["LTM_BUILD_TOOL": Bundle.main.executablePath ?? ""]) { $1 }.merging(extra) { $1 }
    }

    /// The pinned qemu-ios commit, as a detached worktree of the checkout sources.json names.
    func qemuTree(_ work: URL) throws -> URL {
        let tree = work.appendingPathComponent("qemu-src")
        let commit = pin("qemu-ios")["commit"] ?? ""
        if !files.fileExists(atPath: tree.path) {
            try run([
                "/usr/bin/git", "-C", checkout("qemu-ios").path, "worktree", "add", "--detach", "-q", tree.path, commit
            ])
        }
        guard try output(["git", "-C", tree.path, "rev-parse", "HEAD"]) == commit else {
            throw ToolError("vendor: \(tree.path) is not at the pinned qemu-ios \(commit)")
        }
        return tree
    }

    /// ANGLE's universal libEGL and libGLESv2, headers and licenses (build-support/recipes/build-angle.sh), from gclient's checkout of
    /// the pinned commit, cached under <vendor root>/angle-src/<commit>.
    func angle(_ work: URL) throws -> URL {
        let out = work.appendingPathComponent("angle")
        if files.fileExists(atPath: out.appendingPathComponent("licenses/SOURCE.txt").path) { return out }
        let packages =
            (try readJSON(root.appendingPathComponent("build-support/dependencies.json"))["packages"]
                as? [[String: Any]]) ?? []
        guard let commit = packages.first(where: { $0["name"] as? String == "ANGLE" })?["version"] as? String else {
            throw ToolError("vendor: no ANGLE package in build-support/dependencies.json")
        }
        let log = work.appendingPathComponent("logs/angle.log")
        say("ANGLE \(commit.prefix(10)); log \(log.path)")
        try files.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try run(
            [
                "/bin/bash", recipes.appendingPathComponent("build-angle.sh").path,
                vendorRoot.appendingPathComponent("angle-src/\(commit)").path, out.path
            ],
            log: log,
            environment: env(["LTM_ARCH": Self.archs.joined(separator: " ")])
        )
        return out
    }

    /// One build-package-native.sh root per slice (usbmuxd at its pin, the QEMU dylib, iBoot32Patcher), with the
    /// static prefix cached per recipe, then merged into one universal root.
    func native(_ work: URL, qemu: URL, angle: URL) throws -> URL {
        let universal = work.appendingPathComponent("universal")
        if files.fileExists(atPath: universal.appendingPathComponent("native-build.json").path),
            files.fileExists(atPath: universal.appendingPathComponent("build/iBoot32Patcher/iBoot32Patcher").path)
        {
            return universal
        }
        let staticKey = String(try treeHash(Self.staticKeyed).prefix(12))
        for arch in Self.archs {  // one at a time: both stage usbmuxd through a worktree of the same checkout
            let slice = work.appendingPathComponent("native/\(arch)")
            let staticRoot = vendorRoot.appendingPathComponent("static/\(staticKey)/\(arch)")
            if files.fileExists(atPath: slice.appendingPathComponent("native-build.json").path) { continue }
            let log = work.appendingPathComponent("logs/native-\(arch).log")
            say("native \(arch) (dependencies, usbmuxd, QEMU); log \(log.path)")
            remove(slice)
            try files.createDirectory(at: slice.deletingLastPathComponent(), withIntermediateDirectories: true)
            let e = env([
                "LTM_ARCH": arch, "QEMU_IOS_DIR": qemu.path, "USBMUXD_SOURCE_DIR": checkout("usbmuxd").path,
                "USBMUXD_COMMIT": pin("usbmuxd")["commit"] ?? "",
                "LTM_STATIC_DEPS": staticRoot.appendingPathComponent("prefix").path, "LTM_ANGLE": angle.path
            ])
            if !Self.staticComplete(staticRoot) {
                remove(staticRoot)
                try files.createDirectory(at: staticRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
                try run(
                    ["/bin/bash", recipes.appendingPathComponent("build-static-deps.sh").path, staticRoot.path],
                    log: log,
                    environment: e
                )
            }
            try run(
                ["/bin/bash", recipes.appendingPathComponent("build-package-native.sh").path, slice.path],
                log: log,
                environment: e
            )
        }
        remove(universal)
        try MergeNative.merge(output: universal, roots: Self.archs.map { work.appendingPathComponent("native/\($0)") })
        try run(
            [
                "/bin/bash", recipes.appendingPathComponent("build-iboot32patcher.sh").path,
                work.appendingPathComponent("native/arm64/src").path,
                universal.appendingPathComponent("build/iBoot32Patcher").path
            ],
            log: work.appendingPathComponent("logs/universal.log"),
            environment: env(["LTM_ARCH": Self.archs.joined(separator: " ")])
        )
        return universal
    }

    /// build-static-deps.sh writes static-build.json as its last step (atomically), so a static root without it is an
    /// interrupted build, whatever libraries it already holds.
    static func staticComplete(_ staticRoot: URL) -> Bool {
        files.fileExists(atPath: staticRoot.appendingPathComponent("static-build.json").path)
    }

    /// Holds an exclusive flock on `<directory>/.lock` until the returned descriptor is closed (or the process exits):
    /// concurrent runs share static/<key> and the vendor directories, so a second run waits for the first.
    static func lock(_ directory: URL, waiting: () -> Void) throws -> Int32 {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(".lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ToolError("vendor: cannot open \(path): \(String(cString: strerror(errno)))") }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            waiting()
            while flock(fd, LOCK_EX) != 0 {
                guard errno == EINTR else {
                    close(fd)
                    throw ToolError("vendor: cannot lock \(path): \(String(cString: strerror(errno)))")
                }
            }
        }
        return fd
    }

    /// qemu-ios's guest export (contrib/export-guest-artifacts.sh, where its recipes are), checked for what the app and
    /// firmwarekit read: guest-tools/ (the flat iPod set the app uploads), ipad-guest-tools/ (the flat directory
    /// firmwarekit reads) and manifest.json (source commit, sha256 per input and output).
    func guest(_ work: URL, qemu: URL) throws -> (URL, [String: Any]) {
        let guestRoot = work.appendingPathComponent("guest")
        if !files.fileExists(atPath: guestRoot.appendingPathComponent("manifest.json").path) {
            say("guest tools")
            remove(guestRoot)
            try run(
                ["/bin/bash", qemu.appendingPathComponent("contrib/export-guest-artifacts.sh").path, guestRoot.path],
                log: work.appendingPathComponent("logs/guest.log"),
                environment: env(["ARMV6_SDK": sdk.path, "IPAD_SDK": ipadSDK.path])
            )
        }
        let manifest = try readJSON(guestRoot.appendingPathComponent("manifest.json"))
        let serial = (manifest["guest_package"] as? [String: Any])?["serial"] as? Int ?? 0
        let missing = Self.ipodTools.map { "guest-tools/\($0)" } + Self.guestTools.map { "ipad-guest-tools/\($0)" }
        let absent = missing.filter { !files.fileExists(atPath: guestRoot.appendingPathComponent($0).path) }
        guard serial >= Self.guestPackageMinSerial, absent.isEmpty else {
            throw ToolError(
                "vendor: the guest export (serial \(serial)) lacks \(absent.isEmpty ? "a current guest package" : absent.joined(separator: ", "))"
            )
        }
        return (guestRoot, manifest)
    }

    func developerTools(_ work: URL, qemu: URL) throws -> URL {
        let payload = work.appendingPathComponent("developer-tools")
        let log = work.appendingPathComponent("logs/developer-tools.log")
        if !files.fileExists(atPath: payload.appendingPathComponent("developer-tools.json").path) {
            say("developer tools")
            remove(payload)
            try run(
                ["/bin/bash", root.appendingPathComponent("tools/developer-packages/fetch.sh").path, payload.path],
                log: log,
                environment: env(["LTM_QEMU_SOURCE_DIR": qemu.path, "LTM_BASH_SDK": sdk.path])
            )
        }
        try run(
            ["/bin/bash", root.appendingPathComponent("tools/developer-packages/audit.sh").path, payload.path],
            log: log,
            environment: env()
        )
        return payload
    }

    /// The checkouts of FirmwareKit's packages and of the project's (the app's own, Sparkle among them), for their
    /// licenses: where firmwarekit's build below finds them too.
    func packageCheckouts(_ work: URL) throws -> [URL] {
        let log = work.appendingPathComponent("logs/packages.log")
        let scratch = work.appendingPathComponent("firmwarekit-build")
        let packages = work.appendingPathComponent("xcode/packages")
        try run(
            [
                "swift", "package", "resolve", "--package-path",
                root.appendingPathComponent("Packages/FirmwareKit").path, "--scratch-path", scratch.path
            ],
            log: log
        )
        try run(
            [
                "xcodebuild", "-resolvePackageDependencies", "-project",
                root.appendingPathComponent("LightTouchMac.xcodeproj").path, "-clonedSourcePackagesDirPath",
                packages.path
            ],
            log: log
        )
        return [scratch.appendingPathComponent("checkouts"), packages.appendingPathComponent("checkouts")]
    }

    /// firmwarekit (host slice) and the Release helper it boots, staged as an app would hold them.
    func firmwarekit(_ work: URL) throws -> (tool: URL, helper: URL) {
        let log = work.appendingPathComponent("logs/device.log")
        let scratch = work.appendingPathComponent("firmwarekit-build")
        let swift = [
            "swift", "build", "-c", "release", "--package-path",
            root.appendingPathComponent("Packages/FirmwareKit").path, "--scratch-path", scratch.path
        ]
        try run(swift, log: log)
        let bin = try output(swift + ["--show-bin-path"])
        try run(
            [
                "xcodebuild", "-skipMacroValidation", "-project",
                root.appendingPathComponent("LightTouchMac.xcodeproj").path, "-target", "LightTouchDevice",
                "-configuration", "Release", "SYMROOT=\(work.path)/xcode", "COMPILER_INDEX_STORE_ENABLE=NO",
                "OBJROOT=\(work.path)/xcode/obj", "-clonedSourcePackagesDirPath", "\(work.path)/xcode/packages",
                "CODE_SIGNING_ALLOWED=NO", "build"
            ],
            log: log
        )
        return (
            url(bin).appendingPathComponent("firmwarekit"),
            work.appendingPathComponent("xcode/Release/LightTouchDevice")
        )
    }

    func makeWritable(_ dir: URL) throws {
        if files.fileExists(atPath: dir.path) { try run(["/bin/chmod", "-R", "u+w", dir.path]) }
    }

    /// The built-in iPod: `firmwarekit create` of builtIn with the export's guest tools, packed by pack-base.
    func builtInDevice(_ vendor: URL, _ work: URL, guestRoot: URL, tool: URL, helper: URL) throws -> URL {
        let builtIn = try builtIn
        let log = work.appendingPathComponent("logs/device.log")
        let stage = work.appendingPathComponent("stage/Contents")
        remove(stage.deletingLastPathComponent())
        try files.createDirectory(at: stage.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try files.createDirectory(at: stage.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try files.copyItem(at: tool, to: stage.appendingPathComponent("MacOS/firmwarekit"))
        try files.copyItem(at: helper, to: stage.appendingPathComponent("MacOS/LightTouchDevice"))
        try files.createSymbolicLink(
            at: stage.appendingPathComponent("Frameworks"),
            withDestinationURL: vendor.appendingPathComponent("Frameworks")
        )
        try files.createSymbolicLink(
            at: stage.appendingPathComponent("Resources/Device"),
            withDestinationURL: vendor.appendingPathComponent("Resources/Device")
        )
        let (entry, ipsw) = try builtInIPSW()
        guard files.fileExists(atPath: ipsw.path) else {
            throw ToolError(
                "vendor: no \(builtIn) IPSW at \(ipsw.path) (download it in the app, or set LTM_BUILT_IN_IPSW)"
            )
        }
        let device = work.appendingPathComponent("device")
        try makeWritable(device)
        remove(device)
        try files.createDirectory(at: device.appendingPathComponent("out"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: entry).write(to: device.appendingPathComponent("entry.json"))
        say("preparing the built-in \(builtIn)")
        let clean = environment.filter { !$0.key.hasPrefix("LTM_") }
        let guestTools = guestRoot.appendingPathComponent("ipad-guest-tools")
        try run(
            [
                stage.appendingPathComponent("MacOS/firmwarekit").path, "create", "--entry",
                device.appendingPathComponent("entry.json").path,
                "--ipsw", ipsw.path, "--out", device.appendingPathComponent("out").path, "--seed", Self.seed,
                "--cache", device.appendingPathComponent("cache").path, "--guest-tools", guestTools.path,
                "--helper", stage.appendingPathComponent("MacOS/LightTouchDevice").path,
                // The firmware's own language, region and keyboard, whatever the building Mac's.
                "--language", "en-US", "--keyboards", ""
            ],
            log: log,
            environment: clean
        )
        guard Self.preparedWith(guestTools, lock: device.appendingPathComponent("out/device.lock.json")) else {
            throw ToolError("vendor: the built-in iPod was not prepared with the vendored guest tools")
        }
        let blob = device.appendingPathComponent("\(builtIn).itbase")
        let reuse = Self.previousBuiltIn(vendor, root: vendorRoot, builtIn: builtIn).map { ["--reuse", $0.path] } ?? []
        try run(
            [
                stage.appendingPathComponent("MacOS/firmwarekit").path, "pack-base", "--base",
                device.appendingPathComponent("out").path,
                "--out", blob.path
            ] + reuse,
            log: log,
            environment: clean
        )
        for name in ["out", "cache"] {
            try makeWritable(device.appendingPathComponent(name))
            remove(device.appendingPathComponent(name))
        }
        return blob
    }

    /// The packed built-in iPod a previous build made, for pack-base to take its unchanged chunks from (so the chunks,
    /// and the app's Sparkle deltas, change only where the device did): this vendor directory's own, else the newest
    /// under the vendor root.
    static func previousBuiltIn(_ vendor: URL, root: URL, builtIn: String) -> URL? {
        func packed(_ dir: URL) -> URL? {
            let itbase = dir.appendingPathComponent("Resources/Device/\(builtIn).itbase")
            return files.fileExists(atPath: itbase.appendingPathComponent("index.json").path) ? itbase : nil
        }
        if let own = packed(vendor) { return own }
        let siblings = ((try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .compactMap(packed)
        func modified(_ url: URL) -> Date {
            (try? files.attributesOfItem(atPath: url.appendingPathComponent("index.json").path)[.modificationDate]
                as? Date) ?? .distantPast
        }
        return siblings.max { modified($0) < modified($1) }
    }

    /// Frameworks/ and MacOS/: every non-system dependency embedded once under @rpath, build rpaths dropped.
    func binaries(_ vendor: URL, universal: URL, qemu: URL, angle: URL, work: URL) throws {
        let frameworks = vendor.appendingPathComponent("Frameworks")
        let tools = vendor.appendingPathComponent("MacOS")
        let toolsLog = work.appendingPathComponent("logs/tools.log")
        var names: [String: String] = [:]
        func relink(_ path: URL, rpath: String) throws -> [String] {
            let path = url(MergeNative.real(path.path))
            let dependencies = try Self.archs.map {
                try MachOClosure.dependencies(path, arch: $0).map { "\($0.name)\t\($0.file.path)" }
            }
            guard Set(dependencies).count == 1 else {
                throw ToolError("\(path.path): dependencies differ between slices")
            }
            var edits: [String] = []
            for (dependency, file) in try MachOClosure.dependencies(path, arch: Self.archs[0]) {
                edits += ["-change", dependency, "@rpath/" + (try embed(file))]
            }
            let rpaths = try MachOClosure.rpaths(path, arch: Self.archs[0])
            for old in rpaths where old.hasPrefix("/") { edits += ["-delete_rpath", old] }
            // only what loads from Frameworks
            if !edits.isEmpty, !rpaths.contains(rpath) { edits += ["-add_rpath", rpath] }
            return edits
        }
        func embed(_ source: URL, as name: String? = nil) throws -> String {
            let real = MergeNative.real(source.path)
            if let known = names[real] { return known }
            let embedded = name ?? (real as NSString).lastPathComponent
            names[real] = embedded
            let target = frameworks.appendingPathComponent(embedded)
            try files.copyItem(at: url(real), to: target)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            try run(
                ["/usr/bin/install_name_tool", "-id", "@rpath/\(embedded)"]
                    + (try relink(url(real), rpath: "@loader_path")) + [target.path],
                log: toolsLog
            )
            return embedded
        }
        for directory in [frameworks, tools] {
            remove(directory)
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let prefix = universal.appendingPathComponent("prefix")
        // the names the app links
        _ = try embed(prefix.appendingPathComponent("lib/libimobiledevice-1.0.dylib"), as: "libimobiledevice-1.0.dylib")
        _ = try embed(prefix.appendingPathComponent("lib/libplist-2.0.dylib"), as: "libplist-2.0.dylib")
        _ = try embed(universal.appendingPathComponent("qemu-build/libqemu-arm.dylib"), as: "libqemu-arm.dylib")
        for name in ["libEGL.dylib", "libGLESv2.dylib"] { _ = try embed(angle.appendingPathComponent(name), as: name) }
        let helper = work.appendingPathComponent("ipod-helper")
        try run(
            ["/usr/bin/cc", "-O2", "-Wall"] + Self.archs.flatMap { ["-arch", $0] } + [
                "-mmacosx-version-min=\(Self.minos)",
                qemu.appendingPathComponent("contrib/macos-app/ipod-helper.c").path, "-lz", "-o", helper.path
            ],
            log: toolsLog
        )
        for source in [
            universal.appendingPathComponent("build/usbmuxd/src/usbmuxd"),
            universal.appendingPathComponent("build/iBoot32Patcher/iBoot32Patcher"),
            universal.appendingPathComponent("static/prefix/bin/inetcat"), helper
        ] {
            let target = tools.appendingPathComponent(source.lastPathComponent)
            try files.copyItem(at: source.resolvingSymlinksInPath(), to: target)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            let edits = try relink(source, rpath: "@executable_path/../Frameworks")
            if !edits.isEmpty { try run(["/usr/bin/install_name_tool"] + edits + [target.path], log: toolsLog) }
        }
        let shipped = try entries(frameworks) + entries(tools)
        let dsyms = vendor.appendingPathComponent("dSYMs")
        remove(dsyms)
        try files.createDirectory(at: dsyms, withIntermediateDirectories: true)
        for path in shipped {
            if try output(["nm", "-ap", path.path]).contains(" OSO ") {
                try run(
                    [
                        "/usr/bin/dsymutil", path.path, "-o",
                        dsyms.appendingPathComponent("\(path.lastPathComponent).dSYM").path
                    ],
                    log: toolsLog
                )
            }
            try run(["/usr/bin/strip", "-S", "-x", path.path], log: toolsLog)
        }
        for path in shipped {
            for arch in Self.archs {
                try MachOClosure.check(path, minimum: Self.minos, arch: arch, noWeakImports: true)
            }
        }
        for path in shipped {  // Xcode's Code Sign On Copy keeps these flags when it signs with the app's identity
            try run(["/usr/bin/codesign", "-f", "-o", "runtime", "-s", "-", path.path], log: toolsLog)
        }
        let include = vendor.appendingPathComponent("include")
        remove(include)
        try files.createDirectory(at: include, withIntermediateDirectories: true)
        for name in ["libimobiledevice", "plist"] {
            try files.copyItem(
                at: prefix.appendingPathComponent("include/\(name)"),
                to: include.appendingPathComponent(name)
            )
        }
    }

    func copy(_ from: URL, _ to: URL) throws {
        try files.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        remove(to)
        try files.copyItem(at: from, to: to)
    }

    func resources(
        _ vendor: URL,
        work: URL,
        universal: URL,
        qemu: URL,
        angle: URL,
        guestRoot: URL,
        manifest: [String: Any],
        developer: URL,
        checkouts: [URL]
    ) throws {
        let res = vendor.appendingPathComponent("Resources")
        let toolsLog = work.appendingPathComponent("logs/tools.log")
        for name in ["Guest", "licenses", "usbmuxd-conf"] { remove(res.appendingPathComponent(name)) }
        try files.createDirectory(at: res.appendingPathComponent("Device"), withIntermediateDirectories: true)
        for name in Self.bootROMs {
            try copy(
                assets.appendingPathComponent(name),
                res.appendingPathComponent("Device/\((name as NSString).lastPathComponent)")
            )
        }
        // The guest binaries ship as one archive: codesign and the notary see no nested code in Resources, and the app
        // and firmwarekit unpack it on first use (FirmwareKit GuestArchive).
        let packed = work.appendingPathComponent("guest-archive")
        remove(packed)
        try copy(guestRoot.appendingPathComponent("ipad-guest-tools"), packed.appendingPathComponent("guest-tools"))
        try copy(developer, packed.appendingPathComponent("developer-tools"))
        for name in Self.ipodTools {
            try copy(
                guestRoot.appendingPathComponent("guest-tools/\(name)"),
                packed.appendingPathComponent("tools/\(name)")
            )
        }
        // Apple's Developer Disk Images (Tweaks' Developer Settings), one per iOS minor version, by their SHA-256:
        // packed too, since each holds iOS binaries.
        let images = work.appendingPathComponent("developer-disk-images")
        let imageManifest = root.appendingPathComponent(Self.developerImages)
        try DependencySources.fetch(
            manifest: imageManifest,
            group: "developer-disk-images",
            destination: images,
            caches: [],
            offline: false
        )
        for package in try DependencySources.packages(manifest: imageManifest, group: "developer-disk-images") {
            let archive = package["archive"] as? String ?? ""
            let version = package["version"] as? String ?? ""
            let name = archive.replacingOccurrences(of: "-\(version)", with: "")
            try copy(
                images.appendingPathComponent(archive),
                packed.appendingPathComponent("developer-disk-images/\(version)/\(name)")
            )
        }
        try files.createDirectory(at: res.appendingPathComponent("Guest"), withIntermediateDirectories: true)
        try run(
            [
                "/usr/bin/aa", "archive", "-d", packed.path, "-o", res.appendingPathComponent("Guest/guest.aar").path,
                "-exclude-field", "uid,gid,flg,mtm,btm,ctm", "-exclude-name", ".DS_Store"
            ],
            log: toolsLog
        )
        try files.createDirectory(at: res.appendingPathComponent("usbmuxd-conf"), withIntermediateDirectories: true)
        try
            ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
            + "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict/></plist>\n")
            .write(
                to: res.appendingPathComponent("usbmuxd-conf/SystemConfiguration.plist"),
                atomically: true,
                encoding: .utf8
            )
        let licenses = res.appendingPathComponent("licenses")
        for source in [
            universal.appendingPathComponent("prefix/share/licenses"),
            universal.appendingPathComponent("static/prefix/share/licenses")
        ] where files.fileExists(atPath: source.path) {
            try run(["/usr/bin/ditto", source.path, licenses.path])
        }
        for name in ["LICENSE", "COPYING", "COPYING.LIB"] {
            try copy(qemu.appendingPathComponent(name), licenses.appendingPathComponent("qemu/\(name)"))
        }
        try copy(angle.appendingPathComponent("licenses"), licenses.appendingPathComponent("angle"))
        let qemuPin = pin("qemu-ios")
        let usbPin = pin("usbmuxd")
        let version = try String(contentsOf: qemu.appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try
            ("QEMU \(version) for iOS devices (qemu-ios): \(qemuPin["repository"] ?? ""), commit \(qemuPin["commit"] ?? "").\n"
            + "The emulator (Frameworks/libqemu-arm.dylib), ipod-helper and the guest tools (Resources/Guest) are built from that tree.\n")
            .write(to: licenses.appendingPathComponent("qemu/SOURCE.txt"), atomically: true, encoding: .utf8)
        if files.fileExists(atPath: qemu.appendingPathComponent("hw/arm/powervr/LICENSE.md").path) {
            for name in ["LICENSE.md", "README.md"] {
                try copy(
                    qemu.appendingPathComponent("hw/arm/powervr/\(name)"),
                    licenses.appendingPathComponent("powervr/\(name)")
                )
            }
        }
        let usb = work.appendingPathComponent("native/arm64/build/usbmuxd")
        for name in ["COPYING.GPLv2", "COPYING.GPLv3"] {
            try copy(usb.appendingPathComponent(name), licenses.appendingPathComponent("usbmuxd/\(name)"))
        }
        try
            "usbmuxd (Light Touch's fork): \(usbPin["repository"] ?? ""), branch \(usbPin["branch"] ?? ""), commit \(usbPin["commit"] ?? "").\n"
            .write(to: licenses.appendingPathComponent("usbmuxd/SOURCE.txt"), atomically: true, encoding: .utf8)
        for name in ["LICENSE", "SOURCE.txt", "iBoot32Patcher-ltm.patch"] {
            try copy(
                universal.appendingPathComponent("build/iBoot32Patcher/\(name)"),
                licenses.appendingPathComponent("iBoot32Patcher/\(name)")
            )
        }
        // the packages linked (SwiftPackageLinks), from the local packages and the project's remote ones
        var packages: [String: URL] = [:]
        for package in try checkouts.flatMap(entries) { packages[package.lastPathComponent.lowercased()] = package }
        let local = try entries(root.appendingPathComponent("Packages")).filter {
            files.fileExists(atPath: $0.appendingPathComponent("Package.swift").path)
        }
        var manifests: [String: [String: Any]] = [:]
        for package in Array(packages.values) + local {
            let json = try output(["swift", "package", "dump-package", "--package-path", package.path])
            manifests[package.lastPathComponent.lowercased()] =
                try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        }
        let project = try String(
            contentsOf: root.appendingPathComponent("LightTouchMac.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let direct = project.matches(of: /repositoryURL = "([^"]+)"/).map {
            String($0.1.split(separator: "/").last ?? "").replacingOccurrences(of: ".git", with: "").lowercased()
        }
        let linked = SwiftPackageLinks.linked(
            roots: local.map { $0.lastPathComponent.lowercased() },
            direct: direct,
            manifests: manifests
        )
        let unlinked = packages.keys.filter { !linked.contains($0) }.sorted()
        for package in packages.values.sorted(by: { $0.path < $1.path })
        where linked.contains(package.lastPathComponent.lowercased()) {
            let target = licenses.appendingPathComponent("swift/\(package.lastPathComponent)")
            try files.createDirectory(at: target, withIntermediateDirectories: true)
            for text in try entries(package)
            where ["LICENSE", "LICENCE", "COPYING", "NOTICE"].contains(
                where: text.lastPathComponent.uppercased().hasPrefix
            ) && Records.isFile(text) {
                try copy(text, target.appendingPathComponent(text.lastPathComponent))
            }
            // RARLAB's UnRAR license travels with its source
            let unrar = package.appendingPathComponent("Sources/Cunrar/license.txt")
            if files.fileExists(atPath: unrar.path) {
                try copy(unrar, target.appendingPathComponent("UnRAR-license.txt"))
            }
        }
        let guestPackage = manifest["guest_package"] as? [String: Any] ?? [:]
        var components: [String: Any] = [
            "qemu-ios": String((qemuPin["commit"] ?? "").prefix(10)),
            "usbmuxd": String((usbPin["commit"] ?? "").prefix(10)),
            "guest tools": "\(guestPackage["version"] ?? "") (serial \(guestPackage["serial"] ?? ""))"
        ]
        for package in try readJSON(root.appendingPathComponent("build-support/dependencies.json"))["packages"]
            as? [[String: Any]] ?? []
        {
            components[package["name"] as? String ?? ""] = String((package["version"] as? String ?? "").prefix(10))
        }
        var roms: [String: String] = [:]
        for name in Self.bootROMs {
            roms[(name as NSString).lastPathComponent] = try sha256(assets.appendingPathComponent(name))
        }
        let pinFields = { (p: [String: String]) in
            ["repository": p["repository"] ?? "", "branch": p["branch"] ?? "", "commit": p["commit"] ?? ""]
        }
        try writeJSON(
            [
                "schema_version": 2, "pins": ["qemu-ios": pinFields(qemuPin), "usbmuxd": pinFields(usbPin)],
                "components": components,
                // resolved but not linked (SwiftPackageLinks): no license of theirs ships, BundleHygiene asks none
                "swift_packages_unlinked": unlinked,
                "host_architectures": Self.archs, "firmware": ["bootroms_sha256": roms],
                "guest_manifest_sha256": try sha256(guestRoot.appendingPathComponent("manifest.json")),
                "xcode": try output(["xcodebuild", "-version"]),
                "macos_sdk": try output(["xcrun", "--sdk", "macosx", "--show-sdk-version"])
            ],
            to: res.appendingPathComponent("build-inputs.json")
        )
    }

    /// The built-in iPod's catalog entry and where its IPSW is (LTM_BUILT_IN_IPSW, else the app's IPSW cache).
    func builtInIPSW() throws -> ([String: Any], URL) {
        let builtIn = try builtIn
        let catalog = try readJSON(root.appendingPathComponent("LightTouchMac/Resources/firmware-catalog.json"))
        guard
            let entry = (catalog["entries"] as? [[String: Any]] ?? []).first(where: {
                $0["id"] as? String == builtIn
            }),
            let sha1 = (entry["source"] as? [String: Any])?["sha1"] as? String
        else { throw ToolError("vendor: no \(builtIn) in the catalog") }
        return (entry, url(environment["LTM_BUILT_IN_IPSW"] ?? ipswCache.appendingPathComponent("\(sha1).ipsw").path))
    }

    /// What this Mac lacks for a vendor build: each a line saying what is missing and one saying where to get it.
    /// Nothing here downloads or copies Apple's software or firmware.
    public func problems(release: Bool) throws -> [(String, String)] {
        var missing: [(String, String)] = []
        if (try? output(["/usr/bin/uname", "-m"])) != "arm64" {
            missing.append(("an Apple Silicon Mac", "the native recipes build both slices from arm64"))
        }
        if (try? output(["xcrun", "--sdk", "macosx", "--show-sdk-path"])) == nil {
            missing.append(("the macOS SDK", "xcode-select --install; open Xcode once to finish its setup"))
        }
        // tool: Homebrew formula (curl, make, file, lipo and xcrun come with macOS and Xcode)
        let path = (environment["PATH"] ?? "").split(separator: ":")
        let formulas = [
            ("pkg-config", "pkgconf"), ("ninja", "ninja"), ("meson", "meson"), ("glibtoolize", "libtool"),
            ("autoreconf", "autoconf"), ("automake", "automake"), ("python3.12", "python@3.12"), ("jq", "jq"),
            ("ldid", "ldid")
        ].filter { tool, _ in !path.contains { files.isExecutableFile(atPath: "\($0)/\(tool)") } }.map(\.1)
        if !formulas.isEmpty {
            let brew = formulas.joined(separator: " ")
            missing.append(("build tools: \(brew)", "brew install \(brew)  (Homebrew: https://brew.sh)"))
        }
        for name in ["qemu-ios", "usbmuxd"] {
            let dir = checkout(name)
            let commit = pin(name)["commit"] ?? ""
            let variable = name == "qemu-ios" ? "QEMU_IOS_DIR" : "USBMUXD_SOURCE_DIR"
            let found = try? output(["git", "-C", dir.path, "cat-file", "-e", "\(commit)^{commit}"])
            if found == nil {
                missing.append(
                    (
                        "\(name) at \(commit) in \(dir.path) (\(variable) moves it)",
                        "git clone -b \(pin(name)["branch"] ?? "main") \(pin(name)["repository"] ?? "") \(dir.path)  (or git -C \(dir.path) fetch)"
                    )
                )
            }
        }
        if !files.fileExists(atPath: sdk.appendingPathComponent("usr/lib/libSystem.dylib").path) {
            missing.append(
                (
                    "the iPhoneOS 3.1.3 SDK at \(sdk.path) (ARMV6_SDK)",
                    "Apple's \"iPhone SDK 3.1.3 with Xcode 3.1.4\" disk image (developer.apple.com/download/all): its iPhoneOS3.1.3.sdk"
                )
            )
        }
        if !files.fileExists(atPath: ipadSDK.appendingPathComponent("usr/lib/libSystem.dylib").path) {
            missing.append(
                (
                    "the iPhoneOS 3.2 SDK at \(ipadSDK.path) (IPAD_SDK)",
                    "Apple's \"Xcode 3.2.2 and iPhone SDK 3.2\" disk image (developer.apple.com/download/all): its iPhoneOS3.2.sdk"
                )
            )
        }
        for name in Self.bootROMs where !files.fileExists(atPath: assets.appendingPathComponent(name).path) {
            missing.append(
                (
                    "the SecureROM \(assets.appendingPathComponent(name).path) (LTM_ASSETS)",
                    "a dump of the device's own SecureROM (iPod touch 2G: 240.4; iPod touch 1G: S5L8900); never in a repository"
                )
            )
        }
        if release {
            let (entry, ipsw) = try builtInIPSW()
            let source = entry["source"] as? [String: Any] ?? [:]
            if !files.fileExists(atPath: ipsw.path) {
                missing.append(
                    (
                        "the iPod touch 2G 3.1.3 (\(try builtIn)) IPSW at \(ipsw.path) (LTM_BUILT_IN_IPSW)",
                        "download it in Light Touch, or: curl -L --create-dirs -o \"\(ipsw.path)\" \(source["url"] ?? "")  (sha1 \(source["sha1"] ?? ""))"
                    )
                )
            }
        }
        return missing
    }

    /// HostRuntime's MachineOptions.swift from this vendor directory's QEMU, into the vendor directory (which
    /// scripts/vendor-check compares) and the checkout. `qemu` runs a command hosting libqemu-arm.dylib.
    func machineOptions(_ vendor: URL, qemu: [String]) throws {
        let text = try MachineOptions.source(
            qemu: qemu + [vendor.appendingPathComponent("Frameworks/libqemu-arm.dylib").path],
            machines: root.appendingPathComponent("tests/fixtures/machines.json")
        )
        try text.write(to: vendor.appendingPathComponent("MachineOptions.swift"), atomically: true, encoding: .utf8)
        let checkout = root.appendingPathComponent(MachineOptions.path)
        if (try? String(contentsOf: checkout, encoding: .utf8)) != text {
            try text.write(to: checkout, atomically: true, encoding: .utf8)
            say("wrote \(MachineOptions.path) for the pinned QEMU: commit it")
        }
    }

    /// Builds what is missing or stale (with `release`, the built-in iPod too) and writes the machine options;
    /// returns the vendor directory. `qemuHost` runs a command hosting libqemu-arm.dylib (ltm-build qemu).
    public func build(release: Bool, qemuHost: [String]) throws -> URL {
        let lock = try Self.lock(vendorRoot) { say("waiting for another scripts/vendor run to finish") }
        defer { close(lock) }
        let vendor = try directory()
        let work = vendor.appendingPathComponent("work")
        let recipe = try treeHash(Self.tools)
        let device = try treeHash(Self.deviceSources)
        let done = vendor.appendingPathComponent("vendor.json")
        var record = ((try? readJSON(done)) ?? [:]).compactMapValues { $0 as? String }
        let blob = vendor.appendingPathComponent("Resources/Device/\(try builtIn).itbase")
        let rebuild =
            record["recipe"] != recipe
            || !files.fileExists(atPath: vendor.appendingPathComponent("Frameworks/libqemu-arm.dylib").path)
        let prepareBuiltIn = release && (rebuild || record["device"] != device || !files.fileExists(atPath: blob.path))
        if rebuild || prepareBuiltIn {
            try files.createDirectory(at: work, withIntermediateDirectories: true)
            let qemu = try qemuTree(work)
            let (guestRoot, manifest) = try guest(work, qemu: qemu)
            if rebuild {
                let angle = try angle(work)
                let universal = try native(work, qemu: qemu, angle: angle)
                let developer = try developerTools(work, qemu: qemu)
                try binaries(vendor, universal: universal, qemu: qemu, angle: angle, work: work)
                try resources(
                    vendor,
                    work: work,
                    universal: universal,
                    qemu: qemu,
                    angle: angle,
                    guestRoot: guestRoot,
                    manifest: manifest,
                    developer: developer,
                    checkouts: try packageCheckouts(work)
                )
                // A built-in iPod from before is no longer this build's until --release prepares it again.
                record = ["recipe": recipe]
            }
            if prepareBuiltIn {
                let (tool, helper) = try firmwarekit(work)
                try copy(try builtInDevice(vendor, work, guestRoot: guestRoot, tool: tool, helper: helper), blob)
                record["device"] = device
            }
            try writeJSON(record, to: done)
        }
        try machineOptions(vendor, qemu: qemuHost)
        return vendor
    }
}
