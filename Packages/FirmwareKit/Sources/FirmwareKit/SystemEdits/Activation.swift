import BinaryParsing
import CActivation
import Crypto
import Foundation

public struct ActivationFailure: Error, CustomStringConvertible, Sendable {
    public let code = "activation_failed"
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "\(code): \(message)" }
}

/// An unconditional part of preparing a new device. No executable or strategy is supplied by callers.
public enum Activation {
    public struct Result: Sendable, Equatable, Codable {
        public let inputSHA256: String, outputSHA256: String
        // Optional so device records written by earlier releases remain decodable.
        public var patch: Patch? = nil
        public var factoryContinuation: Patch? = nil
        /// The data route (iOS 6): lockdownd left stock, these keys seeded into /var/root/Library/Lockdown/data_ark.plist.
        public var dataArk: [String: String]? = nil
        public var gestaltOverrides: [String: Bool]? = nil
        /// The native component that owns a data-only activation shortcut,
        /// when it has moved out of lockdownd (iOS 8's mobactivationd).
        public var component: String? = nil
        /// A fresh device must generate its authentic cache in the native
        /// restore environment before this configuration can be finalized.
        public var nativeCacheRequired: Bool? = nil
        var record: [String: Any] {
            var result: [String: Any] = ["input_sha256": inputSHA256, "output_sha256": outputSHA256]
            if let dataArk { result["data_ark"] = dataArk }
            if let component { result["component"] = component }
            if let gestaltOverrides { result["gestalt_overrides"] = gestaltOverrides }
            if let nativeCacheRequired { result["native_cache_required"] = nativeCacheRequired }
            if let p = factoryContinuation {
                result["factory_continuation"] = ["strategy": p.strategy, "isa": p.isa,
                    "offset": p.offset, "original": p.original.hexString, "replacement": p.replacement.hexString]
            }
            if let patch {
                result["patch"] = [
                    "strategy": patch.strategy, "isa": patch.isa, "offset": patch.offset,
                    "original": patch.original.hexString,
                    "replacement": patch.replacement.hexString
                ]
            }
            return result
        }
    }
    public struct Patch: Sendable, Equatable, Codable {
        public let strategy: String, isa: String
        public let offset: Int
        public let original: Data, replacement: Data
    }

    /// lockdownd at `path` on the volume activated in place: its catalog record and metadata kept. A mounted
    /// volume's file is written through `run(on:)` (which makes a read-only file writable for the write).
    public static func run(on v: any VolumeFiles, _ path: String) throws -> Result {
        if let m = v as? MountedVolume { return try run(on: m.url(path)) }
        let (after, result) = try activated(try v.contents(at: path))
        try v.put(after, at: path)
        return result
    }

    public static func run(on file: URL) throws -> Result {
        let (after, result) = try activated(try Data(contentsOf: file))
        try overwrite(file, with: after)
        return result
    }

    static func activated(_ before: Data) throws -> (Data, Result) {
        if let qualified = try qualifiedA6Factory(before) { return qualified }
        var after = before
        var error: UnsafePointer<CChar>?
        var report = LTActivationReport()
        let success = after.withUnsafeMutableBytes {
            lt_activate_report($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &report, &error)
        }
        guard success != 0 else {
            throw ActivationFailure(error.map { String(cString: $0) } ?? "Unsupported activation path")
        }
        // 1.x ships unsigned lockdownd and predates mandatory code signing. Only
        // the positively recognized 1.x path may remain unsigned; later paths
        // still require a valid signature allocation. Existing signatures are refreshed.
        if success != 2 || MachOSignature.codeSignature(in: after) != nil {
            after = try signed(after)
        }
        let patch = Patch(
            strategy: String(cString: report.strategy),
            isa: String(cString: report.isa),
            offset: report.offset,
            original: withUnsafeBytes(of: report.original) { Data($0.prefix(Int(report.width))) },
            replacement: withUnsafeBytes(of: report.replacement) { Data($0.prefix(Int(report.width))) }
        )
        let continuation: Patch? = report.continuation_width > 0 ? Patch(
            strategy: "development-factory-continuation", isa: "thumb", offset: report.continuation_offset,
            original: withUnsafeBytes(of: report.continuation_original) { Data($0.prefix(Int(report.continuation_width))) },
            replacement: withUnsafeBytes(of: report.continuation_replacement) { Data($0.prefix(Int(report.continuation_width))) }
        ) : nil
        return (after, Result(inputSHA256: Preparer.sha256(before), outputSHA256: Preparer.sha256(after),
                              patch: patch, factoryContinuation: continuation))
    }

    /// N42 10A405's Qualcomm activation handler predates the later development
    /// shortcut. Its ShouldHactivate answer alone does not complete activation
    /// without a modem. Qualify the entire stock executable before using this
    /// build's no-record block; no model or MobileGestalt identity is changed.
    /// The replacement initializes the handler's cleanup slots, selects its
    /// native Activated constant, and enters its original BrickState=false
    /// publication tail. The activation-record path remains untouched.
    static func qualifiedA6Factory(_ before: Data) throws -> (Data, Result)? {
        let input = Preparer.sha256(before)
        let prepared = "dc5033e2bf1ba37790431cde3b3a19de8fe9dc799f46a348ad848eef3ca83fd4"
        if input == prepared { throw ActivationFailure("Activation shortcut is already prepared") }
        guard input == "ecb3e46cedceb255ee423fd455f7291b1abca7c72ed9c35c32fdf0c9d7500230" else { return nil }
        let offset = 0x109ce
        let original = Data([
            0xc8, 0xb9, 0x49, 0xf6, 0x37, 0x51, 0x00, 0x20, 0xc0, 0xf2, 0x04, 0x01,
            0x49, 0xf2, 0x58, 0x22, 0xc0, 0xf2, 0x07, 0x02, 0x79, 0x44, 0x7a, 0x44,
            0x4f, 0xf0, 0x00, 0x0b, 0x01, 0xf0, 0x5b, 0xff, 0x48, 0xf2, 0x92, 0x70,
            0xc0, 0xf2, 0x07, 0x00, 0xcd, 0xf8, 0x20, 0xb0, 0x78, 0x44,
        ])
        let replacement = Data([
            0x00, 0xbf, 0x48, 0xf6, 0x74, 0x70, 0xc0, 0xf2, 0x07, 0x00, 0x78, 0x44,
            0x09, 0x90, 0x00, 0x20, 0x04, 0x90, 0x06, 0x90, 0x08, 0x90, 0x83, 0x46,
            0x82, 0x46, 0x43, 0xf6, 0xdc, 0x40, 0xc0, 0xf2, 0x07, 0x00, 0x78, 0x44,
            0x00, 0x68, 0x00, 0x68, 0x80, 0x46, 0x00, 0xf0, 0x2b, 0xb9,
        ])
        let range = offset..<(offset + original.count)
        guard before.subdata(in: range) == original else {
            throw ActivationFailure("Qualified A6 activation block differs")
        }
        var after = before
        after.replaceSubrange(range, with: replacement)
        after = try signed(after)
        guard Preparer.sha256(after) == prepared else {
            throw ActivationFailure("Qualified A6 activation output differs")
        }
        return (after, Result(inputSHA256: input, outputSHA256: prepared,
                              patch: Patch(strategy: "a6-native-no-record-factory-shortcut", isa: "thumb",
                                           offset: offset, original: original, replacement: replacement)))
    }

    private static func overwrite(_ file: URL, with after: Data) throws {
        // Preserve the HFS catalog record and its metadata; this file is on a disposable staging volume.
        let metadata = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard metadata >= 0 else { throw ActivationFailure("Cannot open activation target") }
        var original = stat()
        guard fstat(metadata, &original) == 0, original.st_mode & S_IFMT == S_IFREG else {
            close(metadata)
            throw ActivationFailure("Activation target is not a regular file")
        }
        defer {
            _ = fchmod(metadata, original.st_mode & 0o7777)
            close(metadata)
        }
        guard fchmod(metadata, original.st_mode & 0o7777 | 0o200) == 0 else {
            throw ActivationFailure("Cannot make activation target writable")
        }
        let out = open(file.path, O_WRONLY | O_NOFOLLOW)
        guard out >= 0 else { throw ActivationFailure("Cannot open activation target") }
        defer { close(out) }
        try after.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { return }  // empty: nothing to write
            var offset = 0
            while offset < bytes.count {
                let count = write(out, start.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ActivationFailure("Cannot write activation target") }
                offset += count
            }
        }
    }

    /// iOS 6 lockdownd, which no binary strategy matches, takes its activation state from its data ark: the
    /// lockdown_cache domain's ActivationState, which a factory unit carries as FactoryActivated. Offered only when
    /// lockdownd names that domain and state; the binary stays stock.
    public static func dataArkRoute(lockdownd: Data) -> Result? {
        guard lockdownd.range(of: Data("com.apple.mobile.lockdown_cache\0".utf8)) != nil,
            lockdownd.range(of: Data("FactoryActivated\0".utf8)) != nil
        else { return nil }
        let h = Preparer.sha256(lockdownd)
        return Result(
            inputSHA256: h,
            outputSHA256: h,
            dataArk: ["com.apple.mobile.lockdown_cache-ActivationState": "FactoryActivated"]
        )
    }

    /// iOS 7/8's local development-activation flag, as used by Hacktiv8's
    /// jailbroken-device recipe. Only modify a real cache for this exact build;
    /// never fabricate its opaque CacheData or firmware identity.
    /// Reference: github.com/overcast302/hacktiv8/blob/main/exploits/sftp/sftp.py
    public static func gestaltRoute(lockdownd: Data, cache: Data, build: String) -> Result? {
        guard lockdownd.range(of: Data("ShouldHactivate\0".utf8)) != nil,
              lockdownd.range(of: Data("Short circuiting activation state to Activated".utf8)) != nil,
              let plist = try? PropertyListSerialization.propertyList(from: cache, format: nil) as? [String: Any],
              plist["CacheVersion"] as? String == build,
              let uuid = plist["CacheUUID"] as? String, UUID(uuidString: uuid) != nil,
              let opaque = plist["CacheData"] as? Data, !opaque.isEmpty,
              plist["CacheExtra"] is [String: Any] else { return nil }
        let hash = Preparer.sha256(lockdownd)
        return Result(inputSHA256: hash, outputSHA256: hash,
                      gestaltOverrides: ["a6vjPkzcRjrsXmniFsm0dg": true])
    }

    /// Stage the already-qualified N42 data-only routes for a new device.
    /// No opaque cache is manufactured here: the native initializer must
    /// generate and verify it before a normal boot is permitted.
    public static func nativeGestaltPlan(component: Data, build: String) -> Result? {
        let known = [
            "12A365": "1a2ea9ac54a5b7685cc70292a722762f4007c5cd493f85feb00738697756c513",
            "13A344": "6f09a4c6cfc1738db32b6065c0f05d11d1604a57f5652ccb6b47d556ab3567f7",
            "14G61": "0261d2d149140ce0c7d290dc7e33a454168e6f5a2c424122af27da38e92ef753"
        ]
        guard let expected = known[build], Preparer.sha256(component) == expected,
              component.range(of: Data("ShouldHactivate\0".utf8)) != nil,
              component.range(of: Data((build == "14G61"
                  ? "Hactivation is enabled, short circuiting activation state to Activated."
                  : "Short circuiting activation state to Activated").utf8)) != nil else { return nil }
        let hash = Preparer.sha256(component)
        return Result(inputSHA256: hash, outputSHA256: hash,
                      gestaltOverrides: ["a6vjPkzcRjrsXmniFsm0dg": true],
                      component: build == "14G61" ? "usr/libexec/mobileactivationd"
                          : "System/Library/PrivateFrameworks/MobileActivation.framework/Support/mobactivationd",
                      nativeCacheRequired: true)
    }

    /// Rebuild the existing code-page hashes as an ad-hoc signature, retaining entitlements and
    /// special-slot hashes. Patching does not change the binary's size or its signing allocation.
    static func signed(_ data: Data, preservingEmptyCMS: Bool = false) throws -> Data {
        var b = [UInt8](data)
        func invalid() -> ActivationFailure { ActivationFailure("Unsupported code signature") }
        guard let cs = MachOSignature.codeSignature(in: data) else { throw invalid() }
        let (start, size) = cs
        guard size >= 12, start <= b.count - size, try be32(b, start) == 0xFADE_0CC0 else { throw invalid() }
        let length = Int(try be32(b, start + 4))
        let count = Int(try be32(b, start + 8))
        guard length >= 12, length <= size, count <= (length - 12) / 8 else { throw invalid() }
        var entries: [(UInt32, Int)] = []
        var directories = 0
        for i in 0..<count {
            let type = try be32(b, start + 12 + i * 8)
            let offset = Int(try be32(b, start + 16 + i * 8))
            guard offset >= 12 + count * 8, offset <= length - 8 else { throw invalid() }
            let blob = start + offset
            let blobLength = Int(try be32(b, blob + 4))
            guard blobLength >= 8, blobLength <= length - offset else { throw invalid() }
            if preservingEmptyCMS && type == 0x10000 {
                // Some native metadata images carry an empty CMS wrapper as
                // part of their ad-hoc signature. Retain that representation,
                // but never preserve a stale, nonempty CMS signature.
                guard blobLength == 8, try be32(b, blob) == 0xFADE_0B01 else { throw invalid() }
            }
            if type == 0 || (0x1000...0x1005).contains(type) {
                guard blobLength >= 44, try be32(b, blob) == 0xFADE_0C02 else { throw invalid() }
                let hashOffset = Int(try be32(b, blob + 16))
                let special = Int(try be32(b, blob + 24))
                let slots = Int(try be32(b, blob + 28))
                let limit = Int(try be32(b, blob + 32))
                let hashSize = Int(b[blob + 36])
                let hashType = b[blob + 37]
                let exponent = Int(b[blob + 39])
                guard exponent > 0, exponent <= 20, limit > 0, limit <= start,
                    (hashType == 1 && hashSize == 20) || (hashType == 2 && hashSize == 32),
                    hashOffset >= 44 + special * hashSize,
                    hashOffset <= blobLength, slots <= (blobLength - hashOffset) / hashSize
                else { throw invalid() }
                let page = 1 << exponent
                guard slots == (limit + page - 1) / page else { throw invalid() }
                // Scatter layouts require a different page mapping, so fail before touching disk.
                if try be32(b, blob + 8) >= 0x20100 {
                    guard blobLength >= 48, try be32(b, blob + 44) == 0 else { throw invalid() }
                }
                putBE32(&b, blob + 12, try be32(b, blob + 12) | 2)  // CS_ADHOC
                for slot in 0..<slots {
                    let bytes = Data(b[(slot * page)..<min(limit, (slot + 1) * page)])
                    let digest =
                        hashType == 1 ? Array(Insecure.SHA1.hash(data: bytes)) : Array(SHA256.hash(data: bytes))
                    b.replaceSubrange(
                        (blob + hashOffset + slot * hashSize)..<(blob + hashOffset + (slot + 1) * hashSize),
                        with: digest
                    )
                }
                directories += 1
            }
            if type != 0x10000 || preservingEmptyCMS { entries.append((type, offset)) }
        }
        guard directories > 0, entries.contains(where: { $0.0 == 0 }) else { throw invalid() }
        for i in 0..<count {
            putBE32(&b, start + 12 + i * 8, i < entries.count ? entries[i].0 : 0)
            putBE32(&b, start + 16 + i * 8, i < entries.count ? UInt32(entries[i].1) : 0)
        }
        putBE32(&b, start + 8, UInt32(entries.count))
        return Data(b)
    }
}

/// Mach-O header checks for the guest helpers: thin/fat files, their slices' cpu, load commands and
/// LC_CODE_SIGNATURE.
enum MachOSignature {
    static let armCPU: Int32 = 12, armv7: Int32 = 9  // CPU_TYPE_ARM, CPU_SUBTYPE_ARM_V7
    static let lcCodeSignature: UInt32 = 0x1D, lcVersionMinIphoneos: UInt32 = 0x25, lcBuildVersion: UInt32 = 0x32
    static let lcMain: UInt32 = 0x8000_0028, lcDyldInfoOnly: UInt32 = 0x8000_0022

    /// One thin image: its cpu, and each load command's cmd and offset in the file.
    struct Image {
        var cputype: Int32, cpusubtype: Int32, is64Bit: Bool
        var commands: [(cmd: UInt32, offset: Int)]
    }

    /// The images of a thin or fat Mach-O (nil for anything else, or anything cut short), and whether it was fat.
    /// Each command's offset is its offset in the file.
    static func images(_ data: Data) -> (images: [Image], fat: Bool)? {
        // mach_header(_64): magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags (, reserved); then the
        // load commands, each (cmd, cmdsize) and its body, all within the image
        func thin(_ s: inout ParserSpan) throws(ParsingError) -> Image? {
            let magic = try UInt32(parsingLittleEndian: &s)
            guard magic == 0xFEED_FACE || magic == 0xFEED_FACF else { return nil }
            let cpu = try UInt32(parsingLittleEndian: &s)
            let sub = try UInt32(parsingLittleEndian: &s)
            try s.seek(toRelativeOffset: 4)
            let ncmds = try UInt32(parsingLittleEndian: &s)
            try s.seek(toRelativeOffset: magic == 0xFEED_FACF ? 12 : 8)
            var commands: [(cmd: UInt32, offset: Int)] = []
            for _ in 0..<ncmds {
                let offset = s.startPosition
                var c = try s.seeking(toRelativeOffset: 0)
                let cmd = try UInt32(parsingLittleEndian: &c)
                let size = try UInt32(parsingLittleEndian: &c)
                guard size >= 8 else { return nil }
                _ = try s.sliceSpan(byteCount: size)
                commands.append((cmd, offset))
            }
            return Image(
                cputype: Int32(bitPattern: cpu),
                cpusubtype: Int32(bitPattern: sub),
                is64Bit: magic == 0xFEED_FACF,
                commands: commands
            )
        }
        // fat_header: magic, nfat_arch (big-endian); then each fat_arch: cputype, cpusubtype, offset, size, align
        return try? [UInt8](data).withParserSpan { s throws(ParsingError) -> (images: [Image], fat: Bool)? in
            var whole = try s.seeking(toRelativeOffset: 0)
            if let image = try? thin(&whole) { return ([image], false) }
            guard try UInt32(parsingBigEndian: &s) == 0xCAFE_BABE else { return nil }
            let count = try UInt32(parsingBigEndian: &s)
            guard count > 0, count < 32 else { return nil }
            var slices: [Image] = []
            for _ in 0..<count {
                var arch = try s.sliceSpan(byteCount: 20)
                try arch.seek(toRelativeOffset: 8)
                let offset = try UInt32(parsingBigEndian: &arch)
                let size = try UInt32(parsingBigEndian: &arch)
                var file = try s.seeking(toAbsoluteOffset: offset)
                var slice = try file.sliceSpan(byteCount: size)
                guard let image = try thin(&slice) else { return nil }
                slices.append(image)
            }
            return (slices, true)
        }
    }

    static func isSigned(_ image: Image) -> Bool { image.commands.contains { $0.cmd == lcCodeSignature } }

    /// ipad1_rootfs.guest_tool_problem: nil for a thin armv7 Mach-O that 3.2's dyld takes (no LC_MAIN, no
    /// LC_VERSION_MIN_IPHONEOS) and that is signed; else why not.
    static func guestToolProblem(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), let (images, fat) = images(data), !fat, let m = images.first,
            !m.is64Bit
        else { return "not a thin 32-bit Mach-O" }
        guard m.cputype == armCPU, m.cpusubtype == armv7 else { return "cpu \(m.cputype)/\(m.cpusubtype), not armv7" }
        if m.commands.contains(where: { [lcMain, lcVersionMinIphoneos].contains($0.cmd) }) {
            return "carries LC_MAIN/LC_VERSION_MIN (not run through machotool mkold)"
        }
        return isSigned(m) ? nil : "unsigned (ldid -S)"
    }

    /// ipad1_rootfs.appsync_problem: nil for a fat Mach-O with an armv7 slice and a signature per slice.
    static func appSyncProblem(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), let (slices, fat) = images(data), fat else {
            return "not a fat Mach-O (expected armv6+armv7)"
        }
        for (i, s) in slices.enumerated() where !isSigned(s) {
            return "slice \(i) (cpu \(s.cputype)/\(s.cpusubtype)) is not ldid-signed"
        }
        return slices.contains { $0.cputype == armCPU && $0.cpusubtype == armv7 } ? nil : "no armv7 slice"
    }

    /// 2.x/3.0 dyld needs classic relocations and an ARMv6 slice; fail before baking a modern helper.
    static func earlyARMProblem(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), let (images, _) = images(data) else { return "not a Mach-O" }
        guard let image = images.first(where: { $0.cputype == armCPU && $0.cpusubtype == 6 }) else {
            return "no armv6 slice"
        }
        if image.commands.contains(where: {
            [lcDyldInfoOnly, lcMain, lcVersionMinIphoneos, lcBuildVersion].contains($0.cmd)
        }) {
            return "requires a newer dyld; rebuild with LEGACY_LINK=1"
        }
        return isSigned(image) ? nil : "unsigned armv6 slice"
    }

    /// LC_CODE_SIGNATURE's (dataoff, datasize) of a thin 32-bit Mach-O in memory (Activation.signed patches the buffer).
    static func codeSignature(in data: Data) -> (offset: Int, size: Int)? {
        guard let (images, fat) = images(data), !fat, let image = images.first, !image.is64Bit,
            let cs = image.commands.first(where: { $0.cmd == lcCodeSignature })
        else { return nil }
        // linkedit_data_command: cmd, cmdsize, dataoff, datasize
        return try? [UInt8](data).withParserSpan { s throws(ParsingError) -> (offset: Int, size: Int) in
            (Int(try s.le32(at: cs.offset + 8)), Int(try s.le32(at: cs.offset + 12)))
        }
    }
}
