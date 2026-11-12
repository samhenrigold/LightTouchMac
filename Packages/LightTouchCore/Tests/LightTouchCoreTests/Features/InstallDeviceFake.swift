import Foundation
import HostServiceWire
import Testing

@testable import LightTouchCore

/// A scripted device for the install queue (AppInstaller): media preparation, imports and removals start when
/// asked and finish when the test says so; failures, alerts and overlapping guest work are recorded.
final class FakeDevice: InstallDevice {
    let instance: DeviceInstance
    var mediaFirmware = MediaSupport.Firmware(
        version: "3.1.3",
        name: "iOS 3.1.3",
        media: ["Music", "Photos", "Videos"]
    )
    let productType: String? = "iPod2,1", guestArch = "armv6"
    var iosVersion = "3.1.3"
    var deviceReachable: Bool? = true
    var failures = 0, overlapped = false
    var errors: [Error] = []
    /// Imports (by title) and removals (by bundle id) as they reach the guest, and imports that committed.
    var started: [String] = [], committed: [String] = []
    private var waiting: [String: CheckedContinuation<Void, Error>] = [:]
    /// Preparation: every file asked for, the names that fail, the names that wait for `preparing[name]`.
    var prepared: [String] = [], failing: Set<String> = [], delayed: Set<String> = []
    var preparing: [String: CheckedContinuation<Void, Error>] = [:]
    struct Unreadable: LocalizedError { var errorDescription: String? { "Unreadable photo" } }

    init(_ name: String = "device", state: URL? = nil) {
        instance = DeviceInstance(
            id: UUID(),
            name: name,
            board: "n72ap",
            firmware: "ipod-3.1.3",
            created: .now,
            base: .init(kind: .prepared, path: "Devices/\(name)/base"),
            storage: .init(
                key: name,
                overlay: "Devices/\(name)/overlay",
                snapshot: "Devices/\(name)/snapshot",
                usbmuxConf: "Devices/\(name)/usbmuxd-conf"
            )
        )
    }

    func prepareMedia(_ source: URL) async throws -> PreparedMedia {
        let name = source.deletingPathExtension().lastPathComponent
        prepared.append(name)
        if delayed.contains(name) { try await withCheckedThrowingContinuation { preparing[name] = $0 } }
        try Task.checkCancellation()
        if failing.contains(name) { throw Unreadable() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-media-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent(source.lastPathComponent)
        return source.pathExtension == "mp3"
            ? .song(MediaSong(id: UUID().uuidString, directory: directory, audio: file, metadata: file, title: name))
            : .photo(MediaPhoto(id: UUID().uuidString, directory: directory, image: file, title: name))
    }

    func importMedia(_ media: PreparedMedia, progress: @escaping @Sendable (Double) -> Void, willCommit: () -> Void)
        async throws
    {
        try await guestWork(media.title) { progress(0.25) }
        try Task.checkCancellation()  // the upload is interruptible; the removal call below is not
        willCommit()
        committed.append(media.title)
    }

    func uninstall(_ bundleID: String) async throws { try await guestWork(bundleID) {} }

    /// One guest operation: only while this device holds its queue slot, never two at once.
    private func guestWork(_ name: String, _ begun: () -> Void) async throws {
        if !AppInstaller.isUsingDevice(instance.id) || !waiting.isEmpty { overlapped = true }
        started.append(name)
        begun()
        try await withCheckedThrowingContinuation { waiting[name] = $0 }
    }

    func finish(_ name: String, error: Error? = nil) {
        guard let reply = waiting.removeValue(forKey: name) else {
            Issue.record("\(name) is not waiting")
            return
        }
        if let error { reply.resume(throwing: error) } else { reply.resume() }
    }

    func install(_ ipa: URL, placeholderRaised: Bool, progress: @escaping @Sendable (String) -> Void) async throws
        -> String
    { "" }
    func installPlaceholder(_ action: String, bundleID: String, after previous: Task<Void, Never>?) -> Task<
        Void, Never
    >? { nil }
    func reportConnectionFailure(_ error: Error, operation: String) {
        failures += 1
        deviceReachable = false
    }
    func present(_ error: Error, in window: AnyObject?) { errors.append(error) }
    func warnMayNotLaunch(_ appName: String, in window: AnyObject?) {}
}

/// AppInstaller's process-wide collaborators kept in `state` for the life of `body`: the IPA library, the
/// metadata cache (seeded with a name for each of `named`), the device list and the diagnostics log.
func withInstallerState<T>(
    named: [String] = [],
    devices: @escaping () -> [DeviceInstance] = { [] },
    _ body: @MainActor (URL, LogLines) async throws -> T
) async throws -> T {
    try await withTemporaryState { state in
        let metadata = state.appendingPathComponent("AppMetadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try JSONSerialization.data(
            withJSONObject: Dictionary(uniqueKeysWithValues: named.map { ($0, ["name": $0, "hasIcon": false]) })
        )
        .write(to: metadata.appendingPathComponent("index.json"))
        let log = LogLines()
        let before = (IPALibrary.stateRoot, AppMetadataCache.testing, AppInstaller.log, AppInstaller.devices)
        IPALibrary.stateRoot = state
        AppMetadataCache.testing = AppMetadataCache(directory: metadata)
        AppInstaller.log = log.add
        AppInstaller.devices = devices
        defer { (IPALibrary.stateRoot, AppMetadataCache.testing, AppInstaller.log, AppInstaller.devices) = before }
        let result = try await body(state, log)
        #expect(!AppInstaller.hasPendingWork, "the test left work queued")
        return result
    }
}
