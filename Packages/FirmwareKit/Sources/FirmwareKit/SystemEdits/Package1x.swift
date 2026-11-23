// An iPhone OS 1.x package installed from the Mac into a stopped device (firmwarekit edit --action install-package,
// StoppedVolumeEdit.installPackage1x), as file edits on the system volume (1.x checks no signature):
//
//   PXL      a zip with PxlPkg.plist (Ripdev's format): each of RDPxlPackageFiles copies its source, a folder's
//            contents or a file, to its destination, as pxldaemon 4.0's installPackageFile does (overwrite false
//            keeps a file that is there, executable sets 0755 or 0664).
//   Foo.app  a zip whose one top-level item is Foo.app (the Installer-era archives), or the folder itself: to
//            /Applications/Foo.app.
//   root     a zip whose top-level folders are all the root's (Applications, usr, …): at /.
//   themes   a zip of SummerBoard themes and wallpapers (themePlacements): where SummerBoard looks.
//
// Each may also be a .tgz, a .tar or a RAR, and a folder holding only Foo.app is Foo.app.
//
// The package is untrusted. A member is refused outside the package (an absolute name, "." or "..", empty), larger
// than `maxMember` (all of it larger than `maxTotal`), or a link that is absolute or climbs out of the package; a
// source or destination with "." or ".."; a destination outside `roots` once the device's own links are followed
// (inside the volume: /var is private/var); a Mach-O with no ARM slice older than armv7 (the s5l8900's ARM11; the
// rule ipa-preflight's AppBinary has for an IPA). Nothing in it runs. Its postflight, pxldaemon's argv list (which
// pxldaemon runs last first), is read, not run: launchctl's (load, start, unload, stop) are what the next boot
// does anyway; cp, mv, rm, ln -s and chmod on absolute paths under `roots` are made here as the same file edits;
// anything else (dropbearkey, ssh-keygen, a SpringBoard patcher) refuses the package, since a stopped device can't
// run it and the package would be half installed.
//
// Owners are root's, as 1.x runs everything as root through 1.1.2. From 1.1.3 SpringBoard and the apps run as
// mobile (N45Board.springBoardUser), and a destination in root's home goes to mobile's, mobile's own: the packages
// were written for 1.0 to 1.1.2's /var/root. Every .app put in /Applications is in 1.0's DisplayOrder.plist
// (SystemEdits.registerDisplayIdentifier), and SpringBoard 1.1 to 1.1.2's allowlist is turned off as the jailbreak
// does (SpringBoardAllowlist), so its icon is on Home. What was installed is kept where pxldaemon keeps it,
// /Library/PXL/DB/<identifier>.plist (RDPxlPackageInstalledFiles, each file it wrote over marked replaced, and the
// package's Postflight and Preremove), which Package1x.uninstall follows.

import Foundation
import Unrar
import ZIPFoundation

public struct Package1x {
    public enum Item: Equatable {
        case file(Data, mode: UInt16)
        case folder
        case link(String)
    }
    /// What goes where: `path` device-absolute, as the package names it.
    struct Placement {
        var path: String
        var item: Item
        var overwrite = true
        var permanent = false
    }

    public let identifier: String
    public let name: String
    let info: [String: Any]
    var placements: [Placement]
    /// In the order pxldaemon runs them.
    var postflight: [[String]]
    /// What is installed as it is but won't work.
    public var warnings: [String]

    static let maxMember = 64 << 20
    static let maxTotal = 512 << 20
    /// The root's folders a package may write under (/etc, /var and /tmp are links into private).
    static let roots: Set<String> = ["Applications", "Library", "System", "bin", "sbin", "usr", "opt", "private"]
    static let rootTops = roots.union(["etc", "var", "tmp"])
    static let satisfiedByBoot: Set<String> = ["launchctl"]
    static let fileCommands: Set<String> = ["cp", "mv", "rm", "ln", "chmod"]

    /// The package at `url` (.pxl, .zip or a .app folder), validated; throws FirmwareError(.unsupported) saying why
    /// it is refused.
    public static func load(_ url: URL) throws -> Package1x {
        var members = try Self.members(url)
        var tops = Set(members.keys.map { String($0.split(separator: "/")[0]) })
        // a folder holding only Foo.app (anySIM-1.1p/anySIM.app): Foo.app
        if tops.count == 1, let top = tops.first, !top.hasSuffix(".app"), members[top] == .folder,
            case let inner = Set(members.keys.filter { $0.hasPrefix(top + "/") }.map { $0.split(separator: "/")[1] }),
            inner.count == 1, let app = inner.first, app.hasSuffix(".app")
        {
            members = Dictionary(
                uniqueKeysWithValues: members.filter { $0.key != top }.map {
                    (String($0.key.dropFirst(top.count + 1)), $0.value)
                })
            tops = [String(app)]
        }
        var info: [String: Any] = [:]
        var placements: [Placement]
        var postflight: [[String]] = []
        var notes: [String] = []
        if case .file(let data, _) = members["PxlPkg.plist"] {
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { throw refused("PxlPkg.plist isn't a property list") }
            info = plist
            placements = []
            for entry in plist["RDPxlPackageFiles"] as? [[String: Any]] ?? [] {
                guard let source = entry["source"] as? String, let destination = entry["destination"] as? String
                else { throw refused("a file entry without its source or destination") }
                let src = try relative(source)
                let dest = "/" + (try absolute(destination)).joined(separator: "/")
                var place = Placement(path: dest, item: .folder)
                place.overwrite = entry["overwrite"] as? Bool ?? true
                place.permanent = entry["permanent"] as? Bool ?? false
                if let item = members[src], item != .folder {  // a file to its destination
                    place.item = item
                    if case .file(let data, _) = item, let executable = entry["executable"] as? Bool {
                        place.item = .file(data, mode: executable ? 0o755 : 0o664)
                    }
                    placements.append(place)
                    continue
                }
                let under = members.keys.filter { $0.hasPrefix(src + "/") }.sorted()
                guard members[src] != nil || !under.isEmpty else { throw refused("no \(source) in the package") }
                placements.append(place)
                for key in under {
                    place.item = members[key]!
                    place.path = (dest == "/" ? "" : dest) + "/" + key.dropFirst(src.count + 1)
                    placements.append(place)
                }
            }
            guard !placements.isEmpty else { throw refused("PxlPkg.plist installs nothing") }
            postflight = commands(plist["RDPxlPackagePostflight"])
            try checkCommands(postflight, "postflight")
        } else if tops.count == 1, let app = tops.first, app.hasSuffix(".app") {
            placements = members.keys.sorted().map { Placement(path: "/Applications/" + $0, item: members[$0]!) }
        } else if case let folders = tops.filter({ members[$0] == .folder }), !folders.isEmpty,
            folders.isSubset(of: rootTops)
        {
            // a loose file beside the root's folders (aSMS's readme) has nowhere to go
            let loose = tops.subtracting(folders)
            placements = members.keys.sorted().filter { !loose.contains($0) }.map {
                Placement(path: "/" + $0, item: members[$0]!)
            }
            notes = loose.sorted().map { "\($0) left out: a file beside the root's folders" }
        } else if let themes = themePlacements(members, tops) {
            placements = themes
        } else {
            throw refused(
                "neither a PXL, one .app nor a root tree (its top: \(tops.sorted().prefix(4).joined(separator: ", ")))")
        }
        var warnings = notes
        for (path, item) in members.sorted(by: { $0.key < $1.key }) {
            guard case .file(let data, _) = item, let subtypes = armSubtypes(data) else { continue }
            if subtypes.isEmpty {  // BSDSubsystem 1.5's i386 nice: a mistake that can't run there either
                warnings.append("\(path) has no ARM code: it won't run")
            } else if !subtypes.contains(where: { $0 < 9 }) {
                throw refused("\(path) has no armv6 code (the iPhone 2G and iPod touch run armv6)")
            }
        }
        // the identifier: the PXL's, else the app's Info.plist's, else the file's name
        let appInfo = tops.count == 1 && tops.first!.hasSuffix(".app") ? members[tops.first! + "/Info.plist"] : nil
        if case .file(let data, _) = appInfo {
            info = (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]) ?? [:]
        }
        let identifier = info["CFBundleIdentifier"] as? String ?? url.deletingPathExtension().lastPathComponent
        guard !identifier.isEmpty, !identifier.contains("/"), identifier != ".", identifier != ".." else {
            throw refused("its identifier \(identifier) can't name a file")
        }
        let name = info["RDPxlPackageName"] as? String ?? info["CFBundleName"] as? String ?? identifier
        return Package1x(
            identifier: identifier, name: name, info: info, placements: placements, postflight: postflight,
            warnings: warnings)
    }

    static let summerBoardThemes = "/var/root/Library/SummerBoard/Themes/"
    static let wallpapers = "/var/root/Library/Wallpaper/"

    /// An Installer-era zip of SummerBoard themes and wallpapers, placed where SummerBoard's PXL themes and
    /// OSXWallpaperPack put them: each top folder a theme (Dock.png, Wallpaper.png, StatusBar.png or Icons/ in it),
    /// or Themes/ holding themes, to SummerBoard's Themes; Wallpaper/'s files to root's Library/Wallpaper. Nil for
    /// anything else (an icon pack, ThemeBuilder's image pack), whose place isn't clear.
    static func themePlacements(_ members: [String: Item], _ tops: Set<String>) -> [Placement]? {
        func isTheme(_ folder: String) -> Bool {
            members[folder] == .folder
                && (["Dock.png", "Wallpaper.png", "StatusBar.png"].contains { members[folder + "/" + $0] != nil }
                    || members[folder + "/Icons"] == .folder)
        }
        func under(_ folder: String) -> [String] { members.keys.filter { $0.hasPrefix(folder + "/") }.sorted() }
        var out: [Placement] = []
        for top in tops.sorted() {
            if top == "Wallpaper", members[top] == .folder,
                under(top).allSatisfy({ !$0.dropFirst(10).contains("/") && members[$0] != .folder })
            {
                out += under(top).map { Placement(path: wallpapers + $0.dropFirst(10), item: members[$0]!) }
            } else if top == "Themes", members[top] == .folder,
                case let names = Set(under(top).map { String($0.split(separator: "/")[1]) }),
                !names.isEmpty, names.allSatisfy({ isTheme("Themes/" + $0) })
            {
                out += under(top).map { Placement(path: summerBoardThemes + $0.dropFirst(7), item: members[$0]!) }
            } else if isTheme(top) {
                out += ([top] + under(top)).map { Placement(path: summerBoardThemes + $0, item: members[$0]!) }
            } else {
                return nil
            }
        }
        return out.isEmpty ? nil : out
    }

    static func refused(_ why: String) -> FirmwareError { FirmwareError(.unsupported, "the package: \(why)") }

    /// `path`'s components, relative to the package: none empty, "." or "..".
    static func relative(_ path: String) throws -> String {
        var p = Substring(path)
        while p.hasSuffix("/") { p = p.dropLast() }
        guard !p.hasPrefix("/"), !p.isEmpty,
            !p.split(separator: "/", omittingEmptySubsequences: false).contains(where: { [".", "..", ""].contains($0) })
        else { throw refused("\(path) is outside the package") }
        return String(p)
    }

    /// An absolute device path's components (repeated and trailing slashes dropped), none "." or "..".
    static func absolute(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), !parts.contains(where: { $0 == "." || $0 == ".." }) else {
            throw refused("\(path) isn't an absolute path without . or ..")
        }
        return parts
    }

    /// Whether a link at `path` (relative, in the package or on the volume) to `target` stays below the top of
    /// where it is: relative, and never climbing above it.
    static func staysInside(_ path: String, _ target: String) -> Bool {
        guard !target.hasPrefix("/"), !target.isEmpty else { return false }
        var depth = path.split(separator: "/").count - 1
        for c in target.split(separator: "/") {
            if c == ".." { depth -= 1 } else if c != "." { depth += 1 }
            if depth < 0 { return false }
        }
        return true
    }

    /// The package's items by relative path (folders implied by a member's path included), validated.
    static func members(_ url: URL) throws -> [String: Item] {
        var out: [String: Item] = [:]
        var total = 0
        func add(_ name: String, _ item: Item) throws {
            let path = try relative(name)
            let last = (path as NSString).lastPathComponent
            if path.hasPrefix("__MACOSX") || last.hasPrefix("._") || last == ".DS_Store" { return }
            if case .link(let target) = item, !staysInside(path, target) {
                throw refused("\(path) links outside the package (\(target))")
            }
            if case .file(let data, _) = item {
                total += data.count
                guard data.count <= maxMember, total <= maxTotal else { throw refused("\(path) is too large") }
            }
            out[path] = item
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty, out[parent] == nil {
                out[parent] = .folder
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        var folder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &folder), folder.boolValue {  // host file
            guard url.pathExtension == "app" else { throw refused("a folder that isn't an .app") }
            let top = url.lastPathComponent
            try add(top, .folder)
            for rel in FileManager.default.subpaths(atPath: url.path) ?? [] {  // host files, links not followed
                let file = url.appendingPathComponent(rel)
                let name = top + "/" + rel
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                switch attributes[.type] as? FileAttributeType {
                case .typeSymbolicLink?:
                    try add(name, .link(try FileManager.default.destinationOfSymbolicLink(atPath: file.path)))
                case .typeDirectory?: try add(name, .folder)
                default:
                    guard (attributes[.size] as? Int ?? 0) <= maxMember else { throw refused("\(name) is too large") }
                    let mode = UInt16(attributes[.posixPermissions] as? Int ?? 0o644) & 0o7777
                    try add(name, .file(try Data(contentsOf: file), mode: mode))
                }
            }
            return out
        }
        let head = (try? FileHandle(forReadingFrom: url).read(upToCount: 512)) ?? Data()
        if head.starts(with: Array("Rar!".utf8)) {
            // RAR keeps no modes or links: files, 0644 (a Mach-O is made 0755 as it installs)
            let rar: Unrar.Archive
            let entries: [Unrar.Entry]
            do {
                rar = try Unrar.Archive(fileURL: url)
                entries = try rar.entries()
            } catch { throw refused("\(url.lastPathComponent) isn't a readable RAR archive (\(error))") }
            for entry in entries {
                let name = entry.fileName.replacingOccurrences(of: "\\", with: "/")
                guard !entry.encrypted else { throw refused("\(name) is encrypted") }
                guard entry.uncompressedSize <= maxMember else { throw refused("\(name) is too large") }
                if entry.directory {
                    try add(name, .folder)
                    continue
                }
                var data = Data()
                do {
                    try rar.extract(entry) { chunk, progress in
                        data.append(chunk)
                        if data.count > maxMember { progress.cancel() }
                    }
                } catch { throw refused("\(name) can't be read (\(error))") }
                guard data.count <= maxMember else { throw refused("\(name) is too large") }
                try add(name, .file(data, mode: 0o644))
            }
            return out
        }
        // a tar (.tgz, .tar.gz, .tar): ustar's magic at 257 once inflated
        if head.starts(with: [0x1F, 0x8B]) || head.count > 262 && head[257..<262] == Data("ustar".utf8) {
            let tar: TarArchive
            do { tar = try TarArchive(Data(contentsOf: url), limit: maxTotal) } catch let e as FirmwareError {
                throw refused("\(url.lastPathComponent): \(e.message)")
            }
            var files: [String: Data] = [:]
            // TarArchive drops a leading / or ./ from each name, as tar does when it extracts
            for m in tar.members where !m.path.isEmpty {
                switch m.kind {
                case .directory: try add(m.path, .folder)
                case .file:
                    files[m.path] = m.data
                    try add(m.path, .file(m.data, mode: m.mode))
                case .symlink: try add(m.path, .link(m.link))
                case .hardLink:  // a copy of the file it names, as Package1x has no hard links
                    guard let data = files[m.link] else { throw refused("\(m.path) links to \(m.link), not before it") }
                    try add(m.path, .file(data, mode: m.mode))
                }
            }
            return out
        }
        let archive: ZIPFoundation.Archive
        do { archive = try ZIPFoundation.Archive(url: url, accessMode: .read) } catch {
            throw refused("\(url.lastPathComponent) isn't a zip, a tar or a RAR archive")
        }
        for entry in archive {
            guard entry.uncompressedSize <= maxMember else { throw refused("\(entry.path) is too large") }
            if entry.type == .directory {
                try add(entry.path, .folder)
                continue
            }
            var data = Data()
            do {
                _ = try archive.extract(entry, skipCRC32: false) { chunk in
                    data.append(chunk)
                    guard data.count <= maxMember else { throw refused("\(entry.path) is too large") }
                }
            } catch let e as ZIPFoundation.Archive.ArchiveError { throw refused("\(entry.path) can't be read (\(e))") }
            if entry.type == .symlink {
                try add(entry.path, .link(String(decoding: data, as: UTF8.self)))
            } else {
                let mode = (entry.fileAttributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
                try add(entry.path, .file(data, mode: mode & 0o7777))
            }
        }
        return out
    }

    /// The ARM cpusubtypes of a Mach-O (thin or fat; [] when it has no ARM slice), or nil when `data` isn't one.
    static func armSubtypes(_ data: Data) -> [UInt32]? {
        let b = [UInt8](data.prefix(4096))
        func le(_ o: Int) -> UInt32 {
            o + 4 <= b.count ? (0..<4).reduce(0) { $0 | UInt32(b[o + $1]) << (8 * $1) } : 0
        }
        func be(_ o: Int) -> UInt32 { le(o).byteSwapped }
        switch le(0) {
        case 0xFEED_FACE, 0xFEED_FACF: return le(4) == 12 ? [le(8) & 0x00FF_FFFF] : []
        case 0xBEBA_FECA:  // fat, big-endian; a Java class shares the magic, with a version where the count is
            let count = Int(be(4))
            guard (1..<20).contains(count) else { return nil }
            return (0..<count).compactMap { k in be(8 + 20 * k) == 12 ? be(12 + 20 * k) & 0x00FF_FFFF : nil }
        default: return nil
        }
    }
}

extension Package1x {
    /// What `install` did: log lines, the volume paths written by owner uid, and the apps put in /Applications.
    struct Installed {
        var lines: [String] = []
        var owners: [UInt32: [String]] = [:]
        var apps: [String] = []
        var receipt: [[String: Any]] = []
    }

    /// The package onto the mounted 1.x system volume `v`.
    func install(_ v: any VolumeFiles) throws -> Installed {
        var done = Installed()
        let place = Self.placer(v)
        /// `replaced`: the path was there before (a file the package overwrote), which an uninstall leaves.
        func record(
            _ path: String, uid: UInt32, folder: Bool = false, permanent: Bool = false, replaced: Bool = false
        ) {
            done.owners[uid, default: []].append(path)
            var entry: [String: Any] = ["file": "/" + path]
            if folder { entry["directory"] = true }
            if permanent { entry["permanent"] = true }
            if replaced { entry["replaced"] = true }
            done.receipt.append(entry)
        }
        /// mkdir -p, each new folder recorded.
        func folder(_ path: String, uid: UInt32, permanent: Bool = false) throws {
            guard !path.isEmpty, !v.isDirectory(path) else { return }
            guard !v.exists(path) else { throw Self.refused("/\(path) is there and isn't a folder") }
            try folder((path as NSString).deletingLastPathComponent, uid: uid)
            try v.makeDirectory(path, mode: 0o755)
            record(path, uid: uid, folder: true, permanent: permanent)
        }
        for p in placements {
            let (path, uid) = try place(p.path, p.item == .folder)
            if p.item == .folder {
                try folder(path, uid: uid, permanent: p.permanent)
                continue
            }
            guard !path.isEmpty, !v.isDirectory(path) else { throw Self.refused("\(p.path) is a folder there") }
            let existed = v.exists(path) || v.isSymlink(path)
            if !p.overwrite, existed { continue }
            try folder((path as NSString).deletingLastPathComponent, uid: uid)
            switch p.item {
            case .file(let data, let mode):
                let machO = Self.armSubtypes(data) != nil
                try v.put(data, at: path, mode: machO ? mode & 0o7000 | 0o755 : mode == 0 ? 0o644 : mode)
            case .link(let target):
                // where it points once the device's links on the way are followed (an earlier member's among
                // them): inside the volume and the folders a package may write, as a file there would be
                var to = path.split(separator: "/").dropLast().map(String.init)
                for c in target.split(separator: "/") where c != "." {
                    guard c == ".." else {
                        to.append(String(c))
                        continue
                    }
                    guard to.popLast() != nil else { throw Self.refused("\(p.path) links outside the volume") }
                }
                let resolved = try Self.resolve(v, to, followLast: true)
                guard let top = resolved.split(separator: "/").first, Self.roots.contains(String(top)) else {
                    throw Self.refused("\(p.path) links outside the folders a package may write (/\(resolved))")
                }
                try v.remove(path)
                try v.makeSymlink(path, to: target)
            case .folder: break
            }
            record(path, uid: uid, permanent: p.permanent, replaced: existed)
        }
        done.lines.append("\(name): \(placements.count) items")
        done.lines += warnings
        for argv in postflight where !argv.isEmpty {
            let (line, written) = try Self.run(argv, v, place: place)
            done.lines.append(line)
            for w in written { record(w.path, uid: w.uid, replaced: w.replaced) }
        }
        // the apps it put in /Applications: on Home
        done.apps = Array(
            Set(
                done.receipt.compactMap { $0["file"] as? String }.compactMap { file -> String? in
                    let c = file.split(separator: "/")
                    return c.count >= 2 && c[0] == "Applications" && c[1].hasSuffix(".app")
                        ? "Applications/\(c[1])" : nil
                }
            )
        ).sorted()
        for app in done.apps {
            guard let id = v.plist(at: app + "/Info.plist")?["CFBundleIdentifier"] as? String else { continue }
            if try SystemEdits.registerDisplayIdentifier(v, id) {
                done.lines.append("DisplayOrder.plist: \(id) in iconList")
            }
        }
        let springBoard = N72Board.springBoard
        // nil without an allowlist (1.0, 1.1.3 on) and once the jailbreak turned it off (no check left to find)
        if !done.apps.isEmpty,
            let (patched, offset) = try? SpringBoardAllowlist.patch([UInt8](v.contents(at: springBoard)))
        {
            try v.put(Data(patched), at: springBoard, mode: 0o755)
            done.owners[0, default: []].append(springBoard)
            done.lines.append(
                "SpringBoard: the allowedDisplayIdentifiers check off (file offset 0x\(String(offset, radix: 16)))")
        }
        var receipt: [String: Any] = [
            "RDPxlPackageFormat": 1, "CFBundleIdentifier": identifier, "RDPxlPackageName": name
        ]
        for key in ["RDPxlPackageVersion", "RDPxlPackageDesc", "RDPxlPackagePostflight", "RDPxlPackagePreremove"] {
            receipt[key] = info[key]
        }
        receipt["RDPxlPackageInstalledFiles"] = done.receipt
        let db = "Library/PXL/DB"
        try folder(db, uid: 0)
        try v.put(
            PropertyListSerialization.data(fromPropertyList: receipt, format: .xml, options: 0),
            at: "\(db)/\(identifier).plist",
            mode: 0o644
        )
        done.owners[0, default: []].append("\(db)/\(identifier).plist")
        done.lines.append("/\(db)/\(identifier).plist")
        done.owners = done.owners.mapValues { Array(Set($0.filter(v.exists))).sorted() }  // the postflight's rm and mv
        return done
    }

    /// The volume path for device path `path` on `v` and its owner (root's home is mobile's from 1.1.3), refused
    /// outside `roots`.
    static func placer(_ v: any VolumeFiles) -> (String, Bool) throws -> (path: String, uid: UInt32) {
        let mobile = N45Board.springBoardUser(v).uid == 501
        return { path, followLast in
            var parts = try absolute(path)
            var uid: UInt32 = 0
            if mobile {
                let home =
                    parts.starts(with: ["private", "var", "root"]) ? 3 : parts.starts(with: ["var", "root"]) ? 2 : 0
                if home > 0 {
                    parts = ["private", "var", "mobile"] + parts.dropFirst(home)
                    uid = 501
                }
            }
            let resolved = try resolve(v, parts, followLast: followLast)
            guard resolved.isEmpty || roots.contains(String(resolved.split(separator: "/")[0])) else {
                throw refused("\(path) is outside the folders a package may write (/\(resolved))")
            }
            return (resolved, uid)
        }
    }

    /// Refuses a postflight or preremove that runs anything but launchctl and the file commands.
    static func checkCommands(_ commands: [[String]], _ what: String) throws {
        for argv in commands where !argv.isEmpty {
            let tool = (argv[0] as NSString).lastPathComponent
            guard satisfiedByBoot.contains(tool) || fileCommands.contains(tool) else {
                throw refused("its \(what) runs \(argv[0]), which a stopped device can't run")
            }
        }
    }

    /// pxldaemon's argv list as it runs them (last first); a dict in an argv is an option (createsFile).
    static func commands(_ list: Any?) -> [[String]] {
        (list as? [Any] ?? []).reversed().map { ($0 as? [Any] ?? []).compactMap { $0 as? String } }
    }

    typealias Written = (path: String, uid: UInt32, replaced: Bool)

    /// One postflight or preremove command (`checkCommands` allowed only these): launchctl's left to the boot, the
    /// file commands made. Returns its log line and the paths it wrote.
    static func run(
        _ argv: [String],
        _ v: any VolumeFiles,
        place: (String, Bool) throws -> (path: String, uid: UInt32)
    ) throws -> (String, [Written]) {
        let tool = (argv[0] as NSString).lastPathComponent
        let flags = argv.dropFirst().filter { $0.hasPrefix("-") }.joined()
        let args = Array(argv.dropFirst().filter { !$0.hasPrefix("-") })
        let said = argv.joined(separator: " ")
        if Self.satisfiedByBoot.contains(tool) {
            return ("postflight \(said): at the next boot", [])
        }
        /// The command's last argument as a destination: into it when it is a folder.
        func target(_ source: String) throws -> (path: String, uid: UInt32) {
            let to = try place(args.last!, false)
            return v.isDirectory(to.path) ? (to.path + "/" + (source as NSString).lastPathComponent, to.uid) : to
        }
        switch tool {
        case "cp", "mv":
            guard args.count == 2 else { throw Self.refused("its postflight \(said) isn't SOURCE DESTINATION") }
            let from = try place(args[0], false).path
            guard v.exists(from) else { return ("postflight \(said): no \(args[0]), as it fails there", []) }
            let to = try target(from)
            guard !v.isDirectory(to.path) else { throw Self.refused("its postflight \(said) would replace a folder") }
            let existed = v.exists(to.path)
            if tool == "mv" {
                if existed { try v.remove(to.path) }  // as mv replaces a file
                try v.rename(from, to: to.path)
            } else if v.isFile(from) {
                let mode = try v.item(at: from)?.mode ?? 0o644
                try v.put(v.contents(at: from), at: to.path, mode: mode & 0o7777)
            } else {
                throw Self.refused("its postflight \(said) copies a folder or link")
            }
            return ("postflight \(said)", [(to.path, to.uid, existed)])
        case "rm":
            for arg in args {
                // pxldaemon passes argv as is (no shell), so rm sees a "*" as a name, which isn't there
                guard !arg.contains("*") else { continue }
                let path = try place(arg, false).path
                guard !path.isEmpty, v.isFile(path) || v.isSymlink(path) || flags.contains("r") || flags.contains("R")
                else { continue }
                try v.remove(path)
            }
        case "ln":
            guard flags.contains("s"), args.count == 2 else { throw Self.refused("its postflight \(said) isn't ln -s") }
            let to = try target(args[0])
            guard Self.staysInside(to.path, args[0]) else { throw Self.refused("its postflight \(said) links outside") }
            guard !v.exists(to.path) else { return ("postflight \(said): there already", []) }  // as ln fails
            try v.makeSymlink(to.path, to: args[0])
            return ("postflight \(said)", [(to.path, to.uid, false)])
        case "chmod":
            guard args.count == 2, let mode = UInt16(args[0], radix: 8), mode <= 0o7777 else {
                throw Self.refused("its postflight \(said) isn't chmod OCTAL PATH")
            }
            let path = try place(args[1], false).path
            if v.exists(path) { try v.setMode(path, mode) }
        default: throw Self.refused("its postflight runs \(argv[0])")
        }
        return ("postflight \(said)", [])
    }

    /// The volume path `parts` names, the volume's own links on the way followed (inside the volume); the last name
    /// too when `followLast`.
    static func resolve(_ v: any VolumeFiles, _ parts: [String], followLast: Bool) throws -> String {
        var done: [String] = []
        var rest = parts[...]
        var hops = 0
        while let name = rest.popFirst() {
            let here = (done + [name]).joined(separator: "/")
            guard rest.isEmpty ? followLast : true, v.isSymlink(here) else {
                done.append(name)
                continue
            }
            hops += 1
            let target = try v.destinationOfSymlink(at: here)
            guard hops < 32 else { throw refused("/\(here): too many links") }
            var base = target.hasPrefix("/") ? [] : done
            for c in target.split(separator: "/") where c != "." {
                guard c == ".." else {
                    base.append(String(c))
                    continue
                }
                guard base.popLast() != nil else { throw refused("/\(here) links outside the volume (\(target))") }
            }
            rest = (base + rest)[...]
            done = []
        }
        return done.joined(separator: "/")
    }
}
