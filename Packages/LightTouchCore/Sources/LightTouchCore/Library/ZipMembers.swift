// Zip members read in process (ZIPFoundation): an .ipa's paths, modes and small files, an IPSW's Restore.plist.
// Members are named exactly, never as patterns, so `[`, `]`, `*` and `?` in a bundle name are just characters.

import Foundation
import ZIPFoundation

public nonisolated enum ZipMembers {
    /// Every path in the archive; empty when it is not a readable zip.
    public static func paths(_ zip: URL) -> [String] {
        guard let archive = try? Archive(url: zip, accessMode: .read, pathEncoding: nil) else { return [] }
        return archive.map(\.path)
    }

    /// The member's bytes, or nil when it is missing, empty, over `limit` bytes or unreadable.
    public static func data(_ zip: URL, _ path: String, limit: Int = 1 << 22) -> Data? {
        guard let archive = try? Archive(url: zip, accessMode: .read, pathEncoding: nil), let entry = archive[path],
            entry.type == .file, entry.uncompressedSize > 0, entry.uncompressedSize <= UInt64(limit)
        else { return nil }
        // The declared size is the archive's word: the stream itself is held to `limit` too, or a member declared
        // small could inflate until memory ran out.
        struct OverLimit: Error {}
        var data = Data()
        do {
            _ = try archive.extract(entry, skipCRC32: false) { chunk in
                guard data.count + chunk.count <= limit else { throw OverLimit() }
                data.append(chunk)
            }
        } catch { return nil }
        return data
    }

    /// `range` of the member's bytes (fewer where it ends sooner), or nil when it is missing or unreadable. Nothing
    /// past the range is inflated, so the head of a large binary costs its head.
    public static func data(_ zip: URL, _ path: String, range: Range<Int>) -> Data? {
        guard let archive = try? Archive(url: zip, accessMode: .read, pathEncoding: nil), let entry = archive[path],
            entry.type == .file
        else { return nil }
        struct Enough: Error {}
        var data = Data()
        var offset = 0
        do {
            _ = try archive.extract(entry, skipCRC32: true) { chunk in
                let wanted = range.clamped(to: offset..<(offset + chunk.count))
                data.append(chunk.dropFirst(wanted.lowerBound - offset).prefix(wanted.count))
                offset += chunk.count
                if offset >= range.upperBound { throw Enough() }
            }
        } catch is Enough {
        } catch { return nil }
        return data
    }

    /// The member's POSIX permission bits, or nil when it is missing.
    public static func permissions(_ zip: URL, _ path: String) -> UInt16? {
        guard let archive = try? Archive(url: zip, accessMode: .read, pathEncoding: nil), let entry = archive[path]
        else { return nil }
        return (entry.fileAttributes[.posixPermissions] as? NSNumber).map { UInt16(truncating: $0) }
    }
}
