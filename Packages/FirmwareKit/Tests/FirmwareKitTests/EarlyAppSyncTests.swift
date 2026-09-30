import Foundation
import Testing
@testable import FirmwareKit

struct EarlyAppSyncTests {
    @Test(arguments: [true, false], [true, false])
    func preparesInstallationService(lockbot: Bool, sharedCache: Bool) throws {
        guard let path = ProcessInfo.processInfo.environment["FK_EARLY_APPSYNC_HELPERS"] else { return }
        let helpers = URL(fileURLWithPath: path)
        try Oracle.withTemp { root in
            let fm = FileManager.default
            try fm.createDirectory(at: root.appendingPathComponent("usr/libexec"), withIntermediateDirectories: true)
            let libmis = root.appendingPathComponent("usr/lib/libmis.dylib")
            try fm.createDirectory(at: libmis.deletingLastPathComponent(), withIntermediateDirectories: true)
            let untouched = Data("stock system trust library".utf8)
            try untouched.write(to: libmis)
            let cache = root.appendingPathComponent("System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7")
            if sharedCache {
                try fm.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try untouched.write(to: cache) // opaque cache must not be parsed or patched by AppSync.
            }
            let relative = lockbot ? "System/Library/Lockdown/Services.plist" : SystemEdits.installdJob
            let plist = root.appendingPathComponent(relative)
            try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            let job: [String: Any] = ["Label": "com.apple.mobile.installation_proxy", "UserName": "mobile",
                                      "ProgramArguments": ["/usr/libexec/mobile_installation_proxy", "argument"],
                                      "EnvironmentVariables": ["EXISTING": "keep"]]
            let original: [String: Any] = lockbot ? ["com.apple.mobile.installation_proxy": job, "unrelated": ["Label": "keep"]] : job
            try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0).write(to: plist)
            _ = try SystemEdits.installAppSync(root, helper: helpers.appendingPathComponent(SystemEdits.Helpers.appsync), cache: sharedCache ? "System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7" : "absent-cache", log: { _ in })
            let output = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
            let service = lockbot ? output["com.apple.mobile.installation_proxy"] as! [String: Any] : output
            #expect(service["UserName"] as? String == "mobile")
            #expect((service["EnvironmentVariables"] as? [String: String])?["EXISTING"] == "keep")
            if lockbot {
                #expect(service["ProgramArguments"] as? [String] == ["/usr/libexec/appsync-launch", "/usr/libexec/mobile_installation_proxy", "argument"])
                #expect((output["unrelated"] as? [String: String])?["Label"] == "keep")
                let launcher = root.appendingPathComponent(SystemEdits.appsyncLauncherPath)
                #expect(try Data(contentsOf: launcher) == Data(contentsOf: helpers.appendingPathComponent(SystemEdits.Helpers.appsyncLauncher)))
                #expect((try fm.attributesOfItem(atPath: launcher.path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
            } else {
                #expect((service["EnvironmentVariables"] as? [String: String])?["DYLD_INSERT_LIBRARIES"] == "/usr/lib/libappsync.dylib")
                #expect(!fm.fileExists(atPath: root.appendingPathComponent(SystemEdits.appsyncLauncherPath).path))
            }
            #expect(try Data(contentsOf: libmis) == untouched)
            if sharedCache { #expect(try Data(contentsOf: cache) == untouched) }
        }
    }

    @Test func refusesModernLoaderCommands() throws {
        try Oracle.withTemp { root in
            var bytes = Data(count: 28 + 48)
            func put(_ offset: Int, _ value: UInt32) {
                for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
            }
            put(0, 0xfeedface); put(4, 12); put(8, 6); put(12, 6)
            put(16, 1); put(20, 48); put(28, 0x80000022); put(32, 48)
            let target = root.appendingPathComponent("modern.dylib")
            try bytes.write(to: target)
            #expect(MachOSignature.earlyARMProblem(target)?.contains("newer dyld") == true)
        }
    }
}
