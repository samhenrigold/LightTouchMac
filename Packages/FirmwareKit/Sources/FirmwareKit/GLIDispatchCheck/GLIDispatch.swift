// The GLI shim's dispatch ABI. The table comes from the IPSW's own shared cache at prepare time
// (the @encode of __GLIFunctionDispatchRec in OpenGLES + which slots OpenGLES exports a trampoline
// for), as contrib/ipad1-gles/glitsv.py derives it; per-function facts (GLEngine ES1/ES2 fills, the
// 3.1.3 wire slot, the macOS prototype) are carried by field name from a base table. The recipe checks
// the generated table against the shim's ABI (the table the shim was generated from) before
// installing it: ipad1_rootfs.gli_abi_problem / gli_engine / gld_problem.
import Foundation

public enum GLIDispatch {
    static let openGLES = "/System/Library/Frameworks/OpenGLES.framework/OpenGLES"
    static let libGFXShared = "/System/Library/Frameworks/OpenGLES.framework/libGFXShared.dylib"
    static let tableOffset = 0x10, gcOffset = 0xC, tsdOffset = 0xC0     // as contrib/it-gles/genstubs.py
    static let columns = ["slot", "byte_off", "eagl_ctx_off", "dispatch_field", "gl_function", "es1_filled",
                          "es2_filled", "OpenGLES_export", "slot_3.1.3", "macOS_gliDispatch_prototype"]

    /// A gli-dispatch TSV: comment/header lines, then one row per slot (lines starting with a digit).
    public struct Table: Sendable, Equatable {
        public var header: [String]
        public var rows: [[String]]
        public init(header: [String], rows: [[String]]) { self.header = header; self.rows = rows }
        public init(tsv: String) {
            var h: [String] = [], r: [[String]] = []
            for line in tsv.split(separator: "\n", omittingEmptySubsequences: false).dropLast(tsv.hasSuffix("\n") ? 1 : 0) {
                if line.first?.isNumber == true && line.first!.isASCII {
                    r.append(line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init))
                } else { h.append(String(line)) }
            }
            self.init(header: h, rows: r)
        }
        public init(contentsOf url: URL) throws { self.init(tsv: try String(contentsOf: url, encoding: .utf8)) }
        /// dispatch_field per slot: the ABI.
        public var fields: [String] { rows.map { $0.count > 3 ? $0[3] : "" } }
        /// Slots OpenGLES exports a trampoline for.
        public var exports: Set<Int> { Set(rows.filter { $0.count > 7 && $0[7] == "Y" }.compactMap { Int($0[0]) }) }
        public var tsv: String { (header + rows.map { $0.joined(separator: "\t") }).joined(separator: "\n") + "\n" }
    }

    public enum Verdict: Equatable, Sendable {
        case compatible
        case incompatible(String)
        public var reason: String? { if case .incompatible(let r) = self { return r }; return nil }
    }

    // MARK: firmware side

    /// The dispatch_field list from the first `{__GLIFunctionDispatchRec=...}` @encode in `data`.
    public static func fields(in data: Data) -> [String]? {
        data.withUnsafeBytes { b -> [String]? in
            let needle = Array("{__GLIFunctionDispatchRec=".utf8)
            guard let base = b.baseAddress,
                  let hit = needle.withUnsafeBytes({ memmem(base, b.count, $0.baseAddress, needle.count) }) else { return nil }
            var i = base.distance(to: UnsafeRawPointer(hit)) + needle.count
            var end = i
            while end < b.count && b[end] != UInt8(ascii: "}") { end += 1 }
            guard end < b.count else { return nil }
            var out: [String] = []
            while i < end {                               // re.findall(rb'"([^"]+)"')
                guard b[i] == UInt8(ascii: "\"") else { i += 1; continue }
                var j = i + 1
                while j < end && b[j] != UInt8(ascii: "\"") { j += 1 }
                guard j < end else { break }
                if j > i + 1 { out.append(String(decoding: b[(i + 1)..<j], as: UTF8.self)); i = j + 1 } else { i += 1 }
            }
            return out
        }
    }

    /// {slot: export name without the underscore}: each `_gl*` export of OpenGLES loads its target with one
    /// `ldr rX, [rY, #off]` that a `blx/bx rX` then calls; slot = (off - 0x10) / 4 (glitsv.exports).
    public static func exports(_ cache: DyldSharedCache, slots: Int, warn: (String) -> Void = { _ in }) throws -> [Int: String] {
        guard let img = cache.image(openGLES) else { throw FirmwareError(.unsupported, "no OpenGLES image in the cache") }
        var out: [Int: String] = [:]
        var syms: [DyldSharedCache.Symbol] = []
        cache.forEachSymbol(in: img) { s in
            if s.name.hasPrefix("_gl") && s.type & 0x0F == 0x0F { syms.append(s) }   // N_SECT | N_EXT
            return true
        }
        try cache.data.withUnsafeBytes { b in
            for s in syms {
                guard let fo = cache.fileOffset(of: UInt64(s.value)) else { throw FirmwareError(.internal, "\(s.name) not mapped") }
                let code = UnsafeRawBufferPointer(rebasing: b[fo..<min(fo + 96, b.count)])
                let offs = callLoads(code, thumb: s.desc & 8 != 0)
                    .filter { $0 != gcOffset && $0 != tsdOffset && $0 >= tableOffset && $0 < tableOffset + 4 * slots }
                if offs.count == 1 {
                    out[(offs.first! - tableOffset) / 4] = String(s.name.dropFirst())
                } else if !offs.isEmpty {
                    warn("skip \(s.name): ambiguous [\(offs.map { "'" + hex($0) + "'" }.sorted().joined(separator: ", "))]")
                }
            }
        }
        return out
    }

    /// The immediate offsets of the loads a register call goes through, up to the first `pop {..., pc}`.
    /// A decoder for exactly what glitsv.py matches in capstone's text: `ldr* rT, [rN, #0xOFF]` with rN in
    /// r0-r8 and OFF > 9 (capstone prints smaller immediates in decimal), then an unconditional `blx/bx rT`.
    /// ponytail: only the load/branch/pop/IT forms trampolines use are decoded; any other instruction is
    /// just skipped by its length. Enough for the 3.x/4.x OpenGLES caches (checked against glitsv.py).
    static func callLoads(_ c: UnsafeRawBufferPointer, thumb: Bool) -> Set<Int> {
        var loads: [Int: Int] = [:], offs = Set<Int>()
        func load(_ rt: Int, _ rn: Int, _ imm: Int) { if rn <= 8 && imm > 9 { loads[rt] = imm } }
        func call(_ rm: Int) { if let o = loads[rm] { offs.insert(o) } }
        var pos = 0
        if thumb {
            var itLeft = 0, itConditional = false
            while pos + 2 <= c.count {
                let h1 = Int(c.u16le(pos))
                let wide = [0x1d, 0x1e, 0x1f].contains(h1 >> 11)
                if wide && pos + 4 > c.count { break }
                let conditional = itLeft > 0 && itConditional
                if itLeft > 0 { itLeft -= 1 }
                if !wide {
                    pos += 2
                    switch h1 {
                    case _ where h1 & 0xF800 == 0x6800: load(h1 & 7, (h1 >> 3) & 7, ((h1 >> 6) & 0x1F) * 4)   // ldr
                    case _ where h1 & 0xF800 == 0x7800: load(h1 & 7, (h1 >> 3) & 7, (h1 >> 6) & 0x1F)         // ldrb
                    case _ where h1 & 0xF800 == 0x8800: load(h1 & 7, (h1 >> 3) & 7, ((h1 >> 6) & 0x1F) * 2)   // ldrh
                    case _ where h1 & 0xFF07 == 0x4780 || h1 & 0xFF07 == 0x4700:                              // blx/bx rm
                        if !conditional { call((h1 >> 3) & 0xF) }
                    case _ where h1 & 0xFF00 == 0xBD00: return offs                                          // pop {..., pc}
                    case _ where h1 & 0xFF00 == 0xBF00 && h1 & 0xF != 0:                                     // it
                        itLeft = 4 - (h1 & 0xF).trailingZeroBitCount
                        itConditional = (h1 >> 4) & 0xF != 0xE
                    default: break
                    }
                    continue
                }
                let h2 = Int(c.u16le(pos + 2))
                pos += 4
                let rn = h1 & 0xF, rt = h2 >> 12
                switch h1 & 0xFFF0 {
                case 0xF8D0: load(rt, rn, h2 & 0xFFF)                                                        // ldr.w
                case 0xF890, 0xF8B0, 0xF990, 0xF9B0: if rt != 15 { load(rt, rn, h2 & 0xFFF) }                // ldrb/h, ldrsb/h.w
                case 0xF850, 0xF810, 0xF830, 0xF910, 0xF930:                                                 // T4: [rn, #+imm8]{!}, ldrt
                    if h2 & 0x0800 != 0 && h2 & 0x0600 == 0x0600 && !(rt == 15 && h1 & 0xFFF0 != 0xF850) { load(rt, rn, h2 & 0xFF) }
                    if h1 == 0xF85D && h2 == 0xFB04 { return offs }                                          // ldr pc, [sp], #4
                default:
                    if h1 == 0xE8BD && h2 & 0x8000 != 0 { return offs }                                      // pop.w {..., pc}
                }
            }
        } else {
            while pos + 4 <= c.count {
                let w = Int(c.u32le(pos))
                pos += 4
                let cond = w >> 28
                if cond == 0xF { continue }
                if w & 0x0E500000 == 0x04100000 || w & 0x0E500000 == 0x04500000 {                           // ldr/ldrb imm12
                    if w & 0x01800000 == 0x01800000 { load((w >> 12) & 0xF, (w >> 16) & 0xF, w & 0xFFF) }    // P=1, U=1
                    if w & 0x0FFFFFFF == 0x049DF004 { return offs }                                          // pop {pc}
                } else if w & 0x0FFFFFD0 == 0x012FFF10 {                                                     // bx/blx rm
                    if cond == 0xE { call(w & 0xF) }
                } else if w & 0x0FFF0000 == 0x08BD0000 && w & 0x8000 != 0 {                                  // pop {..., pc}
                    return offs
                }
            }
        }
        return offs
    }

    /// glitsv.derive: the firmware's table, with the per-function facts carried from `base` by field name.
    public static func generate(sharedCache cache: DyldSharedCache, build: String, base: Table, baseName: String = "gli-dispatch-7B500.tsv",
                                warn: (String) -> Void = { _ in }) throws -> Table {
        guard let fl = fields(in: cache.data) else { throw FirmwareError(.unsupported, "no __GLIFunctionDispatchRec @encode in the shared cache") }
        let ex = try exports(cache, slots: fl.count, warn: warn)
        var by: [String: [String]] = [:]
        for r in base.rows where r.count > 3 { by[r[3]] = r }
        var rows: [[String]] = []
        for (slot, field) in fl.enumerated() {
            let b = by[field]
            let derived = "gl" + field.split(separator: "_", omittingEmptySubsequences: false)
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined() + "*"
            let name = ex[slot] ?? (b?[4] ?? derived)
            let (es1, es2, w313, proto) = b.map { ($0[5], $0[6], $0[8], $0.count > 9 ? $0[9] : "") } ?? ("", "", "-", "")
            rows.append([String(slot), String(format: "0x%03x", 4 * slot), String(format: "0x%03x", 4 * slot + tableOffset), field, name,
                         es1, es2, ex[slot] != nil ? "Y" : "", w313, proto])
        }
        let header = [
            "# __GLIFunctionDispatchRec for \(build), \(fl.count) slots (0x\(String(format: "%X", 4 * fl.count + tableOffset)) bytes), generated by contrib/ipad1-gles/glitsv.py.",
            "# From this firmware: slot/dispatch_field (@encode in OpenGLES) and OpenGLES_export (trampolines). Carried from",
            "# \(baseName) by dispatch_field: gl_function (unless exported), es1/es2_filled, slot_3.1.3, prototype; - = no wire slot.",
            columns.joined(separator: "\t"),
        ]
        return Table(header: header, rows: rows)
    }

    // MARK: verdicts

    /// Whether a shim generated from `shim` fits a firmware whose table is `table`: the dispatch fields must be
    /// the same, in order.
    public static func compatibility(_ table: Table, shim: Table, shimName: String = "the shim's table") -> Verdict {
        compatibility(fields: table.fields, shim: shim, shimName: shimName)
    }

    static func compatibility(fields have: [String], shim: Table, shimName: String) -> Verdict {
        let want = shim.fields
        guard have != want else { return .compatible }
        let diff = zip(have, want).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(have.count, want.count)
        return .incompatible("dispatch table differs from \(shimName) at slot \(diff) (\(have.count) vs \(want.count) slots)")
    }

    /// ipad1_rootfs.gli_abi_problem: nil if the cache's __GLIFunctionDispatchRec fields are the TSV's, in order.
    public static func abiProblem(cache data: Data, cachePath: String, tsv: URL) throws -> String? {
        guard let have = fields(in: data) else { return "no __GLIFunctionDispatchRec @encode in \(cachePath)" }
        return compatibility(fields: have, shim: try Table(contentsOf: tsv), shimName: tsv.lastPathComponent).reason
    }

    /// ipad1_rootfs.gli_engine: the first TSV (in sorted path order) the cache fits, else every TSV's reason.
    public static func engine(cache data: Data, cachePath: String, tsvs: [URL]) throws -> (tsv: URL?, why: String?) {
        var whys: [String] = []
        for tsv in tsvs.sorted(by: { $0.path < $1.path }) {
            guard let why = try abiProblem(cache: data, cachePath: cachePath, tsv: tsv) else { return (tsv, nil) }
            whys.append(why)
        }
        return (nil, whys.joined(separator: "; "))
    }

    /// glitsv.verify: nil if the TSV's fields and export column are this cache's.
    public static func verify(_ cache: DyldSharedCache, tsv: Table) throws -> String? {
        guard let fl = fields(in: cache.data) else { return "no __GLIFunctionDispatchRec @encode" }
        if tsv.fields != fl { return "dispatch fields differ" }
        let have = Set(try exports(cache, slots: fl.count).keys), want = tsv.exports
        if have != want { return "export column differs: +\(have.subtracting(want).sorted()) -\(want.subtracting(have).sorted())" }
        return nil
    }

    /// ipad1_rootfs.gld_problem: (needed, why). Needed when this firmware's EAGL takes a libGFXShared shared
    /// state (4.x: OpenGLES imports gfxCreateSharedState); why is nil when the gld plugin exports every
    /// gld* entry point libGFXShared dlsyms.
    public static func gldProblem(_ cache: DyldSharedCache, plugin: URL) -> (needed: Bool, why: String?) {
        guard let ogl = cache.image(openGLES), cache.symbolNames(in: ogl).contains("_gfxCreateSharedState") else { return (false, nil) }
        guard let gfx = cache.image(libGFXShared) else { return (true, "OpenGLES imports gfxCreateSharedState but the cache has no libGFXShared") }
        let want = cache.cStrings(in: gfx, section: "__cstring").filter { $0.wholeMatch(of: /gld[A-Z]\w+/) != nil }
        guard let have = try? Data(contentsOf: plugin) else { return (true, "\(plugin.path) missing (run contrib/ipad1-gles/build.sh)") }
        let lost = want.filter { have.range(of: Data(("\0_" + $0 + "\0").utf8)) == nil }
        return (true, !lost.isEmpty || want.isEmpty ? "gldshim lacks \(lost.joined(separator: ", "))" : nil)
    }
}
