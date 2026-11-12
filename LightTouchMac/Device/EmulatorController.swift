import Cocoa
import DeviceRuntime
import FirmwareSchema
import HostRuntime
import HostServiceClient
import HostServiceWire
import LightTouchCore
import Observation

// Owns one device: builds its boot from the device record (a prepared base),
// starts its usbmuxd (for app management), then runs it in its own
// LightTouchDevice helper (DeviceProcess) and exposes input and app operations
// to the UI. Everything that used to be a direct call into the dylib crosses the
// helper's DeviceLink: status and frames are read from shared memory, input is a
// command, the rest are requests. One controller per boot: a restart is a new
// session (DeviceSessionHost.restart).
//
// The composition root: the boot, the helper and the status poll are its own; the rest are components in
// LightTouchCore/Session it owns and forwards to (input, rotation, keyboard, battery, carrier, options, web proxy,
// guest package, foreground watch, time zone, app management, and the state machines: readiness, recovery,
// activation, boot watch, shutdown ladder, boot cycle, erase), each running against the controller through its
// host protocol (the extension at the end).
//
// Observable (as are its components): the window, the inspector and the sidebar each track what they show
// (ObservationLoop). Bookkeeping no observer shows is @ObservationIgnored.

@MainActor @Observable
final class EmulatorController {
    let profile: Board
    /// Emulated Wi-Fi with the Mac's networking (slirp); off is a device with no internet.
    let network: Bool
    let usbmux = USBMux()
    var started = false
    @ObservationIgnored var stopped = false
    @ObservationIgnored var serialCapture: SerialLogCapture?
    /// The GuestFaults phrases this boot's serial log has shown (openSerialLog resets it).
    @ObservationIgnored var guestFaultsSeen: Set<String> = []
    /// When this boot powered on, and the processes whose crash reports it has logged (openSerialLog resets both).
    @ObservationIgnored var poweredOn = Date()
    @ObservationIgnored var crashesLogged: Set<String> = []
    /// The app in front of the guest at the last look, and whether this boot's guest tools going quiet was reported
    /// (openSerialLog resets it): for Analytics.
    @ObservationIgnored var frontBundleID: String?
    @ObservationIgnored var reportedToolsQuiet = false
    var isErasing = false { didSet { trackStartup(was: oldValue || state == .booting || preparingDevice) } }
    /// When the current startup (erase, boot, readiness) began: the toast's counter, per device, not per window.
    private(set) var startupBegan = Date()
    /// A boot being stopped (Stop, or Shut Down before it is up) is no longer starting up: its toast goes at once.
    var isStartingUp: Bool { isErasing || (state == .booting && !shuttingDown) || preparingDevice }
    private func trackStartup(was: Bool) {
        if isStartingUp, !was { startupBegan = Date() }
        // A crash while a device starts keeps the next launch from starting it (CrashGuard).
        if isStartingUp != guardsStartup {
            guardsStartup = isStartingUp
            if guardsStartup { CrashGuard.begin(.deviceStart) } else { CrashGuard.end(.deviceStart) }
        }
    }
    @ObservationIgnored private var guardsStartup = false

    var isSleeping = false
    /// The guest runs its vibration motor (an iPhone's), as of the last status poll; the display trembles with it.
    @ObservationIgnored private(set) var vibrating = false
    @ObservationIgnored private let vibrationSound = VibrationSound()
    /// The status poll's motor state: the buzz and the tremble follow it, and a paused or stopped device is still.
    func updateVibration(_ status: SharedStatus?) {
        let running = state == .running && status?.vibrating == true
        vibrating = running
        guard let status, !stopped else { return vibrationSound.stop() }
        vibrationSound.update(running: running, pulses: status.vibratorPulses)
    }
    /// The guest's front app, the web proxy reaching the guest, the end of Setup (ForegroundWatch).
    @ObservationIgnored private(set) lazy var foreground = ForegroundWatch(host: self)
    var foregroundAppName: String? { foreground.appName }
    /// This device's web proxy (DeviceWebProxy): its routing and certificate beside the device's own state.
    @ObservationIgnored private(set) lazy var proxy = DeviceWebProxy(
        directory: { [unowned self] in
            WebProxyConfiguration.directory(for: instance)
        },
        shortName: profile.shortName
    )
    var proxyDirectory: URL { proxy.directory }
    /// iPhone OS 1.x devices take the web proxy's CA while stopped (FirmwareTool.trustAnchor): no agent, no MCInstall.
    var trustsStopped: Bool { profile.trustsStopped }
    var webProxy: WebProxyConfiguration { proxy.configuration }
    var webProxyStatus: WebProxyStatus { proxy.status }
    var webProxyAvailable: Bool { proxy.available }
    func configureWebProxy(_ value: WebProxyConfiguration) throws { try proxy.configure(value) }
    /// This device's settings.plist (DeviceSettings), read once and written on every change.
    @ObservationIgnored private lazy var settingsFile = DeviceSettingsFile(directory: instance.paths.directory)
    typealias NoticeOperation = DeviceNotices.Operation
    @ObservationIgnored private(set) lazy var notices = DeviceNotices(
        settings: settingsFile,
        shortName: profile.shortName
    ) {
        [weak self] in self?.storageFailed ?? false
    }
    var deviceNotice: String? { notices.message }
    func reportDeviceNotice(_ message: String, for operation: NoticeOperation) {
        notices.report(message, for: operation)
    }
    /// The notice's remedy is Erase All Content and Settings (a refused
    /// overlay, an unfinished or failed erase, an unactivated guest).
    var deviceNoticeOffersErase: Bool { notices.offersErase }
    /// Boot refused: the overlay belongs to a different base image.
    var baseImageMismatch = false

    func dismissDeviceNotice() { notices.dismiss() }
    func resolveDeviceNotice(for operation: NoticeOperation) { notices.resolve(operation) }

    let bootScope = BootSessionScope()
    var bootGeneration: Int { bootScope.generation }
    /// Retired boots' services workers (Stop waits for them only so long).
    let workers = WorkerRetirement()
    var isPoweredOff: Bool { state == .poweredOff }

    @ObservationIgnored var reportedStorageFailure = false
    /// From the boot until SpringBoard answers over lockdown; the status line says where it is.
    @ObservationIgnored private(set) lazy var readiness: ReadinessWatch = {
        let readiness = ReadinessWatch(host: self, notices: notices)
        readiness.onPreparingChange = { [weak self] old in
            guard let self else { return }
            trackStartup(was: isErasing || state == .booting || old)
        }
        return readiness
    }()
    var preparingDevice: Bool { readiness.preparingDevice }
    var preparationStatus: String { readiness.preparationStatus }
    /// How far this boot has provably got (BootStage): the boot toast's subtitle.
    var bootStage: BootStage { readiness.bootStage }
    func noteBoot(_ event: BootStage.Event) { readiness.noteBoot(event) }
    var readinessFailure: String? { readiness.readinessFailure }

    /// The VM's lifecycle. Everything the UI enables or disables keys off this;
    /// `.dead` is the one that used to be invisible — QEMU would exit and the
    /// app kept a frozen frame with every control live.
    typealias VMState = LightTouchCore.VMState
    private(set) var state: VMState = .notStarted {
        didSet { trackStartup(was: isErasing || oldValue == .booting || preparingDevice) }
    }
    /// The one way `state` changes (VMState.transition(to:): its table, and why erasing and stopping aren't states).
    func transition(to next: VMState) {
        if next != state { Analytics.breadcrumb("\(profile.rawValue) \(next)") }
        state.transition(to: next)
    }

    /// Set by the inspector's poll: nil = never checked, true/false = last read.
    var deviceReachable: Bool? {
        didSet {
            // A service answered: nothing blocks commands any more, not even a stale activation issue.
            if deviceReachable == true { recovery.servicesAnswered() }
            if deviceReachable == true, reachableSince == nil {
                reachableSince = Date()
                Analytics.signal("Device.booted", analyticsParameters, value: Date().timeIntervalSince(poweredOn))
                startFileWatch()  // iOS is up: every file the helper depends on exists now
                checkGuestMounts()
                watchCrashReports()
            }
            recovery.consider()
            activation.checkIfNeeded()
            // Clean abandoned uploads when the guest first answers. The sweep
            // excludes this process’s session-tagged uploads even if it runs late.
            if deviceReachable == true, !didSweepStaging {
                didSweepStaging = true
                if let socket = usbmux.session?.clientSocket {
                    let endpoint = DeviceServices(clientSocket: socket, udid: guestUDID, session: bootScope.id)
                    bootScope[.staging] = Task { await endpoint.sweepStaging() }
                }
            }
        }
    }
    /// The Files window is copying files to or from this device (FilesConnection).
    var hasFileTransfer: Bool { FilesConnection.shared.isTransferring(instance.id) }
    var connectionIssue: DeviceConnectionIssue? { recovery.issue }

    /// The standing issue from failed service reads, and the recovery of an unresponsive management service.
    @ObservationIgnored private(set) lazy var recovery = ConnectionRecovery(host: self, notices: notices)
    var isReconnecting: Bool { recovery.isReconnecting }
    func reportConnectionFailure(_ error: Error, operation: String) {
        recovery.reportFailure(error, operation: operation)
    }
    var installerUsesDevice: Bool { AppInstaller.isUsingDevice(instance.id) }
    var guestAgentAlive: Bool { guestAgent.isAlive }
    func reconnectManagement() async throws { try await guest.reconnectManagement() }
    func appsMayHaveChanged() { NotificationCenter.default.post(name: .ltmAppsChanged, object: instance.id) }

    @ObservationIgnored var didSweepStaging = false

    /// The device record whose state this controller runs.
    var instance: DeviceInstance

    init(instance: DeviceInstance, profile: Board, network: Bool = true) {
        self.instance = instance
        self.profile = profile
        self.network = network
        let center = NSWorkspace.shared.notificationCenter
        hostSleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hostWillSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hostDidWake() }
            }
        ]
    }

    deinit { hostSleepObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver) }

    // MARK: - Mac sleep

    @ObservationIgnored nonisolated(unsafe) private var hostSleepObservers: [NSObjectProtocol] = []
    /// The Mac's sleep and the screen's visibility (HostPower).
    @ObservationIgnored lazy var hostPower = HostPower(host: self) { [weak self] in
        guard let self, statusTimer != nil else { return }
        startStatusPoll()
    }
    func hostWillSleep() { hostPower.hostWillSleep() }
    var countsBootTime: Bool { hostPower.countsBootTime }
    func hostDidWake() { hostPower.hostDidWake() }
    func resyncTimeZone() { timeZone.resync() }

    /// Per-user machine state (the NAND copy-on-write overlay, logs).
    var stateDir: URL { Bundled.stateDirectory }

    // MARK: - Helper

    /// This device's LightTouchDevice, from start() until the next restart.
    var process: DeviceProcess?
    /// Its link: status and frames (synchronous), commands and requests.
    var link: DeviceLink? { process?.link }
    /// The status block, read now; nil before the helper's first hello.
    var status: SharedStatus? { process?.status }
    /// The session replaces this controller with a fresh helper (DeviceSessionHost.restart).
    @ObservationIgnored var onRestartRequested: (() -> Void)?
    /// A restart asked for (onRestartRequested) won't happen: the view's free-form restart ends (C-4).
    @ObservationIgnored var onRestartRefused: (() -> Void)?
    @ObservationIgnored var onStorageGenerationChanged: (() -> Void)?
    /// The active recording's audio (GuestAudioCapture).
    @ObservationIgnored var audioSink: ((LinkEvent) -> Void)?
    @ObservationIgnored var statusTimer: Timer?
    @ObservationIgnored var lastFrameSerial: UInt64 = 0
    @ObservationIgnored var releasing = false
    @ObservationIgnored var admittedStorage: StorageBootProof?
    /// What this helper's boot was built with (BootSettings); Start after Shut Down compares it with the next.
    @ObservationIgnored var bootSettings: BootSettings?

    // MARK: - Boot
    @ObservationIgnored var fileWatch: DeviceFileWatch?
    /// Something deleted, renamed or replaced the device's files while its helper
    /// had them open: the guest runs on dead inodes until Stop, which then quits
    /// without flushing into them.
    var filesMeddled = false

    // MARK: - Boot deadline
    /// The boot deadline, recovery mode, a boot that can't be built and the helper's death (BootWatch).
    @ObservationIgnored private(set) lazy var bootWatch = BootWatch(host: self)
    /// The guest's zone and region follow the Mac's (TimeZoneSync).
    @ObservationIgnored lazy var timeZone = TimeZoneSync(host: self)

    // MARK: - Liveness
    /// When the guest last painted a new frame. Advanced by the status poll on
    /// every new ring serial; the signal behind `booting → running`.
    @ObservationIgnored var lastFrameAdvance = Date.distantPast
    /// The agent's ping (its ops), until it restarts.
    let agentCache = GuestAgentCache()
    /// When a reporting guest agent's session last ended (its report dropped): the agent died or was restarted.
    @ObservationIgnored var agentSessionEnded: Date?
    @ObservationIgnored var lastAgentStatusCheck = Date.distantPast
    var agentStatus = 0
    /// Set by the status poll: when the agent last went stale (2), nil while it answers.
    @ObservationIgnored var agentStaleSince: Date?
    /// When lockdown first answered this boot.
    @ObservationIgnored var reachableSince: Date?
    /// This boot ends in Setup, not the Home screen: iOS 5 or later on an overlay that hasn't finished it.
    var expectsSetup = false
    var inRecovery = false

    // MARK: - Input
    /// The hardware buttons, shake, tilt, pasting and typing (DeviceInput); the keyboard is KeyboardInput.
    @ObservationIgnored private(set) lazy var input = DeviceInput(host: self, settings: settingsFile)
    var compassHeading: Int?
    /// The quarter turns and auto-rotation with the guest (DeviceRotation).
    @ObservationIgnored private(set) lazy var rotation = DeviceRotation(
        host: self,
        settings: settingsFile,
        setsAccelerometer: profile.orientationSource == .springBoard
    )
    /// The fake network's settings and the running modem (CarrierModem).
    @ObservationIgnored private(set) lazy var carrier = CarrierModem(
        hasCellular: profile.hasCellular,
        settings: settingsFile,
        scope: bootScope
    ) { [weak self] in self?.link }

    /// Device ▸ Tweaks… (DeviceTweaks): applied by the foreground watch, the clock at each boot.
    @ObservationIgnored private(set) lazy var tweaks = DeviceTweaks(
        settings: settingsFile,
        version: iosVersion,
        guestTools: GuestPackage.runsAgent(firmware: instance.firmware),
        clockPinned: lock?.pinsClock == true,
        cellular: profile.hasCellular
    )

    /// Device ▸ Accessibility: what the guest last said is on (nil: not read this boot).
    @ObservationIgnored var accessibilityOn: Set<AccessibilityFeature>?

    // MARK: - Options
    /// Attach to Local Network, the debug port and the boot arguments (DeviceOptions).
    @ObservationIgnored private(set) lazy var options = DeviceOptions(settings: settingsFile, board: instance.board) {
        [weak self] in self?.link
    }
    /// This boot's offer and its verdict (GuestPackageWatch).
    @ObservationIgnored private(set) lazy var guestPackage = GuestPackageWatch(host: self, stateDirectory: stateDir)

    // MARK: - Keyboard passthrough
    /// Keyboard passthrough and Connect Hardware Keyboard (KeyboardInput), per device.
    @ObservationIgnored private(set) lazy var keyboard = KeyboardInput(
        settings: settingsFile,
        canToggleHardwareKeyboard: profile.canToggleHardwareKeyboard,
        control: { [weak self] request, done in self?.control(request, done) },
        send: { [weak self] command in self?.link?.send(command) },
        canPress: { [weak self] in self.map { $0.acceptsInput && !$0.isSleeping } ?? false }
    )

    // MARK: - Machine control
    /// Restart and Power On in place (BootCycle).
    @ObservationIgnored private(set) lazy var cycle = BootCycle(host: self)
    /// Stop, Force Stop and Shut Down (ShutdownLadder): Stop is a hard halt, never a guest shutdown.
    @ObservationIgnored private(set) lazy var ladder = ShutdownLadder(host: self)
    /// Erase All Content and Settings (DeviceErase).
    @ObservationIgnored lazy var eraser = DeviceErase(host: self)

    // MARK: - App management
    /// Reaching the device's services, installs and media imports, restarting the Home screen (DeviceApps).
    @ObservationIgnored private(set) lazy var apps = DeviceApps(host: self)
    /// The once-per-boot activation verdict (ActivationCheck).
    @ObservationIgnored private lazy var activation = ActivationCheck(
        host: self,
        services: self,
        recovery: recovery,
        readiness: readiness,
        notices: notices
    )

    // MARK: - Boot environment (DeviceOptions)

    static let verboseBootDefaultsKey = DeviceOptions.verboseBootDefaultsKey
    static var verboseBoot: Bool { UserDefaults.standard.bool(forKey: verboseBootDefaultsKey) }
    static let kernelConsoleDefaultsKey = DeviceOptions.kernelConsoleDefaultsKey
    static var kernelConsole: Bool { UserDefaults.standard.bool(forKey: kernelConsoleDefaultsKey) }
}

// The session's state machines (LightTouchCore/Session) run against the controller through these.
extension EmulatorController: MachineHost, ConnectionHost, ActivationServices, ReadinessHost, BootWatchHost,
    ShutdownHost, EraseHost, BootCycleHost, AppLaunchHost, RotationHost,
    InputHost, GuestPackageHost, TimeZoneHost, AppsHost,
    ForegroundHost
{
    var helper: DeviceHelper? { process }
    var helperLink: HelperLink? { link }
    var isPainting: Bool { state == .running }
    func readyForInput() { deviceReachable = true }
    /// The boot toast's subtitle: the storage update while boot admission runs one, then the boot's stage.
    var bootStageText: String {
        PreparedDeviceBoot.readMigrationProgress(lease: instance.paths.lease).map(PreparedDeviceBoot.migrationText)
            ?? bootStage.text(expectingSetup: expectsSetup)
    }
}
