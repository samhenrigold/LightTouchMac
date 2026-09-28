// ActivationHook: the user's opt-in hook, a black box run as `hook FILE` on a copy of the recipe's target
// (lockdownd). It must exit 0 and change the file, and its output must still carry a code signature
// (an LC_CODE_SIGNATURE whose CodeDirectory parses): FirmwareKit does not re-sign (the Python oracle
// re-signs with ldid). The hook's, the input's and the output's sha256 go into the lock.
//
//   let r = try ActivationHook.run(hook, on: file)     // file is replaced in place on success
//   r.hookSHA256, r.inputSHA256, r.outputSHA256
//
// A hook that is not executable but ends in .py is run with python3, as the oracle does.

import CryptoKit
import Foundation

/// The preparer contract's `hook_failed`.
public struct HookFailure: Error, CustomStringConvertible, Sendable {
    public let code = "hook_failed"
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "\(code): \(message)" }
}

public enum ActivationHook {
    public struct Result: Sendable, Equatable, Codable {
        public let hookSHA256: String, inputSHA256: String, outputSHA256: String
    }

    /// Runs `hook` on a temp copy of `file`, checks it, then writes the result back into `file` in place
    /// (mode 0755, so the catalog record survives). `displayPath` names the target in errors.
    public static func run(_ hook: URL, on file: URL, displayPath: String? = nil, timeout: TimeInterval = 300) throws -> Result {
        let name = displayPath ?? file.path
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("fk-hook-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let work = dir.appendingPathComponent(file.lastPathComponent)
        let before = try Data(contentsOf: file)
        try before.write(to: work)

        let p = Process()
        if !fm.isExecutableFile(atPath: hook.path) && hook.pathExtension == "py" {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["python3", hook.path, work.path]
        } else {
            p.executableURL = hook
            p.arguments = [work.path]
        }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.standardError   // stdout is the preparer's JSON Lines channel
        do { try p.run() } catch { throw HookFailure("activation hook \(hook.path) did not start: \(error.localizedDescription)") }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning {
            p.terminate(); p.waitUntilExit()
            throw HookFailure("activation hook \(hook.path) timed out after \(Int(timeout)) s")
        }
        guard p.terminationReason == .exit, p.terminationStatus == 0 else {
            throw HookFailure("activation hook \(hook.path) failed (exit \(p.terminationStatus))")
        }
        let after = try Data(contentsOf: work)
        guard after != before else { throw HookFailure("activation hook \(hook.path) left \(name) unchanged") }
        guard MachOSignature.present(in: after) else { throw HookFailure("activation hook left \(name) unsigned") }

        let out = open(file.path, O_WRONLY | O_TRUNC)
        guard out >= 0 else { throw FirmwareError(.internal, "open \(file.path): \(String(cString: strerror(errno)))") }
        defer { close(out) }
        let n = after.withUnsafeBytes { write(out, $0.baseAddress, $0.count) }
        guard n == after.count, fchmod(out, 0o755) == 0 else { throw FirmwareError(.internal, "write \(file.path): \(String(cString: strerror(errno)))") }
        return Result(hookSHA256: sha256(try Data(contentsOf: hook)), inputSHA256: sha256(before), outputSHA256: sha256(after))
    }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
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
