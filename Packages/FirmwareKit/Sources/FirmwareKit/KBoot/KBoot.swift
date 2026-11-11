// KBoot: the ipad1 machine's direct-kernel boot bundle, kboot.bin: what iBoot-817.29 does before it jumps
// to xnu. A port of ipad1_kboot.py (build, fill_dt, logo, main); the byte layout is documented there.
//
//   let ident = try UnitIdentity.synthesize(seed: seed)
//   try KBoot.write(decrypted: decDir, to: kbootURL, identity: ident)                // normal boot
//   try KBoot.write(decrypted: decDir, to: kbootURL, identity: ident, ramdisk: rd)   // md0 RAM-disk root
//   let img = try KBoot.build(kernel: mach, deviceTree: dt, identity: ident, iboot: v, ramdisk: nil)
//   KBoot.bundle(img, segments: logo)          // image + K48SEG segments + K48KBOOT trailer
//   KBoot.ibootVersion(iBootBin)               // chosen/firmware-version: "iBoot-N.N" out of the decrypted iBoot
//   try MachO(kernel).segments / .entry        // LC_SEGMENT list, LC_UNIXTHREAD pc
//
// decrypted: a FirmwareDecryptor output directory (kernelcache.mach, DeviceTree.bin, iBoot.bin, AppleLogo.bin).
// The kernel virtual base is the kernelcache's own link base (0xC0000000 on 3.x, 0x80000000 on 4.x).
// RAM-disk mode puts the image after the kernel, adds chosen/memory-map RAMDisk, appends rd=md0 and empties
// chosen/root-matching; the DT's own secure-root-prefix is left as the IPSW has it, so md0 is a SecureRoot.
// What differs per A4 board is a KBoot.Board, picked from the DT's own compatible (ipad1_kboot.BOARDS): K48's
// landscape panel (display-rotation 270, 4.x lays its UI out by it) or N81's portrait Retina one. A board without
// the SPI NOR (N81: boot-from-nand) gets K48's 4.x nor-flash subtree grafted in (graftNOR). The S5L8920 family
// (s5l8920_kboot.py) is Boards too: the iPhone 3GS (N88, -M n88) and the S5L8922 iPod touch 3G (N18, -M n18), each
// with its own platform-name/chip-id, a 320x480 panel and the iPad's clock table cut to its DT's 32 slots; N18 gets
// the NOR graft, N88 keeps its own NOR and has its baseband node's identity filled with test values.

import BinaryParsing
import Foundation
import HostRuntime

public enum KBoot {
    public static let physBase: UInt32 = 0x4000_0000, dramSize: UInt32 = 0x1000_0000
    public static let pramSize: UInt32 = 0x4000, vramSize: UInt32 = 0x90_0000 - 0x4000
    public static let memSize = dramSize - pramSize - vramSize
    public static let vramPA = physBase + memSize, pramPA = physBase + dramSize - pramSize
    public static let fbWidth = 1024, fbHeight = 768, fbDepth = 32
    /// ipad1_kboot.DEFAULT_BOOT_ARGS. enable-hsic=1: 4.x's AppleS5L8930XUSBArbitrator::handleStart publishes the
    /// USB host nubs for the DT's hsic-enabled only when this boot-arg is 1 (no USB keyboard without it); 3.x ignores it.
    /// serial=3 debug=0x8 stay, though a real unit boots without them: they are the whole serial log (no byte of it
    /// without them), which prepare's one-shots read their markers from (FTL_Open, it_seal, it_keybag), the app's boot
    /// stages and Device Console show, and diagnostics carry a panic in. Dropping them gains nothing measurable: an
    /// n90ap-8C148 boot lit at the same time with and without them, three paired runs.
    public static let defaultBootArgs =
        "serial=3 debug=0x8 amfi_allow_any_signature=1 cs_enforcement_disable=1 enable-hsic=1"
    public static let defaultIBootVersion = "iBoot-817.29"
    public static let rootMatching =
        "<dict><key>IOProviderClass</key><string>IOMedia</string><key>IOPropertyMatch</key>"
        + "<dict><key>Partition ID</key><integer>1</integer></dict></dict>"
    // The A6 PPN disk uses LwVM: the System filesystem is a child of the
    // outer partition. Matching Partition ID 1 can select that parent media.
    static let a6RootMatching =
        "<dict><key>IOProviderClass</key><string>IOMedia</string><key>IOPropertyMatch</key>"
        + "<dict><key>BSD Name</key><string>disk0s1s1</string></dict></dict>"

    // Measured on a real iPad 1 running 7B500: cpu/memory 0, bus/peripheral 100 MHz, fixed/timebase 24 MHz.
    static let cpuHz: UInt32 = 0, memHz: UInt32 = 0, busHz: UInt32 = 100_000_000, periphHz: UInt32 = 100_000_000
    static let fixedHz: UInt32 = 24_000_000, timebaseHz: UInt32 = 24_000_000, usbphyHz: UInt32 = 24_000_000
    /// /arm-io/audio-complex ncoref-frequency (S5L8920/8922 only): PLL1's 162 MHz, as iBoot fills it.
    static let ncorefHz = PreparedDeviceBoot.ncorefHz
    static let clocks: [UInt32] = {
        var c = [UInt32](repeating: periphHz, count: 55)
        for (i, hz) in [0: timebaseHz, 5: cpuHz, 6: periphHz, 27: memHz, 32: busHz, 33: fixedHz] { c[i] = hz }
        return c
    }()
    /// A real iPad's clock-frequencies on 3.2.2 (iBoot-817), slot for slot: the PLLs (1 APLL 1 GHz, 3 EPLL 1026 MHz),
    /// the performance clocks, FMI's 102.6 MHz (33), the panel's 68.4 MHz pixel clock (39), the SPI (47-51) and I2C
    /// (52-54) references; but slot 44, which 3.x's iBoot-817 sets to 24 MHz and 4.x's iBoots leave 0 (the iPad's
    /// 931, the iPhone 4's 1072). iBoot on the emulated PMGR fills the same table (KBootIBootTests). The slots are the
    /// same in every A4 DeviceTree (the nodes' clock-ids), so one table serves all releases.
    static let k48Clocks: [UInt32] = [
        24_000_000, 1_000_000_000, 0, 1_026_000_000, 0, 0, 0, 1_000_000_000, 0, 1_000_000_000,
        200_000_000, 102_600_000, 1_026_000_000, 166_666_666, 68_400_000, 200_000_000, 100_000_000, 0, 102_600_000,
        51_300_000, 200_000_000, 48_857_142, 0, 2_000_000, 342_000_000, 0, 200_000_000, 100_000_000, 200_000_000,
        166_666_666, 200_000_000, 171_000_000, 100_000_000, 102_600_000, 100_000_000, 100_000_000, 68_400_000,
        54_000_000, 0, 68_400_000, 342_000_000, 51_300_000, 0, 51_300_000, 0, 0, 12_000_000, 24_000_000,
        24_000_000, 24_000_000, 24_000_000, 24_000_000, 1_000_000, 1_000_000, 1_000_000
    ]
    /// A real iPhone 4's on 4.3 (iBoot-1072.58): the iPad's but for its 800 MHz APLL (1, 7, 9), MPLL at 500 MHz (2),
    /// 160 MHz for 166.67 (13, 29), 51.3 MHz for 68.4 (14, 36) and 48.86 MHz in 49.
    static let n90Clocks: [UInt32] = {
        var c = k48Clocks
        for (i, hz) in [
            1: 800_000_000, 2: 500_000_000, 7: 800_000_000, 9: 800_000_000, 13: 160_000_000, 14: 51_300_000,
            29: 160_000_000, 36: 51_300_000, 49: 48_857_142
        ] as [Int: UInt32] { c[i] = hz }
        return c
    }()
    /// What iBoot fills the same on every A4 board: the iPad's 3.2.2 and 4.2.1 iBoots (817, 931) under the emulator,
    /// and the real iPad (3.2.2) and iPhone 4 (4.3): arm-io/pmgr's bridge-settings (the fabric bridges' settings, the
    /// first 168 of its 256 bytes) and otgphyctrl's phy-tuning-val. arm-io/pmgr/device-clocks is not one of them:
    /// iBoot hands the IPSW's candidate parents over and the kernel settles them (KBootIBootTests).
    static let a4BridgeSettings =
        Data(hexLiteral: "000000000c0f0000040000000c0f00000c0401000101000100000000000000000000020008020000")
        + Data(hexLiteral: "040002000206000008000200020600000c000200020600000c040300000100000c04030001010001")
        + Data(hexLiteral: "0c040300020100020c040300040100040c040300050100050c040300060100060c04030007010007")
        + Data(hexLiteral: "0804030003010003000000000000000000000400000c000004000400001000000800040004040000")
        + Data(hexLiteral: "0804050002010002")
    static let a4PHYTuning: UInt32 = 0x733

    /// NAND geometry and timings as iBoot probes the emulated flash (16 GB, eight Hynix dies; iBoot-817's and
    /// iBoot-931's values for its read ID, KBootIBootTests); only the keys the DT has are written.
    static let nand: [(String, UInt32)] = [
        ("#ce", 8), ("#die-ce", 1), ("#ce-blocks", 0x1000), ("#block-pages", 128), ("#page-bytes", 4096),
        ("#spare-bytes", 0x80), ("device-readid", 0xB614_D5AD), ("vendor-type", 0x10_0014), ("#databus", 2),
        ("ecc-correctable", 16), ("ecc-threshold", 12), ("bbt-format", 3),
        ("read-cycle-ns", 25), ("read-setup-ns", 12), ("read-hold-ns", 10), ("read-delay-ns", 20),
        ("read-valid-ns", 15), ("write-cycle-ns", 25), ("write-setup-ns", 12), ("write-hold-ns", 10),
        // 4.x DTs time the bus in clocks.
        ("read-setup-clks", 1), ("read-hold-clks", 1), ("read-dccycle-clks", 1), ("write-setup-clks", 1),
        ("write-hold-clks", 1),
        ("meta-per-logical-page", 12), ("valid-meta-per-logical-page", 10), ("logical-page-size", 4096),
        ("ppn-device", 0),
        // iBoot-1219 (5.x): the populated CEs numbered across the buses (bus b's at 8b + n); AppleIOPFMI-49's
        // _fmiInitVirtToPhysMap loops forever on an empty one. 4 CEs on each of 2 buses.
        ("ce-bitmap", 0x0F0F)
    ]
    /// A pair of Hynix PPN packages, with two CAUs per package. The IPSW
    /// contains empty slots for iBoot's probed storage identity.
    static let a6PPN: [(String, UInt32)] = [
        ("#ce", 2), ("#die-ce", 2), ("#ce-blocks", 2128), ("#block-pages", 256),
        ("#page-bytes", 16384), ("#spare-bytes", 64), ("#databus", 2),
        // The native request structure has 128 physical-page slots per bank.
        ("max-transaction-size", 128),
        ("ce-bitmap", 0x101), ("ppn-device", 1), ("ppn-spec-version", 0x10505),
        ("ppn-ftl-ver", 2), ("caus-ce", 2), ("blocks-cau", 1064),
        ("cau-bits", 4), ("block-bits", 11), ("page-bits", 8),
        ("mlc-pages", 256), ("slc-pages", 128), ("toggle-device", 1),
        ("logical-page-size", 4096), ("meta-per-logical-page", 16),
        ("valid-meta-per-logical-page", 16), ("metadata-whitening", 0),
        ("read-setup-clks", 1), ("read-hold-clks", 1), ("read-dccycle-clks", 1),
        ("write-setup-clks", 1), ("write-hold-clks", 1)
    ]
    /// The nodes the geometry goes in: iBoot-1219 DTs carry it on flash-controller0 itself as well as on its disk.
    static let nandNodes = ["arm-io/flash-controller0", "arm-io/flash-controller0/disk"]
    static let model = [("model-number", "MB292"), ("region-info", "LL/A")]

    /// One kboot board: what iBoot would put in its DT. (The machine that runs it is the emulator's: DeviceInfo.)
    public struct Board: Equatable, Sendable {
        public var fbWidth: Int, fbHeight: Int
        public var rotation: UInt32, scale: UInt32, boardID: UInt32
        public var modelNumber: String
        /// DRAM bytes: memSize, vram and pram sit at its top, as iBoot puts them.
        public var dram: UInt32 = KBoot.dramSize
        public var physicalBase: UInt32 = KBoot.physBase
        /// A radio board (N90) keeps its baseband node; the machine's `baseband` property unmatches it at boot.
        public var radio = false
        /// The machine answers the Bluetooth HCI on the UART the DT hangs the board's bluetooth node off (qemu-ios
        /// bt_uart: ipod_touch_bt.c's H4 controller), so the preparation keeps BTServer (SystemEdits.Options.bluetooth).
        /// Without it, BTServer is disabled: BlueTool's HCI_Reset would never complete. The A4 boards' UART is silent:
        /// their serial driver reads it through CDMA v2's pause-and-resume, which qemu-ios doesn't model yet.
        public var bluetoothHCI = false
        /// The SoC as iBoot names it (root platform-name, chosen/chip-id).
        public var platformName = "s5l8930x", chipID: UInt32 = 0x8930
        /// /product/product-id, which iBoot fills and the IPSW DT reserves zeroed (6.x MobileGestalt's product hash).
        /// 6.x GraphicsServices picks the font cache by it: the 3GS's (compared at GSFontInitialize) selects
        /// CGFontCacheUR.plist, the only set its rootfs ships fonts for; zeroed, the default plist names fonts the 3GS
        /// IPSW lacks and every UIFont and bitmap context comes back nil. nil: leave the slot alone.
        public var productID: [UInt8]? = nil
        /// arm-io/clock-frequencies (cut to the DT's slots): the iPad's measured cpu0 rates in every slot, unless the
        /// board's own were read off a real unit.
        public var clocks: [UInt32] = KBoot.clocks
        /// arm-io/i2c0/pmu swi-vcores, the CPU's two core voltages in mV, and arm-io/clcd dot-pitch, the panel's pixels
        /// per inch, as iBoot fills them: the iPad's from its iBoot (on the emulator and the real unit), the iPhone 4's
        /// from the real unit (nil: the IPSW's zeros).
        public var swiVcores: [UInt32]? = nil
        public var dotPitch: UInt32? = nil
        /// arm-io/chip-revision (the A4 stepping: 0x11, B1, on the iPad; 0x20 on the iPhone 4).
        public var chipRevision: UInt32 = 0x11
        /// The panel as iBoot's pinot_init reads it: lcd-panel-id, raw-panel-id's bytes, and the backlight-id that
        /// picks AppleARMBacklight's device-specific brightness table (nil: the IPSW's 0xffffffff, the default table).
        public var panelID: UInt32 = 0x00A1_D13C
        public var rawPanelID: [UInt8]? = nil
        public var backlightID: UInt32? = nil

        public static let k48 = Board(
            fbWidth: 1024,
            fbHeight: 768,
            rotation: 270,
            scale: 1,
            boardID: 0x02,
            modelNumber: "MB292",
            clocks: KBoot.k48Clocks,
            swiVcores: [950, 1150],
            dotPitch: 132,
            panelID: 0xA1E5_06C9,
            rawPanelID: [0xA1, 0xE5, 0x69, 0x09, 0, 0, 0, 0, 0, 0, 0, 0, 0x64],
            backlightID: 6
        )
        public static let n81 = Board(
            fbWidth: 640,
            fbHeight: 960,
            rotation: 0,
            scale: 2,
            boardID: 0x08,
            modelNumber: "MC540"
        )
        public static let n90 = Board(
            fbWidth: 640,
            fbHeight: 960,
            rotation: 0,
            scale: 2,
            boardID: 0x00,
            modelNumber: "MC603",
            dram: 0x2000_0000,
            radio: true,
            clocks: KBoot.n90Clocks,
            swiVcores: [950, 1050],
            dotPitch: 326,
            chipRevision: 0x20,
            panelID: 0xA18A_05C8,
            rawPanelID: [0xA1, 0x8A, 0x58, 0x09, 0x07],
            backlightID: 5
        )
        /// iPhone 5 (A6/Swift): its own kernel, DT, memory map and native panel.
        public static let n42 = Board(
            fbWidth: 640, fbHeight: 1136, rotation: 0, scale: 2,
            boardID: 0x02, modelNumber: "MD299", dram: 0x4000_0000,
            physicalBase: 0x8000_0000, radio: true,
            platformName: "s5l8950x", chipID: 0x8950,
            clocks: [UInt32](repeating: 24_000_000, count: 512),
            dotPitch: 326, chipRevision: 0x20
        )
        /// iPhone 3GS (S5L8920): -M n88, model MB715. Its baseband node is unmatched (no modem model yet).
        public static let n88 = Board(
            fbWidth: 320,
            fbHeight: 480,
            rotation: 0,
            scale: 1,
            boardID: 0x00,
            modelNumber: "MB715",
            bluetoothHCI: true,
            platformName: "s5l8920x",
            chipID: 0x8920,
            productID: [
                0x87, 0x84, 0xae, 0x8d, 0x70, 0x66, 0xb0, 0xf0, 0x13, 0x6b,
                0xe9, 0x1d, 0xcf, 0xe6, 0x32, 0xa4, 0x36, 0xff, 0xd6, 0xfb
            ]
        )
        /// iPod touch 3G (S5L8922): -M n18, model MC008; NOR-less, so it takes the graft.
        public static let n18 = Board(
            fbWidth: 320,
            fbHeight: 480,
            rotation: 0,
            scale: 1,
            boardID: 0x02,
            modelNumber: "MC008",
            bluetoothHCI: true,
            platformName: "s5l8922x",
            chipID: 0x8922
        )
        /// The S5L8920 family (-M n18, n88): no metadata whitening in its DTs, the IPSW's NAND epoch, no USB host.
        public var isS5L8920: Bool { chipID == 0x8920 || chipID == 0x8922 }
        public var isA6: Bool { chipID == 0x8950 }
        var wifiDTNode: String { isA6 ? "wlan" : "arm-io/sdio" }

        /// From the DT's compatible ("N81AP\0iPod4,1\0AppleARM" -> n81); K48 otherwise.
        public static func of(_ dt: DeviceTree) -> Board {
            let first = dt.value("", "compatible").map { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } ?? ""
            return ["N81AP": .n81, "N90AP": .n90, "N88AP": .n88, "N18AP": .n18, "N42AP": .n42][first] ?? .k48
        }

        var memSize: UInt32 { dram - KBoot.pramSize - KBoot.vramSize }
        var vramPA: UInt32 { physicalBase + memSize }
        /// iBoot puts the A4's PRAM at the top of its 512 MiB DRAM window whatever the DRAM (0x5fffc000 on the
        /// 256 MiB iPad too, where the window mirrors DRAM); the S5L8920's at the top of its DRAM.
        var pramPA: UInt32 { physicalBase + ((isS5L8920 || isA6) ? dram : 0x2000_0000) - KBoot.pramSize }
    }

    /// K48's 4.x (8C148) spi0/nor-flash subtree: diagnostics, nvram, the image area and effaceable storage
    /// (ipad1_kboot.NOR_GRAFT). Phandles are K48's.
    static let norGraft: [(String, String, [(String, DeviceTree.Value)])] = [
        (
            "arm-io/spi0", "nor-flash",
            [
                ("compatible", .string("nor-flash,spi")), ("#address-cells", .u32(1)),
                ("device_type", .string("nor-flash")), ("#size-cells", .u32(1)),
                ("ranges", .words([0, 0, 0x10_0000])), ("reg", .words([0, 0x53, 0x0801_0000, 0, 0, 0, 0, 0])),
                ("AAPL,phandle", .u32(0x0091_70E0))
            ]
        ),
        (
            "arm-io/spi0/nor-flash", "diagnostic-data",
            [
                ("compatible", .string("diagnostic-data,format1")),
                ("device_type", .string("diagnostic-data")),
                ("reg", .words([0x6000, 0x2000, 0x4000, 0x2000])), ("AAPL,phandle", .u32(0x0091_74F0))
            ]
        ),
        (
            "arm-io/spi0/nor-flash", "nvram",
            [
                ("compatible", .string("nvram,chrp")), ("device_type", .string("nvram")),
                ("reg", .words([0xF_C000, 0x2000, 0xF_E000, 0x2000])), ("AAPL,phandle", .u32(0x0091_7880))
            ]
        ),
        (
            "arm-io/spi0/nor-flash", "raw-device",
            [
                ("compatible", .string("raw-device,non-nvram")), ("device_type", .string("raw-device")),
                ("reg", .words([0x8000, 0xF_2000, 0, 0x1000])), ("AAPL,phandle", .u32(0x0091_7860))
            ]
        ),
        (
            "arm-io/spi0/nor-flash", "effaceable",
            [
                ("compatible", .string("effaceable,nor")), ("device_type", .string("effaceable")),
                ("reg", .words([0xF_A000, 0x1000, 0xF_B000, 0x1000])), ("AAPL,phandle", .u32(0x0091_7F70))
            ]
        )
    ]

    /// A NOR-less board: graft the NOR in. Either way take the NAND off boot duty (the N88 has its own NOR
    /// and the property too): the kernel keys off boot-from-nand's presence, not its value
    /// (IOFlashStorageDevice then hunts NAND boot blocks and the FTL never finds root); the editor cannot
    /// delete, so rename it.
    static func graftNOR(_ dt: inout DeviceTree) throws {
        guard dt.contains("arm-io/spi0") else { return }
        if !dt.contains("arm-io/spi0/nor-flash") {
            for (parent, name, props) in norGraft { try dt.addNode(parent, name, props) }
        }
        try landingMap(&dt)
        if dt.props["arm-io/flash-controller0/disk"]?["boot-from-nand"] != nil {
            try dt.rename("arm-io/flash-controller0/disk", "boot-from-nand", "boot-from-nor")
        }
    }

    /// 3.x's FMI groups the CEs into buses by the disk node's landing-map words, one CE mask per bus (3.1.3
    /// findNandInfo); the IPSW's DT has a single word, so every CE folds into one bus and its board table has no match
    /// ("2-bus not supported"). One word per populated bus from the disk's CE bitmap (reg), as s5l8920_kboot.py does;
    /// DTs without landing-map (4.x on) are untouched.
    static func landingMap(_ dt: inout DeviceTree) throws {
        let disk = "arm-io/flash-controller0/disk"
        guard dt.props[disk]?["landing-map"] != nil, let reg = dt.value(disk, "reg"), reg.count >= 4 else { return }
        let ces = try MachO.u32(reg, 0)
        let words = (0..<4).map { ces & (0xFF << (8 * UInt32($0))) }.filter { $0 != 0 }
        try dt.rename(disk, "landing-map", "landing-map-dt")
        try dt.add(disk, "landing-map", DeviceTree.Value.le(words))
    }

    public struct Segment: Equatable, Sendable {
        public var pa: UInt32, length: UInt32
        /// nil: zero-fill.
        public var data: Data?
        public init(pa: UInt32, length: UInt32, data: Data?) {
            self.pa = pa
            self.length = length
            self.data = data
        }
    }

    public struct Image: Sendable {
        public var image: Data
        public var loadPA: UInt32, entryPA: UInt32, bootArgsPA: UInt32
    }

    /// The first "iBoot-N(.N)*" in a decrypted iBoot, else the default.
    public static func ibootVersion(_ iboot: Data?) -> String {
        guard let b = iboot.map([UInt8].init) else { return defaultIBootVersion }
        let tag = Array("iBoot-".utf8)
        let digit = { (c: UInt8) in c >= 0x30 && c <= 0x39 }
        var i = 0
        while i + tag.count < b.count {
            if b[i] == tag[0], b[i..<i + tag.count].elementsEqual(tag), digit(b[i + tag.count]) {
                var j = i + tag.count
                while j < b.count, digit(b[j]) { j += 1 }
                while j + 1 < b.count, b[j] == 0x2E, digit(b[j + 1]) {
                    j += 1
                    while j < b.count, digit(b[j]) { j += 1 }
                }
                return String(decoding: b[i..<j], as: UTF8.self)
            }
            i += 1
        }
        return defaultIBootVersion
    }

    /// (root props, chosen props, {node: local-mac-address}) for an identity.
    static func identityDT(_ id: UnitIdentity, board: Board = .k48) throws -> (
        [(String, DeviceTree.Value)], [(String, DeviceTree.Value)], [(String, Data)]
    ) {
        func need(_ k: String) throws -> String {
            guard let v = id[k] else { throw FirmwareError(.unsupported, "identity: missing \(k)") }
            return v
        }
        func hex(_ s: String) throws -> UInt64 {
            let t = s.lowercased().hasPrefix("0x") ? String(s.dropFirst(2)) : s
            guard let v = UInt64(t, radix: 16) else { throw FirmwareError(.unsupported, "identity: \(s) is not hex") }
            return v
        }
        func mac(_ s: String) throws -> Data {
            guard let d = Data(hex: s.replacingOccurrences(of: ":", with: "")) else {
                throw FirmwareError(.unsupported, "identity: bad MAC \(s)")
            }
            return d
        }
        let ecid = try hex(need("unique-chip-id"))
        guard let die = id.dieID, die.count == 2 else { throw FirmwareError(.unsupported, "identity: missing die-id") }
        let dieWords = try die.map { w -> UInt32 in
            let v = try hex(w)
            guard v <= UInt32.max else {
                throw FirmwareError(.unsupported, "identity: die-id word \(w) is over 32 bits")
            }
            return UInt32(v)
        }
        guard ecid >> 32 <= UInt32.max else {
            throw FirmwareError(.unsupported, "identity: unique-chip-id over 64 bits")
        }
        let root: [(String, DeviceTree.Value)] =
            [
                ("serial-number", .string(try need("serial-number"))),
                ("mlb-serial-number", .string(try need("mlb-serial-number")))
            ]
            + model.map { k, v in (k, .string(id[k] ?? (k == "model-number" ? board.modelNumber : v))) }
        let chosen: [(String, DeviceTree.Value)] = [
            ("unique-chip-id", .words([UInt32(ecid & 0xFFFF_FFFF), UInt32(ecid >> 32)])),
            ("die-id", .words(dieWords))
        ]
        // Bluetooth hangs off whichever UART the board wires it to (K48 uart3, N81 uart1): fillDT finds it.
        return (root, chosen, [(board.wifiDTNode, try mac(need("wifi-mac"))), ("bluetooth", try mac(need("bt-mac")))])
    }

    /// An empty NVRAM image as IODTNVRAM parses it (ipad1_kboot.nvram_image): CHRP partitions, a 2 KiB "common"
    /// (0x70), the rest "free" (0x7f). Each 16-byte header is sig, checksum, length in 16-byte units, 12-byte name;
    /// the checksum adds byte 0 and bytes 2-15 with end-around carry. A zeroed image is a zero-length partition,
    /// and initNVRAMImage loops on it forever.
    static func nvramImage(size: Int) -> Data {
        func part(_ sig: UInt8, _ name: String, _ units: Int) -> Data {
            var h =
                [sig, 0, UInt8(units & 0xFF), UInt8(units >> 8)] + Array(name.utf8)
                + [UInt8](repeating: 0, count: 12 - name.utf8.count)
            var c = UInt32(h[0])
            for x in h[2...] {
                c += UInt32(x)
                if c > 0xFF { c = (c & 0xFF) + 1 }
            }
            h[1] = UInt8(c)
            return Data(h) + Data(count: units * 16 - 16)
        }
        let common = 0x80
        return part(0x70, "common", common) + part(0x7F, "free", size / 16 - common)
    }

    static func fillDT(
        _ dt: inout DeviceTree,
        memoryMap: [(String, UInt32, UInt32)],
        identity: UnitIdentity,
        iboot: String,
        rootMatching: String
    ) throws {
        let board = Board.of(dt)
        let (root, chosen, macs) = try identityDT(identity, board: board)
        for (k, v) in [("platform-name", DeviceTree.Value.string(board.platformName))] + root { try dt.set("", k, v) }
        // debug-enabled 1, where a real unit has 0: the kernel honors the AMFI boot-args (amfi_allow_any_signature,
        // cs_enforcement_disable) only with it, and an n90ap-8C148 boot never lit with it 0.
        let flags: [(String, DeviceTree.Value)] = [
            "debug-enabled", "production-cert", "secure-boot", "gid-aes-key",
            "uid-aes-key", "system-trusted"
        ].map { ($0, .u32(1)) }
        for (k, v) in flags + [("board-id", .u32(board.boardID)), ("chip-id", .u32(board.chipID))] + chosen
            + [
                ("firmware-version", .string(iboot)), ("display-rotation", .u32(board.rotation)),
                ("display-scale", .u32(board.scale)),
                ("root-matching", .string(rootMatching))
            ]
        {
            // 3.1.3's DTs (N88 7E18) have none of these: nothing to fill.
            if ["die-id", "display-rotation", "display-scale"].contains(k), dt.props["chosen"]?[k] == nil { continue }
            try dt.set("chosen", k, v)
        }
        // iBoot-1537/1940 (6.x/7.x) hand NVRAM over as /chosen/nvram-proxy-data; the IPSW DT reserves it zeroed.
        if let slot = dt.props["chosen"]?["nvram-proxy-data"] {
            try dt.set("chosen", "nvram-proxy-data", .bytes(nvramImage(size: slot.length)))
        }
        // Every iBoot read so far (817, 931, the iPhone 4's 1072) leaves a BOOTREPLY header there, the rest zero.
        if dt.props["chosen"]?["bootp-response"]?.length ?? 0 > 0 {
            try dt.set("chosen", "bootp-response", .bytes(Data([2])))
        }
        if let id = board.productID, dt.props["product"]?["product-id"]?.length == id.count {
            try dt.set("product", "product-id", .bytes(Data(id)))
        }
        // iBoot-1940 also copies syscfg's MACs to /chosen; 7.x's MobileGestalt reads them there (and hashes them into the UDID).
        for (k, node) in [("mac-address-wifi0", board.wifiDTNode), ("mac-address-bluetooth0", "bluetooth")]
        where dt.props["chosen"]?[k] != nil {
            if let mac = macs.first(where: { $0.0 == node })?.1 { try dt.set("chosen", k, .bytes(mac)) }
        }
        for (k, hz) in [
            ("clock-frequency", cpuHz), ("memory-frequency", memHz), ("bus-frequency", busHz),
            ("peripheral-frequency", periphHz), ("fixed-frequency", fixedHz), ("timebase-frequency", timebaseHz)
        ] {
            for cpu in ["cpus/cpu0", "cpus/cpu1"] where dt.props[cpu]?[k] != nil {
                try dt.set(cpu, k, .u32(board.isA6 && k == "clock-frequency" ? 1_300_000_000 : hz))
            }
        }
        let slots = (dt.props["arm-io"]?["clock-frequencies"]?.length ?? board.clocks.count * 4) / 4
        try dt.set("arm-io", "clock-frequencies", .words(Array(board.clocks.prefix(slots))))
        try dt.set("arm-io", "usbphy-frequency", .u32(usbphyHz))
        if board.isA6,
            let template = dt.value("arm-io/pmgr", "voltage-states1"),
            template.allSatisfy({ $0 == 0 }),
            let nominal = dt.value("arm-io/pmgr", "nominal-performance1"),
            let boost = dt.value("arm-io/pmgr", "boost-performance1")
        {
            // The restore DT reserves the GPU domain's state table for iBoot.
            // Use its own declared nominal/boost levels, in the same 8-byte
            // performance/voltage format as the supplied CPU-domain table.
            // Voltage zero denotes the firmware default in this template.
            let states = nominal.prefix(4) + Data(count: 4) + boost.prefix(4) + Data(count: 4)
            try dt.set("arm-io/pmgr", "voltage-states1", .bytes(states))
        }
        if !board.isS5L8920 && !board.isA6 {
            if dt.props["arm-io/pmgr"]?["bridge-settings"]?.length ?? 0 >= a4BridgeSettings.count {
                try dt.set("arm-io/pmgr", "bridge-settings", .bytes(a4BridgeSettings))
            }
            if dt.props["arm-io/otgphyctrl"]?["phy-tuning-val"] != nil {
                try dt.set("arm-io/otgphyctrl", "phy-tuning-val", .u32(a4PHYTuning))
            }
        }
        if let mv = board.swiVcores, dt.props["arm-io/i2c0/pmu"]?["swi-vcores"] != nil {
            try dt.set("arm-io/i2c0/pmu", "swi-vcores", .words(mv))
        }
        if let ppi = board.dotPitch, dt.props["arm-io/clcd"]?["dot-pitch"] != nil {
            try dt.set("arm-io/clcd", "dot-pitch", .u32(ppi))
        }
        if dt.props["arm-io/audio-complex"]?["ncoref-frequency"] != nil {
            try dt.set("arm-io/audio-complex", "ncoref-frequency", .u32(ncorefHz))
        }
        if dt.contains("arm-io/sgx") { try dt.set("arm-io/sgx", "compatible", .string("none")) }  // no SGX model
        for (want, mac) in macs {
            let path = dt.props.keys.sorted().first { $0 == want || $0.hasSuffix("/" + want) } ?? want
            if dt.contains(path) { try dt.set(path, "local-mac-address", .bytes(mac)) }
        }
        if dt.contains("arm-io/mipi-dsim/lcd") {  // the panel id iBoot's pinot_init writes; the DSI model's reply
            // 3.0's DTs (N88 7A341) have no raw-panel-id slot
            let lcd = "arm-io/mipi-dsim/lcd"
            if dt.props[lcd]?["lcd-panel-id"] != nil { try dt.set(lcd, "lcd-panel-id", .u32(board.panelID)) }
            if dt.props[lcd]?["raw-panel-id"] != nil {
                try dt.set(lcd, "raw-panel-id", board.rawPanelID.map { .bytes(Data($0)) } ?? .u32(board.panelID))
            }
        }
        if let id = board.backlightID, dt.props["backlight"]?["backlight-id"] != nil {
            try dt.set("backlight", "backlight-id", .u32(id))
        }
        if dt.contains("baseband"), !board.radio {  // Wi-Fi iPad: no radio, so unmatch and unname the N82 baseband node
            for (k, v) in [("compatible", "none"), ("device_type", "none"), ("name", "nobb")] {
                try dt.set("baseband", k, .string(v))
            }
            // lockdownd still reads the node's identity (N88): GSMA's test IMEI and a placeholder serial, so nothing
            // passes for a real unit (s5l8920_kboot.py).
            if dt.props["baseband"]?["device-imei"] != nil {
                try dt.set("baseband", "device-imei", .string("004999010640000"))
                if dt.props["baseband"]?["snum"] != nil {  // 3.0's DT has none
                    try dt.set("baseband", "snum", .bytes(Data("TESTSNUM0000".utf8)))
                }
            }
        }
        if dt.props["arm-io"]?["chip-revision"] != nil {
            try dt.set("arm-io", "chip-revision", .u32(board.chipRevision))
        }
        for node in nandNodes {
            guard let props = dt.props[node] else { continue }
            for (k, v) in (board.isA6 ? a6PPN : nand) where props[k] != nil {
                try dt.set(node, k, .u32(v))
            }
            if board.isA6 && props["device-readid"] != nil {
                try dt.set(node, "device-readid", .bytes(Data([0x50, 0x50, 0x4e, 1, 5, 5, 0, 0])))
            }
        }
        try dt.set("pram", "reg", .words([board.pramPA, pramSize]))
        try dt.set("vram", "reg", .words([board.vramPA, vramSize]))
        for (i, (name, pa, size)) in memoryMap.enumerated() {
            try dt.rename("chosen/memory-map", "MemoryMapReserved-\(i)", name)
            try dt.set("chosen/memory-map", name, .words([pa, size]))
        }
    }

    /// The flat physical image, its load PA, entry PA and boot_args PA. `ramdisk`: raw HFS to boot as md0.
    public static func build(
        kernel: Data,
        deviceTree: Data,
        bootArgs: String = defaultBootArgs,
        identity: UnitIdentity,
        iboot: String = defaultIBootVersion,
        ramdisk: Data? = nil,
        rootDevice: String? = nil
    ) throws -> Image {
        let page = { (n: Int) in (n + 0xFFF) & ~0xFFF }
        let m = try MachO(kernel)
        if let rootDevice,
            rootDevice.isEmpty || !rootDevice.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) })
        {
            throw FirmwareError(.unsupported, "invalid root device name")
        }
        let namedRootMatching = rootDevice.map {
            "<dict><key>IOProviderClass</key><string>IOMedia</string><key>IOPropertyMatch</key>"
                + "<dict><key>BSD Name</key><string>\($0)</string></dict></dict>"
        }
        let segs = m.segments.filter { $0.name != "__PAGEZERO" }
        guard let lowest = segs.map(\.vmaddr).min(), let end = segs.map({ Int($0.vmaddr) + Int($0.vmsize) }).max()
        else {
            throw FirmwareError(.unsupported, "kernelcache has no segments")
        }
        let vbase = Int(lowest & 0xF000_0000)
        var dt = try DeviceTree(deviceTree)
        let board = Board.of(dt)
        if board.isA6 {
            // Later restore trees describe iBoot syscfg lookups rather than
            // reserving zero-filled slots. Resolve the same expressions before
            // measuring the tree. The original iBoot omits unavailable syscfg
            // properties without a fallback (14G61 resolver +0x33d70/+0x33e3c).
            // The iPhone 5's trees only: the older boards' are kept as recorded, and 9B208's (iPhone 4) carries a
            // zero-length content-protect with the directive bit set, which this resolver refuses.
            let (rootIdentity, _, _) = try identityDT(identity, board: board)
            var syscfg: [String: Data] = [:]
            for (key, field) in [
                ("MLB#", "mlb-serial-number"), ("Regn", "region-info"),
                ("Mod#", "model-number"), ("SrNm", "serial-number")
            ] {
                if let value = rootIdentity.first(where: { $0.0 == field })?.1 { syscfg[key] = value.encoded }
            }
            var macs: [String: Data] = [:]
            for (key, field, name) in [("WMac", "wifi-mac", "wifiaddr"), ("BMac", "bt-mac", "btaddr")] {
                if let text = identity[field], let value = Data(hex: text.replacingOccurrences(of: ":", with: "")) {
                    syscfg[key] = value
                    macs[name] = value
                }
            }
            try dt.resolveBootDirectives(syscfg: syscfg, macAddresses: macs)
            // 6.x/7.x IPSWs reserve only a two-byte placeholder. iBoot
            // replaces it with 64 bytes, which the emulator fills afresh at
            // reset. An undersized record silently prevents that injection.
            if let slot = dt.props["chosen"]?["random-seed"] {
                if slot.length != 64 { try dt.replace("chosen", "random-seed", .bytes(Data(count: 64))) }
            } else {
                try dt.add("chosen", "random-seed", Data(count: 64))
            }
        }
        let physicalBase = board.physicalBase
        let pa = { (va: Int) in UInt32(truncatingIfNeeded: va - vbase + Int(physicalBase)) }
        if !board.isA6 { try graftNOR(&dt) }
        // Host nubs (EHCI, OHCI0) up at arbitrator start, next to device mode (qemu-ios docs/ipad1/usb-keyboard.md).
        if dt.contains("arm-io/usb-complex") { try dt.add("arm-io/usb-complex", "hsic-enabled") }
        let dtLen = dt.data.count
        var top = page(end)
        let rdVA = top
        var args = bootArgs
        if let rd = ramdisk {
            top += page(rd.count)
            args += " rd=md0"
        }
        let dtVA = top
        let argsVA = top + page(dtLen)
        let endVA = argsVA + 0x1000
        let topOfKernel = pa((endVA + 0x3FFF) & ~0x3FFF)
        // The segments' sizes are the kernelcache's word: what they lay out must fit the memory it boots in.
        guard endVA - vbase <= Int(board.memSize) else {
            throw FirmwareError(
                .unsupported,
                "the kernelcache's segments, RAM disk and device tree take \(endVA - vbase) bytes, past the board's \(board.memSize)"
            )
        }

        var image = Data(count: endVA - vbase)
        var memoryMap: [(String, UInt32, UInt32)] = []
        for s in segs {
            let n = Int(min(s.filesize, s.vmsize))
            let at = Int(s.vmaddr) - vbase
            guard Int(s.fileoff) + n <= kernel.count else {
                throw FirmwareError(.unsupported, "kernelcache segment \(s.name) runs past the file")
            }
            let from = kernel.startIndex + Int(s.fileoff)
            image.replaceSubrange(at..<at + n, with: kernel[from..<from + n])
            memoryMap.append(("Kernel-\(s.name)", pa(Int(s.vmaddr)), s.vmsize))
        }
        if let rd = ramdisk {
            image.replaceSubrange(rdVA - vbase..<rdVA - vbase + rd.count, with: rd)
            memoryMap.append(("RAMDisk", pa(rdVA), UInt32(rd.count)))
        }
        memoryMap += [("DeviceTree", pa(dtVA), UInt32(dtLen)), ("BootArgs", pa(argsVA), 0x1000)]
        try fillDT(
            &dt,
            memoryMap: memoryMap,
            identity: identity,
            iboot: iboot,
            rootMatching: ramdisk == nil ? (namedRootMatching ?? (board.isA6 ? a6RootMatching : rootMatching)) : ""
        )
        image.replaceSubrange(dtVA - vbase..<dtVA - vbase + dt.data.count, with: dt.data)

        // boot_args rev 1 / the version the kernel checks for (2, or 3 from xnu-1735.47). Video: base, display
        // (0 = text console for -v/-s), rowbytes, w, h, depth.
        let verbose = args.split(separator: " ").contains { $0 == "-v" || $0 == "-s" }
        let cmdline = Array(args.utf8)
        guard cmdline.count < 256 else { throw FirmwareError(.unsupported, "boot-args longer than BOOT_LINE_LENGTH") }
        var ba = Data([1, 0, m.bootArgsVersion(), 0])
        ba += DeviceTree.Value.le([
            UInt32(vbase), physicalBase, board.memSize, topOfKernel,
            board.vramPA, verbose ? 0 : 1, UInt32(board.fbWidth * fbDepth / 8), UInt32(board.fbWidth),
            UInt32(board.fbHeight), UInt32(fbDepth) | (board.scale - 1) << 16,
            0, UInt32(dtVA), UInt32(dtLen)
        ])
        ba += cmdline + [UInt8](repeating: 0, count: 256 - cmdline.count)
        image.replaceSubrange(argsVA - vbase..<argsVA - vbase + ba.count, with: ba)
        return Image(image: image, loadPA: physicalBase, entryPA: pa(Int(try m.entry())), bootArgsPA: pa(argsVA))
    }

    /// image + segments ("K48SEG\0\0", pa, len, flags bit 0 = zero-fill, data) + the 24-byte trailer.
    public static func bundle(_ img: Image, segments: [Segment]) -> Data {
        var out = img.image
        for s in segments {
            out += Data("K48SEG\0\0".utf8) + DeviceTree.Value.le([s.pa, s.length, s.data == nil ? 1 : 0])
            if let d = s.data { out += d }
        }
        out +=
            Data("K48KBOOT".utf8)
            + DeviceTree.Value.le([img.loadPA, img.entryPA, img.bootArgsPA, UInt32(img.image.count)])
        return out
    }

    /// ipad1_kboot.main: kboot.bin from a decrypted-firmware directory.
    public static func write(
        decrypted dir: URL,
        to out: URL,
        identity: UnitIdentity,
        bootArgs: String = defaultBootArgs,
        ramdisk: URL? = nil,
        kernelOverride: Data? = nil,
        rootDevice: String? = nil
    ) throws {
        let file = { (n: String) in dir.appendingPathComponent(n) }
        let exists = { (n: String) in FileManager.default.fileExists(atPath: file(n).path) }
        let img = try build(
            kernel: kernelOverride ?? Data(contentsOf: file("kernelcache.mach")),
            deviceTree: Data(contentsOf: file("DeviceTree.bin")),
            bootArgs: bootArgs,
            identity: identity,
            iboot: ibootVersion(exists("iBoot.bin") ? try Data(contentsOf: file("iBoot.bin")) : nil),
            ramdisk: try ramdisk.map { try Data(contentsOf: $0) },
            rootDevice: rootDevice
        )
        let board = Board.of(try DeviceTree(Data(contentsOf: file("DeviceTree.bin"))))
        let logo =
            exists("AppleLogo.bin")
            ? try BootLogo.segments(
                iBootIm: Data(contentsOf: file("AppleLogo.bin")),
                framebufferPA: board.vramPA,
                width: board.fbWidth,
                height: board.fbHeight,
                turn: board.rotation == 270
            ) : []
        try bundle(img, segments: logo).write(to: out)
    }
}

/// A 32-bit little-endian Mach-O's segments, their sections and its entry point (imgtools/macho.py, as much as kboot,
/// the keybag one-shot and the sandbox patch need).
public struct MachO: Sendable {
    public struct Segment: Equatable, Sendable {
        public var name: String
        public var vmaddr: UInt32, vmsize: UInt32, fileoff: UInt32, filesize: UInt32
        var sections: [Section] = []
    }
    struct Section: Equatable, Sendable {
        var name: String, segment: String
        var addr: UInt32, size: UInt32, offset: UInt32
    }
    /// What a Mach-O's header and load commands say.
    struct Load: Sendable {
        var cputype: UInt32
        var segments: [Segment]
        /// LC_UNIXTHREAD's ARM_THREAD_STATE pc (r15), from the first one.
        var entry: UInt32?
    }

    public let segments: [Segment]
    let data: Data
    let load: Load

    public init(_ data: Data) throws {
        self.data = data
        load = try parsing(data, "Mach-O") { s in try Self.load(&s) }
        segments = load.segments
    }

    static let lcSegment: UInt32 = 1, lcUnixThread: UInt32 = 5

    /// The header at `s` (mach_header: magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags) and its load
    /// commands, each a cmd, a cmdsize of at least 8 and its body, all in the data: an LC_SEGMENT's 16-byte name,
    /// vmaddr, vmsize, fileoff, filesize, protections, nsects and flags, then its 68-byte sections (sectname, segname,
    /// addr, size, offset, …), within the command; LC_UNIXTHREAD's flavor, count and r0-r15. Offsets are the span's.
    static func load(_ s: inout ParserSpan) throws -> Load {
        guard try UInt32(parsingLittleEndian: &s) == 0xFEED_FACE else {
            throw FirmwareError(.unsupported, "not a 32-bit Mach-O")
        }
        let cputype = try UInt32(parsingLittleEndian: &s)
        try s.seek(toRelativeOffset: 8)
        let ncmds = try UInt32(parsingLittleEndian: &s)
        try s.seek(toRelativeOffset: 8)
        func name(_ c: inout ParserSpan) throws -> String {
            String(decoding: try [UInt8](parsing: &c, byteCount: 16).prefix { $0 != 0 }, as: UTF8.self)
        }
        var load = Load(cputype: cputype, segments: [])
        for _ in 0..<ncmds {
            let cmd = try UInt32(parsingLittleEndian: &s)
            let size = try UInt32(parsingLittleEndian: &s)
            guard size >= 8 else { throw FirmwareError(.unsupported, "Mach-O load command \(cmd) of \(size) bytes") }
            var c = try s.sliceSpan(byteCount: size - 8)
            if cmd == lcSegment {
                var seg = Segment(
                    name: try name(&c),
                    vmaddr: try UInt32(parsingLittleEndian: &c),
                    vmsize: try UInt32(parsingLittleEndian: &c),
                    fileoff: try UInt32(parsingLittleEndian: &c),
                    filesize: try UInt32(parsingLittleEndian: &c)
                )
                try c.seek(toRelativeOffset: 8)
                let nsects = try UInt32(parsingLittleEndian: &c)
                try c.seek(toRelativeOffset: 4)
                for _ in 0..<nsects {
                    var sect = try c.sliceSpan(byteCount: 68)
                    seg.sections.append(
                        Section(
                            name: try name(&sect),
                            segment: try name(&sect),
                            addr: try UInt32(parsingLittleEndian: &sect),
                            size: try UInt32(parsingLittleEndian: &sect),
                            offset: try UInt32(parsingLittleEndian: &sect)
                        )
                    )
                }
                load.segments.append(seg)
            } else if cmd == lcUnixThread, load.entry == nil {
                try c.seek(toRelativeOffset: 8 + 15 * 4)
                load.entry = try UInt32(parsingLittleEndian: &c)
            }
        }
        return load
    }

    /// The boot_args.Version pe_identify_machine demands, read off the kernel's own check (imgtools/ipad1_kboot.py
    /// boot_args_version): the Thumb pair `ldrh rN, [r0, #2]` (0x8840|N) … `cmp rN, #V` (0x28|N<<8|V) just before the
    /// literal naming "pe_identify_machine: Epoch Mismatch". 2 when the shape is not found (3.2.x, 4.2.1 and 4.3.0
    /// boot with 2); 4.3.5's xnu-1735.47 and iOS 5's xnu-1878 say 3.
    public func bootArgsVersion() -> UInt8 {
        guard let so = data.range(of: Data("pe_identify_machine: Epoch Mismatch".utf8))?.lowerBound,
            let seg = segments.first(where: {
                Int($0.fileoff) <= so - data.startIndex && so - data.startIndex < Int($0.fileoff) + Int($0.filesize)
            })
        else { return 2 }
        let sva = seg.vmaddr &+ UInt32(so - data.startIndex - Int(seg.fileoff))
        if let lit = data.range(of: Data(DeviceTree.Value.le([sva])))?.lowerBound {
            let window = [UInt8](data[max(data.startIndex, lit - 0x400)..<lit])
            for n in 0..<8 {
                guard window.count > 2,
                    let i = (0..<(window.count - 1)).reversed().first(where: {
                        window[$0] == 0x40 | UInt8(n) && window[$0 + 1] == 0x88
                    })
                else { continue }
                for j in (i + 2)..<min(i + 10, window.count) where window[j] == 0x28 | UInt8(n) { return window[j - 1] }
            }
        }
        // iOS 6's xnu-2107 reaches the string through movw/movt/add rX, pc, so no literal names it: the pair is
        // `ldrh rN, [r0, #2]; cmp rN, #V` with that sequence within the next 24 bytes (ipad1_kboot 08a698c2f1).
        let bytes = [UInt8](data)
        let h16 = { (o: Int) in UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 }
        let imm16 = { (hw1: UInt32, hw2: UInt32) in
            (hw1 & 0xF) << 12 | ((hw1 >> 10) & 1) << 11 | ((hw2 >> 12) & 7) << 8 | (hw2 & 0xFF)
        }
        func namesString(_ at: Int, _ seg: Segment) -> Bool {
            for o in stride(from: at, to: min(at + 24, bytes.count - 10), by: 2) {
                let hw1 = h16(o)
                let hw2 = h16(o + 2)
                guard hw1 & 0xFBF0 == 0xF240 else { continue }  // movw
                let rd = (hw2 >> 8) & 0xF
                let lo = imm16(hw1, hw2)
                let t1 = h16(o + 4)
                let t2 = h16(o + 6)
                guard t1 & 0xFBF0 == 0xF2C0, (t2 >> 8) & 0xF == rd else { continue }  // movt, same register
                guard h16(o + 8) == 0x4478 | (rd & 7) | ((rd & 8) << 4) else { continue }  // add rd, pc
                let pc = seg.vmaddr &+ UInt32(o + 8 - Int(seg.fileoff)) &+ 4
                return (imm16(t1, t2) << 16 | lo) &+ pc == sva
            }
            return false
        }
        for seg in segments where seg.filesize > 0 {
            let lo = Int(seg.fileoff)
            let hi = min(Int(seg.fileoff) + Int(seg.filesize), bytes.count - 4)
            guard lo < hi else { continue }
            for i in stride(from: lo, to: hi, by: 2) where bytes[i + 1] == 0x88 && bytes[i] & 0xF8 == 0x40 {
                let n = bytes[i] & 7
                if bytes[i + 3] == 0x28 | n, namesString(i + 6, seg) { return bytes[i + 2] }
            }
        }
        return 2
    }

    /// LC_UNIXTHREAD's ARM_THREAD_STATE pc (r15).
    public func entry() throws -> UInt32 {
        guard let pc = load.entry else { throw FirmwareError(.unsupported, "no LC_UNIXTHREAD") }
        return pc
    }

    static func u32(_ d: Data, _ at: Int) throws -> UInt32 { try parsing(d, "Mach-O") { s in try s.le32(at: at) } }
}
