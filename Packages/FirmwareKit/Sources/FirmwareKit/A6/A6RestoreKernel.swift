import Foundation

/// Compatibility needed only while formatting new N42 media in the original
/// restore environment. Normal boot continues to use the original kernel.
public enum A6RestoreKernel {
    static let originalSHA256 = "14b955200561e63d71cf67366668b54d1463fd2c42ce28c9cdb672947479850d"

    public static func prepare(
        _ original: Data, build: String,
        log: (String) -> Void = { _ in }
    ) throws -> Data {
        guard build == "12A365" else { return original }
        func invalid(_ reason: String) -> FirmwareError {
            FirmwareError(.unsupported, "N42 restore PRNG compatibility: " + reason)
        }
        guard Preparer.sha256(original) == originalSHA256 else {
            throw invalid("unrecognized 12A365 kernel")
        }
        let image = try MachO(original)
        func offset(_ address: UInt32, bytes: Int) throws -> Int {
            guard
                let segment = image.segments.first(where: {
                    UInt64(address) >= UInt64($0.vmaddr)
                        && UInt64(address) + UInt64(bytes) <= UInt64($0.vmaddr) + UInt64($0.filesize)
                })
            else { throw invalid("address outside file-backed segments") }
            let position = Int(segment.fileoff) + Int(address - segment.vmaddr)
            guard position >= 0, position <= original.count - bytes else { throw invalid("truncated segment") }
            return position
        }
        func word(_ position: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(original[position + $1]) << (8 * $1) }
        }

        // Our Thumb wrapper, assembled from tools/a6/chunked-random.S. It
        // preserves r4-r7/LR and 8-byte stack alignment, makes <=512-byte
        // calls to the original read_random, and supports a short final call.
        // The final literal is taken from this firmware's original import.
        var wrapper = Data([
            0xf0, 0xb5, 0x81, 0xb0, 0x04, 0x46, 0x0d, 0x46,
            0x07, 0x4e, 0x00, 0x2d, 0x0a, 0xd0, 0x40, 0xf2,
            0x00, 0x27, 0xbd, 0x42, 0x38, 0xbf, 0x2f, 0x46,
            0x20, 0x46, 0x39, 0x46, 0xb0, 0x47, 0x3c, 0x44,
            0xed, 0x1b, 0xf2, 0xe7, 0x01, 0xb0, 0xf0, 0xbd
        ])
        let slot = try offset(0x8075_c0c0, bytes: 4)
        guard word(slot) == 0x8009_9cc9 else { throw invalid("read_random import changed") }
        wrapper.append(original.subdata(in: slot..<(slot + 4)))
        let header = try offset(0x8074_c000, bytes: 24)
        guard word(header) == 0xfeed_face, word(header + 20) + 28 <= 0x600 else {
            throw invalid("IOFlashStorage header occupies wrapper space")
        }
        let cave = try offset(0x8074_c600, bytes: wrapper.count)
        guard original.subdata(in: cave..<(cave + wrapper.count)) == Data(count: wrapper.count) else {
            throw invalid("IOFlashStorage header padding is in use")
        }
        var result = original
        result.replaceSubrange(cave..<(cave + wrapper.count), with: wrapper)
        // Redirect only this kext's import, not the system PRNG entry point.
        result.replaceSubrange(slot..<(slot + 4), with: [0x01, 0xc6, 0x74, 0x80])
        log("12A365 temporary restore kernel: split IOFlashStorage random requests into native 512-byte calls")
        return result
    }
}
