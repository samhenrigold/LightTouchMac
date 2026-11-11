import Foundation

/// Flat A6 media uses native 4096-byte sectors. Data occupies all space after
/// System, rather than inheriting the size of a temporary seed filesystem.
public struct A6StorageLayout: Equatable, Sendable {
    public static let defaultMediaBytes: UInt64 = 16_000_000_000
    public static let sectorBytes: UInt64 = 4096
    public let mediaBytes: UInt64
    public let systemOffset: UInt64
    public let systemBytes: UInt64
    public let dataOffset: UInt64
    public let dataBytes: UInt64

    public init(
        mediaBytes: UInt64 = Self.defaultMediaBytes,
        systemBytes: UInt64 = 3 << 30
    ) throws {
        let start: UInt64 = 16 << 20
        let (end, overflow) = start.addingReportingOverflow(systemBytes)
        guard !overflow, systemBytes > 0,
            systemBytes.isMultiple(of: Self.sectorBytes),
            mediaBytes.isMultiple(of: Self.sectorBytes),
            mediaBytes / Self.sectorBytes <= UInt64(UInt32.max),
            end < mediaBytes
        else {
            throw FirmwareError(.unsupported, "Invalid A6 System/Data media geometry")
        }
        self.mediaBytes = mediaBytes
        self.systemOffset = start
        self.systemBytes = systemBytes
        self.dataOffset = end
        self.dataBytes = mediaBytes - end
    }

    /// A new native-sector MBR. This is a preparation artifact, not an edit of
    /// an existing disk: resizing existing protected Data uses the native HFS
    /// driver and preserves its volume identity, files and keybag.
    public func partitionTable() -> Data {
        var table = Data(repeating: 0, count: Int(Self.sectorBytes))
        for (index, range) in [(systemOffset, systemBytes), (dataOffset, dataBytes)].enumerated() {
            let entry = 446 + index * 16
            table[entry + 1] = 254
            table[entry + 2] = 255
            table[entry + 3] = 255
            table[entry + 4] = 0xaf
            table[entry + 5] = 254
            table[entry + 6] = 255
            table[entry + 7] = 255
            for (offset, value) in [(8, range.0 / Self.sectorBytes), (12, range.1 / Self.sectorBytes)] {
                for byte in 0..<4 { table[entry + offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
            }
        }
        table[510] = 0x55
        table[511] = 0xaa
        return table
    }
}
