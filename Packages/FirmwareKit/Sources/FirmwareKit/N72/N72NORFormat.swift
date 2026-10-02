import Foundation

/// Conversion of the generated N72 NOR's signature envelopes. Hardware models
/// must not infer this host preparation format from guest DMA addresses.
public enum N72NORFormat {
    public static let canonical = "n72-uid-encrypt-v2"
    public enum Failure: Error, Equatable {
        case malformedNOR, changedFirmware, unknownWrapping, unsupportedBuild
    }
    public struct Plan: Sendable {
        public let base: Data
        public let writable: Data
        public let signatureRanges: [Range<Int>]
    }

    /// Stock 5F138 restore independently demonstrated all-image wrapping. Other
    /// firmware's readers require their own qualification before admission here.
    public static func migrate(build: String, base: Data, writable: Data,
                               legacyWrappedTypes: [String], expectedImageTypes: [String]) throws -> Plan {
        guard build == "5F138" else { throw Failure.unsupportedBuild }
        let images = try scan(base, expectedTypes: expectedImageTypes)
        let working = try scan(writable, expectedTypes: expectedImageTypes)
        guard images.map(\.type) == working.map(\.type),
              images.map(\.whole) == working.map(\.whole),
              images.map(\.signature) == working.map(\.signature) else {
            throw Failure.changedFirmware
        }
        guard Set(legacyWrappedTypes).isSubset(of: Set(images.map(\.type))) else {
            throw Failure.unknownWrapping
        }
        let iv = Data(count: 16)
        let oldKey = try AESCBC.crypt(N72NOR.kdfConst, iv: iv, key: N72NOR.uidKey, decrypt: true)
        let newKey = try AESCBC.crypt(N72NOR.kdfConst, iv: iv, key: N72NOR.uidKey, decrypt: false)
        var outputBase = base, outputWritable = writable
        for image in images {
            let raw = legacyWrappedTypes.contains(image.type)
                ? try AESCBC.crypt(base.subdata(in: image.signature), iv: iv, key: oldKey, decrypt: true)
                : base.subdata(in: image.signature)
            let canonicalSignature = try AESCBC.crypt(raw, iv: iv, key: newKey, decrypt: false)
            // A working NOR may already contain the exact converted signature,
            // but a restore or arbitrary firmware replacement must not be guessed.
            let workingSignature = writable.subdata(in: image.signature)
            guard workingSignature == base.subdata(in: image.signature) || workingSignature == canonicalSignature else {
                throw Failure.changedFirmware
            }
            var originalImage = base.subdata(in: image.whole)
            var workingImage = writable.subdata(in: image.whole)
            let local = (image.signature.lowerBound - image.whole.lowerBound)..<(image.signature.upperBound - image.whole.lowerBound)
            originalImage.replaceSubrange(local, with: Data(count: local.count))
            workingImage.replaceSubrange(local, with: Data(count: local.count))
            guard originalImage == workingImage else { throw Failure.changedFirmware }
            outputBase.replaceSubrange(image.signature, with: canonicalSignature)
            outputWritable.replaceSubrange(image.signature, with: canonicalSignature)
        }
        return Plan(base: outputBase, writable: outputWritable, signatureRanges: images.map(\.signature))
    }

    private struct Image {
        let type: String
        let whole: Range<Int>
        let signature: Range<Int>
    }
    private static func scan(_ data: Data, expectedTypes: [String]) throws -> [Image] {
        guard !expectedTypes.isEmpty, Set(expectedTypes).count == expectedTypes.count else { throw Failure.unknownWrapping }
        let bytes = [UInt8](data)
        guard bytes.count == 0x100000, bytes.prefix(4).elementsEqual("2GMI".utf8),
              word(bytes, 4) == 0x40, word(bytes, 8) == 0, word(bytes, 12) == 0x200,
              N72NOR.crc(bytes[0..<0x30]) == word(bytes, 0x30) else { throw Failure.malformedNOR }
        var result: [Image] = [], seen = Set<String>(), offset = 0x8000
        while offset + 20 <= 0xfc000 && bytes[offset..<offset + 4].elementsEqual("3gmI".utf8) {
            let size = Int(word(bytes, offset + 4)), payload = Int(word(bytes, offset + 8))
            guard size >= 20, size % 64 == 0, size <= 0xfc000 - offset,
                  payload <= size - 20 else { throw Failure.malformedNOR }
            let type = String(decoding: bytes[offset + 16..<offset + 20].reversed(), as: UTF8.self)
            guard seen.insert(type).inserted else { throw Failure.malformedNOR }
            let end = offset + 20 + payload
            var tag = offset + 20, signature: Range<Int>?
            while tag < end {
                guard end - tag >= 12 else { throw Failure.malformedNOR }
                let total = Int(word(bytes, tag + 4)), length = Int(word(bytes, tag + 8))
                guard total >= 12, total <= end - tag, length <= total - 12 else { throw Failure.malformedNOR }
                if bytes[tag..<tag + 4].elementsEqual("HSHS".utf8) {
                    guard signature == nil, length == 128,
                          tag - offset >= 20 + Int(word(bytes, offset + 12)) else { throw Failure.malformedNOR }
                    signature = tag + 12..<tag + 12 + length
                }
                tag += total
            }
            guard let signature else { throw Failure.malformedNOR }
            result.append(Image(type: type, whole: offset..<offset + size, signature: signature))
            offset += size
        }
        // Admission is for this preparer's recorded image inventory, not an
        // arbitrary NOR prefix. Reject missing images and unrecognized gaps;
        // both Python and Swift generated formats zero-fill this unused area.
        // The builder owns the image-area boundary; bytes outside that region
        // (including mutable NVRAM) are preserved and never interpreted here.
        guard result.map(\.type) == expectedTypes,
              Int(word(bytes, 0x10)) * 64 == offset,
              bytes[offset..<N72NOR.nvram].allSatisfy({ $0 == 0 }) else {
            throw Failure.malformedNOR
        }
        return result
    }
    private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
}
