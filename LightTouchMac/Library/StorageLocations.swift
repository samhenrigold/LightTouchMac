import Foundation

/// Where the app's state and logs live (docs/storage-layout.md). A layout
/// from before the device library is not migrated: LegacyState offers to
/// erase it once.
nonisolated enum StorageLocations {
    static let bundleIdentifier = "gold.samhenri.LightTouchMac"
    static let logLimit = 1_000_000

    struct Layout: Sendable {
        let state: URL
        let logs: URL
    }

    static func prepare(applicationSupport: URL, library: URL, override: URL? = nil) throws -> Layout {
        let state = override ?? applicationSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
        try privateDirectory(state)
        let logs = override?.appendingPathComponent("Logs", isDirectory: true)
            ?? library.appendingPathComponent("Logs/\(bundleIdentifier)", isDirectory: true)
        try privateDirectory(logs)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logs.path)
        return Layout(state: state, logs: logs)
    }

    static func privateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
            }
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
    }

    struct DaemonIdentity: Equatable {
        let parent: UInt32
        let uid: UInt32
        let started: UInt64
        let micros: UInt64
        let path: String
    }

    static func daemonIdentity(_ pid: pid_t) -> DaemonIdentity? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                           Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_status != 5 else { return nil } // A zombie cannot write files.
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return DaemonIdentity(parent: info.pbi_ppid, uid: info.pbi_uid,
                              started: info.pbi_start_tvsec, micros: info.pbi_start_tvusec,
                              path: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    /// Time Machine skips it (an xattr, so it survives renames). For
    /// recreatable or in-flight data only: overlays and bases stay backed up.
    static func excludeFromBackup(_ url: URL, _ excluded: Bool = true) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try? url.setResourceValues(values)
    }

    static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    /// AppMetadataCache's names and icons: disposable metadata, not device
    /// storage, so the system caches; an isolated run keeps even its cache under
    /// LTM_STATE_DIR.
    static func appMetadataDirectory(state: URL, caches: URL, isolated: Bool) -> URL {
        let root = isolated ? state.appendingPathComponent("Caches", isDirectory: true)
            : caches.appendingPathComponent(bundleIdentifier, isDirectory: true)
        let directory = root.appendingPathComponent("AppMetadata", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// macOS can remove disposable cache files while the app is running.
    /// Recreate the parent for each write, then publish complete bytes together.
    static func writeCacheData(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
