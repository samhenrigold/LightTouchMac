import BuildSupport
import Foundation
import HostRuntime
import Testing

@testable import ReleaseChecks

/// The built app as it ships: signatures, slices, entitlements per executable, the load closure, the bundled tools,
/// hygiene and the identity scan. Seconds, no device.
@Suite(.enabled(if: appGiven, "no app: LTM_RELEASE_APP / LTM_RELEASE_ARCHIVE (the Release plan)"))
struct ReleaseAppStaticTests {
    static let archs: Set<String> = ["arm64", "x86_64"]
    let app: URL
    var contents: URL { app.appendingPathComponent("Contents") }
    init() throws { app = try ReleaseApp.app() }

    func run(_ arguments: [String], environment: [String: String]? = nil) throws -> CommandResult {
        try Shell.run(arguments, environment: environment ?? ReleaseApp.cleanEnvironment)
    }

    @Test func signatureVerifiesDeepAndStrict() throws {
        let result = try run(["codesign", "--verify", "--deep", "--strict", app.path])
        #expect(result.succeeded, "\(result.error)")
    }

    /// The helper's entitlements are exactly its build's (LightTouchDevice-Sandbox.entitlements, unless the release was
    /// built with LTM_HELPER_SANDBOX=NO), and the app carries the helper's app group exactly when the helper does.
    @Test func everyExecutableIsHardenedUniversalAndEntitledAsDeclared() throws {
        let sandbox = helperSandbox
        func entitlements(_ name: String) throws -> NSDictionary {
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: repository.appendingPathComponent("Configuration/\(name).entitlements")),
                format: nil
            ) as! NSDictionary
        }
        let qemu = try entitlements(sandbox ? "LightTouchDevice-Sandbox" : "LightTouchDevice")
        let appEntitlements: NSDictionary =
            sandbox
            ? try entitlements("LightTouchMac-Sandbox")
            : ["com.apple.security.personal-information.location": true]
        let binaries = ReleaseApp.binaries(in: app)
        #expect(binaries.count > 5)
        let resources = binaries.filter { $0.path.hasPrefix(contents.appendingPathComponent("Resources").path + "/") }
        #expect(resources.isEmpty, "Mach-O under Resources: \(resources.map(\.lastPathComponent))")
        for binary in binaries {
            let name = String(binary.path.dropFirst(app.path.count + 1))
            #expect(
                try run(["codesign", "-dv", binary.path]).error.contains("(runtime)"),
                "\(name): no hardened runtime"
            )
            // exactly the host slices, but the toolchain's Swift compatibility libraries, which carry arm64e besides
            let slices = Set(try MachOClosure.architectures(binary))
            if binary.lastPathComponent.hasPrefix("libswiftCompatibility") {
                #expect(Self.archs.isSubset(of: slices), "\(name): slices")
            } else {
                #expect(slices == Self.archs, "\(name): slices")
            }
            let dump = try run(["codesign", "-d", "--entitlements", "-", "--xml", binary.path]).output
            let granted =
                dump.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? NSDictionary()
                : try PropertyListSerialization.propertyList(from: Data(dump.utf8), format: nil) as! NSDictionary
            // The app asks Core Location only for the Carrier panel's "This Mac's Location"; nothing else is entitled.
            let want: NSDictionary =
                switch binary.lastPathComponent {
                case "LightTouchDevice": qemu
                case "LightTouch": appEntitlements
                // as Sparkle signs it; the export keeps it
                case "Autoupdate": ["com.apple.application-identifier": "org.sparkle-project.Sparkle.Autoupdate"]
                default: NSDictionary()
                }
            #expect(granted == want, "\(name): entitlements \(granted), want \(want)")
        }
    }

    /// Release honors no environment override: none of their names is in a shipped binary.
    @Test func noBinaryNamesADebugOverride() throws {
        let found = try ReleaseApp.overrideNames(in: ReleaseApp.binaries(in: app))
        #expect(found.isEmpty, "\(found)")
        // DeviceLink's negative control (a Debug helper spawned with no sandbox grants)
        for binary in ReleaseApp.binaries(in: app) {
            let data = try Data(contentsOf: binary, options: .alwaysMapped)
            #expect(data.range(of: Data("LTM_HELPER_NO_GRANTS".utf8)) == nil, "\(binary.lastPathComponent)")
        }
    }

    @Test func hostCodeLoadsOnlyFromTheBundleAtTheAppsMinimum() throws {
        let info =
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: contents.appendingPathComponent("Info.plist")),
                format: nil
            ) as! [String: Any]
        let minimum = try #require(info["LSMinimumSystemVersion"] as? String)
        #expect(minimum == "14.4")
        let host = ReleaseApp.binaries(in: app).filter {
            ["MacOS", "Frameworks"].contains($0.deletingLastPathComponent().lastPathComponent)
        }
        for binary in host {
            for arch in Self.archs.sorted() {
                #expect(throws: Never.self, "\(binary.lastPathComponent) \(arch)") {
                    try MachOClosure.check(
                        binary,
                        minimum: minimum,
                        arch: arch,
                        bundle: app,
                        executable: contents.appendingPathComponent("MacOS")
                    )
                }
            }
        }
    }

    /// QEMU 11 has no built-in AES: built without a crypto library, its cipher API is the stub, and the iPod touch 1G's
    /// 8900 engine and the A4 CDMA engine fail every decrypt, so those devices never reach USB (10-07).
    @Test func theEmulatorHasACipherBackend() throws {
        let dylib = try Data(contentsOf: contents.appendingPathComponent("Frameworks/libqemu-arm.dylib"))
        #expect(
            dylib.range(of: Data("no crypto library enabled in build".utf8)) == nil,
            "libqemu-arm.dylib has QEMU's stub cipher backend"
        )
    }

    @Test func theBundledHelperWorkerAndBridgeRunFromTheBundle() throws {
        let helper = contents.appendingPathComponent("MacOS/LightTouchDevice")
        let details = try run(["codesign", "-dvv", helper.path])
        #expect(
            details.succeeded && details.error.contains("Identifier=gold.samhenri.LightTouchMac.LightTouchDevice"),
            "\(details.error)"
        )
        let info =
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: contents.appendingPathComponent("Info.plist")),
                format: nil
            ) as! [String: Any]
        // IPSWs and .ipa files open here from Finder and the Dock, never taken over: Alternate.
        let types = (info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []).flatMap { type in
            (type["LSItemContentTypes"] as? [String] ?? []).map { ($0, type["LSHandlerRank"] as? String) }
        }
        #expect(
            Dictionary(uniqueKeysWithValues: types) == [
                "com.apple.itunes.ipsw": "Alternate", "com.apple.itunes.ipa": "Alternate"
            ]
        )
        #expect(
            info["NSSupportsAutomaticGraphicsSwitching"] as? Bool == true,
            "a dual-GPU Intel Mac would switch to its discrete GPU"
        )

        let worker = contents.appendingPathComponent("MacOS/LightTouchServices")
        #expect(try run(["codesign", "--verify", "--strict", worker.path]).succeeded)
        #expect(
            !(try run(["otool", "-L", worker.path]).output.contains("libqemu")),
            "the services worker must not load the emulator"
        )
        // No request is sent: the packaged worker launches and exits without probing a device or loading QEMU.
        var env = ReleaseApp.cleanEnvironment
        env["USBMUXD_SOCKET_ADDRESS"] = "127.0.0.1:1"
        let empty = try Shell.run(
            [worker.path, "--socket", "127.0.0.1:1", "--udid", "", "--session", UUID().uuidString],
            input: "",
            environment: env,
            timeout: 10
        )
        #expect(empty.succeeded && empty.output.isEmpty, "\(empty)")
        #expect(try run([contents.appendingPathComponent("MacOS/inetcat").path, "--version"]).succeeded)

        let probe = try Shell.run(
            [helper.path] + HelperLaunch(.machines).arguments,
            environment: ReleaseApp.cleanEnvironment,
            timeout: 60
        )
        try #require(probe.succeeded, "\(probe.error)")
        let listing = try JSONSerialization.jsonObject(with: Data(probe.output.utf8)) as! [String: Any]
        let dylib = contents.appendingPathComponent("Frameworks/libqemu-arm.dylib")
        #expect(
            URL(fileURLWithPath: listing["dylibPath"] as! String).resolvingSymlinksInPath()
                == dylib.resolvingSymlinksInPath(),
            "the helper loaded \(listing["dylibPath"] ?? ""), not the bundled dylib"
        )
        let machines = listing["machines"] as! [[String: Any]]
        let catalog =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: contents.appendingPathComponent("Resources/firmware-catalog.json"))
            ) as! [String: Any]
        let entries = catalog["entries"] as! [[String: Any]]
        #expect(
            Set(machines.compactMap { $0["board"] as? String }).isSuperset(
                of: entries.compactMap { $0["board"] as? String }
            ),
            "the emulator lacks a catalog board"
        )
        let recorded =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: repository.appendingPathComponent("tests/fixtures/machines.json"))
            ) as! [[String: Any]]
        let stale = recorded.filter { r in
            !machines.contains { NSDictionary(dictionary: $0) == NSDictionary(dictionary: r) }
        }.compactMap { $0["board"] as? String }
        #expect(
            stale.isEmpty,
            "tests/fixtures/machines.json differs from the emulator for \(stale): record LightTouchDevice's machines launch again"
        )

        // iPhone OS 1.x lockdownd is SSLv3 only: the bundled OpenSSL must have it (build-static-deps.sh).
        let imd = contents.appendingPathComponent("Frameworks/libimobiledevice-1.0.dylib")
        #expect(
            try run(["nm", "-gU", imd.path]).output.contains("_SSLv3_client_method"),
            "libimobiledevice links an OpenSSL without SSLv3"
        )
    }

    @Test func theDeviceAssetsAndTheFirstRunEntry() throws {
        let catalog =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: contents.appendingPathComponent("Resources/firmware-catalog.json"))
            ) as! [String: Any]
        #expect(catalog["bundled"] as? [String: String] == ["n72ap-7E18": "Device/n72ap-7E18.itbase"])
        let device = contents.appendingPathComponent("Resources/Device")
        let assets = ["bootrom_240_4", "bootrom_s5l8900", "n72ap-7E18.itbase"]
        #expect(
            Set(try FileManager.default.contentsOfDirectory(atPath: device.path).filter { !$0.hasPrefix(".") })
                == Set(assets),
            "the SecureROMs and the built-in iPod only (no raw pages, no iBoot)"
        )
        let index =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: device.appendingPathComponent("n72ap-7E18.itbase/index.json"))
            ) as? [String: Any]
        #expect(index?["format"] as? Int == 2, "the built-in iPod is not a packed device")
        let entries = catalog["entries"] as! [[String: Any]]
        let first = try #require(entries.first { $0["id"] as? String == catalog["first_run"] as? String })
        #expect(first["status"] as? String == "available")
        #expect(
            ((first["source"] as? [String: Any])?["url"] as? String)?.hasPrefix("https://secure-appldnld.apple.com/")
                == true
        )
    }

    /// Tweaks' Developer Settings: every pinned Developer Disk Image and signature (4.2 to 7.1) in the guest archive,
    /// as pinned.
    @Test func theDeveloperDiskImages() throws {
        let unpacked = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-ddi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: unpacked) }
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let extracted = try run([
            "aa", "extract", "-i", contents.appendingPathComponent("Resources/Guest/guest.aar").path, "-d",
            unpacked.path, "-include-path", "developer-disk-images"
        ])
        #expect(extracted.succeeded, "\(extracted.error)")
        let manifest =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: repository.appendingPathComponent("build-support/developer-disk-images.json"))
            ) as! [String: Any]
        let pinned = manifest["packages"] as! [[String: Any]]
        let versions = Set(pinned.map { $0["version"] as! String })
        #expect(versions == ["4.2", "4.3", "5.0", "5.1", "6.0", "6.1", "7.0", "7.1"])
        for image in pinned {
            let version = image["version"] as! String
            let name = (image["archive"] as! String).replacingOccurrences(of: "-\(version)", with: "")
            let file = unpacked.appendingPathComponent("developer-disk-images/\(version)/\(name)")
            #expect(
                (try? sha256Hex(Data(contentsOf: file))) == image["sha256"] as? String,
                "developer-disk-images/\(version)/\(name) is missing or not the pinned one"
            )
        }
    }

    @Test func theBundleIsBuiltFromTheCurrentPins() throws {
        let inputs =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: contents.appendingPathComponent("Resources/build-inputs.json"))
            ) as! [String: Any]
        let pins =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: repository.appendingPathComponent("build-support/sources.json"))
            ) as! [String: Any]
        for name in ["qemu-ios", "usbmuxd"] {
            let built = ((inputs["pins"] as? [String: Any])?[name] as? [String: Any])?["commit"] as? String
            let pinned = (pins[name] as? [String: Any])?["commit"] as? String
            #expect(
                built != nil && built == pinned,
                "\(name): built from \(built ?? "?"), pinned \(pinned ?? "?"): run scripts/vendor and archive again"
            )
        }
    }

    /// Every dylib the vendor directory ships reaches the app's Frameworks (Xcode's Embed Vendor Frameworks names them
    /// one by one; ANGLE's were left out once, and the experimental ANGLE renderer fell back to CGL).
    @Test func everyVendorDylibIsEmbedded() throws {
        let print = try run(["/bin/bash", repository.appendingPathComponent("scripts/vendor-check").path, "--print"])
        let vendor = URL(fileURLWithPath: print.output.trimmingCharacters(in: .whitespacesAndNewlines))
            .appendingPathComponent("Frameworks")
        try #require(print.succeeded, "\(print.output)")
        let shipped = try FileManager.default.contentsOfDirectory(atPath: vendor.path).filter { $0.hasSuffix(".dylib") }
        #expect(shipped.contains("libGLESv2.dylib") && shipped.contains("libEGL.dylib"))
        let embedded = Set(
            try FileManager.default.contentsOfDirectory(atPath: contents.appendingPathComponent("Frameworks").path)
        )
        #expect(
            Set(shipped).subtracting(embedded).isEmpty,
            "not embedded: \(Set(shipped).subtracting(embedded).sorted())"
        )
    }

    @Test func hygieneLicensesAndNoLocalPaths() throws {
        // The project's: scripts/ship archives the project, so these are the versions the app was built with.
        let resolved = [
            repository.appendingPathComponent(
                "LightTouchMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
            ),
            repository.appendingPathComponent("Packages/FirmwareKit/Package.resolved")
        ]
        let inputs =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: contents.appendingPathComponent("Resources/build-inputs.json"))
            ) as? [String: Any]
        let packages = try BundleHygiene.swiftPackages(
            resolved: resolved,
            unlinked: inputs?["swift_packages_unlinked"] as? [String] ?? []
        )
        let found = try BundleHygiene.problems(app: app, packages: packages)
        #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
    }

    /// The identity scan of a zip of the app (tools/release/scan-release-zip.py).
    @Test func identityScanOfTheZippedApp() throws {
        let scanner = repository.appendingPathComponent("tools/release/scan-release-zip.py")
        try withScratch { root in
            let zip = root.appendingPathComponent("LightTouchMac.zip")
            try #require(try Shell.run(["ditto", "-c", "-k", "--keepParent", app.path, zip.path]).succeeded)
            let scan = try Shell.run(["python3", scanner.path, zip.path], environment: ReleaseApp.cleanEnvironment)
            #expect(scan.succeeded, "\((scan.output + scan.error).suffix(600))")
        }
    }

    /// An export (scripts/ship: exported for Developer ID, zipped and unzipped): stapled and accepted by Gatekeeper.
    @Test(.enabled(if: ReleaseApp.exported, "not an export (LTM_RELEASE_EXPORTED=1)"))
    func anExportIsStapledAndPassesGatekeeper() throws {
        #expect(try run(["xcrun", "stapler", "validate", app.path]).succeeded, "no stapled notarization ticket")
        let assess = try run(["spctl", "-a", "-vv", "-t", "exec", app.path])
        #expect(
            assess.succeeded && (assess.output + assess.error).contains("source=Notarized Developer ID"),
            "\(assess.error)"
        )
    }
}
