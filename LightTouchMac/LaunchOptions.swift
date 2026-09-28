// Created by Sam on 2026-08-05.
//
// The app's own launch configuration, parsed with swift-argument-parser
// instead of hand-rolled env/CommandLine poking. Parsing is lenient: when the
// app is launched by Xcode or Finder (which inject their own flags), unknown
// arguments fall back to defaults rather than aborting.

import ArgumentParser
import Foundation

struct LaunchOptions: ParsableArguments {
    
    @Option(name: .long, help: "Directory holding the device assets (bootrom, NAND, NOR, iBoot).")
    var filesRoot: String = LaunchOptions.defaultFilesRoot
    
    /// LTM_FILES wins; then a bundled Resources/device (a packaged app); then
    /// the dev checkout.
    static var defaultFilesRoot: String {
        if let env = ProcessInfo.processInfo.environment["LTM_FILES"] { return env }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("device").path,
           FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        return "\(NSHomeDirectory())/Developer/qemu-ios-files"
    }
    
    /// `nand-current` is a symlink in the dev checkout naming the image that
    /// ships. It resolves to its target's name so device state stays keyed by
    /// the real image: repointing it starts a fresh overlay instead of
    /// replaying the old one onto different flash. A packaged app has no such
    /// link and keeps the legacy "nand-ultimate" label its state is keyed by.
    @Option(name: .long, help: "NAND image directory name under files-root.")
    var nand: String = "nand-current"
    
    @Flag(name: .long, inversion: .prefixedNo,
          help: "Start usbmuxd so apps can be installed and managed over USB.")
    var appsync: Bool = true
    
    @Flag(name: .long, inversion: .prefixedNo,
          help: "Emulated Wi-Fi with host networking (slirp).")
    var network: Bool = true
    
    @Option(name: .long, help: "Guest RAM.")
    var memory: String = "128M"
    
    /// Parse leniently — Xcode/Finder inject flags we don't recognise, so fall
    /// back to an all-defaults parse (an empty argument list) rather than the
    /// synthesized `init()`, which leaves the property wrappers unpopulated.
    static func resolved() -> LaunchOptions {
        var options = (try? parse(Array(CommandLine.arguments.dropFirst())))
            ?? (try? parse([])) ?? { fatalError("LaunchOptions has a required field without a default") }()
        if options.nand == "nand-current" {
            let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "\(options.filesRoot)/nand-current")
            options.nand = target.map { ($0 as NSString).lastPathComponent } ?? "nand-ultimate"
        }
        return options
    }
    
    // MARK: - Derived paths
    
    var bootrom: String { "\(filesRoot)/bootrom_240_4" }
    var iBoot: String   { "\(filesRoot)/ios3/iBoot.bin" }
    var nor: String     { "\(filesRoot)/ios3/nor_7E18.bin" }
    var nandImage: String { "\(filesRoot)/\(nand)" }
    /// A packaged app ships the NAND as ONE opaque blob rather than raw page
    /// files: Apple's notary walks every file in the bundle and rejects the
    /// armv6 Mach-Os that a raw iOS filesystem inevitably contains (see
    /// qemu-ios contrib/macos-app/nandpack.py). Unpacked on first boot.
    var packedNAND: String { "\(filesRoot)/nand.itnand" }

    /// iPad 1 (LIGHTTOUCH_DEVICE=ipad1): a kernel-direct boot bundle and a NAND
    /// page store, both produced by qemu-ios/imgtools. See docs/archive/ipad1-in-app.md.
    var ipad1KBoot: String { "\(filesRoot)/ipad1/7B500/k48-kboot.bin" }
    var ipad1NAND: String  { "\(filesRoot)/ipad1/userland/golden-appsync" }

    /// What the pre-library state keys were derived from (LegacyAdoption).
    var adoptionInputs: LegacyAdoption.Inputs {
        .init(filesRoot: filesRoot, nand: nand, nandImage: nandImage, packedNAND: packedNAND, ipad1NAND: ipad1NAND)
    }

    /// Development override for which board a launch runs: LIGHTTOUCH_DEVICE=ipad1
    /// (or ipod). With LTM_FILES it chooses, or adopts, that device's instance.
    static var deviceOverride: DeviceProfile? {
        switch ProcessInfo.processInfo.environment["LIGHTTOUCH_DEVICE"] {
        case "ipad1": .iPad1
        case "ipod": .iPodTouch2G
        default: nil
        }
    }

    /// Required assets that don't exist, so the app can report them up front
    /// instead of failing inside the dylib on the QEMU thread with no UI — a
    /// missing NAND used to be an invisible hang.
    func missingAssets(for profile: DeviceProfile) -> [String] {
        let fm = FileManager.default
        if profile == .iPad1 {
            return [filesRoot, ipad1KBoot, ipad1NAND].filter { !fm.fileExists(atPath: $0) }
        }
        var missing = [filesRoot, bootrom, iBoot, nor].filter { !fm.fileExists(atPath: $0) }
        if !fm.fileExists(atPath: nandImage), !fm.fileExists(atPath: packedNAND) {
            missing.append(nandImage)
        }
        return missing
    }
}
