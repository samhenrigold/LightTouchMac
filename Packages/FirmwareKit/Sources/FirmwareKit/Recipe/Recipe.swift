// Recipe: the one `firmwarekit create` (docs/sweep/PLAN.md C4). Every board runs the same steps in the same
// order; a board contributes only what differs (Board): its boot files, how its volumes are laid out, its NAND
// writer, its keybag one-shot, whether it needs a seal, and its keys in the lock.
//
//   create = verify -> decrypt -> identity + board.bootFiles -> board.volumes (the shared bake in SystemEdits)
//            -> board.store -> [board.keybag if data protection] -> [board.seal if needsSeal] -> lock
//
// Shared here: the IPSW sha1 and Restore.plist checks, the decrypt cache (CACHE/<sha1>/ with a .done marker),
// the seed name ("<board.seedPrefix>-<build>-default"), the step/progress events, the read-only outputs, the
// store listing hashes (built_listing_sha256 before any boot, listing_sha256 after) and the lock, whose
// board-specific keys are merged in from `board.lock`. Helper file names and cache paths derive from
// `board.arch` (SystemEdits.Helpers.name, SystemEdits.dyldCache).

import CryptoKit
import Foundation

/// What one board adds to Recipe.create. Methods run in the order above, each inside its step.
protocol Board: AnyObject {
    /// "armv7" or "armv6": guest helper names and the dyld shared cache path.
    var arch: String { get }
    /// The default seed's prefix ("ipad1", "ipod2g"); the lock's identity.seed keeps it.
    var seedPrefix: String { get }
    var bootStep: String { get }
    var volumesStep: String { get }
    var keybagStep: String { get }
    var dataProtection: Bool { get }
    var needsSeal: Bool { get }
    /// Outputs made read-only and hashed for the lock, besides nand/.
    var shipped: [String] { get }

    /// Before `begin`: what this recipe needs (helper, storage, guest helpers).
    func check(_ c: Recipe.Context) throws
    /// After the IPSW is verified: board facts read from it (the iPod's NAND epoch).
    func inspect(_ c: Recipe.Context) throws
    func identity(seed: String) throws -> UnitIdentity
    func bootFiles(_ c: Recipe.Context) throws
    func volumes(_ c: Recipe.Context) throws
    /// Writes nand/ from the volumes (the volumes are deleted after).
    func store(_ c: Recipe.Context) throws
    func keybag(_ c: Recipe.Context) throws
    func seal(_ c: Recipe.Context) throws
    /// The board's lock keys, merged (dictionaries recursively) onto the shared ones.
    func lock(_ c: Recipe.Context) throws -> [String: Any]
}

extension Board {
    func inspect(_ c: Recipe.Context) throws {}
    func keybag(_ c: Recipe.Context) throws {}
    func seal(_ c: Recipe.Context) throws {}
}

public enum Recipe {
    /// What the steps share; boards read and fill it.
    final class Context {
        let o: Preparer.Options, e: FirmwareEntry, recipe: FirmwareEntry.Recipe
        let emit: (PrepareEvent) -> Void
        let work: URL, nand: URL
        var ipsw: IPSWArchive { IPSWArchive(o.ipsw) }
        var sha1 = "", restore: RestoreInfo!, dec: URL!, seed = "", ident: UnitIdentity!
        /// Filled by `volumes`.
        var activation: Activation.Result?, guestPackage: GuestPackage.Record?, engine: String?
        /// Filled by the store and lock steps.
        var built = "", nandHashes: [String: String] = [:], listing = ""
        var progress: StepProgress!
        /// Every fit check the steps ran (the lock's "fit"); an optional piece that does not fit is a warning event.
        lazy var fit = FitCheck.Log { [unowned self] in self.warn($0) }

        init(_ o: Preparer.Options, recipe: FirmwareEntry.Recipe, emit: @escaping (PrepareEvent) -> Void) {
            self.o = o; e = o.entry; self.recipe = recipe; self.emit = emit
            work = o.out.appendingPathComponent("work"); nand = o.out.appendingPathComponent("nand")
        }
        func file(_ n: String) -> URL { o.out.appendingPathComponent(n) }
        func decFile(_ n: String) -> URL { dec.appendingPathComponent(n) }
        /// stderr; a "warning: " line is also a warning event.
        func log(_ s: String) {
            if s.hasPrefix("warning: ") { emit(.warning(String(s.dropFirst(9)))) }
            FileHandle.standardError.write(Data((s + "\n").utf8))
        }
        func warn(_ s: String) { log("warning: " + s) }
    }

    static func create(_ o: Preparer.Options, board: Board, emit: @escaping @Sendable (PrepareEvent) -> Void) throws {
        let fm = FileManager.default, e = o.entry
        guard let recipe = e.recipe else { throw FirmwareError(.unsupported, "\(e.id): no recipe") }
        let c = Context(o, recipe: recipe, emit: emit)
        guard let sha1 = e.source.sha1 else { throw FirmwareError(.unsupported, "\(e.id) pins no IPSW sha1") }
        guard (try? fm.contentsOfDirectory(atPath: o.out.path))?.isEmpty == true else {
            throw FirmwareError(.internal, "\(o.out.path) is not an empty directory")
        }
        try board.check(c)
        if e.estimates.peakBytes > 0, let free = try? o.out.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < e.estimates.peakBytes - (e.source.bytes ?? 0) {
            throw FirmwareError(.diskFull, "needs \(e.estimates.peakBytes - (e.source.bytes ?? 0)) bytes, \(free) available")
        }
        let steps = ["Verifying the IPSW", "Decrypting the firmware", board.bootStep, board.volumesStep, "Writing the NAND"]
            + (board.dataProtection ? [board.keybagStep] : []) + (board.needsSeal ? ["Sealing the NAND"] : []) + ["Writing the lock"]
        emit(.begin(steps: steps.count, seconds: steps.map { StepPlan.plan($0).seconds }))
        let progress = StepProgress(work: c.work, emit: emit)
        c.progress = progress
        defer { progress.stop() }
        var index = 0
        func step() { index += 1; progress.next(index: index, name: steps[index - 1]); c.log("[\(index)/\(steps.count)] \(steps[index - 1])") }

        step()   // verify
        let ipswBytes = ByteCount(total: (try? fm.attributesOfItem(atPath: o.ipsw.path)[.size] as? Int) ?? 0)
        progress.measure = { ipswBytes.fraction }
        c.sha1 = try Preparer.digest(o.ipsw, Insecure.SHA1(), count: ipswBytes.add)
        guard c.sha1 == sha1.lowercased() else { throw FirmwareError(.shaMismatch, "\(o.ipsw.lastPathComponent): sha1 \(c.sha1), \(e.id) pins \(sha1)") }
        c.restore = try RestoreInfo(c.ipsw)
        try c.restore.verify(against: e)
        try board.inspect(c)

        step()   // decrypt, once per IPSW
        try fm.createDirectory(at: c.work, withIntermediateDirectories: true)
        let cacheRoot = o.cache ?? c.work.appendingPathComponent("cache")
        c.dec = cacheRoot.appendingPathComponent(sha1)
        if !fm.fileExists(atPath: c.dec.appendingPathComponent(".done").path) {
            let tmp = cacheRoot.appendingPathComponent(sha1 + ".tmp")
            try? fm.removeItem(at: tmp)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            _ = try FirmwareDecryptor.decrypt(ipsw: o.ipsw, entry: e, into: tmp)
            try JSONSerialization.data(withJSONObject: ["ipsw": o.ipsw.path, "entry": e.id, "tool": FirmwareKit.version])
                .write(to: tmp.appendingPathComponent(".done"))
            try? fm.removeItem(at: c.dec)
            try fm.moveItem(at: tmp, to: c.dec)
        } else {
            c.log("decrypted components cached in \(c.dec.path)")
        }

        step()   // identity.json + the board's boot files
        c.seed = o.seed ?? "\(board.seedPrefix)-\(e.build)-default"
        c.ident = try board.identity(seed: c.seed)
        try c.ident.write(to: c.file("identity.json"))
        try board.bootFiles(c)

        step()   // volumes (+ the shared bake, activation, guest package)
        try board.volumes(c)

        step()   // the store, and its listing before any boot writes into it (the lock's built_listing_sha256)
        try board.store(c)
        c.built = try Preparer.nandListing(c.nand, files: try nandFiles(c.nand)).sha256
        c.log("store as built: listing sha256 \(c.built)")

        if board.dataProtection {
            step()   // 4.x data protection: effaceable + system keybag from the IPSW's own ramdisk
            try board.keybag(c)
        }
        if board.needsSeal {
            step()   // one clean halt, then a check boot on a throwaway overlay
            try board.seal(c)
        }

        step()   // read-only outputs, lock
        for n in ["nand"] + board.shipped { try Preparer.readOnly(c.file(n)) }
        let files = try nandFiles(c.nand)
        let nandBytes = ByteCount(total: files.reduce(0) { $0 + ((try? fm.attributesOfItem(atPath: c.nand.appendingPathComponent($1).path)[.size] as? Int) ?? 0) })
        progress.measure = { nandBytes.fraction }
        (c.nandHashes, c.listing) = try Preparer.nandListing(c.nand, files: files, count: nandBytes.add)
        let tools = try fm.contentsOfDirectory(atPath: o.guestTools.path).sorted()
        func opt(_ v: Any?) -> Any { v ?? NSNull() }
        let shared: [String: Any] = [
            "format": 1, "created": ISO8601DateFormatter().string(from: Date()),
            "entry": ["id": e.id, "sha256": Preparer.sha256(try entryJSON.encode(e)), "content": try JSONSerialization.jsonObject(with: entryJSON.encode(e))],
            "build": e.build, "product_version": c.restore.productVersion, "product_type": e.productType, "board": e.board,
            "storage": recipe.storage,
            "tool": ["name": "firmwarekit", "version": FirmwareKit.version, "helper": opt(o.helper?.path),
                     "built": ["guest tools": Dictionary(uniqueKeysWithValues: try tools.map { ($0, try Preparer.digest(o.guestTools.appendingPathComponent($0), SHA256())) })]],
            "inputs": ["ipsw": ["path": o.ipsw.path, "sha1": c.sha1], "decrypted": c.dec.path, "identity": "identity.json",
                       "activation": opt(c.activation.map { $0.record }),
                       "rootfs": "rootfs.dmg", "guest_tools": o.guestTools.path, "lockdown": NSNull()],
            "identity": ["seed": c.seed, "udid": c.ident.udid ?? "", "sha256": try Preparer.digest(c.file("identity.json"), SHA256())],
            "outputs": ["nand": ["path": "nand", "listing_sha256": c.listing, "built_listing_sha256": c.built]],
            "guest_package": opt(c.guestPackage?.object),
            "fit": c.fit.object,
        ]
        let lock = merged(shared, try board.lock(c))
        try fm.removeItem(at: c.work)
        try Preparer.lockData(lock).write(to: c.file("device.lock.json"))
        c.log("\(o.out.path): UDID \(c.ident.udid ?? "-")")
        progress.finish()
        emit(.done(lock: "device.lock.json"))
    }

    /// The entry's bytes for the lock's entry.sha256: sorted keys, so the hash is the same run to run (a Swift
    /// dictionary's order is per process; the unsorted encoding gave every lock a different entry.sha256).
    static var entryJSON: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }

    /// Every file under nand/ by its relative path, sorted (the store's listing order).
    static func nandFiles(_ nand: URL) throws -> [String] {
        var out: [String] = []
        guard let en = FileManager.default.enumerator(atPath: nand.path) else { return [] }
        while let rel = en.nextObject() as? String {
            if (en.fileAttributes?[.type] as? FileAttributeType) == .typeRegular { out.append(rel) }
        }
        return out.sorted()
    }

    /// `extras` over `base`; dictionaries merge recursively.
    static func merged(_ base: [String: Any], _ extras: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in extras {
            if let a = out[k] as? [String: Any], let b = v as? [String: Any] { out[k] = merged(a, b) } else { out[k] = v }
        }
        return out
    }

    /// The ramdisk the keybag one-shot boots: the build's own Update (else Restore) ramdisk out of the decrypt cache,
    /// or, for a build without ramdisk keys (recipe.keybag_ramdisk_from), the sibling entry's, decrypted into work.
    /// Returns (its URL, the lock's name for it).
    static func keybagRamdisk(_ c: Context) throws -> (URL, String) {
        // A restore-only build ships just the Restore ramdisk; a build whose Update ramdisk has no public key (the 5.0
        // betas, 9A334) boots its keyed Restore ramdisk: it runs the same restored_external.
        let comp = try BuildComponents.load(c.ipsw)
        guard let update = [comp["UpdateRamDisk"], comp["RestoreRamDisk"]].compactMap({ $0 }).first(where: { (try? c.e.key(forPath: $0)) != nil })
                ?? comp["UpdateRamDisk"] ?? comp["RestoreRamDisk"] else { throw FirmwareError(.unsupported, "\(c.e.id): no ramdisk") }
        let name = String(update.dropLast(4)) + "-ramdisk.dmg"
        guard let from = c.recipe.keybagRamdiskFrom else { return (c.decFile(name), name) }
        guard let sib = c.o.sibling, sib.entry.id == from else {
            throw FirmwareError(.unsupported, "\(c.e.id): the keybag ramdisk comes from \(from); pass --sibling-entry/--sibling-ipsw for it")
        }
        let rd = try Preparer.siblingRamdisk(sib.entry, ipsw: sib.ipsw, work: c.work)
        c.log("keybag ramdisk: \(from):\(rd.lastPathComponent) (this build has no ramdisk key)")
        return (rd, "\(from):\(rd.lastPathComponent)")
    }

    /// The path a lock's sha256 record names: {"path": n, "sha256": ...}.
    static func fileRecord(_ c: Context, _ n: String) throws -> [String: String] {
        ["path": n, "sha256": try Preparer.digest(c.file(n), SHA256())]
    }
}
