// What a device wrote, read by the unsandboxed preparer at a stopped edit: a guest that controls its own volumes and
// overlay must not crash the edit, size its reads, or steer its reads and writes outside the device's folder.

import Foundation
import Testing

@testable import FirmwareKit

struct GuestWrittenInputTests {
    /// A journaled volume whose journal info block says `offset` and `size`.
    static func journaledVolume(offset: UInt64, size: UInt64, in dir: URL) throws -> URL {
        let image = dir.appendingPathComponent("data.hfs")
        try HFSPlusWriter.makeHFS(image, size: 8 << 20)
        let header = try Data(contentsOf: image)[1024 + 12..<1024 + 16]  // journalInfoBlock, in 4 KiB blocks
        let jib = header.reduce(0) { $0 << 8 | UInt64($1) } * 4096
        let handle = try FileHandle(forWritingTo: image)
        defer { try? handle.close() }
        try handle.seek(toOffset: jib + 36)
        try handle.write(contentsOf: [offset, size].flatMap { v in (0..<8).map { UInt8(v >> (56 - 8 * $0) & 0xFF) } })
        return image
    }

    /// A journal offset with its top bit set trapped converting to an Int, and a size past the volume sized the
    /// snapshot's buffer: both are refused, the volume's own journal is still read.
    static let outside: [(UInt64, UInt64)] = [(1 << 63, 512 << 10), (4096, 1 << 40), (8 << 20, 4096)]

    @Test(arguments: outside)
    func aJournalOutsideTheVolumeIsRefused(_ offset: UInt64, _ size: UInt64) throws {
        let dir = try Fixtures.tempDir("guest-journal")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fine = try Self.journaledVolume(offset: 8192, size: 512 << 10, in: dir)
        #expect(try HFSPlusVolume(fine).journal()?.size == 512 << 10)
        let image = try Self.journaledVolume(offset: offset, size: size, in: dir)
        #expect(throws: FirmwareError.self) { try HFSPlusVolume(image).journal() }
        #expect(throws: FirmwareError.self) { try HFSPlusVolume(image).journalSnapshot() }
    }
}
