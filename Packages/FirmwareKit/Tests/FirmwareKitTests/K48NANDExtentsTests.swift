import Darwin
import Foundation
import Testing

@testable import FirmwareKit

/// Which bytes of a NAND file hold data decides what a migration copies and a pack keeps, so a volume that can't say
/// (lseek's ENOTSUP on an App Translocation mount, or any other failure) must leave the rest counted as data.
struct K48NANDExtentsTests {
    private func withFile(size: Int, _ body: (Int32) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-extents-\(UUID().uuidString)")
        try Data(repeating: 1, count: size).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let fd = open(url.path, O_RDONLY)
        #expect(fd >= 0)
        defer { close(fd) }
        try body(fd)
    }

    @Test func aRealFilesExtentsCoverItsData() throws {
        try withFile(size: 8192) { fd in
            #expect(K48NANDImage.dataExtents(fd) == [0..<8192])
        }
    }

    @Test func onlyENXIOEndsTheScan() throws {
        try withFile(size: 8192) { fd in
            let none = K48NANDImage.dataExtents(fd) { _, _, _ in
                errno = ENXIO
                return -1
            }
            #expect(none.isEmpty)
        }
    }

    @Test func aFailedSeekLeavesTheRestAsData() throws {
        try withFile(size: 8192) { fd in
            let unsupported = K48NANDImage.dataExtents(fd) { _, _, _ in
                errno = ENOTSUP
                return -1
            }
            #expect(unsupported == [0..<8192])

            // One extent answered, then the volume fails: what follows it still counts.
            let later = K48NANDImage.dataExtents(fd) { _, offset, whence in
                if offset == 0 { return whence == SEEK_DATA ? 0 : 4096 }
                errno = EIO
                return -1
            }
            #expect(later == [0..<4096, 4096..<8192])

            // SEEK_DATA answered and SEEK_HOLE didn't: everything from the data on.
            let noHole = K48NANDImage.dataExtents(fd) { _, _, whence in
                if whence == SEEK_DATA { return 4096 }
                errno = ENOTSUP
                return -1
            }
            #expect(noHole == [4096..<8192])
        }
    }
}
