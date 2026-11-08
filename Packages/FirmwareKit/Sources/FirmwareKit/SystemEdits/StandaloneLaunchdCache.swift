import Foundation

extension LaunchdCache {
    /// Update only named jobs in the native v4 metadata. Slice sizes, offsets,
    /// unrelated jobs and other architectures remain unchanged.
    static func updatingStandalone(_ original: Data, jobs: [String: Data], removing: [String]) throws -> Data {
        func invalid() -> FirmwareError { FirmwareError(.unsupported, "unsupported standalone launchd service cache") }
        func word(_ bytes: Data, _ offset: Int, big: Bool = false) throws -> Int {
            guard offset >= 0, offset <= bytes.count - 4 else { throw invalid() }
            return (0..<4).reduce(0) { $0 | Int(bytes[offset + $1]) << (big ? 24 - 8 * $1 : 8 * $1) }
        }
        guard let parsed = MachOSignature.images(original), parsed.fat,
              try word(original, 0, big: true) == 0xcafebabe else { throw invalid() }
        let count = try word(original, 4, big: true)
        guard count == parsed.images.count, count <= (original.count - 8) / 20 else { throw invalid() }
        var result = original, ranges: [Range<Int>] = [], updated = 0
        for index in 0..<count {
            let arch = 8 + index * 20
            let cpu = try word(original, arch, big: true), subtype = try word(original, arch + 4, big: true)
            let start = try word(original, arch + 8, big: true), size = try word(original, arch + 12, big: true)
            guard start >= 8 + count * 20, size > 0, start <= original.count - size else { throw invalid() }
            let range = start..<(start + size)
            guard !ranges.contains(where: { $0.overlaps(range) }) else { throw invalid() }
            ranges.append(range)
            guard cpu == 12, [9, 11].contains(subtype & 0x00ffffff) else { continue }
            var slice = original.subdata(in: range)
            guard try word(slice, 4) == cpu, try word(slice, 8) == subtype,
                  let section = try MachO(slice).segments.flatMap(\.sections).first(where: { $0.name == "__xpcd_cache" }) else {
                throw invalid()
            }
            let offset = Int(section.offset), capacity = Int(section.size)
            guard capacity >= 40, offset <= slice.count - capacity else { throw invalid() }
            let before = slice.subdata(in: offset..<(offset + capacity))
            guard var plist = try PropertyListSerialization.propertyList(from: before, format: nil) as? [String: Any],
                  plist["VersionNumber"] as? Int == 4,
                  var daemons = plist["LaunchDaemons"] as? [String: Any] else { throw invalid() }
            for (path, data) in jobs {
                guard path.hasPrefix("/System/Library/LaunchDaemons/"), path.hasSuffix(".plist"),
                      let job = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    throw invalid()
                }
                daemons[path] = job
            }
            for path in removing {
                guard path.hasPrefix("/System/Library/LaunchDaemons/"), path.hasSuffix(".plist") else { throw invalid() }
                daemons.removeValue(forKey: path)
            }
            plist["LaunchDaemons"] = daemons
            let padded = try paddedMetadata(plist, capacity: capacity)
            slice.replaceSubrange(offset..<(offset + capacity), with: padded)
            slice = try Activation.signed(slice, preservingEmptyCMS: true)
            result.replaceSubrange(range, with: slice)
            updated += 1
        }
        guard updated > 0 else { throw invalid() }
        return result
    }
}
