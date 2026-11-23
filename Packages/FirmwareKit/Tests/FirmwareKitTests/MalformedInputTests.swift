import Foundation
import HostRuntime
import Testing

@testable import FirmwareKit

/// Firmware and guest structures that are cut short, claim lengths and offsets past their data, or nest and loop
/// past any real one: each reader refuses them with an error rather than trapping, reading another structure's bytes
/// or running away.
struct MalformedInputTests {
    // MARK: DeviceTree

    /// A device tree of `depth` nodes, each the only child of the one before.
    static func nestedDeviceTree(depth: Int) -> Data {
        var d = Data()
        for level in 0..<depth {
            d += KBootTests.node([("name", Data("n\0".utf8))]).prefix(4)
            d += DeviceTree.Value.le([level == depth - 1 ? 0 : 1])
            d += KBootTests.prop("name", Data("n\0".utf8))
        }
        return d
    }

    /// iBoot's trees are a few levels deep; one nested past any real one is refused, not walked off the stack.
    @Test func aDeviceTreeNestedPastAnyRealOneIsRefused() throws {
        #expect(try DeviceTree(Self.nestedDeviceTree(depth: 8)).contains("n/n/n/n/n/n/n"))
        #expect(throws: FirmwareError.self) { try DeviceTree(Self.nestedDeviceTree(depth: 200_000)) }
    }

    /// A property whose length runs past the tree, a node claiming more children than follow, and a last property
    /// whose padding is missing.
    @Test func aDeviceTreeCutShortIsRefused() {
        let blob = KBootTests.dtBlob
        var long = blob
        long.replaceSubrange(8 + 32..<8 + 36, with: DeviceTree.Value.le([UInt32(blob.count)]))  // "name"'s length
        var children = blob
        children.replaceSubrange(4..<8, with: DeviceTree.Value.le([99]))
        let unpadded = KBootTests.node([("name", Data("x\0".utf8))]).dropLast(2)
        for bad in [long, children, unpadded, blob.prefix(7), Data()] {
            #expect(throws: FirmwareError.self) { try DeviceTree(bad) }
        }
    }

    // MARK: Disk images

    /// An Apple partition map whose block size (16) is smaller than an entry's fields: the type was read 80 bytes
    /// into an entry only checked for 16.
    @Test func anApplePartitionMapWithTinyBlocksIsRefused() {
        var map = [UInt8](repeating: 0, count: 40)
        map.replaceSubrange(0..<4, with: [0x45, 0x52, 0, 16])
        map.replaceSubrange(16..<24, with: [0x50, 0x4D, 0, 0, 0, 0, 0, 1])
        #expect(throws: FirmwareError.self) { try APM.hfsSlice(Data(map)) }
    }

    /// An encrcdsa header whose data offset has its top bit set: converting it to an Int trapped.
    @Test func anEncryptedImageOffsetPastAnIntIsRefused() throws {
        let dir = try Fixtures.tempDir("malformed-encrcdsa")
        defer { TemporaryTrees.remove(dir) }
        var header = [UInt8](repeating: 0, count: 0x100)
        header.replaceSubrange(0..<8, with: Array("encrcdsa".utf8))
        header.replaceSubrange(52..<56, with: [0, 0, 0x10, 0])  // 4 KiB chunks
        header.replaceSubrange(56..<72, with: [0, 0, 0, 0, 0, 0, 0x10, 0] + [0x80, 0, 0, 0, 0, 0, 0, 0])
        let image = dir.appendingPathComponent("image")
        try Data(header).write(to: image)
        #expect(throws: FirmwareError.self) {
            try VFDecrypt.decrypt(input: image, output: dir.appendingPathComponent("out"), key: Data(count: 36))
        }
    }

    // MARK: dyld shared cache

    /// A dyld_v1 cache of one image, /usr/lib/libtest.dylib, mapped at 0x30000000: its Mach-O at 0x100 holds
    /// `commands` (by default an LC_SEGMENT with a 12-byte __cstring at 0x400 and an LC_SYMTAB of
    /// _MISValidateSignature, a Thumb function at 0x410, and _x).
    static func sharedCache(ncmds: UInt32 = 2, commands: [UInt8]? = nil) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 0x1000)
        func at(_ o: Int, _ bytes: [UInt8]) { c.replaceSubrange(o..<o + bytes.count, with: bytes) }
        func w(_ v: [UInt32]) -> [UInt8] { [UInt8](le(v)) }
        at(0, Array("dyld_v1   armv7\0".utf8))
        at(0x10, w([0x40, 1, 0x60, 1]))
        at(0x40, w([0x3000_0000, 0, 0x1000, 0, 0, 0, 5, 5]))
        at(0x60, w([0x3000_0100, 0, 0, 0, 0, 0, 0x80, 0]))
        at(0x80, Array("/usr/lib/libtest.dylib\0".utf8))
        let segment =
            w([1, 56 + 68]) + Array("__TEXT".utf8) + [UInt8](repeating: 0, count: 10)
            + w([0x3000_0000, 0x1000, 0, 0x1000, 5, 5, 1, 0]) + Array("__cstring".utf8)
            + [UInt8](repeating: 0, count: 7) + Array("__TEXT".utf8) + [UInt8](repeating: 0, count: 10)
            + w([0x3000_0400, 12, 0x400, 0, 0, 0, 0, 0, 0])
        let cmds = commands ?? segment + w([2, 24, 0x500, 2, 0x600, 0x40])
        at(0x100, w([0xFEED_FACE, 12, 9, 6, ncmds, UInt32(cmds.count), 0]) + cmds)
        at(0x400, Array("hello\0world\0".utf8) + [0, 0, 0, 0, 0x80, 0xB5, 0x00, 0xAF])
        at(0x500, w([1, 0x0008_010F, 0x3000_0410, 23, 0x01, 0]))  // nlists: strx, type/sect/desc, value
        at(0x600, Array("\0_MISValidateSignature\0_x\0".utf8))
        return c
    }

    /// An image whose load command claims no size: the walk visited the same command once per ncmds (50 million
    /// times here) and took the image as read.
    @Test func aCacheImagesZeroSizedLoadCommandIsRefused() throws {
        let clean = try DyldSharedCache(data: Data(Self.sharedCache()))
        let img = try #require(clean.image("/usr/lib/libtest.dylib"))
        #expect(try clean.cStrings(in: img, section: "__cstring") == ["hello", "world"])
        #expect(try clean.symbolNames(in: img) == ["_MISValidateSignature", "_x"])
        #expect(try AppSyncCachePatch.locate(clean).offset == 0x410)
        let looping = try DyldSharedCache(
            data: Data(Self.sharedCache(ncmds: 50_000_000, commands: [1, 0, 0, 0, 0, 0, 0, 0])))
        let image = try #require(looping.image("/usr/lib/libtest.dylib"))
        #expect(throws: FirmwareError.self) { try looping.cStrings(in: image, section: "__cstring") }
    }

    // MARK: Mach-O (kernelcaches)

    static let le = DeviceTree.Value.le

    /// A 32-bit ARM Mach-O header for `cmds`, the commands' bytes after it, then `tail`.
    static func machO(ncmds: UInt32, _ cmds: Data, tail: Data = Data()) -> Data {
        le([0xFEED_FACE, 12, 9, 2, ncmds, UInt32(cmds.count), 0]) + cmds + tail
    }

    /// The keybag one-shot's read of the kernelcache's entry, the sandbox patch's and kboot's, over a kernel whose
    /// one command is missing and one whose LC_SEGMENT is only its 8-byte cmd/cmdsize: the first two read the
    /// segment's fields past the end of the file.
    @Test func aKernelcacheCutShortIsRefused() {
        for kernel in [Self.machO(ncmds: 1, Data()), Self.machO(ncmds: 1, Self.le([1, 8]))] {
            #expect(throws: FirmwareError.self) { try N72Keybag.kernelEntry(kernel) }
            #expect(throws: SandboxPatch.Error.self) { try SandboxPatch.locate([UInt8](kernel)) }
            #expect(throws: FirmwareError.self) { try MachO(kernel) }
        }
    }

    /// A segment whose fileoff and filesize add up past 4 GiB: the boot_args version check added them as UInt32s.
    @Test func aSegmentPast4GiBIsNotAnOverflow() throws {
        let seg =
            Self.le([1, 56]) + DeviceTree.name32("__TEXT").prefix(16)
            + Self.le([0x8000_0000, 0x1000, 0x10, 0xFFFF_FFF8, 7, 7, 0, 0])
        let kernel = Self.machO(ncmds: 1, seg, tail: Data("pe_identify_machine: Epoch Mismatch\0".utf8))
        #expect(try MachO(kernel).bootArgsVersion() == 2)
    }

    /// A kernelcache whose segment claims 3.75 GiB: kboot laid out (and zero-filled) an image that size.
    @Test func aKernelcacheLargerThanMemoryIsRefused() {
        var kernel = KBootTests.kernel(at: 0x8000_0000)
        kernel.replaceSubrange(28 + 56 + 28..<28 + 56 + 32, with: Self.le([0xF000_0000]))  // __DATA's vmsize
        #expect(throws: FirmwareError.self) {
            try KBoot.build(kernel: kernel, deviceTree: KBootTests.dtBlob, identity: KBootTests.placeholder)
        }
    }

    /// boot_args read out of guest memory by the keybag one-shot: a topOfKernelData at the top of the address space
    /// and a device tree pointer below the kernel's base are refused, not wrapped.
    @Test func bootArgsThatWouldWrapAreRefused() throws {
        func args(top: UInt32, dtp: UInt32) -> Data {
            var a = Data(count: 0x138)
            a.replaceSubrange(0..<2, with: [1, 0])
            a.replaceSubrange(4..<20, with: Self.le([0x8000_0000, N72Keybag.physBase, 0x0800_0000, top]))
            a.replaceSubrange(0x30..<0x38, with: Self.le([dtp, 0x1000]))
            return a
        }
        let ok = try N72Keybag.ramdiskPlace(
            bootArgs: args(top: 0x0900_0000, dtp: 0x8100_0000), at: 0, base: 0x8000_0000, ramdisk: 0x1000)
        #expect(ok.rdPA == 0x0900_0000 && ok.newTop == 0x0900_4000 && ok.dtPA == 0x0900_0000)
        for bad in [args(top: 0xFFFF_F800, dtp: 0x8100_0000), args(top: 0x0900_0000, dtp: 0x10)] {
            #expect(throws: FirmwareError.self) {
                try N72Keybag.ramdiskPlace(bootArgs: bad, at: 0, base: 0x8000_0000, ramdisk: 0x1000)
            }
        }
        #expect(throws: FirmwareError.self) {
            try N72Keybag.ramdiskPlace(bootArgs: Data(count: 0x20), at: 0, base: 0x8000_0000, ramdisk: 0x1000)
        }
    }

    // MARK: IMG3

    static func word(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }

    /// An img3 of `tags` (magic as stored, total, data length, data), its fullSize `full` (default: what they take).
    static func img3(_ tags: [(String, Int, Int, [UInt8])], full: Int? = nil) -> [UInt8] {
        let body = tags.flatMap { Array($0.0.utf8) + word($0.1) + word($0.2) + $0.3 }
        return Array("3gmI".utf8) + word(full ?? 0x14 + body.count) + word(body.count) + word(0) + word(0) + body
    }

    /// A DATA tag whose data length runs past its own total into the next tag: the payload was the DATA bytes and
    /// the KBAG's header after them.
    @Test func anImg3TagWhoseDataRunsIntoTheNextIsRefused() {
        let bad = Self.img3([
            ("ATAD", 28, 32, [UInt8](repeating: 0xDA, count: 16)), ("GABK", 20, 8, [1, 0, 0, 0, 0, 1, 0, 0])
        ])
        #expect(throws: FirmwareError.self) { try IMG3.payload(Data(bad)) }
        #expect(throws: FirmwareError.self) { try IMG3.tags(Data(bad)) }
    }

    /// An img3 cut short (its fullSize past the file) or whose tag claims more than is left.
    @Test func anImg3CutShortIsRefused() {
        let data = [UInt8](repeating: 0xDA, count: 16)
        let cut = Self.img3([("ATAD", 28, 16, data)], full: 0x1000)
        let long = Self.img3([("ATAD", 28, 16, data), ("GABK", 0x1000, 8, [1, 0, 0, 0, 0, 1, 0, 0])])
        for bad in [cut, long] {
            #expect(throws: FirmwareError.self) { try IMG3.tags(Data(bad)) }
            #expect(throws: FirmwareError.self) { try SandboxPatch.rebuildIMG3(Data(bad), data: [1, 2, 3]) }
        }
    }

    /// The K48 iBoot path's DeviceTree img3 with its production KBAG cut short: the KBAG's IV and key were read past
    /// the end of the file.
    @Test func aDeviceTreeImg3WithItsKBAGCutShortIsRefused() {
        let bag = [1, 0, 0, 0, 0, 1, 0, 0] + [UInt8](repeating: 7, count: 8)
        let image = Self.img3([("GABK", 68, 56, bag)], full: 0x14 + 28)
        #expect(throws: FirmwareError.self) {
            try K48IBoot.hostUSBDeviceTree(
                img3: Data(image),
                plaintext: KBootTests.dtBlob,
                gidBlobs: Data(repeating: 7, count: 96)
            )
        }
    }

    // MARK: NAND (what the guest left)

    /// A prepared 1.x store whose volume header, rewritten in its live NAND as a guest would, claims `blocks` blocks of
    /// `blockSize` bytes.
    static func legacyDevice(claiming blockSize: UInt32, _ blocks: UInt32, in dir: URL) throws -> (URL, URL) {
        let (base, _) = try N45FTLTests.prepared(dir)
        let overlay = dir.appendingPathComponent("overlay")
        try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
        let live = try PageNANDImage.Store(PreparedDeviceBoot.liveNAND(base: base, overlay: overlay), writable: true)
        let at = N45NAND.location(lpn: N45NAND.firstLBA, banks: N45FTLTests.banks)
        var record = try live.read(at.bank, at.page)
        for (o, v) in [(1024 + 40, blockSize), (1024 + 44, blocks)] {
            for k in 0..<4 { record[o + k] = UInt8(v >> (24 - 8 * k) & 0xFF) }
        }
        try live.write(at.bank, at.page, record)
        return (base, overlay)
    }

    /// The guest's HFS+ header sizes the 1.x volume export: 4 GiB, past what the FTL's map covers, read logical
    /// blocks past the map (Index out of range); 0xFFFFFFFF blocks of 0xFFFFFFFF bytes overflowed the product.
    @Test(arguments: [(UInt32(4096), UInt32(0x10_0000)), (0xFFFF_FFFF, 0xFFFF_FFFF)])
    func aLegacyVolumeHeaderClaimingMoreThanTheFTLMapsIsRefused(_ size: UInt32, _ blocks: UInt32) throws {
        let dir = try Fixtures.tempDir("malformed-n45-header")
        defer { TemporaryTrees.remove(dir) }
        let (base, overlay) = try Self.legacyDevice(claiming: size, blocks, in: dir)
        #expect(throws: FirmwareError.self) {
            try VolumeRebuild.rebuild(base: base, overlay: overlay, into: dir.appendingPathComponent("out"))
        }
    }

    /// A log block in use whose page offset (the guest's) points past the block: the page was read from the next
    /// block instead.
    @Test func aLegacyLogOffsetPastItsBlockIsRefused() throws {
        let dir = try Fixtures.tempDir("malformed-n45-log")
        defer { TemporaryTrees.remove(dir) }
        let (base, _) = try N45FTLTests.prepared(dir)
        let overlay = dir.appendingPathComponent("overlay")
        try N45FTLTests.booted(overlay, base)
        let sb = N45FTLTests.sb
        var offsets = [UInt8](repeating: 0xFF, count: N45NAND.page)
        N45FTLTests.le(&offsets, 2 * 5, sb + 2, 2)  // slot 0's page 5 at page sb + 2 of a block of sb
        let live = try PageNANDImage.Store(PreparedDeviceBoot.liveNAND(base: base, overlay: overlay), writable: true)
        let at = N45NAND.location(vpn: 3 * sb + 5, banks: N45FTLTests.banks)  // booted()'s first log-offset page
        try live.write(at.bank, at.page, offsets + N45NAND.cxtSpare(type: 0x44, index: 0, age: 0xFFFF_FFF0))
        #expect(throws: FirmwareError.self) { try N45FTL(base: base, overlay: overlay) }
    }

    /// An iPad store whose guest-written MBR places the system partition past the pages the FTL exports: the export
    /// wrote a volume of that size.
    @Test func aGuestMBRPlacingAPartitionPastTheExportIsRefused() async throws {
        let dir = try Fixtures.tempDir("malformed-k48-mbr")
        defer { TemporaryTrees.remove(dir) }
        let geo = K48NAND.Geometry.selfcheck
        let ps = geo.pageSize
        func mbr(_ count: Int) -> [UInt8] {
            var m = [UInt8](repeating: 0, count: ps)
            m[510] = 0x55
            m[511] = 0xAA
            m[0x1be + 4] = 0xAF
            put32(&m, 0x1be + 8, 63)
            put32(&m, 0x1be + 12, UInt32(count))
            return m
        }
        let paths = ["mbr", "system.img"].map { dir.appendingPathComponent($0) }
        try Data(mbr(64) + [UInt8](repeating: 0, count: ps * 62)).write(to: paths[0])
        try Data([UInt8](repeating: 0x5A, count: ps * 64)).write(to: paths[1])
        let base = dir.appendingPathComponent("base")
        try await K48NAND.build(
            geometry: geo,
            mbr: paths[0],
            kernelVersion: Array("Darwin Kernel Version selfcheck".utf8),
            system: paths[1],
            data: .none,
            out: base
        )
        let overlay = dir.appendingPathComponent("overlay")
        let st = try K48NAND.Store(create: overlay, geo: geo)
        let (cs, pp) = geo.vpnToPhys((geo.numBlocks - 2) * geo.ppsublk)
        try st.write(cs, pp, mbr(geo.exportedPages), K48NAND.spare(0, 1000, K48NAND.tUser))
        st.close()
        for c in 0..<geo.numCS {
            var dirty = [UInt8](repeating: 0, count: geo.pagesPerCE / 8)
            if c == cs { dirty[pp / 8] |= 1 << (pp % 8) }
            let (b, e) = geo.busCE(c)
            try Data(dirty).write(to: overlay.appendingPathComponent("bus\(b)-ce\(e).dirty"))
        }
        #expect(throws: FirmwareError.self) {
            try VolumeRebuild.rebuild(base: base, overlay: overlay, into: dir.appendingPathComponent("out"))
        }
    }

    /// An MBR shorter than its table and a DEVICEINFOBBT page whose table length runs past the page.
    @Test func aShortMBRAndALongBadBlockTableAreRefused() {
        #expect(throws: FirmwareError.self) { try K48NAND.partitions(mbr: [UInt8](repeating: 0, count: 0x1C0)) }
        var bbt = [UInt8](repeating: 0, count: 4096)
        bbt.replaceSubrange(0..<13, with: Array("DEVICEINFOBBT".utf8))
        put32(&bbt, 0x34, 0x2000)
        #expect(K48NAND.deviceInfoBBT(bbt) == nil)
        put32(&bbt, 0x34, 16)
        #expect(K48NAND.deviceInfoBBT(bbt)?.bbt.count == 16)
    }
}
