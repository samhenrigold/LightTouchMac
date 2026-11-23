import Crypto
import Foundation
import HostRuntime
import Testing

@testable import FirmwareKit

/// The 1.x boards' image store (PageNANDImage.s5l8900) and its format 2 migration (K48NANDMigration's steps over
/// PageNANDImage's page directories) on a small format 1 original iPhone: N45FTLTests' prepared volume as bank<N>
/// page files, with the odd pages a store can hold (short, empty, every bit set, all zero), under an overlay that
/// supersedes a page of the volume, adds pages, marks a block erased and rewrites a page inside it, and holds a stray
/// temporary file and the 1.x SystemConfiguration step's stamp.
@Suite(.detachesItsImages) struct N45NANDMigrationTests {
    struct Killed: Error {}
    typealias Device = N72NANDMigrationTests.Device
    typealias Address = PageNANDImage.Address

    static let image = PageNANDImage.s5l8900(banks: N45FTLTests.banks)
    static let stride = image.stride
    static let erasedBlock = 2001  // on bank 1, in the overlay
    static func record(_ fill: UInt8, spare: UInt8 = 0x5A) -> [UInt8] {
        [UInt8](repeating: fill, count: N45NAND.page) + [UInt8](repeating: spare, count: N45NAND.spare)
    }
    static let odd: [Address: [UInt8]] = [
        Address(chip: 0, page: 2000 * 128): [UInt8](repeating: 0x33, count: 20),  // short: zero-filled
        Address(chip: 0, page: 2000 * 128 + 1): [],  // empty: all zero, spare too (not an erased page)
        Address(chip: 3, page: 2000 * 128 + 2): image.blankRecord,  // every bit set: erased, a hole
        Address(chip: 2, page: 2000 * 128 + 3): [UInt8](repeating: 0, count: stride),
        Address(chip: 1, page: erasedBlock * 128 + 1): record(0x44),  // under the mark
        Address(chip: 1, page: erasedBlock * 128 + 2): record(0x45)
    ]
    /// The FTL's location of logical page 10 (the base's map): the guest rewrote it in place.
    static var superseded: Address {
        let p = N45NAND.location(lpn: 10, banks: N45FTLTests.banks)
        return Address(chip: p.bank, page: p.page)
    }
    static func overlayPages(_ supersededSpare: [UInt8]) -> [Address: [UInt8]] {
        [
            superseded: [UInt8](repeating: 0xC3, count: N45NAND.page) + supersededSpare,
            Address(chip: 1, page: erasedBlock * 128 + 2): record(0x46),  // rewritten after the mark
            Address(chip: 2, page: 3000 * 128 + 5): [UInt8](repeating: 0x21, count: 100),  // short, overlay only
            Address(chip: 3, page: 3001 * 128): record(0x47)  // the base has none
        ]
    }

    func write(_ bytes: [UInt8], _ a: Address, in dir: URL) throws {
        let bank = dir.appendingPathComponent("bank\(a.chip)")
        try FileManager.default.createDirectory(at: bank, withIntermediateDirectories: true)
        try Data(bytes).write(to: bank.appendingPathComponent("\(a.page).page"))
    }

    func makeDevice(_ root: URL) throws -> Device {
        let d = Device(root: root)
        let fm = FileManager.default
        try fm.createDirectory(at: d.base, withIntermediateDirectories: true)
        // N45NAND writes an image store; format 1 is its every written page as a file
        let (prepared, _) = try N45FTLTests.prepared(root)
        let store = try PageNANDImage.Store(prepared)
        for chip in 0..<Self.image.chips {
            try fm.createDirectory(at: d.nand.appendingPathComponent("bank\(chip)"), withIntermediateDirectories: true)
            for page in store.dataBlocks(chip).flatMap({ $0 * 128..<($0 + 1) * 128 }) {
                let r = try store.read(chip, page)
                if r != Self.image.blankRecord { try write(r, Address(chip: chip, page: page), in: d.nand) }
            }
        }
        let spare = try store.read(Self.superseded.chip, Self.superseded.page)[N45NAND.page...]
        for (a, bytes) in Self.odd { try write(bytes, a, in: d.nand) }
        for (a, bytes) in Self.overlayPages(Array(spare)) { try write(bytes, a, in: d.overlay) }
        try Data().write(to: d.overlay.appendingPathComponent("bank1/blk\(Self.erasedBlock).erased"))
        try Data([1, 2, 3]).write(to: d.overlay.appendingPathComponent("bank1/.7.page.tmp"))
        try Data("key".utf8).write(to: d.overlay.appendingPathComponent(".base-identity"))
        try Data().write(to: d.overlay.appendingPathComponent(N45Migration.stamp))
        let record: [String: Any] = [
            "format": 1, "id": d.id.uuidString, "board": "m68ap", "firmware": "m68ap-test",
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

    func withDevice(_ body: (Device) async throws -> Void) async throws {
        let root = try Fixtures.tempDir("n45-migration")
        defer { try? K48NANDMigration.removeTree(root) }
        try await body(try makeDevice(root))
    }

    /// Every page a file of the device names, plus a few no file names.
    func pages(_ d: Device) -> [Address] {
        var all = PageNANDImage.LegacyReader(Self.image, base: d.nand, overlay: d.overlay).pages
        all.formUnion([Address(chip: 0, page: 0), Address(chip: 3, page: Self.image.pagesPerChip - 1)])
        return all.sorted { ($0.chip, $0.page) < ($1.chip, $1.page) }
    }

    func view(_ base: URL, _ overlay: URL?, _ pages: [Address]) throws -> [Address: [UInt8]] {
        let read = try Self.image.reader(base: base, overlay: overlay)
        return try Dictionary(uniqueKeysWithValues: pages.map { ($0, try read($0)) })
    }

    func volume(_ base: URL, _ overlay: URL?, _ work: URL) throws -> String {
        defer { TemporaryTrees.remove(work) }
        return try Preparer.digest(VolumeRebuild.rebuild(base: base, overlay: overlay, into: work)[0].image, SHA256())
    }

    func flags(_ url: URL) -> UInt32 {
        var st = stat()
        lstat(url.path, &st)
        return st.st_flags
    }

    @Test func imageRecordsReadBackAsWrittenAndHolesReadErased() throws {
        let dir = try Fixtures.tempDir("n45-image").appendingPathComponent("nand")
        let store = try PageNANDImage.Store(create: dir, Self.image)
        let zero = [UInt8](repeating: 0, count: Self.stride)
        try store.write(2, 7, zero)
        try store.write(3, Self.image.pagesPerChip - 1, Self.record(0x12))
        try store.sync()
        #expect(PageNANDImage.of(dir) == Self.image && PreparedDeviceBoot.isImageStore(dir))
        #expect(try VolumeRebuild.board(of: dir) == .legacy && !N72NANDImage.isImage(dir))
        let read = try PageNANDImage.Store(dir)
        #expect(try read.read(2, 7) == zero)  // all zero is not an erased page
        #expect(try read.read(3, Self.image.pagesPerChip - 1) == Self.record(0x12))
        #expect(try read.read(0, 7) == Self.image.blankRecord)
        // as stored: XOR 0xFF, so an erased page is a hole (zero) and the qemu-ios FMC reads it so
        let fd = open(dir.appendingPathComponent("cs2.pages").path, O_RDONLY)
        defer { close(fd) }
        var head = [UInt8](repeating: 0, count: 4)
        pread(fd, &head, 4, off_t(7 * Self.stride))
        #expect(head == [0xFF, 0xFF, 0xFF, 0xFF])
        let geometry = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("geometry.json"))
        )
        #expect(
            (geometry as? NSDictionary)
                == [
                    "storage_format": "nand-xor-blank-v2", "blank": "ff", "board": "s5l8900", "chip_selects": 4,
                    "page_bytes": 2048, "spare_bytes": 64, "pages_per_block": 128, "blocks_per_ce": 4096
                ]
        )
    }

    /// Two records 14 MiB apart: APFS fills the gap with allocated zeros, and compaction punches them, the records
    /// reading back as written and the gap blank.
    @Test func compactionGivesBackTheZerosAroundScatteredRecords() throws {
        let dir = try Fixtures.tempDir("n45-compact").appendingPathComponent("nand")
        let store = try PageNANDImage.Store(create: dir, Self.image)
        let far = 14 * (1 << 20) / Self.stride
        try store.write(1, 0, Self.record(0x12))
        try store.write(1, far, Self.record(0x34))
        try store.sync()
        func allocated() -> Int {
            var st = stat()
            stat(dir.appendingPathComponent("cs1.pages").path, &st)
            return Int(st.st_blocks) * 512
        }
        let filled = allocated()
        try store.compact(1)
        #expect(filled > 12 << 20 && allocated() < 1 << 20, "\(filled) -> \(allocated())")
        #expect(try store.read(1, 0) == Self.record(0x12) && store.read(1, far) == Self.record(0x34))
        #expect(try store.read(1, far / 2) == Self.image.blankRecord)
    }

    @Test func migratesPageExactAndKeepsTheFormat1StoreUntilACleanStop() async throws {
        try await withDevice { d in
            let pages = pages(d)
            let guest = try view(d.nand, d.overlay, pages)
            let base = try view(d.nand, nil, pages)
            let before = try volume(d.nand, d.overlay, d.root.appendingPathComponent("v0"))
            // the fixture reads as the FMC did: the mark erases its block but for the page rewritten after it, and
            // the guest's rewrite of logical page 10 is in the volume
            #expect(guest[Address(chip: 1, page: Self.erasedBlock * 128 + 1)] == Self.image.blankRecord)
            #expect(guest[Address(chip: 1, page: Self.erasedBlock * 128 + 2)] == Self.record(0x46))
            #expect(guest[Address(chip: 0, page: 2000 * 128 + 1)] == [UInt8](repeating: 0, count: Self.stride))
            #expect(before != (try volume(d.nand, nil, d.root.appendingPathComponent("v-base"))))

            #expect(try FirmwareBootAdmission.migrate(d.owner()))  // the 1.x boards' admission
            #expect(try d.format() == 2 && PageNANDImage.of(d.nand) == Self.image)
            let live = PreparedDeviceBoot.liveNAND(overlay: d.overlay)
            #expect(PageNANDImage.of(live) == Self.image)
            #expect(try view(d.nand, d.overlay, pages) == guest)
            #expect(try view(d.nand, nil, pages) == base)
            #expect(try volume(d.nand, d.overlay, d.root.appendingPathComponent("v1")) == before)
            #expect(try N45FTL(base: d.nand, overlay: d.overlay).read(lpn: 10)?.data.first == 0xC3)
            #expect(flags(d.base) & UInt32(UF_IMMUTABLE) != 0 && flags(d.nand) & UInt32(UF_IMMUTABLE) != 0)
            #expect(access(d.nand.appendingPathComponent("cs0.pages").path, W_OK) != 0)
            let left = try FileManager.default.contentsOfDirectory(atPath: d.overlay.path).sorted()
            #expect(left == [".base-identity", N45Migration.stamp, "nand"].sorted(), "\(left)")
            let kept = try FileManager.default.contentsOfDirectory(
                atPath: d.layout.legacy.appendingPathComponent("overlay").path
            )
            let banks = Set(Self.overlayPages([]).keys.map { "bank\($0.chip)" }).union(["bank1"])
            #expect(kept.sorted() == banks.sorted())
            #expect(!FileManager.default.fileExists(atPath: d.layout.intent.path))
            // kept through a start without a clean stop, gone after one
            #expect(try K48NANDMigration.admit(d.owner()) == false)
            let marker = PreparedDeviceBoot.cleanStopMarker(lease: d.device.appendingPathComponent("work/lease"))
            FileManager.default.createFile(atPath: marker.path, contents: nil)
            #expect(try K48NANDMigration.admit(d.owner()))
            #expect(!FileManager.default.fileExists(atPath: d.layout.legacy.path))
        }
    }

    /// A byte changed in either new image after the build fails the proof, and the device stays as it was.
    @Test(arguments: [false, true]) func aCorruptedImageLeavesTheDeviceUntouched(inBase: Bool) async throws {
        try await withDevice { d in
            let record = try Data(contentsOf: d.record)
            let pages = pages(d)
            let guest = try view(d.nand, d.overlay, pages)
            let changed = try K48NANDMigration.admit(
                d.owner(),
                checkpoint: { checkpoint in
                    guard checkpoint == .built else { return }
                    let a = inBase ? Address(chip: 0, page: 2000 * 128 + 1) : Address(chip: 3, page: 3001 * 128)
                    let dir = inBase ? "base-nand" : "nand"
                    let fd = open(d.layout.migrating.appendingPathComponent("\(dir)/cs\(a.chip).pages").path, O_RDWR)
                    defer { close(fd) }
                    var byte: UInt8 = 0
                    pread(fd, &byte, 1, off_t(a.page * Self.stride + 100))
                    byte ^= 0x40
                    pwrite(fd, &byte, 1, off_t(a.page * Self.stride + 100))
                }
            )
            #expect(!changed)
            #expect(try Data(contentsOf: d.record) == record)
            #expect(try view(d.nand, d.overlay, pages) == guest)
            #expect(PageNANDImage.of(d.nand) == nil)
            for dir in [d.layout.migrating, d.layout.legacy, d.layout.intent] {
                #expect(!FileManager.default.fileExists(atPath: dir.path))
            }
        }
    }

    /// A run killed at each step: rolled back before the record swap (format 1; the next start migrates), finished
    /// after it (format 2).
    @Test func aRunKilledAtEachStepRecovers() async throws {
        let overlayDirs = Set(Self.overlayPages([]).keys.map(\.chip)).union([1]).count
        var steps: [K48NANDMigration.Checkpoint] = [.built, .verified]
        steps += (0..<overlayDirs + 3).map { .renamed($0) }  // base/nand, the overlay's banks, the base, the live
        steps.append(.recordWritten)
        for step in steps {
            try await withDevice { d in
                let record = try Data(contentsOf: d.record)
                let pages = pages(d)
                let guest = try view(d.nand, d.overlay, pages)
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
                    #expect(try d.format() == 2 && PageNANDImage.of(d.nand) == Self.image, "\(step)")
                } else {
                    #expect(try Data(contentsOf: d.record) == record, "\(step)")
                    #expect(PageNANDImage.of(d.nand) == nil, "\(step)")
                    #expect(!FileManager.default.fileExists(atPath: d.layout.legacy.path), "\(step)")
                    #expect(try K48NANDMigration.admit(d.owner(), log: { _ in }) && d.format() == 2, "\(step)")
                }
                #expect(try view(d.nand, d.overlay, pages) == guest, "\(step)")
            }
        }
    }

    @Test func progressClimbsThroughTheRun() async throws {
        try await withDevice { d in
            var reported: [Double] = []
            _ = try K48NANDMigration.admit(d.owner(), progress: { reported.append($0) })
            // 0, a step for each of the 4 banks converted (base, live) and checked, the 2 volume sets, then 1
            #expect(reported.count == 1 + 14 + 1 && reported == reported.sorted(), "\(reported)")
        }
    }
}
