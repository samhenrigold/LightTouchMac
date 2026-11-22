// What an .ipa's main binary says it runs on, read on the Mac before anything is sent: its 32-bit ARM slices and
// whether each is still FairPlay-encrypted. AppSync makes installd take either kind, so an encrypted copy, or one
// built only for a newer processor, would upload for minutes, install, and then die at launch with nothing said.

import Foundation
import HostRuntime

public nonisolated enum AppBinary {
    /// One 32-bit ARM slice: its CPU_SUBTYPE_ARM_* (6 is v6, 9 v7, 11 v7s) and whether LC_ENCRYPTION_INFO's cryptid
    /// is set.
    public struct Slice: Equatable, Sendable {
        public var subtype: UInt32
        public var isEncrypted: Bool
        public init(subtype: UInt32, isEncrypted: Bool) {
            self.subtype = subtype
            self.isEncrypted = isEncrypted
        }
    }

    private struct Unreadable: Error {}

    /// The 32-bit ARM slices of the Mach-O that `read` gives byte ranges of (fewer bytes where it ends sooner):
    /// empty when it has none (64-bit only, or built for the Simulator), nil when it is no Mach-O this can read,
    /// whose verdict stays installd's.
    public static func slices(_ read: (Range<Int>) -> Data?) -> [Slice]? {
        try? parse(read)
    }

    /// Why a device with the processor of `soc` can't run a binary with these slices, worded for the install's
    /// row about the file `name`; nil when it can, or when nothing is known of the binary.
    public static func problem(_ slices: [Slice]?, soc: Board.SoC, name: String) -> String? {
        guard let slices else { return nil }
        // The slice dyld takes: the newest the processor runs, and anything older than ARMv7 runs on all of them.
        let newestFirst: [UInt32] =
            switch soc {
            case .s5l8900, .s5l8720: [6]
            case .s5l8920, .s5l8930: [9, 6]
            case .s5l8950: [11, 9, 6]
            }
        let taken =
            newestFirst.lazy.compactMap { subtype in slices.first { $0.subtype == subtype } }.first
            ?? slices.first { $0.subtype < 9 }
        guard let taken else {
            return slices.isEmpty
                ? "“\(name)” has no 32-bit version, and this device runs only 32-bit apps."
                : "“\(name)” is built for a newer processor than this device’s."
        }
        return taken.isEncrypted
            ? "“\(name)” is still encrypted, so it can’t open in Light Touch. Use a decrypted copy of the app."
            : nil
    }

    /// `problem` for the binary at `member` of the archive `ipa`, read off the caller's actor.
    @concurrent public static func problem(in ipa: URL, member: String, soc: Board.SoC) async -> String? {
        problem(slices { ZipMembers.data(ipa, member, range: $0) }, soc: soc, name: ipa.lastPathComponent)
    }

    private static func parse(_ read: (Range<Int>) -> Data?) throws -> [Slice] {
        guard let head = read(0..<4096) else { throw Unreadable() }
        switch try word(head, 0, bigEndian: true) {
        case 0xcafe_babe:  // fat: big-endian entries of cputype, cpusubtype, offset, size, align
            let count = Int(try word(head, 4, bigEndian: true))
            guard count <= (head.count - 8) / 20 else { throw Unreadable() }
            return try (0..<count).compactMap { index in
                guard try word(head, 8 + 20 * index, bigEndian: true) == 12 else { return nil }
                return try thin(read, at: Int(try word(head, 16 + 20 * index, bigEndian: true)))
            }
        case 0xcefa_edfe: return try thin(read, at: 0).map { [$0] } ?? []
        case 0xcffa_edfe: return []  // 64-bit
        default: throw Unreadable()
        }
    }

    /// The slice at `base`, nil when it is not 32-bit ARM. The header and load commands are taken from 64 KiB, the
    /// window the guest's AppSync reads a signature's load command in.
    private static func thin(_ read: (Range<Int>) -> Data?, at base: Int) throws -> Slice? {
        guard let image = read(base..<base + 65536) else { throw Unreadable() }
        guard try word(image, 0) == 0xfeed_face, try word(image, 4) == 12 else { return nil }
        var offset = 28
        var encrypted = false
        for _ in 0..<(try word(image, 16)) {
            let size = Int(try word(image, offset + 4))
            guard size >= 8 else { throw Unreadable() }
            if try word(image, offset) == 0x21 { encrypted = try word(image, offset + 16) != 0 }  // LC_ENCRYPTION_INFO
            offset += size
        }
        return Slice(subtype: try word(image, 8) & 0x00ff_ffff, isEncrypted: encrypted)
    }

    private static func word(_ data: Data, _ offset: Int, bigEndian: Bool = false) throws -> UInt32 {
        guard offset >= 0, data.count >= 4, offset <= data.count - 4 else { throw Unreadable() }
        let value = data[(data.startIndex + offset)..<(data.startIndex + offset + 4)].reduce(UInt32(0)) {
            $0 << 8 | UInt32($1)
        }
        return bigEndian ? value : value.byteSwapped
    }
}
