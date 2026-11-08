// Select the HFS partition in a 512-byte-sector GPT root image, as shipped in 14G61.
import Foundation
import zlib

enum GPT {
    static let hfsType = Data([0x00, 0x53, 0x46, 0x48, 0, 0, 0xAA, 0x11,
                              0xAA, 0x11, 0, 0x30, 0x65, 0x43, 0xEC, 0xAC])

    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))) }
    }

    /// `prefix` holds the primary header and partition table, bounded to 1 MiB by the caller.
    static func hfsSlice(_ prefix: Data, diskBytes: UInt64) throws -> (offset: Int, length: Int) {
        func invalid(_ why: String) -> FirmwareError { FirmwareError(.unsupported, "GPT: " + why) }
        guard prefix.count >= 1024, prefix[512..<520] == Data("EFI PART".utf8) else {
            throw invalid("missing primary header")
        }
        func le(_ at: Int, _ n: Int) -> UInt64 {
            (0..<n).reduce(0) { $0 | UInt64(prefix[at + $1]) << ($1 * 8) }
        }
        let headerSize = Int(le(524, 4))
        guard le(520, 4) == 0x10000, (92...512).contains(headerSize), le(536, 8) == 1 else {
            throw invalid("unsupported primary header")
        }
        var header = prefix.subdata(in: 512..<512 + headerSize)
        header.replaceSubrange(16..<20, with: Data(count: 4))
        guard UInt64(checksum(header)) == le(528, 4) else { throw invalid("header checksum mismatch") }
        let tableLBA = le(584, 8), count = le(592, 4), entrySize = le(596, 4)
        // Bound arithmetic and table access before converting firmware-controlled values to Int.
        guard tableLBA >= 2, tableLBA <= UInt64(prefix.count / 512), count > 0,
              entrySize >= 128, entrySize % 8 == 0,
              entrySize <= UInt64(prefix.count), count <= UInt64(prefix.count) / entrySize else {
            throw invalid("invalid or unsupported partition table size")
        }
        let at = Int(tableLBA * 512), length = Int(count * entrySize)
        guard at <= prefix.count, length <= prefix.count - at,
              UInt64(checksum(prefix.subdata(in: at..<at + length))) == le(600, 4) else {
            throw invalid("truncated partition table or checksum mismatch")
        }
        let firstUsable = le(552, 8), lastUsable = le(560, 8)
        guard firstUsable >= tableLBA + (count * entrySize + 511) / 512,
              lastUsable >= firstUsable, lastUsable < diskBytes / 512 else {
            throw invalid("invalid usable sector range")
        }
        var result: (offset: Int, length: Int)?
        for index in 0..<Int(count) {
            let p = at + index * Int(entrySize)
            guard prefix[p..<p + 16] == hfsType else { continue }
            let first = le(p + 32, 8), last = le(p + 40, 8)
            guard result == nil, first >= firstUsable, last >= first, last <= lastUsable,
                  last < UInt64(Int.max / 512) else {
                throw invalid("ambiguous or out-of-range HFS partition")
            }
            result = (Int(first * 512), Int((last - first + 1) * 512))
        }
        guard let result else { throw invalid("no HFS partition") }
        return result
    }
}
