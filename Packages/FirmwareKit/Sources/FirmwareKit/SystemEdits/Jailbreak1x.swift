// The jailbreak on iPhone OS 1.x (firmwarekit create --jailbreak, edit --action jailbreak): file edits only, no
// exploit, as the 2007 jailbreaks left the system volume. 1.x checks no code signature, and the recipe already mounts
// the root read-write (N72Board.fstabRW).
//
//   afc2      com.apple.afc2 in Lockdown/Services.plist: afcd --lockdown -d / (installAFC2), the entry AppTapp's
//             Services.plist adds, so Files browses the whole file system.
//   SpringBoard  1.1 to 1.1.2 list only the apps a compiled-in allowlist names; the check is turned off
//             (SpringBoardAllowlist). 1.0 lists every app (those DisplayOrder.plist doesn't name after those it
//             does) and 1.1.3 on hide only their disallowedDisplayIdentifiers: neither is patched.
//   Installer.app  Nullriver's AppTapp Installer 2.63, the 1.x jailbreaks' package manager, from the guest archive
//             (build-support/jailbreak, packed by scripts/vendor beside guest-tools; pinned here by SHA-1) to
//             /Applications/Installer.app, its Mach-O files 0755 as AppTapp left them, all root's (1.x runs it as
//             root). 1.0's DisplayOrder.plist gets it at the end of iconList, where AppTapp put it.
//
// No Cydia or Substrate: Cydia's bootstrap needs 2.0.

import Crypto
import Foundation

extension SystemEdits {
    /// The 1.x jailbreak on the mounted system volume `v`, Installer.app from `installer` (InstallerApp.bundled).
    /// Returns the log lines and the paths to make root's.
    static func installJailbreak1x(_ v: any VolumeFiles, installer: URL) throws -> (lines: [String], root: [String]) {
        var lines = [try installAFC2(v).line]
        var root: [String] = []
        let springBoard = N72Board.springBoard
        if let (patched, offset) = try SpringBoardAllowlist.patch([UInt8](v.contents(at: springBoard))) {
            try v.put(Data(patched), at: springBoard, mode: 0o755)
            root.append(springBoard)
            lines.append(
                "SpringBoard: the allowedDisplayIdentifiers check off (file offset 0x\(String(offset, radix: 16)))")
        }
        for (path, data) in try InstallerApp.load(installer) {
            let at = InstallerApp.path + (path.isEmpty ? "" : "/" + path)
            if let data {
                try v.put(data, at: at, mode: MachO32([UInt8](data)) != nil ? 0o755 : 0o644)
            } else {
                try v.makeDirectory(at, mode: 0o755)
            }
            root.append(at)
        }
        lines.append("Installer.app 2.63: /\(InstallerApp.path)")
        if try registerDisplayIdentifier(v, InstallerApp.identifier) {
            lines.append("DisplayOrder.plist: \(InstallerApp.identifier) in iconList")
        }
        return (lines, root)
    }

    static let displayOrder = "System/Library/CoreServices/SpringBoard.app/DisplayOrder.plist"

    /// 1.0 (the only SpringBoard with a DisplayOrder.plist): `identifier` at the end of its iconList, once. True if
    /// added.
    static func registerDisplayIdentifier(_ v: any VolumeFiles, _ identifier: String) throws -> Bool {
        guard v.exists(displayOrder) else { return false }
        var added = false
        try rewritePlist(v, displayOrder) { order in
            let list = order["iconList"] as? NSMutableArray ?? NSMutableArray()
            guard !list.contains(where: { ($0 as? NSDictionary)?["displayIdentifier"] as? String == identifier })
            else { return }
            list.add(NSDictionary(dictionary: ["displayIdentifier": identifier]))
            order["iconList"] = list
            added = true
        }
        return added
    }

    /// AppTapp Installer 2.63 as the guest archive carries it: a zip of Installer.app, checked by its SHA-1.
    enum InstallerApp {
        static let identifier = "com.nullriver.iphone.Installer"
        static let path = "Applications/Installer.app"
        static let zip = (name: "Installer-2.63.zip", sha1: "fc170f683dfacf658ac75aecc7ee19dbd59dadcd")

        /// The zip in the unpacked guest archive whose guest-tools folder is `guestTools`.
        static func bundled(guestTools: URL) throws -> URL {
            let url = guestTools.deletingLastPathComponent().appendingPathComponent("jailbreak/" + zip.name)
            guard FileManager.default.fileExists(atPath: url.path) else {  // host file
                throw FirmwareError(.internal, "Installer.app: no \(url.path) (run scripts/vendor)")
            }
            let got = try Preparer.digest(url, Insecure.SHA1())
            guard got == zip.sha1 else {
                throw FirmwareError(.shaMismatch, "Installer.app: \(zip.name) SHA-1 \(got), not \(zip.sha1)")
            }
            return url
        }

        /// The bundle's files by path inside Installer.app ("" the bundle itself; folders with no data), sorted, each
        /// folder before what it holds. Throws on a member outside the bundle.
        static func load(_ url: URL) throws -> [(String, Data?)] {
            let archive = IPSWArchive(url)
            let prefix = "Installer.app/"
            var files: [String: Data?] = ["": nil]
            for name in try archive.names() where name.hasPrefix(prefix) && name.count > prefix.count {
                let rel = String(name.dropFirst(prefix.count))
                let folder = rel.hasSuffix("/")
                let path = folder ? String(rel.dropLast()) : rel
                guard
                    !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                        $0.isEmpty || $0 == "." || $0 == ".."
                    })
                else { throw FirmwareError(.unsupported, "Installer.app: \(name) is outside the bundle") }
                files[path] = folder ? .some(nil) : try archive.read(name)
            }
            guard files["Info.plist"] != nil else { throw FirmwareError(.unsupported, "Installer.app: no Info.plist") }
            return files.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }
    }
}
