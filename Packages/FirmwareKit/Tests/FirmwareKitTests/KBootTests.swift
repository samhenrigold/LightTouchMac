import Foundation
import Testing
@testable import FirmwareKit

struct KBootTests {
    // ipad1_kboot.selfcheck: a two-segment Mach-O and a minimal DT.
    static func prop(_ name: String, _ value: Data) -> Data {
        DeviceTree.name32(name) + DeviceTree.Value.le([UInt32(value.count)]) + value + Data(count: ((value.count + 3) & ~3) - value.count)
    }
    static func node(_ props: [(String, Data)], _ children: [Data] = []) -> Data {
        DeviceTree.Value.le([UInt32(props.count), UInt32(children.count)]) + props.map { prop($0, $1) }.reduce(Data(), +) + children.reduce(Data(), +)
    }
    static func z(_ n: Int) -> Data { Data(count: n) }
    static let dtBlob = deviceTree()
    static func deviceTree(armIO extra: [Data] = []) -> Data { node([("name", Data("device-tree\0".utf8))] + ["platform-name", "model-number", "region-info", "serial-number", "mlb-serial-number"].map { ($0, z(32)) }, [
        node([("name", Data("chosen\0".utf8)), ("firmware-version", z(256)), ("root-matching", z(256)), ("unique-chip-id", z(8)), ("die-id", z(8))]
             + ["debug-enabled", "production-cert", "secure-boot", "gid-aes-key", "uid-aes-key", "system-trusted",
                "board-id", "chip-id", "display-rotation", "display-scale"].map { ($0, z(4)) },
             [node([("name", Data("memory-map\0".utf8))] + (0..<16).map { ("MemoryMapReserved-\($0)", z(8)) })]),
        node([("name", Data("cpus\0".utf8))], [node([("name", Data("cpu0\0".utf8))] + ["clock-frequency", "memory-frequency", "bus-frequency",
             "peripheral-frequency", "fixed-frequency", "timebase-frequency"].map { ($0, z(4)) })]),
        node([("name", Data("arm-io\0".utf8)), ("clock-frequencies", z(256)), ("usbphy-frequency", z(4))],
             [node([("name", Data("usb-complex\0".utf8))], [node([("name", Data("usb-ehci\0".utf8))])])] + extra),
        node([("name", Data("pram\0".utf8)), ("reg", z(8))]),
        node([("name", Data("vram\0".utf8)), ("reg", z(8))]),
    ]) }
    static let placeholder = UnitIdentity(fields: [
        ("serial-number", .string("EMU000000000")), ("mlb-serial-number", .string("EMU0000000000")),
        ("unique-chip-id", .string("0x0000000001")), ("die-id", .list(["0x0", "0x0"])),
        ("wifi-mac", .string("02:00:00:00:00:01")), ("bt-mac", .string("02:00:00:00:00:02"))])

    static func kernel(at base: UInt32) -> Data {
        let le = DeviceTree.Value.le
        func seg(_ name: String, _ vm: UInt32, _ vs: UInt32, _ fo: UInt32, _ fs: UInt32) -> Data {
            le([1, 56]) + DeviceTree.name32(name).prefix(16) + le([vm, vs, fo, fs, 7, 7, 0, 0])
        }
        let thread = le([5, 16 + 64, 1, 16] + [UInt32](repeating: 0, count: 15) + [base + 0x1040])
        let cmds = seg("__TEXT", base + 0x1000, 0x2000, 0, 0x2000) + seg("__DATA", base + 0x3000, 0x1800, 0x2000, 0x10) + thread
        var k = le([0xFEED_FACE, 12, 9, 2, 3, UInt32(cmds.count), 0]) + cmds
        k += Data(count: 0x2000 - k.count) + Data(repeating: 0x44, count: 16)
        return k
    }
    static func u32(_ d: Data, _ at: Int) -> UInt32 { MachO.u32(d, at) }

    @Test func selfcheck() throws {
        let img = try KBoot.build(kernel: Self.kernel(at: 0xC000_0000), deviceTree: Self.dtBlob, identity: Self.placeholder)
        #expect((img.loadPA, img.entryPA, img.bootArgsPA) == (0x4000_0000, 0x4000_1040, 0x4000_6000))
        let image = img.image, r0 = Int(img.bootArgsPA - img.loadPA)
        #expect(image[0x1000..<0x1004] == Data([0xCE, 0xFA, 0xED, 0xFE]) && image[0x3000..<0x3010] == Data(repeating: 0x44, count: 16))
        #expect(image[0x3010..<0x4800] == Data(count: 0x17F0))   // __DATA zero fill past filesize
        #expect(image[r0..<r0 + 4] == Data([1, 0, 2, 0]))
        #expect([4, 8, 12, 16].map { Self.u32(image, r0 + $0) } == [0xC000_0000, 0x4000_0000, 0x0F70_0000, 0x4000_8000])
        let dtp = Int(Self.u32(image, r0 + 0x30)), dtlen = Int(Self.u32(image, r0 + 0x34))
        #expect(dtp == 0xC000_5000 && dtlen == Self.dtBlob.count + 36)   // + hsic-enabled
        #expect(image[(r0 + 0x38)...].prefix { $0 != 0 } == Data(KBoot.defaultBootArgs.utf8))
        #expect(Self.u32(image, r0 + 0x18) == 1)   // no -v: graphics (the logo) stays up
        let dt = try DeviceTree(image[(dtp - 0xC000_0000)..<(dtp - 0xC000_0000 + dtlen)])
        let words = { (p: String, k: String) in dt.value(p, k).map { d in stride(from: 0, to: d.count, by: 4).map { Self.u32(d, $0) } } }
        #expect(words("chosen/memory-map", "Kernel-__TEXT") == [0x4000_1000, 0x2000])
        #expect(words("chosen/memory-map", "DeviceTree") == [0x4000_5000, UInt32(dtlen)])
        #expect(words("chosen/memory-map", "BootArgs") == [0x4000_6000, 0x1000])
        #expect(dt.props["chosen/memory-map"]?["MemoryMapReserved-4"] != nil)
        #expect(dt.props["arm-io/usb-complex"]?["hsic-enabled"]?.length == 0 && dt.contains("arm-io/usb-complex/usb-ehci"))
        #expect(words("chosen", "unique-chip-id") == [1, 0] && words("chosen", "die-id") == [0, 0])
        #expect(words("chosen", "chip-id") == [0x8930] && words("cpus/cpu0", "timebase-frequency") == [24_000_000])
        #expect(words("vram", "reg") == [0x4F70_0000, 0x8F_C000] && words("pram", "reg") == [0x4FFF_C000, 0x4000])
        #expect(words("chosen", "display-rotation") == [270])

        // 4.x link base; RAM-disk mode puts the disk after the kernel (0x80004800 -> page 0x80005000), DT after it.
        let img4 = try KBoot.build(kernel: Self.kernel(at: 0x8000_0000), deviceTree: Self.dtBlob, identity: Self.placeholder)
        #expect((img4.entryPA, img4.bootArgsPA) == (0x4000_1040, 0x4000_6000) && Self.u32(img4.image, 0x6000 + 4) == 0x8000_0000)
        let rd = Data([UInt8]("H+".utf8) * 0x900)
        let imgr = try KBoot.build(kernel: Self.kernel(at: 0x8000_0000), deviceTree: Self.dtBlob, identity: Self.placeholder, ramdisk: rd)
        #expect(imgr.image[0x5000..<0x5000 + rd.count] == rd && imgr.bootArgsPA == 0x4000_8000)
        #expect(imgr.image[(0x8000 + 0x38)...].prefix { $0 != 0 } == Data((KBoot.defaultBootArgs + " rd=md0").utf8))
        let dtr = try DeviceTree(imgr.image[0x7000..<0x7000 + Self.dtBlob.count + 36])
        #expect(dtr.value("chosen/memory-map", "RAMDisk") == DeviceTree.Value.le([0x4000_5000, UInt32(rd.count)]))
        #expect(dtr.value("chosen", "root-matching")?.prefix(4) == Data(count: 4))
    }

    /// ipad1_kboot.fill_dt's NAND geometry: every key a node has, on flash-controller0 (iBoot-1219, 5.x: with
    /// ce-bitmap, which AppleIOPFMI-49 spins on when empty) and on its disk child (4.x).
    @Test func nandGeometryOn5xNodes() throws {
        let blob = Self.deviceTree(armIO: [Self.node([("name", Data("flash-controller0\0".utf8)), ("#ce", Self.z(4)), ("ce-bitmap", Self.z(4))],
                                                     [Self.node([("name", Data("disk\0".utf8)), ("#ce", Self.z(4)), ("#databus", Self.z(4))])])])
        let img = try KBoot.build(kernel: Self.kernel(at: 0x8000_0000), deviceTree: blob, identity: Self.placeholder)
        let r0 = Int(img.bootArgsPA - img.loadPA), vbase = Self.u32(img.image, r0 + 4)
        let dtp = Int(Self.u32(img.image, r0 + 0x30) - vbase), dtlen = Int(Self.u32(img.image, r0 + 0x34))
        let built = try DeviceTree(img.image[dtp..<dtp + dtlen])
        let w = { (p: String, k: String) in built.value(p, k).map { Self.u32($0, 0) } }
        #expect(w("arm-io/flash-controller0", "ce-bitmap") == 0x0F0F && w("arm-io/flash-controller0", "#ce") == 8)
        #expect(w("arm-io/flash-controller0/disk", "#ce") == 8 && w("arm-io/flash-controller0/disk", "#databus") == 2)
        #expect(built.value("arm-io/flash-controller0/disk", "ce-bitmap") == nil)
    }

    @Test func deviceTreeEdits() throws {
        var dt = try DeviceTree(Self.dtBlob)
        #expect(dt.data == Self.dtBlob)
        #expect(throws: FirmwareError.self) { try dt.set("chosen", "board-id", .words([1, 2])) }
        try dt.set("chosen", "firmware-version", .string("iBoot-1"))
        #expect(dt.value("chosen", "firmware-version")?.prefix(8) == Data("iBoot-1\0".utf8))
        try dt.add("", "added", Data([1, 2, 3]))
        #expect(dt.value("", "added") == Data([1, 2, 3]) && dt.data.count == Self.dtBlob.count + 40)
        try dt.rename("chosen/memory-map", "MemoryMapReserved-0", "X")
        #expect(dt.props["chosen/memory-map"]?["X"] != nil && dt.props["chosen/memory-map"]?["MemoryMapReserved-0"] == nil)
        #expect(try DeviceTree(dt.data).value("chosen/memory-map", "X") == Data(count: 8))
        #expect(throws: FirmwareError.self) { try DeviceTree(Self.dtBlob + Data(count: 4)) }
    }

    /// ipad1_kboot.boot_args_version: the kernel's own `ldrh r3, [r0, #2]; cmp r3, #3` before the Epoch Mismatch literal.
    @Test func bootArgsVersion() throws {
        var k = Self.kernel(at: 0x8000_0000)
        #expect(try MachO(k).bootArgsVersion() == 2)   // no check in the kernel: 3.2.x / 4.2.1 / 4.3.0 shape
        let s = Data("pe_identify_machine: Epoch Mismatch\0".utf8)
        k.replaceSubrange(0x100..<0x100 + s.count, with: s)
        k.replaceSubrange(0x200..<0x204, with: Data([0x43, 0x88, 0x03, 0x2B]))        // ldrh r3, [r0, #2]; cmp r3, #3
        k.replaceSubrange(0x210..<0x214, with: DeviceTree.Value.le([0x8000_1100]))    // the string's VA in the literal pool
        #expect(try MachO(k).bootArgsVersion() == 3)
        let img = try KBoot.build(kernel: k, deviceTree: Self.dtBlob, identity: Self.placeholder)
        #expect(img.image[Int(img.bootArgsPA - img.loadPA)..<Int(img.bootArgsPA - img.loadPA) + 4] == Data([1, 0, 3, 0]))
    }

    @Test func iBootVersion() {
        #expect(KBoot.ibootVersion(Data("xxiBoot-xiBoot-817.29.\0".utf8)) == "iBoot-817.29")
        #expect(KBoot.ibootVersion(Data("iBoot-931.71.16 ".utf8)) == "iBoot-931.71.16")
        #expect(KBoot.ibootVersion(nil) == "iBoot-817.29" && KBoot.ibootVersion(Data("none".utf8)) == "iBoot-817.29")
    }

    // sha256 of `ipad1_kboot.py --identity ID [--ramdisk DEC/<UpdateRamDisk>-ramdisk.dmg] DEC OUT` at qemu-ios
    // ipad1 5e4ab3e6bf (enable-hsic=1), DEC = ipad1_fw.py's output, ID = UnitIdentity.synthesize("ipad1-7B500-default")
    // (IdentityTests' sha 4d3799...), whose die-id now follows ff331e1ef9's ECID-derived words, as the DT's
    // chosen/die-id shows.
    static let python: [(String, String, String, String)] = [
        ("k48ap-7B500", "018-8374-001-ramdisk.dmg",
         "71f2b5c862f4b2445bcb085071c2b6264f36e0750ea701d2d9a588f0b6d97423", "5f921d8a7dfa60f9203c653d7524cbcc23bbfe4f4402858e4ebafe54a5eb754f"),
        ("k48ap-8C148", "038-0024-002-ramdisk.dmg",
         "b983e3f72a757f3c7581c1d55cb7b5432550935d4fba5ebe4ea64560bcd6f98e", "fc3e36b72520d33cabad48d58385d1787d1a55510164e4a7d771eb8810117324"),
        ("k48ap-7B367", "018-7225-009-ramdisk.dmg",
         "9df137569c86ad51d814f1da56ac33bf178f8763b27f96fdd4784b95a652770e", "94703af6dbba02cc7ba691bfecaa6801662345d5e18a135e5384126bec31d495"),
    ].filter { Oracle.firmware($0.0).available }

    /// The whole Swift chain (IPSW -> FirmwareDecryptor -> KBoot) against the Python chain's kboot.bin.
    @Test(arguments: python) func kbootMatchesPython(id: String, ramdisk: String, normal: String, rdMode: String) throws {
        try Oracle.withTemp { dir in
            let dec = dir.appendingPathComponent("dec")
            _ = try FirmwareDecryptor.decrypt(ipsw: Oracle.firmware(id).ipsw, entry: Oracle.entry(id), into: dec, rootfs: false)
            let ident = try UnitIdentity.synthesize(seed: "ipad1-7B500-default")
            let a = dir.appendingPathComponent("kboot.bin"), b = dir.appendingPathComponent("kboot-rd.bin")
            try Oracle.time("kboot \(id)") { try KBoot.write(decrypted: dec, to: a, identity: ident) }
            try KBoot.write(decrypted: dec, to: b, identity: ident, ramdisk: dec.appendingPathComponent(ramdisk))
            #expect(try Oracle.sha256(file: a) == normal)
            #expect(try Oracle.sha256(file: b) == rdMode)

            // The DT's secure-root-prefix is the IPSW's, in both modes.
            let src = try DeviceTree(Data(contentsOf: dec.appendingPathComponent("DeviceTree.bin")))
            #expect(src.value("", "secure-root-prefix")?.prefix(3) == Data("md\0".utf8))
            for f in [a, b] {
                let bin = try Data(contentsOf: f), trailer = bin.suffix(24)
                #expect(trailer.prefix(8) == Data("K48KBOOT".utf8))
                let t = [UInt8](trailer)
                let args = Int(t.u32(16) - t.u32(8)), vbase = Self.u32(bin, args + 4)
                let dtp = Int(Self.u32(bin, args + 0x30) - vbase), dtlen = Int(Self.u32(bin, args + 0x34))
                let built = try DeviceTree(bin[dtp..<dtp + dtlen])
                #expect(built.value("", "secure-root-prefix") == src.value("", "secure-root-prefix"))
            }
        }
    }
}

private func * (a: [UInt8], n: Int) -> [UInt8] { (0..<n).flatMap { _ in a } }
