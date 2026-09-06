import Foundation
import CryptoKit

nonisolated enum MediaIdentity {
    /// Content-derived UUID; AFC compares every existing byte before reuse.
    /// Host work directories remain unique so simultaneous preparation is safe.
    static func identifier(for file: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hash = SHA256()
        while let bytes = try input.read(upToCount: 65536), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        var bytes = Array(hash.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80 // UUID custom-content version.
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let cuts = [0, 8, 12, 16, 20, 32]
        return zip(cuts, cuts.dropFirst()).map { start, end in
            String(hex[hex.index(hex.startIndex, offsetBy: start)..<hex.index(hex.startIndex, offsetBy: end)])
        }.joined(separator: "-")
    }
    /// AVAudioFile puts the current time in these three generated M4A headers.
    /// Zero only those timestamps so repeated conversion has identical bytes.
    static func normalizeGeneratedM4A(_ file: URL) throws {
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        var atoms = 0
        func invalid() -> DeviceToolsError { .failed("The converted audio file is invalid.") }
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else { throw invalid() }
            return data
        }
        func integer(_ bytes: Data) -> UInt64 { bytes.reduce(0) { ($0 << 8) | UInt64($1) } }
        func walk(_ start: UInt64, _ end: UInt64, _ depth: Int) throws {
            guard depth <= 4 else { throw invalid() }
            var offset = start
            while offset < end {
                try Task.checkCancellation()
                atoms += 1
                guard atoms <= 4096, end - offset >= 8 else { throw invalid() }
                let header = try read(offset, 8)
                let kind = String(decoding: header.suffix(4), as: UTF8.self)
                var size = integer(header.prefix(4)), headerSize: UInt64 = 8
                if size == 1 {
                    guard end - offset >= 16 else { throw invalid() }
                    size = integer(try read(offset + 8, 8)); headerSize = 16
                } else if size == 0 { size = end - offset }
                guard size >= headerSize, size <= end - offset else { throw invalid() }
                if ["moov", "trak", "mdia"].contains(kind) {
                    try walk(offset + headerSize, offset + size, depth + 1)
                } else if ["mvhd", "tkhd", "mdhd"].contains(kind) {
                    guard size >= headerSize + 4 else { throw invalid() }
                    let version = try read(offset + headerSize, 1)[0]
                    guard version <= 1 else { throw invalid() }
                    let count = version == 0 ? 8 : 16
                    guard size >= headerSize + 4 + UInt64(count) else { throw invalid() }
                    try handle.seek(toOffset: offset + headerSize + 4)
                    try handle.write(contentsOf: Data(count: count))
                }
                offset += size
            }
        }
        try walk(0, length, 0)
    }

}
