import Foundation

/// Shared System/Data preparation for N42, using the same volume editor and
/// activation/graphics/guest-service components as the existing board recipes.
public enum A6Preparation {
    /// Match the qualified N42 guest-support handoff, including the AMFI
    /// setting already used by its restore path and earlier normal profiles.
    public static let defaultBootArgs = KBoot.defaultBootArgs + " amfi_get_out_of_my_way=1"

    public static func volumes(ipsw: URL, decrypted: URL, helpers: URL, out: URL,
                               log: (String) -> Void = { _ in }) async throws -> SystemEdits.Result {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: out.path) else { throw FirmwareError(.internal, "A6 volume output already exists") }
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let layout = try A6StorageLayout()
        var options = SystemEdits.Options()
        options.caOGL = true; options.webProxy = false; options.appsync = false
        options.guestTools = false; options.seal = false; options.skipSetup = true
        options.nativeGestaltActivation = true
        options.locationServicesEnabled = true
        let fit = FitCheck.Log()
        let result = try await SystemEdits.buildK48(rootfs: decrypted.appendingPathComponent("rootfs.dmg"),
            work: out, systemBytes: Int(layout.systemBytes), dataBytes: Int64(layout.dataBytes),
            options: options, helpers: helpers, firmwareArch: "armv7s",
            kernel: Data(contentsOf: decrypted.appendingPathComponent("kernelcache.mach")), fit: fit, log: log)
        let writer = try HFSPlusWriter(result.system)
        writer.owner = (0, 0)
        do {
            let build = writer.plist(at: "System/Library/CoreServices/SystemVersion.plist")?["ProductBuildVersion"] as? String
            if build == "14G61" {
                let path = "System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7s"
                let bytes = try writer.contents(at: path)
                let prepared = try A6GraphicsCache.prepare(bytes, build: "14G61")
                if prepared != bytes { try writer.put(prepared, at: path, mode: 0o644) }
                log("14G61 development cache enables the installed OpenGLES framework; native code retained")
            }
            let files = try BasebandFirmware.installMav5(from: IPSWArchive(ipsw), board: "n42ap", system: writer)
            log("Original modem firmware: \(files.count) files")
            try writer.close()
        } catch { try? writer.close(); throw error }
        try SideloadTools.install(system: result.system, helpers: helpers)
        try layout.partitionTable().write(to: out.appendingPathComponent("mbr.bin"), options: .withoutOverwriting)
        try JSONSerialization.data(withJSONObject: fit.fits.map(\.object), options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("fit.json"))
        if let activation = result.activation {
            try JSONSerialization.data(withJSONObject: activation.record, options: [.prettyPrinted, .sortedKeys])
                .write(to: out.appendingPathComponent("activation.json"))
            if activation.nativeCacheRequired == true, let overrides = activation.gestaltOverrides {
                let system = try HFSPlusWriter(result.system)
                let build = system.plist(at: "System/Library/CoreServices/SystemVersion.plist")?["ProductBuildVersion"] as? String
                try system.close()
                guard let build else { throw FirmwareError(.unsupported, "No native cache build identity") }
                let plan = try PropertyListSerialization.data(fromPropertyList: ["Build": build, "Overrides": overrides], format: .xml, options: 0)
                try plan.write(to: out.appendingPathComponent("activation-plan.plist"), options: .withoutOverwriting)
                if build == "14G61" {
                    let preparation = try A6FirstBoot.install(system: result.system, data: result.data, activationPlan: plan)
                    try preparation.write(to: out.appendingPathComponent("first-boot-preparation.json"), options: .withoutOverwriting)
                    log("14G61 preparation records retained through native migration; no userland sealing boot required")
                }
                log("Native activation plan staged; require verified cache initialization before normal boot")
            }
        }
        return result
    }
}
