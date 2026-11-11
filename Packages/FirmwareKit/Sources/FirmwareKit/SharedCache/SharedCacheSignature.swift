import Crypto
import Foundation

extension DyldSharedCache {
    /// Refresh only existing code-page hash slots after intentional cache edits.
    /// Signature layout, special slots, scatter mappings and payload are retained.
    /// This does not create a signature or alter its admission policy.
    public func rehashingCodeSignature() throws -> Data {
        func invalid(_ detail: String) -> FirmwareError {
            FirmwareError(.unsupported, "shared cache signature: " + detail)
        }
        func word(_ at: Int, count: Int = 4, big: Bool = true) throws -> Int {
            guard (1...8).contains(count), at >= 0, at <= data.count - count else {
                throw invalid("truncated metadata")
            }
            var value: UInt64 = 0
            for i in 0..<count { value |= UInt64(data[at + i]) << (8 * (big ? count - 1 - i : i)) }
            guard value <= UInt64(Int.max) else { throw invalid("metadata integer overflow") }
            return Int(value)
        }
        let signature = try word(40, count: 8, big: false)
        var allocation = try word(48, count: 8, big: false)
        guard signature >= 56, signature <= data.count - 12 else { throw invalid("missing signature") }
        if allocation == 0 { allocation = data.count - signature }
        guard allocation >= 12, allocation <= data.count - signature,
            try word(signature) == 0xfade_0cc0
        else { throw invalid("invalid signature extent") }
        let length = try word(signature + 4)
        let count = try word(signature + 8)
        guard length >= 12, length <= allocation, count <= (length - 12) / 8 else {
            throw invalid("invalid signature index")
        }
        struct Directory {
            let start: Int, hashes: Int, pages: Int, limit: Int, width: Int, kind: Int, pageSize: Int
        }
        var directories: [Directory] = []
        var spans: [Range<Int>] = []
        for i in 0..<count {
            let relative = try word(signature + 16 + i * 8)
            guard relative >= 12 + count * 8, relative <= length - 8 else {
                throw invalid("invalid blob offset")
            }
            let cd = signature + relative
            let size = try word(cd + 4)
            guard size >= 8, size <= length - relative else { throw invalid("truncated blob") }
            spans.append(relative..<(relative + size))
            guard try word(cd) == 0xfade_0c02 else { continue }
            guard size >= 44 else { throw invalid("truncated CodeDirectory") }
            let version = try word(cd + 8)
            guard (0x20000...0x20100).contains(version) else { throw invalid("unsupported CodeDirectory version") }
            let minimum = version >= 0x20100 ? 48 : 44
            guard size >= minimum else { throw invalid("truncated CodeDirectory header") }
            let hashes = try word(cd + 16)
            let identifier = try word(cd + 20)
            let special = try word(cd + 24)
            let pages = try word(cd + 28)
            let limit = try word(cd + 32)
            let width = Int(data[cd + 36])
            let kind = Int(data[cd + 37])
            let exponent = Int(data[cd + 39])
            guard (kind == 1 && width == 20) || (kind == 2 && width == 32),
                (1...20).contains(exponent), limit > 0, limit <= signature,
                hashes >= minimum + special * width, hashes <= size,
                pages <= (size - hashes) / width
            else { throw invalid("unsupported code-page layout") }
            let pageSize = 1 << exponent
            let metadataEnd = hashes - special * width
            guard pages == (limit + pageSize - 1) / pageSize,
                identifier >= minimum, identifier < metadataEnd,
                data[(cd + identifier)..<(cd + metadataEnd)].contains(0)
            else {
                throw invalid("invalid code-page coverage or identifier")
            }
            if version >= 0x20100 {
                let scatter = try word(cd + 44)
                if scatter != 0 {
                    guard scatter >= minimum else { throw invalid("invalid scatter vector") }
                    var entry = scatter
                    var previousEnd = 0
                    while true {
                        guard entry <= metadataEnd - 24 else { throw invalid("unterminated scatter vector") }
                        let amount = try word(cd + entry)
                        let first = try word(cd + entry + 4)
                        let target = try word(cd + entry + 8, count: 8)
                        let spare = try word(cd + entry + 16, count: 8)
                        guard spare == 0 else { throw invalid("unsupported scatter record") }
                        if amount == 0 {
                            guard first == 0, target == 0 else { throw invalid("invalid scatter terminator") }
                            break
                        }
                        // Cache scatter targets are virtual mappings. Hash
                        // slots still cover the signed file range in order.
                        guard first >= previousEnd, amount <= pages, first <= pages - amount,
                            target > 0, target % pageSize == 0
                        else { throw invalid("invalid scatter mapping") }
                        previousEnd = first + amount
                        entry += 24
                    }
                }
            }
            directories.append(
                Directory(
                    start: cd, hashes: hashes, pages: pages, limit: limit,
                    width: width, kind: kind, pageSize: pageSize))
        }
        let sorted = spans.sorted { $0.lowerBound < $1.lowerBound }
        for i in sorted.indices.dropFirst() where sorted[i - 1].upperBound > sorted[i].lowerBound {
            throw invalid("overlapping signature blobs")
        }
        guard !directories.isEmpty else { throw invalid("no supported CodeDirectory") }
        var result = data
        for cd in directories {
            for page in 0..<cd.pages {
                let bytes = data[(page * cd.pageSize)..<min(cd.limit, (page + 1) * cd.pageSize)]
                let digest = cd.kind == 1 ? Data(Insecure.SHA1.hash(data: bytes)) : Data(SHA256.hash(data: bytes))
                let at = cd.start + cd.hashes + page * cd.width
                if data[at..<(at + cd.width)] != digest {
                    result.replaceSubrange(at..<(at + cd.width), with: digest)
                }
            }
        }
        return result
    }
}
