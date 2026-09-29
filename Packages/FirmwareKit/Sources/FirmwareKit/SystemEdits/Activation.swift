import CActivation
import CryptoKit
import Foundation
import MachO
import MachOKit

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
    }

    public static func run(on file: URL) throws -> Result {
        let before = try Data(contentsOf: file)
        var after = before
        var error: UnsafePointer<CChar>?
        let success = after.withUnsafeMutableBytes {
            lt_activate($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &error)
        }
        guard success != 0 else {
            throw ActivationFailure(error.map { String(cString: $0) } ?? "Unsupported activation path")
        }
        after = try signed(after)
        // Preserve the HFS catalog record and its metadata; this file is on a disposable staging volume.
        let out = open(file.path, O_WRONLY | O_NOFOLLOW)
        guard out >= 0 else { throw ActivationFailure("Cannot open activation target") }
        defer { close(out) }
        try after.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(out, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ActivationFailure("Cannot write activation target") }
                offset += count
            }
        }
        return Result(inputSHA256: hash(before), outputSHA256: hash(after))
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Rebuild the existing code-page hashes as an ad-hoc signature, retaining entitlements and
    /// special-slot hashes. Patching does not change the binary's size or its signing allocation.
    static func signed(_ data: Data) throws -> Data {
        var b = [UInt8](data)
        func invalid() -> ActivationFailure { ActivationFailure("Unsupported code signature") }
        guard let cs = MachOSignature.codeSignature(in: data) else { throw invalid() }
        let (start, size) = cs
        guard size >= 12, start <= b.count - size, be32(b, start) == 0xFADE_0CC0 else { throw invalid() }
        let length = Int(be32(b, start + 4)), count = Int(be32(b, start + 8))
        guard length >= 12, length <= size, count <= (length - 12) / 8 else { throw invalid() }
        var entries: [(UInt32, Int)] = []
        var directories = 0
        for i in 0..<count {
            let type = be32(b, start + 12 + i * 8)
            let offset = Int(be32(b, start + 16 + i * 8))
            guard offset >= 12 + count * 8, offset <= length - 8 else { throw invalid() }
            let blob = start + offset, blobLength = Int(be32(b, blob + 4))
            guard blobLength >= 8, blobLength <= length - offset else { throw invalid() }
            if type == 0 || (0x1000...0x1005).contains(type) {
                guard blobLength >= 44, be32(b, blob) == 0xFADE_0C02 else { throw invalid() }
                let hashOffset = Int(be32(b, blob + 16)), special = Int(be32(b, blob + 24))
                let slots = Int(be32(b, blob + 28)), limit = Int(be32(b, blob + 32))
                let hashSize = Int(b[blob + 36]), hashType = b[blob + 37], exponent = Int(b[blob + 39])
                guard exponent > 0, exponent <= 20, limit > 0, limit <= start,
                      (hashType == 1 && hashSize == 20) || (hashType == 2 && hashSize == 32),
                      hashOffset >= 44 + special * hashSize,
                      hashOffset <= blobLength, slots <= (blobLength - hashOffset) / hashSize else { throw invalid() }
                let page = 1 << exponent
                guard slots == (limit + page - 1) / page else { throw invalid() }
                // Scatter layouts require a different page mapping, so fail before touching disk.
                if be32(b, blob + 8) >= 0x20100 {
                    guard blobLength >= 48, be32(b, blob + 44) == 0 else { throw invalid() }
                }
                putBE32(&b, blob + 12, be32(b, blob + 12) | 2) // CS_ADHOC
                for slot in 0..<slots {
                    let bytes = Data(b[(slot * page)..<min(limit, (slot + 1) * page)])
                    let digest = hashType == 1 ? Array(Insecure.SHA1.hash(data: bytes)) : Array(SHA256.hash(data: bytes))
                    b.replaceSubrange((blob + hashOffset + slot * hashSize)..<(blob + hashOffset + (slot + 1) * hashSize), with: digest)
                }
                directories += 1
            }
            if type != 0x10000 { entries.append((type, offset)) } // Remove the now-invalid CMS signature.
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

private func putBE32(_ b: inout [UInt8], _ offset: Int, _ value: UInt32) {
    for i in 0..<4 { b[offset + i] = UInt8(truncatingIfNeeded: value >> (24 - i * 8)) }
}

/// Mach-O header checks for the guest helpers, through MachOKit: thin/fat files, their slices' cpu, load
/// commands and LC_CODE_SIGNATURE.
enum MachOSignature {
    static let armCPU: Int32 = 12, armv7: Int32 = 9   // CPU_TYPE_ARM, CPU_SUBTYPE_ARM_V7

    static func codeSignature(_ cmds: some Sequence<LoadCommand>) -> LoadCommandInfo<linkedit_data_command>? {
        for lc in cmds { if case .codeSignature(let info) = lc { return info } }
        return nil
    }

    /// ipad1_rootfs.guest_tool_problem: nil for a thin armv7 Mach-O that 3.2's dyld takes (no LC_MAIN, no
    /// LC_VERSION_MIN_IPHONEOS) and that is signed; else why not.
    static func guestToolProblem(_ url: URL) -> String? {
        guard case .machO(let m)? = try? MachOKit.loadFromFile(url: url), !m.is64Bit else { return "not a thin 32-bit Mach-O" }
        let h = m.header.layout
        guard h.cputype == armCPU, h.cpusubtype == armv7 else { return "cpu \(h.cputype)/\(h.cpusubtype), not armv7" }
        for lc in m.loadCommands {
            switch lc {
            case .main, .versionMinIphoneos: return "carries LC_MAIN/LC_VERSION_MIN (not run through mkold.py)"
            default: continue
            }
        }
        return codeSignature(m.loadCommands) != nil ? nil : "unsigned (ldid -S)"
    }

    /// ipad1_rootfs.appsync_problem: nil for a fat Mach-O with an armv7 slice and a signature per slice.
    static func appSyncProblem(_ url: URL) -> String? {
        guard case .fat(let f)? = try? MachOKit.loadFromFile(url: url), let slices = try? f.machOFiles() else { return "not a fat Mach-O (expected armv6+armv7)" }
        for (i, s) in slices.enumerated() where codeSignature(s.loadCommands) == nil {
            return "slice \(i) (cpu \(s.header.layout.cputype)/\(s.header.layout.cpusubtype)) is not ldid-signed"
        }
        return slices.contains { $0.header.layout.cputype == armCPU && $0.header.layout.cpusubtype == armv7 } ? nil : "no armv7 slice"
    }

    /// LC_CODE_SIGNATURE's (dataoff, datasize) of a thin 32-bit Mach-O in memory (Activation.signed patches the buffer).
    static func codeSignature(in data: Data) -> (offset: Int, size: Int)? {
        data.withUnsafeBytes { b -> (Int, Int)? in
            guard b.count >= 28, let base = b.baseAddress, b.loadUnaligned(as: UInt32.self) == 0xFEED_FACE,
                  let cs = codeSignature(MachOImage(ptr: base.assumingMemoryBound(to: mach_header.self)).loadCommands) else { return nil }
            return (Int(cs.dataoff), Int(cs.datasize))
        }
    }
}

private func be32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]) }
private func le32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
