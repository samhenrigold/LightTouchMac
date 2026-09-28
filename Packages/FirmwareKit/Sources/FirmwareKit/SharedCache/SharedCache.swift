// dyld_v1 shared caches (iOS 3.x/4.x, armv6/armv7): mappings, cached images, each image's own
// LC_SYMTAB (cache file offsets: the old caches keep an unslid linkedit), and the AppSync patch.
// Port of imgtools/appsync_cachepatch.py and ipad1_rootfs.cache_images/image_strings.
import Foundation

extension UnsafeRawBufferPointer {
    func u16le(_ o: Int) -> UInt16 { UInt16(littleEndian: loadUnaligned(fromByteOffset: o, as: UInt16.self)) }
    func u32le(_ o: Int) -> UInt32 { UInt32(littleEndian: loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
    func u64le(_ o: Int) -> UInt64 { UInt64(littleEndian: loadUnaligned(fromByteOffset: o, as: UInt64.self)) }
    func u32be(_ o: Int) -> UInt32 { UInt32(bigEndian: loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
    /// Offset of the first NUL at or after `o` (the end if there is none).
    func nulIndex(from o: Int) -> Int {
        var i = o
        while i < count && self[i] != 0 { i += 1 }
        return i
    }
    /// The NUL-terminated bytes at `o`.
    func cBytes(_ o: Int) -> UnsafeRawBufferPointer { UnsafeRawBufferPointer(rebasing: self[o..<nulIndex(from: o)]) }
    func latin1(_ o: Int) -> String { String(cBytes(o).map { Character(Unicode.Scalar($0)) }) }
}

public struct DyldSharedCache: @unchecked Sendable {
    public struct Mapping: Sendable { public let address: UInt64, size: UInt64, fileOffset: UInt64 }
    public struct Image: Sendable { public let path: String; public let address: UInt64; public let headerOffset: Int }
    public struct Symbol: Sendable { public let name: String; public let type: UInt8; public let desc: UInt16; public let value: UInt32 }

    /// The whole cache, memory-mapped (never copied).
    public let data: Data
    public let mappings: [Mapping]
    public let images: [Image]

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        self.data = data
        guard data.count >= 0x20, data.prefix(7) == Data("dyld_v1".utf8) else {
            throw FirmwareError(.unsupported, "not a dyld_v1 shared cache")
        }
        let (maps, imgs): ([Mapping], [(UInt64, Int)]) = data.withUnsafeBytes { b in
            let (mo, mc, io, ic) = (Int(b.u32le(0x10)), Int(b.u32le(0x14)), Int(b.u32le(0x18)), Int(b.u32le(0x1c)))
            let maps = (0..<mc).map { i in Mapping(address: b.u64le(mo + 32 * i), size: b.u64le(mo + 32 * i + 8), fileOffset: b.u64le(mo + 32 * i + 16)) }
            return (maps, (0..<ic).map { i in (b.u64le(io + 32 * i), Int(b.u32le(io + 32 * i + 24))) })
        }
        mappings = maps
        func offset(_ a: UInt64) -> Int? {
            maps.first { $0.address <= a && a < $0.address + $0.size }.map { Int($0.fileOffset + a - $0.address) }
        }
        images = data.withUnsafeBytes { b in
            imgs.map { va, p in Image(path: b.latin1(p), address: va, headerOffset: offset(va) ?? -1) }
        }
    }

    public func fileOffset(of address: UInt64) -> Int? {
        mappings.first { $0.address <= address && address < $0.address + $0.size }.map { Int($0.fileOffset + address - $0.address) }
    }

    public func image(_ path: String) -> Image? { images.first { $0.path == path } }

    /// Walks an image's load commands: (cmd, offset of the command) for each.
    func loadCommands(_ img: Image, _ body: (UInt32, Int, UnsafeRawBufferPointer) -> Void) {
        data.withUnsafeBytes { b in
            let h = img.headerOffset
            guard h >= 0, b.u32le(h) == 0xFEEDFACE else { return }
            var off = h + 28
            for _ in 0..<b.u32le(h + 16) {
                body(b.u32le(off), off, b)
                off += Int(b.u32le(off + 4))
            }
        }
    }

    /// The image's LC_SYMTAB entries in table order; `body` returns false to stop.
    public func forEachSymbol(in img: Image, _ body: (Symbol) -> Bool) {
        var tab: (Int, Int, Int)?
        loadCommands(img) { cmd, off, b in
            if cmd == 2 { tab = (Int(b.u32le(off + 8)), Int(b.u32le(off + 12)), Int(b.u32le(off + 16))) }
        }
        guard let (symoff, nsyms, stroff) = tab else { return }
        data.withUnsafeBytes { b in
            for s in 0..<nsyms {
                let e = symoff + 12 * s
                let sym = Symbol(name: b.latin1(stroff + Int(b.u32le(e))), type: b[e + 4], desc: b.u16le(e + 6), value: b.u32le(e + 8))
                if !body(sym) { return }
            }
        }
    }

    public func symbolNames(in img: Image) -> [String] {
        var out: [String] = []
        forEachSymbol(in: img) { out.append($0.name); return true }
        return out
    }

    /// The C strings of one of the image's sections (e.g. "__cstring"), as image_strings(section=) gives them.
    public func cStrings(in img: Image, section: String) -> [String] {
        var out: [String] = []
        loadCommands(img) { cmd, off, b in
            guard cmd == 1 else { return }
            for k in 0..<Int(b.u32le(off + 48)) {
                let so = off + 56 + 68 * k
                guard String(decoding: b.cBytes(so).prefix(16), as: UTF8.self) == section,
                      let start = fileOffset(of: UInt64(b.u32le(so + 32))) else { continue }
                let bytes = b[start..<start + Int(b.u32le(so + 36))]
                out += bytes.split(separator: 0).map { String($0.map { Character(Unicode.Scalar($0)) }) }
            }
        }
        return out
    }

    /// (address, Thumb) of an N_SECT symbol with a non-zero value, searching every image's symbol table in
    /// cache order (appsync_cachepatch.find_symbol).
    public func findSymbol(_ name: String) throws -> (address: UInt64, thumb: Bool) {
        let want = Array(name.utf8)
        for img in images {
            guard img.headerOffset >= 0 else { throw FirmwareError(.internal, "VA \(hex(img.address)) not in any mapping") }
            var hit: (UInt64, Bool)?
            var tab: (Int, Int, Int)?
            loadCommands(img) { cmd, off, b in
                if cmd == 2 { tab = (Int(b.u32le(off + 8)), Int(b.u32le(off + 12)), Int(b.u32le(off + 16))) }
            }
            guard let (symoff, nsyms, stroff) = tab else { continue }
            data.withUnsafeBytes { b in
                for s in 0..<nsyms {
                    let e = symoff + 12 * s
                    let value = b.u32le(e + 8)
                    guard value != 0, b[e + 4] & 0x0e == 0x0e else { continue }
                    if b.cBytes(stroff + Int(b.u32le(e))).elementsEqual(want) {
                        hit = (UInt64(value), b.u16le(e + 6) & 0x0008 != 0)   // N_ARM_THUMB_DEF
                        return
                    }
                }
            }
            if let (a, t) = hit { return (a, t) }
        }
        throw FirmwareError(.unsupported, "\(name) not found in cache image symbol tables")
    }
}

func hex<T: BinaryInteger>(_ v: T) -> String { "0x" + String(v, radix: 16) }

/// The amfid half of AppSync: MISValidateSignature -> `movs r0,#0; bx lr`, located by symbol and
/// byte-checked (a Thumb `push {..., lr}` entry) before anything is written.
public enum AppSyncCachePatch {
    public static let target = "_MISValidateSignature"
    public static let patch: [UInt8] = [0x00, 0x20, 0x70, 0x47]

    static func looksLikeThumbEntry(_ b: [UInt8]) -> Bool {
        let hw = UInt16(b[0]) | UInt16(b[1]) << 8
        if hw & 0xFF00 == 0xB500 { return true }                        // push {..., lr}
        if hw == 0xE92D { return (UInt16(b[2]) | UInt16(b[3]) << 8) & 0x4000 != 0 }   // push.w with LR
        return false
    }

    /// Locates and (with `apply`) patches the cache in place. Returns appsync_cachepatch's status line;
    /// throws on a prologue that is not a Thumb function entry.
    @discardableResult
    public static func patchCache(at url: URL, apply: Bool = true) throws -> String {
        let cache = try DyldSharedCache(contentsOf: url)
        let (va, thumb) = try cache.findSymbol(target)
        guard let foff = cache.fileOffset(of: va) else { throw FirmwareError(.internal, "VA \(hex(va)) not in any mapping") }
        let cur = [UInt8](cache.data[foff..<foff + 4])
        let curHex = cur.map { String(format: "%02x", $0) }.joined(), patchHex = "00207047"
        if cur == patch { return "\(target) already patched (VA \(hex(va)) off \(hex(foff)))" }
        guard thumb, looksLikeThumbEntry(cur) else {
            throw FirmwareError(.unsupported, "\(target) prologue \(curHex) at \(hex(foff)) is not a Thumb function entry — refusing to patch")
        }
        if !apply { return "would patch \(target) \(curHex) -> \(patchHex) at \(hex(foff))" }
        let fh = try FileHandle(forUpdating: url)
        defer { try? fh.close() }
        try fh.seek(toOffset: UInt64(foff))
        try fh.write(contentsOf: Data(patch))
        return "patched \(target) \(curHex) -> \(patchHex) (VA \(hex(va)) off \(hex(foff)))"
    }
}
