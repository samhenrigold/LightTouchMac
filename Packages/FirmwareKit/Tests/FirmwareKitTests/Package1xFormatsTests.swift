import Foundation
import Testing

@testable import FirmwareKit

/// iPhone OS 1.x packages beyond PXL and one-app zips (Package1x): a .tgz root tree
/// and a RAR.
struct Package1xFormatsTests {
    let fm = FileManager.default
    let t = Package1xTests()

    func scratch(_ name: String) -> URL {
        fm.temporaryDirectory.appendingPathComponent("ltm-pkg1x-\(name)-\(UUID().uuidString)")
    }

    /// `/usr/bin/tar -czf` of `folder`'s contents (names ./…, as aSMS's are).
    func tgz(_ folder: URL, _ out: URL) throws -> URL {
        let p = try Process.run(
            URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-czf", out.path, "-C", folder.path, "."])
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return out
    }

    /// aSMS's shape: a daemon, a tool and a readme beside them.
    @Test func aTgzRootTreeInstallsWithoutItsReadme() throws {
        let dir = scratch("tgz")
        defer { try? fm.removeItem(at: dir) }
        let pkg = dir.appendingPathComponent("pkg")
        try JailbreakTests.put(Data("<plist/>".utf8), pkg, "Library/LaunchDaemons/com.example.sms.plist")
        try JailbreakTests.put(Package1xTests.machO(subtype: 6), pkg, "usr/bin/sms")
        try JailbreakTests.put(Data("read me".utf8), pkg, "readme")
        let package = try Package1x.load(tgz(pkg, dir.appendingPathComponent("sms-0.2.tgz")))
        #expect(package.identifier == "sms-0.2")
        #expect(package.placements.map(\.path).contains("/usr/bin/sms"))
        #expect(!package.placements.map(\.path).contains("/readme"))
        #expect(package.warnings == ["readme left out: a file beside the root's folders"])
        let r = try t.root(dir.appendingPathComponent("root"), mobile: false)
        _ = try package.install(MountedVolume(root: r))
        #expect(try t.mode(r.appendingPathComponent("usr/bin/sms")) == 0o755)
        #expect(fm.fileExists(atPath: r.appendingPathComponent("Library/LaunchDaemons/com.example.sms.plist").path))
    }

    @Test func aTgzThatInflatesTooFarOrClimbsOutIsRefused() throws {
        let dir = scratch("tgz-bad")
        defer { try? fm.removeItem(at: dir) }
        let big = dir.appendingPathComponent("big")
        try JailbreakTests.put(Data(count: 2 << 20), big, "usr/zeros")
        let gz = try Data(contentsOf: tgz(big, dir.appendingPathComponent("big.tgz")))
        #expect(throws: FirmwareError.self) { try TarArchive(gz, limit: 1 << 20) }
        #expect(try TarArchive(gz).members.contains { $0.path == "usr/zeros" })
        let out = dir.appendingPathComponent("out")
        try JailbreakTests.put(Data("x".utf8), out, "usr/x")
        let p = try Process.run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: [
                "-czf", dir.appendingPathComponent("out.tgz").path, "-C", out.path, "-s", ",^usr,usr/../..,", "usr"
            ]
        )
        p.waitUntilExit()
        let error = #expect(throws: FirmwareError.self) { try Package1x.load(dir.appendingPathComponent("out.tgz")) }
        #expect(error?.message.contains("is outside the package") == true, "\(error?.message ?? "")")
    }

    /// Unrar.swift's own multibyte.v4.rar (MIT): a RAR 4 archive, as 2007's were, with Windows separators and two
    /// folders.
    @Test func aRARIsReadAsItsMembers() throws {
        let dir = scratch("rar")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let rar = dir.appendingPathComponent("archive.rar")
        try Data(
            base64Encoded:
                "UmFyIRoHAM+QcwAADQAAAAAAAABFgnQgglgADwAAAA8AAAAD5xuEuJCaI1IdMDgApIEAAOOCouODvOOCq+OCpOODllzjgrXjg7Pjg5Xjgprjg6sudHh0ADBVovyrpEXWXLXzVNWa6y4AdHh044GT44KT44Gr44Gh44Gv8v50IIJwAA8AAAAPAAAAA+cbhLiQmiNSHTBQAKSBAADjgqLjg7zjgqvjgqTjg5Zc44OV44Kp44Or44K/44KZXOOCteODs+ODleOCmuODqy50eHQAMFWi/KukRdZc1alU67+ZXFW189WaQOsudHgAdOOBk+OCk+OBq+OBoeOBr5UndOCSUQAAAAAAAAAAAAMAAAAAlJojUhQwLwDtQQAA44Ki44O844Kr44Kk44OWXOODleOCqeODq+OCv+OCmQAwVaL8q6RF1lzVqVTrv5kAwNnrdOCSOgAAAAAAAAAAAAMAAAAAFZsjUhQwGADtQQAA44Ki44O844Kr44Kk44OWADBVovyrpEDWAMDEPXsAQAcA"
        )!.write(to: rar)
        let members = try Package1x.members(rar)
        let files = members.filter { if case .file = $0.value { true } else { false } }
        #expect(files.count == 2 && members.count == 4, "\(members.keys.sorted())")
        #expect(files.values.allSatisfy { $0 == .file(Data("こんにちは".utf8), mode: 0o644) })
        #expect(members.keys.allSatisfy { !$0.contains("\\") && $0.hasPrefix("アーカイブ") })
        let error = #expect(throws: FirmwareError.self) { try Package1x.load(rar) }
        #expect(error?.message.contains("neither a PXL") == true, "a folder of text files has nowhere to go")
    }
}
