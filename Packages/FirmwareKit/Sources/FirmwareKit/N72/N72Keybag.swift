// N72Keybag: the iPod's 4.x data-protection one-shot (qemu-ios imgtools/ipod2g_keybag.py). Effaceable storage
// (in NOR, through nor-rw) and the system keybag (on disk0s1, in a NAND overlay), made the way a restore makes
// them: the IPSW's own Update ramdisk with it_keybag as restored_external, booted as md0.
//
// Everything iBoot loads is a signed img3, so the ramdisk cannot come through iBoot. iBoot boots the device
// normally (rd=md0 in the machine's command line), and at the kernel's entry (LC_UNIXTHREAD pc, MMU off) this
// stages what iBoot's restore path would have, over the helper's gdbstub: the ramdisk at topOfKernelData, a
// chosen/memory-map RAMDisk (pa, len) in a spare MemoryMapReserved slot, an empty chosen/root-matching, and
// topOfKernelData past the ramdisk. The 4.x DeviceTree's secure-root-prefix "md" makes md0 a SecureRoot.
// Then the overlay's pages (stored at their logical homes) are folded into nand/ and the written NOR
// replaces nor.bin. The boot uses aes-uid=engine, as the device's own boots do (the keybag's keys are
// UID-derived).

import Foundation

enum N72Keybag {
    /// rd=md0 rides the machine's command line (early iBoot literal and late write).
    static let bootArgs = "rd=md0 serial=3 debug=0x8 -v amfi_allow_any_signature=1 cs_enforcement_disable=1"
    static let physBase: UInt32 = 0x0800_0000, cmdlineOffset = 0x38, cmdlineLength = 256

    /// `out` holds nand/, nor.bin, iBoot.bin and gid-blobs.bin (writable); `dec` the decrypt cache (the kernelcache);
    /// `ramdisk` the decrypted restore ramdisk to boot (this build's, or a sibling's: Recipe.keybagRamdisk).
    static func run(out: URL, dec: URL, ramdisk: URL, itKeybag: URL, bootrom: URL, helper: URL, work: URL,
                    log: (String) -> Void) throws -> Int {
        let fm = FileManager.default
        let rd = try Preparer.ramdiskWithHelper(ramdisk, helper: itKeybag, work: work)
        let nor = work.appendingPathComponent("nor.rw"), ovl = work.appendingPathComponent("keybag-overlay")
        let serial = work.appendingPathComponent("keybag.log")
        try fm.copyItem(at: out.appendingPathComponent("nor.bin"), to: nor)
        chmod(nor.path, 0o644)
        try fm.createDirectory(at: ovl, withIntermediateDirectories: true)
        let port = try GDBRemote.freePort()
        let file = { (n: String) in Preparer.esc(out.appendingPathComponent(n)) }
        let machine = ["iPod-Touch,bootrom=\(Preparer.esc(bootrom))", "nand=\(file("nand"))", "nor=\(file("nor.bin"))",
                       "nor-rw=\(Preparer.esc(nor))", "nandrw=\(Preparer.esc(ovl))", "direct-iboot=\(file("iBoot.bin"))",
                       "gid-blobs=\(file("gid-blobs.bin"))", "aes-uid=engine", "boot-args=\(bootArgs.replacingOccurrences(of: ",", with: ",,"))"]
            .joined(separator: ",")
        let argv = ["LightTouchDevice", "-M", machine, "-m", "128M", "-display", "none", "-audio", "driver=none", "-monitor", "none",
                    "-serial", "file:\(serial.path)", "-gdb", "tcp:127.0.0.1:\(port)", "-S"]
        let kc = try Data(contentsOf: dec.appendingPathComponent("kernelcache.mach"))
        let image = try Data(contentsOf: rd)
        final class Note: @unchecked Sendable { var text = "" }
        let note = Note()
        let (r, text) = try Preparer.oneshot(helper, argv: argv, machine: "iPod-Touch", serial: serial, stop: "panic(", timeout: 300,
                                             work: work, log: log) {
            note.text = try handoff(GDBRemote(port: port), kernelcache: kc, ramdisk: image)
        }
        log(note.text)
        for line in text.split(separator: "\n") where line.contains("it_keybag:") { log(line.trimmingCharacters(in: .whitespaces)) }
        guard text.contains(Preparer.keybagDone) else {
            let why = text.split(separator: "\n").first { $0.contains("panic(") }.map { String($0.prefix(160)) }
                ?? (r.exited ? "halted without the keybag" : "no halt")
            throw FirmwareError(.oneshotFailed, "keybag boot: \(why) after \(Int(r.seconds)) s")
        }
        let written = try Data(contentsOf: nor)
        guard written != (try Data(contentsOf: out.appendingPathComponent("nor.bin"))) else {
            throw FirmwareError(.oneshotFailed, "keybag boot: NOR unchanged, effaceable was not written")
        }
        let pages = try foldOverlay(ovl, into: out.appendingPathComponent("nand"))
        try written.write(to: out.appendingPathComponent("nor.bin"))
        for u in [rd, nor, ovl, serial] { try? fm.removeItem(at: u) }
        log("keybag boot: effaceable in nor.bin, \(pages) NAND pages folded in")
        return pages
    }

    /// (entry pc, link base): LC_UNIXTHREAD's pc and __TEXT's vmaddr top nibble.
    static func kernelEntry(_ d: Data) throws -> (pc: UInt32, base: UInt32) {
        let b = [UInt8](d)
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
        var off = 28, pc: UInt32?, base: UInt32?
        for _ in 0..<Int(u32(16)) {
            let cmd = u32(off), size = Int(u32(off + 4))
            if cmd == 5 { pc = u32(off + 16 + 15 * 4) }
            if cmd == 1, String(decoding: b[off + 8..<off + 24].prefix { $0 != 0 }, as: UTF8.self) == "__TEXT" { base = u32(off + 24) & 0xF000_0000 }
            off += size
        }
        guard let pc, let base else { throw FirmwareError(.unsupported, "no LC_UNIXTHREAD / __TEXT in the kernelcache") }
        return (pc, base)
    }

    /// ipod2g_keybag.add_ramdisk: a RAMDisk memory-map entry in the first spare reserved slot, no root-matching.
    static func addRamdisk(_ blob: Data, pa: UInt32, length: UInt32) throws -> Data {
        var dt = try DeviceTree(blob)
        guard let spare = dt.props["chosen/memory-map"]?.keys.filter({ $0.hasPrefix("MemoryMapReserved-") }).sorted().first else {
            throw FirmwareError(.unsupported, "no spare chosen/memory-map slot")
        }
        try dt.rename("chosen/memory-map", spare, "RAMDisk")
        try dt.set("chosen/memory-map", "RAMDisk", .words([pa, length]))
        try dt.set("chosen", "root-matching", .bytes(Data()))
        guard dt.data.count == blob.count else { throw FirmwareError(.internal, "DeviceTree changed size") }
        return dt.data
    }

    /// Stop at the kernel's entry and give it the ramdisk the way iBoot's restore path does.
    static func handoff(_ gdb: GDBRemote, kernelcache: Data, ramdisk: Data) throws -> String {
        let (pc, base) = try kernelEntry(kernelcache)
        let entry = pc &- base &+ physBase
        guard try gdb.command(String(format: "Z0,%x,4", entry)) == "OK" else { throw FirmwareError(.oneshotFailed, "gdbstub refused the breakpoint") }
        let stop = try gdb.command("c")
        let regs = try gdb.registers()
        guard stop.hasPrefix("T"), regs[15] == entry else {
            throw FirmwareError(.oneshotFailed, "keybag boot did not stop at the kernel entry: \(stop) pc=\(String(regs[15], radix: 16))")
        }
        _ = try gdb.command(String(format: "z0,%x,4", entry))
        let ba = regs[0]
        var args = try gdb.read(ba, 0x138)
        func u32(_ o: Int) -> UInt32 { args.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) } }
        let rev = UInt16(args[0]) | UInt16(args[1]) << 8
        let virt = u32(4), phys = u32(8), mem = u32(12), top = u32(16), dtp = u32(0x30), dtlen = u32(0x34)
        guard rev == 1, phys == physBase, virt == base else { throw FirmwareError(.oneshotFailed, "unexpected boot_args at 0x\(String(ba, radix: 16))") }
        let rdPA = (top + 0xFFF) & ~0xFFF
        let newTop = (rdPA + UInt32(ramdisk.count) + 0x3FFF) & ~0x3FFF
        guard newTop < phys + mem else { throw FirmwareError(.oneshotFailed, "the ramdisk does not fit below memSize") }
        let dtPA = dtp - virt + phys
        try gdb.write(dtPA, try addRamdisk(try gdb.read(dtPA, Int(dtlen)), pa: rdPA, length: UInt32(ramdisk.count)))
        try gdb.write(rdPA, ramdisk)
        let line = String(decoding: args[cmdlineOffset..<cmdlineOffset + cmdlineLength].prefix { $0 != 0 }, as: UTF8.self)
        guard line.split(separator: " ").contains("rd=md0") else { throw FirmwareError(.oneshotFailed, "iBoot's command line lacks rd=md0: [\(line)]") }
        withUnsafeBytes(of: newTop.littleEndian) { args.replaceSubrange(0x10..<0x14, with: $0) }
        try gdb.write(ba, args)
        try gdb.send("c")
        return String(format: "keybag boot: ramdisk %d bytes at 0x%08x, topOfKernelData 0x%08x -> 0x%08x, [%@]", ramdisk.count, rdPA, top, newTop, line)
    }

    /// ipod2g_keybag.fold_overlay: the overlay's page files over the device's.
    static func foldOverlay(_ ovl: URL, into nand: URL) throws -> Int {
        let fm = FileManager.default
        var n = 0
        for cs in try fm.contentsOfDirectory(atPath: ovl.path).sorted() {
            for name in try fm.contentsOfDirectory(atPath: ovl.appendingPathComponent(cs).path) {
                if name.hasSuffix(".erased") { throw FirmwareError(.oneshotFailed, "erase markers in the keybag overlay; not folding") }
                guard name.hasSuffix(".page"), !name.hasPrefix(".") else { continue }
                let dst = nand.appendingPathComponent(cs).appendingPathComponent(name)
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: ovl.appendingPathComponent(cs).appendingPathComponent(name), to: dst)
                n += 1
            }
        }
        return n
    }
}

/// Just enough of the gdb remote protocol (QEMU's gdbstub): breakpoints, registers, memory, continue.
final class GDBRemote {
    let fd: Int32
    var buffer = [UInt8]()

    /// A port nothing listens on now.
    static func freePort() throws -> Int {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(s) }
        var a = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                            sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) == 0 && getsockname(s, $0, &len) == 0 }
        }
        guard ok else { throw FirmwareError(.internal, "no free TCP port") }
        return Int(UInt16(bigEndian: a.sin_port))
    }

    /// Connects, retrying for up to 10 s while the helper starts QEMU.
    init(port: Int) throws {
        for _ in 0..<100 {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            var a = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                sin_port: UInt16(port).bigEndian, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
            let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
            if ok {
                var tv = timeval(tv_sec: 120, tv_usec: 0)   // `c` waits for iBoot to reach the kernel
                setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                fd = s
                return
            }
            close(s)
            usleep(100_000)
        }
        throw FirmwareError(.oneshotFailed, "no gdbstub on port \(port)")
    }

    deinit { close(fd) }

    func send(_ text: String) throws { try send(bytes: Array(text.utf8)) }

    func send(bytes body: [UInt8]) throws {
        let packet = Array("$".utf8) + body + Array(String(format: "#%02x", body.reduce(0) { ($0 + Int($1)) & 0xFF }).utf8)
        guard packet.withUnsafeBytes({ Darwin.send(fd, $0.baseAddress, $0.count, 0) }) == packet.count else {
            throw FirmwareError(.oneshotFailed, "gdbstub send failed")
        }
    }

    func receive() throws -> String {
        while true {
            if let i = buffer.firstIndex(of: UInt8(ascii: "$")), let j = buffer[i...].firstIndex(of: UInt8(ascii: "#")), buffer.count >= j + 3 {
                let data = String(decoding: buffer[(i + 1)..<j], as: UTF8.self)
                buffer.removeFirst(j + 3)
                _ = Darwin.send(fd, "+", 1, 0)
                return data
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { throw FirmwareError(.oneshotFailed, "gdbstub closed") }
            buffer += chunk.prefix(n)
        }
    }

    func command(_ text: String) throws -> String { try send(text); return try receive() }
    func command(bytes: [UInt8]) throws -> String { try send(bytes: bytes); return try receive() }

    func registers() throws -> [UInt32] {
        let g = Array(try command("g").utf8)
        guard g.count >= 128 else { throw FirmwareError(.oneshotFailed, "short register reply") }
        return (0..<16).map { i in
            let bytes = Self.unhex(g[(i * 8)..<(i * 8 + 8)])
            return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        }
    }

    func read(_ address: UInt32, _ count: Int) throws -> Data {
        var out = Data()
        while out.count < count {
            let k = min(0x800, count - out.count)
            let r = Array(try command(String(format: "m%x,%x", address + UInt32(out.count), k)).utf8)
            guard r.count == 2 * k else { throw FirmwareError(.oneshotFailed, "gdb read at 0x\(String(address, radix: 16)): \(String(decoding: r.prefix(8), as: UTF8.self))") }
            out += Self.unhex(r[...])
        }
        return out
    }

    /// In 1 KiB packets: QEMU's packet buffer is 4 KiB of hex.
    func write(_ address: UInt32, _ data: Data) throws {
        let b = [UInt8](data)
        for off in stride(from: 0, to: b.count, by: 0x400) {
            let part = b[off..<min(off + 0x400, b.count)]
            var packet = Array(String(format: "M%x,%x:", address + UInt32(off), part.count).utf8)
            for x in part { packet.append(Self.digits[Int(x >> 4)]); packet.append(Self.digits[Int(x & 15)]) }
            let r = try command(bytes: packet)
            guard r == "OK" else { throw FirmwareError(.oneshotFailed, "gdb write at 0x\(String(address + UInt32(off), radix: 16)): \(r)") }
        }
    }

    static let digits = Array("0123456789abcdef".utf8)

    static func unhex(_ s: ArraySlice<UInt8>) -> [UInt8] {
        func v(_ c: UInt8) -> UInt8 { c >= 97 ? c - 87 : c >= 65 ? c - 55 : c - 48 }
        return stride(from: s.startIndex, to: s.endIndex - 1, by: 2).map { v(s[$0]) << 4 | v(s[$0 + 1]) }
    }
}
