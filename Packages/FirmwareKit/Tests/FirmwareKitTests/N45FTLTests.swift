import Foundation
import HostRuntime
import Testing

@testable import FirmwareKit

@Suite(.detachesItsImages) struct N45FTLTests {
    static let banks = 4  // the M68's; the N45's 8 take the same paths
    static let sb = N45NAND.superblock(banks), pp = N45NAND.page

    /// A prepared store (N45NAND.write) of a small HFSX-headed volume, and the volume.
    static func prepared(_ dir: URL) throws -> (base: URL, volume: [UInt8]) {
        let fsPages = 3 * sb - 3 - 50
        var vol = [UInt8](repeating: 0, count: fsPages * pp)
        vol[1024] = UInt8(ascii: "H")
        vol[1025] = UInt8(ascii: "X")
        let blocks = UInt32(fsPages * pp / 4096)
        for (o, v) in [(1024 + 40, UInt32(4096)), (1024 + 44, blocks)] {
            for k in 0..<4 { vol[o + k] = UInt8(v >> (24 - 8 * k) & 0xFF) }
        }
        for p in 1..<fsPages {
            vol[p * pp] = UInt8(p % 251)
            vol[p * pp + 1] = 0x5A
        }
        let image = dir.appendingPathComponent("volume.img")
        let base = dir.appendingPathComponent("nand")
        try Data(vol).write(to: image)
        try N45NAND.write(volume: image, out: base, filID: 0x4330_3030, banks: banks)
        return (base, Array(vol[0..<Int(blocks) * 4096]))
    }

    static func le(_ b: inout [UInt8], _ o: Int, _ v: Int, _ n: Int) {
        for k in 0..<n { b[o + k] = UInt8(v >> (8 * k) & 0xFF) }
    }

    /// What a booted guest leaves in the device's live NAND (the overlay's clone of the base's image), built by hand:
    /// the context moved to virtual block 3 (lower usnDec
    /// than the prepared one), logical block 0 remapped to virtual block 30 with page 10 changed, and a log block
    /// (virtual block 31) holding a newer copy of logical block 1's page 5. `clean: false` ends the context block
    /// on a map page instead of the context.
    static func booted(_ ovl: URL, _ base: URL, clean: Bool = true, changeData: Bool = true) throws {
        try FileManager.default.createDirectory(at: ovl, withIntermediateDirectories: true)
        let live = try PageNANDImage.Store(PreparedDeviceBoot.liveNAND(base: base, overlay: ovl), writable: true)
        func put(_: URL, vpn: Int, _ data: [UInt8], _ spare: [UInt8]) throws {
            try live.write(N45NAND.location(vpn: vpn, banks: banks), data + spare)
        }
        let read = try N45FTL.reader(PageNANDImage.s5l8900(at: base), base: base, overlay: nil)
        let ctxVB = 3
        let start = ctxVB * sb
        try put(
            ovl,
            vpn: start,
            [UInt8](repeating: 0, count: pp),
            N45NAND.cxtSpare(type: 0x43, index: 0, age: 0xFFFF_FFF0)
        )
        for i in 0..<N45NAND.mapTables {  // the map, lbn 0 -> vbn 30
            var page = [UInt8](repeating: 0xFF, count: pp)
            for j in 0..<pp / 2 {
                let lbn = i * pp / 2 + j
                if lbn < N45NAND.mappedLBNs { le(&page, 2 * j, lbn == 0 ? 30 : lbn + N45NAND.dataStart, 2) }
            }
            try put(ovl, vpn: start + 1 + i, page, N45NAND.cxtSpare(type: 0x46, index: i, age: 0xFFFF_FFF0))
        }
        let offsetPages = (N45FTL.logs * sb * 2 + pp - 1) / pp
        var offsets = [UInt8](repeating: 0xFF, count: offsetPages * pp)
        le(&offsets, 2 * 5, 2, 2)  // slot 0, offset 5 -> page 2 of its log block
        for i in 0..<offsetPages {
            try put(
                ovl,
                vpn: start + 5 + i,
                Array(offsets[i * pp..<(i + 1) * pp]),
                N45NAND.cxtSpare(type: 0x44, index: i, age: 0xFFFF_FFF0)
            )
        }
        var cxt = N45NAND.ftlMeta(banks: banks)
        for i in 0..<N45NAND.mapTables { le(&cxt, 0x38 + 4 * i, start + 1 + i, 4) }
        for i in 0..<offsetPages { le(&cxt, 0x110 + 4 * i, start + 5 + i, 4) }
        le(&cxt, 0x1A4 + 4, 31, 2)
        le(&cxt, 0x1A4 + 6, 1, 2)
        for i in 0..<3 { le(&cxt, 0x312 + 2 * i, ctxVB + i, 2) }
        let last = start + 5 + offsetPages
        if clean {
            try put(ovl, vpn: last, cxt, N45NAND.cxtSpare(type: 0x43, index: 0, age: 0xFFFF_FFF0))
        } else {
            try put(
                ovl,
                vpn: last,
                [UInt8](repeating: 0, count: pp),
                N45NAND.cxtSpare(type: 0x46, index: 0, age: 0xFFFF_FFF0)
            )
        }
        // logical block 0 copied to virtual block 30 with page 10 changed; the log page for lbn 1 offset 5
        for off in 0..<sb {
            guard let (d, s) = read(N45NAND.location(lpn: off, banks: banks)) else { continue }
            try put(ovl, vpn: 30 * sb + off, off == 10 && changeData ? [UInt8](repeating: 0xA1, count: pp) : d, s)
        }
        let log =
            changeData
            ? [UInt8](repeating: 0xB2, count: pp)
            : read(N45NAND.location(lpn: sb + 5, banks: banks))!.data
        try put(ovl, vpn: 31 * sb + 2, log, N45NAND.dataSpare(sb + 5))
    }

    /// The same device in format 1: the base image as bank<N> page files, and the live clone's records that differ
    /// from the base as page files in the overlay (the live clone removed). booted() erases no block, so no markers.
    static func asFormat1(_ nand: URL, overlay: URL) throws {
        let fm = FileManager.default
        let image = try PageNANDImage.s5l8900(at: nand)
        let base = try PageNANDImage.Store(nand)
        let liveURL = PreparedDeviceBoot.liveNAND(overlay: overlay)
        let live = fm.fileExists(atPath: liveURL.path) ? try PageNANDImage.Store(liveURL) : nil
        let pages = nand.deletingLastPathComponent().appendingPathComponent("nand-pages")
        func put(_ record: [UInt8], _ root: URL, _ chip: Int, _ page: Int) throws {
            let dir = root.appendingPathComponent("bank\(chip)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(record).write(to: dir.appendingPathComponent("\(page).page"))
        }
        for chip in 0..<image.chips {
            try fm.createDirectory(at: pages.appendingPathComponent("bank\(chip)"), withIntermediateDirectories: true)
            var blocks = base.dataBlocks(chip)
            if let live { blocks.formUnion(live.dataBlocks(chip)) }
            for page in blocks.flatMap({ $0 * N45NAND.pagesPerBlock..<($0 + 1) * N45NAND.pagesPerBlock }) {
                let b = try base.read(chip, page)
                if b != image.blankRecord { try put(b, pages, chip, page) }
                if let l = try live?.read(chip, page), l != b { try put(l, overlay, chip, page) }
            }
        }
        try fm.removeItem(at: nand)
        try fm.moveItem(at: pages, to: nand)
        if live != nil { try fm.removeItem(at: liveURL) }
    }

    /// A fresh store reads back as its volume, through the prepared context.
    @Test func preparedStore() throws {
        let dir = try Fixtures.tempDir("n45ftl-prepared")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (base, vol) = try Self.prepared(dir)
        #expect(try VolumeRebuild.board(of: base) == .legacy)
        let ftl = try N45FTL(base: base, overlay: nil)
        #expect(ftl.banks == Self.banks && ftl.logBlocksInUse == 0)
        let v = try VolumeRebuild.rebuild(base: base, overlay: nil, into: dir.appendingPathComponent("out"))
        #expect(v.map(\.name) == ["system"] && v[0].bytes == vol.count)
        #expect([UInt8](try Data(contentsOf: v[0].image)) == vol)
    }

    /// A booted overlay: the moved context, the remapped block and the log page win; the rest is the base's.
    @Test func bootedOverlay() throws {
        let dir = try Fixtures.tempDir("n45ftl-booted")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (base, vol) = try Self.prepared(dir)
        let ovl = dir.appendingPathComponent("overlay")
        try Self.booted(ovl, base)
        let ftl = try N45FTL(base: base, overlay: ovl)
        #expect(ftl.logBlocksInUse == 1)
        #expect(ftl.location(lpn: 10) == N45NAND.location(vpn: 30 * Self.sb + 10, banks: Self.banks))
        #expect(ftl.location(lpn: Self.sb + 5) == N45NAND.location(vpn: 31 * Self.sb + 2, banks: Self.banks))
        #expect(ftl.location(lpn: Self.sb + 6) == N45NAND.location(lpn: Self.sb + 6, banks: Self.banks))
        let img = [UInt8](
            try Data(
                contentsOf: VolumeRebuild.rebuild(base: base, overlay: ovl, into: dir.appendingPathComponent("out"))[0]
                    .image
            )
        )
        let first = N45NAND.firstLBA
        let pp = Self.pp
        func page(_ lpn: Int) -> ArraySlice<UInt8> { img[(lpn - first) * pp..<(lpn - first + 1) * pp] }
        func want(_ lpn: Int) -> ArraySlice<UInt8> { vol[(lpn - first) * pp..<(lpn - first + 1) * pp] }
        #expect(page(10).allSatisfy { $0 == 0xA1 } && page(Self.sb + 5).allSatisfy { $0 == 0xB2 })
        #expect(
            page(11) == want(11) && page(Self.sb + 6) == want(Self.sb + 6)
                && page(2 * Self.sb + 1) == want(2 * Self.sb + 1)
        )
    }

    /// The context block not ending in the context (an unclean stop) is refused, not guessed at.
    @Test func uncleanRefused() throws {
        let dir = try Fixtures.tempDir("n45ftl-unclean")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (base, _) = try Self.prepared(dir)
        let ovl = dir.appendingPathComponent("overlay")
        try Self.booted(ovl, base, clean: false)
        #expect(throws: FirmwareError.self) { try N45FTL(base: base, overlay: ovl) }
    }

    /// A stopped edit of a booted 1.x device: begin, an edit through the real HFS driver, commit. The generation's
    /// overlay (the guest's, cloned) carries the change at the FTL's own locations, new files take their
    /// ancestors' owners, the journal is left for the device to initialize, and the original storage is intact.
    @Test func stoppedEditInPlace() async throws {
        let fm = FileManager.default
        let root = try Fixtures.tempDir("n45ftl-edit")
        defer { try? fm.removeItem(at: root) }
        let device = root.appendingPathComponent("device")
        let base = device.appendingPathComponent("base")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("volume.img")
        try Fixtures.makeVolume(image, size: 16 << 20, name: "Legacy edit test") { v in
            try v.makeDirectory("Applications")
            try v.put(Data("stock".utf8), at: "Applications/Stock")
        }
        try HFSPlusVolume(image, writable: true).setOwner(
            ["Applications", "Applications/Stock"],
            uid: 0,
            gid: 80,
            mode: 0o775
        )
        try N45NAND.write(
            volume: image,
            out: base.appendingPathComponent("nand"),
            filID: 0x4330_3030,
            banks: Self.banks
        )
        let overlay = device.appendingPathComponent("overlay")
        try Self.booted(overlay, base.appendingPathComponent("nand"), changeData: false)
        try Data("{}".utf8).write(to: base.appendingPathComponent("device.lock.json"))
        let record: [String: Any] = [
            "id": UUID().uuidString, "board": "m68ap", "firmware": "test",
            "base": ["kind": "prepared", "path": base.path],
            "storage": ["key": "old", "overlay": overlay.path, "snapshot": "old-snapshot"]
        ]
        try DeviceRecord.data(record).write(to: device.appendingPathComponent(DeviceRecord.name))
        let before = try Self.tree(overlay)

        let session = try await StoppedVolumeEdit.begin(device: device)
        try await VolumeMount.withMounted(session.image, at: root.appendingPathComponent("edit")) { mount in
            let app = mount.appendingPathComponent("Applications/Hello.app")
            try fm.createDirectory(at: app, withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: app.appendingPathComponent("Hello"))
        }
        try await StoppedVolumeEdit.commit(device: device, id: session.id)

        let published = try DeviceRecord.object(Data(contentsOf: device.appendingPathComponent(DeviceRecord.name)))
        let newBase = URL(fileURLWithPath: try #require((published["base"] as? [String: Any])?["path"] as? String))
        let newOverlay = URL(
            fileURLWithPath: try #require((published["storage"] as? [String: Any])?["overlay"] as? String)
        )
        #expect(newOverlay != overlay && newBase != base)
        let ftl = try N45FTL(base: newBase.appendingPathComponent("nand"), overlay: newOverlay)
        #expect(ftl.logBlocksInUse == 1)  // the guest's FTL state carried over unchanged
        let rebuilt = try VolumeRebuild.rebuild(
            base: newBase.appendingPathComponent("nand"),
            overlay: newOverlay,
            into: root.appendingPathComponent("verify")
        )[0]
        let volume = try HFSPlusVolume(rebuilt.image)
        let hello = try volume.record(at: "Applications/Hello.app/Hello")
        #expect(try volume.contents(hello) == Data("hello".utf8) && hello.uid == 0 && hello.gid == 80)
        #expect(try volume.contents(volume.record(at: "Applications/Stock")) == Data("stock".utf8))
        #expect(try Self.tree(overlay) == before)  // the original generation is untouched
    }

    static func tree(_ dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for case let u as URL in FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
        where !u.hasDirectoryPath {
            out[u.path] = try Data(contentsOf: u)
        }
        return out
    }
}
