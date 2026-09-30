import Foundation

extension StorageCapacity {
    public static func require(_ bytes: Int64, at directory: URL) throws {
        guard bytes > 0 else { return }
        try require(bytes, available: available(at: directory))
    }

    static func require(_ bytes: Int64, available: Int64) throws {
        guard available >= bytes else {
            throw FirmwareError(.diskFull, "needs \(bytes) bytes, \(available) available")
        }
    }
}
