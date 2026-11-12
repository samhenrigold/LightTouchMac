// The N42's restore boot bundle: the IPSW's own restored_external RAM disk with our initializer in its place (plus
// the prepared Data seed, the activation plan and its MobileGestalt worker), and kboot-restore.bin booting it. The
// N42 recipe's store step and firmwarekit-prepare's --a6-restore both write it here.

import Foundation

public enum A6RestoreBundle {
    public struct Inputs {
        public var decrypted: URL
        /// it_initialize, which becomes the RAM disk's restored_external.
        public var initializer: URL
        /// it_mobilegestalt, staged with the activation plan.
        public var mobileGestalt: URL?
        public var factoryFormat = false
        public var dataSeed: URL?
        public var seedBaseSystem: URL?
        public var activationPlan: URL?
        public var guestAssetsSystem: URL?
        public var extraBootArgs = ""
        public init(decrypted: URL, initializer: URL) {
            self.decrypted = decrypted
            self.initializer = initializer
        }
    }

    /// Writes `work`/restore-ramdisk.hfs and `work`/kboot-restore.bin; returns the restore's guest assets, if any.
    @discardableResult
    public static func write(
        _ i: Inputs,
        work: URL,
        identity: UnitIdentity,
        log: (String) -> Void = { _ in }
    ) throws -> [A6GuestAssets.Asset]? {
        let dec = i.decrypted
        let files = try FileManager.default.contentsOfDirectory(atPath: dec.path)
            .filter { $0.hasSuffix("-ramdisk.dmg") }.sorted()
        // Update ramdisks can sort before restore ramdisks. Select the
        // original native restore service, never an arbitrary filename.
        let restoreCandidates = try files.compactMap { name -> HFSPlusVolume? in
            let candidate = try HFSPlusVolume(dec.appendingPathComponent(name))
            guard (try? candidate.record(at: "usr/local/bin/restored_external")) != nil else { return nil }
            let hasJob =
                (try? candidate.record(at: "System/Library/LaunchDaemons/com.apple.restored_external.plist")) != nil
            // Earlier restore images invoke the service from their native
            // rc.boot executable instead of a launchdaemon. Both layouts
            // must identify the erase service, not restored_update.
            let service = Data("/usr/local/bin/restored_external\0".utf8)
            let hasBootInvocation = ["private/etc/rc.boot", "etc/rc.boot"].contains { path in
                guard let record = try? candidate.record(at: path),
                    let contents = try? candidate.contents(record)
                else { return false }
                return contents.range(of: service) != nil
            }
            guard hasJob || hasBootInvocation else { return nil }
            return candidate
        }
        guard restoreCandidates.count == 1, let source = restoreCandidates.first else {
            throw FirmwareError(
                .unsupported, "Expected exactly one native restored_external RAM disk, found \(restoreCandidates.count)"
            )
        }
        let rd = work.appendingPathComponent("restore-ramdisk.hfs")
        let paths = try source.paths().sorted {
            $0.path.split(separator: "/").count < $1.path.split(separator: "/").count
        }
        // Compressed restore images can expand beyond their volume size when
        // materialized. Reserve their actual file bytes plus catalog/helper
        // space; keep the same preparation path for every supported release.
        let fileBytes = try paths.reduce(UInt64(0)) { total, item in
            total + (item.record.kind == .file ? try source.size(item.record) : 0)
        }
        let mib = 1 << 20
        let ramdiskBytes = max(64 << 20, ((Int(fileBytes) + mib - 1) / mib + 32) * mib)
        try HFSPlusWriter.makeHFS(rd, size: Int64(ramdiskBytes), name: "Restore", journaled: false)
        let writer = try HFSPlusWriter(rd)
        do {
            for item in paths {
                let p = item.path
                let r = item.record
                if p.isEmpty { continue }
                writer.owner = (r.uid, r.gid)
                if r.kind == .folder {
                    try writer.makeDirectory(p, mode: r.mode & 0o7777)
                } else if r.isSymlink {
                    try writer.makeSymlink(p, to: String(decoding: source.contents(r), as: UTF8.self))
                } else {
                    try writer.put(source.contents(r), at: p, mode: r.mode & 0o7777)
                }
            }
            writer.owner = (0, 0)
            try writer.put(contentsOf: i.initializer, at: "usr/local/bin/restored_external", mode: 0o755)
            if let dataSeed = i.dataSeed { try stageSeed(dataSeed, base: i.seedBaseSystem, into: writer) }
            if let activationPlan = i.activationPlan {
                guard let worker = i.mobileGestalt else {
                    throw FirmwareError(.internal, "An activation plan needs the MobileGestalt worker")
                }
                let workerData = try Data(contentsOf: worker)
                try A6RestoreCache.validate(
                    plan: Data(contentsOf: activationPlan),
                    originalLibrary: source.contents(source.record(at: "usr/lib/libMobileGestalt.dylib")),
                    helper: workerData)
                writer.owner = (0, 0)
                try writer.put(workerData, at: "usr/local/bin/it_mobilegestalt", mode: 0o755)
                try writer.makeDirectory("usr/local/share/qemu", mode: 0o755)
                try writer.put(
                    contentsOf: activationPlan, at: "usr/local/share/qemu/activation-plan.plist", mode: 0o644)
            }
            try writer.close()
        } catch {
            try? writer.close()
            throw error
        }
        let originalKernel = try Data(contentsOf: dec.appendingPathComponent("kernelcache.mach"))
        let assets = try i.guestAssetsSystem.map {
            try A6GuestAssets.prepare(kernel: originalKernel, system: $0, restoreRAMDisk: rd)
        }
        var restoreKernel = assets?.kernel
        if i.factoryFormat {
            let version =
                try PropertyListSerialization.propertyList(
                    from: source.contents(source.record(at: "System/Library/CoreServices/SystemVersion.plist")),
                    format: nil) as? [String: Any]
            guard let build = version?["ProductBuildVersion"] as? String else {
                throw FirmwareError(.unsupported, "Native restore build identity missing")
            }
            restoreKernel = try A6RestoreKernel.prepare(restoreKernel ?? originalKernel, build: build, log: log)
        }
        try KBoot.write(
            decrypted: dec, to: work.appendingPathComponent("kboot-restore.bin"), identity: identity,
            bootArgs: A6Preparation.defaultBootArgs + " -v" + (i.factoryFormat ? " nand-enable-reformat=1" : "")
                + i.extraBootArgs,
            ramdisk: rd, kernelOverride: restoreKernel)
        return assets?.assets
    }

    /// FirmwareKit's Data additions under usr/local/share/qemu/data-seed: the prepared Data volume less what the
    /// stock System's /private/var already has (the initializer copies that natively once the keybag exists).
    private static func stageSeed(_ dataSeed: URL, base seedBaseSystem: URL?, into writer: HFSPlusWriter) throws {
        let source = try HFSPlusVolume(dataSeed)
        let seedBase = try seedBaseSystem.map { try HFSPlusVolume($0) }
        let target = "usr/local/share/qemu/data-seed"
        guard (try? source.record(at: "keybags/systembag.kb")) == nil else {
            throw FirmwareError(.unsupported, "Prepared Data seed must not contain a device keybag")
        }
        try writer.makeDirectory(target, mode: 0o755)
        for item in try source.paths().sorted(by: {
            $0.path.split(separator: "/").count < $1.path.split(separator: "/").count
        }) {
            if let first = item.path.split(separator: "/").first,
                [".journal", ".journal_info_block"].contains(String(first))
                    || VolumeMount.junk.contains(String(first)) || first.hasPrefix(".HFS+")
            {
                continue
            }
            let r = item.record
            let path = item.path.isEmpty ? target : target + "/" + item.path
            if r.kind != .folder, let seedBase,
                let old = try? seedBase.record(at: "private/var/" + item.path),
                old.kind == r.kind, old.uid == r.uid, old.gid == r.gid, old.mode == r.mode,
                try seedBase.contents(old) == source.contents(r)
            {
                continue
            }
            writer.owner = (r.uid, r.gid)
            if item.path.isEmpty {
                try writer.setAttributes(path, uid: r.uid, gid: r.gid, mode: r.mode & 0o7777)
            } else if r.kind == .folder {
                try writer.makeDirectory(path, mode: r.mode & 0o7777)
            } else if r.isSymlink {
                try writer.makeSymlink(path, to: String(decoding: source.contents(r), as: UTF8.self))
            } else {
                try writer.put(source.contents(r), at: path, mode: r.mode & 0o7777)
            }
        }
    }
}
