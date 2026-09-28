import Foundation

/// Durable device data moves as one directory. No merge can safely infer which
/// NAND base belongs to which overlay, pairing identity, or recovery snapshot.
nonisolated enum StorageLocations {
    static let bundleIdentifier = "gold.samhenri.LightTouchMac"
    static let logLimit = 1_000_000

    struct Layout: Sendable {
        let state: URL
        let logs: URL
    }

    static func prepare(applicationSupport: URL, library: URL, override: URL? = nil) throws -> Layout {
        let fm = FileManager.default
        let state: URL
        if let override {
            state = override
            try privateDirectory(state)
        } else {
            state = applicationSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
            let legacy = applicationSupport.appendingPathComponent("LightTouchMac", isDirectory: true)
            try migrateState(from: legacy, to: state)
        }
        let logs = override?.appendingPathComponent("Logs", isDirectory: true)
            ?? library.appendingPathComponent("Logs/\(bundleIdentifier)", isDirectory: true)
        // Log migration failure is reported to the caller: do not silently
        // create a second tree of logs beside unreported legacy output.
        try privateDirectory(logs)
        try migrateLogs(state: state, logs: logs)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logs.path)
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

    static func migrateState(from legacy: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path) else {
            try privateDirectory(destination)
            return
        }
        try privateDirectory(legacy)
        if fm.fileExists(atPath: destination.path) {
            try privateDirectory(destination)
            let oldContents = try fm.contentsOfDirectory(atPath: legacy.path)
            if oldContents.isEmpty {
                try fm.removeItem(at: legacy)
                return
            }
            guard try fm.contentsOfDirectory(atPath: destination.path).isEmpty else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey:
                    "Two Light Touch device folders already exist. Your data has been preserved in \(legacy.path) and \(destination.path). Choose which complete device folder to keep before launching again; do not mix their NAND bases and overlays."])
            }
            // rmdir refuses a directory that another process has populated.
            guard rmdir(destination.path) == 0 else { throw posixError() }
        }
        try rejectRunningLegacyDaemon(in: legacy)
        try normalizeImagePointers(in: legacy)
        // Both roots are siblings on the same volume. rename is atomic and
        // preserves file identities; never fall back to a copy/delete migration.
        guard rename(legacy.path, destination.path) == 0 else { throw posixError() }
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

    private static func ownsDaemon(at path: String) -> Bool {
        guard path.hasSuffix("/usbmuxd") else { return false }
        let executable = URL(fileURLWithPath: path)
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if bundle.pathExtension == "app",
           Bundle(url: bundle)?.bundleIdentifier == bundleIdentifier { return true }
        return path == NSHomeDirectory() + "/Developer/usbmuxd-qemu/usbmuxd/src/usbmuxd"
    }

    private static func rejectRunningLegacyDaemon(in state: URL) throws {
        let pidFile = state.appendingPathComponent("work/usbmuxd.pid")
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0, let identity = daemonIdentity(pid),
              identity.uid == geteuid(), ownsDaemon(at: identity.path) else { return }
        guard identity.parent == 1 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey:
                "Quit the other running copy of Light Touch before moving its device folder. Your existing device data has not been moved."])
        }
        // A crash can leave the daemon alive but reparented to launchd. Reap
        // only that verified orphan; otherwise startup would permanently stop
        // before USBMux.start could run its normal stale-daemon cleanup.
        guard daemonIdentity(pid) == identity else { return }
        if kill(pid, SIGTERM) != 0, errno != ESRCH { throw posixError() }
        let deadline = Date().addingTimeInterval(2)
        while let current = daemonIdentity(pid), current == identity {
            guard Date() < deadline else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey:
                    "A helper from the previous Light Touch run is still stopping. Your existing device data has been preserved; try launching again in a moment."])
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// Older builds wrote absolute base-image directories. Converting those to
    /// paths relative to the state root works before AND after the rename, even
    /// if the app is interrupted between individual atomic pointer writes.
    private static func normalizeImagePointers(in state: URL) throws {
        let fm = FileManager.default
        let device = state.appendingPathComponent("device", isDirectory: true)
        guard fm.fileExists(atPath: device.path) else { return }
        try privateDirectory(device)
        var updates: [(URL, Data)] = []
        for name in try fm.contentsOfDirectory(atPath: device.path)
        where name.hasPrefix("active-") && name.hasSuffix(".json") {
            let url = device.appendingPathComponent(name)
            guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular,
                  var value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                  let path = value["directory"] as? String else { throw CocoaError(.fileReadCorruptFile) }
            if path.hasPrefix("/") {
                let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
                let prefix = state.standardizedFileURL.path + "/"
                guard canonical.hasPrefix(prefix + "device/") else { throw CocoaError(.fileReadCorruptFile) }
                value["directory"] = String(canonical.dropFirst(prefix.count))
                updates.append((url, try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])))
            }
        }
        for (url, data) in updates { try data.write(to: url, options: .atomic) }
    }

    static func migrateLogs(state: URL, logs: URL, limit: Int = logLimit) throws {
        let fm = FileManager.default
        for (name, old) in [("app.log", "app.log"), ("serial.log", "serial.log"),
                            ("usbmuxd.log", "work/usbmuxd.log")] {
            let source = state.appendingPathComponent(old)
            let sources = [source, source.appendingPathExtension("1")]
                .filter { fm.fileExists(atPath: $0.path) }
            guard !sources.isEmpty else { continue }
            let target = logs.appendingPathComponent(name)
            let targets = [target, target.appendingPathExtension("1")]
            var records: [(url: URL, modified: Date, tail: Data)] = []
            for url in Set(sources + targets.filter { fm.fileExists(atPath: $0.path) }) {
                let attributes = try fm.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
                }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let length = try file.seekToEnd()
                try file.seek(toOffset: length > UInt64(limit) ? length - UInt64(limit) : 0)
                records.append((url, attributes[.modificationDate] as? Date ?? .distantPast,
                                try file.read(upToCount: limit) ?? Data()))
            }
            records.sort { $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified > $1.modified }
            var retained: [(url: URL, modified: Date, tail: Data)] = []
            for record in records where !retained.contains(where: { $0.tail == record.tail }) {
                retained.append(record)
                if retained.count == 2 { break }
            }
            let staging = logs.appendingPathComponent(".migration-\(UUID().uuidString)", isDirectory: true)
            try privateDirectory(staging)
            defer { try? fm.removeItem(at: staging) }
            for (index, record) in retained.enumerated() {
                let staged = staging.appendingPathComponent("\(index)")
                try record.tail.write(to: staged, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600, .modificationDate: record.modified], ofItemAtPath: staged.path)
            }
            // Stage every selected source before replacing either destination.
            // A failed publication leaves every legacy source available to retry.
            for index in retained.indices {
                guard rename(staging.appendingPathComponent("\(index)").path, targets[index].path) == 0 else {
                    throw posixError()
                }
            }
            if retained.count == 1, fm.fileExists(atPath: targets[1].path) { try fm.removeItem(at: targets[1]) }
            for source in sources { try fm.removeItem(at: source) }
        }
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
}
