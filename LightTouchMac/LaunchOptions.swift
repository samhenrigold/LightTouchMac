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
    
    @Option(name: .long, help: "NAND image directory name under files-root.")
    var nand: String = "nand-appsync3"
    
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
        if let parsed = try? parse(Array(CommandLine.arguments.dropFirst())) {
            return parsed
        }
        return (try? parse([])) ?? { fatalError("LaunchOptions has a required field without a default") }()
    }
    
    // MARK: - Derived paths
    
    var bootrom: String { "\(filesRoot)/bootrom_240_4" }
    var iBoot: String   { "\(filesRoot)/ios3/iBoot.bin" }
    var nor: String     { "\(filesRoot)/ios3/nor_7E18.bin" }
    var nandImage: String { "\(filesRoot)/\(nand)" }
}
