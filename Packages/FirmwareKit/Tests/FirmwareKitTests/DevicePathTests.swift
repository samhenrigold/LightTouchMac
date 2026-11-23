import Foundation
import SQLite3
import Testing

@testable import FirmwareKit

/// Files on a device's volume are opened without following links (DevicePath): a link the device planted where an
/// edit reads or writes, absolute or relative, on the file or on a folder above it, dangling or a hard link, leaves
/// everything outside the volume as it was.
struct DevicePathTests {
    enum Link: String, CaseIterable, CustomTestStringConvertible {
        case absolute, relative, parent, dangling, hard
        var testDescription: String { rawValue }
    }

    /// A volume and, beside it, what a planted link would lead to: a file, a folder and a name that isn't there.
    struct Volume {
        let base: URL, root: URL, outside: URL
        var canary: URL { outside.appendingPathComponent("canary") }
        var folder: URL { outside.appendingPathComponent("folder") }
        var missing: URL { outside.appendingPathComponent("missing") }
        let fm = FileManager.default

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-nofollow-\(UUID().uuidString)")
            root = base.appendingPathComponent("volume")
            outside = base.appendingPathComponent("outside")
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("host".utf8).write(to: canary)
            #expect(chmod(canary.path, 0o600) == 0)
        }

        /// `rel` made the planted `link` (its folders made first); false when the kind can't be planted there (a
        /// folder link above a file at the root).
        @discardableResult
        func plant(_ link: Link, at rel: String) throws -> Bool {
            let u = root.appendingPathComponent(rel)
            let up = rel.split(separator: "/").count - 1
            if link == .parent {
                guard up > 0 else { return false }
                let dir = u.deletingLastPathComponent()
                try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
                TemporaryTrees.remove(dir)
                try fm.createSymbolicLink(atPath: dir.path, withDestinationPath: folder.path)
                return true
            }
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            TemporaryTrees.remove(u)
            switch link {
            case .absolute: try fm.createSymbolicLink(atPath: u.path, withDestinationPath: canary.path)
            case .relative:
                try fm.createSymbolicLink(
                    atPath: u.path,
                    withDestinationPath: String(repeating: "../", count: up + 1) + "outside/canary"
                )
            case .dangling: try fm.createSymbolicLink(atPath: u.path, withDestinationPath: missing.path)
            case .hard: #expect(Darwin.link(canary.path, u.path) == 0)
            case .parent: break
            }
            return true
        }

        /// Nothing outside the volume changed: the file's bytes and mode, an empty folder, no new name.
        func expectUntouched(_ what: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            #expect(try Data(contentsOf: canary) == Data("host".utf8), "\(what)", sourceLocation: sourceLocation)
            #expect(
                try fm.attributesOfItem(atPath: canary.path)[.posixPermissions] as? Int == 0o600,
                "\(what)",
                sourceLocation: sourceLocation
            )
            #expect(try fm.contentsOfDirectory(atPath: folder.path).isEmpty, "\(what)", sourceLocation: sourceLocation)
            #expect(!fm.fileExists(atPath: missing.path), "\(what)", sourceLocation: sourceLocation)
        }

        /// The name at `rel` is now a file of the volume's own (the edit replaced the link, not wrote through it).
        func expectOwnFile(_ rel: String, sourceLocation: SourceLocation = #_sourceLocation) {
            var st = stat()
            #expect(lstat(root.appendingPathComponent(rel).path, &st) == 0, sourceLocation: sourceLocation)
            #expect(st.st_mode & S_IFMT == S_IFREG && st.st_nlink == 1, "\(rel)", sourceLocation: sourceLocation)
        }
    }

    static let plist = try! PropertyListSerialization.data(fromPropertyList: ["k": 1], format: .xml, options: 0)

    /// The write sinks: put (SystemEdits.put: /.cydia_no_stash, fstab, the helpers), seedPlist (SpringBoard's and
    /// 1.x's preferences, data_ark.plist), rewritePlist (launchd jobs, Lockdown's Services.plist), mkdirs, remove.
    /// A link on the file is replaced, so the edit completes; one on a folder above it stops the edit.
    @Test(arguments: Link.allCases) func writesNeverLeaveTheVolume(link: Link) throws {
        let v = try Volume()
        defer { try? v.fm.removeItem(at: v.base) }
        let sinks: [(String, String, (URL) throws -> Void)] = [
            ("put", "private/etc/fstab", { try SystemEdits.put(Data("edit".utf8), $0, mode: 0o644) }),
            ("put at the root", ".cydia_no_stash", { try SystemEdits.put(Data(), $0, mode: 0o644) }),
            (
                "seedPlist", "private/var/mobile/Library/Preferences/a.plist",
                { try SystemEdits.seedPlist($0) { $0["x"] = 1 } }
            ),
            (
                "rewritePlist", "System/Library/Lockdown/Services.plist",
                { try SystemEdits.rewritePlist($0) { $0["x"] = 1 } }
            ),
            ("data_ark", "root/Library/Lockdown/data_ark.plist", { try DevicePath.write(Self.plist, $0, mode: 0o600) })
        ]
        for (name, rel, sink) in sinks where try v.plant(link, at: rel) {
            let completed = (try? sink(v.root.appendingPathComponent(rel))) != nil
            try v.expectUntouched("\(name) through a \(link) link")
            switch link {
            case .parent: #expect(!completed, "\(name): a link above the file stops the edit")
            case .absolute, .relative, .dangling:
                // rewritePlist must read the file first, and a link is never read
                #expect(completed == (name != "rewritePlist"), "\(name)")
                if completed { v.expectOwnFile(rel) }
            case .hard: if completed { v.expectOwnFile(rel) }
            }
        }
        // mkdirs through a folder link, or onto a link (or a file) where a folder goes
        try v.plant(link, at: link == .parent ? "usr/local/bin/x" : "usr/local/bin")
        #expect(throws: FirmwareError.self) {
            try SystemEdits.mkdirs(v.root.appendingPathComponent("usr/local/bin/new"))
        }
        try v.expectUntouched("mkdirs through a \(link) link")
        // remove: a link above stops it; a link itself is removed, not what it leads to
        try v.plant(link, at: "Library/MobileSubstrate/DynamicLibraries/patcyh.dylib")
        try DevicePath.remove(v.root.appendingPathComponent("Library/MobileSubstrate"))
        #expect(!v.fm.fileExists(atPath: v.root.appendingPathComponent("Library/MobileSubstrate").path))
        try v.plant(link, at: "private/var/root/Library/Preferences/SystemConfiguration/x")
        try? DevicePath.remove(
            v.root.appendingPathComponent("private/var/root/Library/Preferences/SystemConfiguration")
        )
        try? DevicePath.remove(
            v.root.appendingPathComponent("private/var/root/Library/Preferences/SystemConfiguration/x")
        )
        try v.expectUntouched("remove through a \(link) link")
    }

    /// The read sinks (DevicePath.read and .dictionary: afcd, SystemVersion.plist, SpringBoard's job, the 1.x Wi-Fi
    /// plist) see nothing through a link; a hard link stays on its own volume on a device, so it reads.
    @Test(arguments: Link.allCases) func readsRefuseLinks(link: Link) throws {
        let v = try Volume()
        defer { try? v.fm.removeItem(at: v.base) }
        try Self.plist.write(to: v.canary)
        let rel = "System/Library/LaunchDaemons/com.apple.SpringBoard.plist"
        try v.plant(link, at: rel)
        let u = v.root.appendingPathComponent(rel)
        if link == .hard {
            #expect(try DevicePath.read(u) == Self.plist)
        } else {
            #expect(throws: FirmwareError.self) { try DevicePath.read(u) }
            #expect(DevicePath.dictionary(u) == nil)
            #expect(
                N45Board.springBoardUser(MountedVolume(root: v.root)).uid == 0,
                "the job isn't read: root's, as with none"
            )
        }
        #expect(try Data(contentsOf: v.canary) == Self.plist)
        #expect(!v.fm.fileExists(atPath: v.missing.path))
    }

    /// The jailbreak's own sinks (installCydia): /.cydia_no_stash, SpringBoard's preferences and dpkg's status and
    /// available, each a planted link; tar keeps a link that is there (-k) and extracts nothing through one.
    @Test(arguments: Link.allCases) func jailbreakLeavesWhatLinksLeadToAlone(link: Link) throws {
        let v = try Volume()
        defer { try? v.fm.removeItem(at: v.base) }
        let cydia = CydiaInstallTests()
        let bootstrap = try cydia.bootstrap(in: v.base.appendingPathComponent("bootstrap"))
        let m = try cydia.firmware(in: v.base.appendingPathComponent("firmware"), prefs: nil, version: "4.2.1")
        try v.fm.removeItem(at: v.root)
        try v.fm.moveItem(at: m, to: v.root)
        for rel in [
            SystemEdits.Cydia.noStash, SystemEdits.Cydia.springBoardPrefs, "private/var/lib/dpkg/status",
            "private/var/lib/dpkg/available"
        ] {
            try v.plant(link, at: rel)
        }
        let completed = (try? SystemEdits.installCydia(MountedVolume(root: v.root), bootstrap: bootstrap)) != nil
        try v.expectUntouched("installCydia with \(link) links")
        // a hard link reads (on a device it can only be to a file of the same volume; here the host's isn't a plist)
        if link != .parent && link != .hard {
            #expect(completed)
            v.expectOwnFile(SystemEdits.Cydia.noStash)
            v.expectOwnFile(SystemEdits.Cydia.springBoardPrefs)
        }
    }

    /// TrustStore1x.addAnchor with a trust store outside the volume where a planted link leads: never written.
    @Test(arguments: Link.allCases) func trustStoreThroughALink(link: Link) throws {
        let v = try Volume()
        defer { try? v.fm.removeItem(at: v.base) }
        var db: OpaquePointer?
        try v.fm.removeItem(at: v.canary)
        #expect(sqlite3_open(v.canary.path, &db) == SQLITE_OK)
        #expect(
            sqlite3_exec(db, "CREATE TABLE tsettings(sha1 BLOB, subj BLOB, tset BLOB, data BLOB);", nil, nil, nil) == 0
        )
        sqlite3_close(db)
        let store = try Data(contentsOf: v.canary)
        try v.plant(link, at: TrustStore1x.path)
        _ = try? TrustStore1x.addAnchor(
            TrustStore1xTests.certificate,
            to: v.root.appendingPathComponent(TrustStore1x.path)
        )
        #expect(try Data(contentsOf: v.canary) == store, "the store a \(link) link leads to is not written")
        #expect(try v.fm.contentsOfDirectory(atPath: v.folder.path).isEmpty)
        #expect(!v.fm.fileExists(atPath: v.missing.path))
    }

    /// 1.x's SystemConfiguration step (N45Board.seedSystemConfiguration, as N45Migration runs it) with the Wi-Fi and
    /// preferences plists planted.
    @Test(arguments: Link.allCases) func systemConfigurationThroughALink(link: Link) throws {
        let v = try Volume()
        defer { try? v.fm.removeItem(at: v.base) }
        let sc = N45Board.scPrefs(MountedVolume(root: v.root))
        for rel in [sc + "/com.apple.wifi.plist", sc + "/preferences.plist"] { try v.plant(link, at: rel) }
        let completed = (try? N45Board.seedSystemConfiguration(MountedVolume(root: v.root))) != nil
        try v.expectUntouched("seedSystemConfiguration through a \(link) link")
        if link != .hard { #expect(completed == (link != .parent)) }
    }

    @Test func pathsAreRefusedWithDotDot() throws {
        let v = try Volume()
        defer { try? v.fm.removeItem(at: v.base) }
        let up = v.root.appendingPathComponent("../outside/canary")
        #expect(throws: FirmwareError.self) { try DevicePath.read(up) }
        #expect(throws: FirmwareError.self) { try DevicePath.write(Data("x".utf8), up) }
        try v.expectUntouched("..")
    }

    /// The files that edit a device's volumes reach it through DevicePath only: a raw file call on a line there must
    /// say it is on a host file (`// host file`) or follows no link (`// no link followed`).
    @Test func deviceVolumeEditsUseDevicePath() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FirmwareKit")
        let files = [
            "SystemEdits/SystemEdits.swift", "SystemEdits/Cydia.swift", "N45/N45Recipe.swift",
            "N45/N45Migration.swift", "N45/Preferences1x.swift", "N45/TrustStore1x.swift",
            "StoppedVolumeEdit/StoppedVolumeEdit+Jailbreak.swift"
        ]
        let raw =
            /contentsOf:|fileExists\(|removeItem\(|createFile\(|createSymbolicLink\(|createDirectory\(|attributesOfItem\(|setAttributes\(|contentsOfDirectory\(|enumerator\(|destinationOfSymbolicLink\(|moveItem\(|copyItem\(|\.write\(to:|sqlite3_open|FileHandle\(|(^|[^\w.])(open|stat|lstat|chmod|mkdir|unlink|rename|truncate|listxattr|getxattr|setxattr|clonefile)\(/
        var found: [String] = []
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains(raw) && !line.contains("// host file") && !line.contains("// no link followed")
                && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            {
                found.append("\(file):\(n + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(found.isEmpty, "raw file calls on a device's volume:\n\(found.joined(separator: "\n"))")
        // and the check sees one
        #expect("let d = NSDictionary(contentsOf: m.appendingPathComponent(job))".contains(raw))
    }
}
