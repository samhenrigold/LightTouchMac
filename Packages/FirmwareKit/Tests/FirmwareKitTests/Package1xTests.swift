import Foundation
import Testing
import ZIPFoundation

@testable import FirmwareKit

/// iPhone OS 1.x packages from the Mac (Package1x): PXL, an Installer-era zip of one .app, an .app folder, onto a
/// 1.0-style and a 1.1.3-style root, and every way a package is refused.
struct Package1xTests {
    let fm = FileManager.default

    /// A thin ARM Mach-O header with `subtype` (6 armv6, 9 armv7).
    static func machO(subtype: UInt32) -> Data {
        Data(
            [0xFEED_FACE, 12, subtype, 2, 0, 0, 0].flatMap { v in
                (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
            })
    }

    static func plist(_ object: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    /// A zip of `members` (name: data, mode; a nil data a folder; a "->" prefix a link to the rest).
    func zip(_ dir: URL, _ name: String, _ members: [(String, Data?, UInt16)]) throws -> URL {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data, mode) in members {
            let link = data.flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.hasPrefix("->") ? $0 : nil }
            let bytes = link.map { Data($0.dropFirst(2).utf8) } ?? data ?? Data()
            try archive.addEntry(
                with: path,
                type: data == nil ? .directory : link != nil ? .symlink : .file,
                uncompressedSize: Int64(bytes.count),
                permissions: mode,
                provider: { position, size in bytes.subdata(in: Int(position)..<Int(position) + size) }
            )
        }
        return url
    }

    /// A 1.x root: /var and /etc links into private, SpringBoard's launchd job (UserName mobile from 1.1.3), and
    /// (1.0) a DisplayOrder.plist.
    func root(_ dir: URL, mobile: Bool) throws -> URL {
        try fm.createDirectory(at: dir.appendingPathComponent("private/var/root"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("private/var/mobile"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("private/etc"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("var").path, withDestinationPath: "private/var")
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("etc").path, withDestinationPath: "private/etc")
        // a link out of the folders a package may write, and one out of the volume
        try fm.createSymbolicLink(
            atPath: dir.appendingPathComponent("Applications/dev").path, withDestinationPath: "../dev")
        try fm.createSymbolicLink(
            atPath: dir.appendingPathComponent("Applications/up").path, withDestinationPath: "../..")
        var job: [String: Any] = ["Label": "com.apple.SpringBoard"]
        if mobile { job["UserName"] = "mobile" }
        try JailbreakTests.put(Self.plist(job), dir, SystemEdits.springBoardJob)
        if !mobile {
            let order = ["iconList": [["displayIdentifier": "com.apple.Preferences"]], "buttonBar": []]
            try JailbreakTests.put(Self.plist(order), dir, SystemEdits.displayOrder)
        }
        return dir
    }

    /// MobileTextEdit's shape: an app folder to its .app, plus a daemon, a file in root's home and a postflight.
    func pxl(
        _ dir: URL, files: [[String: Any]]? = nil, postflight: [[String]] = [], members: [(String, Data?, UInt16)] = []
    )
        throws -> URL
    {
        let manifest: [String: Any] = [
            "CFBundleIdentifier": "com.example.edit", "RDPxlPackageName": "Edit", "RDPxlPackageVersion": "0.2",
            "RDPxlPackageFiles": files ?? [
                ["source": "app", "destination": "/Applications/Edit.app"],
                ["source": "daemon", "destination": "/Library/LaunchDaemons", "overwrite": false],
                [
                    "source": "notes.txt", "destination": "/var/root/Media/notes.txt", "executable": false,
                    "permanent": true
                ]
            ],
            "RDPxlPackagePostflight": postflight
        ]
        return try zip(
            dir,
            "Edit.pxl",
            [
                ("PxlPkg.plist", try Self.plist(manifest), 0o644),
                ("app/", nil, 0o755),
                ("app/Info.plist", try Self.plist(["CFBundleIdentifier": "com.example.edit.app"]), 0o644),
                ("app/Edit", Self.machO(subtype: 6), 0o644),
                ("app/icon.png", Data("png".utf8), 0o644),
                ("app/Default.png", Data("->icon.png".utf8), 0o755),
                ("daemon/com.example.d.plist", Data("<plist/>".utf8), 0o644),
                ("notes.txt", Data("hi".utf8), 0o755)
            ] + members
        )
    }

    func mode(_ url: URL) throws -> Int {
        (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int) & 0o7777
    }

    @Test(arguments: [false, true])
    func aPXLInstallsItsFilesItsAppOnHomeAndItsReceipt(mobile: Bool) throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-pkg1x-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let r = try root(dir.appendingPathComponent("root"), mobile: mobile)
        let package = try Package1x.load(
            pxl(
                dir,
                postflight: [  // pxldaemon runs these last first: the copy, then launchctl's
                    ["/bin/launchctl", "load", "/Library/LaunchDaemons/com.example.d.plist"],
                    ["/bin/cp", "/var/root/Media/notes.txt", "/var/root/Media/notes.bak"]
                ]
            )
        )
        #expect(package.identifier == "com.example.edit")
        let done = try package.install(MountedVolume(root: r))
        let app = r.appendingPathComponent("Applications/Edit.app")
        #expect(try mode(app.appendingPathComponent("Edit")) == 0o755, "a Mach-O is executable")
        #expect(try mode(app.appendingPathComponent("icon.png")) == 0o644)
        #expect(try fm.destinationOfSymbolicLink(atPath: app.appendingPathComponent("Default.png").path) == "icon.png")
        #expect(fm.fileExists(atPath: r.appendingPathComponent("Library/LaunchDaemons/com.example.d.plist").path))
        let home = r.appendingPathComponent(mobile ? "private/var/mobile/Media" : "private/var/root/Media")
        #expect(try Data(contentsOf: home.appendingPathComponent("notes.txt")) == Data("hi".utf8))
        #expect(try mode(home.appendingPathComponent("notes.txt")) == 0o664, "executable false")
        #expect(fm.fileExists(atPath: home.appendingPathComponent("notes.bak").path), "the postflight's cp")
        #expect(
            !fm.fileExists(atPath: r.appendingPathComponent("private/var/\(mobile ? "root" : "mobile")/Media").path))
        #expect(done.apps == ["Applications/Edit.app"])
        #expect(done.owners[501, default: []].contains("private/var/mobile/Media/notes.txt") == mobile)
        #expect(done.owners[0, default: []].contains("Applications/Edit.app/Edit"))
        #expect(
            done.lines.contains(
                "postflight /bin/launchctl load /Library/LaunchDaemons/com.example.d.plist: at the next boot"))
        let order = NSDictionary(contentsOf: r.appendingPathComponent(SystemEdits.displayOrder))
        let icons = (order?["iconList"] as? [[String: String]])?.compactMap { $0["displayIdentifier"] }
        #expect(icons == (mobile ? nil : ["com.apple.Preferences", "com.example.edit.app"]))
        let receipt = try #require(
            NSDictionary(contentsOf: r.appendingPathComponent("Library/PXL/DB/com.example.edit.plist")))
        let files = (receipt["RDPxlPackageInstalledFiles"] as? [[String: Any]])?.compactMap { $0["file"] as? String }
        #expect(files?.contains("/Applications/Edit.app/Edit") == true)
        #expect(files?.contains("/Applications/Edit.app") == true, "the folder it made")
        #expect(receipt["RDPxlPackagePostflight"] != nil && receipt["RDPxlPackageVersion"] as? String == "0.2")
    }

    @Test func overwriteFalseKeepsWhatIsThere() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-pkg1x-keep-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let r = try root(dir.appendingPathComponent("root"), mobile: false)
        try JailbreakTests.put(Data("mine".utf8), r, "Library/LaunchDaemons/com.example.d.plist")
        _ = try Package1x.load(pxl(dir)).install(MountedVolume(root: r))
        #expect(
            try Data(contentsOf: r.appendingPathComponent("Library/LaunchDaemons/com.example.d.plist"))
                == Data("mine".utf8))
    }

    @Test func anInstallerZipAndAnAppFolderGoToApplications() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-pkg1x-app-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let r = try root(dir.appendingPathComponent("root"), mobile: true)
        let members: [(String, Data?, UInt16)] = [
            ("Respring.app/Info.plist", try Self.plist(["CFBundleIdentifier": "com.example.respring"]), 0o644),
            ("Respring.app/Respring", Self.machO(subtype: 6), 0o755),
            ("__MACOSX/Respring.app/._Respring", Data("apple double".utf8), 0o644)
        ]
        let zipped = try Package1x.load(zip(dir, "respring.zip", members))
        #expect(zipped.identifier == "com.example.respring")
        #expect(try zipped.install(MountedVolume(root: r)).apps == ["Applications/Respring.app"])
        #expect(try mode(r.appendingPathComponent("Applications/Respring.app/Respring")) == 0o755)
        let folder = dir.appendingPathComponent("Respring.app")
        try fm.copyItem(at: r.appendingPathComponent("Applications/Respring.app"), to: folder)
        #expect(
            try Package1x.load(folder).placements.map(\.path).sorted() == [
                "/Applications/Respring.app", "/Applications/Respring.app/Info.plist",
                "/Applications/Respring.app/Respring"
            ])
    }

    /// Each refused, before or while it installs, with nothing written outside the volume.
    @Test(arguments: [
        "member ..", "member absolute", "source ..", "destination ..", "destination /dev", "link absolute",
        "link out", "postflight", "armv7", "through a link out of the roots", "through a link out of the volume",
        "postflight out", "not a package"
    ])
    func aPackageIsRefused(_ why: String) throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-pkg1x-bad-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let r = try root(dir.appendingPathComponent("volume/root"), mobile: false)
        let app: [[String: Any]] = [["source": "app", "destination": "/Applications/Edit.app"]]
        let url: URL =
            switch why {
            case "member ..": try pxl(dir, members: [("app/../../../escape", Data("x".utf8), 0o644)])
            case "member absolute": try pxl(dir, members: [("/tmp/escape", Data("x".utf8), 0o644)])
            case "source ..": try pxl(dir, files: [["source": "../app", "destination": "/Applications/x"]])
            case "destination ..": try pxl(dir, files: [["source": "app", "destination": "/Applications/../../escape"]])
            case "destination /dev": try pxl(dir, files: [["source": "notes.txt", "destination": "/dev/notes"]])
            case "link absolute": try pxl(dir, members: [("app/passwd", Data("->/etc/passwd".utf8), 0o755)])
            case "link out": try pxl(dir, members: [("app/up", Data("->../../../..".utf8), 0o755)])
            case "postflight": try pxl(dir, files: app, postflight: [["/usr/bin/dropbearkey", "-t", "rsa"]])
            case "armv7": try pxl(dir, members: [("app/Edit7", Self.machO(subtype: 9), 0o755)])
            case "through a link out of the roots":
                try pxl(dir, files: [["source": "notes.txt", "destination": "/Applications/dev/notes"]])
            case "through a link out of the volume":
                try pxl(dir, files: [["source": "notes.txt", "destination": "/Applications/up/escape"]])
            case "postflight out":
                try pxl(dir, files: app, postflight: [["/bin/cp", "/Applications/Edit.app/Edit", "/dev/x"]])
            default: try zip(dir, "themes.zip", [("Black Wood/Dock.png", Data("png".utf8), 0o644)])
            }
        let said: [String: String] = [
            "member ..": "is outside the package", "member absolute": "is outside the package",
            "source ..": "is outside the package", "destination ..": "without . or ..",
            "destination /dev": "outside the folders", "link absolute": "links outside the package",
            "link out": "links outside the package", "postflight": "a stopped device can't run",
            "armv7": "no armv6 code", "through a link out of the roots": "outside the folders",
            "through a link out of the volume": "links outside the volume", "postflight out": "outside the folders",
            "not a package": "neither a PXL"
        ]
        let error = #expect(throws: FirmwareError.self, "\(why)") {
            try Package1x.load(url).install(MountedVolume(root: r))
        }
        #expect(error?.message.contains(said[why]!) == true, "\(why): \(error?.message ?? "")")
        let outside = try fm.contentsOfDirectory(atPath: dir.appendingPathComponent("volume").path)
        #expect(outside == ["root"], "nothing beside the volume")
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("escape").path))
    }

    @Test func armSubtypes() {
        #expect(Package1x.armSubtypes(Self.machO(subtype: 6)) == [6])
        #expect(Package1x.armSubtypes(Data("text".utf8)) == nil)
        var fat = Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2])
        for (cpu, sub) in [(12, 9), (12, 6)] as [(UInt32, UInt32)] {
            for v in [cpu, sub, 0, 0, 0] { fat += withUnsafeBytes(of: v.bigEndian) { Data($0) } }
        }
        #expect(Package1x.armSubtypes(fat) == [9, 6])
        #expect(Package1x.armSubtypes(Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 0x32])) == nil, "a Java class")
    }

    /// LTM_PACKAGE_ARCHIVE=DIR: every package in DIR loaded (read only), the accepted and refused counted.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LTM_PACKAGE_ARCHIVE"] != nil))
    func archiveCoverage() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LTM_PACKAGE_ARCHIVE"]!)
        var accepted = 0
        var refused: [String: Int] = [:]
        let names = try fm.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") }.sorted()
        for name in names {
            do {
                _ = try Package1x.load(dir.appendingPathComponent(name))
                accepted += 1
            } catch {
                let why = "\(error)".replacingOccurrences(
                    of: #"[^ ]*(\.app|/)[^ ]*"#, with: "…", options: .regularExpression)
                refused[String(why.prefix(90)), default: 0] += 1
                print("refused \(name): \(error)")
            }
        }
        print("coverage \(dir.lastPathComponent): \(accepted)/\(names.count) accepted")
        for (why, n) in refused.sorted(by: { $0.value > $1.value }) { print("  \(n) \(why)") }
    }
}
