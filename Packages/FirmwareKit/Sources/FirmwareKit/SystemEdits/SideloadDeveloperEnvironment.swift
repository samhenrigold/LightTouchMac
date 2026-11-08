import Foundation
import CoreFoundation
import Crypto

extension SideloadTools {
    /// The explicitly selected installation helper needs dyld's developer
    /// environment on iOS 9. Keep every existing entitlement and all executable
    /// instructions. A larger entitlement blob may extend the signing tail;
    /// existing file offsets and the signed code limit stay fixed.
    static func installationServiceAllowingEnvironment(_ input: Data) throws -> Data {
        func invalid() -> FirmwareError {
            FirmwareError(.unsupported, "Unsupported installation-service entitlement allocation")
        }
        guard let signature = MachOSignature.codeSignature(in: input),
              signature.size >= 12, signature.offset >= 0,
              signature.size <= input.count, signature.offset <= input.count - signature.size else { throw invalid() }
        let bytes = input.subdata(in: signature.offset..<(signature.offset + signature.size))
        func be(_ data: Data, _ offset: Int) throws -> Int {
            guard offset >= 0, offset <= data.count - 4 else { throw invalid() }
            return (0..<4).reduce(0) { $0 | Int(data[offset + $1]) << (24 - $1 * 8) }
        }
        func put(_ value: Int, _ data: inout Data, _ offset: Int) {
            for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - index * 8)) }
        }
        let length = try be(bytes, 4), count = try be(bytes, 8)
        guard try be(bytes, 0) == 0xfade0cc0, length >= 12, length <= bytes.count,
              count <= (length - 12) / 8 else { throw invalid() }
        var entries: [(type: Int, blob: Data)] = []
        for index in 0..<count {
            let type = try be(bytes, 12 + index * 8), offset = try be(bytes, 16 + index * 8)
            guard offset >= 12 + count * 8, offset <= length - 8 else { throw invalid() }
            let size = try be(bytes, offset + 4)
            guard size >= 8, size <= length - offset else { throw invalid() }
            if type != 0x10000 { entries.append((type, bytes.subdata(in: offset..<(offset + size)))) }
        }
        guard entries.filter({ $0.type == 5 }).count == 1,
              let entitlementIndex = entries.firstIndex(where: { $0.type == 5 }),
              try be(entries[entitlementIndex].blob, 0) == 0xfade7171,
              var entitlements = try PropertyListSerialization.propertyList(
                from: Data(entries[entitlementIndex].blob.dropFirst(8)), format: nil) as? [String: Any] else { throw invalid() }
        if let enabled = entitlements["get-task-allow"] as? NSNumber,
           CFGetTypeID(enabled) == CFBooleanGetTypeID(), enabled.boolValue { return input }
        entitlements["get-task-allow"] = true
        let xml = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
        var entitlementBlob = Data(count: 8)
        put(0xfade7171, &entitlementBlob, 0); put(8 + xml.count, &entitlementBlob, 4)
        entitlementBlob.append(xml)
        entries[entitlementIndex].blob = entitlementBlob
        var directories = 0
        for index in entries.indices where entries[index].type == 0 || (0x1000...0x1005).contains(entries[index].type) {
            var blob = entries[index].blob
            guard blob.count >= 44, try be(blob, 0) == 0xfade0c02 else { throw invalid() }
            let hashOffset = try be(blob, 16), special = try be(blob, 24)
            let width = Int(blob[36]), hashType = blob[37]
            guard special >= 5, (hashType == 1 && width == 20) || (hashType == 2 && width == 32),
                  special <= (blob.count - 44) / width,
                  hashOffset >= 44 + special * width, hashOffset <= blob.count else { throw invalid() }
            let digest = hashType == 1 ? Data(Insecure.SHA1.hash(data: entitlementBlob)) : Data(SHA256.hash(data: entitlementBlob))
            blob.replaceSubrange((hashOffset - 5 * width)..<(hashOffset - 4 * width), with: digest)
            entries[index].blob = blob; directories += 1
        }
        guard directories > 0, entries.contains(where: { $0.type == 0 }) else { throw invalid() }
        var packed = Data(count: 12 + entries.count * 8)
        put(0xfade0cc0, &packed, 0); put(entries.count, &packed, 8)
        for (index, entry) in entries.enumerated() {
            while !packed.count.isMultiple(of: 4) { packed.append(0) }
            put(entry.type, &packed, 12 + index * 8); put(packed.count, &packed, 16 + index * 8)
            packed.append(entry.blob)
        }
        put(packed.count, &packed, 4)
        let allocation = max(signature.size, (packed.count + 15) / 16 * 16)
        packed.append(Data(count: allocation - packed.count))
        var result = input
        guard signature.offset + signature.size == input.count else { throw invalid() }
        result.replaceSubrange(signature.offset..<input.count, with: packed)
        if allocation != signature.size {
            guard let parsed = MachOSignature.images(input), !parsed.fat,
                  let image = parsed.images.first,
                  let command = image.commands.first(where: { $0.cmd == MachOSignature.lcCodeSignature }) else { throw invalid() }
            func le(_ offset: Int) throws -> Int {
                guard offset >= 0, offset <= input.count - 4 else { throw invalid() }
                return (0..<4).reduce(0) { $0 | Int(input[offset + $1]) << ($1 * 8) }
            }
            func putLE(_ value: Int, _ offset: Int) throws {
                guard value >= 0, value <= Int(UInt32.max), offset >= 0, offset <= result.count - 4 else { throw invalid() }
                for index in 0..<4 { result[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
            }
            guard let linkedit = image.commands.first(where: {
                $0.cmd == 1 && $0.offset <= input.count - 56 &&
                String(decoding: input[($0.offset + 8)..<($0.offset + 24)].prefix(while: { $0 != 0 }), as: UTF8.self) == "__LINKEDIT"
            }) else { throw invalid() }
            let fileOffset = try le(linkedit.offset + 32), oldSize = try le(linkedit.offset + 36)
            guard fileOffset + oldSize == input.count, fileOffset <= signature.offset else { throw invalid() }
            let newSize = result.count - fileOffset
            try putLE(allocation, command.offset + 12)
            try putLE(newSize, linkedit.offset + 36)
            try putLE(max(try le(linkedit.offset + 28), (newSize + 4095) / 4096 * 4096), linkedit.offset + 28)
        }
        return try Activation.signed(result)
    }
}
