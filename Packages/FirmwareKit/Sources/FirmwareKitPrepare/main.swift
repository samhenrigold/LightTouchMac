import FirmwareKit
import Foundation

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }
let args = CommandLine.arguments
if args.count == 5 && args[1] == "--a6-initial-restore" {
    do {
        try A6RestoreStream.writeInitial(system: URL(fileURLWithPath: args[2]),
            data: URL(fileURLWithPath: args[3]), output: URL(fileURLWithPath: args[4]))
        print("Prepared initial native restore with all allocated blocks and full-size partition map")
        exit(0)
    } catch { fail(String(describing: error)) }
}
if args.count == 4 && args[1] == "--a6-factory-nand" {
    do {
        try A6NAND.create(at: URL(fileURLWithPath: args[2]))
        try A6NAND.factoryHeader().write(to: URL(fileURLWithPath: args[3]), options: .withoutOverwriting)
        print("Created new sparse N42 PPN media; native restore must format the FTL")
        exit(0)
    } catch { fail(String(describing: error)) }
}
if args.count == 6 && args[1] == "--a6-volumes" {
    do {
        let r = try await A6Preparation.volumes(ipsw: URL(fileURLWithPath: args[2]),
            decrypted: URL(fileURLWithPath: args[3]), helpers: URL(fileURLWithPath: args[4]),
            out: URL(fileURLWithPath: args[5]), log: { print($0); fflush(stdout) })
        print("Prepared new N42 volumes: \(r.system.path), \(r.data.path)")
        exit(0)
    } catch { fail(String(describing: error)) }
}
if args.count == 4 && args[1] == "--shared-cache-rehash" {
    do {
        let output = URL(fileURLWithPath: args[3])
        guard !FileManager.default.fileExists(atPath: output.path) else { fail("Expected a new output path") }
        let cache = try DyldSharedCache(contentsOf: URL(fileURLWithPath: args[2]))
        let result = try cache.rehashingCodeSignature()
        try result.write(to: output, options: .withoutOverwriting)
        print("Refreshed existing shared-cache code-page hashes; payload and signature layout preserved")
        exit(0)
    } catch { fail(String(describing: error)) }
}
if args.count == 5 && args[1] == "--a6-guest-assets" {
    do {
        let output = URL(fileURLWithPath: args[4])
        guard !FileManager.default.fileExists(atPath: output.path),
              !FileManager.default.fileExists(atPath: output.path + ".json") else { fail("Expected new output paths") }
        let result = try A6GuestAssets.prepare(kernel: Data(contentsOf: URL(fileURLWithPath: args[2]), options: .alwaysMapped),
                                               system: URL(fileURLWithPath: args[3]))
        try result.kernel.write(to: output, options: .withoutOverwriting)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result.assets).write(to: URL(fileURLWithPath: output.path + ".json"), options: .withoutOverwriting)
        print("Prepared exact native guest assets: \(result.assets.count)")
        exit(0)
    } catch { fail(String(describing: error)) }
}
if args.count == 4 && args[1] == "--a6-layout" {
    do {
        guard let systemBytes = UInt64(args[2]) else { fail("Expected System size in bytes") }
        let layout = try A6StorageLayout(systemBytes: systemBytes)
        try layout.partitionTable().write(to: URL(fileURLWithPath: args[3]), options: .withoutOverwriting)
        print("A6 media=\(layout.mediaBytes) System=\(layout.systemBytes) Data=\(layout.dataBytes) Data-offset=\(layout.dataOffset)")
        exit(0)
    } catch { fail(String(describing: error)) }
}
if args.count == 6 && args[1] == "--hfs-mav5-firmware" {
    do {
        let source = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3])
        guard !FileManager.default.fileExists(atPath: output.path) else { fail("Expected a new output path") }
        try FileManager.default.copyItem(at: source, to: output)
        let writer = try HFSPlusWriter(output)
        writer.owner = (0, 0)
        let paths = try BasebandFirmware.installMav5(from: IPSWArchive(URL(fileURLWithPath: args[4])),
                                                   board: args[5], system: writer)
        try writer.close()
        print("Installed original IPSW modem assets: \(paths.joined(separator: ", "))")
        exit(0)
    } catch { fail(String(describing: error)) }
}
if args.count == 5 && args[1] == "--finished-setup-seeds" {
    do {
        guard let major = Int(args[2]), (5...8).contains(major) else { fail("Expected supported setup major version 5...8") }
        let output = URL(fileURLWithPath: args[4])
        guard !FileManager.default.fileExists(atPath: output.path) else { fail("Expected a new output directory") }
        let seeds = try SystemEdits.finishedSetupPlists(major: major, productVersion: args[3])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (path, bytes) in seeds {
            let target = output.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target)
        }
        print("Exported shared finished-setup records for native provisioning")
        exit(0)
    } catch { fail(String(describing: error)) }
}
if args.count == 4 && args[1] == "--hfs-content-protection" {
    do {
        let source = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3])
        guard !FileManager.default.fileExists(atPath: output.path) else { fail("Expected a new output path") }
        try FileManager.default.copyItem(at: source, to: output)
        try HFSPlusVolume(output, writable: true).setContentProtection()
        print("Enabled the shared Data-format content-protection flag in a separate image")
        exit(0)
    } catch { fail(String(describing: error)) }
}
if args.count == 7 && args[1] == "--hfs-finish-setup" {
    do {
        let systemSource = URL(fileURLWithPath: args[2]), dataSource = URL(fileURLWithPath: args[3])
        let systemOutput = URL(fileURLWithPath: args[4]), dataOutput = URL(fileURLWithPath: args[5])
        guard let major = Int(args[6]), major >= 5,
              !FileManager.default.fileExists(atPath: systemOutput.path),
              !FileManager.default.fileExists(atPath: dataOutput.path) else {
            fail("Expected new output paths and an iOS major version >= 5")
        }
        try FileManager.default.copyItem(at: systemSource, to: systemOutput)
        try FileManager.default.copyItem(at: dataSource, to: dataOutput)
        let previousOwners = try HFSPlusVolume(dataSource).owners(under: "")
        let system = try HFSPlusWriter(systemOutput), data = try HFSPlusWriter(dataOutput)
        system.owner = (0, 0)
        data.owner = (0, 0)
        let activation = try SystemEdits.prepareLocalSetup(system: system, data: data, major: major) { print($0) }
        try system.close()
        try data.close()
        // Match buildK48's Data-volume ownership policy for newly seeded files;
        // existing native files retain their owners and modes.
        let preparedData = try HFSPlusVolume(dataOutput, writable: true)
        let newPaths = try preparedData.owners(under: "").keys.filter { previousOwners[$0] == nil }
        let mobile = newPaths.filter { $0 == "mobile" || $0.hasPrefix("mobile/") }
        _ = try preparedData.setOwner(mobile, uid: 501, gid: 501)
        try JSONEncoder().encode(activation).write(to: systemOutput.appendingPathExtension("activation.json"))
        print("Prepared local activation and finished Setup through shared SystemEdits")
        exit(0)
    } catch { fail(String(describing: error)) }
}
if (args.count == 6 || args.count == 7) && args[1] == "--hfs-gles-bridge" {
    do {
        let source = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3])
        guard !FileManager.default.fileExists(atPath: output.path), let bytes = Int(args[5]), bytes > 0 else {
            fail("Expected a new output path and valid output volume size")
        }
        try FileManager.default.copyItem(at: source, to: output)
        try HFSPlusWriter.grow(output, toBytes: bytes)
        let writer = try HFSPlusWriter(output)
        writer.owner = (0, 0)
        let arch = args.count == 7 ? args[6] : "armv7"
        let fw = FitCheck.Firmware(volume: writer, arch: arch)
        let fit = FitCheck.Log()
        _ = try SystemEdits.installCAOGL(writer, helpers: URL(fileURLWithPath: args[4]), arch: arch,
                                       fw: fw, fit: fit) { print($0) }
        try SystemEdits.configureGraphicsJob(writer, accelerated: true)
        try writer.close()
        let proof = try JSONSerialization.data(withJSONObject: fit.fits.map(\.object), options: [.prettyPrinted, .sortedKeys])
        try proof.write(to: output.appendingPathExtension("fit.json"))
        print("Installed the shared qemu-ios graphics bridge after its firmware compatibility check")
        exit(0)
    } catch { fail(String(describing: error)) }
}
// Apply only the launch environment, through the shared SystemEdits path,
// to a separate clone. The source image and all executables remain intact.
if (args.count == 5 || args.count == 6) && args[1] == "--hfs-launch-env" {
    struct Job: Decodable { let label: String; let values: [String: String] }
    do {
        let source = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3])
        let jobs = try JSONDecoder().decode([String: Job].self, from: Data(contentsOf: URL(fileURLWithPath: args[4])))
        guard !jobs.isEmpty, !FileManager.default.fileExists(atPath: output.path) else {
            fail("Expected a nonempty job configuration and a new output path")
        }
        try FileManager.default.copyItem(at: source, to: output)
        if args.count == 6 {
            guard let bytes = Int(args[5]), bytes > 0 else { fail("Invalid output volume size") }
            try HFSPlusWriter.grow(output, toBytes: bytes)
        }
        let writer = try HFSPlusWriter(output)
        for path in jobs.keys.sorted() {
            let job = jobs[path]!
            try SystemEdits.setLaunchEnvironment(writer, path: path, label: job.label, values: job.values)
        }
        try writer.close()
        let result = try HFSPlusVolume(output)
        for (path, job) in jobs {
            let p = try PropertyListSerialization.propertyList(from: result.contents(result.record(at: path)), format: nil) as! [String: Any]
            let env = p["EnvironmentVariables"] as? [String: String] ?? [:]
            guard job.values.allSatisfy({ env[$0.key] == $0.value }) else { fail("Environment readback failed: \(path)") }
        }
        print("Verified launch environment for \(jobs.count) jobs in a separate image")
        exit(0)
    } catch { fail(String(describing: error)) }
}
// Materialize the IPSW's original /private/var tree on its separate Data
// volume. No preferences, activation state, executables or plists are edited.
if (args.count == 4 || args.count == 6) && args[1] == "--a6-stock-data" {
    do {
        var systemBytes: UInt64 = 3 << 30
        if args.count == 6 {
            guard args[4] == "--system-bytes", let size = UInt64(args[5]) else {
                fail("Expected --system-bytes SIZE")
            }
            systemBytes = size
        }
        let layout = try A6StorageLayout(systemBytes: systemBytes)
        let source = try HFSPlusVolume(URL(fileURLWithPath: args[2]))
        let target = URL(fileURLWithPath: args[3])
        guard !FileManager.default.fileExists(atPath: target.path) else { fail("Output already exists") }
        let seed = try source.paths().filter { $0.path == "private/var" || $0.path.hasPrefix("private/var/") }
            .sorted { $0.path.split(separator: "/").count < $1.path.split(separator: "/").count }
        guard seed.contains(where: { $0.path == "private/var/db" }) else { fail("IPSW has no /private/var/db seed") }
        try HFSPlusWriter.makeHFS(target, size: Int64(layout.dataBytes), name: "Data", journaled: true)
        let writer = try HFSPlusWriter(target)
        for item in seed {
            let path = item.path == "private/var" ? "" : String(item.path.dropFirst("private/var/".count))
            let r = item.record
            writer.owner = (r.uid, r.gid); writer.date = r.dates[1]
            if path.isEmpty { try writer.setAttributes("", uid: r.uid, gid: r.gid, mode: r.mode & 0o7777) }
            else if r.kind == .folder { try writer.makeDirectory(path, mode: r.mode & 0o7777) }
            else if r.isSymlink { try writer.makeSymlink(path, to: String(decoding: source.contents(r), as: UTF8.self)) }
            else { try writer.put(source.contents(r), at: path, mode: r.mode & 0o7777) }
        }
        try writer.close()
        // Match the shared SystemEdits Data-format path: modern services
        // require per-file protection on the restored Data filesystem.
        try HFSPlusVolume(target, writable: true).setContentProtection()
        let result = try HFSPlusVolume(target)
        for item in seed {
            let path = item.path == "private/var" ? "" : String(item.path.dropFirst("private/var/".count))
            let record = try result.record(at: path)
            guard record.uid == item.record.uid, record.gid == item.record.gid,
                  record.mode == item.record.mode else { fail("Stock Data metadata mismatch: \(path)") }
            if item.record.kind == .file {
                guard try source.contents(item.record) == result.contents(record) else { fail("Stock Data content mismatch: \(path)") }
            }
        }
        print("Verified \(seed.count) original IPSW Data records; System volume was opened read-only")
        exit(0)
    } catch { fail(String(describing: error)) }
}
if args.count == 4 && args[1] == "--a6-nand" {
    do {
        let rootfs = URL(fileURLWithPath: args[2])
        let out = URL(fileURLWithPath: args[3])
        let data = out.appendingPathComponent("data-empty.hfs")
        try HFSPlusWriter.makeHFS(data, size: 2048 << 20, name: "Data", journaled: true)
        let mbr = out.appendingPathComponent("mbr.bin")
        try K48NAND.makeMBR(systemMiB: 2048).write(to: mbr)
        let kernel = out.appendingPathComponent("decrypted/kernelcache.mach")
        _ = try await K48NAND.build(mbr: mbr,
            kernelVersion: K48NAND.kernelVersion(kernelcache: kernel),
            epoch: K48NAND.signatureEpoch(kernelcache: kernel), system: rootfs,
            data: .image(data), out: out.appendingPathComponent("nand"),
            log: { print($0); fflush(stdout) })
        exit(0)
    } catch { fail(String(describing: error)) }
}
if args.count >= 4 && args[1] == "--a6-kboot" {
    do {
        let dec = URL(fileURLWithPath: args[2])
        var root = "disk0s1s1", guestSupport = false, extraArgs = "", guestAssetsSystem: URL?
        var identitySeed = "n42ap-11A465-local"
        var option = 4
        if option < args.count, !args[option].hasPrefix("--") { root = args[option]; option += 1 }
        while option < args.count {
            if args[option] == "--guest-support" { guestSupport = true; option += 1 }
            else if args[option] == "--guest-assets-system", option + 1 < args.count {
                guestAssetsSystem = URL(fileURLWithPath: args[option + 1]); option += 2
            }
            else if args[option] == "--boot-args", option + 1 < args.count {
                extraArgs += " " + args[option + 1]; option += 2
            } else if args[option] == "--seed", option + 1 < args.count {
                identitySeed = args[option + 1]; option += 2
            } else { fail("Expected --guest-support, --guest-assets-system IMAGE, or --boot-args STRING") }
        }
        let baseArgs = guestSupport ? A6Preparation.defaultBootArgs : "serial=3 debug=0x8"
        let identity = try UnitIdentity.synthesize(seed: identitySeed, storage: "16g", modelNumber: "MD299").addingIMEI(seed: identitySeed)
        let assets = try guestAssetsSystem.map {
            try A6GuestAssets.prepare(kernel: Data(contentsOf: dec.appendingPathComponent("kernelcache.mach"), options: .alwaysMapped), system: $0)
        }
        try KBoot.write(decrypted: dec, to: URL(fileURLWithPath: args[3]), identity: identity,
                        bootArgs: "\(baseArgs) rd=\(root)" + extraArgs,
                        kernelOverride: assets?.kernel,
                        rootDevice: root)
        try identity.write(to: URL(fileURLWithPath: args[3] + ".identity.json"))
        if let assets {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(assets.assets).write(to: URL(fileURLWithPath: args[3] + ".assets.json"), options: .withoutOverwriting)
        }
        exit(0)
    } catch { fail(String(describing: error)) }
}
if args.count >= 4 && args[1] == "--a6-restore" {
    do {
        var factoryArgs = "", extraArgs = "", identitySeed = "n42ap-11A465-local"
        var dataSeed: URL?, seedBaseSystem: URL?, activationPlan: URL?, guestAssetsSystem: URL?
        var option = 4
        while option < args.count {
            if args[option] == "--factory-format" { factoryArgs = " nand-enable-reformat=1"; option += 1 }
            else if args[option] == "--boot-args", option + 1 < args.count {
                extraArgs += " " + args[option + 1]; option += 2
            } else if args[option] == "--seed", option + 1 < args.count {
                identitySeed = args[option + 1]; option += 2
            } else if args[option] == "--data-seed", option + 1 < args.count {
                dataSeed = URL(fileURLWithPath: args[option + 1]); option += 2
            } else if args[option] == "--seed-base-system", option + 1 < args.count {
                seedBaseSystem = URL(fileURLWithPath: args[option + 1]); option += 2
            } else if args[option] == "--activation-plan", option + 1 < args.count {
                activationPlan = URL(fileURLWithPath: args[option + 1]); option += 2
            } else if args[option] == "--guest-assets-system", option + 1 < args.count {
                guestAssetsSystem = URL(fileURLWithPath: args[option + 1]); option += 2
            } else { fail("Expected --factory-format or --boot-args STRING") }
        }
        let dir = URL(fileURLWithPath: args[2]), helper = URL(fileURLWithPath: args[3])
        let dec = dir.appendingPathComponent("decrypted")
        let files = try FileManager.default.contentsOfDirectory(atPath: dec.path)
            .filter { $0.hasSuffix("-ramdisk.dmg") }.sorted()
        // Update ramdisks can sort before restore ramdisks. Select the
        // original native restore service, never an arbitrary filename.
        let restoreCandidates = try files.compactMap { name -> HFSPlusVolume? in
            let candidate = try HFSPlusVolume(dec.appendingPathComponent(name))
            guard (try? candidate.record(at: "usr/local/bin/restored_external")) != nil else { return nil }
            let hasJob = (try? candidate.record(at: "System/Library/LaunchDaemons/com.apple.restored_external.plist")) != nil
            // Earlier restore images invoke the service from their native
            // rc.boot executable instead of a launchdaemon. Both layouts
            // must identify the erase service, not restored_update.
            let service = Data("/usr/local/bin/restored_external\0".utf8)
            let hasBootInvocation = ["private/etc/rc.boot", "etc/rc.boot"].contains { path in
                guard let record = try? candidate.record(at: path),
                      let contents = try? candidate.contents(record) else { return false }
                return contents.range(of: service) != nil
            }
            guard hasJob || hasBootInvocation else { return nil }
            return candidate
        }
        guard restoreCandidates.count == 1, let source = restoreCandidates.first else {
            fail("Expected exactly one native restored_external RAM disk, found \(restoreCandidates.count)")
        }
        let rd = dir.appendingPathComponent("restore-ramdisk.hfs")
        let paths = try source.paths().sorted { $0.path.split(separator: "/").count < $1.path.split(separator: "/").count }
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
        for item in paths {
            let p = item.path, r = item.record
            if p.isEmpty { continue }
            writer.owner = (r.uid, r.gid)
            if r.kind == .folder { try writer.makeDirectory(p, mode: r.mode & 0o7777) }
            else if r.isSymlink { try writer.makeSymlink(p, to: String(decoding: source.contents(r), as: UTF8.self)) }
            else { try writer.put(source.contents(r), at: p, mode: r.mode & 0o7777) }
        }
        writer.owner = (0, 0)
        try writer.put(contentsOf: helper, at: "usr/local/bin/restored_external", mode: 0o755)
        if let dataSeed {
            let source = try HFSPlusVolume(dataSeed)
            let seedBase = try seedBaseSystem.map { try HFSPlusVolume($0) }
            let target = "usr/local/share/qemu/data-seed"
            guard (try? source.record(at: "keybags/systembag.kb")) == nil else {
                fail("Prepared Data seed must not contain a device keybag")
            }
            try writer.makeDirectory(target, mode: 0o755)
            for item in try source.paths().sorted(by: { $0.path.split(separator: "/").count < $1.path.split(separator: "/").count }) {
                if let first = item.path.split(separator: "/").first,
                   [".journal", ".journal_info_block"].contains(String(first)) || VolumeMount.junk.contains(String(first)) || first.hasPrefix(".HFS+") { continue }
                let r = item.record, path = item.path.isEmpty ? target : target + "/" + item.path
                // Stock /private/var is copied natively from System after the
                // keybag exists. Carry only FirmwareKit's additions/changes in
                // the temporary ramdisk, rather than duplicate large assets.
                if r.kind != .folder, let seedBase,
                   let old = try? seedBase.record(at: "private/var/" + item.path),
                   old.kind == r.kind, old.uid == r.uid, old.gid == r.gid, old.mode == r.mode,
                   try seedBase.contents(old) == source.contents(r) { continue }
                writer.owner = (r.uid, r.gid)
                if item.path.isEmpty { try writer.setAttributes(path, uid: r.uid, gid: r.gid, mode: r.mode & 0o7777) }
                else if r.kind == .folder { try writer.makeDirectory(path, mode: r.mode & 0o7777) }
                else if r.isSymlink { try writer.makeSymlink(path, to: String(decoding: source.contents(r), as: UTF8.self)) }
                else { try writer.put(source.contents(r), at: path, mode: r.mode & 0o7777) }
            }
        }
        if let activationPlan {
            let worker = helper.deletingLastPathComponent().appendingPathComponent("it_mobilegestalt")
            let workerData = try Data(contentsOf: worker)
            try A6RestoreCache.validate(plan: Data(contentsOf: activationPlan),
                originalLibrary: source.contents(source.record(at: "usr/lib/libMobileGestalt.dylib")),
                helper: workerData)
            writer.owner = (0, 0)
            try writer.put(workerData, at: "usr/local/bin/it_mobilegestalt", mode: 0o755)
            try writer.makeDirectory("usr/local/share/qemu", mode: 0o755)
            try writer.put(contentsOf: activationPlan, at: "usr/local/share/qemu/activation-plan.plist", mode: 0o644)
        }
        try writer.close()
        let identity = try UnitIdentity.synthesize(seed: identitySeed, storage: "16g", modelNumber: "MD299").addingIMEI(seed: identitySeed)
        let originalKernel = try Data(contentsOf: dec.appendingPathComponent("kernelcache.mach"))
        let assets = try guestAssetsSystem.map { try A6GuestAssets.prepare(kernel: originalKernel, system: $0, restoreRAMDisk: rd) }
        var restoreKernel = assets?.kernel
        if !factoryArgs.isEmpty {
            let version = try PropertyListSerialization.propertyList(
                from: source.contents(source.record(at: "System/Library/CoreServices/SystemVersion.plist")), format: nil) as? [String: Any]
            guard let build = version?["ProductBuildVersion"] as? String else { fail("Native restore build identity missing") }
            restoreKernel = try A6RestoreKernel.prepare(restoreKernel ?? originalKernel,
                                                       build: build, log: { print($0) })
        }
        try KBoot.write(decrypted: dec, to: dir.appendingPathComponent("kboot-restore.bin"), identity: identity,
            bootArgs: A6Preparation.defaultBootArgs + " -v" + factoryArgs + extraArgs,
            ramdisk: rd, kernelOverride: restoreKernel)
        if let assets {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(assets.assets).write(to: dir.appendingPathComponent("restore-assets.json"))
        }
        print("N42 temporary restoration RAM disk prepared")
        exit(0)
    } catch { fail(String(describing: error)) }
}
if (args.count == 5 || (args.count == 6 && args[5] == "--rootfs")) && args[1] == "--decrypt" {
    do {
        let entry = try FirmwareEntry.load(from: URL(fileURLWithPath: args[3]))
        _ = try FirmwareDecryptor.decrypt(ipsw: URL(fileURLWithPath: args[2]), entry: entry,
                                         into: URL(fileURLWithPath: args[4]), rootfs: args.count == 6)
        exit(0)
    } catch { fail(String(describing: error)) }
}
// Native A6 restore-delta preparation; no host Python/runtime utility required.
if args.count == 5 && args[1] == "--a6-image-delta" {
    do {
        guard !FileManager.default.fileExists(atPath: args[4] + ".json") else {
            fail("Expected a new restore manifest")
        }
        let result = try A6RestoreStream.writeDelta(
            base: URL(fileURLWithPath: args[2]), image: URL(fileURLWithPath: args[3]),
            output: URL(fileURLWithPath: args[4]))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        try data.write(to: URL(fileURLWithPath: args[4] + ".json"), options: .withoutOverwriting)
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    } catch { fail(String(describing: error)) }
}
// Prepare only the same guest installation helpers used by the older profiles.
if args.count == 5 && args[1] == "--hfs-sideload-tools" {
    do {
        let source = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3])
        guard !FileManager.default.fileExists(atPath: output.path) else { fail("Expected a new output image") }
        try FileManager.default.copyItem(at: source, to: output)
        try SideloadTools.install(system: output, helpers: URL(fileURLWithPath: args[4]))
        print("Prepared existing guest installation helpers")
        exit(0)
    } catch { fail(String(describing: error)) }
}
if args.count == 4 && args[1] == "--hfs-stat" {
    do {
        let volume = try HFSPlusVolume(URL(fileURLWithPath: args[2]))
        let record = try volume.record(at: args[3])
        var result: [String: Any] = [
            "path": args[3], "cnid": record.cnid, "parent": record.parent,
            "kind": record.kind == .folder ? "directory" : "file",
            "mode": String(record.mode, radix: 8), "uid": record.uid, "gid": record.gid,
            "symlink": record.isSymlink, "size": record.data?.logicalSize ?? 0,
        ]
        if record.isSymlink { result["target"] = String(decoding: try volume.contents(record), as: UTF8.self) }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]))
        exit(0)
    } catch { fail(String(describing: error)) }
}
if (args.count == 3 || args.count == 4) && args[1] == "--hfs-list" {
    do {
        let volume = try HFSPlusVolume(URL(fileURLWithPath: args[2]))
        let prefix = args.count == 4 ? args[3] : ""
        let paths = try volume.paths().map { $0.path }.filter { $0.hasPrefix(prefix) }.sorted()
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: paths, options: [.prettyPrinted]))
        exit(0)
    } catch { fail(String(describing: error)) }
}
if args.count == 4 && args[1] == "--hfs-cat" {
    do {
        let volume = try HFSPlusVolume(URL(fileURLWithPath: args[2]))
        FileHandle.standardOutput.write(try volume.contents(volume.record(at: args[3])))
        exit(0)
    } catch { fail(String(describing: error)) }
}
if args.count == 4 && args[1] == "--inspect-rootfs" {
    do {
        let hfs = URL(fileURLWithPath: args[3])
        try await UDIF.extractRootfs(dmg: URL(fileURLWithPath: args[2]), to: hfs)
        let v = try HFSPlusVolume(hfs)
        for path in ["usr/lib/dyld", "sbin/launchd", "System/Library/CoreServices/SpringBoard.app/SpringBoard"] {
            let b = try v.contents(v.record(at: path))
            print(path, b.prefix(16).map { String(format: "%02x", $0) }.joined())
        }
        for (p, _) in try v.paths() where p.contains("dyld_shared_cache") { print(p) }
        exit(0)
    } catch { fail(String(describing: error)) }
}
if args.count == 5 && args[1] == "--vfdecrypt" {
    do {
        let hex = Array(args[3]); guard hex.count == 72 else { fail("rootfs key must be 36 bytes") }
        let key = Data(stride(from: 0, to: hex.count, by: 2).map { UInt8(String(hex[$0...$0+1]), radix: 16)! })
        try VFDecrypt.decrypt(input: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[4]), key: key)
        exit(0)
    } catch { fail(String(describing: error)) }
}
if args.count == 4 && args[1] == "--keybag" {
    do {
        let dir = URL(fileURLWithPath: args[2]), helper = URL(fileURLWithPath: args[3])
        let dec = dir.appendingPathComponent("decrypted")
        let ramdisks = try FileManager.default.contentsOfDirectory(atPath: dec.path).filter { $0.hasSuffix("-ramdisk.dmg") }.sorted()
        guard let ramdisk = ramdisks.first else { fail("no decrypted restore RAM disk") }
        let source = try HFSPlusVolume(dec.appendingPathComponent(ramdisk))
        let rd = dir.appendingPathComponent("keybag-ramdisk.hfs")
        try HFSPlusWriter.makeHFS(rd, size: 32 << 20, name: "Restore", journaled: false)
        let w = try HFSPlusWriter(rd)
        for item in try source.paths().sorted(by: { $0.path.split(separator: "/").count < $1.path.split(separator: "/").count }) {
            let p = item.path, r = item.record
            if p.isEmpty { continue }
            w.owner = (r.uid, r.gid)
            if r.kind == .folder { try w.makeDirectory(p, mode: r.mode & 0o7777) }
            else if r.isSymlink { try w.makeSymlink(p, to: String(decoding: source.contents(r), as: UTF8.self)) }
            else { try w.put(source.contents(r), at: p, mode: r.mode & 0o7777) }
        }
        w.owner = (0, 0)
        try w.put(contentsOf: helper, at: "usr/local/bin/restored_external", mode: 0o755)
        try w.close()
        let record = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("provenance.json"))) as! [String: Any]
        let seed = record["identity_seed"] as? String ?? "ios6-gm-iphone4"
        let identity = try UnitIdentity.synthesize(seed: seed, storage: "16g", modelNumber: "MC603").addingIMEI(seed: seed)
        try KBoot.write(decrypted: dec, to: dir.appendingPathComponent("kboot-restore.bin"), identity: identity,
            bootArgs: "serial=3 debug=0x8 -v amfi_allow_any_signature=1 amfi_get_out_of_my_way=1 cs_enforcement_disable=1 enable-hsic=1", ramdisk: rd)
        print("Restore initialization bundle ready")
        exit(0)
    } catch { fail(String(describing: error)) }
}
guard args.count == 5 else { fail("usage: firmwarekit-prepare IPSW ENTRY HELPERS NEW-OUT") }
let url = { (s: String) in URL(fileURLWithPath: s).standardizedFileURL }
let ipsw = url(args[1]), entryPath = url(args[2]), helpers = url(args[3]), out = url(args[4])
do {
    let fm = FileManager.default
    guard !fm.fileExists(atPath: out.path) else { fail("OUT must be new") }
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    let entry = try FirmwareEntry.load(from: entryPath)
    let dec = out.appendingPathComponent("decrypted")
    print("Decrypting supplied \(entry.id)"); fflush(stdout)
    _ = try FirmwareDecryptor.decrypt(ipsw: ipsw, entry: entry, into: dec, rootfs: true)
    let seed = "\(entry.id)-local"
    let identity = try UnitIdentity.synthesize(seed: seed, storage: "16g", modelNumber: "MC603").addingIMEI(seed: seed)
    try identity.write(to: out.appendingPathComponent("identity.json"))
    let bootArgs = "rd=disk0s1 serial=3 debug=0x8 -v amfi_allow_any_signature=1 amfi_get_out_of_my_way=1 cs_enforcement_disable=1 enable-hsic=1"
    try KBoot.write(decrypted: dec, to: out.appendingPathComponent("kboot.bin"), identity: identity, bootArgs: bootArgs)
    try Data(repeating: 0xff, count: 1 << 20).write(to: out.appendingPathComponent("nor.bin"))
    let systemMiB = (Int(entry.version.split(separator: ".")[0]) ?? 6) >= 7 ? 2048 : 1536
    let partitionMap = try K48NAND.makeMBR(systemMiB: systemMiB)
    let partitions = try K48NAND.partitions(mbr: [UInt8](partitionMap))
    let dataBytes = Int64(partitions[1].count) * 4096
    var options = SystemEdits.Options()
    options.caOGL = true; options.appsync = false; options.webProxy = false
    options.guestTools = false; options.seal = false; options.skipSetup = true
    let result = try await SystemEdits.buildK48(rootfs: dec.appendingPathComponent("rootfs.dmg"), work: out,
        systemBytes: systemMiB << 20, dataBytes: dataBytes, options: options,
        helpers: helpers, kernel: Data(contentsOf: dec.appendingPathComponent("kernelcache.mach")),
        log: { print($0); fflush(stdout) })
    if fm.fileExists(atPath: helpers.appendingPathComponent("it_agent").path) {
        try SideloadTools.install(system: result.system, helpers: helpers)
    }
    // This local preparation disables guest-package seeding, whose normal
    // recipe also activates the device. Retain shared activation explicitly.
    let setupSystem = try HFSPlusWriter(result.system), setupData = try HFSPlusWriter(result.data)
    setupSystem.owner = (0, 0); setupData.owner = (0, 0)
    _ = try SystemEdits.prepareLocalSetup(system: setupSystem, data: setupData,
        major: Int(entry.version.split(separator: ".")[0]) ?? 6) { print($0) }
    try setupSystem.close(); try setupData.close()
    let mbr = out.appendingPathComponent("mbr.bin")
    try partitionMap.write(to: mbr)
    let kernel = dec.appendingPathComponent("kernelcache.mach")
    _ = try await K48NAND.build(mbr: mbr, kernelVersion: K48NAND.kernelVersion(kernelcache: kernel),
        epoch: K48NAND.signatureEpoch(kernelcache: kernel), system: result.system, data: .image(result.data),
        out: out.appendingPathComponent("nand"), log: { print($0); fflush(stdout) })
    let record: [String: Any] = ["entry": entry.id, "version": entry.version, "build": entry.build,
        "machine": "iPhone-4", "boot_args": bootArgs, "system_mib": systemMiB, "data_mib": dataBytes >> 20,
        "source": ipsw.path, "graphics": result.engine ?? "none", "skip_setup": true, "identity_seed": seed]
    try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("provenance.json"))
    print("Prepared \(out.path)")
} catch { fail(String(describing: error)) }
