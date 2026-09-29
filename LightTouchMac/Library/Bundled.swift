// Created by Sam on 2026-08-05.
//
// Where the things the app ships actually live.
//
// A packaged LightTouchMac is meant to be self-contained: someone who has never
// heard of Homebrew should be able to drag it to /Applications and have app
// installs, media import and the home-screen placeholder all work. So every
// external binary and library is looked for INSIDE the bundle first —
// Contents/MacOS for native helpers, Resources/tools for scripts and guest data,
// Contents/Frameworks for
// dylibs — and only then in the places a development checkout keeps them.
//
// Run from Xcode there is nothing in the bundle and the checkout answers every
// time; scripts/package.sh is what fills it in for a shippable build. Keeping
// the search order the same in both means the packaged app exercises the same
// code paths the dev build does, rather than a packaging-only branch nobody
// runs until it breaks.

import Foundation

/// Nonisolated: the project defaults to MainActor, and these are read from the
/// detached tasks that do the blocking device work as well as from the UI.
nonisolated enum Bundled {

    /// Scripts and guest upload payloads shipped with the app.
    static let toolsDirectory = Bundle.main.resourceURL?
        .appendingPathComponent("tools", isDirectory: true).path

    /// Native helper executables share the standard executable directory.
    static let hostToolsDirectory = Bundle.main.executableURL?.deletingLastPathComponent().path

    /// Dylibs shipped with the app, where package.sh repoints @rpath.
    static let frameworksDirectory = Bundle.main.privateFrameworksPath

    /// The device assets (the iPod bootrom, the packed built-in device): LTM_FILES,
    /// then the bundle's Resources/device, then the dev checkout's qemu-ios-files.
    static let filesRoot: String = {
        if let env = ProcessInfo.processInfo.environment["LTM_FILES"] { return env }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("device").path,
           FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        return "\(NSHomeDirectory())/Developer/qemu-ios-files"
    }()

    /// Prepare once before the app constructs controllers or opens any device
    /// files. On error the caller must stop startup instead of creating a new
    /// device next to inaccessible or conflicting existing data.
    private static let layout: Result<StorageLocations.Layout, any Error> = Result {
        let fm = FileManager.default
        return try StorageLocations.prepare(
            applicationSupport: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            library: fm.urls(for: .libraryDirectory, in: .userDomainMask)[0],
            override: ProcessInfo.processInfo.environment["LTM_STATE_DIR"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            })
    }

    /// One app per library: State/.app-lock, held (flock) for the process's
    /// life. Launch sweeps and device starts run only after this succeeds.
    static let appLockMessage = "Light Touch is already running with this library"
    private static let appLock: Result<Int32, any Error> = Result {
        let state = try layout.get().state
        let fd = open(state.appendingPathComponent(".app-lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StorageLocations.posixError() }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw CocoaError(.fileLocking, userInfo: [NSLocalizedDescriptionKey: appLockMessage + "."])
        }
        return fd
    }

    static func requireStorage() throws { _ = try appLock.get() }

    /// The fallback is only a path for error reporting, never an alternate
    /// writable root. App startup requires the successful layout above.
    static var stateDirectory: URL {
        if case .success(let value) = layout { return value.state }
        return ProcessInfo.processInfo.environment["LTM_STATE_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(StorageLocations.bundleIdentifier, isDirectory: true)
    }

    static var preparedLogsDirectory: URL? {
        if case .success(let value) = layout { return value.logs }
        return nil
    }

    static var logsDirectory: URL {
        if let ready = preparedLogsDirectory { return ready }
        return ProcessInfo.processInfo.environment["LTM_STATE_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("Logs", isDirectory: true)
        } ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/\(StorageLocations.bundleIdentifier)", isDirectory: true)
    }

    /// Legacy Store download scratch (and, in Debug, the development lockdown
    /// helpers). Each device's own daemon files are under Devices/<uuid>/work.
    static var workDirectory: URL {
        let url = stateDirectory.appendingPathComponent("work", isDirectory: true)
        if case .success = layout { try? StorageLocations.privateDirectory(url) }
        return url
    }

    /// A non-executable resource shipped alongside the app (a config dir, a
    /// data file), or nil when this build has none.
    static func resource(_ relativePath: String) -> String? {
        guard let base = Bundle.main.resourceURL?.appendingPathComponent(relativePath).path,
              FileManager.default.fileExists(atPath: base) else { return nil }
        return base
    }

    /// A shipped executable or script, or nil when this build has none — in
    /// which case the caller falls back to a checkout path.
    static func tool(_ name: String) -> String? {
        [hostToolsDirectory, toolsDirectory].compactMap { $0 }
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The first of `candidates` that exists, bundle copy first.
    static func resolve(_ name: String, fallbacks candidates: [String]) -> String? {
        tool(name) ?? candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Directories to search for command-line tools, ours before anyone's.
    static var binarySearchPaths: [String] {
        [hostToolsDirectory, toolsDirectory, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].compactMap { $0 }
    }
}
