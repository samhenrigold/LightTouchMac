import CryptoKit
import Foundation
import CActivation

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
        guard b.count >= 28, le32(b, 0) == 0xFEED_FACE,
              let lc = MachOSignature.commands(b[...]).first(where: { $0.cmd == MachOSignature.lcCodeSignature }),
              lc.at + 16 <= b.count else { throw invalid() }
        let start = Int(le32(b, lc.at + 8)), size = Int(le32(b, lc.at + 12))
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

/// Mach-O header checks: load commands and whether each slice carries a parseable code signature.
enum MachOSignature {
    static let lcCodeSignature: UInt32 = 0x1D, lcMain: UInt32 = 0x8000_0028, lcVersionMinIPhoneOS: UInt32 = 0x25

    /// (cputype, cpusubtype, slice bytes) for a thin Mach-O, or each slice of a fat one; nil if neither.
    static func slices(_ d: [UInt8]) -> [(cpu: Int32, sub: Int32, bytes: ArraySlice<UInt8>)]? {
        guard d.count >= 28 else { return nil }
        if be32(d, 0) == 0xCAFE_BABE {
            let n = Int(be32(d, 4))
            var out: [(Int32, Int32, ArraySlice<UInt8>)] = []
            for i in 0..<n {
                let o = 8 + 20 * i
                guard o + 20 <= d.count else { return nil }
                let off = Int(be32(d, o + 8)), size = Int(be32(d, o + 12))
                guard off + size <= d.count else { return nil }
                out.append((Int32(bitPattern: be32(d, o)), Int32(bitPattern: be32(d, o + 4)), d[off..<off + size]))
            }
            return out
        }
        let magic = le32(d, 0)
        guard magic == 0xFEED_FACE || magic == 0xFEED_FACF else { return nil }
        return [(Int32(bitPattern: le32(d, 4)), Int32(bitPattern: le32(d, 8)), d[...])]
    }

    /// The load commands of one (thin) slice: (cmd, offset of the command within the slice).
    static func commands(_ s: ArraySlice<UInt8>) -> [(cmd: UInt32, at: Int)] {
        let b = Array(s)
        guard b.count >= 28 else { return [] }
        var off = le32(b, 0) == 0xFEED_FACF ? 32 : 28, out: [(UInt32, Int)] = []
        for _ in 0..<Int(le32(b, 16)) {
            guard off + 8 <= b.count else { break }
            let size = Int(le32(b, off + 4))
            out.append((le32(b, off), off))
            guard size >= 8 else { break }
            off += size
        }
        return out
    }

    /// Every slice has an LC_CODE_SIGNATURE whose SuperBlob holds a CodeDirectory that parses.
    static func present(in data: Data) -> Bool {
        guard let slices = slices([UInt8](data)), !slices.isEmpty else { return false }
        return slices.allSatisfy { s in
            let b = Array(s.bytes)
            guard let lc = commands(s.bytes).first(where: { $0.cmd == lcCodeSignature }), lc.at + 16 <= b.count else { return false }
            let off = Int(le32(b, lc.at + 8)), size = Int(le32(b, lc.at + 12))
            guard size >= 12, off + size <= b.count, be32(b, off) == 0xFADE_0CC0 else { return false }
            let count = Int(be32(b, off + 8))
            for i in 0..<count where 12 + 8 * i + 8 <= size {
                guard be32(b, off + 12 + 8 * i) == 0 else { continue }   // CSSLOT_CODEDIRECTORY
                let cd = off + Int(be32(b, off + 16 + 8 * i))
                guard cd + 44 <= off + size, be32(b, cd) == 0xFADE_0C02 else { return false }
                let len = Int(be32(b, cd + 4)), hashOff = Int(be32(b, cd + 16)), identOff = Int(be32(b, cd + 20))
                let nCode = Int(be32(b, cd + 28)), hashSize = Int(b[cd + 36])
                guard len >= 44, cd + len <= off + size, identOff < len, hashOff + nCode * hashSize <= len,
                      b[(cd + identOff)..<(cd + len)].contains(0) else { return false }
                return true
            }
            return false
        }
    }

    /// ipad1_rootfs.guest_tool_problem: nil for a thin armv7 Mach-O that 3.2's dyld takes (no LC_MAIN, no
    /// LC_VERSION_MIN_IPHONEOS) and that is signed; else why not.
    static func guestToolProblem(_ data: Data) -> String? {
        let d = [UInt8](data)
        guard d.count >= 28, le32(d, 0) == 0xFEED_FACE else { return "not a thin 32-bit Mach-O" }
        let (cpu, sub) = (Int32(bitPattern: le32(d, 4)), Int32(bitPattern: le32(d, 8)))
        guard (cpu, sub) == (12, 9) else { return "cpu \(cpu)/\(sub), not armv7" }
        let cmds = Set(commands(d[...]).map(\.cmd))
        if cmds.contains(lcMain) || cmds.contains(lcVersionMinIPhoneOS) { return "carries LC_MAIN/LC_VERSION_MIN (not run through mkold.py)" }
        return cmds.contains(lcCodeSignature) ? nil : "unsigned (ldid -S)"
    }

    /// ipad1_rootfs.appsync_problem: nil for a fat Mach-O with an armv7 slice and a signature per slice.
    static func appSyncProblem(_ data: Data) -> String? {
        let d = [UInt8](data)
        guard d.count >= 8, be32(d, 0) == 0xCAFE_BABE, let slices = slices(d) else { return "not a fat Mach-O (expected armv6+armv7)" }
        for (i, s) in slices.enumerated() where !commands(s.bytes).contains(where: { $0.cmd == lcCodeSignature }) {
            return "slice \(i) (cpu \(s.cpu)/\(s.sub)) is not ldid-signed"
        }
        return slices.contains { $0.cpu == 12 && $0.sub == 9 } ? nil : "no armv7 slice"
    }
}

private func be32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]) }
private func le32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
