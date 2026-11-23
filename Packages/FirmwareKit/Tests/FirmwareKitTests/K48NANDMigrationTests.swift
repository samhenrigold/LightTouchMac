import Crypto
import Foundation
import HostRuntime
import Testing

@testable import FirmwareKit

/// The format 2 migration (K48NANDMigration) on a small format 1 n81 device: a legacy store laid out by build, and an
/// overlay whose bitmap owns a superseding user page and a page the guest programmed all zero over base data (which
/// the IOP reads as erased), with an unowned page written after the bitmap's last publication (which it ignores).
struct K48NANDMigrationTests {
    let geo = K48NAND.Geometry.selfcheck
    let ps = 4096
    struct Killed: Error {}

    struct Device {
        let root: URL
        var device: URL { root.appendingPathComponent("Devices/\(id.uuidString)") }
        let id = UUID()
        var base: URL { device.appendingPathComponent("base") }
        var nand: URL { base.appendingPathComponent("nand") }
        var overlay: URL { device.appendingPathComponent("overlay") }
        var record: URL { device.appendingPathComponent(DeviceRecord.name) }
        var layout: K48NANDMigration.Layout { .init(device: device) }
        func owner() throws -> StoppedRecordOwner { try StoppedRecordOwner(device: device) }
        func format() throws -> Int { try DeviceRecord.object(Data(contentsOf: record))["format"] as? Int ?? 1 }
    }

    /// Physical pages the overlay owns or holds: the superseding user page, the all-zero one, the stale one.
    var superseding: (cs: Int, ppage: Int) { geo.vpnToPhys((geo.numBlocks - 2) * geo.ppsublk) }
    var zeroed: (cs: Int, ppage: Int) { geo.vpnToPhys(3 * geo.ppsublk + 63 + 20) }  // system LBA 20's page
    var stale: (cs: Int, ppage: Int) { geo.vpnToPhys(3 * geo.ppsublk + 63 + 40) }

    func makeDevice(_ root: URL, board: String = "n81ap") async throws -> Device {
        let d = Device(root: root)
        let fm = FileManager.default
        try fm.createDirectory(at: d.base, withIntermediateDirectories: true)
        var mbr = [UInt8](repeating: 0, count: ps * 63)
        mbr[510] = 0x55
        mbr[511] = 0xAA
        for (i, (typ, lba, cnt)) in [(0xAF, 63, 700), (0xAF, 800, 400)].enumerated() {
            put32(&mbr, 0x1be + 16 * i + 8, UInt32(lba))
            put32(&mbr, 0x1be + 16 * i + 12, UInt32(cnt))
            mbr[0x1be + 16 * i + 4] = UInt8(typ)
        }
        var sys = (0..<ps * 700).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) }
        sys[1024] = UInt8(ascii: "H")
        sys[1025] = UInt8(ascii: "X")
        var data = [UInt8](repeating: 0, count: ps * 400)
        data[1024] = UInt8(ascii: "H")
        data[1025] = UInt8(ascii: "+")
        let inputs = root.appendingPathComponent("inputs")
        try fm.createDirectory(at: inputs, withIntermediateDirectories: true)
        let paths = ["mbr", "system.img", "data.img"].map { inputs.appendingPathComponent($0) }
        try Data(mbr).write(to: paths[0])
        try Data(sys).write(to: paths[1])
        try Data(data).write(to: paths[2])
        try await K48NAND.build(
            geometry: geo,
            mbr: paths[0],
            kernelVersion: Array("Darwin Kernel Version selfcheck".utf8),
            system: paths[1],
            data: .image(paths[2]),
            out: d.nand,
            format: .legacy
        )
        let st = try K48NAND.Store(create: d.overlay, geo: geo, format: .legacy)
        var dirty = [[UInt8]](repeating: [UInt8](repeating: 0, count: geo.pagesPerCE / 8), count: geo.numCS)
        try st.write(
            superseding.cs,
            superseding.ppage,
            [UInt8](repeating: 0xA1, count: ps),
            K48NAND.spare(63 + 5, 1000, K48NAND.tUser)
        )
        dirty[superseding.cs][superseding.ppage / 8] |= 1 << (superseding.ppage % 8)
        try st.write(
            stale.cs,
            stale.ppage,
            [UInt8](repeating: 0xB2, count: ps),
            K48NAND.spare(63 + 6, 2000, K48NAND.tUser)
        )
        st.close()
        try fm.removeItem(at: d.overlay.appendingPathComponent("geometry.json"))  // an IOP overlay has none
        dirty[zeroed.cs][zeroed.ppage / 8] |= 1 << (zeroed.ppage % 8)  // the overlay's record there is a hole: all zero
        for cs in 0..<geo.numCS {
            try Data(dirty[cs]).write(to: d.overlay.appendingPathComponent(K48NANDImage.name(cs, geo, "dirty")))
        }
        try Data("legacy-zero-blank-v1".utf8).write(to: d.overlay.appendingPathComponent("storage-format"))
        try Data("key".utf8).write(to: d.overlay.appendingPathComponent(".base-identity"))
        let record: [String: Any] = [
            "format": 1, "id": d.id.uuidString, "board": board, "firmware": "\(board)-test",
            "base": ["kind": "prepared", "path": d.base.path],
            "storage": [
                "key": "key", "overlay": d.overlay.path, "snapshot": d.device.appendingPathComponent("snapshot").path
            ]
        ]
        try DeviceRecord.data(record).write(to: d.record)
        try Preparer.readOnly(d.nand)
        chflags(d.nand.path, UInt32(UF_IMMUTABLE))
        chflags(d.base.path, UInt32(UF_IMMUTABLE))
        return d
    }

    func withDevice(board: String = "n81ap", _ body: (Device) async throws -> Void) async throws {
        let root = try Fixtures.tempDir("k48-migration")
        defer { try? K48NANDMigration.removeTree(root) }
        try await body(try await makeDevice(root, board: board))
    }

    /// The data a tree holds: each file's size and its data extents' bytes (the stores are sparse).
    func contents(_ dir: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() {
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }
            let fd = open(url.path, O_RDONLY)
            defer { close(fd) }
            var h = SHA256()
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            for block in K48NANDImage.dataBlocks(fd, blockBytes: buffer.count).sorted() {
                let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(block << 20)) }
                h.update(data: Data(buffer[..<max(n, 0)]))
            }
            var st = stat()
            fstat(fd, &st)
            out[name] = "\(st.st_size) \(h.finalize().hexString)"
        }
        return out
    }

    func volumes(_ store: URL, _ overlay: URL?, _ work: URL) throws -> [String: String] {
        defer { TemporaryTrees.remove(work) }
        return try Dictionary(
            uniqueKeysWithValues: VolumeRebuild.rebuild(base: store, overlay: overlay, into: work).map {
                ($0.name, try Preparer.digest($0.image, SHA256()))
            }
        )
    }

    func flags(_ url: URL) -> UInt32 {
        var st = stat()
        lstat(url.path, &st)
        return st.st_flags
    }

    @Test func migratesPageExactAndKeepsTheFormat1StoreUntilACleanStop() async throws {
        try await withDevice { d in
            let before = try volumes(d.nand, d.overlay, d.root.appendingPathComponent("v0"))
            let oldBase = try contents(d.nand)
            #expect(try K48NANDMigration.admit(d.owner()))
            #expect(try d.format() == 2)
            #expect(try K48NAND.storeFormat(d.nand) == .image)
            let live = PreparedDeviceBoot.liveNAND(overlay: d.overlay)
            #expect(try K48NAND.storeFormat(live) == .image)
            #expect(try volumes(d.nand, d.overlay, d.root.appendingPathComponent("v1")) == before)
            // the guest's view, page by page: the all-zero owned page reads erased, the stale page the base's
            let st = try K48NAND.StoreReader(d.nand, geo: geo, overlay: d.overlay)
            #expect(st.read(zeroed.cs, zeroed.ppage) == nil)
            #expect(st.read(superseding.cs, superseding.ppage)?.data.allSatisfy { $0 == 0xA1 } == true)
            let base = try K48NAND.StoreReader(d.nand, geo: geo)
            #expect(st.read(stale.cs, stale.ppage)?.data == base.read(stale.cs, stale.ppage)?.data)
            #expect(base.read(zeroed.cs, zeroed.ppage) != nil && base.read(superseding.cs, superseding.ppage) == nil)
            // the base is published read-only and immutable again; the format 1 files are kept
            #expect(flags(d.base) & UInt32(UF_IMMUTABLE) != 0 && flags(d.nand) & UInt32(UF_IMMUTABLE) != 0)
            #expect(access(d.nand.appendingPathComponent("bus0-ce0.pages").path, W_OK) != 0)
            #expect(try contents(d.layout.legacy.appendingPathComponent("base-nand")) == oldBase)
            let left = try FileManager.default.contentsOfDirectory(atPath: d.overlay.path).sorted()
            #expect(left == [".base-identity", "nand"], "\(left)")
            #expect(!FileManager.default.fileExists(atPath: d.layout.intent.path))
            #expect(!FileManager.default.fileExists(atPath: d.layout.migrating.path))
            // kept through a start without a clean stop, gone after one
            #expect(try K48NANDMigration.admit(d.owner()) == false)
            #expect(FileManager.default.fileExists(atPath: d.layout.legacy.path))
            let marker = PreparedDeviceBoot.cleanStopMarker(lease: d.device.appendingPathComponent("work/lease"))
            FileManager.default.createFile(atPath: marker.path, contents: nil)
            #expect(try K48NANDMigration.admit(d.owner()))
            #expect(!FileManager.default.fileExists(atPath: d.layout.legacy.path))
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    /// A byte changed in either new image after the build (in data, or in what was a hole) fails the proof, and the
    /// device stays exactly as it was, in format 1.
    @Test(arguments: [false, true]) func aCorruptedImageLeavesTheDeviceUntouched(inBase: Bool) async throws {
        try await withDevice { d in
            let record = try Data(contentsOf: d.record)
            let (oldBase, oldOverlay) = (try contents(d.nand), try contents(d.overlay))
            let stride = geo.pageSize + geo.spareBytes
            let changed = try K48NANDMigration.admit(
                d.owner(),
                checkpoint: { checkpoint in
                    guard checkpoint == .built else { return }
                    let (dir, cs, offset) =
                        inBase
                        ? ("base-nand", 3, (geo.pagesPerCE - 1) * stride)  // the last page: a hole
                        : ("nand", superseding.cs, superseding.ppage * stride + 100)
                    let file = d.layout.migrating.appendingPathComponent(
                        "\(dir)/\(K48NANDImage.name(cs, geo, "pages"))"
                    )
                    let fd = open(file.path, O_RDWR)
                    defer { close(fd) }
                    var byte: UInt8 = 0
                    pread(fd, &byte, 1, off_t(offset))
                    byte ^= 0x40
                    pwrite(fd, &byte, 1, off_t(offset))
                }
            )
            #expect(!changed)
            #expect(try Data(contentsOf: d.record) == record)
            #expect(try contents(d.nand) == oldBase && contents(d.overlay) == oldOverlay)
            #expect(try K48NAND.storeFormat(d.nand) == .legacy)
            for dir in [d.layout.migrating, d.layout.legacy, d.layout.intent] {
                #expect(!FileManager.default.fileExists(atPath: dir.path))
            }
            #expect(flags(d.base) & UInt32(UF_IMMUTABLE) != 0)
        }
    }

    /// A run killed at each step: the next admission rolls back before the record swap (format 1, as it was; the
    /// start after migrates) and finishes after it (format 2).
    @Test func aRunKilledAtEachStepRecovers() async throws {
        var steps: [K48NANDMigration.Checkpoint] = [.built, .verified]
        steps += (0..<12).map { .renamed($0) }  // base/nand, 4 x (.pages, .dirty), storage-format, the base, the live
        steps.append(.recordWritten)
        for step in steps {
            try await withDevice { d in
                let record = try Data(contentsOf: d.record)
                let (oldBase, oldOverlay) = (try contents(d.nand), try contents(d.overlay))
                let paths = try #require(try d.owner().paths)
                #expect(throws: Killed.self) {
                    try K48NANDMigration.migrate(d.layout, base: paths.base, overlay: paths.overlay, log: { _ in }) {
                        if $0 == step { throw Killed() }
                    }
                }
                #expect(try K48NANDMigration.admit(d.owner(), log: { _ in }), "\(step)")
                for dir in [d.layout.migrating, d.layout.intent] {
                    #expect(!FileManager.default.fileExists(atPath: dir.path), "\(step)")
                }
                #expect(flags(d.base) & UInt32(UF_IMMUTABLE) != 0, "\(step)")
                if step == .recordWritten {
                    #expect(try d.format() == 2 && K48NAND.storeFormat(d.nand) == .image)
                    #expect(
                        FileManager.default.fileExists(atPath: PreparedDeviceBoot.liveNAND(overlay: d.overlay).path)
                    )
                    #expect(try contents(d.layout.legacy.appendingPathComponent("base-nand")) == oldBase)
                } else {
                    #expect(try Data(contentsOf: d.record) == record, "\(step)")
                    #expect(try contents(d.nand) == oldBase && contents(d.overlay) == oldOverlay, "\(step)")
                    #expect(!FileManager.default.fileExists(atPath: d.layout.legacy.path), "\(step)")
                    #expect(try K48NANDMigration.admit(d.owner(), log: { _ in }) && d.format() == 2, "\(step)")
                }
            }
        }
    }

    /// The start's toast: the migration's progress file climbs from 0 to 1 through the run (the app reads it beside the
    /// lease) and is gone after; the toast says "Updating storage (one time)…" with the percentage.
    @Test func progressIsReportedForTheStartsToast() async throws {
        try await withDevice { d in
            let lease = d.device.appendingPathComponent("work/lease")
            var seen: [Double] = []
            let changed = try K48NANDMigration.admit(
                d.owner(),
                checkpoint: { _ in
                    if let p = PreparedDeviceBoot.readMigrationProgress(lease: lease) { seen.append(p) }
                }
            )
            #expect(changed)
            #expect(seen.count == 15, "\(seen)")  // built, verified, 12 renames, the record: there throughout
            #expect(seen == seen.sorted() && seen.first.map { $0 > 0 && $0 < 1 } == true && seen.last == 1, "\(seen)")
            #expect(PreparedDeviceBoot.readMigrationProgress(lease: lease) == nil)
            #expect(!FileManager.default.fileExists(atPath: PreparedDeviceBoot.migrationProgress(lease: lease).path))
        }
        try await withDevice { d in
            var reported: [Double] = []
            _ = try K48NANDMigration.admit(d.owner(), progress: { reported.append($0) })
            // 0, a step for each of the 4 chip selects converted (base, live) and checked, the 2 volume sets, then 1
            #expect(reported.count == 1 + 14 + 1 && reported == reported.sorted(), "\(reported)")
            #expect(reported.first == 0 && reported.last == 1)
        }
        #expect(PreparedDeviceBoot.migrationText(0.4249) == "Updating storage (one time)… 42%")
        #expect(PreparedDeviceBoot.migrationText(1) == "Updating storage (one time)… 100%")
    }

    /// No room for the build: a quiet notice naming the space needed, and the device starts as before. A migration
    /// that fails says so quietly too.
    @Test func noRoomOrAFailureIsAQuietNotice() async throws {
        try await withDevice { d in
            let record = try Data(contentsOf: d.record)
            var notices: [String] = []
            let changed = try K48NANDMigration.admit(
                d.owner(),
                notice: { notices.append($0) },
                available: { _ in 1 << 20 }
            )
            #expect(!changed && notices.count == 1)
            #expect(notices.first?.hasPrefix("Light Touch needs 1.") == true, "\(notices)")  // GB: 2 x base + 1 GiB
            #expect(notices.first?.contains("of free space to update this device’s storage") == true)
            #expect(try Data(contentsOf: d.record) == record)
            #expect(!FileManager.default.fileExists(atPath: d.layout.intent.path))
        }
        try await withDevice { d in
            var notices: [String] = []
            let changed = try K48NANDMigration.admit(
                d.owner(),
                checkpoint: { if $0 == .built { throw Killed() } },
                notice: { notices.append($0) }
            )
            #expect(!changed)
            #expect(try d.format() == 1)
            #expect(
                notices == [
                    "Light Touch couldn’t update this device’s storage, so it starts as before. The details are in the log."
                ]
            )
        }
    }

    /// Only a kboot board's format 1 record over its own legacy store migrates.
    @Test func otherDevicesAreLeftAlone() async throws {
        try await withDevice(board: "n72ap") { d in
            let changed = try K48NANDMigration.admit(d.owner())
            #expect(!changed)
            #expect(try d.format() == 1)
            #expect(try K48NAND.storeFormat(d.nand) == .legacy)
        }
        try await withDevice { d in
            var record = try DeviceRecord.object(Data(contentsOf: d.record))
            record["base"] = ["kind": "prepared", "path": d.root.appendingPathComponent("elsewhere").path]
            try DeviceRecord.data(record).write(to: d.record)
            #expect(try K48NANDMigration.admit(d.owner()) == false)
        }
    }

    /// The legacy format reads an all-zero record as erased; the image format keeps one programmed as such, and a hole
    /// is erased. Its geometry names the format and FirmwareKit's layout, without which the format is refused.
    @Test func imageStoreRecordsReadBackAsWritten() throws {
        try Oracle.withTemp { dir in
            let st = try K48NAND.Store(create: dir, geo: geo, plain: true)
            try st.write(0, 7, [UInt8](repeating: 0, count: ps), K48NAND.spare(1, 1, K48NAND.tUser))
            try st.write(0, 8, [UInt8](repeating: 0xFF, count: ps), K48NAND.spare(2, 1, K48NAND.tUser))
            st.close()
            #expect(try K48NAND.storeFormat(dir) == .image)
            let r = try K48NAND.StoreReader(dir, geo: geo)
            #expect(
                r.read(0, 7, raw: true).map { $0.data.allSatisfy { $0 == 0 } && (try? le32($0.meta, 0)) == 1 } == true)
            #expect(
                r.read(0, 8, raw: true).map { $0.data.allSatisfy { $0 == 0xFF } && (try? le32($0.meta, 0)) == 2 }
                    == true)
            #expect(r.read(0, 9) == nil && r.read(1, 7) == nil)
            var g = try K48NAND.geometryObject(dir)
            g.removeValue(forKey: "layout")
            try JSONSerialization.data(withJSONObject: g).write(to: dir.appendingPathComponent("geometry.json"))
            #expect(throws: FirmwareError.self) { try K48NAND.StoreReader(dir, geo: geo) }
        }
    }

    /// FK_MIGRATION_DEVICE: a copy of a real format 1 A4, S5L8920 or iPod touch 2G device (its Devices/<uuid>, never
    /// the original).
    /// A byte flipped in the new base or live image after the build fails the proof and leaves the device as it was.
    @Test(
        .serialized,
        .enabled(if: ProcessInfo.processInfo.environment["FK_MIGRATION_DEVICE"] != nil, "set FK_MIGRATION_DEVICE"),
        arguments: ["base-nand", "nand"]
    )
    func aRealDeviceCopyRefusesACorruptedImage(_ image: String) throws {
        let device = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["FK_MIGRATION_DEVICE"]))
        let d = K48NANDMigration.Layout(device: device)
        let paths = try #require(try StoppedRecordOwner(device: device).paths)
        let record = try Data(contentsOf: d.record)
        let (oldBase, oldOverlay) = (
            try contents(paths.base.appendingPathComponent("nand")), try contents(paths.overlay)
        )
        let changed = try K48NANDMigration.admit(
            StoppedRecordOwner(device: device),
            checkpoint: { checkpoint in
                let file = ["bus1-ce2.pages", "cs1.pages"].map { d.migrating.appendingPathComponent("\(image)/\($0)") }
                    .first { FileManager.default.fileExists(atPath: $0.path) }
                guard checkpoint == .built, let file else { return }
                let fd = open(file.path, O_RDWR)
                defer { close(fd) }
                let offset = off_t((K48NANDImage.dataBlocks(fd, blockBytes: 1 << 20).min() ?? 0) << 20) + 4100
                var byte: UInt8 = 0
                pread(fd, &byte, 1, offset)
                byte ^= 0x01
                pwrite(fd, &byte, 1, offset)
            }
        )
        #expect(!changed)
        #expect(try Data(contentsOf: d.record) == record)
        #expect(try contents(paths.base.appendingPathComponent("nand")) == oldBase)
        #expect(try contents(paths.overlay) == oldOverlay)
        for gone in [d.migrating, d.legacy, d.intent] { #expect(!FileManager.default.fileExists(atPath: gone.path)) }
    }
}
