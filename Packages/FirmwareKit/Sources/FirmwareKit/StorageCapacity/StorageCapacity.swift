import Foundation

/// Available bytes on the destination volume, including reclaimable capacity
/// when macOS provides it. Some command-line/tmp URLs report an unusable zero
/// for ImportantUsage despite physically available space; filesystem attributes
/// supply the physically available bytes as a fallback.
/// This Foundation-only leaf is also compiled directly by the GUI target, which
/// does not link the IPSW preparation package and its image-processing dependencies.
public enum StorageCapacity {
    nonisolated public static func available(at directory: URL) throws -> Int64 {
        try available(important: {
            try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        }, physical: {
            let values = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
            guard let value = values[.systemFreeSize] as? NSNumber else {
                throw NSError(domain: "StorageCapacity", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot inspect free space at \(directory.path)"])
            }
            return Int64(clamping: value.uint64Value)
        })
    }

    nonisolated static func available(important: () -> Int64?, physical: () throws -> Int64) throws -> Int64 {
        if let value = important(), value > 0 { return value }
        return max(0, try physical())
    }
}
