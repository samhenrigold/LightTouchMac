import Foundation

extension LaunchdCache {
    /// Keep the native section size and its binary-plist trailer position.
    /// Padding goes before the offset table; object offsets stay unchanged.
    static func paddedMetadata(_ plist: [String: Any], capacity: Int) throws -> Data {
        func invalid() -> FirmwareError { FirmwareError(.unsupported, "native launchd metadata capacity or encoding") }
        let payload = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        guard payload.count >= 40, payload.count <= capacity else { throw invalid() }
        var table: UInt64 = 0
        for byte in payload.suffix(8) { table = (table << 8) | UInt64(byte) }
        guard table >= 8, table <= UInt64(payload.count - 32) else { throw invalid() }
        let oldWidth = Int(payload[payload.count - 26])
        guard [1, 2, 4, 8].contains(oldWidth) else { throw invalid() }
        var objects: UInt64 = 0
        for byte in payload[(payload.count - 24)..<(payload.count - 16)] { objects = (objects << 8) | UInt64(byte) }
        guard objects > 0, objects <= UInt64((payload.count - 32 - Int(table)) / oldWidth) else { throw invalid() }
        // CF also requires the offset width to cover the padded allocation.
        // Existing native metadata already has a wide table; tiny dictionaries
        // can require wider entries even though their object offsets stay fixed.
        let width = [1, 2, 4, 8].first { $0 >= oldWidth && ($0 == 8 || UInt64(capacity) < (UInt64(1) << (8 * $0))) }!
        guard objects <= UInt64((capacity - 32) / width) else { throw invalid() }
        let moved = capacity - 32 - Int(objects) * width
        guard moved >= Int(table) else { throw invalid() }
        var padded = Data(payload.prefix(Int(table)))
        padded.append(Data(repeating: 0, count: moved - Int(table)))
        for index in 0..<Int(objects) {
            var offset: UInt64 = 0
            let start = Int(table) + index * oldWidth
            for byte in payload[start..<(start + oldWidth)] { offset = (offset << 8) | UInt64(byte) }
            for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
                padded.append(UInt8(truncatingIfNeeded: offset >> shift))
            }
        }
        var trailer = Data(payload.suffix(32))
        trailer[6] = UInt8(width)
        for index in 0..<8 { trailer[24 + index] = UInt8(truncatingIfNeeded: UInt64(moved) >> (56 - index * 8)) }
        padded.append(trailer)
        guard padded.count == capacity,
            let check = try PropertyListSerialization.propertyList(from: padded, format: nil) as? NSDictionary,
            check == plist as NSDictionary
        else { throw invalid() }
        return padded
    }

    /// 13A344's launchd uses the embedded metadata, rather than iOS 8's
    /// standalone override. Preserve all headers, instructions and unrelated
    /// metadata. Refresh existing signature slots after the bounded edits.
    static func updatingCached(_ original: Data, jobs: [String: Data], removing: [String]) throws -> Data {
        func invalid() -> FirmwareError { FirmwareError(.unsupported, "unrecognized 13A344 launchd shared cache") }
        let uuid = Data([
            0xdd, 0xa0, 0x3c, 0x9d, 0xe2, 0x3b, 0x3a, 0xc2,
            0xa6, 0xef, 0x24, 0x94, 0xbc, 0x26, 0x81, 0x06
        ])
        guard original.count >= 112, original.subdata(in: 88..<104) == uuid,
            original[104] <= 1, original[105..<112].allSatisfy({ $0 == 0 })
        else { throw invalid() }
        let cache = try DyldSharedCache(data: original)
        guard let image = cache.image("/" + path), image.headerOffset >= 0,
            image.headerOffset <= original.count - 4096
        else { throw invalid() }
        let header = original.subdata(in: image.headerOffset..<(image.headerOffset + 4096))
        guard let section = try MachO(header).segments.flatMap(\.sections).first(where: { $0.name == "__xpcd_cache" }),
            let offset = cache.fileOffset(of: UInt64(section.addr)),
            section.size == 439704, offset == 1_874_536,
            offset <= original.count - Int(section.size)
        else { throw invalid() }
        let range = offset..<(offset + Int(section.size))
        guard
            var plist = try PropertyListSerialization.propertyList(from: original.subdata(in: range), format: nil)
                as? [String: Any],
            plist["VersionNumber"] as? Int == 4,
            var daemons = plist["LaunchDaemons"] as? [String: Any]
        else { throw invalid() }
        for (path, data) in jobs {
            guard path.hasPrefix("/System/Library/LaunchDaemons/"), path.hasSuffix(".plist"),
                let job = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { throw invalid() }
            daemons[path] = job
        }
        for path in removing {
            guard path.hasPrefix("/System/Library/LaunchDaemons/"), path.hasSuffix(".plist") else { throw invalid() }
            daemons.removeValue(forKey: path)
        }
        plist["LaunchDaemons"] = daemons
        var result = original
        result.replaceSubrange(range, with: try paddedMetadata(plist, capacity: range.count))
        // The native dyld override gate requires the development cache type.
        // Normal boot admits only this prepared cache's exact identity through
        // A6GuestAssets; no signature verification policy is changed here.
        result.replaceSubrange(104..<112, with: Data(count: 8))
        return try DyldSharedCache(data: result).rehashingCodeSignature()
    }
}
