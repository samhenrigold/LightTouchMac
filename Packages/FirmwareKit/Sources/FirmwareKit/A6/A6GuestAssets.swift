import Crypto
import Foundation

/// The local guest support files selected by the A6 preparation recipe.
/// Register exact, page-verified files while retaining the native trust set.
public enum A6GuestAssets {
    public struct Asset: Codable, Sendable {
        public let path: String, sha256: String
        public let codeDirectories: [String]
    }
    public struct Result: Sendable {
        public let kernel: Data
        public let assets: [Asset]
    }
    private static let sharedCachePath = "System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7s"
    private static let paths = [
        "System/Library/Frameworks/OpenGLES.framework/OpenGLES",
        "usr/local/bin/it_agent", "usr/local/bin/it_install", "usr/local/bin/it_netcheck",
        "usr/lib/libappsync.dylib", "usr/libexec/installd",
        "System/Library/Caches/com.apple.xpcd/xpcd_cache.dylib",
        sharedCachePath
    ]
    private static let ios9KernelSHA256 = "6591c8ae828298cf0131ed98e0dfa234c1dabadbb6bd8ce47b4a361733645bdc"

    public static func prepare(kernel: Data, system: URL, restoreRAMDisk: URL? = nil) throws -> Result {
        let volume = try HFSPlusVolume(system)
        var assets: [Asset] = []
        var hashes = Set<Data>()
        // 13A344's qualified preparation needs only the edited cache's exact
        // identity. Do not broaden that recipe to unrelated support binaries.
        let kernelHash = Preparer.sha256(kernel)
        var selected = kernelHash == ios9KernelSHA256 ? [sharedCachePath] : paths
        if kernelHash == "bbc90ec2bd9ce1cc43c6a98b47d39348d63443b5d6c22293f23a1f43bebe4b46" {
            selected += try A6FirstBoot.preparedPaths(in: volume)
        }
        // Optional preparation-only sealer; never broaden older recipes or
        // accept a caller-supplied digest in place of verifying the staged file.
        if kernelHash == "bbc90ec2bd9ce1cc43c6a98b47d39348d63443b5d6c22293f23a1f43bebe4b46",
            (try? volume.record(at: A6Sealing.executable)) != nil
        {
            selected.append(A6Sealing.executable)
        }
        for path in selected {
            let bytes = try volume.contents(volume.record(at: path))
            let directories = try verifiedCodeDirectories(bytes)
            hashes.formUnion(directories)
            assets.append(
                Asset(
                    path: path, sha256: Preparer.sha256(bytes),
                    codeDirectories: directories.map(\.hexString)))
        }
        if let restoreRAMDisk,
            Preparer.sha256(kernel) == "bbc90ec2bd9ce1cc43c6a98b47d39348d63443b5d6c22293f23a1f43bebe4b46"
        {
            // The temporary restore environment executes our initializer and
            // cache worker too. Derive their identities from the staged files,
            // using exactly the same signed-page validation as System support.
            let restore = try HFSPlusVolume(restoreRAMDisk)
            for path in ["usr/local/bin/restored_external", "usr/local/bin/it_mobilegestalt"] {
                guard let record = try? restore.record(at: path) else { continue }
                let bytes = try restore.contents(record)
                let directories = try verifiedCodeDirectories(bytes)
                hashes.formUnion(directories)
                assets.append(
                    Asset(
                        path: "restore:/" + path, sha256: Preparer.sha256(bytes),
                        codeDirectories: directories.map(\.hexString)))
            }
        }
        return Result(kernel: try registering(hashes, in: kernel), assets: assets)
    }

    private static func invalid(_ detail: String) -> FirmwareError {
        FirmwareError(.unsupported, "A6 guest assets: " + detail)
    }

    private static func number(_ b: Data, _ offset: Int, count: Int = 4, big: Bool = false) throws -> Int {
        guard offset >= 0, offset <= b.count - count, (1...8).contains(count) else {
            throw invalid("truncated metadata")
        }
        var value: UInt64 = 0
        for i in 0..<count { value |= UInt64(b[offset + i]) << (8 * (big ? count - 1 - i : i)) }
        guard value <= UInt64(Int.max) else { throw invalid("metadata integer overflow") }
        return Int(value)
    }

    /// Validate every signed page before deriving the native architecture's
    /// CodeDirectory identities. No caller-supplied digest strings are used.
    static func verifiedCodeDirectories(_ bytes: Data) throws -> [Data] {
        var base = 0
        var size = bytes.count
        var signature = 0
        var allocation = 0
        if bytes.starts(with: Data("dyld_v1".utf8)) {
            guard bytes.prefix(16).range(of: Data("armv7s".utf8)) != nil else { throw invalid("not an armv7s cache") }
            signature = try number(bytes, 40, count: 8)
            allocation = try number(bytes, 48, count: 8)
            if allocation == 0 {
                // Older dyld_v1 caches leave codeSignatureSize zero. The
                // signature still has its own bounded SuperBlob length;
                // use EOF as the allocation limit, then validate it below.
                guard signature >= 56, signature <= bytes.count - 12 else {
                    throw invalid("invalid legacy cache signature extent")
                }
                allocation = bytes.count - signature
            }
        } else {
            guard let parsed = MachOSignature.images(bytes) else { throw invalid("not a signed Mach-O") }
            if parsed.fat {
                let count = try number(bytes, 4, big: true)
                var selected: (subtype: Int, base: Int, size: Int)?
                for i in 0..<count {
                    let entry = 8 + i * 20
                    let cpu = try number(bytes, entry, big: true)
                    let sub = try number(bytes, entry + 4, big: true) & 0x00ff_ffff
                    if cpu == 12, [9, 11].contains(sub), sub > (selected?.subtype ?? 0) {
                        selected = (
                            sub, try number(bytes, entry + 8, big: true), try number(bytes, entry + 12, big: true)
                        )
                    }
                }
                guard let selected else { throw invalid("no native ARM slice") }
                base = selected.base
                size = selected.size
            }
            guard size >= 28, base <= bytes.count - size,
                try number(bytes, base) == 0xfeed_face, try number(bytes, base + 4) == 12
            else {
                throw invalid("invalid native slice")
            }
            let commands = try number(bytes, base + 16)
            var cursor = base + 28
            for _ in 0..<commands {
                let command = try number(bytes, cursor)
                let length = try number(bytes, cursor + 4)
                guard length >= 8, cursor <= base + size - length else { throw invalid("invalid load command") }
                if command == 0x1d {
                    guard length >= 16, allocation == 0 else { throw invalid("ambiguous code signature") }
                    signature = base + (try number(bytes, cursor + 8))
                    allocation = try number(bytes, cursor + 12)
                }
                cursor += length
            }
        }
        guard allocation >= 12, signature >= base, signature <= base + size - allocation,
            try number(bytes, signature, big: true) == 0xfade_0cc0
        else { throw invalid("missing code signature") }
        let length = try number(bytes, signature + 4, big: true)
        let count = try number(bytes, signature + 8, big: true)
        guard length >= 12, length <= allocation, count <= (length - 12) / 8 else {
            throw invalid("invalid signature index")
        }
        var directories: [Data] = []
        for i in 0..<count {
            let relative = try number(bytes, signature + 16 + i * 8, big: true)
            guard relative >= 12 + count * 8, relative <= length - 8 else { throw invalid("invalid signature blob") }
            let cd = signature + relative
            let magic = try number(bytes, cd, big: true)
            let cdLength = try number(bytes, cd + 4, big: true)
            guard cdLength >= 8, cdLength <= length - relative else { throw invalid("truncated signature blob") }
            guard magic == 0xfade_0c02 else { continue }
            guard cdLength >= 44 else { throw invalid("truncated CodeDirectory") }
            let version = try number(bytes, cd + 8, big: true)
            let hashes = try number(bytes, cd + 16, big: true)
            let special = try number(bytes, cd + 24, big: true)
            let pages = try number(bytes, cd + 28, big: true)
            let limit = try number(bytes, cd + 32, big: true)
            let width = Int(bytes[cd + 36])
            let kind = bytes[cd + 37]
            let exponent = Int(bytes[cd + 39])
            guard (kind == 1 && width == 20) || (kind == 2 && width == 32),
                (1...20).contains(exponent), limit > 0, limit <= signature - base,
                hashes >= 44 + special * width, hashes <= cdLength,
                pages <= (cdLength - hashes) / width
            else { throw invalid("unsupported signed page layout") }
            if version >= 0x20100 {
                guard cdLength >= 48 else { throw invalid("truncated scatter metadata") }
                let scatter = try number(bytes, cd + 44, big: true)
                if scatter != 0 {
                    // A dyld cache's scatter targets describe its virtual
                    // mappings. CodeDirectory page hashes still cover the
                    // signed file range in slot order; verify every slot
                    // below, including the unmapped link-edit pages.
                    guard bytes.starts(with: Data("dyld_v1".utf8)), scatter >= 48 else {
                        throw invalid("unsupported scatter signature")
                    }
                    var entry = scatter
                    var previousEnd = 0
                    while true {
                        guard entry <= cdLength - 24 else { throw invalid("unterminated scatter vector") }
                        let count = try number(bytes, cd + entry, big: true)
                        let first = try number(bytes, cd + entry + 4, big: true)
                        let target = try number(bytes, cd + entry + 8, count: 8, big: true)
                        let spare = try number(bytes, cd + entry + 16, count: 8, big: true)
                        guard spare == 0 else { throw invalid("unsupported scatter record") }
                        if count == 0 {
                            guard first == 0, target == 0 else { throw invalid("invalid scatter terminator") }
                            break
                        }
                        guard first >= previousEnd, count <= pages, first <= pages - count,
                            target > 0, target % (1 << exponent) == 0
                        else { throw invalid("invalid scatter mapping") }
                        previousEnd = first + count
                        entry += 24
                    }
                }
            }
            let pageSize = 1 << exponent
            guard pages == (limit + pageSize - 1) / pageSize else { throw invalid("incomplete signed pages") }
            func digest(_ data: Data) -> Data {
                kind == 1 ? Data(Insecure.SHA1.hash(data: data)) : Data(SHA256.hash(data: data))
            }
            for page in 0..<pages {
                let data = bytes.subdata(in: (base + page * pageSize)..<(base + min(limit, (page + 1) * pageSize)))
                let expected = bytes.subdata(in: (cd + hashes + page * width)..<(cd + hashes + (page + 1) * width))
                guard digest(data) == expected else { throw invalid("signed page does not match its CodeDirectory") }
            }
            directories.append(Data(digest(bytes.subdata(in: cd..<(cd + cdLength))).prefix(20)))
        }
        guard !directories.isEmpty else { throw invalid("no verified CodeDirectory") }
        return directories
    }

    /// 14G61's native table uses 256 sorted suffix buckets. Retain all stock
    /// entries and lookup instructions; move only expanded buckets into
    /// verified unused header space. Other kernels fail closed.
    static func registering(_ owned: Set<Data>, in kernel: Data) throws -> Data {
        if Preparer.sha256(kernel) == ios9KernelSHA256 {
            return try registeringIOS9(owned, in: kernel)
        }
        guard Preparer.sha256(kernel) == "bbc90ec2bd9ce1cc43c6a98b47d39348d63443b5d6c22293f23a1f43bebe4b46",
            !owned.isEmpty, owned.allSatisfy({ $0.count == 20 })
        else { throw invalid("unsupported kernel or asset inventory") }
        let file = 0x790000
        let header = 0x6fd4
        let oldBase = header + 1024
        let original = kernel.subdata(in: file..<(file + 0x26000))
        guard Preparer.sha256(original) == "ad6cf379d838fcf0fc44d146c19e3e435a3c068b9f6915c8bad2ddd9c2daf2ed",
            original[0x482..<0x12f4].allSatisfy({ $0 == 0 }),
            try number(original, 0x23b4) == 0x5066
        else { throw invalid("native table layout differs") }
        var patched = original
        var native = Set<Data>()
        let newBase = 0x482 + (oldBase - 0x482) % 19
        let delta = (oldBase - newBase) / 19
        var cursor = newBase
        func put(_ value: Int, _ offset: Int, count: Int) {
            for i in 0..<count { patched[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        for first in 0..<256 {
            let count = try number(original, header + first * 4, count: 2)
            let index = try number(original, header + first * 4 + 2, count: 2)
            guard oldBase + (index + count) * 19 <= original.count else { throw invalid("native bucket exceeds image") }
            var entries: [Data] = []
            for i in 0..<count {
                let suffix = original.subdata(in: (oldBase + (index + i) * 19)..<(oldBase + (index + i + 1) * 19))
                entries.append(suffix)
                native.insert(Data([UInt8(first)]) + suffix)
            }
            guard entries == entries.sorted(by: { $0.lexicographicallyPrecedes($1) }) else {
                throw invalid("unsorted native bucket")
            }
            let additions = owned.filter { Int($0[0]) == first && !native.contains($0) }.map { Data($0.dropFirst()) }
            if additions.isEmpty {
                guard index + delta <= 65535 else { throw invalid("bucket index overflow") }
                put(index + delta, header + first * 4 + 2, count: 2)
            } else {
                entries.append(contentsOf: additions)
                entries.sort(by: { $0.lexicographicallyPrecedes($1) })
                guard entries.count <= 65535 else { throw invalid("bucket count overflow") }
                if cursor + entries.count * 19 > 0x12f4 {
                    return try registeringCompact(owned, in: kernel, kext: original)
                }
                put(entries.count, header + first * 4, count: 2)
                put((cursor - newBase) / 19, header + first * 4 + 2, count: 2)
                for entry in entries {
                    patched.replaceSubrange(cursor..<(cursor + 19), with: entry)
                    cursor += 19
                }
            }
        }
        guard native.count == 5635 else { throw invalid("native inventory differs") }
        put(0x807e_7000 + newBase - 0x807e_936e, 0x23b4, count: 4)
        guard patched[0x234c..<0x23b0] == original[0x234c..<0x23b0],
            patched[oldBase..<0x2160d] == original[oldBase..<0x2160d]
        else { throw invalid("native lookup changed") }
        var result = kernel
        result.replaceSubrange(file..<(file + original.count), with: patched)
        return result
    }

    /// Native-qualified 13A344 cache-identity extension. As on 14G61, retain
    /// the stock suffix table and lookup instructions; expanded buckets use
    /// only verified unused header bytes. Unknown layouts fail closed.
    private static func registeringIOS9(_ owned: Set<Data>, in kernel: Data) throws -> Data {
        guard !owned.isEmpty, owned.allSatisfy({ $0.count == 20 }) else {
            throw invalid("invalid iOS 9 asset inventory")
        }
        let file = 0x70c000
        let header = 0x6eb0
        let oldBase = header + 1024
        let literal = 0x3bfc
        let anchor = 0x3bc6
        guard kernel.count >= file + 0x22000 else { throw invalid("truncated iOS 9 kernel") }
        let original = kernel.subdata(in: file..<(file + 0x22000))
        guard Preparer.sha256(original) == "7096ef21f4bfa88072c27ccebc0cb365a6b2d5b3d60caca5c7507f7332993e09",
            try number(original, literal) + anchor == oldBase
        else {
            throw invalid("iOS 9 native table layout differs")
        }
        let newBase = 0x450 + (oldBase - 0x450) % 19
        let delta = (oldBase - newBase) / 19
        guard original[newBase..<0xb44].allSatisfy({ $0 == 0 }) else {
            throw invalid("iOS 9 header padding is in use")
        }
        var patched = original
        var native = Set<Data>()
        var cursor = newBase
        func put(_ value: Int, _ at: Int, count: Int) {
            for i in 0..<count { patched[at + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        for first in 0..<256 {
            let count = try number(original, header + first * 4, count: 2)
            let index = try number(original, header + first * 4 + 2, count: 2)
            guard oldBase + (index + count) * 19 <= 0x1dfeb else {
                throw invalid("iOS 9 bucket exceeds native table")
            }
            var entries: [Data] = []
            for i in 0..<count {
                let entry = original.subdata(in: (oldBase + (index + i) * 19)..<(oldBase + (index + i + 1) * 19))
                entries.append(entry)
                native.insert(Data([UInt8(first)]) + entry)
            }
            guard entries == entries.sorted(by: { $0.lexicographicallyPrecedes($1) }) else {
                throw invalid("unsorted iOS 9 native bucket")
            }
            let additions = owned.filter { Int($0[0]) == first && !native.contains($0) }.map { Data($0.dropFirst()) }
            if additions.isEmpty {
                guard index + delta <= 65535 else { throw invalid("iOS 9 bucket index overflow") }
                put(index + delta, header + first * 4 + 2, count: 2)
            } else {
                entries.append(contentsOf: additions)
                entries.sort(by: { $0.lexicographicallyPrecedes($1) })
                guard entries.count <= 65535, cursor + entries.count * 19 <= 0xb44 else {
                    throw invalid("iOS 9 expanded buckets exceed verified padding")
                }
                put(entries.count, header + first * 4, count: 2)
                put((cursor - newBase) / 19, header + first * 4 + 2, count: 2)
                for entry in entries {
                    patched.replaceSubrange(cursor..<(cursor + 19), with: entry)
                    cursor += 19
                }
            }
        }
        guard native.count == 4921 else { throw invalid("iOS 9 native inventory differs") }
        if owned.isSubset(of: native) { return kernel }
        put((newBase - anchor) & 0xffff_ffff, literal, count: 4)
        guard patched[oldBase..<0x1dfeb] == original[oldBase..<0x1dfeb] else {
            throw invalid("iOS 9 native suffix table changed")
        }
        for i in original.indices where patched[i] != original[i] {
            guard
                (newBase..<cursor).contains(i) || (header..<oldBase).contains(i)
                    || (literal..<(literal + 4)).contains(i)
            else {
                throw invalid("iOS 9 native lookup changed")
            }
        }
        var result = kernel
        result.replaceSubrange(file..<(file + original.count), with: patched)
        return result
    }

    /// When separate expanded buckets do not fit, move the small directory
    /// into the same verified padding and pack the complete catalog into its
    /// original directory+catalog allocation. No executable bytes are moved.
    private static func registeringCompact(_ owned: Set<Data>, in kernel: Data, kext original: Data) throws -> Data {
        let header = 0x6fd4
        let oldBase = header + 1024
        let end = 0x2160d
        let newHeader = 0x484
        let newBase = header
        guard try number(original, 0x23b0) == 0x4c74,
            newHeader + 1024 <= 0x12f4
        else { throw invalid("native directory pointer differs") }
        var native = Set<Data>()
        for first in 0..<256 {
            let count = try number(original, header + first * 4, count: 2)
            let index = try number(original, header + first * 4 + 2, count: 2)
            guard oldBase + (index + count) * 19 <= end else { throw invalid("native catalog exceeds allocation") }
            for i in 0..<count {
                let start = oldBase + (index + i) * 19
                native.insert(Data([UInt8(first)]) + original.subdata(in: start..<(start + 19)))
            }
        }
        guard native.count == 5635 else { throw invalid("native inventory differs") }
        let all = native.union(owned)
        guard all.count <= (end - newBase) / 19 else { throw invalid("owned assets exceed native catalog allocation") }
        var result = original
        var index = 0
        func put(_ value: Int, _ offset: Int, count: Int) {
            for i in 0..<count { result[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
        }
        for first in 0..<256 {
            let entries = all.filter { Int($0[0]) == first }.sorted { $0.lexicographicallyPrecedes($1) }
            guard index <= 65535, entries.count <= 65535 else { throw invalid("native catalog index overflow") }
            put(entries.count, newHeader + first * 4, count: 2)
            put(index, newHeader + first * 4 + 2, count: 2)
            for entry in entries {
                let start = newBase + index * 19
                result.replaceSubrange(start..<(start + 19), with: entry.dropFirst())
                index += 1
            }
        }
        // The two original PC-relative additions use PCs 0x2360 and 0x236e.
        // Update their data literals only, retaining the complete lookup code.
        put(newHeader - 0x2360, 0x23b0, count: 4)
        put(newBase - 0x236e, 0x23b4, count: 4)
        var verified = Set<Data>()
        for first in 0..<256 {
            let count = try number(result, newHeader + first * 4, count: 2)
            let index = try number(result, newHeader + first * 4 + 2, count: 2)
            for i in 0..<count {
                let start = newBase + (index + i) * 19
                verified.insert(Data([UInt8(first)]) + result.subdata(in: start..<(start + 19)))
            }
        }
        guard verified == all, result[0x234c..<0x23b0] == original[0x234c..<0x23b0] else {
            throw invalid("native catalog readback differs")
        }
        var prepared = kernel
        prepared.replaceSubrange(0x790000..<(0x790000 + original.count), with: result)
        return prepared
    }
}
