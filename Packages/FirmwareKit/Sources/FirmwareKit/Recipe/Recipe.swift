// Recipe: the one `firmwarekit create`. Every board runs the same steps in the same
// order; a board contributes only what differs (Board): its boot files, how its volumes are laid out, its NAND
// writer, its keybag one-shot, whether it needs a seal, and its keys in the lock.
//
//   create = verify -> decrypt -> identity + board.bootFiles -> board.volumes (the shared bake in SystemEdits)
//            -> board.store -> [board.keybag if data protection] -> [board.seal if needsSeal] -> lock
//
// Shared here: the IPSW sha1 and Restore.plist checks, the decrypt cache (versioned immutable entries with a validated manifest),
// the seed name ("<board.seedPrefix>-<build>-default"), the step/progress events, the read-only outputs, the
// store listing hashes (built_listing_sha256 before any boot, listing_sha256 after) and the lock, whose
// board-specific keys are merged in from `board.lock`. Helper file names and cache paths derive from
// `board.arch` (SystemEdits.Helpers.name, SystemEdits.dyldCache).

import Crypto
import FirmwareSchema
import Foundation
import HostRuntime

/// What one board adds to Recipe.create. Methods run in the order above, each inside its step.
protocol Board: AnyObject {
    /// "armv7" or "armv6": guest helper names and the dyld shared cache path.
    var arch: String { get }
    /// The default seed's prefix ("ipad1", "ipod2g"); the lock's identity.seed keeps it.
    var seedPrefix: String { get }
    var bootStep: String { get }
    var volumesStep: String { get }
    /// The store step's name: "Writing the NAND", or the N42's restore boot.
    var storeStep: String { get }
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
    nonisolated(nonsending) func volumes(_ c: Recipe.Context) async throws
    /// Writes nand/ from the volumes (the volumes are deleted after).
    nonisolated(nonsending) func store(_ c: Recipe.Context) async throws
    nonisolated(nonsending) func keybag(_ c: Recipe.Context) async throws
    func seal(_ c: Recipe.Context) throws
    /// The board's lock keys, merged (dictionaries recursively) onto the shared ones.
    func lock(_ c: Recipe.Context) throws -> [String: Any]
}

extension Board {
    var storeStep: String { "Writing the NAND" }
    func inspect(_ c: Recipe.Context) throws {}
    nonisolated(nonsending) func keybag(_ c: Recipe.Context) async throws {}
    func seal(_ c: Recipe.Context) throws {}
}

public enum Recipe {
    /// What the steps share; boards read and fill it.
    final class Context {
        let o: Preparer.Options, e: FirmwareEntry, recipe: FirmwareEntry.Recipe
        let emit: (PrepareEvent) -> Void
        let work: URL, nand: URL
        /// The verify step's private copy of the IPSW (Preparer.pinnedCopy), the only one read after it.
        var source: URL?
        var ipsw: IPSWArchive { IPSWArchive(source ?? work.appendingPathComponent("unverified.ipsw")) }
        /// Filled by the verify, decrypt and identity steps.
        var sha1 = "", restore: RestoreInfo?, dec: URL?, seed = "", ident: UnitIdentity?
        /// The Cydia bootstrap (recipe option jailbreak), fetched by the decrypt step.
        var cydia: URL?
        /// Filled by `volumes`.
        var activation: Activation.Result?, guestPackage: GuestPackage.Record?, engine: String?
        /// Filled by the store and lock steps.
        var built = "", nandHashes: [String: String] = [:], listing = ""
        /// Every fit check the steps ran (the lock's "fit"); an optional piece that does not fit is a warning event.
        lazy var fit = FitCheck.Log { [unowned self] in self.warn($0) }

        init(_ o: Preparer.Options, recipe: FirmwareEntry.Recipe, emit: @escaping (PrepareEvent) -> Void) {
            self.o = o
            e = o.entry
            self.recipe = recipe
            self.emit = emit
            work = o.out.appendingPathComponent("work")
            nand = o.out.appendingPathComponent("nand")
        }
        func file(_ n: String) -> URL { o.out.appendingPathComponent(n) }
        /// `dec`, once the decrypt step has filled it.
        func decrypted() throws -> URL { try dec.filled("the decrypted firmware") }
        func decFile(_ n: String) throws -> URL { try decrypted().appendingPathComponent(n) }
        /// stderr; a "warning: " line is also a warning event.
        /// Every warning event this prepare emitted.
        var warnings: [String] = []
        func log(_ s: String) {
            if s.hasPrefix("warning: ") {
                warnings.append(String(s.dropFirst(9)))
                emit(.warning(String(s.dropFirst(9))))
            }
            FirmwareDiagnostics.write(Data((s + "\n").utf8))
        }
        func warn(_ s: String) { log("warning: " + s) }
    }

    nonisolated(nonsending) static func create(
        _ o: Preparer.Options,
        board: Board,
        emit: @escaping @Sendable (PrepareEvent) -> Void
    ) async throws {
        let fm = FileManager.default
        let e = o.entry
        guard let recipe = e.recipe else { throw FirmwareError(.unsupported, "\(e.id): no recipe") }
        let c = Context(o, recipe: recipe, emit: emit)
        guard let sha1 = e.source.sha1 else { throw FirmwareError(.unsupported, "\(e.id) pins no IPSW sha1") }
        guard (try? fm.contentsOfDirectory(atPath: o.out.path))?.isEmpty == true else {
            throw FirmwareError(.internal, "\(o.out.path) is not an empty directory")
        }
        try board.check(c)
        if e.estimates.peakBytes > 0 {
            // The verify step's copy is a clone on the IPSW's own volume and a full copy from another.
            let cloned = Preparer.sameVolume(o.ipsw.resolvingSymlinksInPath(), o.out)
            try StorageCapacity.require(e.estimates.peakBytes - (cloned ? e.source.bytes ?? 0 : 0), at: o.out)
        }
        let steps =
            ["Verifying the IPSW", "Decrypting the firmware", board.bootStep, board.volumesStep, board.storeStep]
            + (board.dataProtection ? [board.keybagStep] : []) + (board.needsSeal ? [StepPlan.sealStep] : []) + [
                "Writing the lock"
            ]
        let major = Int(e.version.split(separator: ".").first ?? "") ?? 0
        emit(.begin(steps: steps.count, seconds: steps.map { StepPlan.plan($0, major: major).seconds }))
        let progress = StepProgress(work: c.work, major: major, emit: emit)
        defer { progress.stop() }
        var index = 0
        func step() {
            index += 1
            progress.next(index: index, name: steps[index - 1])
            c.log("[\(index)/\(steps.count)] \(steps[index - 1])")
        }

        step()  // verify
        // An IPSW imported from another volume is a symbolic link to the user's file (IPSWStore): the file's size.
        let ipswBytes = ByteCount(
            total: (try? fm.attributesOfItem(atPath: o.ipsw.resolvingSymlinksInPath().path)[.size] as? Int) ?? 0
        )
        progress.measure = { ipswBytes.fraction }
        c.source = try Preparer.pinnedCopy(o.ipsw, sha1: sha1, entry: e.id, into: c.work, count: ipswBytes.add)
        c.sha1 = sha1.lowercased()
        let restore = try RestoreInfo(c.ipsw)
        c.restore = restore
        try restore.verify(against: e)
        try board.inspect(c)

        step()  // decrypt, once per IPSW
        try fm.createDirectory(at: c.work, withIntermediateDirectories: true)
        let cacheRoot = o.cache ?? c.work.appendingPathComponent("cache")
        let cacheLease = try FirmwareCache.consume(root: cacheRoot)
        defer { withExtendedLifetime(cacheLease) {} }
        let dec = try DecryptionCache.resolve(
            root: cacheRoot,
            identity: .init(ipsw: sha1, entry: e),
            produce: { tmp in
                try FirmwareDecryptor.decrypt(ipsw: c.source.filled("the verified IPSW"), entry: e, into: tmp).files
            },
            reused: {
                c.log("reusing verified decrypt-cache manifest for \(e.id)")
            }
        )
        c.dec = dec
        if recipe.options["jailbreak"] == true, !(board is N45Board) {  // 1.x: no Cydia (installJailbreak1x)
            // Cydia's bootstrap beside the decrypt cache, as the app's caches keep IPSW and Decrypted
            c.cydia = try SystemEdits.Cydia.bootstrap(
                in: cacheRoot.deletingLastPathComponent().appendingPathComponent("Jailbreak"),
                log: c.log
            )
        }

        step()  // identity.json + the board's boot files
        c.seed = o.seed ?? "\(board.seedPrefix)-\(e.build)-default"
        let ident = try board.identity(seed: c.seed)
        c.ident = ident
        try ident.write(to: c.file("identity.json"))
        try board.bootFiles(c)

        step()  // volumes (+ the shared bake, activation, guest package)
        try await board.volumes(c)
        if o.stopAfterVolumes {
            let survey: [String: Any] = [
                "entry": e.id, "build": e.build, "board": e.board, "fit": c.fit.object,
                "guest_package": c.guestPackage?.object ?? NSNull(), "warnings": c.warnings
            ]
            // the volume images the recipe built (system.img, data.img or volume.img) kept beside it, for inspection
            let volumes = c.o.out.appendingPathComponent("volumes")
            try? fm.removeItem(at: volumes)
            try fm.createDirectory(at: volumes, withIntermediateDirectories: true)
            for n in try fm.contentsOfDirectory(atPath: c.work.path) where n.hasSuffix(".img") {
                try fm.moveItem(at: c.work.appendingPathComponent(n), to: volumes.appendingPathComponent(n))
            }
            try? fm.removeItem(at: c.work)
            try Preparer.lockData(survey).write(to: c.file("fit.json"))
            progress.finish()
            emit(.done(lock: "fit.json"))
            return
        }

        step()  // the store, and its listing before any boot writes into it (the lock's built_listing_sha256)
        try await board.store(c)
        c.built = try Preparer.nandListing(c.nand, files: try nandFiles(c.nand)).sha256
        c.log("store as built: listing sha256 \(c.built)")

        if board.dataProtection {
            step()  // 4.x data protection: effaceable + system keybag from the IPSW's own ramdisk
            try await board.keybag(c)
        }
        if board.needsSeal {
            step()  // one clean halt, then a check boot on a throwaway overlay
            try board.seal(c)
        }

        step()  // read-only outputs, lock
        for n in ["nand"] + board.shipped { try Preparer.readOnly(c.file(n)) }
        let files = try nandFiles(c.nand)
        let nandBytes = ByteCount(
            total: files.reduce(0) {
                $0 + ((try? fm.attributesOfItem(atPath: c.nand.appendingPathComponent($1).path)[.size] as? Int) ?? 0)
            }
        )
        progress.measure = { nandBytes.fraction }
        (c.nandHashes, c.listing) = try Preparer.nandListing(c.nand, files: files, count: nandBytes.add)
        let tools = try fm.contentsOfDirectory(atPath: o.guestTools.path).sorted()
        func opt(_ v: Any?) -> Any { v ?? NSNull() }
        let shared: [String: Any] = [
            "format": 1, "created": ISO8601DateFormatter().string(from: Date()),
            "preparation": PreparationChanges.serial,
            "entry": [
                "id": e.id, "sha256": Preparer.sha256(try entryJSON.encode(e)),
                "content": try JSONSerialization.jsonObject(with: entryJSON.encode(e))
            ],
            "build": e.build, "product_version": restore.productVersion, "product_type": e.productType,
            "board": e.board,
            "storage": recipe.storage,
            "tool": [
                "name": "firmwarekit", "version": FirmwareKit.version, "helper": opt(o.helper?.path),
                "built": [
                    "guest tools": Dictionary(
                        uniqueKeysWithValues: try tools.map {
                            ($0, try Preparer.digest(o.guestTools.appendingPathComponent($0), SHA256()))
                        }
                    )
                ]
            ],
            "inputs": [
                "ipsw": ["path": o.ipsw.path, "sha1": c.sha1], "decrypted": dec.path, "identity": "identity.json",
                "activation": opt(c.activation.map { $0.record }),
                "rootfs": "rootfs.dmg", "guest_tools": o.guestTools.path, "lockdown": NSNull(),
                // create's choices beyond the entry, for preparing the base again (LockedPreparation.plan)
                "language": opt(o.language), "keyboards": opt(o.keyboards), "hfs": VolumeMount.backend.rawValue,
                "sibling": opt(o.sibling.map { ["entry": $0.entry.id, "ipsw": $0.ipsw.path] })
            ],
            "identity": [
                "seed": c.seed, "udid": ident.udid ?? "",
                "sha256": try Preparer.digest(c.file("identity.json"), SHA256())
            ],
            "outputs": ["nand": ["path": "nand", "listing_sha256": c.listing, "built_listing_sha256": c.built]],
            "guest_package": opt(c.guestPackage?.object),
            "fit": c.fit.object
        ]
        let lock = merged(shared, try board.lock(c))
        try fm.removeItem(at: c.work)
        try DeviceLock(json: lock).data().write(to: c.file(DeviceLock.fileName))
        c.log("\(o.out.path): UDID \(ident.udid ?? "-")")
        progress.finish()
        emit(.done(lock: "device.lock.json"))
    }

    /// The entry's bytes for the lock's entry.sha256: sorted keys, so the hash is the same run to run (a Swift
    /// dictionary's order is per process; the unsorted encoding gave every lock a different entry.sha256).
    static var entryJSON: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

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
            if let a = out[k] as? [String: Any], let b = v as? [String: Any] {
                out[k] = merged(a, b)
            } else {
                out[k] = v
            }
        }
        return out
    }

    /// The ramdisk the keybag one-shot boots: the build's own Update (else Restore) ramdisk out of the decrypt cache,
    /// or, for a build without ramdisk keys (recipe.keybag_ramdisk_from), the sibling entry's, decrypted into work.
    /// Returns (its URL, the lock's name for it).
    nonisolated(nonsending) static func keybagRamdisk(_ c: Context) async throws -> (URL, String) {
        // A restore-only build ships just the Restore ramdisk; a build whose Update ramdisk has no public key (the 5.0
        // betas, 9A334) boots its keyed Restore ramdisk: it runs the same restored_external.
        let comp = try BuildComponents.load(c.ipsw, board: c.e.board)
        guard
            let update = [comp["UpdateRamDisk"], comp["RestoreRamDisk"]].compactMap({ $0 }).first(where: {
                (try? c.e.key(forPath: $0)) != nil
            })
                ?? comp["UpdateRamDisk"] ?? comp["RestoreRamDisk"]
        else { throw FirmwareError(.unsupported, "\(c.e.id): no ramdisk") }
        let name = FirmwareDecryptor.ramdiskName(update)
        guard let from = c.recipe.keybagRamdiskFrom else { return (try c.decFile(name), name) }
        guard let sib = c.o.sibling, sib.entry.id == from else {
            throw FirmwareError(
                .unsupported,
                "\(c.e.id): the keybag ramdisk comes from \(from); pass --sibling-entry/--sibling-ipsw for it"
            )
        }
        guard let sibSHA1 = sib.entry.source.sha1 else {
            throw FirmwareError(.unsupported, "\(sib.entry.id) pins no IPSW sha1")
        }
        let sibIPSW = try Preparer.pinnedCopy(sib.ipsw, sha1: sibSHA1, entry: sib.entry.id, into: c.work)
        defer { try? FileManager.default.removeItem(at: sibIPSW) }
        let rd = try Preparer.siblingRamdisk(sib.entry, ipsw: sibIPSW, work: c.work)
        c.log("keybag ramdisk: \(from):\(rd.lastPathComponent) (this build has no ramdisk key)")
        return (rd, "\(from):\(rd.lastPathComponent)")
    }

    /// The path a lock's sha256 record names: {"path": n, "sha256": ...}.
    static func fileRecord(_ c: Context, _ n: String) throws -> [String: String] {
        ["path": n, "sha256": try Preparer.digest(c.file(n), SHA256())]
    }
}

extension Optional {
    /// A value an earlier recipe step fills in (`what` names it); nil means a board ran its steps out of order.
    func filled(_ what: String) throws -> Wrapped {
        guard let self else { throw FirmwareError(.internal, "\(what) is not set: a recipe step ran out of order") }
        return self
    }
}
