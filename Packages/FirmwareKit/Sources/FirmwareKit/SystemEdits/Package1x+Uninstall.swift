// An iPhone OS 1.x package removed from a stopped device (firmwarekit edit --action uninstall-package), driven by
// the receipt Package1x.install left at /Library/PXL/DB/<identifier>.plist: its RDPxlPackagePreremove made as the
// postflight's file edits are (SummerBoard's moves SpringBoard's launchd job back), then each file it lists removed,
// then each folder it made once empty, its apps out of 1.0's DisplayOrder.plist, and the receipt. Left in place: a
// "permanent" entry (pxldaemon's word for what stays), a "replaced" one (the file was there before the package
// wrote over it), and anything the receipt doesn't name. The receipt is on the device, so each path in it is held
// to what an install may write (Package1x.roots, the device's links followed inside the volume).

import Foundation

extension Package1x {
    static let receipts = "Library/PXL/DB"

    /// An installed package, from its receipt.
    public struct Receipt: Codable, Equatable, Sendable {
        public let identifier: String
        public let name: String
        public let version: String?
    }

    /// The receipts under /Library/PXL/DB on `v`, sorted by name.
    static func installed(_ v: any VolumeFiles) -> [Receipt] {
        guard v.isDirectory(receipts), let names = try? v.contentsOfDirectory(at: receipts) else { return [] }
        return names.filter { $0.hasSuffix(".plist") }.compactMap { file -> Receipt? in
            guard let plist = v.plist(at: "\(receipts)/\(file)") else { return nil }
            let id = plist["CFBundleIdentifier"] as? String ?? String(file.dropLast(6))
            return Receipt(
                identifier: id, name: plist["RDPxlPackageName"] as? String ?? id,
                version: plist["RDPxlPackageVersion"] as? String)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Removes the package `identifier` from the mounted 1.x system volume `v`. Returns log lines and the paths the
    /// preremove wrote by owner uid.
    static func uninstall(_ identifier: String, _ v: any VolumeFiles) throws -> (
        lines: [String], owners: [UInt32: [String]]
    ) {
        guard !identifier.isEmpty, !identifier.contains("/"), identifier != ".", identifier != ".." else {
            throw refused("its identifier \(identifier) can't name a file")
        }
        let path = "\(receipts)/\(identifier).plist"
        guard let receipt = v.plist(at: path) else {
            throw FirmwareError(.unsupported, "no package \(identifier) is installed (no /\(path))")
        }
        let preremove = commands(receipt["RDPxlPackagePreremove"])
        try checkCommands(preremove, "preremove")
        var lines: [String] = []
        var owners: [UInt32: [String]] = [:]
        var files: [String] = []
        var folders: [String] = []
        var kept = 0
        for entry in receipt["RDPxlPackageInstalledFiles"] as? [[String: Any]] ?? [] {
            guard let file = entry["file"] as? String else { continue }
            // already a volume path: resolved as written, never through mobile's home again
            let resolved = try resolve(v, try absolute(file), followLast: false)
            guard let top = resolved.split(separator: "/").first, roots.contains(String(top)),
                resolved != receipts, !resolved.hasPrefix(receipts + "/")
            else { throw refused("its receipt names \(file), outside the folders a package may write") }
            if entry["permanent"] as? Bool == true || entry["replaced"] as? Bool == true {
                kept += 1
            } else if entry["directory"] as? Bool == true {
                folders.append(resolved)
            } else {
                files.append(resolved)
            }
        }
        // every path held to the roots before anything changes
        let place = placer(v)
        for argv in preremove where !argv.isEmpty {
            let (line, written) = try run(argv, v, place: place)
            lines.append(line.replacingOccurrences(of: "postflight", with: "preremove"))
            for w in written { owners[w.uid, default: []].append(w.path) }
        }
        // its apps leave Home first, while their Info.plists are there to name them
        for app in folders where app.split(separator: "/").count == 2 && app.hasPrefix("Applications/") {
            guard let id = v.plist(at: app + "/Info.plist")?["CFBundleIdentifier"] as? String,
                try unregisterDisplayIdentifier(v, id)
            else { continue }
            lines.append("DisplayOrder.plist: \(id) out of iconList")
        }
        for file in files where v.isFile(file) || v.isSymlink(file) { try v.remove(file) }
        var left = 0
        // deepest first, each only once empty: what the user or another package put there stays
        for folder in folders.sorted(by: { $0.count > $1.count }) where v.isDirectory(folder) {
            if try v.contentsOfDirectory(at: folder).isEmpty { try v.remove(folder) } else { left += 1 }
        }
        try v.remove(path)
        lines.append(
            "\(receipt["RDPxlPackageName"] as? String ?? identifier): \(files.count) files and \(folders.count - left) "
                + "folders removed, \(kept) kept (permanent or replaced)"
                + (left > 0 ? ", \(left) folders not empty" : ""))
        return (lines, owners.mapValues { Array(Set($0.filter(v.exists))).sorted() })
    }

    /// 1.0's DisplayOrder.plist without `identifier` in its iconList. True if it was there.
    static func unregisterDisplayIdentifier(_ v: any VolumeFiles, _ identifier: String) throws -> Bool {
        guard v.exists(SystemEdits.displayOrder) else { return false }
        var removed = false
        try SystemEdits.rewritePlist(v, SystemEdits.displayOrder) { order in
            guard let list = order["iconList"] as? NSMutableArray else { return }
            let before = list.count
            list.filter { ($0 as? NSDictionary)?["displayIdentifier"] as? String == identifier }.forEach(list.remove)
            removed = list.count < before
        }
        return removed
    }
}
