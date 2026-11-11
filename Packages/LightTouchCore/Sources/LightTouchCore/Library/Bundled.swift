// Where the things the app ships actually live.
//
// A packaged LightTouchMac is meant to be self-contained: someone who has never
// heard of Homebrew should be able to drag it to /Applications and have app
// installs, media import and the home-screen placeholder all work. So every
// external binary and library is looked for INSIDE the bundle first —
// Contents/MacOS for native helpers, Contents/Frameworks for dylibs, the
// unpacked Resources/Guest/guest.aar for guest binaries — and only then in the
// places a development checkout keeps them.
//
// A Debug build from Xcode has none of the vendored parts and the checkout
// answers; Archive copies them in from scripts/vendor's directory. Keeping
// the search order the same in both means the packaged app exercises the same
// code paths the dev build does, rather than a packaging-only branch nobody
// runs until it breaks.

import FirmwareSchema
import Foundation

/// Nonisolated: the project defaults to MainActor, and these are read from the
/// detached tasks that do the blocking device work as well as from the UI.
public nonisolated enum Bundled {
    /// Resources/Guest/guest.aar unpacked (FirmwareKit GuestArchive): guest-tools/, developer-tools/ and tools/;
    /// nil in a build without it.
    public static let guestRoot: URL? = guestRoot(resources: Bundle.main.resourceURL)

    /// `resources`' Guest/guest.aar, unpacked once into the user's caches.
    public static func guestRoot(resources: URL?) -> URL? {
        resources.flatMap { (resources: URL) -> URL? in
            do { return try GuestArchive.unpacked(resources: resources) } catch {
                NSLog("guest tools: couldn’t unpack %@/Guest/guest.aar: %@", resources.path, "\(error)")
                return nil
            }
        }
    }

    /// Guest upload payloads shipped with the app (the iPod media helpers).
    public static var toolsDirectory: String? { guestRoot?.appendingPathComponent("tools", isDirectory: true).path }

    /// Native helper executables share the standard executable directory.
    public static let hostToolsDirectory = hostToolsDirectory(of: .main)
    public static func hostToolsDirectory(of bundle: Bundle) -> String? {
        bundle.executableURL?.deletingLastPathComponent().path
    }

    /// Dylibs shipped with the app (scripts/vendor sets their @rpath install names).
    public static let frameworksDirectory = Bundle.main.privateFrameworksPath

    /// The device assets (the iPod SecureROMs): LTM_FILES,
    /// then the bundle's Resources/Device, then the dev checkout's qemu-ios-files (LTM_FILES and the checkout: Debug
    /// only).
    public static let filesRoot: String = filesRoot(
        environment: ProcessInfo.processInfo.environment,
        resources: Bundle.main.resourceURL
    )
    public static func filesRoot(environment: [String: String], resources: URL?) -> String {
        #if DEBUG
            if let env = environment["LTM_FILES"] { return env }
        #endif
        let bundled = resources?.appendingPathComponent("Device").path
        #if DEBUG
            if let bundled, FileManager.default.fileExists(atPath: bundled) { return bundled }
            return "\(NSHomeDirectory())/Developer/qemu-ios-files"
        #else
            return bundled ?? "Resources/Device"
        #endif
    }

    /// Prepare once before the app constructs controllers or opens any device
    /// files. On error the caller must stop startup instead of creating a new
    /// device next to inaccessible or conflicting existing data.
    private static let layout: Result<StorageLocations.Layout, any Error> = Result {
        let fm = FileManager.default
        return try StorageLocations.prepare(
            applicationSupport: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            library: fm.urls(for: .libraryDirectory, in: .userDomainMask)[0],
            override: stateOverride
        )
    }

    /// Debug only (tests, the sessions drivers, development runs): LTM_STATE_DIR keeps all writable state and the
    /// logs in one directory. A Release build has no environment overrides: the bundle's tools and files and the
    /// user's own library, always.
    public static var stateOverride: URL? {
        #if DEBUG
            ProcessInfo.processInfo.environment["LTM_STATE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        #else
            nil
        #endif
    }

    /// One app per library: State/.app-lock, held (flock) for the process's
    /// life. Launch sweeps and device starts run only after this succeeds.
    public static let appLockMessage = "Light Touch is already running with this library"
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

    public static func requireStorage() throws {
        // A preview's host never holds the library: the app run beside it from Xcode would be refused.
        guard !isPreview else {
            throw CocoaError(
                .fileLocking, userInfo: [NSLocalizedDescriptionKey: "An Xcode preview doesn’t open the library."])
        }
        _ = try appLock.get()
    }

    /// An Xcode preview's host: a copy of the app Xcode launches to draw views, which skips the launch (Debug only).
    public static let isPreview: Bool = {
        #if DEBUG
            ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        #else
            false
        #endif
    }()

    /// The fallback is only a path for error reporting, never an alternate
    /// writable root. App startup requires the successful layout above.
    public static var stateDirectory: URL {
        if case .success(let value) = layout { return value.state }
        return stateOverride
            ?? StorageLocations.stateRoot(
                applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            )
    }

    public static var preparedLogsDirectory: URL? {
        if case .success(let value) = layout { return value.logs }
        return nil
    }

    public static var logsDirectory: URL {
        if let ready = preparedLogsDirectory { return ready }
        return stateOverride?.appendingPathComponent("Logs", isDirectory: true)
            ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/\(StorageLocations.bundleIdentifier)", isDirectory: true)
    }

    /// Legacy Store download scratch (and, in Debug, the development lockdown
    /// helpers). Each device's own daemon files are under Devices/<uuid>/work.
    public static var workDirectory: URL {
        let url = stateDirectory.appendingPathComponent("work", isDirectory: true)
        if case .success = layout { try? StorageLocations.privateDirectory(url) }
        return url
    }

    /// A non-executable resource shipped alongside the app (a config dir, a
    /// data file), or nil when this build has none.
    public static func resource(_ relativePath: String) -> String? {
        guard let base = Bundle.main.resourceURL?.appendingPathComponent(relativePath).path,
            FileManager.default.fileExists(atPath: base)
        else { return nil }
        return base
    }

    /// A shipped executable or script, or nil when this build has none — in
    /// which case the caller falls back to a checkout path.
    public static func tool(_ name: String) -> String? { tool(name, in: [hostToolsDirectory, toolsDirectory]) }

    /// The first executable `name` in `directories` (nil ones skipped), in order.
    public static func tool(_ name: String, in directories: [String?]) -> String? {
        directories.compactMap { $0 }
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The first of `candidates` that exists, bundle copy first.
    public static func resolve(_ name: String, fallbacks candidates: [String]) -> String? {
        resolve(name, fallbacks: candidates, in: [hostToolsDirectory, toolsDirectory])
    }
    public static func resolve(_ name: String, fallbacks candidates: [String], in directories: [String?]) -> String? {
        tool(name, in: directories) ?? candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Directories to search for command-line tools, ours before anyone's.
    public static var binarySearchPaths: [String] {
        [hostToolsDirectory, toolsDirectory, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].compactMap { $0 }
    }
}
