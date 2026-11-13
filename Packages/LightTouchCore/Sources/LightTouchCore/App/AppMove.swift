// Moving Light Touch out of where Sparkle can't update it: macOS runs a copy opened where it was downloaded from a
// read-only translocated mount (SURunningTranslocated), and a copy opened in a disk image
// from that read-only volume (SURunningFromDiskImageError). The app offers the move at launch
// (AppDelegate.offerMoveToApplications); this is what it decides and copies. Pure Foundation; AppMoveTests.

import Foundation

public nonisolated enum AppMove {
    /// The bundle can't be updated where it is: translocated, or on a read-only volume.
    public static func isStuck(_ bundle: URL) -> Bool {
        bundle.path.contains("/AppTranslocation/")
            || (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
    }

    /// Where the copy goes: /Applications when this user can write there (and replace a copy already there), else
    /// ~/Applications, so the move never asks for an administrator password.
    public static func destination(
        for bundle: URL,
        system: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        writable: (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) }
    ) -> URL {
        let name = bundle.lastPathComponent
        let existing = system.appendingPathComponent(name)
        let fits = writable(system) && (!FileManager.default.fileExists(atPath: existing.path) || writable(existing))
        return (fits ? system : home).appendingPathComponent(name)
    }

    /// Copies `bundle` to `destination`, replacing an older copy there, and takes the copy's quarantine
    /// off: a copy that keeps it is translocated again when it opens (only a move in Finder lifts that), and this
    /// copy's Gatekeeper check passed when it opened.
    public static func copy(_ bundle: URL, to destination: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        try files.copyItem(at: bundle, to: destination)
        unquarantine(destination)
        guard let contents = files.enumerator(at: destination, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in contents { unquarantine(url) }
    }

    private static func unquarantine(_ url: URL) {
        _ = url.withUnsafeFileSystemRepresentation { removexattr($0, "com.apple.quarantine", XATTR_NOFOLLOW) }
    }
}
