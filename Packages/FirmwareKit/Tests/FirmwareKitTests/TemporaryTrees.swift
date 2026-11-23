// The temporary trees FirmwareKit's tests make, removed whatever they hold. A test that publishes a device generation
// leaves its base locked (chflags uchg) and read-only, which FileManager.removeItem can't delete, so the tests' own
// `try? removeItem` failed silently and every Unit plan run left gigabytes in the temporary directory (78 GB in a day).

import Darwin
import Foundation

nonisolated enum TemporaryTrees {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var trees: [URL] = []
    nonisolated(unsafe) private static var sweepsAtExit = false

    /// Removes `url` at the latest when the test process exits (a test that never removes what it made).
    static func remember(_ url: URL) {
        lock.withLock {
            trees.append(url)
            guard !sweepsAtExit else { return }
            sweepsAtExit = true
            atexit { TemporaryTrees.removeRemembered() }
        }
    }

    static func removeRemembered() {
        for url in lock.withLock({ trees }) { remove(url) }
    }

    /// Removes the file or tree at `url`, each entry unlocked and each directory made writable first. Symbolic links
    /// are unlocked themselves and never followed.
    static func remove(_ url: URL) {
        let fm = FileManager.default
        unlock(url)
        if let walk = fm.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let item as URL in walk { unlock(item) }
        }
        try? fm.removeItem(at: url)
    }

    private static func unlock(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        lchflags(url.path, 0)
        if info.st_mode & S_IFMT == S_IFDIR { chmod(url.path, 0o700) }
    }
}
