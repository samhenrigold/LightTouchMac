import Foundation
import Testing

@testable import FirmwareKit

struct K48NANDTests {
    /// 7.x's launchd starts it_seal minutes into the boot: its one-shots get 900 s, earlier releases 300 s.
    @Test func oneshotTimeoutByVersion() {
        #expect(K48Board.oneshotTimeout(productVersion: "7.1.2") == 900)
        #expect(K48Board.oneshotTimeout(productVersion: "7.0") == 900)
        #expect(K48Board.oneshotTimeout(productVersion: "6.1.3") == 300)
        #expect(K48Board.oneshotTimeout(productVersion: "3.2.2") == 300)
    }

    /// Only a jailbroken device boots with AMFI out of the way (Substrate's library in amfid).
    @Test func amfiOutOfTheWayOnlyJailbroken() {
        #expect(K48Board.bootArgs(jailbreak: false) == KBoot.defaultBootArgs)
        #expect(K48Board.bootArgs(jailbreak: true) == KBoot.defaultBootArgs + " amfi_get_out_of_my_way=1")
    }

    @Test(arguments: ["nand-xor-ff-v2", "future-format", ""])
    func physicalAndUnknownFormatsRefusedBeforePageMapping(_ format: String) throws {
        try Oracle.withTemp { dir in
            var geometry = try #require(
                JSONSerialization.jsonObject(with: Data(K48NAND.Geometry.selfcheck.json.utf8)) as? [String: Any]
            )
            geometry["storage_format"] = format
            try JSONSerialization.data(withJSONObject: geometry).write(to: dir.appendingPathComponent("geometry.json"))
            // No page files: refusal must occur before mmap or any filesystem interpretation.
            #expect(throws: FirmwareError.self) { try K48NAND.geometry(store: dir) }
            #expect(throws: FirmwareError.self) { try K48NAND.StoreReader(dir, geo: .selfcheck) }
            #expect(throws: FirmwareError.self) { try K48NAND.check(store: dir) }
        }
    }

    @Test(arguments: ["spare_bytes", "chip_id"])
    func geometryRejectsDifferentPhysicalContract(_ field: String) throws {
        try Oracle.withTemp { dir in
            var geometry = try #require(
                JSONSerialization.jsonObject(with: Data(K48NAND.Geometry.selfcheck.json.utf8)) as? [String: Any]
            )
            if field == "chip_id" { geometry[field] = "0xFFFFFFFF" } else { geometry[field] = 64 }
            try JSONSerialization.data(withJSONObject: geometry).write(to: dir.appendingPathComponent("geometry.json"))
            #expect(throws: FirmwareError.self) { try K48NAND.geometry(store: dir) }
        }
    }

    @Test func legacyFormatAndOverlayCompatibility() throws {
        try Oracle.withTemp { dir in
            var geometry = try #require(
                JSONSerialization.jsonObject(with: Data(K48NAND.Geometry.selfcheck.json.utf8)) as? [String: Any]
            )
            try JSONSerialization.data(withJSONObject: geometry).write(to: dir.appendingPathComponent("geometry.json"))
            #expect(try K48NAND.geometry(store: dir).name == "selfcheck")
            geometry["storage_format"] = "legacy-zero-blank-v1"
            try JSONSerialization.data(withJSONObject: geometry).write(to: dir.appendingPathComponent("geometry.json"))
            #expect(try K48NAND.geometry(store: dir).name == "selfcheck")
            let overlay = dir.appendingPathComponent("overlay")
            try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: false)
            try Data("nand-xor-ff-v2\n".utf8).write(to: overlay.appendingPathComponent("storage-format"))
            #expect(throws: FirmwareError.self) { try K48NAND.StoreReader(dir, geo: .selfcheck, overlay: overlay) }
            #expect(throws: FirmwareError.self) { try K48NAND.StoreReader(dir, geo: .k48With16GB) }
        }
    }

    @Test func physicalExportRefusalPublishesNoFilesystem() async throws {
        try await Oracle.withTemp { dir in
            let base = dir.appendingPathComponent("nand")
            let out = dir.appendingPathComponent("export")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
            var geometry = try #require(
                JSONSerialization.jsonObject(with: Data(K48NAND.Geometry.k48With16GB.json.utf8)) as? [String: Any]
            )
            geometry["storage_format"] = "nand-xor-ff-v2"
            try JSONSerialization.data(withJSONObject: geometry).write(to: base.appendingPathComponent("geometry.json"))
            await #expect(throws: FirmwareError.self) {
                try await VolumeExport.export(.init(base: base, overlay: nil), out: out)
            }
            #expect(!FileManager.default.fileExists(atPath: out.path))
        }
    }

    @Test func geometryMatchesKernel() {
        let g = K48NAND.Geometry.k48With16GB
        #expect(g.usable == 1952 && g.toc == 2 && g.dataPages == 2046)
        #expect(g.exportedPages == 3_925_449)  // the real 16 GB unit's sector count
    }

    /// 3.0's layout of the same part (vendor type 0x10001): one VFL bank, 1024-page superblocks, a one-page block TOC.
    @Test func oneBankGeometryForIOS30() {
        let g = K48NAND.Geometry.k48With16GBV1
        #expect(g.vflBanks == 1 && g.ppsublk == 1024 && g.toc == 1 && g.dataPages == 1023)
        #expect(g.json.contains("\"vendor_type\": 65537") && !K48NAND.Geometry.k48With16GB.json.contains("vendor_type"))
    }

    /// The FIL's epoch getter, `ldr rN, [pc, #8]; blx rN; adds r0, #0x30; uxtb r0, r0; pop {r7, pc}` naming `movs r0, #2;
    /// bx lr`: r3 as on 4.3.5, r0 as on the 5.0 betas; no getter (4.3.0, 5.0 GM on) is epoch 1.
    @Test(arguments: [(UInt8(3), UInt8(2)), (0, 2), (nil, 1)]) func signatureEpochFromTheGetter(
        _ reg: UInt8?,
        _ want: UInt8
    ) throws {
        var k = KBootTests.kernel(at: 0x8000_0000)  // __TEXT at 0x80001000 from file offset 0
        if let reg {
            k.replaceSubrange(
                0x200..<0x208,
                with: Data([0x02, 0x48 | reg, 0x80 | reg << 3, 0x47, 0x30, 0x30, 0xC0, 0xB2])
            )
            k.replaceSubrange(0x208..<0x20a, with: Data([0x80, 0xBD]))
            k.replaceSubrange(0x20c..<0x210, with: DeviceTree.Value.le([0x8000_1301]))  // the getter, Thumb
            k.replaceSubrange(0x300..<0x304, with: Data([0x02, 0x20, 0x70, 0x47]))  // movs r0, #2; bx lr
        }
        try Oracle.withTemp { dir in
            let url = dir.appendingPathComponent("kernelcache.mach")
            try k.write(to: url)
            #expect(try K48NAND.signatureEpoch(kernelcache: url) == want)
        }
    }

    /// make_mbr reproduces the 16 GB unit's sector 0.
    @Test func mbrMatchesUnit() {
        let head = [UInt8](K48NAND.makeMBR())
        let unit = Data(
            hex: "00010100affeffff3f00000000000500" + "00feffffaefeffff6d0005002fe53600"
                + "00feffffaffeffff4000050008000000"
        )!
        #expect(Data(head[0x1be..<0x1ee]) == unit && head[510] == 0x55 && head[511] == 0xAA)
        #expect((head[..<0x1be] + head[0x1ee..<510] + head[512...]).allSatisfy { $0 == 0 })
    }

    /// Small synthetic store (the selfcheck geometry), including a sparse data image and an fstab line: the checker
    /// accepts it and its index pages map exactly; whitened (K48, N81) and plain (N18).
    @Test(
        .enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"),
        arguments: [true, false]
    )
    func syntheticStore(whitening: Bool) async throws {
        let dir = try Fixtures.tempDir("nand")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ps = 4096
        var mbr = [UInt8](repeating: 0, count: ps * 63)
        mbr[510] = 0x55
        mbr[511] = 0xAA
        for (i, (typ, lba, cnt)) in [(0xAF, 63, 700), (0xAE, 800, 4000), (0xAF, 763, 8)].enumerated() {
            let o = 0x1be + 16 * i
            mbr[o + 4] = UInt8(typ)
            put32(&mbr, o + 8, UInt32(lba))
            put32(&mbr, o + 12, UInt32(cnt))
        }
        var rng = SystemRandomNumberGenerator()
        var sys = (0..<ps * 700).map { _ in UInt8.random(in: 0...255, using: &rng) }
        sys[1024] = UInt8(ascii: "H")
        sys[1025] = UInt8(ascii: "X")
        let fstab = Array("/dev/disk0s1 / hfs rw 0 1\n/dev/disk0s2s1 /private/var hfs rw 0 2\n".utf8)
        sys.replaceSubrange(ps * 300..<ps * 300 + fstab.count, with: fstab)
        let s3 = [UInt8](repeating: 0x5A, count: ps * 8)
        let paths = ["mbr", "system.img", "s3.bin", "data.img"].map { dir.appendingPathComponent($0) }
        try Data(mbr).write(to: paths[0])
        try Data(sys).write(to: paths[1])
        try Data(s3).write(to: paths[2])
        // sparse data volume: 4000 pages, a header and two islands of data
        let fh = try {
            FileManager.default.createFile(atPath: paths[3].path, contents: nil)
            return try FileHandle(forWritingTo: paths[3])
        }()
        try fh.truncate(atOffset: UInt64(ps * 4000))
        for (page, n) in [(0, 3), (1000, 5), (3990, 2)] {
            try fh.seek(toOffset: UInt64(page * ps))
            try fh.write(contentsOf: Data((0..<n * ps).map { UInt8(truncatingIfNeeded: $0 * 7 + page) }))
        }
        try fh.seek(toOffset: 1024)
        try fh.write(contentsOf: Data("H+".utf8))
        try fh.close()

        let kv = Array("Darwin Kernel Version selfcheck".utf8)
        let mine = dir.appendingPathComponent("swift")
        try await K48NAND.build(
            geometry: .selfcheck,
            mbr: paths[0],
            kernelVersion: kv,
            system: paths[1],
            s3: paths[2],
            data: .image(paths[3]),
            out: mine,
            whitening: whitening
        )
        var lines: [String] = []
        #expect(
            try K48NAND.check(store: mine, mbr: paths[0], system: paths[1]) { lines.append($0) },
            "\(lines.filter { $0.hasPrefix("FAIL") })"
        )
        #expect(lines.contains { $0.contains("index pages map exactly") })
    }

    /// The real thing (FK_NAND_FULL=1): the 7B500 pristine system + 14.7 GB sparse data volume into a
    /// k48-16g store that the checker accepts.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"))
    func fullStore() async throws {
        let u = Fixtures.files.appendingPathComponent("ipad1/userland/pristine")
        let hw2 = Fixtures.files.appendingPathComponent("ipad1/hw2")
        let inputs = [
            hw2.appendingPathComponent("rdisk0-head4M.bin"), u.appendingPathComponent("system.img"),
            hw2.appendingPathComponent("rdisk0s3.bin"), u.appendingPathComponent("data.img"),
            Fixtures.files.appendingPathComponent("ipad1/7B500/dec/kernelcache.mach"),
        ]
        guard ProcessInfo.processInfo.environment["FK_NAND_FULL"] == "1", inputs.allSatisfy(Fixtures.exists) else {
            try FixtureRequirements.missing(
                #"K48NANDTests.swift: ProcessInfo.processInfo.environment["FK_NAND_FULL"] == "1", inputs.allSatisfy(Fixtures.exists)"#
            )
        }
        let dir = try Fixtures.tempDir("nand-full")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mine = dir.appendingPathComponent("swift")
        let t0 = Date()
        let res = try await K48NAND.build(
            mbr: inputs[0],
            kernelVersion: try K48NAND.kernelVersion(kernelcache: inputs[4]),
            system: inputs[1],
            s3: inputs[2],
            data: .image(inputs[3]),
            out: mine
        )
        let swiftTime = Date().timeIntervalSince(t0)
        print("k48-16g: \(res.records) records; swift build \(String(format: "%.1f", swiftTime)) s")
        let du = try Fixtures.run(["du", "-sk", mine.path])
        print("swift store on disk: \(String(decoding: du.out, as: UTF8.self))")
        let t2 = Date()
        #expect(try K48NAND.check(store: mine, mbr: inputs[0], system: inputs[1]))
        print("check: \(String(format: "%.1f", Date().timeIntervalSince(t2))) s")
    }
}
