import BuildSupport
import Foundation
import Testing

@testable import BuildTools

struct NativeCacheTests {
    static let repository = URL(fileURLWithPath: #filePath).appendingPathComponent("../../../../..").standardized

    @Test func packagingChangesReuseNativeInputsWhilePinsRecipesAndToolchainInvalidateThem() throws {
        try withScratch { root in
            let vendor = Vendor(root: root)
            for name in [
                "build-support", "scripts", "Packages/BuildTools/Package.swift", "Packages/BuildTools/Package.resolved",
                "Packages/BuildTools/Sources"
            ] {
                try vendor.copy(Self.repository.appendingPathComponent(name), root.appendingPathComponent(name))
            }
            let toolchain = ["xcode": "test build", "sdk": "test SDK"]
            let key = try vendor.nativeKey(toolchain: toolchain)
            let packageKey = try vendor.pinKey()
            let release = root.appendingPathComponent("Packages/BuildTools/Sources/BuildTools/ReleaseHelper.swift")
            try Data("changed packaging".utf8).write(to: release)
            #expect(try vendor.nativeKey(toolchain: toolchain) == key)
            #expect(try vendor.pinKey() != packageKey)
            #expect(try vendor.nativeKey(toolchain: ["xcode": "new build", "sdk": "test SDK"]) != key)
            var pins = try readJSON(root.appendingPathComponent("build-support/sources.json"))
            var qemu = pins["qemu-ios"] as? [String: Any] ?? [:]
            qemu["commit"] = "a different emulator"
            pins["qemu-ios"] = qemu
            try writeJSON(pins, to: root.appendingPathComponent("build-support/sources.json"))
            #expect(try vendor.nativeKey(toolchain: toolchain) != key)
            let pinnedKey = try vendor.nativeKey(toolchain: toolchain)
            try Data("changed recipe".utf8).write(
                to: root.appendingPathComponent("build-support/recipes/build-package-native.sh"))
            #expect(try vendor.nativeKey(toolchain: toolchain) != pinnedKey)
        }
    }

    @Test func twoVendorPackagesShareOneNativeTreeWithoutCopyingItsBuildOutputs() throws {
        try withScratch { root in
            let vendor = Vendor(root: root, environment: ["LTM_VENDOR_ROOT": root.appendingPathComponent("cache").path])
            let a = root.appendingPathComponent("package-a/work")
            let b = root.appendingPathComponent("package-b/work")
            for work in [a, b] { try files.createDirectory(at: work, withIntermediateDirectories: true) }
            let cache = try vendor.sharedNative(a)
            let payload = cache.appendingPathComponent("native/arm64/prefix/payload")
            try files.createDirectory(at: payload.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("built once".utf8).write(to: payload)
            #expect(try vendor.sharedNative(b).path == cache.path)
            #expect(
                try Data(contentsOf: b.appendingPathComponent("native/arm64/prefix/payload")) == Data("built once".utf8)
            )
            #expect(
                try files.destinationOfSymbolicLink(atPath: a.appendingPathComponent("native-cache").path) == cache.path
            )
            #expect(
                try files.destinationOfSymbolicLink(atPath: b.appendingPathComponent("native-cache").path) == cache.path
            )
            // A real directory may contain an older/in-progress build. Never overwrite it to install a cache link.
            try files.removeItem(at: b.appendingPathComponent("angle"))
            try files.createDirectory(at: b.appendingPathComponent("angle"), withIntermediateDirectories: true)
            #expect(throws: ToolError.self) { try vendor.sharedNative(b) }
        }
    }

    @Test func aCompletionRecordWithoutTheActualLibrariesIsNotAReusableBuild() throws {
        try withScratch { root in
            try Data("{}".utf8).write(to: root.appendingPathComponent("native-build.json"))
            #expect(!Vendor.nativeComplete(root))
        }
    }
}
