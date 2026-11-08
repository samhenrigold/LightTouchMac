import Foundation
import Testing

@testable import FirmwareKit

struct KBootTests {
    // ipad1_kboot.selfcheck: a two-segment Mach-O and a minimal DT.
    static func prop(_ name: String, _ value: Data) -> Data {
        DeviceTree.name32(name) + DeviceTree.Value.le([UInt32(value.count)]) + value
            + Data(count: ((value.count + 3) & ~3) - value.count)
    }
    static func node(_ props: [(String, Data)], _ children: [Data] = []) -> Data {
        DeviceTree.Value.le([UInt32(props.count), UInt32(children.count)])
            + props.map { prop($0, $1) }.reduce(Data(), +) + children.reduce(Data(), +)
    }
    static func z(_ n: Int) -> Data { Data(count: n) }
    static let dtBlob = deviceTree()
    static func deviceTree(armIO extra: [Data] = [], top: [Data] = []) -> Data {
        node(
            [("name", Data("device-tree\0".utf8))]
                + ["platform-name", "model-number", "region-info", "serial-number", "mlb-serial-number"].map {
                    ($0, z(32))
                },
            [
                node(
                    [
                        ("name", Data("chosen\0".utf8)), ("firmware-version", z(256)), ("root-matching", z(256)),
                        ("unique-chip-id", z(8)), ("die-id", z(8))
                    ]
                        + [
                            "debug-enabled", "production-cert", "secure-boot", "gid-aes-key", "uid-aes-key",
                            "system-trusted",
                            "board-id", "chip-id", "display-rotation", "display-scale"
                        ].map { ($0, z(4)) },
                    [node([("name", Data("memory-map\0".utf8))] + (0..<16).map { ("MemoryMapReserved-\($0)", z(8)) })]
                ),
                node(
                    [("name", Data("cpus\0".utf8))],
                    [
                        node(
                            [("name", Data("cpu0\0".utf8))]
                                + [
                                    "clock-frequency", "memory-frequency", "bus-frequency",
                                    "peripheral-frequency", "fixed-frequency", "timebase-frequency"
                                ].map { ($0, z(4)) }
                        )
                    ]
                ),
                node(
                    [("name", Data("arm-io\0".utf8)), ("clock-frequencies", z(256)), ("usbphy-frequency", z(4))],
                    [node([("name", Data("usb-complex\0".utf8))], [node([("name", Data("usb-ehci\0".utf8))])])] + extra
                ),
                node([("name", Data("pram\0".utf8)), ("reg", z(8))]),
                node([("name", Data("vram\0".utf8)), ("reg", z(8))])
            ] + top
        )
    }
    static let placeholder = UnitIdentity(fields: [
        ("serial-number", .string("EMU000000000")), ("mlb-serial-number", .string("EMU0000000000")),
        ("unique-chip-id", .string("0x0000000001")), ("die-id", .list(["0x0", "0x0"])),
        ("wifi-mac", .string("02:00:00:00:00:01")), ("bt-mac", .string("02:00:00:00:00:02"))
    ])

    @Test func a6RootSelectsNestedSystemVolumeAndRamdiskRemainsIndependent() throws {
        var source = try DeviceTree(Self.dtBlob)
        try source.add("", "compatible", Data("N42AP\0iPhone5,2\0AppleARM\0".utf8))
        for ramdisk: Data? in [nil, Data(repeating: 0, count: 4096)] {
            let image = try KBoot.build(kernel: Self.kernel(at: 0x8000_0000),
                deviceTree: source.data, identity: Self.placeholder, ramdisk: ramdisk)
            let argsOffset = Int(image.bootArgsPA - 0x8000_0000)
            let treeOffset = Int(Self.u32(image.image, argsOffset + 0x30) - 0x8000_0000)
            let treeLength = Int(Self.u32(image.image, argsOffset + 0x34))
            let tree = try DeviceTree(image.image[treeOffset..<treeOffset + treeLength])
            let xml = tree.value("chosen", "root-matching")!.prefix { $0 != 0 }
            #expect(String(decoding: xml, as: UTF8.self) == (ramdisk == nil ? KBoot.a6RootMatching : ""))
            if ramdisk == nil {
                let match = try PropertyListSerialization.propertyList(from: Data(xml), format: nil) as! [String: Any]
                #expect((match["IOPropertyMatch"] as? [String: String])?["BSD Name"] == "disk0s1s1")
            }
        }
        let flat = try KBoot.build(kernel: Self.kernel(at: 0x8000_0000),
            deviceTree: source.data, identity: Self.placeholder, rootDevice: "disk0s1")
        let args = Int(flat.bootArgsPA - 0x8000_0000)
        let at = Int(Self.u32(flat.image, args + 0x30) - 0x8000_0000)
        let count = Int(Self.u32(flat.image, args + 0x34))
        let tree = try DeviceTree(flat.image[at..<at + count])
        let xml = tree.value("chosen", "root-matching")!.prefix { $0 != 0 }
        let match = try PropertyListSerialization.propertyList(from: Data(xml), format: nil) as! [String: Any]
        #expect((match["IOPropertyMatch"] as? [String: String])?["BSD Name"] == "disk0s1")
        #expect(throws: FirmwareError.self) {
            try KBoot.build(kernel: Self.kernel(at: 0x8000_0000), deviceTree: source.data,
                identity: Self.placeholder, rootDevice: "disk0s1</string>")
        }
    }

    @Test func a6ReservesEntropyBeforeMeasuringTheHandoff() throws {
        for seedLength: Int? in [nil, 2, 64] {
            var source = try DeviceTree(Self.dtBlob)
            try source.add("", "compatible", Data("N42AP\0iPhone5,2\0AppleARM\0".utf8))
            if let seedLength { try source.add("chosen", "random-seed", Data(count: seedLength)) }
            for ramdisk: Data? in [nil, Data(count: 4096)] {
                let image = try KBoot.build(kernel: Self.kernel(at: 0x8000_0000),
                    deviceTree: source.data, identity: Self.placeholder, ramdisk: ramdisk)
                let args = Int(image.bootArgsPA - image.loadPA)
                let at = Int(Self.u32(image.image, args + 0x30) - image.loadPA)
                let length = Int(Self.u32(image.image, args + 0x34))
                #expect(at + length <= args)
                let tree = try DeviceTree(image.image[at..<at + length])
                #expect(tree.value("chosen", "random-seed") == Data(count: 64))
            }
            #expect(source.value("chosen", "random-seed")?.count == seedLength)
        }
        let a4 = try KBoot.build(kernel: Self.kernel(at: 0x4000_0000),
            deviceTree: Self.dtBlob, identity: Self.placeholder)
        let args = Int(a4.bootArgsPA - a4.loadPA)
        let at = Int(Self.u32(a4.image, args + 0x30) - a4.loadPA)
        let length = Int(Self.u32(a4.image, args + 0x34))
        #expect(try DeviceTree(a4.image[at..<at + length]).value("chosen", "random-seed") == nil)
    }

    static func kernel(at base: UInt32) -> Data {
        let le = DeviceTree.Value.le
        func seg(_ name: String, _ vm: UInt32, _ vs: UInt32, _ fo: UInt32, _ fs: UInt32) -> Data {
            le([1, 56]) + DeviceTree.name32(name).prefix(16) + le([vm, vs, fo, fs, 7, 7, 0, 0])
        }
        let thread = le([5, 16 + 64, 1, 16] + [UInt32](repeating: 0, count: 15) + [base + 0x1040])
        let cmds =
            seg("__TEXT", base + 0x1000, 0x2000, 0, 0x2000) + seg("__DATA", base + 0x3000, 0x1800, 0x2000, 0x10)
            + thread
        var k = le([0xFEED_FACE, 12, 9, 2, 3, UInt32(cmds.count), 0]) + cmds
        k += Data(count: 0x2000 - k.count) + Data(repeating: 0x44, count: 16)
        return k
    }
    static func u32(_ d: Data, _ at: Int) -> UInt32 { (try? MachO.u32(d, at)) ?? 0 }

    /// N81: the board comes from the DT's compatible; its NOR is grafted in and boot-from-nand renamed away.
    @Test func n81Board() throws {
        let n = { (s: String) in Data((s + "\0").utf8) }
        let armIO = [
            Self.node([("name", n("spi0"))]),
            Self.node(
                [("name", n("flash-controller0"))],
                [Self.node([("name", n("disk")), ("boot-from-nand", DeviceTree.Value.le([1]))])]
            ),
            Self.node(
                [("name", n("uart1"))],
                [Self.node([("name", n("bluetooth")), ("local-mac-address", Self.z(6))])]
            )
        ]
        var tree = try DeviceTree(Self.deviceTree(armIO: armIO))
        try tree.add("", "compatible", Data("N81AP\0iPod4,1\0AppleARM\0".utf8))
        let k48 = try DeviceTree(Self.dtBlob)
        #expect(KBoot.Board.of(tree) == .n81 && KBoot.Board.of(k48) == .k48)
        let img = try KBoot.build(
            kernel: Self.kernel(at: 0x8000_0000),
            deviceTree: tree.data,
            identity: Self.placeholder
        )
        let r0 = Int(img.bootArgsPA - img.loadPA)
        let image = img.image
        // rowbytes, w, h, depth | scale-1
        #expect([0x1C, 0x20, 0x24, 0x28].map { Self.u32(image, r0 + $0) } == [640 * 4, 640, 960, 32 | 1 << 16])
        let dtp = Int(Self.u32(image, r0 + 0x30)) - 0x8000_0000
        let dtlen = Int(Self.u32(image, r0 + 0x34))
        let dt = try DeviceTree(image[dtp..<dtp + dtlen])
        let word = { (p: String, k: String) in dt.value(p, k).map { Self.u32($0, 0) } }
        #expect(
            word("chosen", "board-id") == 8 && word("chosen", "display-rotation") == 0
                && word("chosen", "display-scale") == 2
        )
        #expect(
            [
                "nor-flash", "nor-flash/nvram", "nor-flash/effaceable", "nor-flash/raw-device",
                "nor-flash/diagnostic-data"
            ]
            .allSatisfy { dt.contains("arm-io/spi0/" + $0) }
        )
        #expect(dt.value("arm-io/spi0/nor-flash/effaceable", "compatible") == Data("effaceable,nor\0".utf8))
        #expect(
            dt.props["arm-io/flash-controller0/disk"]?["boot-from-nand"] == nil
                && word("arm-io/flash-controller0/disk", "boot-from-nor") == 1
        )
        #expect(dt.value("arm-io/uart1/bluetooth", "local-mac-address") == Data([2, 0, 0, 0, 0, 2]))
        #expect(dt.value("", "model-number")?.prefix(5) == Data("MC540".utf8))
    }

    /// A6's Wi-Fi is a USB/HSIC child, not an SDIO node. Give the native
    /// provisioning manager the same unit identity the other boards receive.
    @Test func n42WiFiIdentity() throws {
        let n = { (s: String) in Data((s + "\0").utf8) }
        let usb = Self.node([("name", n("usb-complex"))], [
            Self.node([("name", n("usb-ehci"))], [
                Self.node([("name", n("wlan")), ("local-mac-address", Self.z(6))])
            ])
        ])
        var tree = try DeviceTree(Self.deviceTree(armIO: [usb]))
        try tree.add("", "compatible", n("N42AP"))
        try tree.add("chosen", "mac-address-wifi0", Self.z(6))
        let img = try KBoot.build(kernel: Self.kernel(at: 0x8000_0000),
                                 deviceTree: tree.data, identity: Self.placeholder)
        let r0 = Int(img.bootArgsPA - img.loadPA)
        let start = Int(Self.u32(img.image, r0 + 0x30)) - 0x8000_0000
        let count = Int(Self.u32(img.image, r0 + 0x34))
        let result = try DeviceTree(img.image[start..<start + count])
        #expect(result.value("arm-io/usb-complex/usb-ehci/wlan", "local-mac-address")
                == Data([2, 0, 0, 0, 0, 1]))
        #expect(result.value("chosen", "mac-address-wifi0") == Data([2, 0, 0, 0, 0, 1]))
    }

    /// The IPSW's device-clocks entries for BASE1, SPI2-CLK, DP and ETHERNET (candidate parent lists, flags).
    static func deviceClocks() -> Data {
        func entry(_ head: String, _ name: String) -> Data {
            Data(hex: head)! + Data(count: 8) + Data(name.utf8) + Data(count: 16 - name.utf8.count)
        }
        return entry("000080090000000001020304", "BASE1") + entry("00008020000000000c0d0000", "SPI2-CLK")
            + entry("00010176000000001a190000", "DP") + entry("000000590000000016000000", "ETHERNET")
    }
    static func pmgr() -> Data {
        node([("name", Data("pmgr\0".utf8)), ("device-clocks", deviceClocks())])
    }
    static func entries(_ d: Data?) -> [String] {
        guard let d else { return [] }
        return stride(from: 0, to: d.count, by: 36).map { d[d.startIndex + $0..<d.startIndex + $0 + 12].hexString }
    }

    static func panel() -> Data {
        node(
            [("name", Data("mipi-dsim\0".utf8))],
            [node([("name", Data("lcd\0".utf8)), ("lcd-panel-id", z(4)), ("raw-panel-id", z(16))])]
        )
    }
    static func backlight() -> Data {
        node([("name", Data("backlight\0".utf8)), ("backlight-id", Data([0xFF, 0xFF, 0xFF, 0xFF]))])
    }

    /// N90: 512 MiB (memSize, vram, pram at its top) and the baseband node kept matchable for the machine.
    @Test func n90Board() throws {
        let n = { (s: String) in Data((s + "\0").utf8) }
        let bb = Self.node([("name", n("baseband")), ("compatible", n("baseband,n90")), ("device_type", n("baseband"))])
        var tree = try DeviceTree(
            Self.deviceTree(
                armIO: [Self.node([("name", n("spi0"))]), Self.pmgr(), Self.panel()],
                top: [bb, Self.backlight()]
            )
        )
        try tree.add("", "compatible", Data("N90AP\0iPhone3,1\0AppleARM\0".utf8))
        try tree.add("arm-io", "chip-revision", Self.z(4))
        #expect(KBoot.Board.of(tree) == .n90)
        let img = try KBoot.build(
            kernel: Self.kernel(at: 0x8000_0000),
            deviceTree: tree.data,
            identity: Self.placeholder
        )
        let r0 = Int(img.bootArgsPA - img.loadPA)
        let image = img.image
        #expect([0x0C, 0x14].map { Self.u32(image, r0 + $0) } == [0x1F70_0000, 0x5F70_0000])  // memSize, vram base
        let dtp = Int(Self.u32(image, r0 + 0x30)) - 0x8000_0000
        let dtlen = Int(Self.u32(image, r0 + 0x34))
        let out = try DeviceTree(image[dtp..<dtp + dtlen])
        #expect(out.value("baseband", "compatible") == n("baseband,n90"))
        #expect(out.value("vram", "reg") == DeviceTree.Value.le([0x5F70_0000, 0x8F_C000]))
        #expect(out.value("chosen", "board-id") == DeviceTree.Value.le([0]))
        // The real iPhone 4's clock table (4.3): APLL, EPLL, FMI, the pixel clock, SPI and I2C, not 100 MHz everywhere.
        let clocks = out.value("arm-io", "clock-frequencies").map { d in (0..<64).map { Self.u32(d, $0 * 4) } } ?? []
        #expect(
            [1, 2, 3, 13, 14, 27, 33, 39, 44, 49, 52, 55].map { clocks[$0] }
                == [
                    800_000_000, 500_000_000, 1_026_000_000, 160_000_000, 51_300_000, 100_000_000, 102_600_000,
                    68_400_000, 0, 48_857_142, 1_000_000, 0
                ]
        )
        // The IPSW's candidate parents, as iBoot hands them over: the kernel settles them.
        #expect(out.value("arm-io/pmgr", "device-clocks") == Self.deviceClocks())
        // The iPhone 4's A4 stepping, its panel's ID as iBoot reads it, and the backlight table that panel selects.
        #expect(out.value("arm-io", "chip-revision") == DeviceTree.Value.le([0x20]))
        #expect(out.value("arm-io/mipi-dsim/lcd", "lcd-panel-id") == DeviceTree.Value.le([0xA18A_05C8]))
        #expect(out.value("arm-io/mipi-dsim/lcd", "raw-panel-id") == Data([0xA1, 0x8A, 0x58, 0x09, 7]) + Self.z(11))
        #expect(out.value("backlight", "backlight-id") == DeviceTree.Value.le([5]))
        var k48 = try DeviceTree(Self.deviceTree(armIO: [Self.pmgr(), Self.panel()], top: [Self.backlight()]))
        try k48.add("arm-io", "chip-revision", Self.z(4))
        let k48Image = try KBoot.build(
            kernel: Self.kernel(at: 0x8000_0000),
            deviceTree: k48.data,
            identity: Self.placeholder
        )
        let k0 = Int(k48Image.bootArgsPA - k48Image.loadPA)
        let kp = Int(Self.u32(k48Image.image, k0 + 0x30)) - 0x8000_0000
        let kdt = try DeviceTree(k48Image.image[kp..<kp + Int(Self.u32(k48Image.image, k0 + 0x34))])
        // The real iPad's (3.2.2): a 1 GHz APLL, PLL1 off, 166.67 and 68.4 MHz where the iPhone 4 has 160 and 51.3.
        let k48Clocks = kdt.value("arm-io", "clock-frequencies").map { d in (0..<64).map { Self.u32(d, $0 * 4) } } ?? []
        #expect(
            [1, 2, 13, 14, 33, 44, 49].map { k48Clocks[$0] }
                == [1_000_000_000, 0, 166_666_666, 68_400_000, 102_600_000, 0, 24_000_000]
        )
        #expect(kdt.value("arm-io", "chip-revision") == DeviceTree.Value.le([0x11]))
        #expect(kdt.value("arm-io/mipi-dsim/lcd", "lcd-panel-id") == DeviceTree.Value.le([0xA1E5_06C9]))
        #expect(kdt.value("backlight", "backlight-id") == DeviceTree.Value.le([6]))
        #expect(kdt.value("arm-io/pmgr", "device-clocks") == Self.deviceClocks())
    }

    /// N88 (S5L8920): its own platform-name/chip-id, a 320x480 panel, its own NOR kept (nothing grafted) with
    /// boot-from-nand renamed away, the baseband node unmatched (renamed nobb) with test identity in it.
    @Test func n88Board() throws {
        let n = { (s: String) in Data((s + "\0").utf8) }
        let nor = Self.node([("name", n("nor-flash")), ("compatible", n("nor-flash,spi"))])
        let armIO = [
            Self.node([("name", n("spi0"))], [nor]),
            Self.node(
                [("name", n("flash-controller0"))],
                [Self.node([("name", n("disk")), ("boot-from-nand", DeviceTree.Value.le([1]))])]
            ),
            Self.node([("name", n("audio-complex")), ("ncoref-frequency", Self.z(4))])
        ]
        let bb = Self.node([
            ("name", n("baseband")), ("compatible", n("baseband,n88")), ("device_type", n("baseband")),
            ("device-imei", Self.z(16)), ("snum", Self.z(12))
        ])
        var tree = try DeviceTree(Self.deviceTree(armIO: armIO, top: [bb]))
        try tree.add("", "compatible", Data("N88AP\0iPhone2,1\0AppleARM\0".utf8))
        #expect(KBoot.Board.of(tree) == .n88)
        let img = try KBoot.build(
            kernel: Self.kernel(at: 0x8000_0000),
            deviceTree: tree.data,
            identity: Self.placeholder
        )
        let r0 = Int(img.bootArgsPA - img.loadPA)
        let image = img.image
        #expect([0x1C, 0x20, 0x24, 0x28].map { Self.u32(image, r0 + $0) } == [320 * 4, 320, 480, 32])
        let dtp = Int(Self.u32(image, r0 + 0x30)) - 0x8000_0000
        let dtlen = Int(Self.u32(image, r0 + 0x34))
        let dt = try DeviceTree(image[dtp..<dtp + dtlen])
        let word = { (p: String, k: String) in dt.value(p, k).map { Self.u32($0, 0) } }
        #expect(
            word("chosen", "chip-id") == 0x8920 && word("chosen", "board-id") == 0
                && word("chosen", "display-rotation") == 0
        )
        #expect(dt.value("", "platform-name")?.prefix(9) == Data("s5l8920x\0".utf8))
        #expect(!dt.contains("arm-io/spi0/nor-flash/effaceable"))  // its own NOR: no graft
        #expect(dt.props["arm-io/flash-controller0/disk"]?["boot-from-nand"] == nil)
        #expect(dt.value("nobb", "compatible")?.prefix(5) == Data("none\0".utf8))
        #expect(dt.value("nobb", "device-imei")?.prefix(16) == Data("004999010640000\0".utf8))
        #expect(dt.value("nobb", "snum") == Data("TESTSNUM0000".utf8))
        #expect(dt.value("", "model-number")?.prefix(5) == Data("MB715".utf8))
        #expect(word("arm-io/audio-complex", "ncoref-frequency") == 162_000_000)  // PLL1, as iBoot fills it
    }

    /// N18 (S5L8922): its platform-name and chip-id, the 320x480 portrait panel at scale 1, and the NOR graft as on N81.
    @Test func n18Board() throws {
        let n = { (s: String) in Data((s + "\0").utf8) }
        let armIO = [
            Self.node([("name", n("spi0"))]),
            Self.node(
                [("name", n("flash-controller0"))],
                [Self.node([("name", n("disk")), ("boot-from-nand", DeviceTree.Value.le([1]))])]
            )
        ]
        var tree = try DeviceTree(Self.deviceTree(armIO: armIO))
        try tree.add("", "compatible", Data("N18AP\0iPod3,1\0AppleARM\0".utf8))
        #expect(KBoot.Board.of(tree) == .n18)
        let img = try KBoot.build(
            kernel: Self.kernel(at: 0x8000_0000),
            deviceTree: tree.data,
            identity: Self.placeholder
        )
        let r0 = Int(img.bootArgsPA - img.loadPA)
        let image = img.image
        // rowbytes, w, h, depth | scale-1
        #expect([0x1C, 0x20, 0x24, 0x28].map { Self.u32(image, r0 + $0) } == [320 * 4, 320, 480, 32])
        let dtp = Int(Self.u32(image, r0 + 0x30)) - 0x8000_0000
        let dtlen = Int(Self.u32(image, r0 + 0x34))
        let dt = try DeviceTree(image[dtp..<dtp + dtlen])
        let word = { (p: String, k: String) in dt.value(p, k).map { Self.u32($0, 0) } }
        #expect(dt.value("", "platform-name")?.prefix(9) == n("s5l8922x"))
        #expect(
            word("chosen", "chip-id") == 0x8922 && word("chosen", "board-id") == 2
                && word("chosen", "display-scale") == 1
        )
        #expect(
            dt.contains("arm-io/spi0/nor-flash/effaceable")
                && word("arm-io/flash-controller0/disk", "boot-from-nor") == 1
        )
        #expect(dt.value("", "model-number")?.prefix(5) == Data("MC008".utf8))
    }

    @Test func selfcheck() throws {
        let img = try KBoot.build(
            kernel: Self.kernel(at: 0xC000_0000),
            deviceTree: Self.dtBlob,
            identity: Self.placeholder
        )
        #expect((img.loadPA, img.entryPA, img.bootArgsPA) == (0x4000_0000, 0x4000_1040, 0x4000_6000))
        let image = img.image
        let r0 = Int(img.bootArgsPA - img.loadPA)
        #expect(
            image[0x1000..<0x1004] == Data([0xCE, 0xFA, 0xED, 0xFE])
                && image[0x3000..<0x3010] == Data(repeating: 0x44, count: 16)
        )
        #expect(image[0x3010..<0x4800] == Data(count: 0x17F0))  // __DATA zero fill past filesize
        #expect(image[r0..<r0 + 4] == Data([1, 0, 2, 0]))
        #expect(
            [4, 8, 12, 16].map { Self.u32(image, r0 + $0) } == [0xC000_0000, 0x4000_0000, 0x0F70_0000, 0x4000_8000]
        )
        let dtp = Int(Self.u32(image, r0 + 0x30))
        let dtlen = Int(Self.u32(image, r0 + 0x34))
        #expect(dtp == 0xC000_5000 && dtlen == Self.dtBlob.count + 36)  // + hsic-enabled
        #expect(image[(r0 + 0x38)...].prefix { $0 != 0 } == Data(KBoot.defaultBootArgs.utf8))
        #expect(Self.u32(image, r0 + 0x18) == 1)  // no -v: graphics (the logo) stays up
        let dt = try DeviceTree(image[(dtp - 0xC000_0000)..<(dtp - 0xC000_0000 + dtlen)])
        let words = { (p: String, k: String) in
            dt.value(p, k).map { d in stride(from: 0, to: d.count, by: 4).map { Self.u32(d, $0) } }
        }
        #expect(words("chosen/memory-map", "Kernel-__TEXT") == [0x4000_1000, 0x2000])
        #expect(words("chosen/memory-map", "DeviceTree") == [0x4000_5000, UInt32(dtlen)])
        #expect(words("chosen/memory-map", "BootArgs") == [0x4000_6000, 0x1000])
        #expect(dt.props["chosen/memory-map"]?["MemoryMapReserved-4"] != nil)
        #expect(
            dt.props["arm-io/usb-complex"]?["hsic-enabled"]?.length == 0 && dt.contains("arm-io/usb-complex/usb-ehci")
        )
        #expect(words("chosen", "unique-chip-id") == [1, 0] && words("chosen", "die-id") == [0, 0])
        #expect(words("chosen", "chip-id") == [0x8930] && words("cpus/cpu0", "timebase-frequency") == [24_000_000])
        #expect(words("vram", "reg") == [0x4F70_0000, 0x8F_C000] && words("pram", "reg") == [0x5FFF_C000, 0x4000])
        #expect(words("chosen", "display-rotation") == [270])

        // 4.x link base; RAM-disk mode puts the disk after the kernel (0x80004800 -> page 0x80005000), DT after it.
        let img4 = try KBoot.build(
            kernel: Self.kernel(at: 0x8000_0000),
            deviceTree: Self.dtBlob,
            identity: Self.placeholder
        )
        #expect(
            (img4.entryPA, img4.bootArgsPA) == (0x4000_1040, 0x4000_6000)
                && Self.u32(img4.image, 0x6000 + 4) == 0x8000_0000
        )
        let rd = Data([UInt8]("H+".utf8) * 0x900)
        let imgr = try KBoot.build(
            kernel: Self.kernel(at: 0x8000_0000),
            deviceTree: Self.dtBlob,
            identity: Self.placeholder,
            ramdisk: rd
        )
        #expect(imgr.image[0x5000..<0x5000 + rd.count] == rd && imgr.bootArgsPA == 0x4000_8000)
        #expect(imgr.image[(0x8000 + 0x38)...].prefix { $0 != 0 } == Data((KBoot.defaultBootArgs + " rd=md0").utf8))
        let dtr = try DeviceTree(imgr.image[0x7000..<0x7000 + Self.dtBlob.count + 36])
        #expect(dtr.value("chosen/memory-map", "RAMDisk") == DeviceTree.Value.le([0x4000_5000, UInt32(rd.count)]))
        #expect(dtr.value("chosen", "root-matching")?.prefix(4) == Data(count: 4))
    }

    /// ipad1_kboot.fill_dt's NAND geometry: every key a node has, on flash-controller0 (iBoot-1219, 5.x: with
    /// ce-bitmap, which AppleIOPFMI-49 spins on when empty) and on its disk child (4.x).
    @Test func nandGeometryOn5xNodes() throws {
        let blob = Self.deviceTree(armIO: [
            Self.node(
                [("name", Data("flash-controller0\0".utf8)), ("#ce", Self.z(4)), ("ce-bitmap", Self.z(4))],
                [Self.node([("name", Data("disk\0".utf8)), ("#ce", Self.z(4)), ("#databus", Self.z(4))])]
            )
        ])
        let img = try KBoot.build(kernel: Self.kernel(at: 0x8000_0000), deviceTree: blob, identity: Self.placeholder)
        let r0 = Int(img.bootArgsPA - img.loadPA)
        let vbase = Self.u32(img.image, r0 + 4)
        let dtp = Int(Self.u32(img.image, r0 + 0x30) - vbase)
        let dtlen = Int(Self.u32(img.image, r0 + 0x34))
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
        #expect(
            dt.props["chosen/memory-map"]?["X"] != nil && dt.props["chosen/memory-map"]?["MemoryMapReserved-0"] == nil
        )
        #expect(try DeviceTree(dt.data).value("chosen/memory-map", "X") == Data(count: 8))
        #expect(throws: FirmwareError.self) { try DeviceTree(Self.dtBlob + Data(count: 4)) }
    }

    /// ipad1_kboot.boot_args_version: the kernel's own `ldrh r3, [r0, #2]; cmp r3, #3` before the Epoch Mismatch literal.
    @Test func bootArgsVersion() throws {
        var k = Self.kernel(at: 0x8000_0000)
        #expect(try MachO(k).bootArgsVersion() == 2)  // no check in the kernel: 3.2.x / 4.2.1 / 4.3.0 shape
        let s = Data("pe_identify_machine: Epoch Mismatch\0".utf8)
        k.replaceSubrange(0x100..<0x100 + s.count, with: s)
        k.replaceSubrange(0x200..<0x204, with: Data([0x43, 0x88, 0x03, 0x2B]))  // ldrh r3, [r0, #2]; cmp r3, #3
        // the string's VA in the literal pool
        k.replaceSubrange(0x210..<0x214, with: DeviceTree.Value.le([0x8000_1100]))
        #expect(try MachO(k).bootArgsVersion() == 3)
        let img = try KBoot.build(kernel: k, deviceTree: Self.dtBlob, identity: Self.placeholder)
        #expect(
            img.image[Int(img.bootArgsPA - img.loadPA)..<Int(img.bootArgsPA - img.loadPA) + 4] == Data([1, 0, 3, 0])
        )
    }

    /// iOS 6 (xnu-2107): the string named by movw/movt + add pc instead of a literal (ipad1_kboot.boot_args_version).
    @Test func bootArgsVersionPCRelative() throws {
        var k = Self.kernel(at: 0x8000_0000)
        let s = Data("pe_identify_machine: Epoch Mismatch\0".utf8)
        k.replaceSubrange(0x100..<0x100 + s.count, with: s)
        // ldrh r3, [r0, #2]; cmp r3, #3; beq; movw r1, #0xfeee; movt r1, #0xffff; add r1, pc  (0x8000120e + 4 - 0x112 = string)
        k.replaceSubrange(
            0x200..<0x210,
            with: Data([
                0x43, 0x88, 0x03, 0x2B, 0x00, 0xD0, 0x4F, 0xF6, 0xEE, 0x61,
                0xCF, 0xF6, 0xFF, 0x71, 0x79, 0x44
            ])
        )
        #expect(try MachO(k).bootArgsVersion() == 3)
        k[0x20E] = 0x7A  // add r2, pc: lands nowhere
        #expect(try MachO(k).bootArgsVersion() == 2)
    }

    /// xnu-2107 (iOS 6) names the string with movw/movt/add rX, pc after the pair, not through a literal.
    @Test func bootArgsVersionMovwMovt() throws {
        var k = Self.kernel(at: 0x8000_0000)
        let s = Data("pe_identify_machine: Epoch Mismatch\0".utf8)
        k.replaceSubrange(0x100..<0x100 + s.count, with: s)  // VA 0x8000_1100
        func movw(_ top: Bool, _ rd: UInt16, _ imm: UInt16) -> Data {
            let hw1 = (top ? 0xF2C0 : 0xF240) | ((imm >> 11) & 1) << 10 | (imm >> 12)
            let hw2 = ((imm >> 8) & 7) << 12 | rd << 8 | (imm & 0xFF)
            return Data([UInt8(hw1 & 0xFF), UInt8(hw1 >> 8), UInt8(hw2 & 0xFF), UInt8(hw2 >> 8)])
        }
        let addAt = 0x20E
        let pc = UInt32(0x8000_1000 + addAt + 4)
        let delta = UInt32(0x8000_1100) &- pc
        let code =
            Data([0x43, 0x88, 0x03, 0x2B, 0x00, 0xBF])  // ldrh r3, [r0, #2]; cmp r3, #3; nop
            // add r0, pc
            + movw(false, 0, UInt16(delta & 0xFFFF)) + movw(true, 0, UInt16(delta >> 16)) + Data([0x78, 0x44])
        k.replaceSubrange(0x200..<0x200 + code.count, with: code)
        #expect(try MachO(k).bootArgsVersion() == 3)
        k[0x203] = 0x2C  // cmp r4: not the loaded register
        #expect(try MachO(k).bootArgsVersion() == 2)
    }

    /// The real kernels, where present (asset dirs): 4.2.1 2, 5.1.1 3, 6.0 3 (the movw/movt shape), 7.1.2 2 (no check).
    @Test func bootArgsVersionRealKernels() throws {
        let files = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/qemu-ios-files")
        for (rel, want) in [("n90/dec", 2), ("n90/9B206/dec", 3), ("n81/10A403/dec", 3), ("n90/11D257/dec", 2)] {
            let url = files.appendingPathComponent(rel + "/kernelcache.mach")
            guard let k = try? Data(contentsOf: url) else { continue }
            #expect(try MachO(k).bootArgsVersion() == UInt8(want), "\(rel)")
        }
    }

    /// chosen/nvram-proxy-data: the empty image's headers match the K48 NOR's common/free banks.
    @Test func nvramImage() {
        let img = KBoot.nvramImage(size: 8192)
        #expect(img.count == 8192)
        #expect(img.prefix(16) == Data([0x70, 0x7C, 0x80, 0x00]) + Data("common".utf8) + Data(count: 6))
        #expect(img[0x800..<0x804] == Data([0x7F, 0xA4, 0x80, 0x01]))
    }

    @Test func iBootVersion() {
        #expect(KBoot.ibootVersion(Data("xxiBoot-xiBoot-817.29.\0".utf8)) == "iBoot-817.29")
        #expect(KBoot.ibootVersion(Data("iBoot-931.71.16 ".utf8)) == "iBoot-931.71.16")
        #expect(KBoot.ibootVersion(nil) == "iBoot-817.29" && KBoot.ibootVersion(Data("none".utf8)) == "iBoot-817.29")
    }

    // Recorded digests: sha256 of `ipad1_kboot.py --identity ID [--ramdisk DEC/<UpdateRamDisk>-ramdisk.dmg] DEC OUT` at qemu-ios
    // ipad1 5e4ab3e6bf (enable-hsic=1), DEC = ipad1_fw.py's output, ID = UnitIdentity.synthesize("ipad1-7B500-default")
    // (IdentityTests' sha 4d3799...), whose die-id now follows ff331e1ef9's ECID-derived words, as the DT's
    // chosen/die-id shows.
    static let recorded: [(String, String, String, String)] = [
        (
            "k48ap-7B500", "018-8374-001-ramdisk.dmg",
            "0a61765e96e1b0b517206d89d9bad8e0e037d72cbda011696214bf6fa4f63a90",
            "3b2d402061379132be46283a335bcaf079179088a57ebdf622d968c719ed09b2"
        ),
        (
            "k48ap-8C148", "038-0024-002-ramdisk.dmg",
            "1c3e0d521e23a951c30c35ff0f306767468d5bec25bfdcf0fbd68ff79e42719c",
            "bddd3c67d79efa9747a4ac12f0080b477f21c17a78d96a76800ad0c4aa1d420b"
        ),
        (
            "k48ap-7B367", "018-7225-009-ramdisk.dmg",
            "2bad2b498e7fca57f32f747fd2bf274681f1d008dd06a5fd9c165b191f56c6be",
            "a68995bb8b64a8f646834dbfb89cbec088cfd2386ef47bc30be8898d6c00c7b8"
        )
    ]

    /// The whole Swift chain (IPSW -> FirmwareDecryptor -> KBoot) against kboot.bin's recorded digests: the Swift chain's own,
    /// whose iPad rows boot (the Python chain's went stale with the 10-08 identity changes).
    @Test(
        .enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"),
        arguments: recorded
    ) func kbootMatchesRecordedDigests(id: String, ramdisk: String, normal: String, rdMode: String) throws {
        guard Oracle.firmware(id).available else { try FixtureRequirements.missing("cached IPSW for " + id) }
        try Oracle.withTemp { dir in
            let dec = dir.appendingPathComponent("dec")
            _ = try FirmwareDecryptor.decrypt(
                ipsw: Oracle.firmware(id).ipsw,
                entry: Oracle.entry(id),
                into: dec,
                rootfs: false
            )
            let ident = try UnitIdentity.synthesize(seed: "ipad1-7B500-default")
            let a = dir.appendingPathComponent("kboot.bin")
            let b = dir.appendingPathComponent("kboot-rd.bin")
            try Oracle.time("kboot \(id)") { try KBoot.write(decrypted: dec, to: a, identity: ident) }
            try KBoot.write(decrypted: dec, to: b, identity: ident, ramdisk: dec.appendingPathComponent(ramdisk))
            #expect(try Oracle.sha256(file: a) == normal)
            #expect(try Oracle.sha256(file: b) == rdMode)

            // The DT's secure-root-prefix is the IPSW's, in both modes.
            let src = try DeviceTree(Data(contentsOf: dec.appendingPathComponent("DeviceTree.bin")))
            #expect(src.value("", "secure-root-prefix")?.prefix(3) == Data("md\0".utf8))
            for f in [a, b] {
                let bin = try Data(contentsOf: f)
                let trailer = bin.suffix(24)
                #expect(trailer.prefix(8) == Data("K48KBOOT".utf8))
                let t = [UInt8](trailer)
                let args = Int(t.u32(16) - t.u32(8))
                let vbase = Self.u32(bin, args + 4)
                let dtp = Int(Self.u32(bin, args + 0x30) - vbase)
                let dtlen = Int(Self.u32(bin, args + 0x34))
                let built = try DeviceTree(bin[dtp..<dtp + dtlen])
                #expect(built.value("", "secure-root-prefix") == src.value("", "secure-root-prefix"))
            }
        }
    }
}

private func * (a: [UInt8], n: Int) -> [UInt8] { (0..<n).flatMap { _ in a } }

extension [UInt8] {
    /// The little-endian word at `at` of an image a test built or a corpus file it checked.
    func u32(_ at: Int) -> UInt32 {
        UInt32(self[at]) | UInt32(self[at + 1]) << 8 | UInt32(self[at + 2]) << 16 | UInt32(self[at + 3]) << 24
    }
}
