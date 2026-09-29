// Notices a running device's files being pulled out from under its helper:
// base/, overlay/ and the overlay's files (the pages and NOR QEMU has open)
// deleted, renamed or replaced. Only what the guest owns: never Devices/<uuid>
// itself, where the app rewrites device.json, web-proxy.*, work/ and IPAs/ while
// the device runs (those fired the notice on every boot and proxy toggle). The
// helper keeps running on the unlinked inodes and the guest never notices; the
// app says so, and Stop skips flushing into a dead inode. Foundation only:
// tests/drivers/helper-driver compiles it.

import Foundation

nonisolated final class DeviceFileWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LightTouch.files")
    private var sources: [any DispatchSourceFileSystemObject] = []

    /// What the notice says once anything under the device moved.
    static func notice(shortName: String) -> String {
        "Files of this \(shortName) were changed while it was running. Stop and start it again; unsaved changes may be lost."
    }

    /// `directories` and each of their direct children, and `files` (a NOR kept
    /// outside the overlay), are watched for delete, rename and revoke; `base`
    /// also for writes (nothing may add or remove an entry there).
    /// `onChange(path)` once per event, on a private queue.
    // ponytail: children present at start only; a page file QEMU creates later isn't watched
    // (they all exist once iOS is up, which is when this starts).
    init(directories: [URL], files: [URL] = [], base: URL?, onChange: @escaping @Sendable (String) -> Void) {
        let fm = FileManager.default
        var watched: [(URL, DispatchSource.FileSystemEvent)] = (directories + files).map { ($0, [.delete, .rename, .revoke]) }
        for directory in directories {
            for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where !name.hasPrefix(".") {
                watched.append((directory.appendingPathComponent(name), [.delete, .rename, .revoke]))
            }
        }
        if let base { watched.append((base, [.delete, .rename, .revoke, .write])) }
        for (url, events) in watched {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: queue)
            let path = url.path
            source.setEventHandler { onChange(path) }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    var count: Int { sources.count }

    deinit { for source in sources { source.cancel() } }
}
