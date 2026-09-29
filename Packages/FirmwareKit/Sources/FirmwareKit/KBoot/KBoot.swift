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
// display-rotation is 270 (the panel's turn against the portrait UI; 4.x lays its UI out by it).

import Foundation

public enum KBoot {
    public static let physBase: UInt32 = 0x4000_0000, dramSize: UInt32 = 0x1000_0000
    public static let pramSize: UInt32 = 0x4000, vramSize: UInt32 = 0x90_0000 - 0x4000
    public static let memSize = dramSize - pramSize - vramSize
    public static let vramPA = physBase + memSize, pramPA = physBase + dramSize - pramSize
    public static let fbWidth = 1024, fbHeight = 768, fbDepth = 32
    /// ipad1_kboot.DEFAULT_BOOT_ARGS. enable-hsic=1: 4.x's AppleS5L8930XUSBArbitrator::handleStart publishes the
    /// USB host nubs for the DT's hsic-enabled only when this boot-arg is 1 (no USB keyboard without it); 3.x ignores it.
    public static let defaultBootArgs = "serial=3 debug=0x8 amfi_allow_any_signature=1 cs_enforcement_disable=1 enable-hsic=1"
    public static let defaultIBootVersion = "iBoot-817.29"
    public static let rootMatching = "<dict><key>IOProviderClass</key><string>IOMedia</string><key>IOPropertyMatch</key>"
        + "<dict><key>Partition ID</key><integer>1</integer></dict></dict>"

    // Measured on a real iPad 1 running 7B500: cpu/memory 0, bus/peripheral 100 MHz, fixed/timebase 24 MHz.
    static let cpuHz: UInt32 = 0, memHz: UInt32 = 0, busHz: UInt32 = 100_000_000, periphHz: UInt32 = 100_000_000
    static let fixedHz: UInt32 = 24_000_000, timebaseHz: UInt32 = 24_000_000, usbphyHz: UInt32 = 24_000_000
    static let clocks: [UInt32] = {
        var c = [UInt32](repeating: periphHz, count: 55)
        for (i, hz) in [0: timebaseHz, 5: cpuHz, 6: periphHz, 27: memHz, 32: busHz, 33: fixedHz] { c[i] = hz }
        return c
    }()
    /// NAND geometry iBoot would have probed (16 GB, eight Hynix dies); only the keys the DT has are written.
    static let nand: [(String, UInt32)] = [
        ("#ce", 8), ("#die-ce", 1), ("#ce-blocks", 0x1000), ("#block-pages", 128), ("#page-bytes", 4096),
        ("#spare-bytes", 0x80), ("device-readid", 0xB614_D5AD), ("vendor-type", 0x10_0014), ("#databus", 2),
        ("ecc-correctable", 8), ("ecc-threshold", 8), ("bbt-format", 3),
        ("read-cycle-ns", 25), ("read-setup-ns", 10), ("read-hold-ns", 10), ("read-delay-ns", 20),
        ("read-valid-ns", 20), ("write-cycle-ns", 25), ("write-hold-ns", 10),
        ("meta-per-logical-page", 12), ("valid-meta-per-logical-page", 10), ("logical-page-size", 4096), ("ppn-device", 0),
    ]
    static let model = [("model-number", "MB292"), ("region-info", "LL/A")]

    public struct Segment: Equatable, Sendable {
        public var pa: UInt32, length: UInt32
        /// nil: zero-fill.
        public var data: Data?
        public init(pa: UInt32, length: UInt32, data: Data?) { self.pa = pa; self.length = length; self.data = data }
    }

    public struct Image: Sendable {
        public var image: Data
        public var loadPA: UInt32, entryPA: UInt32, bootArgsPA: UInt32
    }

    /// The first "iBoot-N(.N)*" in a decrypted iBoot, else the default.
    public static func ibootVersion(_ iboot: Data?) -> String {
        guard let b = iboot.map([UInt8].init) else { return defaultIBootVersion }
        let tag = Array("iBoot-".utf8), digit = { (c: UInt8) in c >= 0x30 && c <= 0x39 }
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
    static func identityDT(_ id: UnitIdentity) throws -> ([(String, DeviceTree.Value)], [(String, DeviceTree.Value)], [(String, Data)]) {
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
            guard let d = Data(hex: s.replacingOccurrences(of: ":", with: "")) else { throw FirmwareError(.unsupported, "identity: bad MAC \(s)") }
            return d
        }
        let ecid = try hex(need("unique-chip-id"))
        guard let die = id.dieID, die.count == 2 else { throw FirmwareError(.unsupported, "identity: missing die-id") }
        let dieWords = try die.map { w -> UInt32 in
            let v = try hex(w)
            guard v <= UInt32.max else { throw FirmwareError(.unsupported, "identity: die-id word \(w) is over 32 bits") }
            return UInt32(v)
        }
        guard ecid >> 32 <= UInt32.max else { throw FirmwareError(.unsupported, "identity: unique-chip-id over 64 bits") }
        let root: [(String, DeviceTree.Value)] = [("serial-number", .string(try need("serial-number"))),
                                                  ("mlb-serial-number", .string(try need("mlb-serial-number")))]
            + model.map { k, v in (k, .string(id[k] ?? v)) }
        let chosen: [(String, DeviceTree.Value)] = [("unique-chip-id", .words([UInt32(ecid & 0xFFFF_FFFF), UInt32(ecid >> 32)])),
                                                    ("die-id", .words(dieWords))]
        return (root, chosen, [("arm-io/sdio", try mac(need("wifi-mac"))), ("arm-io/uart3/bluetooth", try mac(need("bt-mac")))])
    }

    static func fillDT(_ dt: inout DeviceTree, memoryMap: [(String, UInt32, UInt32)], identity: UnitIdentity,
                       iboot: String, rootMatching: String) throws {
        let (root, chosen, macs) = try identityDT(identity)
        for (k, v) in [("platform-name", DeviceTree.Value.string("s5l8930x"))] + root { try dt.set("", k, v) }
        let flags: [(String, DeviceTree.Value)] = ["debug-enabled", "production-cert", "secure-boot", "gid-aes-key",
                                                    "uid-aes-key", "system-trusted"].map { ($0, .u32(1)) }
        for (k, v) in flags + [("board-id", .u32(0x02)), ("chip-id", .u32(0x8930))] + chosen
            + [("firmware-version", .string(iboot)), ("display-rotation", .u32(270)), ("display-scale", .u32(1)),
               ("root-matching", .string(rootMatching))] {
            try dt.set("chosen", k, v)
        }
        for (k, hz) in [("clock-frequency", cpuHz), ("memory-frequency", memHz), ("bus-frequency", busHz),
                        ("peripheral-frequency", periphHz), ("fixed-frequency", fixedHz), ("timebase-frequency", timebaseHz)] {
            try dt.set("cpus/cpu0", k, .u32(hz))
        }
        try dt.set("arm-io", "clock-frequencies", .words(clocks))
        try dt.set("arm-io", "usbphy-frequency", .u32(usbphyHz))
        if dt.contains("arm-io/sgx") { try dt.set("arm-io/sgx", "compatible", .string("none")) }   // no SGX model
        for (path, mac) in macs where dt.contains(path) { try dt.set(path, "local-mac-address", .bytes(mac)) }
        if dt.contains("arm-io/mipi-dsim/lcd") {   // the panel id iBoot's pinot_init writes; the DSI model's reply
            for k in ["lcd-panel-id", "raw-panel-id"] { try dt.set("arm-io/mipi-dsim/lcd", k, .u32(0x00A1_D13C)) }
        }
        if dt.contains("baseband") {   // Wi-Fi iPad: no radio, so unmatch and unname the N82 baseband node
            for (k, v) in [("compatible", "none"), ("device_type", "none"), ("name", "nobb")] { try dt.set("baseband", k, .string(v)) }
        }
        if dt.props["arm-io"]?["chip-revision"] != nil { try dt.set("arm-io", "chip-revision", .u32(0x11)) }
        if let disk = dt.props["arm-io/flash-controller0/disk"] {
            for (k, v) in nand where disk[k] != nil { try dt.set("arm-io/flash-controller0/disk", k, .u32(v)) }
        }
        try dt.set("pram", "reg", .words([pramPA, pramSize]))
        try dt.set("vram", "reg", .words([vramPA, vramSize]))
        for (i, (name, pa, size)) in memoryMap.enumerated() {
            try dt.rename("chosen/memory-map", "MemoryMapReserved-\(i)", name)
            try dt.set("chosen/memory-map", name, .words([pa, size]))
        }
    }

    /// The flat physical image, its load PA, entry PA and boot_args PA. `ramdisk`: raw HFS to boot as md0.
    public static func build(kernel: Data, deviceTree: Data, bootArgs: String = defaultBootArgs, identity: UnitIdentity,
                             iboot: String = defaultIBootVersion, ramdisk: Data? = nil) throws -> Image {
        let page = { (n: Int) in (n + 0xFFF) & ~0xFFF }
        let m = try MachO(kernel)
        let segs = m.segments.filter { $0.name != "__PAGEZERO" }
        guard let lowest = segs.map(\.vmaddr).min() else { throw FirmwareError(.unsupported, "kernelcache has no segments") }
        let vbase = Int(lowest & 0xF000_0000)
        let pa = { (va: Int) in UInt32(truncatingIfNeeded: va - vbase + Int(physBase)) }
        var dt = try DeviceTree(deviceTree)
        // Host nubs (EHCI, OHCI0) up at arbitrator start, next to device mode (docs/ipad1/usb-keyboard.md).
        if dt.contains("arm-io/usb-complex") { try dt.add("arm-io/usb-complex", "hsic-enabled") }
        let dtLen = dt.data.count
        var top = page(segs.map { Int($0.vmaddr) + Int($0.vmsize) }.max()!)
        let rdVA = top
        var args = bootArgs
        if let rd = ramdisk {
            top += page(rd.count)
            args += " rd=md0"
        }
        let dtVA = top, argsVA = top + page(dtLen), endVA = argsVA + 0x1000
        let topOfKernel = pa((endVA + 0x3FFF) & ~0x3FFF)

        var image = Data(count: endVA - vbase)
        var memoryMap: [(String, UInt32, UInt32)] = []
        for s in segs {
            let n = Int(min(s.filesize, s.vmsize)), at = Int(s.vmaddr) - vbase
            guard Int(s.fileoff) + n <= kernel.count else { throw FirmwareError(.unsupported, "kernelcache segment \(s.name) runs past the file") }
            let from = kernel.startIndex + Int(s.fileoff)
            image.replaceSubrange(at..<at + n, with: kernel[from..<from + n])
            memoryMap.append(("Kernel-\(s.name)", pa(Int(s.vmaddr)), s.vmsize))
        }
        if let rd = ramdisk {
            image.replaceSubrange(rdVA - vbase..<rdVA - vbase + rd.count, with: rd)
            memoryMap.append(("RAMDisk", pa(rdVA), UInt32(rd.count)))
        }
        memoryMap += [("DeviceTree", pa(dtVA), UInt32(dtLen)), ("BootArgs", pa(argsVA), 0x1000)]
        try fillDT(&dt, memoryMap: memoryMap, identity: identity, iboot: iboot, rootMatching: ramdisk == nil ? rootMatching : "")
        image.replaceSubrange(dtVA - vbase..<dtVA - vbase + dt.data.count, with: dt.data)

        // boot_args rev 1 / the version the kernel checks for (2, or 3 from xnu-1735.47). Video: base, display
        // (0 = text console for -v/-s), rowbytes, w, h, depth.
        let verbose = args.split(separator: " ").contains { $0 == "-v" || $0 == "-s" }
        let cmdline = Array(args.utf8)
        guard cmdline.count < 256 else { throw FirmwareError(.unsupported, "boot-args longer than BOOT_LINE_LENGTH") }
        var ba = Data([1, 0, m.bootArgsVersion(), 0])
        ba += DeviceTree.Value.le([UInt32(vbase), physBase, memSize, topOfKernel,
                                   vramPA, verbose ? 0 : 1, UInt32(fbWidth * fbDepth / 8), UInt32(fbWidth), UInt32(fbHeight), UInt32(fbDepth),
                                   0, UInt32(dtVA), UInt32(dtLen)])
        ba += cmdline + [UInt8](repeating: 0, count: 256 - cmdline.count)
        image.replaceSubrange(argsVA - vbase..<argsVA - vbase + ba.count, with: ba)
        return Image(image: image, loadPA: physBase, entryPA: pa(Int(try m.entry())), bootArgsPA: pa(argsVA))
    }

    /// image + segments ("K48SEG\0\0", pa, len, flags bit 0 = zero-fill, data) + the 24-byte trailer.
    public static func bundle(_ img: Image, segments: [Segment]) -> Data {
        var out = img.image
        for s in segments {
            out += Data("K48SEG\0\0".utf8) + DeviceTree.Value.le([s.pa, s.length, s.data == nil ? 1 : 0])
            if let d = s.data { out += d }
        }
        out += Data("K48KBOOT".utf8) + DeviceTree.Value.le([img.loadPA, img.entryPA, img.bootArgsPA, UInt32(img.image.count)])
        return out
    }

    /// ipad1_kboot.main: kboot.bin from a decrypted-firmware directory.
    public static func write(decrypted dir: URL, to out: URL, identity: UnitIdentity, bootArgs: String = defaultBootArgs,
                             ramdisk: URL? = nil) throws {
        let file = { (n: String) in dir.appendingPathComponent(n) }
        let exists = { (n: String) in FileManager.default.fileExists(atPath: file(n).path) }
        let img = try build(kernel: Data(contentsOf: file("kernelcache.mach")), deviceTree: Data(contentsOf: file("DeviceTree.bin")),
                            bootArgs: bootArgs, identity: identity,
                            iboot: ibootVersion(exists("iBoot.bin") ? try Data(contentsOf: file("iBoot.bin")) : nil),
                            ramdisk: try ramdisk.map { try Data(contentsOf: $0) })
        let logo = exists("AppleLogo.bin") ? try BootLogo.segments(iBootIm: Data(contentsOf: file("AppleLogo.bin")), framebufferPA: vramPA) : []
        try bundle(img, segments: logo).write(to: out)
    }
}

/// A 32-bit Mach-O's segments and entry point (imgtools/macho.py, as much as kboot needs).
public struct MachO: Sendable {
    public struct Segment: Equatable, Sendable {
        public var name: String
        public var vmaddr: UInt32, vmsize: UInt32, fileoff: UInt32, filesize: UInt32
    }

    public let segments: [Segment]
    let data: Data

    public init(_ data: Data) throws {
        self.data = data
        guard data.count >= 28, Self.u32(data, 0) == 0xFEED_FACE else { throw FirmwareError(.unsupported, "not a 32-bit Mach-O") }
        var segs: [Segment] = [], off = 28
        for _ in 0..<Self.u32(data, 16) {
            guard off + 8 <= data.count else { throw FirmwareError(.unsupported, "Mach-O load commands run past the file") }
            let cmd = Self.u32(data, off), size = Int(Self.u32(data, off + 4))
            if cmd == 1 {   // LC_SEGMENT
                let nameBytes = data[data.startIndex + off + 8..<data.startIndex + off + 24].prefix { $0 != 0 }
                segs.append(Segment(name: String(decoding: nameBytes, as: UTF8.self),
                                    vmaddr: Self.u32(data, off + 24), vmsize: Self.u32(data, off + 28),
                                    fileoff: Self.u32(data, off + 32), filesize: Self.u32(data, off + 36)))
            }
            guard size > 0 else { break }
            off += size
        }
        segments = segs
    }

    /// The boot_args.Version pe_identify_machine demands, read off the kernel's own check (imgtools/ipad1_kboot.py
    /// boot_args_version): the Thumb pair `ldrh rN, [r0, #2]` (0x8840|N) … `cmp rN, #V` (0x28|N<<8|V) just before the
    /// literal naming "pe_identify_machine: Epoch Mismatch". 2 when the shape is not found (3.2.x, 4.2.1 and 4.3.0
    /// boot with 2); 4.3.5's xnu-1735.47 and iOS 5's xnu-1878 say 3.
    public func bootArgsVersion() -> UInt8 {
        guard let so = data.range(of: Data("pe_identify_machine: Epoch Mismatch".utf8))?.lowerBound,
              let seg = segments.first(where: { Int($0.fileoff) <= so - data.startIndex && so - data.startIndex < Int($0.fileoff + $0.filesize) })
        else { return 2 }
        let sva = seg.vmaddr + UInt32(so - data.startIndex) - seg.fileoff
        guard let lit = data.range(of: Data(DeviceTree.Value.le([sva])))?.lowerBound else { return 2 }
        let window = [UInt8](data[max(data.startIndex, lit - 0x400)..<lit])
        for n in 0..<8 {
            guard window.count > 2, let i = (0..<(window.count - 1)).reversed().first(where: { window[$0] == 0x40 | UInt8(n) && window[$0 + 1] == 0x88 })
            else { continue }
            for j in (i + 2)..<min(i + 10, window.count) where window[j] == 0x28 | UInt8(n) { return window[j - 1] }
        }
        return 2
    }

    /// LC_UNIXTHREAD's ARM_THREAD_STATE pc (r15).
    public func entry() throws -> UInt32 {
        var off = 28
        for _ in 0..<Self.u32(data, 16) {
            let cmd = Self.u32(data, off), size = Int(Self.u32(data, off + 4))
            if cmd == 5 { return Self.u32(data, off + 16 + 15 * 4) }
            guard size > 0 else { break }
            off += size
        }
        throw FirmwareError(.unsupported, "no LC_UNIXTHREAD")
    }

    static func u32(_ d: Data, _ at: Int) -> UInt32 {
        d.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self)) }
    }
}
