import Foundation

/// The admitted storage portion of device.json. Guest package/UI metadata may
/// change independently; boot identity, base and storage must name this generation
/// after the helper takes its lease. This is authority checking, not migration.
public nonisolated struct StorageBootProof: Codable, Sendable, Equatable {
    public enum Failure: Error, Equatable { case malformedRecord, missingLease, changedGeneration }
    private let admitted: Data

    public static func capture(record: URL) throws -> Self {
        try capture(recordBytes: Data(contentsOf: record))
    }

    public static func capture(recordBytes: Data) throws -> Self {
        Self(admitted: try storageBytes(recordBytes))
    }

    public func verify(record: URL, lease: StorageLease) throws {
        guard !lease.isClosed else { throw Failure.missingLease }
        guard try Self.storageBytes(Data(contentsOf: record)) == admitted else {
            throw Failure.changedGeneration
        }
    }

    private static func storageBytes(_ data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = object["base"] as? [String: Any], let storage = object["storage"] as? [String: Any],
              let key = storage["key"] as? String, !key.isEmpty else { throw Failure.malformedRecord }
        var bound: [String: Any] = ["base": base, "storage": storage]
        for key in ["id", "board", "firmware", "identity"] {
            if let value = object[key] { bound[key] = value }
        }
        return try JSONSerialization.data(withJSONObject: bound, options: [.sortedKeys])
    }
}
