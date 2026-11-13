import Cocoa
import DeviceRuntime
import FirmwareSchema
import HostRuntime
import HostServiceClient
import HostServiceWire
import LightTouchCore
import Observation

extension EmulatorController {
    // MARK: - Options
    var localNetworkEnabled: Bool { options.localNetworkEnabled }
    func toggleLocalNetwork() { options.toggleLocalNetwork() }
    var debugPortEnabled: Bool { options.debugPortEnabled }
    func toggleDebugPort() { options.toggleDebugPort() }
    var debugSocket: String? { options.debugSocket }
    var lldbAttachCommand: String? { options.lldbAttachCommand }

    // MARK: - Guest package
    var guestOffer: GuestPackage.Offer? { guestPackage.offer }
    var guestToolsStatus: GuestPackage.Status { guestPackage.status }
    func startGuestPackageWatch() { guestPackage.start() }
    private var recordURL: URL { guestPackage.recordURL }
    var lock: DeviceLock? { guestPackage.lock }

    /// View ▸ Free-Form Screen (issue #21): the record's `panel`, read fresh and written back ("WxH" as the panel
    /// scans; nil, the shipped panel). With `restart`, a running device stops (Stop's hard halt) and a fresh helper
    /// boots on it, since the guest takes its screen size at boot. Returns whether that restart is under way.
    func setPanel(_ panel: String?, restart: Bool) -> Bool {
        guard var record = try? DeviceInstance.read(recordURL) else { return false }
        if record.panel != panel {
            record.panel = panel
            do {
                try record.write(state: stateDir)
                DeviceLibrary.shared.reload()
            } catch {
                logEvent("display: could not record panel \(panel ?? "native"): \(error.localizedDescription)")
                return false
            }
        }
        instance.panel = panel
        guard restart, canStop else { return false }
        logEvent("display: restarting \(instance.name) at panel \(panel ?? "native")")
        let halt = halt()
        Task { [weak self] in
            guard await halt.value else {
                logEvent("display: the helper didn't stop; not restarting at the new panel")
                self?.onRestartRefused?()
                return
            }
            self?.onRestartRequested?()
        }
        return true
    }

    // MARK: - Machine control
    //
    // pause() and resume() are MachineHost's; Restart and Power On are BootCycle's.
    var poweringOn: Bool { cycle.poweringOn }
    /// Restart the guest, its filesystem synced first.
    func reset() { cycle.reset() }
    /// Retain the QEMU main loop at guest power-off; a reset can cold boot it
    /// again without reinitializing QEMU or opening a second NAND writer.
    @discardableResult func powerOff() -> Task<Bool, Never> { ladder.forceStop() }
    func powerOn() { cycle.powerOn() }

    var isReleased: Bool { stopped || releasing }
    func syncGuest() async throws { try await guestAgent.sync() }
    /// Everything one boot learned about its guest: each boot begins with none of it and each ending drops it
    /// (state audit A-12, A-13), so a dead device never draws as asleep and a Restart never inherits the last boot's
    /// connection issue or its Setup.
    func forgetBootFacts() {
        didSweepStaging = false
        recovery.forget()
        foreground.forget()
        isSleeping = false
        deviceReachable = nil
        reachableSince = nil
        agentStatus = 0
        agentStaleSince = nil
        tweaks.forgetBoot()
        accessibilityOn = nil
        readSetupExpectation()
    }
    func endBoot(_ end: BootEnd) { bootWatch.endBoot(end) }

    func startForegroundWatch() { foreground.start() }
    var overlay: URL { overlayURL }
    func foregroundApp() async throws -> (bundleID: String, name: String?) {
        let app = try await guest.foreground()
        if app.bundleID != frontBundleID {
            frontBundleID = app.bundleID
            Analytics.frontApp(app.bundleID, analyticsParameters)
        }
        return app
    }
    func applyWebProxy(since applied: Int?, generation: Int) async throws -> Int? {
        try await proxy.apply(
            since: applied,
            isCurrent: { generation == self.bootGeneration },
            setUp: { enabled in
                try await WebProxySetup(
                    services: self.services,
                    guest: self.guest,
                    proxyDirectory: self.proxyDirectory,
                    stoppedTrust: self.trustsStopped ? (self.instance.paths.directory, self.instance.storage.key) : nil,
                    reportParameters: self.analyticsParameters
                )
                .configure(enabled: enabled)
            }
        )
    }
    func setupFinished(generation: Int) { timeZone.schedule(generation: generation) }
    func applyTweaks(generation: Int) async throws {
        try await tweaks.apply(guest: guest, isCurrent: { generation == self.bootGeneration })
        if let services = try? services { await tweaks.mountDeveloperImage(services: services) }
    }

    /// Guest audio for a recording (ScreenMovieWriter). Its clock is the
    /// dylib's: monotonic seconds since the capture started.
    func startAudioCapture() async throws -> GuestAudioCapture {
        guard let link, !isDead else { throw CaptureError.failed("The device is not ready to record audio.") }
        let origin = ProcessInfo.processInfo.systemUptime
        let capture = GuestAudioCapture(
            clock: { ProcessInfo.processInfo.systemUptime - origin },
            stop: { generation in link.send(.audioStop(generation: generation)) }
        )
        audioSink = { [weak capture] event in capture?.receive(event) }
        guard case .audio(let generation) = try await link.request(.audioStart) else {
            throw CaptureError.failed("The device is not ready to record audio.")
        }
        capture.begin(generation: generation)
        return capture
    }

    // MARK: - Device storage paths

    var overlayURL: URL { instance.paths.overlay }

    static let haltBudget: TimeInterval = ShutdownLadder.Budgets().halt
    /// The quit backstop: the halt, then the kill, then the services worker.
    static let stopBudget: TimeInterval = ShutdownLadder.Budgets().stop
    var shuttingDown: Bool { ladder.shuttingDown }
    var halting: Bool { ladder.halting }
    /// A live helper whose VM can be stopped, including mid-boot.
    var canStop: Bool { ladder.canStop }
    /// Force Stop: Stop's hard halt, also while a Shut Down is under way (one the guest never finishes).
    var canForceStop: Bool { ladder.canForceStop }
    var canShutDown: Bool { ladder.canShutDown }
    var isShuttingDownCleanly: Bool { ladder.isShuttingDownCleanly }
    /// The guest powers itself off, as the slider does; the helper stays, powered off.
    @discardableResult func shutDown() -> Task<ShutdownOutcome, Never> { ladder.shutDown() }
    /// `completion(true)` iff the helper is gone.
    @discardableResult func halt() -> Task<Bool, Never> { ladder.halt() }
    func willStop() {
        AppInstaller.discard(for: instance.id)
        stopTimeZoneSync()
    }

    func requestFactoryReset() { eraser.request() }
    var eraseTargets: DeviceErase.Targets { DeviceErase.Targets(instance) }
    func discardInstalls() { AppInstaller.discard(for: instance.id) }
    func stopGuestWatches() {
        foreground.stop()
        rotation.stopWatching()
    }
    func restart() { onRestartRequested?() }
}
