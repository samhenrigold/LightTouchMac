import BuildSupport
import Foundation

/// The provenance records build-static-deps.sh and build-package-native.sh leave in their roots.
public enum Records {
    static func toolchain() throws -> [String: String] {
        [
            "xcode": try output(["xcodebuild", "-version"]),
            "sdk": try output(["xcrun", "--sdk", "macosx", "--show-sdk-version"])
        ]
    }

    /// static-build.json: the static prefix, its sources and the recipe's hash.
    public static func writeStatic(source: URL, root: URL, arch: String) throws {
        var record: [String: Any] = try toolchain()
        record["schema_version"] = 1
        record["static_deps"] = root.appendingPathComponent("prefix").path
        record["deployment_target"] = "14.0"
        record["architecture"] = arch
        record["sources"] = try readJSON(root.appendingPathComponent("src/static-sources.json"))
        record["recipe_sha256"] = try sha256(
            source.appendingPathComponent("build-support/recipes/build-static-deps.sh"))
        try writeJSON(record, to: root.appendingPathComponent("static-build.json"))
    }

    /// native-build.json: where each part of a native root is (MergeNative reads these keys) and what built it.
    public static func writeNative(source: URL, root: URL, staticPrefix: URL, qemu: URL, usbmuxd: URL, arch: String)
        throws
    {
        let usb = try readJSON(root.appendingPathComponent("usbmuxd-source.json"))
        var record: [String: Any] = try toolchain()
        record["schema_version"] = 1
        record["static_deps"] = staticPrefix.path
        record["qemu_source"] = qemu.path
        record["usbmuxd_source"] = usbmuxd.path
        record["qemu_build"] = root.appendingPathComponent("qemu-build").path
        record["deps_prefix"] = root.appendingPathComponent("prefix").path
        record["usbmuxd_binary"] = root.appendingPathComponent("build/usbmuxd/src/usbmuxd").path
        record["deployment_target"] = "14.0"
        record["architecture"] = arch
        record["sources"] = try readJSON(root.appendingPathComponent("src/native-sources.json"))
        record["usbmuxd"] = usb
        record["usbmuxd_commit"] = usb["commit"]
        record["iboot32patcher"] = try readJSON(root.appendingPathComponent("build/iBoot32Patcher/build.json"))
        record["qemu_commit"] = try output(["git", "-C", qemu.path, "rev-parse", "HEAD"])
        record["qemu_tracked_diff_sha256"] = sha256Hex(
            Data(try output(["git", "-C", qemu.path, "diff", "--binary", "HEAD"]).utf8)
        )
        var recipes: [String: String] = [:]
        for name in recipeFiles { recipes[name] = try sha256(source.appendingPathComponent(name)) }
        record["recipes"] = recipes
        record["static_inputs"] = try walk(staticPrefix).filter { isFile(staticPrefix.appendingPathComponent($0)) }
            .map { ["path": $0, "sha256": try sha256(staticPrefix.appendingPathComponent($0))] }
        let local = root.appendingPathComponent("static/static-build.json")
        let beside = staticPrefix.deletingLastPathComponent().appendingPathComponent("static-build.json")
        if files.fileExists(atPath: local.path) {
            record["static_build"] = try readJSON(local)
        } else if files.fileExists(atPath: beside.path) {
            var build = try readJSON(beside)
            build["origin"] = "explicit LTM_STATIC_DEPS override"
            record["static_build"] = build
        } else {
            record["static_build"] = ["origin": "explicit LTM_STATIC_DEPS override"]
        }
        try writeJSON(record, to: root.appendingPathComponent("native-build.json"))
    }

    /// The recipe files whose hashes native-build.json records.
    static let recipeFiles = [
        "build-support/recipes/build-package-native.sh", "build-support/recipes/build-static-deps.sh",
        "build-support/recipes/build-iboot32patcher.sh",
        "build-support/dependencies.json", "build-support/patches/glib-pipe2-availability.patch",
        "build-support/patches/iBoot32Patcher-ltm.patch", "build-support/patches/libimobiledevice-sslv3-ios1.patch",
        "build-support/patches/libplist-bin-limits.patch", "build-support/patches/libimobiledevice-reply-limits.patch",
        "build-support/patches/libusbmuxd-inetcat-writes.patch", "build-support/checks/reply-limit.c",
        "build-support/checks/inetcat-writes.c",
        "Packages/BuildTools/Sources/BuildTools/DependencySources.swift",
        "Packages/BuildTools/Sources/BuildSupport/MachOClosure.swift"
    ]

    static func isFile(_ file: URL) -> Bool {
        var directory: ObjCBool = false
        return files.fileExists(atPath: file.path, isDirectory: &directory) && !directory.boolValue
    }
}

extension Records {
    static func isLinkToDirectory(_ file: URL) -> Bool {
        guard (try? files.destinationOfSymbolicLink(atPath: file.path)) != nil else { return false }
        var directory: ObjCBool = false
        return files.fileExists(atPath: file.path, isDirectory: &directory) && directory.boolValue
    }
}
