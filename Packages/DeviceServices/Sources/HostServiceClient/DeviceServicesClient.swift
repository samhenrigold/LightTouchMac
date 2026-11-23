// The app's side of one device's host services. Every operation runs in the endpoint's LightTouchServices
// process (HostServiceWorkers); nothing here touches libimobiledevice, and blocking library calls never enter
// the GUI. What the helper does for each is LightTouchServices/Engine.

import CoreServices
import Foundation
import HostServiceWire

extension DeviceServices {
    // MARK: - Attachment and lockdown

    /// Does the USB bridge see the guest? Bounded, gated and abandoned safely in the helper; every caller treats a
    /// silent device as "could not prove it is alive", not "it is dead".
    public func checkAttachment() async throws {
        _ = try await remote(.attachment, seconds: Timeouts.serviceProbe * 2)
    }

    /// lockdownd's ActivationState: "Activated", "Unactivated", "FactoryActivated".
    ///
    /// The tell for a torn filesystem. A hard exit loses HFS+ catalog updates
    /// that were still in memory, and if the activation record is among them the
    /// guest boots to the Connect-to-iTunes screen — where lockdownd still
    /// answers but every service refuses, so the app's only symptom was an
    /// unexplained "Install service error (connect): code -256". Asking turns
    /// that dead end into something the UI can name and offer a fix for.
    public func activationState() async -> String? { try? await lockdownValue("ActivationState") }

    /// Stock lockdown reads share the same endpoint, timeout and error contract.
    /// A string as it is, data as lowercase hex, a number in decimal; `domain` as lockdownd names one.
    public func lockdownValue(_ key: String, domain: String? = nil) async throws -> String? {
        guard case .string(let state) = try await remote(.lockdownValue(key, domain: domain), seconds: Timeouts.query)
        else {
            return nil
        }
        return state
    }

    // MARK: - installation_proxy

    /// Installed third-party apps (instproxy_browse, ApplicationType=User), sorted by name.
    public func installedApps() async throws -> [InstalledApp] {
        guard case .apps(let apps) = try await remote(.apps, seconds: Timeouts.browse) else {
            throw DeviceError.unavailable
        }
        return apps
    }

    public func uninstall(_ bundleID: String) async throws {
        _ = try await remote(.uninstall(bundleID), seconds: Timeouts.uninstall)
    }

    /// Install `ipa`, already staged at `staged`, as a new version of an installed `bundleID` too. The helper
    /// does the 2.x replacement (LightTouchServices/Engine/InstallationProxy.swift): at most a lockdown read, the
    /// archive list, a second upload and three guest commands, each under its own watchdog.
    public func install(
        _ ipa: URL,
        staged: String,
        bundleID: String,
        progress: @escaping @Sendable (Int, String) -> Void
    ) async throws {
        _ = try await remote(
            .install(ipa: ipa.path, staged: staged, bundleID: bundleID),
            seconds: Timeouts.query + Timeouts.browse + Timeouts.stage
                + 3 * Timeouts.installAbsolute + Timeouts.serviceProbe * 2
        ) {
            if case .install(let percent, let phase) = $0 { progress(percent, phase) }
        }
    }

    /// Does installation_proxy answer right now? A fresh boot brings lockdownd
    /// up ~40s before its services, so "lockdown replies" ≠ "installd is ready".
    public func installProxyReady() async -> Bool {
        guard case .boolean(let ready) = try? await remote(.installReady, seconds: Timeouts.serviceProbe) else {
            return false
        }
        return ready
    }

    // MARK: - AFC

    /// Bytes free on the media partition. The pre-flight that names a full
    /// device before installd fails opaquely with PackageExtractionFailed.
    public func freeSpaceBytes() async throws -> Int64 {
        guard case .integer(let bytes) = try await remote(.freeSpace, seconds: Timeouts.query) else {
            throw DeviceError.unavailable
        }
        return bytes
    }

    /// Upload the .ipa into the AFC jail and return its device-relative path,
    /// which is what instproxy_install wants. Chunked so progress is live.
    public func stage(_ ipa: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try await stageFile(ipa, remote: "PublicStaging/\(Self.stagingName(ipa))", progress: progress)
    }

    /// The Files browser's copy into `directory` (of afcRoot). `replacing`: over a file already there, which is
    /// replaced only once the new one is complete; otherwise an identical file there is kept and a different one refused.
    public func uploadFile(
        _ source: URL,
        into directory: String,
        replacing: Bool = false,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Self.validateFilePath(directory)
        let path = directory.isEmpty ? source.lastPathComponent : directory + "/" + source.lastPathComponent
        try Self.validateFilePath(path)
        guard !path.isEmpty else { throw DeviceError.preflight("Select a file to import.") }
        _ = try await stageFile(
            source,
            remote: path,
            reuseIdentical: !replacing,
            replace: replacing,
            allowEmpty: true,
            root: afcRoot,
            progress: progress
        )
    }

    /// Callers supply a validated relative destination. The same chunked AFC
    /// upload, cancellation and incomplete-file cleanup serve apps and songs.
    public func stageFile(
        _ ipa: URL,
        remote: String,
        reuseIdentical: Bool = false,
        replace: Bool = false,
        allowEmpty: Bool = false,
        root: AFCRoot = .media,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        guard
            case .string(let path) = try await self.remote(
                .upload(
                    source: ipa.path,
                    remote: remote,
                    reuse: reuseIdentical,
                    replace: replace,
                    allowEmpty: allowEmpty,
                    root: root
                ),
                seconds: Timeouts.stage,
                progress: {
                    if case .fraction(let value) = $0 { progress(value) }
                }
            ), let path
        else { throw DeviceError.unavailable }
        return path
    }

    /// iPhone OS 1.x: `source` written to `remote` in the Media folder as iTunes syncs (syncWillStart, the sync lock,
    /// syncDidFinish), so a running Music loads its library again.
    public func syncLibraryFile(_ source: URL, remote: String) async throws {
        _ = try await self.remote(.syncLibraryFile(source: source.path, remote: remote), seconds: Timeouts.stage)
    }

    /// Startup cleanup of uploads an earlier session left in PublicStaging and LightTouch/.
    public func sweepStaging() async {
        _ = try? await remote(.sweep, seconds: Timeouts.query)
    }

    /// Best-effort cleanup of a staged upload.
    public func removeStaged(_ path: String) async {
        _ = try? await remote(.remove(path), seconds: Timeouts.query)
    }

    public func files(in path: String) async throws -> [DeviceFile] {
        let result = try await remote(.files(path, root: afcRoot), seconds: Timeouts.browse)
        guard case .files(let files) = result else {
            throw DeviceError.unavailable
        }
        return files
    }

    /// Save to a private adjacent file, then publish only a completed transfer.
    public func download(
        _ file: DeviceFile,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // The GUI owns publication. A killed transfer leaves only this
        // private candidate, never a late replacement of the user's file.
        let staging = destination.deletingLastPathComponent().appendingPathComponent(
            ".LightTouch-host-" + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: staging) }
        let candidate = staging.appendingPathComponent("file")
        _ = try await remote(
            .download(file, destination: candidate.path, root: afcRoot),
            seconds: Timeouts.stage
        ) {
            if case .fraction(let value) = $0 { progress(value) }
        }
        try Task.checkCancellation()
        try Self.quarantine(candidate, from: file.path, root: afcRoot)
        guard Darwin.rename(candidate.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Marks `url` as downloaded by Light Touch from the device's `path` (of `root`) before it gets its final name, so
    /// no copy of the device's bytes is ever on the Mac unmarked: the device is untrusted (an app on it, or a page in
    /// its Safari, may own it), and Gatekeeper checks a quarantined file when it is opened, an app in a zip included.
    /// Throws where the mark can't be set, and the file is then not published.
    public static func quarantine(_ url: URL, from path: String, root: AFCRoot) throws {
        var origin = URLComponents()
        origin.scheme = "x-light-touch-device"
        origin.path =
            switch root {
            case .media: "/Media/" + path
            case .fileSystem: "/" + path
            case .app(let id): "/" + id + "/" + path
            }
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Light Touch",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String
        ]
        properties[kLSQuarantineDataURLKey as String] = origin.url
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var marked = url
        try marked.setResourceValues(values)
    }

    /// The Files browser's edits (of afcRoot): `path` and everything in it.
    public func delete(_ path: String) async throws {
        _ = try await remote(.delete(path, root: afcRoot), seconds: Timeouts.browse)
    }

    /// `path` renamed to `name` in its folder.
    public func rename(_ path: String, to name: String) async throws {
        _ = try await remote(.rename(path, to: name, root: afcRoot), seconds: Timeouts.query)
    }

    public func makeFolder(_ path: String) async throws {
        _ = try await remote(.makeFolder(path, root: afcRoot), seconds: Timeouts.query)
    }

    // MARK: - springboardservices

    /// Bundle IDs in home-screen order: dock first, then each page, reading
    /// the way the icons are laid out. Throws rather than returning [] so the
    /// caller can tell "SpringBoard says there is nothing" from "we couldn't
    /// ask" — an empty list would silently reorder the sidebar to nothing.
    public func homeScreenOrder() async throws -> [String] {
        guard case .strings(let ids) = try await remote(.homeOrder, seconds: Timeouts.query) else {
            throw DeviceError.unavailable
        }
        return ids
    }

    /// Move `bundleID` into the slot `other` currently occupies, or to the end
    /// when `other` is nil. Returns the order SpringBoard ACCEPTED, which is not always the one asked for — the
    /// caller should adopt it rather than assume its own.
    @discardableResult
    public func moveOnHomeScreen(_ bundleID: String, before other: String?, deviceName: String) async throws -> [String]
    {
        guard
            case .strings(let ids) = try await remote(
                .move(bundle: bundleID, before: other, deviceName: deviceName),
                seconds: Timeouts.query
            )
        else { throw DeviceError.unavailable }
        return ids
    }

    /// SpringBoard's UIInterfaceOrientation (1 portrait, 2 upside down,
    /// 3 landscape right, 4 landscape left). 3.2's springboardservicesrelay
    /// answers it; 3.1.3's doesn't (see EmulatorController's auto-rotation).
    public func interfaceOrientation() async throws -> Int {
        guard case .integer(let orientation) = try await remote(.orientation, seconds: Timeouts.query) else {
            throw DeviceError.unavailable
        }
        return Int(orientation)
    }

    // MARK: - Crash reports

    /// The guest's crash reports (paths under its CrashReporter folder) and how many seconds before the device's
    /// clock now each was written; before 3.0, where they come whole, also written into `copyTo`. Throws where the
    /// guest has no crash report service.
    public func crashReports(copyTo: URL? = nil) async throws -> [String: Double] {
        guard
            case .ages(let ages) = try await remote(
                .crashReports(copyTo: copyTo?.path),
                seconds: Timeouts.browse * 2 + Timeouts.query
            )
        else {
            throw DeviceError.unavailable
        }
        return ages
    }
}
