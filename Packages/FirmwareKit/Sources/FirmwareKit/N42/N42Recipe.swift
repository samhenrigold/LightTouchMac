// N42Board: the iPhone 5's (n42ap, recipe "n42", -M iPhone-5) side of Recipe.create. Its store isn't written on
// the Mac: the volumes step is A6Preparation's bake, and the store step formats new PPN media and restores it in
// the guest, as a restore does: a factory NAND (A6NAND), the volumes as an allocated-block restore stream
// (A6RestoreStream), and one LightTouchDevice one-shot of the IPSW's own restore ramdisk with qemu-ios's
// it_initialize as its restored_external (A6RestoreBundle), which writes the stream through the guest's disk
// driver, formats Data, makes the system keybag, seeds Data and the MobileGestalt cache, and halts. Then kboot.bin,
// the normal boot (its kernel trusts the staged guest helpers, A6GuestAssets). No NOR. Then its first normal boot, to
// its Home screen and a clean halt (seal), so a new device's first Start skips iOS's minutes-long data migration.

import Crypto
import Foundation
import HostRuntime

final class N42Board: Board {
    let arch = "armv7"
    let seedPrefix = "iphone5"
    let bootStep = "Writing the identity"
    let volumesStep = "Building the system and data volumes"
    let storeStep = restoreStep
    let keybagStep = "Creating the data-protection keybag"
    let dataProtection = false
    /// The first normal boot, run here: iOS's data migration (a progress bar under the logo) takes minutes in the
    /// emulator, past the app's boot budget, so the device's first Start would read as a failed boot.
    let needsSeal = true
    let shipped = ["kboot.bin"]
    static let restoreStep = "Restoring the flash"
    /// What check() requires in --guest-tools besides the volumes' helpers.
    static let initializer = "it_initialize", mobileGestalt = "it_mobilegestalt"
    static let restoreDone = "A6RESTORE DONE"
    /// What the normal boot passes: guest support, root on the LwVM System partition.
    static let bootArgs = A6Preparation.defaultBootArgs + " rd=disk0s1"
    /// What every boot of the device carries (the lock's machine): the PPN store, the cameras, no verbose handoff,
    /// and the modem's IMEI (the identity's; BootRecipe.iPhone5 gives it to the modem).
    var machineOptions: [String: String] {
        var options = ["ppn": "on", "camera": "on", "quiet-boot": "on"]
        options["imei"] = ident?["imei"]
        return options
    }

    let recipe: FirmwareEntry.Recipe
    var helper: URL?, hardware: DeviceInfo?, ident: UnitIdentity?
    var vols: SystemEdits.Result?, records: URL?
    var restoreRamdisk: String?
    /// The restore boot's limit: 14G61's took 157 s on an M4 Max, unloaded.
    var restoreTimeout: Double = 1200
    /// The first boot's limit: 14G61's migration lit SpringBoard after 380-430 s at a host load of 5, 800 s at 30.
    var firstBootTimeout: Double = 2400

    init(_ o: Preparer.Options) throws {
        guard let recipe = o.entry.recipe else { throw FirmwareError(.unsupported, "\(o.entry.id): no recipe") }
        self.recipe = recipe
    }

    func check(_ c: Recipe.Context) throws {
        guard recipe.storage == "16g", recipe.boot ?? "kboot" == "kboot" else {
            throw FirmwareError(.unsupported, "\(c.e.id): storage \(recipe.storage), boot \(recipe.boot ?? "none")")
        }
        guard let helper = c.o.helper, FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw FirmwareError(
                .internal,
                "the restore boot needs --helper (LightTouchDevice); got \(c.o.helper?.path ?? "none")"
            )
        }
        self.helper = helper
        Machines.helper = helper
        guard let hardware = HostRuntime.Board.n42.hardware else {
            throw FirmwareError(.internal, "\(helper.lastPathComponent)'s emulator library has no machine for n42ap")
        }
        self.hardware = hardware
        let missing = [Self.initializer, Self.mobileGestalt, "launchd-cache-template", "it_agent", "libappsync.dylib"]
            .filter { !FileManager.default.fileExists(atPath: c.o.guestTools.appendingPathComponent($0).path) }
        guard missing.isEmpty else {
            throw FirmwareError(
                .internal, "--guest-tools \(c.o.guestTools.path) lacks \(missing.joined(separator: ", "))")
        }
    }

    func identity(seed: String) throws -> UnitIdentity {
        let ident = try UnitIdentity.synthesize(
            seed: seed, storage: recipe.storage, modelNumber: KBoot.Board.n42.modelNumber
        ).addingIMEI(seed: seed)
        self.ident = ident
        return ident
    }

    /// kboot.bin waits for the volumes (its kernel trusts the staged helpers); here only its boot-args' fit.
    func bootFiles(_ c: Recipe.Context) throws {
        let kernel = try Data(contentsOf: c.decFile("kernelcache.mach"), options: .alwaysMapped)
        try FitCheck.checkBootArgs(c.fit, kernel: kernel, args: Self.bootArgs)
    }

    /// A6Preparation's System and Data, left in work/ as system.img and data.img (--stop-after volumes keeps them);
    /// its records (the activation plan) in work/a6.
    nonisolated(nonsending) func volumes(_ c: Recipe.Context) async throws {
        let records = c.work.appendingPathComponent("a6")
        self.records = records
        var vols = try await A6Preparation.volumes(
            ipsw: c.source.filled("the verified IPSW"),
            decrypted: c.decrypted(),
            helpers: c.o.guestTools,
            out: records,
            language: c.o.language,
            keyboards: c.o.keyboards,
            fit: c.fit,
            // the same seed and build, the same files: Setup finished on the build's release day
            seed: c.seed,
            setupFinished: c.e.released.flatMap { ISO8601DateFormatter().date(from: $0 + "T12:00:00Z") },
            log: c.log
        )
        let fm = FileManager.default
        for (from, name) in [(vols.system, "system.img"), (vols.data, "data.img")] {
            let to = c.work.appendingPathComponent(name)
            try fm.moveItem(at: from, to: to)
            if name == "system.img" { vols.system = to } else { vols.data = to }
        }
        self.vols = vols
        for n in vols.notes { c.emit(.warning(n)) }
        c.activation = vols.activation
        c.guestPackage = vols.guestPackage
        c.engine = vols.engine
    }

    /// The restore boot (above), then kboot.bin.
    nonisolated(nonsending) func store(_ c: Recipe.Context) async throws {
        let fm = FileManager.default
        let vols = try self.vols.filled("the volumes")
        let ident = try self.ident.filled("the identity")
        let work = c.work
        let stream = work.appendingPathComponent("initial.a6di")
        try A6RestoreStream.writeInitial(system: vols.system, data: vols.data, output: stream)
        try A6NAND.create(at: c.nand)
        var inputs = A6RestoreBundle.Inputs(
            decrypted: try c.decrypted(),
            initializer: c.o.guestTools.appendingPathComponent(Self.initializer)
        )
        inputs.mobileGestalt = c.o.guestTools.appendingPathComponent(Self.mobileGestalt)
        inputs.factoryFormat = true
        inputs.dataSeed = vols.data
        inputs.seedBaseSystem = vols.system
        let plan = try records.filled("the volume records").appendingPathComponent("activation-plan.plist")
        inputs.activationPlan = fm.fileExists(atPath: plan.path) ? plan : nil
        inputs.guestAssetsSystem = vols.system
        try A6RestoreBundle.write(inputs, work: work, identity: ident, log: c.log)
        restoreRamdisk = "restore-ramdisk.hfs"
        // the normal boot's kernel, while the System image is here to read the staged helpers from
        let assets = try A6GuestAssets.prepare(
            kernel: Data(contentsOf: c.decFile("kernelcache.mach"), options: .alwaysMapped),
            system: vols.system
        )
        try KBoot.write(
            decrypted: c.decrypted(), to: c.file("kboot.bin"), identity: ident, bootArgs: Self.bootArgs,
            kernelOverride: assets.kernel, rootDevice: "disk0s1"
        )
        try? fm.removeItem(at: vols.system)
        try? fm.removeItem(at: vols.data)

        let serial = work.appendingPathComponent("restore.log")
        var options = machineOptions
        options["restore-image"] = stream.path
        var phone = BootRecipe.IPad(
            boot: .kernel(image: work.appendingPathComponent("kboot-restore.bin").path, writableNOR: nil),
            nand: c.nand.path,
            overlay: nil,
            dieID: nil,
            usbAddress: nil,
            wifi: false,
            machineOptions: options,
            oneShot: true
        )
        phone.imei = options.removeValue(forKey: "imei")
        phone.machineOptions = options
        let config = BootRecipe.iPhone5(
            phone,
            hardware: try hardware.filled("the board's hardware"),
            serial: "file:\(serial.path)",
            audio: ["-audio", "driver=none"],
            netdev: nil,
            restore: []
        )
        let (r, text) = try Preparer.oneshot(
            helper.filled("the helper"),
            argv: config.argv,
            machine: config.machine,
            serial: serial,
            stop: nil,
            timeout: restoreTimeout,
            work: work,
            grants: [.init(c.o.out, .readWrite)],
            log: c.log
        )
        for line in text.split(separator: "\n")
        where line.contains("A6RESTORE") || line.contains("A6NATIVE") || line.contains("it_keybag:") {
            c.log(String(line))
        }
        guard r.exited, text.contains(Self.restoreDone), text.contains(Preparer.keybagDone) else {
            let why =
                text.split(separator: "\n").lazy.compactMap { line -> String? in
                    for marker in ["A6RESTORE FAIL", "it_keybag: FAILED", "panic("] {
                        if let at = line.range(of: marker) { return String(line[at.lowerBound...].prefix(160)) }
                    }
                    return nil
                }.first
                ?? (r.exited ? "halted without the keybag" : "no halt after \(Int(r.seconds)) s")
            throw FirmwareError(.oneshotFailed, "restore boot: \(why)")
        }
        for n in ["initial.a6di", "restore-ramdisk.hfs", "kboot-restore.bin"] {
            try? fm.removeItem(at: work.appendingPathComponent(n))
        }
    }

    /// What the first boot shows once its migration is done and the Home screen is up (SpringBoard's start).
    static let firstBootDone = "Process SpringBoard ("

    /// The first normal boot (needsSeal; the other boards' seal boot): kboot.bin on the restored store until
    /// SpringBoard is up, then the guest's own shutdown (the machine's powerdown, through the agent's halt), so the
    /// store keeps the migration done and a clean FTL. Fails unless the guest halted by itself after SpringBoard.
    func seal(_ c: Recipe.Context) throws {
        let serial = c.work.appendingPathComponent("seal.log")
        var options = machineOptions
        var phone = BootRecipe.IPad(
            boot: .kernel(image: c.file("kboot.bin").path, writableNOR: nil),
            nand: c.nand.path,
            overlay: nil,
            dieID: nil,
            usbAddress: nil,
            wifi: false,
            oneShot: true
        )
        phone.imei = options.removeValue(forKey: "imei")
        phone.machineOptions = options
        let config = BootRecipe.iPhone5(
            phone,
            hardware: try hardware.filled("the board's hardware"),
            serial: "file:\(serial.path)",
            audio: ["-audio", "driver=none"],
            netdev: nil,
            restore: []
        )
        let (r, text) = try Preparer.oneshot(
            helper.filled("the helper"),
            argv: config.argv,
            machine: config.machine,
            serial: serial,
            stop: nil,
            powerdown: (Self.firstBootDone, 30),
            timeout: firstBootTimeout,
            work: c.work,
            grants: [.init(c.o.out, .readWrite)],
            log: c.log
        )
        guard r.exited, text.contains(Self.firstBootDone) else {
            throw FirmwareError(
                .oneshotFailed,
                "first boot: \(text.contains(Self.firstBootDone) ? "no clean halt" : "no Home screen") after \(Int(r.seconds)) s"
            )
        }
    }

    func lock(_ c: Recipe.Context) throws -> [String: Any] {
        let helper = try self.helper.filled("the helper")
        return [
            "boot_strategy": "kboot",
            "tool": ["helper": helper.path, "helper_sha256": try Preparer.digest(helper, SHA256())],
            "inputs": [
                "kernelcache": "kernelcache.mach", "devicetree": "DeviceTree.bin",
                "restore_ramdisk": restoreRamdisk.map { $0 as Any } ?? NSNull()
            ],
            "outputs": ["nand": ["files": c.nandHashes], "kboot": try Recipe.fileRecord(c, "kboot.bin")],
            "skip_setup": true,
            // the agent is in the image (SideloadTools), as the iPod touch 2G's (N72Board): no guest package carries it
            "derived": ["guest_tools": "installed"],
            "machine": machineOptions
        ]
    }
}
