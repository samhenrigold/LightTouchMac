// Created by Sam on 2026-08-06.
//
// A copy of every .ipa this app has successfully installed, keyed by bundle
// id. Installed rows can be dragged out of the app as real files because of
// this — the temp download used to be deleted the moment the install
// finished, leaving nothing to drag. A few MB per app; the collection is the
// point of this program.

import Foundation
import Darwin

nonisolated enum IPALibrary {

    private static let dir: URL = {
        let url = Bundled.stateDirectory.appendingPathComponent("IPAs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Same guard as AppMetadataCache: a bundle id is about to become a path
    /// component, and an archive can claim anything as its identifier.
    private static func safe(_ bundleID: String) -> String? {
        guard !bundleID.isEmpty, !bundleID.hasPrefix("."),
              !bundleID.contains("/"), !bundleID.contains(":"), !bundleID.contains("\0") else { return nil }
        return bundleID
    }

    /// The library's copy for this app, or nil if we never kept one.
    static func url(for bundleID: String) -> URL? {
        guard let id = safe(bundleID) else { return nil }
        let url = dir.appendingPathComponent("\(id).ipa")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Keep a copy of a just-installed .ipa. Best-effort: dragging is a
    /// convenience, never worth failing an install over.
    @concurrent static func adopt(_ ipa: URL, for bundleID: String) async {
        guard let id = safe(bundleID) else { return }
        let dst = dir.appendingPathComponent("\(id).ipa")
        let temporary = dir.appendingPathComponent(".\(UUID().uuidString).ipa")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.copyItem(at: ipa, to: temporary)
            guard rename(temporary.path, dst.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            NSLog("library: could not preserve IPA for %@: %@", id, error.localizedDescription)
        }
    }

    /// The uninstall path forgets the copy alongside the metadata cache.
    static func forget(_ bundleID: String) {
        guard let id = safe(bundleID) else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).ipa"))
    }
}
