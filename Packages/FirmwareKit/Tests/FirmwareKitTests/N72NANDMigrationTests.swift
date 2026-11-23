import Crypto
import Foundation
import HostRuntime
import Testing

@testable import FirmwareKit

/// The iPod touch 2G's image store (N72NANDImage) and its format 2 migration (K48NANDMigration's steps over
/// N72NANDImage's store) on a small format 1 device: a page directory holding a tiny HFS+ volume through the generated
/// layout and the odd pages a store can hold (short, empty, blank, all zero), under an overlay that supersedes pages,
/// adds one, marks a block erased and rewrites a page inside it, and holds a stray temporary file.
struct N72NANDMigrationTests {
    struct Killed: Error {}
    typealias Page = N72NAND.Page

    struct Device {
        let root: URL
        let id = UUID()
        var device: URL { root.appendingPathComponent("Devices/\(id.uuidString)") }
        var base: URL { device.appendingPathComponent("base") }
        var nand: URL { base.appendingPathComponent("nand") }
        var overlay: URL { device.appendingPathComponent("overlay") }
        var record: URL { device.appendingPathComponent(DeviceRecord.name) }
        var layout: K48NANDMigration.Layout { .init(device: device) }
        func owner() throws -> StoppedRecordOwner { try StoppedRecordOwner(device: device) }
        func format() throws -> Int { try DeviceRecord.object(Data(contentsOf: record))["format"] as? Int ?? 1 }
    }

    static let stride = N72NANDImage.stride
    /// The volume: 16 blocks, block 0 an HFS+ header, the others a pattern of their number.
    static func block(_ n: Int, _ salt: UInt8 = 0) -> [UInt8] {
        var b = [UInt8](repeating: UInt8(n) &+ salt &+ 1, count: N72NAND.page)
        if n == 0 {
            b[1024] = UInt8(ascii: "H")
            b[1025] = UInt8(ascii: "+")
            // 4096-byte blocks, 16 of them
            b.replaceSubrange(1024 + 40..<1024 + 48, with: [0, 0, 0x10, 0, 0, 0, 0, 16])
        }
        return b
    }
    static func record(_ data: [UInt8], spare: UInt8 = 0x5A) -> [UInt8] {
        data + [UInt8](repeating: spare, count: N72NAND.spare)
    }
    static let erasedBlock = 9  // on cs1, in the overlay
    static let odd: [Page: [UInt8]] = [
        Page(cs: 0, page: 5000): [UInt8](repeating: 0x33, count: 20),  // short: zero-filled
        Page(cs: 0, page: 5001): [],  // empty: all zero, spare too (not the blank page)
        Page(cs: 3, page: 5002): N72NANDImage.blankRecord,  // the blank page itself: a hole
        Page(cs: 2, page: 5003): [UInt8](repeating: 0, count: stride),
        Page(cs: 1, page: erasedBlock * 128 + 1): record([UInt8](repeating: 0x44, count: 4096)),  // under the mark
        Page(cs: 1, page: erasedBlock * 128 + 2): record([UInt8](repeating: 0x45, count: 4096))
    ]
    static let overlayPages: [Page: [UInt8]] = [
        N72NAND.predict(1): record(block(1, 0x80)),  // superseding
        N72NAND.predict(3): record(block(3, 0x80)),  // the base has none
        Page(cs: 1, page: erasedBlock * 128 + 2): record([UInt8](repeating: 0x46, count: 4096)),  // rewritten after
        Page(cs: 2, page: 4_000_000 / 8): [UInt8](repeating: 0x21, count: 100)  // short, overlay only
    ]

    func write(_ bytes: [UInt8], _ p: Page, in dir: URL) throws {
        let cs = dir.appendingPathComponent("cs\(p.cs)")
        try FileManager.default.createDirectory(at: cs, withIntermediateDirectories: true)
        try Data(bytes).write(to: cs.appendingPathComponent("\(p.page).page"))
    }

    func makeDevice(_ root: URL) throws -> Device {
        let d = Device(root: root)
        let fm = FileManager.default
        try fm.createDirectory(at: d.base, withIntermediateDirectories: true)
        for n in 0..<16 where n != 3 { try write(Self.record(Self.block(n)), N72NAND.predict(n), in: d.nand) }
        for (p, bytes) in Self.odd { try write(bytes, p, in: d.nand) }
        for (p, bytes) in Self.overlayPages { try write(bytes, p, in: d.overlay) }
        try Data().write(to: d.overlay.appendingPathComponent("cs1/blk\(Self.erasedBlock).erased"))
        try Data([1, 2, 3]).write(to: d.overlay.appendingPathComponent("cs1/.7.page.tmp"))
        try Data("key".utf8).write(to: d.overlay.appendingPathComponent(".base-identity"))
        try Data("nor".utf8).write(to: d.overlay.appendingPathComponent("nor.bin"))
        let record: [String: Any] = [
            "format": 1, "id": d.id.uuidString, "board": "n72ap", "firmware": "n72ap-test",
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
        let root = try Fixtures.tempDir("n72-migration")
        defer { try? K48NANDMigration.removeTree(root) }
        try await body(try makeDevice(root))
    }

    /// Every page a file of the device names, plus a few no file names, read through `read`.
    func pages(_ d: Device) -> [Page] {
        var all = Set(Self.odd.keys).union(Self.overlayPages.keys).union((0..<16).map(N72NAND.predict))
        for p in 0..<128 { all.insert(Page(cs: 1, page: Self.erasedBlock * 128 + p)) }
        all.formUnion([Page(cs: 0, page: 0), Page(cs: 3, page: N72NANDImage.pagesPerChip - 1)])
        return all.sorted { ($0.cs, $0.page) < ($1.cs, $1.page) }
    }

    func view(_ base: URL, _ overlay: URL?, _ pages: [Page]) throws -> [Page: [UInt8]] {
        let read = try N72NANDImage.reader(base: base, overlay: overlay)
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

    @Test func imageRecordsReadBackAsWrittenAndHolesReadBlank() throws {
        let dir = try Fixtures.tempDir("n72-image").appendingPathComponent("nand")
        let store = try N72NANDImage.create(dir)
        let zero = [UInt8](repeating: 0, count: Self.stride)
        try store.write(Page(cs: 2, page: 7), zero)
        try store.write(Page(cs: 3, page: N72NANDImage.pagesPerChip - 1), Self.record(Self.block(4)))
        try store.sync()
        #expect(N72NANDImage.isImage(dir) && PreparedDeviceBoot.isImageStore(dir))
        #expect(try VolumeRebuild.board(of: dir) == .ipod)
        let read = try PageNANDImage.Store(dir)
        #expect(try read.read(Page(cs: 2, page: 7)) == zero)  // all zero is not the blank page
        #expect(try read.read(Page(cs: 3, page: N72NANDImage.pagesPerChip - 1)) == Self.record(Self.block(4)))
        #expect(try read.read(Page(cs: 0, page: 7)) == N72NANDImage.blankRecord)
        // as stored: XOR the blank record, so the blank page is a hole (zero)
        let fd = open(dir.appendingPathComponent("cs2.pages").path, O_RDONLY)
        defer { close(fd) }
        var spare = [UInt8](repeating: 0, count: 12)
        pread(fd, &spare, 12, off_t(7 * Self.stride + 4096))
        #expect(spare == [0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0, 0xFF, 0])
        #expect(try Data(contentsOf: dir.appendingPathComponent("geometry.json")).count > 0)
    }

    @Test func migratesPageExactAndKeepsTheFormat1StoreUntilACleanStop() async throws {
        try await withDevice { d in
            let pages = pages(d)
            let guest = try view(d.nand, d.overlay, pages)
            let base = try view(d.nand, nil, pages)
            let before = try volume(d.nand, d.overlay, d.root.appendingPathComponent("v0"))
            // the fixture reads as the FMSS did: the mark blanks its block but for the page rewritten after it
            #expect(guest[Page(cs: 1, page: Self.erasedBlock * 128 + 1)] == N72NANDImage.blankRecord)
            #expect(
                guest[Page(cs: 0, page: 5000)] == [UInt8](repeating: 0x33, count: 20)
                    + [UInt8](repeating: 0, count: 4140)
            )
            #expect(guest[Page(cs: 0, page: 5001)] == [UInt8](repeating: 0, count: Self.stride))

            #expect(try FirmwareBootAdmission.migrate(d.owner()))  // the n72's admission: the GPT step, then this
            #expect(try d.format() == 2 && N72NANDImage.isImage(d.nand))
            let live = PreparedDeviceBoot.liveNAND(overlay: d.overlay)
            #expect(N72NANDImage.isImage(live))
            #expect(try view(d.nand, d.overlay, pages) == guest)
            #expect(try view(d.nand, nil, pages) == base)
            #expect(try volume(d.nand, d.overlay, d.root.appendingPathComponent("v1")) == before)
            #expect(flags(d.base) & UInt32(UF_IMMUTABLE) != 0 && flags(d.nand) & UInt32(UF_IMMUTABLE) != 0)
            #expect(access(d.nand.appendingPathComponent("cs0.pages").path, W_OK) != 0)
            let left = try FileManager.default.contentsOfDirectory(atPath: d.overlay.path).sorted()
            #expect(left == [".base-identity", "nand", "nor.bin"], "\(left)")
            let kept = try FileManager.default.contentsOfDirectory(
                atPath: d.layout.legacy.appendingPathComponent("overlay").path
            )
            #expect(kept.sorted() == ["cs0", "cs1", "cs2"])
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
                    let p = inBase ? Page(cs: 0, page: 5001) : N72NAND.predict(3)
                    let dir = inBase ? "base-nand" : "nand"
                    let fd = open(d.layout.migrating.appendingPathComponent("\(dir)/cs\(p.cs).pages").path, O_RDWR)
                    defer { close(fd) }
                    var byte: UInt8 = 0
                    pread(fd, &byte, 1, off_t(p.page * Self.stride + 100))
                    byte ^= 0x40
                    pwrite(fd, &byte, 1, off_t(p.page * Self.stride + 100))
                }
            )
            #expect(!changed)
            #expect(try Data(contentsOf: d.record) == record)
            #expect(try view(d.nand, d.overlay, pages) == guest)
            #expect(!N72NANDImage.isImage(d.nand))
            for dir in [d.layout.migrating, d.layout.legacy, d.layout.intent] {
                #expect(!FileManager.default.fileExists(atPath: dir.path))
            }
        }
    }

    /// A run killed at each step: rolled back before the record swap (format 1; the next start migrates), finished
    /// after it (format 2).
    @Test func aRunKilledAtEachStepRecovers() async throws {
        var steps: [K48NANDMigration.Checkpoint] = [.built, .verified]
        steps += (0..<6).map { .renamed($0) }  // base/nand, the overlay's cs0, cs1, cs2, the base, the live
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
                    #expect(try d.format() == 2 && N72NANDImage.isImage(d.nand), "\(step)")
                } else {
                    #expect(try Data(contentsOf: d.record) == record, "\(step)")
                    #expect(!N72NANDImage.isImage(d.nand), "\(step)")
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
            // 0, a step for each of the 4 chip selects converted (base, live) and checked, the 2 volume sets, then 1
            #expect(reported.count == 1 + 14 + 1 && reported == reported.sorted(), "\(reported)")
        }
    }
}
