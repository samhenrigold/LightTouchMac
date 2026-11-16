import BuildSupport
import Foundation

// Native compilation has its own content key. A release-check or packaging change still gets a new final vendor
// directory, but it can reuse the thin builds, universal merge and ANGLE without copying their build trees.
extension Vendor {
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

    static let staticKeyed = [
        "build-support/recipes/build-static-deps.sh", "build-support/recipes/compiler-cache.sh",
        "build-support/dependencies.json",
        "build-support/patches/libplist-bin-limits.patch", "build-support/patches/libusbmuxd-inetcat-writes.patch",
        "build-support/checks/inetcat-writes.c",
        "Packages/BuildTools/Sources/BuildTools/DependencySources.swift",
        "Packages/BuildTools/Sources/BuildTools/Records.swift"
    ]
    /// ANGLE's universal libEGL and libGLESv2, headers and licenses (build-support/recipes/build-angle.sh), from gclient's checkout of
    /// the pinned commit, cached under <vendor root>/angle-src/<commit>.
    func angle(_ work: URL) throws -> URL {
        let out = work.appendingPathComponent("angle")
        if ["licenses/SOURCE.txt", "libEGL.dylib", "libGLESv2.dylib", "include/EGL/egl.h"].allSatisfy({
            files.fileExists(atPath: out.appendingPathComponent($0).path)
        }) {
            return out
        }
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
        if Self.nativeComplete(universal) { return universal }
        let staticInputs = try treeHash(Self.staticKeyed)
        let toolchain = try JSONSerialization.data(withJSONObject: Records.toolchain(), options: [.sortedKeys])
        let staticKey = String(sha256Hex(Data(staticInputs.utf8) + toolchain).prefix(12))
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

    static func nativeComplete(_ universal: URL) -> Bool {
        [
            "native-build.json", "qemu-build/libqemu-arm.dylib", "build/iBoot32Patcher/iBoot32Patcher",
            "build/usbmuxd/src/usbmuxd", "prefix/lib/libimobiledevice-1.0.dylib", "prefix/lib/libplist-2.0.dylib",
            "static/prefix/lib/libcrypto.a"
        ].allSatisfy {
            files.fileExists(atPath: universal.appendingPathComponent($0).path)
        }
    }

    /// build-static-deps.sh writes static-build.json as its last step (atomically), so a static root without it is an
    /// interrupted build, whatever libraries it already holds.
    static func staticComplete(_ staticRoot: URL) -> Bool {
        files.fileExists(atPath: staticRoot.appendingPathComponent("static-build.json").path)
    }

    /// Inputs of the native recipes and their command implementations, excluding release checks and packaging.
    static let nativeKeyed = [
        "build-support/recipes", "build-support/patches", "build-support/checks",
        "build-support/dependencies.json", "Packages/BuildTools/Package.swift", "Packages/BuildTools/Package.resolved",
        "Packages/BuildTools/Sources/BuildSupport", "Packages/BuildTools/Sources/ltm-build",
        "Packages/BuildTools/Sources/BuildTools/DependencySources.swift",
        "Packages/BuildTools/Sources/BuildTools/Records.swift", "Packages/BuildTools/Sources/BuildTools/Support.swift",
        "Packages/BuildTools/Sources/BuildTools/MergeNative.swift",
        "Packages/BuildTools/Sources/BuildTools/VendorNative.swift"
    ]

    func nativeKey(toolchain: [String: String]) throws -> String {
        let inputs: [String: Any] = [
            "schema": 1, "files": try treeHash(Self.nativeKeyed), "toolchain": toolchain,
            "qemu": pin("qemu-ios")["commit"] ?? "", "usbmuxd": pin("usbmuxd")["commit"] ?? "",
            "architectures": Self.archs, "minos": Self.minos
        ]
        let data = try JSONSerialization.data(withJSONObject: inputs, options: [.sortedKeys])
        return String(sha256Hex(data).prefix(12))
    }

    /// The vendor-root lock is held by build(). These links preserve the existing work/native and
    /// work/universal interfaces and let scripts/clean keep caches referenced by retained vendor directories.
    func sharedNative(_ work: URL) throws -> URL {
        let key = try nativeKey(toolchain: Records.toolchain())
        let cache = vendorRoot.appendingPathComponent("native/\(key)")
        try files.createDirectory(at: cache, withIntermediateDirectories: true)
        for (name, target) in [
            ("native-cache", cache), ("native", cache.appendingPathComponent("native")),
            ("universal", cache.appendingPathComponent("universal")),
            ("angle", cache.appendingPathComponent("angle"))
        ] {
            let link = work.appendingPathComponent(name)
            if files.fileExists(atPath: link.path), (try? files.destinationOfSymbolicLink(atPath: link.path)) == nil {
                throw ToolError("vendor: refusing to replace an existing native build at \(link.path)")
            }
            try? files.removeItem(at: link)
            try files.createSymbolicLink(at: link, withDestinationURL: target)
        }
        try files.setAttributes([.modificationDate: Date()], ofItemAtPath: cache.path)
        say("native cache \(key) (shared across vendor packages)")
        return cache
    }
}
