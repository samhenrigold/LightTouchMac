import Cocoa
import DeviceRuntime
import FirmwareSchema
import HostRuntime
import HostServiceClient
import HostServiceWire
import LightTouchCore
import Observation

extension EmulatorController {
    // MARK: - App management
    var canManageApps: Bool { apps.canManageApps }
    var canReachDevice: Bool { apps.canReachDevice }
    var canQueueInstall: Bool { apps.canQueueInstall }
    var isInstalling: Bool { apps.isInstalling }
    var restartingSpringBoard: Bool { apps.restartingSpringBoard }
    /// The usbmuxd socket to talk to this device on, for the long-lived
    /// notification_proxy watcher (which owns its own session, not a gated one).
    var usbmuxSession: String? { usbmux.session?.clientSocket }

    /// The guest agent through this device's helper, and the app's operations on it.
    var guestAgent: GuestAgent { GuestAgent(link: link, cache: agentCache) }
    var guest: GuestServices { GuestServices(agent: guestAgent, packaged: status?.guestPackage != nil) }
    var services: DeviceServices { get throws { try apps.services } }
    var installPipeline: AppInstallPipeline { get throws { try apps.installPipeline } }
    func deviceReady() async -> Bool { await apps.deviceReady() }
    func checkDeviceConnection() async throws { try await apps.checkDeviceConnection() }
    func restartSpringBoard() async throws { try await apps.restartSpringBoard() }
    var hasSpringBoardServices: Bool { apps.hasSpringBoardServices }
    func waitForSpringBoard(agentCounts: Bool = false) async throws {
        try await apps.waitForSpringBoard(agentCounts: agentCounts)
    }
    func install(
        _ ipa: URL,
        placeholderRaised: Bool = false,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        try await apps.install(ipa, placeholderRaised: placeholderRaised, progress: progress)
    }
    func importMedia(
        _ media: PreparedMedia,
        progress: @escaping @Sendable (Double) -> Void,
        willCommit: () -> Void
    ) async throws {
        try await apps.importMedia(media, progress: progress, willCommit: willCommit)
    }

    /// The guest's orientation in degrees; nil when this image has no agent.
    /// Failures must not start a second transport.
    func guestOrientation() async throws -> Int? {
        _ = try services
        guard guestAgent.status != 0 else { return nil }
        return try await guestAgent.orientation()
    }
    func interfaceOrientation() async throws -> Int { try await services.interfaceOrientation() }
    var reportedInterfaceOrientation: Int? {
        guestAgent.report.flatMap { $0.isAnswering ? $0.interfaceOrientation : nil }
    }

    /// This device's firmware, from its catalog entry: what an app's minimum
    /// iOS and architecture are checked against.
    private var catalogEntry: FirmwareCatalog.Entry? { FirmwareCatalog.bundled.entry(id: instance.firmware) }
    var iosVersion: String { catalogEntry?.version ?? "3.1.3" }
    /// "iPod2,1": the model Legacy Store judges apps for, with iosVersion.
    var productType: String? { catalogEntry?.productType }
    var guestArch: String { catalogEntry?.recipe?.guest?.arch ?? profile.arch }
    /// What the media gate reads (MediaSupport).
    var mediaFirmware: MediaSupport.Firmware {
        MediaSupport.Firmware(
            version: iosVersion,
            name: (["iOS \(iosVersion)"] + [catalogEntry?.prereleaseBadge].compactMap { $0 }).joined(separator: " "),
            media: catalogEntry?.media ?? [],
            prerelease: catalogEntry?.prerelease != nil
        )
    }

    // MARK: - Accessibility (Device ▸ Accessibility)

    /// Why this device has no accessibility features; nil where it has them.
    var accessibilityUnavailable: String? {
        AccessibilityFeature.unavailableReason(board: profile, version: iosVersion)
    }

    /// Reads what the guest has on (its agent), then `done`; a guest without an agent leaves the check marks off.
    func readAccessibility(_ done: @escaping @MainActor () -> Void = {}) {
        guard isRunning, accessibilityUnavailable == nil, guestAgent.status == 1,
            let services = try? services
        else { return }
        let (guest, version) = (guest, iosVersion)
        Task {
            guard let on = try? await services.accessibility(guest: guest, version: version) else { return }
            accessibilityOn = on
            done()
        }
    }

    /// Turns `feature` on or off as iTunes did; the guest's state is read back once SpringBoard has applied it.
    func setAccessibility(_ feature: AccessibilityFeature, on: Bool) async throws {
        try await services.setAccessibility(feature, on: on)
        var now = accessibilityOn ?? []
        if on { now.insert(feature) } else { now.remove(feature) }
        accessibilityOn = now
        logEvent("accessibility: \(feature) \(on ? "on" : "off")")
        try? await Task.sleep(for: .seconds(3))
        readAccessibility()
    }

    // MARK: - Activation (prepared offline, completed and verified per boot)
    func activationState() async -> String? { await (try? services)?.activationState() }
    func finishActivation() async throws { try await services.finishActivation() }
    func installProxyReady() async -> Bool { await (try? services)?.installProxyReady() == true }

    // launchApp(_:) is AppLaunchHost's: a sleeping display is woken first.
    var displaySleeping: Bool? { status?.displaySleeping }
    func checkServices() throws { _ = try services }
    func launchInGuest(_ bundleID: String) async throws { try await guest.launch(bundleID) }
}
