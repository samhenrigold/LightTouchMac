// App management on a running device: whether its services can be reached, its lockdown services and install
// pipeline, installs and media imports (which hold the device), and restarting the Home screen.

import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceClient
import HostServiceWire
import Observation

/// What app management reads of the session.
public protocol AppsHost: AnyObject {
    var bootScope: BootSessionScope { get }
    var profile: Board { get }
    var iosVersion: String { get }
    /// The usbmuxd socket while usbmuxd runs.
    var usbmuxSession: String? { get }
    /// The UDID the guest reports (the record's, or an upgraded iPhone identity's).
    var guestUDID: String? { get }
    var storageFailed: Bool { get }
    var isRunning: Bool { get }
    var isPoweredOff: Bool { get }
    var shuttingDown: Bool { get }
    var deviceReachable: Bool? { get }
    /// An install (AppInstaller) holds this device.
    var installerUsesDevice: Bool { get }
    var guestAgent: GuestAgent { get }
    var guest: GuestServices { get }
}

@Observable public final class DeviceApps {
    @ObservationIgnored private unowned let host: AppsHost
    public init(host: AppsHost) { self.host = host }

    /// usbmuxd is up and the storage holds: the host side of app management.
    public var canManageApps: Bool { host.usbmuxSession != nil && !host.storageFailed }

    /// The question every app-management command actually wants answered.
    ///
    /// `canManageApps` only says the host daemon is alive, and it is true from
    /// the moment usbmuxd starts — through the whole boot and USB enumeration,
    /// which is ~40s on a warm image and past three minutes on a first boot.
    /// Gating on it alone left Install App… enabled that whole
    /// time, so choosing them opened a file picker (or a Terminal window) for a
    /// device that could only answer "not reachable over USB yet". The
    /// inspector's own buttons already waited for a real round trip; the menu
    /// and toolbar were the ones still guessing. `deviceReachable` is that round
    /// trip, set by the list poll, and nil until the first one lands.
    public var canReachDevice: Bool {
        canManageApps && host.isRunning && host.deviceReachable == true
    }

    /// Adding to the ready queue opens no guest session. A probe suppressed by
    /// our own install must not disable File → Install App or drag-and-drop.
    public var canQueueInstall: Bool {
        canManageApps && host.isRunning
            && (host.deviceReachable == true || host.installerUsesDevice || isInstalling)
    }

    /// True while any install is running — the quit guard reads this so ⌘Q
    /// mid-install prompts instead of leaving a half-installed app.
    public private(set) var isInstalling = false
    /// Restart Home Screen is under way: the status line says so, and the device takes no input meanwhile.
    public private(set) var restartingSpringBoard = false

    /// This device's stock lockdown services (installation_proxy, AFC,
    /// springboardservices, lockdownd) on its usbmuxd; throws until usbmuxd is up.
    public var services: DeviceServices {
        get throws {
            guard !host.bootScope.retired, let socket = host.usbmuxSession else {
                throw DeviceToolsError.failed("The device is not reachable over USB yet.")
            }
            return DeviceServices(clientSocket: socket, udid: host.guestUDID, session: host.bootScope.id)
        }
    }

    /// What the Files window binds to (FilesConnection): this boot's endpoint, the device's UDID and the boot's id,
    /// so the boot's retirement stops the worker it used.
    public var filesEndpoint: HostServiceEndpoint? { try? services.endpoint }

    /// Whether the Files window can reach the device: nil while our own work holds back the reads that would say.
    public var filesReachable: Bool? {
        if canReachDevice { return true }
        return host.deviceReachable == nil && canManageApps && host.isRunning ? nil : false
    }

    /// The install pipeline for this device (AppInstaller runs it, and raises
    /// a catalog download's placeholder through it).
    public var installPipeline: AppInstallPipeline {
        get throws {
            AppInstallPipeline(
                services: try services, agent: host.guestAgent, deviceOS: host.iosVersion, soc: host.profile.soc)
        }
    }

    /// Cheap in-process check that the USB bridge sees the guest (bounded and
    /// gated: DeviceServices.checkAttachment). App-service reads establish
    /// lockdownd readiness separately.
    public func deviceReady() async -> Bool {
        (try? await checkDeviceConnection()) != nil
    }

    public func checkDeviceConnection() async throws {
        try Task.checkCancellation()
        guard !host.isPoweredOff, !host.shuttingDown, host.usbmuxSession != nil else {
            throw DeviceError.notAttached
        }
        try await services.checkAttachment()
    }

    /// `body` holds the device: the inspector's reads stand aside, and the quit guard asks first.
    func holdingDevice<T>(_ body: () async throws -> T) async rethrows -> T {
        isInstalling = true
        defer { isInstalling = false }
        return try await body()
    }

    public func install(
        _ ipa: URL,
        placeholderRaised: Bool = false,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        try await holdingDevice {
            try await installPipeline.install(ipa, placeholderRaised: placeholderRaised, progress: progress)
        }
    }

    public func importMedia(
        _ media: PreparedMedia,
        progress: @escaping @Sendable (Double) -> Void,
        willCommit: () -> Void
    ) async throws {
        guard canQueueInstall else { throw DeviceToolsError.failed("The device is not ready for media import.") }
        try await holdingDevice {
            // iPhone OS 1.x has no guest agent: its libraries are written over AFC alone.
            if host.iosVersion.hasPrefix("1.") {
                return try await FirstGenLibrary(services: try services).add(
                    media,
                    progress: progress,
                    willCommit: willCommit
                )
            }
            let device = MediaImport(services: try services, guest: host.guest)
            try await device.stage(media, progress: progress)
            try Task.checkCancellation()
            willCommit()
            try await device.commit(media)
        }
    }

    public func restartSpringBoard() async throws {
        guard host.isRunning, !isInstalling else { return }
        restartingSpringBoard = true
        defer { restartingSpringBoard = false }
        // launchd stops SpringBoard (from 6.x backboardd, which takes SpringBoard
        // with it) and KeepAlive brings it straight back: the cheap fix for "a freshly sideloaded app crashes until I restart", as
        // SpringBoard rebuilds what it caches about installed apps in seconds
        // where a boot costs ~40. User-invoked only, never the install path's.
        _ = try services
        try await host.guest.respring()
        try await waitForSpringBoard()
    }

    /// springboardservices first ships in iPhone OS 3.1: 2.x and 3.0 lockdownd has no such service (Invalid service
    /// on every try), so there lockdown answering is as ready as the Home screen gets.
    public var hasSpringBoardServices: Bool { host.iosVersion.compare("3.1", options: .numeric) != .orderedAscending }

    /// `agentCounts`: the guest agent naming SpringBoard's screen (or Setup Assistant) frontmost is an answer too.
    /// A device in Setup is up and takes input, yet its springboardservices may refuse the layout (n81 9A334 on a
    /// slow Mac: every connection reset for the whole wait). Not after a respring, where the agent can still name
    /// the screen of the SpringBoard that is going away.
    public func waitForSpringBoard(agentCounts: Bool = false) async throws {
        guard hasSpringBoardServices else { return }
        let deadline = ContinuousClock.now + .seconds(45 * Board.hostSlowdown)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if (try? await services.homeScreenOrder()) != nil { return }
            if agentCounts, host.guestAgent.isAlive,
                SpringBoardAnswer.up(frontmost: try? await host.guest.foreground().bundleID)
            {
                logEvent("boot: SpringBoard answers through the guest agent (its layout service did not)")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw DeviceToolsError.failed(
            "The Home screen didn’t come back. Restart the \(host.profile.shortName); your apps are kept."
        )
    }
}
