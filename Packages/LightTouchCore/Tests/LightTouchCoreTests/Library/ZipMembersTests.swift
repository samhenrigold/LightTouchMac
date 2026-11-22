import Foundation
import Testing

@testable import LightTouchCore

/// A zip member is read up to its limit whatever size the archive declares for it, and a range of one costs only
/// the bytes up to the range's end (ZipMembers).
struct ZipMembersTests {
    /// A zip at `dir`/a.zip with one member, "big", of `count` zero bytes, declared as `declared` bytes when given.
    func zip(in dir: URL, count: Int, declared: UInt32? = nil) throws -> URL {
        try Data(count: count).write(to: dir.appendingPathComponent("big"))
        let url = dir.appendingPathComponent("a.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", url.path, "big"]
        zip.currentDirectoryURL = dir
        try zip.run()
        zip.waitUntilExit()
        guard let declared else { return url }
        // The uncompressed size is at 22 in the local header and 24 in the central directory's.
        var bytes = try Data(contentsOf: url)
        let size = withUnsafeBytes(of: declared.littleEndian) { Data($0) }
        let central = try #require(bytes.range(of: Data([0x50, 0x4b, 0x01, 0x02])))
        bytes.replaceSubrange(22..<26, with: size)
        bytes.replaceSubrange((central.lowerBound + 24)..<(central.lowerBound + 28), with: size)
        try bytes.write(to: url)
        return url
    }

    @Test func aMemberThatInflatesPastItsDeclaredSizeIsRefusedAtTheLimit() async throws {
        try await withTemporaryState { dir in
            let url = try zip(in: dir, count: 8 << 20, declared: 1024)
            #expect(ZipMembers.data(url, "big", limit: 1 << 20) == nil)
            #expect(ZipMembers.data(try zip(in: dir, count: 1 << 16), "big", limit: 1 << 20)?.count == 1 << 16)
        }
    }

    @Test func aRangeOfAMemberIsItsBytesAndEndsWithTheMember() async throws {
        try await withTemporaryState { dir in
            let url = try zip(in: dir, count: 100_000)
            #expect(ZipMembers.data(url, "big", range: 70_000..<70_010) == Data(count: 10))
            #expect(ZipMembers.data(url, "big", range: 99_990..<200_000)?.count == 10)
            #expect(ZipMembers.data(url, "big", range: 200_000..<200_010)?.isEmpty == true)
            #expect(ZipMembers.data(url, "absent", range: 0..<10) == nil)
        }
    }
}
