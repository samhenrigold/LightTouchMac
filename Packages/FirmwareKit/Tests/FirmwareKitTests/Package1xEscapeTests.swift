import Foundation
import Testing
import ZIPFoundation

@testable import FirmwareKit

/// Ways out of a 1.x package beyond a zip member's name (Package1x): a tar's links, links planted by earlier members
/// and written through by later ones (tar and zip), a RAR's names, and members that inflate past their declared size.
/// Each is refused, or lands inside the volume and the folders a package may write.
struct Package1xEscapeTests {
    let fm = FileManager.default
    let t = Package1xTests()

    func scratch(_ name: String) -> URL {
        fm.temporaryDirectory.appendingPathComponent("ltm-pkg1x-\(name)-\(UUID().uuidString)")
    }

    /// A ustar archive of `members` in order (a nil data a folder, a "->" prefix a link to the rest), written by
    /// hand so no host path is ever followed making it.
    static func ustar(_ members: [(String, Data?, UInt16)]) -> Data {
        var out = Data()
        for (name, data, mode) in members {
            let link = data.flatMap { String(data: $0, encoding: .utf8) }.flatMap {
                $0.hasPrefix("->") ? String($0.dropFirst(2)) : nil
            }
            let body = link == nil ? data ?? Data() : Data()
            var h = [UInt8](repeating: 0, count: 512)
            func put(_ s: String, _ at: Int) { for (i, c) in s.utf8.enumerated() { h[at + i] = c } }
            put(name, 0)
            put(String(format: "%07o", mode), 100)
            put("0000000", 108)
            put("0000000", 116)
            put(String(format: "%011o", body.count), 124)
            put(String(format: "%011o", 0), 136)
            put("        ", 148)
            h[156] = link != nil ? UInt8(ascii: "2") : data == nil ? UInt8(ascii: "5") : UInt8(ascii: "0")
            if let link { put(link, 157) }
            put("ustar", 257)
            put("00", 263)
            put(String(format: "%06o", h.reduce(0) { $0 + Int($1) }) + "\0 ", 148)
            out += Data(h) + body + Data(count: (512 - body.count % 512) % 512)
        }
        return out + Data(count: 1024)
    }

    @Test(arguments: ["/etc/passwd", "../../..", "../../../private"])
    func aTarLinkOutOfThePackageIsRefused(_ target: String) throws {
        let dir = scratch("tar-link")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("p.tar")
        try Self.ustar([("usr/bin/x", Data("x".utf8), 0o755), ("usr/bin/out", Data(("->" + target).utf8), 0o755)])
            .write(to: url)
        let error = #expect(throws: FirmwareError.self) { try Package1x.load(url) }
        #expect(error?.message.contains("links outside the package") == true, "\(error?.message ?? "")")
    }

    /// Links that each stay inside the package as named, chained so the device's own links take a later member
    /// further: what is written lands inside the volume's allowed folders, or the package is refused.
    @Test(
        arguments: [
            // l -> .. puts l/x in /Applications: still a folder a package may write
            ([("l", ".."), ("l/x", nil)], "Applications/x"),
            // l/m -> .. from inside /Applications is /: l/m/dev/x is /dev/x
            ([("l", ".."), ("l/m", ".."), ("l/m/dev/x", nil)], nil),
            // a link at / itself is outside the folders
            ([("l", ".."), ("l/m", ".."), ("l/m/n", "..")], nil),
            // a link in private climbing above the volume, then a file through it
            ([("l", ".."), ("l/m", ".."), ("l/m/private/a/b/n", "../../../.."), ("l/m/private/a/b/n/x", nil)], nil),
            // the same link alone: it would point above the volume
            ([("l", ".."), ("l/m", ".."), ("l/m/private/a/b/n", "../../../..")], nil)
        ] as [([(String, String?)], String?)])
    func linksPlantedByEarlierMembersStayInside(_ members: [(String, String?)], _ lands: String?) throws {
        let fixture: Set<String> = ["var", "etc", "Applications/dev", "Applications/up"]  // the root's own links
        for format in ["zip", "tar"] {
            let dir = scratch("planted-\(format)")
            defer { try? fm.removeItem(at: dir) }
            let entries: [(String, Data?, UInt16)] =
                [("Edit.app/Info.plist", try Package1xTests.plist(["CFBundleIdentifier": "com.example.edit"]), 0o644)]
                + members.map { name, link in
                    ("Edit.app/" + name, Data((link.map { "->" + $0 } ?? "x").utf8), link == nil ? 0o644 : 0o755)
                }
            let url: URL
            if format == "zip" {
                url = try t.zip(dir, "p.zip", entries)
            } else {
                url = dir.appendingPathComponent("p.tar")
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try Self.ustar(entries).write(to: url)
            }
            let r = try t.root(dir.appendingPathComponent("volume/root"), mobile: false)
            let installed = (try? Package1x.load(url).install(MountedVolume(root: r))) != nil
            #expect(installed == (lands != nil), "\(format) \(members)")
            if let lands { #expect(fm.fileExists(atPath: r.appendingPathComponent(lands).path), "\(format)") }
            let beside = try fm.contentsOfDirectory(atPath: dir.appendingPathComponent("volume").path)
            #expect(beside == ["root"], "\(format): nothing beside the volume")
            #expect(!fm.fileExists(atPath: r.appendingPathComponent("dev/x").path), "\(format)")
            // no link the package made points out of the volume
            for rel in fm.subpaths(atPath: r.path) ?? [] where !fixture.contains(rel) {
                guard let target = try? fm.destinationOfSymbolicLink(atPath: r.appendingPathComponent(rel).path)
                else { continue }
                let resolved =
                    ((r.appendingPathComponent(rel).deletingLastPathComponent().path as NSString)
                    .appendingPathComponent(target) as NSString).standardizingPath
                #expect(resolved.hasPrefix(r.path), "\(format): \(rel) -> \(target) leaves the volume")
            }
        }
    }

    /// A RAR 4 archive of stored files, as WinRAR wrote them in 2007 (host OS Windows: names with "\").
    static func rar4(_ files: [(String, Data)]) -> Data {
        func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        func block(_ body: [UInt8]) -> [UInt8] {
            le(UInt16(truncatingIfNeeded: Data(body).crc32(checksum: 0))) + body
        }
        var out: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
        out += block([0x73] + le(UInt16(0)) + le(UInt16(13)) + le(UInt16(0)) + le(UInt32(0)))
        for (name, data) in files {
            let n = Array(name.utf8)
            var header: [UInt8] = [0x74] + le(UInt16(0x8000)) + le(UInt16(32 + n.count))
            header += le(UInt32(data.count)) + le(UInt32(data.count)) + [2] + le(data.crc32(checksum: 0))
            header += le(UInt32(0x3721_0000)) + [20, 0x30] + le(UInt16(n.count)) + le(UInt32(0x20)) + n
            out += block(header) + Array(data)
        }
        return Data(out + [0xC4, 0x3D, 0x7B, 0x00, 0x40, 0x07, 0x00])
    }

    @Test func aStoredRAR4IsRead() throws {
        let dir = scratch("rar4")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("p.rar")
        try Self.rar4([("Edit.app\\Info.plist", Data("plist".utf8))]).write(to: url)
        #expect(try Package1x.members(url)["Edit.app/Info.plist"] == .file(Data("plist".utf8), mode: 0o644))
    }

    @Test(arguments: ["..\\..\\escape", "Edit.app\\..\\..\\escape", "\\escape", "/escape", "Edit.app/../../escape"])
    func aRARNameOutOfThePackageIsRefused(_ name: String) throws {
        let dir = scratch("rar-name")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("p.rar")
        try Self.rar4([("Edit.app\\Info.plist", Data("plist".utf8)), (name, Data("x".utf8))]).write(to: url)
        let error = #expect(throws: FirmwareError.self, "\(name)") { try Package1x.load(url) }
        #expect(error?.message.contains("is outside the package") == true, "\(name): \(error?.message ?? "")")
        #expect(try fm.contentsOfDirectory(atPath: dir.path) == ["p.rar"])
    }

    /// A zip member that says it is 16 bytes and inflates past maxMember: refused while it streams.
    @Test func aZipMemberLargerThanItSaysIsRefused() throws {
        let dir = scratch("zip-bomb")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let deflated = try (Data(count: Package1x.maxMember + 1) as NSData).compressed(using: .zlib) as Data
        func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        let name = Array("bomb.bin".utf8)
        let fields =
            le(UInt16(20)) + le(UInt16(0)) + le(UInt16(8)) + le(UInt32(0)) + le(UInt32(0))
            + le(UInt32(deflated.count)) + le(UInt32(16)) + le(UInt16(name.count)) + le(UInt16(0))
        let local = [0x50, 0x4B, 0x03, 0x04] + fields + name
        let central =
            [0x50, 0x4B, 0x01, 0x02] + le(UInt16(0x0314)) + fields + le(UInt16(0)) + le(UInt16(0))
            + le(UInt16(0)) + le(UInt32(0o100644 << 16)) + le(UInt32(0)) + name
        let start = local.count + deflated.count
        let end =
            [0x50, 0x4B, 0x05, 0x06] + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(1)) + le(UInt16(1))
            + le(UInt32(central.count)) + le(UInt32(start)) + le(UInt16(0))
        let url = dir.appendingPathComponent("bomb.zip")
        try (Data(local) + deflated + Data(central) + Data(end)).write(to: url)
        let error = #expect(throws: FirmwareError.self) { try Package1x.members(url) }
        #expect(error?.message.contains("is too large") == true, "\(error?.message ?? "")")
    }
}
