// Created by Sam on 2026-08-05.
//
// Owns one device: builds its boot from the device record (a prepared base),
// starts its usbmuxd (for app management), then runs it in its own
// LightTouchDevice helper (DeviceProcess) and exposes input and app operations
// to the UI. Everything that used to be a direct call into the dylib crosses the
// helper's DeviceLink: status and frames are read from shared memory, input is a
// command, the rest are requests. One controller per boot: a restart is a new
// session (DeviceSessionHost.restart).

import Cocoa

@MainActor
final class EmulatorController {

    let profile: DeviceProfile
    /// Emulated Wi-Fi with the Mac's networking (slirp); off is a device with no internet.
    let network: Bool
    private let usbmux = USBMux()
    private var started = false
    private var serialCapture: SerialLogCapture?
    private var haltTask: Task<Void, Never>?
    private(set) var isErasing = false { didSet { onStatusChange?() } }
    private var haltCompletions: [(Bool) -> Void] = []
    /// Stop asked the helper to halt: its exit is Stopped, not a crash.
    private var halting = false
    private var poweringOn = false
    private(set) var shuttingDown = false { didSet { onStatusChange?() } }
    private(set) var isSleeping = false { didSet { if oldValue != isSleeping { onStatusChange?() } } }
    private(set) var foregroundAppName: String? { didSet { if oldValue != foregroundAppName { onStatusChange?() } } }
    /// Each device's proxy routing and certificate live beside its own state
    /// (WebProxyConfiguration.directory): the itwebproxy of one device's
    /// guestfwd never reads another's mode.
    private var proxyDirectory: URL { WebProxyConfiguration.directory(for: instance) }
    private(set) lazy var webProxy = WebProxyConfiguration.load(from: proxyDirectory)
    private(set) var webProxyStatus: WebProxyStatus = .waiting
    private var proxyRevision = 0
    private(set) var webProxyAvailable = false
    func configureWebProxy(_ value: WebProxyConfiguration) throws {
        guard webProxyAvailable else { throw DeviceToolsError.failed("The proxy is unavailable. Turn on the \(profile.shortName) and connect it to the internet.") }
        try value.save(in: proxyDirectory)
        webProxy = value
        proxyRevision += 1
        webProxyStatus = .waiting
        onStatusChange?()
    }
    enum NoticeOperation: String { case storage, preparation, erase, powerOff, lowSpace, activation, files }
    private(set) lazy var deviceNotice = UserDefaults.standard.dictionary(forKey: instance.defaultsKey("deviceNotice"))?["message"] as? String
    private lazy var noticeOperation = UserDefaults.standard.dictionary(forKey: instance.defaultsKey("deviceNotice"))?["operation"] as? String
    func reportDeviceNotice(_ message: String, for operation: NoticeOperation) {
        let value = storageFailed
            ? "Storage writes failed. The device is stopped and recent changes were not saved. Free disk space, then reopen Light Touch. Open Device Logs for details."
            : message
        logEvent(value)
        deviceNotice = value
        let kind = (storageFailed ? .storage : operation).rawValue
        noticeOperation = kind
        UserDefaults.standard.set(["message": value, "operation": kind], forKey: instance.defaultsKey("deviceNotice"))
        onStatusChange?()
    }
    /// The notice's remedy is Erase All Content and Settings (a refused
    /// overlay, an unfinished or failed erase, an unactivated guest).
    var deviceNoticeOffersErase: Bool {
        [NoticeOperation.erase.rawValue, NoticeOperation.activation.rawValue].contains(noticeOperation) && !storageFailed
    }
    /// Boot refused: the overlay belongs to a different base image.
    private(set) var baseImageMismatch = false

    func dismissDeviceNotice() {
        guard !storageFailed else { return }
        deviceNotice = nil
        noticeOperation = nil
        UserDefaults.standard.removeObject(forKey: instance.defaultsKey("deviceNotice"))
        onStatusChange?()
    }

    func resolveDeviceNotice(for operation: NoticeOperation) {
        if noticeOperation == operation.rawValue { dismissDeviceNotice() }
    }

    private var foregroundTask: Task<Void, Never>?
    private var bootGeneration = 0
    var isPoweredOff: Bool { state == .poweredOff }

    private var reportedStorageFailure = false
    private var readinessTask: Task<Void, Never>?
    /// From the boot until SpringBoard answers over lockdown (startReadinessWatch); the status line says where it is.
    private(set) var preparingDevice = false {
        didSet { onStatusChange?() }
    }
    private(set) var preparationStatus = "Starting iOS…" { didSet { onStatusChange?() } }
    private var readinessFailure: String?


    /// The VM's lifecycle. Everything the UI enables or disables keys off this;
    /// `.dead` is the one that used to be invisible — QEMU would exit and the
    /// app kept a frozen frame with every control live.
    enum VMState: Equatable {
        case notStarted, booting, running, paused, poweredOff
        case dead(exitCode: Int32?)
    }
    private(set) var state: VMState = .notStarted {
        didSet { if oldValue != state { onStatusChange?() } }
    }

    /// Fired on any health-relevant change — a state transition, usbmuxd dying,
    /// device reachability flipping. Pull model: the observer reads `state`,
    /// `canManageApps`, and `statusLine` fresh. One callback, not three.
    var onStatusChange: (() -> Void)?

    /// Set by the inspector's poll: nil = never checked, true/false = last read.
    var deviceReachable: Bool? {
        didSet {
            if deviceReachable == true, connectionIssue?.persistent != true { connectionIssue = nil }
            if deviceReachable == true, reachableSince == nil {
                reachableSince = Date()
                startFileWatch()   // iOS is up: every file the helper depends on exists now
            }
            if oldValue != deviceReachable { onStatusChange?() }
            considerConnectionRecovery()
            checkActivationIfNeeded()
            // Clean abandoned uploads when the guest first answers. The sweep
            // excludes this process’s session-tagged uploads even if it runs late.
            if deviceReachable == true, !didSweepStaging {
                didSweepStaging = true
                if let socket = usbmux.session?.clientSocket {
                    Task { await DeviceServices(clientSocket: socket).sweepStaging() }
                }
            }
        }
    }
    var hasFileTransfer = false
    private(set) var connectionIssue: DeviceConnectionIssue?

    func reportConnectionFailure(_ error: Error, operation: String) {
        guard let issue = DeviceConnectionIssue(error: error, operation: operation, profile: profile) else { return }
        // An unactivated guest stays that way for the boot; a transient failure doesn't replace the message.
        if connectionIssue?.persistent == true, !issue.persistent { return }
        if connectionIssue != issue {
            logEvent("device connection: \(issue.detail); USB=\(usbConnected), agent=\(liveAgentStatus), blocked requests=\(AbandonedWork.count)")
        }
        connectionIssue = issue
        if issue.blocksCommands {
            deviceReachable = false
        } else {
            // installd can be busy with a deletion made on the iPod itself.
            // Killing lockdownd during that transition only makes it worse.
            connectionFailures = 0
        }
        onStatusChange?()
    }
    private var connectionFailures = 0
    private var connectionRecoveryTask: Task<Void, Never>?
    private var lastConnectionRecovery = Date.distantPast
    private(set) var isReconnecting = false { didSet { onStatusChange?() } }

    /// A transient installd transition is not a dead device. If repeated reads
    /// fail, reopen the management service through the independent guest agent.
    /// Never reboot the iPod or touch its applications to repair a connection.
    private func considerConnectionRecovery() {
        if deviceReachable == true { connectionFailures = 0; return }
        guard deviceReachable == false, isRunning, !preparingDevice,
              connectionIssue?.reconnectManagement == true else { return }
        connectionFailures += 1
        guard connectionFailures >= 2, connectionRecoveryTask == nil,
              !isInstalling, !hasFileTransfer, !AppInstaller.isUsingDevice(instance.id), liveAgentStatus == 1,
              Date().timeIntervalSince(lastConnectionRecovery) >= 60 else { return }
        lastConnectionRecovery = Date()
        connectionFailures = 0
        isReconnecting = true
        connectionRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { connectionRecoveryTask = nil; isReconnecting = false }
            do {
                guard isRunning, !preparingDevice, !isInstalling, !hasFileTransfer, !AppInstaller.isUsingDevice(instance.id) else { return }
                if try await DeviceTools.reconnectManagementService(agent: link, cache: agentCache) {
                    logEvent("device: restarted unresponsive management service; reconnecting")
                    try await Task.sleep(for: .seconds(2))
                    guard isRunning else { return }
                    NotificationCenter.default.post(name: .ltmAppsChanged, object: instance.id)
                }
            } catch {
                if !Task.isCancelled { logEvent("device: connection recovery failed: \(error.localizedDescription)") }
            }
        }
    }

    private var didSweepStaging = false

    /// The device record whose state this controller runs.
    let instance: DeviceInstance

    init(instance: DeviceInstance, profile: DeviceProfile, network: Bool = true) {
        self.instance = instance
        self.profile = profile
        self.network = network
        usbmux.onUnexpectedExit = { [weak self] in self?.onStatusChange?() }
    }

    /// Per-user machine state (the NAND copy-on-write overlay, logs).
    private var stateDir: URL { Bundled.stateDirectory }

    // MARK: - Helper

    /// This device's LightTouchDevice, from start() until the next restart.
    private(set) var process: DeviceProcess?
    /// Its link: status and frames (synchronous), commands and requests.
    var link: DeviceLink? { process?.link }
    /// The status block, read now; nil before the helper's first hello.
    var status: SharedStatus? { process?.status }
    /// Why the helper died, for the row and the dead overlay.
    private(set) var deathReason: String?
    /// The session replaces this controller with a fresh helper (DeviceSessionHost.restart).
    var onRestartRequested: (() -> Void)?
    /// The active recording's audio (GuestAudioCapture).
    var audioSink: ((LinkEvent) -> Void)?
    private var statusTimer: Timer?
    private var lastFrameSerial: UInt64 = 0
    private var releasing = false

    // MARK: - Boot

    func start() {
        guard !started else { return }
        do { try Bundled.requireStorage() }
        catch {
            logEvent("storage: \(error.localizedDescription)")
            state = .dead(exitCode: 1)
            return
        }
        started = true
        state = .booting
        resolveDeviceNotice(for: .files)   // a fresh helper opens the files as they are now
        let process = DeviceProcess(instance: instance.id, profile: profile,
                                    log: instance.paths.logs.appendingPathComponent("native.log"),
                                    lease: instance.paths.lease)
        self.process = process
        lastFrameSerial = 0
        process.onDeath = { [weak self, weak process] reason in
            guard let self, let process, self.process === process else { return }
            helperDied(reason)
        }
        process.onAudio = { [weak self] event in self?.audioSink?(event) }
        startStatusPoll()
        // Low space doesn't stop a boot; it's said before writes start failing.
        warnIfLowOnSpace()
        // The boot is built after the hello: usbmuxd must listen before the guest's USB.
        process.start({ [weak self] _ in self?.bootConfiguration() }) { [weak self] result in
            if case let .failure(error) = result, let self { logEvent("boot: \(instance.name): \(error)") }
        }
        startReadinessWatch()
        if hasGuestTools {
            startOrientationWatch()   // idle until the guest is up and reachable
        } else {
            startInterfaceOrientationWatch()
        }
        startTimeZoneSync()       // guest zone follows the Mac's, incl. travel
        startForegroundWatch()
        // The guest-package watch starts in bootConfiguration(), once this boot's offer is composed.
    }

    /// nil when the device can't boot; the notice says why and the state is dead.
    private func bootConfiguration() -> BootConfig? {
        guard !isDead, !releasing else { return nil }
        let config = profile == .iPad1 ? iPadBoot() : iPodBoot()
        if config != nil {
            logEmulatorBuild()
            startGuestPackageWatch()  // after composeGuestOffer(): a watch with no offer judges nothing
            startBootWatch()
        }
        return config
    }

    /// The overlay only fits the base it was made on (DeviceStateStorage.pinOverlay); a
    /// refusal is a dead boot whose notice offers Erase.
    private func pinOverlay(_ overlay: URL) throws -> Bool {
        guard try DeviceStateStorage.pinOverlay(overlay, toBase: instance.storage.key) else {
            baseImageMismatch = true
            reportDeviceNotice("This \(profile.shortName)'s data was made with an older system image.", for: .erase)
            state = .dead(exitCode: 1)
            return false
        }
        return true
    }

    /// The iPod boots its base/ (firmwarekit's n72 recipe): iBoot.bin, nor.bin with a private
    /// writable copy, gid-blobs.bin (the emulated AES has no GID key) and nand/, with the machine
    /// options its lock names, over the shipped bootrom (Bundled.filesRoot) and this device's
    /// copy-on-write overlay.
    private func iPodBoot() -> BootConfig? {
        let overlay = overlayURL
        let base = instance.paths.base
        let lock = base.appendingPathComponent("device.lock.json")
        let files: (boot: URL, nand: URL, writableNOR: URL?)
        do {
            let boot = profile.preparedBoot(strategy: BootRecipe.bootStrategy(lock))
            files = try BootRecipe.preparedFiles(base: base, overlay: overlay, writableNOR: instance.paths.writableNOR,
                                                 boot: boot.boot, also: boot.files)
            guard files.writableNOR != nil else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "writable NOR"]) }
            guard try pinOverlay(overlay) else { return nil }
        } catch {
            failBoot(error)
            return nil
        }
        // usbmuxd must be listening before the guest USB core comes up.
        let usbSession = usbmux.start(paths: instance.paths)
        openSerialLog()
        let netdev = network ? "user,id=wifi0" + (proxyForward() ?? "") : nil
        return BootRecipe.iPod(.init(bootArgs: Self.bootArgs, iBoot: files.boot.path, bootrom: "\(Bundled.filesRoot)/bootrom_240_4",
                                     nand: files.nand.path, nor: base.appendingPathComponent("nor.bin").path,
                                     writableNOR: files.writableNOR!.path, overlay: overlay.path,
                                     usbAddress: usbSession?.guestAddress, wifi: network,
                                     gidBlobs: base.appendingPathComponent("gid-blobs.bin").path, guestPackage: composeGuestOffer(),
                                     machineOptions: BootRecipe.lockMachine(lock)),
                               serial: serialCapture?.argument ?? "null",
                               audio: ["-audio", "driver=coreaudio,out.buffer-count=16"],
                               netdev: netdev, restore: [])
    }

    /// iPad 1 boots its base/ by the lock's boot_strategy: iboot (default) = iBoot.bin + nor.bin +
    /// gid-blobs.bin, kboot (the two older prepared iPads) = kboot.bin; both over a private writable
    /// NOR clone, its die id and this device's copy-on-write overlay (so Erase is "delete the overlay",
    /// as for the iPod). USB goes to the device's usbmuxd bridge; host keys to an emulated USB keyboard.
    private func iPadBoot() -> BootConfig? {
        let overlay = overlayURL
        let lock = instance.paths.base.appendingPathComponent("device.lock.json")
        let strategy = BootRecipe.bootStrategy(lock)
        let files: (boot: URL, nand: URL, writableNOR: URL?)
        do {
            let boot = profile.preparedBoot(strategy: strategy)
            files = try BootRecipe.preparedFiles(base: instance.paths.base, overlay: overlay,
                                                 writableNOR: instance.paths.writableNOR, boot: boot.boot, also: boot.files)
            guard try pinOverlay(overlay) else { return nil }
        } catch {
            failBoot(error)
            return nil
        }
        let usbSession = usbmux.start(paths: instance.paths)
        openSerialLog()
        // The web proxy, as on the iPod: itwebproxy on a slirp guestfwd at 10.0.2.100:3128. This
        // explicit wifi0 replaces the machine's own. The image's Wi-Fi service carries a PAC that
        // uses the proxy and falls back to DIRECT, so Proxy off is purely host-side (itwebproxy "off").
        let netdev = network ? proxyForward().map { "user,id=wifi0" + $0 } : nil
        return BootRecipe.iPad(.init(kboot: files.boot.path, nand: files.nand.path, overlay: overlay.path, dieID: instance.identity?.dieID,
                                     writableNOR: files.writableNOR?.path,
                                     gidBlobs: strategy == "iboot" ? instance.paths.base.appendingPathComponent("gid-blobs.bin").path : nil,
                                     usbAddress: usbSession?.guestAddress, wifi: network,
                                     guestPackage: composeGuestOffer(), machineOptions: BootRecipe.lockMachine(lock)),
                               serial: serialCapture?.argument ?? "null", audio: [], netdev: netdev, restore: [])
    }

    private func openSerialLog() {
        do {
            serialCapture = try SerialLogCapture(url: instance.paths.logs.appendingPathComponent("serial.log"),
                                                 watch: [Self.recoveryMarker, Self.ethlinkMarker]) { [weak self] phrase in
                Task { @MainActor in
                    guard let self else { return }
                    if phrase == Self.ethlinkMarker { self.ethlinkUp = true; self.onStatusChange?(); return }
                    self.inRecovery = true
                    self.abortBoot(Self.recoveryReason(self.profile))
                }
            }
        } catch { logEvent("logging: serial capture unavailable: \(error.localizedDescription)") }
    }

    // MARK: - Files under a running device

    private var fileWatch: DeviceFileWatch?
    /// Something deleted, renamed or replaced the device's files while its helper
    /// had them open: the guest runs on dead inodes until Stop, which then quits
    /// without flushing into them.
    private(set) var filesMeddled = false

    private func startFileWatch() {
        guard fileWatch == nil, !filesMeddled else { return }
        let paths = instance.paths
        fileWatch = DeviceFileWatch(directories: [paths.directory, paths.overlay], base: paths.base) { [weak self] path in
            Task { @MainActor in self?.filesChanged(path) }
        }
    }

    private func filesChanged(_ path: String) {
        guard !filesMeddled, !isDead, !isPoweredOff else { return }
        filesMeddled = true
        fileWatch = nil
        logEvent("files: \(path) changed under the running device; Stop will quit without a flush")
        reportDeviceNotice(DeviceFileWatch.notice(shortName: profile.shortName), for: .files)
    }

    // MARK: - Boot deadline

    /// iBoot's last words before it waits for a restore.
    static let recoveryMarker = "Entering recovery mode"
    /// it_ethlink (the iPad's guest package) bringing the USB Ethernet link up.
    static let ethlinkMarker = "it_ethlink: LinkStatus 0 -> 1"
    static func recoveryReason(_ profile: DeviceProfile) -> String {
        "The \(profile.shortName) entered recovery mode instead of starting iOS. Delete it and prepare it again. Open Device Logs for details."
    }
    static func deadlineReason(_ profile: DeviceProfile) -> String {
        "The \(profile.shortName) didn’t start within \(Int(profile.bootBudget)) seconds. Open Device Logs for details."
    }
    /// A boot file the base lacks (BootRecipe.preparedFiles), else the storage error as it is.
    static func bootFilesReason(_ error: Error, profile: DeviceProfile) -> String {
        if let cocoa = error as? CocoaError, cocoa.code == .fileNoSuchFile, let path = cocoa.userInfo[NSFilePathErrorKey] as? String {
            return "This \(profile.shortName)’s system files are incomplete: \(URL(fileURLWithPath: path).lastPathComponent) is missing. Delete it and prepare it again."
        }
        return "Could not prepare device storage: \(error.localizedDescription)"
    }

    /// The boot can't be built: dead with a named reason (the row and the overlay show it).
    private func failBoot(_ error: Error) {
        let reason = Self.bootFilesReason(error, profile: profile)
        deathReason = reason
        reportDeviceNotice(reason, for: .storage)
        state = .dead(exitCode: 1)
    }

    private var bootWatchTask: Task<Void, Never>?

    /// iOS is up: lockdown answered (the helper's uiReady is QEMU's display, lit
    /// by iBoot too). Without a USB bridge (--no-appsync) painting has to do.
    private var bootFinished: Bool { deviceReachable == true || (usbmux.session == nil && state == .running) }

    /// Never "Booting…" forever: no answer within the board's budget ends the
    /// boot as a named error, with the helper halted. Per boot (also after
    /// Power On and Restart).
    private func startBootWatch() {
        bootWatchTask?.cancel()
        let generation = bootGeneration
        bootWatchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.profile.bootBudget ?? 0))
            guard let self, !Task.isCancelled, generation == bootGeneration, !bootFinished else { return }
            abortBoot(Self.deadlineReason(profile))
        }
    }

    /// The guest will not come up (recovery mode, or out of time): halt the
    /// helper and become `.dead` with `reason`; the row offers Start again.
    private func abortBoot(_ reason: String) {
        guard !isDead, !isPoweredOff, !shuttingDown, !halting, let process, !process.isDead else { return }
        logEvent("boot: \(reason)")
        deathReason = reason
        bootWatchTask?.cancel()
        process.terminate()
        Task {
            if await !process.waitForExit(timeout: Self.haltBudget) { process.kill() }
        }
    }

    /// The guestfwd for itwebproxy, reading this device's routing file; nil
    /// when the helper is missing or the routing can't be written.
    private func proxyForward() -> String? {
        guard let helper = Bundled.resolve("itwebproxy", fallbacks: ["\(Bundled.filesRoot)/../qemu-ios/contrib/it-webproxy/itwebproxy"]) else { return nil }
        do {
            try webProxy.writeRouting(in: proxyDirectory)
            webProxyAvailable = true
            return WebProxyConfiguration.guestForward(helper: helper, directory: proxyDirectory)
        } catch {
            webProxyStatus = .failed
            logEvent("proxy routing: \(error.localizedDescription)")
            return nil
        }
    }

    /// Status is read from the helper's shared block: the old per-frame poll,
    /// now on its own timer so a hidden device (no display link) still flips
    /// booting -> running, notices storage failures and its power-off.
    private func startStatusPoll() {
        statusTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollStorageFailure() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    /// For a restart: stop this device's tasks and usbmuxd, kill its helper if
    /// it is still running, and wait until it is gone. False if it would not exit.
    func release() async -> Bool {
        releasing = true
        stop()
        guard let process, process.link.pid > 0 else { return true }
        if !process.isDead { process.kill() }
        return await process.waitForExit(timeout: 10)
    }

    /// The iPod machine has the guest agent's channel; a stock iPad has none,
    /// so its media import and agent extras are skipped.
    var hasGuestTools: Bool { profile.hasGuestTools }

    /// The boot's readiness steps, shown as the startup status until the Home
    /// screen answers: lockdown, then SpringBoard.
    private func startReadinessWatch() {
        guard !shuttingDown else { return }
        readinessTask?.cancel()
        preparingDevice = true
        preparationStatus = "Starting iOS…"
        readinessFailure = nil
        let generation = bootGeneration
        readinessTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.bootGeneration { self.preparingDevice = false } }
            do {
                let deadline = ContinuousClock.now + .seconds(profile.bootBudget)
                while true {
                    try Task.checkCancellation()
                    guard generation == bootGeneration else { return }
                    guard !isDead, !storageFailed, ContinuousClock.now < deadline else {
                        throw DeviceToolsError.failed("The device did not become ready.")
                    }
                    if state == .running, await deviceReady() { break }
                    try await Task.sleep(for: .milliseconds(250))
                }
                try Task.checkCancellation()
                guard generation == bootGeneration else { return }
                preparationStatus = "Waiting for the Home screen…"
                // A framebuffer and lockdown can both respond while SpringBoard
                // is still starting. Do not enable input until its service answers.
                try await waitForSpringBoard()
                try Task.checkCancellation()
                guard generation == bootGeneration else { return }
                // Read the emulated backlight, not sblaunch's optional lock
                // query: older bundled images do not implement that command.
                // Home is safe while the display is off; an awake Home screen
                // must not receive it (that would open Spotlight). Once per boot.
                guard !isDead, !shuttingDown else { return }
                if status?.displaySleeping == true {
                    logEvent("boot: waking the display after device preparation")
                    pressHome()
                    for _ in 0..<20 {
                        try await Task.sleep(for: .milliseconds(100))
                        guard generation == bootGeneration, !isDead, !shuttingDown else { return }
                        if status?.displaySleeping != true { break }
                    }
                }
                try Task.checkCancellation()
                guard generation == bootGeneration, !isDead, !shuttingDown else { return }
                logEvent("boot: ready for input")
                // SpringBoard answered over lockdown: a real round trip, so the device is reachable
                // without waiting for the Apps inspector's poll (the foreground watch, web proxy and
                // guest-package verdict key off it).
                deviceReachable = true
                resolveDeviceNotice(for: .preparation)
            } catch {
                if !Task.isCancelled, generation == bootGeneration {
                    readinessFailure = error.localizedDescription
                    reportDeviceNotice("The device didn’t finish starting. Restart it to try again; open Device Logs for details.", for: .preparation)
                    logEvent("boot: readiness failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Keep the guest's timezone matched to the Mac's: once when the device
    /// first answers after this boot, and again whenever the host's zone
    /// changes (travel). Set through lockdown's TimeZone value — lockdownd
    /// rewrites /var/db/timezone/localtime and SpringBoard follows live, so
    /// no respring. The guest's clock itself is UTC from the RTC model; only
    /// the zone needs the host's help — unless the catalog entry pins a
    /// `clock` (a developer build inside its validity window): that date is set
    /// once per boot, and later zone syncs keep the guest's time as it is.
    private func startTimeZoneSync() {
        NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange,
                                               object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in await self?.syncTimeZoneWhenReady() }
        }
        Task { [weak self] in await self?.syncTimeZoneWhenReady() }
    }

    /// Wait out the boot (services come up well after lockdown answers), then
    /// set until one attempt sticks — a transient "Invalid service" right
    /// after boot just means the next 5 s tick tries again. Idempotent, so an
    /// overlapping run is harmless.
    private func syncTimeZoneWhenReady() async {
        while !Task.isCancelled {
            guard !shuttingDown, !isDead, !isPoweredOff else { return }
            let clock = catalogEntry?.clockEpoch.map { clockPinned ? "keep" : String(Int($0)) }
            if state == .running, !preparingDevice, canManageApps, await deviceReady(),
               (try? await tools().setTimeZone(TimeZone.current.identifier, clock: clock)) != nil {
                if clock != nil { clockPinned = true }
                return
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// This boot's pinned clock has been set (catalogEntry.clock); later syncs pass "keep".
    private var clockPinned = false

    /// App quit (after the clean shutdowns) and restarts. The helper gets
    /// SIGTERM: a guest that already powered off quits at once; one that
    /// didn't gets the helper's own bounded clean shutdown after we are gone.
    func stop() {
        connectionRecoveryTask?.cancel()
        statusTimer?.invalidate()
        statusTimer = nil
        process?.terminate()
        fileWatch = nil
        // Unlink the owned FIFO paths now, keeping readers alive until the
        // helper is finished writing.
        serialCapture?.removeEndpoints()
        bootWatchTask?.cancel()
        readinessTask?.cancel()
        foregroundTask?.cancel()
        guestPackageTask?.cancel()
        orientationTask?.cancel()
        orientationTask = nil
        usbmux.stop()
    }

    /// Booting and recording: a notice (non-blocking) below 2 GB free, gone once there's room.
    func warnIfLowOnSpace() {
        if let warning = IPSWStore.lowSpaceWarning(at: stateDir) { reportDeviceNotice(warning, for: .lowSpace) }
        else { resolveDeviceNotice(for: .lowSpace) }
    }

    /// The helper is gone (QEMU returned, it crashed or was killed). Flip to
    /// `.dead`; the window shows a Restart overlay, and the other devices keep running.
    private func helperDied(_ reason: String) {
        guard !isDead else { return }
        if !halting, deathReason == nil { deathReason = reason }   // an aborted boot keeps its own reason
        bootWatchTask?.cancel()
        fileWatch = nil
        statusTimer?.invalidate()
        statusTimer = nil
        audioSink?(.audioEnded(generation: 0, failed: true))
        readinessTask?.cancel()
        foregroundTask?.cancel()
        orientationTask?.cancel()
        orientationTask = nil
        usbmux.stop()
        serialCapture?.finish()
        serialCapture = nil
        state = halting ? .poweredOff : .dead(exitCode: nil)
    }

    // MARK: - Liveness

    /// When the guest last painted a new frame. Advanced by the status poll on
    /// every new ring serial; the signal behind `booting → running`.
    private(set) var lastFrameAdvance = Date.distantPast

    private func noteFrameAdvanced() {
        lastFrameAdvance = Date()
        if state == .booting, !poweringOn { state = .running }
    }

    /// Frames within the last ~2s. Not sufficient alone for "healthy": a
    /// locked/idle device legitimately stops painting.
    var framesRecentlyAdvanced: Bool {
        Date().timeIntervalSince(lastFrameAdvance) < 2.0
    }

    var storageFailed: Bool { status?.storageFailed ?? false }
    /// The guest agent, live: 0 absent or not running, 1 alive, 2 stale.
    var liveAgentStatus: Int { status?.agentStatus ?? 0 }

    /// The agent's ping (its ops), until it restarts.
    let agentCache = GuestAgentCache()
    private var lastAgentStatusCheck = Date.distantPast
    private var agentStatus = 0
    var agentStatusText: String {
        guard state == .running || state == .paused else { return "Waiting for device" }
        return agentStatus == 1 ? "Connected" : agentStatus == 2 ? "Not responding" : "Unavailable"
    }

    func pollStorageFailure() {
        guard let status else { return }
        if status.frameSerial != lastFrameSerial {
            lastFrameSerial = status.frameSerial
            noteFrameAdvanced()
        }
        let now = Date()
        if now.timeIntervalSince(lastAgentStatusCheck) >= 1 {
            lastAgentStatusCheck = now
            if status.agentStatus != agentStatus {
                // A restarted agent may be a different version: ping it again.
                agentCache.reset()
                agentStatus = status.agentStatus
                onStatusChange?()
            }
            if status.agentStatus == 2 { agentStaleSince = agentStaleSince ?? now } else { agentStaleSince = nil }
        }
        if !poweringOn, status.shutdownConfirmed, !isDead, !isPoweredOff {
            // Publish terminal state before observable fields: their callbacks
            // must never render a stale running/sleeping subtitle mid-shutdown.
            state = .poweredOff
            foregroundTask?.cancel()
            foregroundAppName = nil
            isSleeping = false
            deviceReachable = false
        }
        if state == .running, !preparingDevice, !shuttingDown {
            isSleeping = status.displaySleeping
        } else if isSleeping {
            isSleeping = false
        }

        if storageFailed, !reportedStorageFailure {
            reportedStorageFailure = true
            reportDeviceNotice(statusLine, for: .storage)
        }
    }

    var isRunning: Bool { state == .running && !storageFailed && !preparingDevice && readinessFailure == nil && !restartingSpringBoard && !shuttingDown && !isErasing }
    var isPaused:  Bool { state == .paused }
    var isDead:    Bool { if case .dead = state { return true } else { return false } }
    /// The guest can take input only while actually executing.
    var acceptsInput: Bool { isRunning }

    /// One line for the window's status area.
    var statusLine: String {
        if isErasing { return "Erasing \(profile.shortName)…" }
        if storageFailed { return "Storage write failed — device stopped; latest changes were not saved" }
        if shuttingDown, !isPoweredOff { return "Stopping…" }
        switch state {
        case .poweredOff: return "Powered Off"
        case .notStarted: return "Starting…"
        case .booting:    return "Booting…"
        case .running:
            if let issue = connectionIssue, issue.persistent { return issue.summary }
            if preparingDevice { return preparationStatus }
            if isSleeping { return "Sleeping" }
            if restartingSpringBoard { return "Restarting SpringBoard…" }
            if let readinessFailure { return "Startup failed — \(readinessFailure)" }
            guard canManageApps else { return "Running — USB unavailable" }
            return "Running — " + guestToolsLine
        case .paused:     return "Paused"
        case .dead:       return "Emulator stopped"
        }
    }

    /// The "Guest tools" line: the loader's report as the package watch judged it
    /// (GuestPackage.status), overridden by what the boot and the agent show now.
    var guestToolsLine: String { "Guest tools: " + guestToolsState.text }
    var guestToolsState: GuestPackage.Status {
        if inRecovery { return .recovery }
        if !bootFinished { return .notBooted }
        let stale = agentStaleSince.map { Date().timeIntervalSince($0) > 60 } ?? false
        let reachable = reachableSince.map { Date().timeIntervalSince($0) > 60 } ?? false
        // The iPad has no agent: it_ethlink's serial line is its sign of life once a package with jobs runs.
        let ethlinkMissing = !hasGuestTools && guestOffer?.serial ?? 0 > 0 && (status?.guestPackage?.serial ?? 0) > 0 && !ethlinkUp && reachable
        if hasGuestTools ? stale : ethlinkMissing { return .notResponding }
        return guestToolsStatus
    }
    /// Set by the status poll: when the agent last went stale (2), nil while it answers.
    private var agentStaleSince: Date?
    /// When lockdown first answered this boot.
    private var reachableSince: Date?
    /// it_ethlink reported LinkStatus 0 -> 1 on serial (the iPad's guest package).
    private(set) var ethlinkUp = false
    private var inRecovery = false

    /// Which libqemu-arm.dylib this device's helper loaded, and when it was
    /// built (its hello). The dylib lives in a build tree other sessions rebuild
    /// under our feet; when "did this run have that fix?" comes up, this answers it.
    var dylibProvenance: String {
        guard let info = process?.info else { return "dylib: helper not connected" }
        return "dylib: \(info.dylibPath) (built \(Date(timeIntervalSince1970: info.dylibModified)), build \(info.buildID ?? "unknown"))"
    }

    private func logEmulatorBuild() { logEvent("emulator \(dylibProvenance)") }
    
    // MARK: - Hardware buttons
    
    private var restartingSpringBoard = false {
        didSet { onStatusChange?() }
    }

    private static let holdInterval: TimeInterval = 0.10
    
    /// The emulator's button numbers (qemu-ios-ui.h).
    enum Button: Int { case home = 0, power, volumeUp, volumeDown }

    private func tapButton(_ button: Button) {
        guard let link else { return }
        link.send(.button(button.rawValue, down: true))
        // Release off the main queue (send is thread-safe and ordered), so a
        // stalled main runloop must not be what holds a hardware button down.
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.holdInterval) {
            link.send(.button(button.rawValue, down: false))
        }
    }
    
    func pressHome()       { tapButton(.home) }
    func pressLock()       { tapButton(.power) }
    func pressVolumeUp()   { tapButton(.volumeUp) }
    func pressVolumeDown() { tapButton(.volumeDown) }
    func rotateLeft()      { link?.send(.rotate(clockwise: false)) }
    func rotateRight()     { link?.send(.rotate(clockwise: true)) }
    private(set) var shakeGeneration: UInt64 = 0
    func shake() {
        link?.send(.shake)
        shakeGeneration &+= 1
    }

    /// A control request; `done(true)` when the machine applied it (false on a
    /// machine without the control, the iPod, or from a helper that's gone).
    private func control(_ request: LinkRequest, _ done: @escaping (Bool) -> Void = { _ in }) {
        guard let link else { return done(false) }
        link.request(request) { reply in
            MainActor.assumeIsolated {
                if case .success(.ok(true)) = reply { done(true) } else { done(false) }
            }
        }
    }
    // MARK: Battery, charger and compass
    //
    // The emulator can't be asked for these, so what the app last set is the
    // menu's state. nil level = the machine's own default until one is chosen.
    private(set) var batteryLevel: Int?
    /// 0 automatic (the power source decides from the host's current), 1 on, 2 off.
    private(set) var batteryCharging: Int32 = 0
    func setBattery(level: Int? = nil, charging: Int32? = nil) {
        let level = level ?? batteryLevel ?? 80
        let charging = charging ?? batteryCharging
        control(.battery(level: level, charging: Int(charging))) { [weak self] applied in
            guard applied, let self else { return }
            batteryLevel = level
            batteryCharging = charging
        }
    }

    /// Whether the built-in USB host grants a high-power port's current. The
    /// usbmuxd bridge always does, as a Mac does, so this only matters with
    /// app management off (--no-appsync).
    private(set) var highPowerUSB = true
    var canChooseUSBCharger: Bool { usbmux.session == nil && profile.canChooseUSBCharger }
    func setHighPowerUSB(_ on: Bool) {
        control(.usbCharger(on)) { [weak self] applied in
            guard applied, let self else { return }
            highPowerUSB = on
            // The host grants current at enumeration: replug so it asks again.
            control(.usbConnection(false)) { [weak self] unplugged in
                guard unplugged else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.control(.usbConnection(true)) }
            }
        }
    }

    private(set) var compassHeading: Int?
    var hasCompass: Bool { profile.hasCompass }
    func setCompassHeading(_ degrees: Int) {
        control(.compass(degrees)) { [weak self] applied in if applied { self?.compassHeading = degrees } }
    }
    // Location comes later (a4-iboot's location responder); it will sit here
    // beside the compass as another control request.

    private(set) var usbConnected = true
    private func reconnectUSB() {
        guard !usbConnected else { return }
        control(.usbConnection(true)) { [weak self] attached in
            guard attached, let self else { return }
            usbConnected = true
            deviceReachable = nil
        }
    }
    enum MotionPose: Int { case upright, flat }
    private(set) lazy var motionPose = MotionPose(rawValue: UserDefaults.standard.integer(forKey: instance.defaultsKey("motionPose"))) ?? .upright
    func setMotionPose(_ pose: MotionPose) {
        motionPose = pose
        UserDefaults.standard.set(pose.rawValue, forKey: instance.defaultsKey("motionPose"))
        onStatusChange?()
    }

    /// Layer rotation and mounted device roll have opposite signs. Normalize
    /// across the upside-down seam before passing degrees to the shared model.
    func setTilt(angle: Double, pitch: Double = 0) {
        guard acceptsInput, !isSleeping else { return }
        let roll = -atan2(sin(angle), cos(angle)) * 180 / .pi
        link?.send(.attitude(pitch: pitch * 180 / .pi, roll: roll, pose: motionPose.rawValue))
    }

    /// The device's orientation as degrees turned clockwise from portrait —
    /// the same value the LCD model calls its rotation, stepped in lockstep
    /// with the guest's own quarter-turn cycle (ipod_touch_kbd_rotate:
    /// portrait → landscape-right(90) → upside-down(180) → landscape-left(270)).
    /// DisplayView poses the shell from this, so all rotation must go through
    /// rotate(clockwise:) or the shell drifts out of step with the guest.
    private(set) var rotationDegrees = 0 {
        // Orientation is health-relevant UI state like any other: the toolbar's
        // rotate glyph shows which way the NEXT turn goes, so it has to follow
        // an automatic rotation too, not just the three manual actions that used
        // to poke it by hand.
        didSet { if oldValue != rotationDegrees { onStatusChange?() } }
    }
    var isLandscape: Bool { rotationDegrees == 90 || rotationDegrees == 270 }

    /// Toggle between portrait and landscape: enter counter-clockwise (home
    /// button ends up on the right), leave by heading back the short way.
    func toggleRotation() {
        rotate(clockwise: rotationDegrees == 270)
    }

    /// Rotate a quarter turn in a named direction.
    func rotate(clockwise: Bool) {
        let next = (rotationDegrees + (clockwise ? 90 : 270)) % 360
        if !setAccelerometer(for: next) { clockwise ? rotateRight() : rotateLeft() }
        rotationDegrees = next
    }

    /// The iPad sets its accelerometer outright for the shell's angle rather
    /// than stepping it: the machine moves it on its own (the power-off
    /// gesture), and a relative step from there lands on the wrong side.
    /// Values are UIDeviceOrientation: a clockwise turn from portrait (1) puts
    /// Home on the left (4), then upside down (2), then Home right (3).
    @discardableResult
    private func setAccelerometer(for degrees: Int) -> Bool {
        guard profile.orientationSource == .springBoard, let value = [0: 1, 90: 4, 180: 2, 270: 3][degrees] else { return false }
        // The machine answers asynchronously now; only an iPad takes this path,
        // and it always has the control, so a refusal is just logged.
        control(.orientation(value)) { applied in
            if !applied { logEvent("rotation: the device refused orientation \(value)") }
        }
        return true
    }

    /// Quarter-turn our way to `target`, the short way round. Every step goes
    /// through rotate(clockwise:) so the guest and `rotationDegrees` stay in
    /// lockstep — this is a caller of the one source of truth, not a second one.
    private func rotate(toward target: Int) {
        while true {
            let delta = (target - rotationDegrees + 360) % 360
            guard delta != 0 else { return }
            rotate(clockwise: delta != 270)   // 90 and 180 go clockwise, 270 back
        }
    }

    // MARK: - Auto-rotation
    //
    // Open a landscape-only app and the emulated iPod swings to landscape by
    // itself; press home and it swings back. The signal comes from the guest,
    // because on 3.1.3 there is nowhere else it can come from: SpringBoard's
    // -[SpringBoard noteUIOrientationChanged:display:] updates an ivar and calls
    // GSEventRotateSimulator() in-process, and posts nothing. The three
    // com.apple.springboard.*Orientation Darwin notifications that notification_proxy
    // WOULD have relayed are posted from the accelerometer path — they describe
    // how the device is being held, which is the thing we are faking anyway —
    // and springboardservicesrelay on 3.1.3 answers only getIconState /
    // setIconState / getIconPNGData, so libimobiledevice's
    // sbservices_get_interface_orientation has nothing to talk to.
    //
    // The guest agent reads SpringBoardServices' SBGetUIOrientation MIG stub
    // (7E18's ABI; other builds answer ENOSYS and the shell stays put).
    //
    // EDGES, NOT LEVELS, is the rule that keeps this from fighting the user.
    // We rotate when the guest's orientation *changes*; we never correct the
    // shell towards the guest's steady state. The home screen is portrait-only
    // on 3.1.3, so a levels rule would undo a manual rotation the instant it was
    // made — the user turns the device, the guest stays at 0, and we would turn
    // it straight back. With edges, a manual rotation the guest declines to
    // follow simply stands, and a manual rotation the guest DOES follow reports
    // the orientation we already moved to, so it lands on a no-op. The user only
    // loses their manual angle when the front app actually changes what it wants,
    // which is the moment they asked us to follow.

    /// Off switch, for anyone who would rather the device never move on its own.
    /// Per device (`autoRotateWithGuest.<uuid>`), seeded from the app-wide value
    /// of earlier builds; on by default — it is only ever driven by an explicit
    /// change on the guest's side.
    static let autoRotateDefaultsKey = "autoRotateWithGuest"
    var autoRotateEnabled: Bool { perDeviceSetting(Self.autoRotateDefaultsKey) }
    func toggleAutoRotate() {
        UserDefaults.standard.set(!autoRotateEnabled, forKey: instance.defaultsKey(Self.autoRotateDefaultsKey))
        onStatusChange?()
    }
    /// A per-device on/off setting, falling back to the app-wide key it replaced, then on.
    private func perDeviceSetting(_ name: String) -> Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: instance.defaultsKey(name)) as? Bool ?? defaults.object(forKey: name) as? Bool ?? true
    }

    /// The last value SpringBoard reported, in SpringBoard's degrees (0, 90,
    /// 180, -90). nil until the first line arrives — that first one only seeds
    /// this, so a watcher that attaches to an already-running guest never yanks
    /// the shell around on connect.
    private var lastGuestOrientation: Int?
    private var orientationTask: Task<Void, Never>?

    /// SpringBoard's degrees are the angle the *content* is rotated by; ours are
    /// the angle the *device* is turned clockwise. They are mirror images.
    ///
    /// From -[SBApplication defaultStatusBarOrientation]: UIInterfaceOrientation
    /// Portrait → 0, PortraitUpsideDown → 180, LandscapeLeft → 90, LandscapeRight
    /// → -90. UIInterfaceOrientationLandscapeLeft is the one with the home button
    /// on the RIGHT, which is the device turned 270° clockwise — hence the flip.
    private func hostDegrees(forGuest degrees: Int) -> Int? {
        switch degrees {
        case 0:          return 0
        case 180:        return 180
        case 90:         return 270   // LandscapeLeft:  home button right
        case -90, 270:   return 90    // LandscapeRight: home button left
        default:         return nil   // a torn line, or a value we don't know
        }
    }

    private func guestOrientationChanged(to degrees: Int) {
        guard let target = hostDegrees(forGuest: degrees) else { return }
        defer { lastGuestOrientation = degrees }
        // First reading seeds only: see lastGuestOrientation.
        guard let previous = lastGuestOrientation, previous != degrees else { return }
        guard autoRotateEnabled, state == .running else { return }
        rotate(toward: target)
    }

    /// The iPad: 3.2's springboardservicesrelay answers getInterfaceOrientation,
    /// so no guest tools are needed. iOS comes back up in the orientation it
    /// last had while the app starts every process portrait, so the first
    /// reading after boot is adopted; after that only changes are followed
    /// (the edges rule above). rotate(toward:) moves the shell and the
    /// accelerometer together.
    private func startInterfaceOrientationWatch() {
        orientationTask?.cancel()
        orientationTask = Task { [weak self] in
            var last: Int?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                if self.state == .booting { last = nil }   // a restart: adopt again
                guard self.state == .running, self.canManageApps, !self.isSleeping, !self.isInstalling,
                      let reading = try? await self.springBoard().interfaceOrientation(),
                      let target = Self.iPadDegrees(forInterface: reading) else { continue }
                if last == nil || (last != reading && self.autoRotateEnabled), target != self.rotationDegrees {
                    self.rotate(toward: target)
                }
                last = reading
            }
        }
    }

    /// SpringBoard's UIInterfaceOrientation -> the app's clockwise device
    /// angle, as on hardware: upright is Portrait (1); turned clockwise, Home
    /// is on the left and the UI is LandscapeLeft (4); then upside down (2);
    /// then LandscapeRight (3).
    static func iPadDegrees(forInterface orientation: Int) -> Int? {
        [1: 0, 4: 90, 2: 180, 3: 270][orientation]
    }

    /// Keeps one reporter alive for as long as the app runs, re-attaching after
    /// a boot, a respring, or a dropped USB session — the same "the guest drops
    /// its services and comes back" reality GuestNotifications backs off around.
    private func startOrientationWatch() {
        orientationTask?.cancel()
        orientationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.state == .running, !self.preparingDevice, !self.isSleeping, !self.isInstalling {
                    let generation = self.bootGeneration
                    do {
                        if let degrees = try await self.tools().guestOrientation() {
                            try Task.checkCancellation()
                            guard generation == self.bootGeneration else { continue }
                            self.guestOrientationChanged(to: degrees)
                        }
                    } catch {
                        if Task.isCancelled { return }
                        self.lastGuestOrientation = nil
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    }
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    // MARK: - Guest package (docs/guest-package-bootstrap.md)

    /// What this boot offered the guest's loader; nil: no offer.
    private(set) var guestOffer: GuestPackage.Offer?
    private(set) var guestToolsStatus: GuestPackage.Status = .unknown {
        didSet { if oldValue != guestToolsStatus { onStatusChange?() } }
    }
    private var guestPackageTask: Task<Void, Never>?
    private var guestOfferDirectory: URL { instance.paths.work.appendingPathComponent("guest-offer", isDirectory: true) }
    private var recordURL: URL {
        DeviceInstance.directory(instance.id, state: stateDir).appendingPathComponent(DeviceInstance.recordName)
    }
    /// The preparer's device.lock.json record.
    private var lockRecord: GuestPackage.LockRecord? {
        GuestPackage.lockRecord(instance.paths.base.appendingPathComponent("device.lock.json"))
    }
    private var guestRecord: DeviceInstance.Guest? { (try? DeviceInstance.read(recordURL))?.guest }

    /// device.json `guest`, read fresh and written back (never the whole cached record).
    private func updateGuestRecord(_ change: (inout DeviceInstance.Guest) -> Void) {
        guard var record = try? DeviceInstance.read(recordURL) else { return }
        var guest = record.guest ?? DeviceInstance.Guest()
        if guest.seed == nil { guest.seed = lockRecord?.seed }
        change(&guest)
        guard guest != record.guest else { return }
        record.guest = guest
        do {
            try record.write(state: stateDir)
            DeviceLibrary.shared.reload()
        } catch { logEvent("guest package: could not record \(guest): \(error.localizedDescription)") }
    }

    /// Compose this boot's offer from the bundled itpack; the machine's
    /// guest-package= directory, or nil (no property: an older dylib, no
    /// itpack, or nothing for this build) and the device keeps what it runs.
    private func composeGuestOffer() -> String? {
        guestOffer = nil
        guard status?.guestPackageSupported == true, let arch = GuestPackage.arch(board: instance.board),
              let pack = GuestPackage.bundledPack(arch: arch, filesRoot: Bundled.filesRoot) else {
            try? FileManager.default.removeItem(at: guestOfferDirectory)
            return nil
        }
        let build = instance.firmware.split(separator: "-").last.map(String.init) ?? ""
        do {
            try FileManager.default.createDirectory(at: instance.paths.work, withIntermediateDirectories: true)
            guestOffer = try GuestPackage.compose(itpack: pack, board: instance.board, build: build,
                                                  lock: lockRecord, guest: guestRecord, into: guestOfferDirectory)
        } catch {
            logEvent("guest package: no offer: \(error.localizedDescription)")
        }
        if let guestOffer { logEvent("guest package: offering \(guestOffer.serial == 0 ? "the built-in package" : "serial \(guestOffer.serial) (\(guestOffer.version))")") }
        return guestOffer == nil ? nil : guestOfferDirectory.path
    }

    /// Judge this boot: a report and a healthy session (UI up, the agent or
    /// lockdown answering) is `good`; a new package with no healthy session
    /// within the budget is `bad`. No report once healthy: legacy baked tools.
    private func startGuestPackageWatch() {
        guestPackageTask?.cancel()
        guestToolsStatus = .unknown
        guard let offer = guestOffer else { return }
        let generation = bootGeneration
        guestPackageTask = Task { [weak self] in
            let started = ContinuousClock.now
            var healthySince: ContinuousClock.Instant?
            var seen: GuestPackageReport?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, generation == self.bootGeneration, !self.isDead, !self.shuttingDown,
                      let status = self.status else { return }
                let report = status.guestPackage
                if let report, report != seen {
                    seen = report
                    logEvent("guest package: loader reports serial \(report.serial), result \(report.result)")
                    self.updateGuestRecord { $0.active = report.serial }
                }
                self.guestToolsStatus = GuestPackage.status(report: report, offer: offer, record: self.guestRecord,
                                                            glesProtocol: status.glesProtocol)
                // The iPod: the agent answers its channel. The iPad has no agent;
                // lockdown answering stands in for its pasteboard agent (the
                // dylib exports no pasteboard-agent status).
                let healthy = self.state == .running && status.uiReady
                    && (self.hasGuestTools ? status.agentStatus == 1 : self.deviceReachable == true)
                if healthy { healthySince = healthySince ?? .now } else { healthySince = nil }
                let steady = healthySince.map { ContinuousClock.now - $0 } ?? .zero
                switch GuestPackage.verdict(report: report, healthyFor: steady, elapsed: ContinuousClock.now - started,
                                            record: self.guestRecord, restored: false) {
                case nil: continue
                case .good(let serial)?:
                    self.updateGuestRecord { $0.lastGood = serial; $0.bad.removeAll { $0 == serial } }
                    logEvent("guest package: serial \(serial) judged good")
                case .bad(let serial)?:
                    self.updateGuestRecord { if !$0.bad.contains(serial) { $0.bad.append(serial) } }
                    logEvent("guest package: serial \(serial) judged bad (no healthy session in \(GuestPackage.badAfter))")
                case .legacy?:
                    self.guestToolsStatus = .legacy
                    logEvent("guest package: no report; legacy baked guest tools")
                case .undecided?: break
                }
                return
            }
        }
    }


    enum GuestToolsChoice { case previous, builtIn, latest }

    /// Device ▸ Restart with … Guest Tools: record the choice, power off
    /// cleanly, and start a fresh helper, whose boot composes the next offer
    /// from the record (its loader runs at boot). A cold boot, not a guest
    /// reset: after system_reset a fresh 7E18 once stayed on the Apple logo.
    func canRestart(with choice: GuestToolsChoice) -> Bool {
        guard isRunning, guestOffer != nil, status?.guestPackage != nil else { return false }
        switch choice {
        case .previous: return true
        case .builtIn: return guestOffer?.serial != 0
        case .latest: return guestOffer?.serial == 0 || guestRecord?.bad.contains(guestOffer?.bundled ?? -1) == true
        }
    }

    func restart(with choice: GuestToolsChoice) {
        guard let offer = guestOffer else { return }
        let active = status?.guestPackage?.serial
        updateGuestRecord { guest in
            switch choice {
            case .previous:
                if let active, active != guest.seed, !guest.bad.contains(active) { guest.bad.append(active) }
                if guest.lastGood == active { guest.lastGood = nil }
                guest.builtIn = nil
            case .builtIn:
                guest.builtIn = offer.bundled
            case .latest:
                guest.builtIn = nil
                guest.bad.removeAll { $0 == offer.bundled }
            }
        }
        logEvent("guest package: restarting with \(choice) guest tools")
        halt { [weak self] _ in self?.onRestartRequested?() }
    }

    // MARK: - Keyboard passthrough
    
    /// Forward a host key by its macOS virtual keycode; the shim maps it to a
    /// QKeyCode exactly as ui/cocoa.m does. Per device (`keyboardInputEnabled.<uuid>`),
    /// seeded from the app-wide value of earlier builds.
    var keyboardInputEnabled: Bool { perDeviceSetting("keyboardInputEnabled") }
    func toggleKeyboardInput() {
        UserDefaults.standard.set(!keyboardInputEnabled, forKey: instance.defaultsKey("keyboardInputEnabled"))
        onStatusChange?()
    }

    func sendKey(macKeyCode: UInt16, down: Bool) {
        guard !down || (keyboardInputEnabled && acceptsInput && !isSleeping) else { return }
        link?.send(.key(macKeyCode: Int(macKeyCode), down: down))
    }
    
    // MARK: - Machine control

    func pause()  { link?.send(.machine(.pause));  if state == .running { state = .paused } }
    func resume() {
        guard !storageFailed else { return }
        link?.send(.machine(.resume))
        if state == .paused { state = .running }
    }
    /// The guest cold-boots portrait, so our tracked orientation has to follow
    /// it back. Leaving it at 90/270 left DisplayView posing the shell sideways
    /// and sizing the cutout landscape while the guest published a portrait
    /// buffer — a permanently rotated, stretched screen that no amount of
    /// rotating could fix, since every later quarter turn stayed 90° out.
    /// Restart the guest.
    func reset() {
        if isPoweredOff { powerOn(); return }
        guard !shuttingDown else { return }
        guard !storageFailed else { return }
        reconnectUSB()
        // Flush first. A bare system_reset is the same hard cut as a SIGKILL as
        // far as the guest's filesystem is concerned — it loses the HFS+ catalog
        // updates still in memory, which is how a device ends up on the
        // Connect-to-iTunes screen. The quit path has done this for a while;
        // Restart, which is one menu row away from Erase, was still doing it
        // the dangerous way.
        let preparation = readinessTask
        preparation?.cancel()
        Task { [weak self] in
            guard let self else { return }
            await preparation?.value
            if !self.hasGuestTools {
                // No guest to sync through: a hard halt (storage flushed, the
                // journal replays), then a fresh helper, as Stop then Start.
                self.halt { [weak self] _ in self?.onRestartRequested?() }
                return
            } else if self.canManageApps {
                _ = await withSoftDeadline(20) { try? await self.syncFilesystem() }
            }
            guard !self.storageFailed else { return }
            self.link?.send(.machine(.reset))
            self.rotationDegrees = 0
            self.setAccelerometer(for: 0)
            self.state = .booting
            self.startReadinessWatch()
            self.startGuestPackageWatch()
            self.startBootWatch()
        }
    }
    /// Retain the QEMU main loop at guest power-off; a reset can cold boot it
    /// again without reinitializing QEMU or opening a second NAND writer.
    func powerOff(completion: @escaping (Bool) -> Void) {
        guard canStop else { completion(false); return }
        AppInstaller.discard(for: instance.id)
        halt(completion: completion)
    }

    func powerOn() {
        guard isPoweredOff, !storageFailed, !shuttingDown else { return }
        // Stopped by a halt: the helper is gone, so start a fresh one. A guest
        // that powered itself off (-no-shutdown) keeps its helper: reset and resume.
        if process?.isDead != false { onRestartRequested?(); return }
        reconnectUSB()
        poweringOn = true
        bootGeneration += 1
        foregroundAppName = nil
        isSleeping = false
        deviceReachable = nil
        reachableSince = nil
        ethlinkUp = false
        rotationDegrees = 0
        setAccelerometer(for: 0)
        state = .booting
        link?.send(.machine(.reset))
        Task { [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now + .seconds(5)
            // system_reset is queued. Wait until the PMU reset clears its
            // shutdown latch (the helper republishes it at 20 Hz) before
            // resuming the stopped VM.
            while status?.shutdownConfirmed == true, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard status?.shutdownConfirmed == false, !self.isDead else {
                self.poweringOn = false
                self.state = .poweredOff
                return
            }
            link?.send(.machine(.resume))
            self.poweringOn = false
            self.startReadinessWatch()
            self.startForegroundWatch()
            self.startGuestPackageWatch()
            self.startBootWatch()
        }
    }

    private func startForegroundWatch() {
        foregroundTask?.cancel()
        let generation = bootGeneration
        foregroundTask = Task { [weak self] in
            var appliedProxyRevision: Int?
            while !Task.isCancelled {
                guard let self else { return }
                if self.canReachDevice, !self.isSleeping, !self.isInstalling, !AppInstaller.hasPendingWork(for: self.instance.id) {
                    if self.webProxyAvailable && appliedProxyRevision != self.proxyRevision {
                        let revision = self.proxyRevision
                        if self.webProxyStatus == .waiting {
                            self.webProxyStatus = .applying
                            self.onStatusChange?()
                        }
                        do {
                            try await self.tools().configureWebProxy(enabled: self.webProxy.mode != .off)
                            try Task.checkCancellation()
                            guard generation == self.bootGeneration else { return }
                            if revision == self.proxyRevision {
                                appliedProxyRevision = revision
                                self.webProxyStatus = .ready
                                self.onStatusChange?()
                            }
                        } catch {
                            if Task.isCancelled { return }
                            if self.webProxyStatus != .failed {
                                self.webProxyStatus = .failed
                                logEvent("proxy settings: \(error.localizedDescription)")
                                self.onStatusChange?()
                            }
                        }
                    }
                    do {
                        let name = try await self.tools().foregroundAppName()
                        try Task.checkCancellation()
                        guard generation == self.bootGeneration else { return }
                        self.foregroundAppName = name
                    } catch {
                        if Task.isCancelled { return }
                        self.foregroundAppName = nil
                    }
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    func pasteToGuest(_ text: String) { link?.send(.paste(text)) }

    /// Guest audio for a recording (ScreenMovieWriter). Its clock is the
    /// dylib's: monotonic seconds since the capture started.
    func startAudioCapture() async throws -> GuestAudioCapture {
        guard let link, !isDead else { throw CaptureError.failed("The device is not ready to record audio.") }
        let origin = ProcessInfo.processInfo.systemUptime
        let capture = GuestAudioCapture(clock: { ProcessInfo.processInfo.systemUptime - origin },
                                        stop: { generation in link.send(.audioStop(generation: generation)) })
        audioSink = { [weak capture] event in capture?.receive(event) }
        guard case let .audio(generation) = try await link.request(.audioStart) else {
            throw CaptureError.failed("The device is not ready to record audio.")
        }
        capture.begin(generation: generation)
        return capture
    }

    // MARK: - Device storage paths

    /// Saved-state files older builds wrote beside the overlay; Erase removes them.
    private var snapshotURL: URL { instance.paths.snapshot }
    private var snapshotTmpURL: URL { snapshotURL.appendingPathExtension("tmp") }
    private var snapshotBadURL: URL { snapshotURL.appendingPathExtension("bad") }
    private var overlayURL: URL { instance.paths.overlay }
    /// The device's private NOR copy, which pairs with its overlay: Erase removes it too, and the
    /// next boot clones base/nor.bin again.
    private var preparedNORURL: URL? { instance.paths.writableNOR }
    /// Stop is a hard halt (Sam, 2026-09-28), never a guest shutdown: a booting or
    /// wedged guest ignores those and left the window on "Powering off…". SIGTERM
    /// makes the helper pause the VM, which flushes storage, and quit QEMU
    /// (DeviceHost.halt); a helper still alive after `haltBudget` is killed. The
    /// guest's filesystems replay their journals on the next boot. The helper's
    /// exit is Stopped (helperDied). `completion(true)` iff the helper is gone.
    static let haltBudget: TimeInterval = 10
    /// The quit backstop: the halt, then the kill.
    static let stopBudget: TimeInterval = haltBudget + 5

    /// A live helper whose VM can be stopped, including mid-boot.
    var canStop: Bool { !isDead && !isPoweredOff && !shuttingDown && !isErasing && state != .notStarted }

    func halt(completion: @escaping (Bool) -> Void) {
        if isPoweredOff || process?.isDead != false { completion(true); return }
        // Multiple requests join one halt.
        if haltTask != nil { haltCompletions.append(completion); return }
        shuttingDown = true
        halting = true
        connectionRecoveryTask?.cancel()
        bootWatchTask?.cancel()
        orientationTask?.cancel()
        foregroundTask?.cancel()
        readinessTask?.cancel()
        haltCompletions = [completion]
        let process = process
        if filesMeddled {
            // The overlay or NOR the helper has open is gone from disk: a flush would
            // write into dead inodes, so quit QEMU outright (no pause first).
            logEvent("stop: files were changed under the device; quitting without a flush")
            link?.send(.machine(.quit))
        } else {
            process?.terminate()
        }
        haltTask = Task { [weak self] in
            var exited = await process?.waitForExit(timeout: Self.haltBudget) ?? true
            if !exited {
                logEvent("stop: the device helper did not exit in \(Int(Self.haltBudget)) s; killing it")
                process?.kill()
                exited = await process?.waitForExit(timeout: 5) ?? true
            }
            guard let self else { return }
            if exited { logEvent("stop: device halted") }
            haltTask = nil
            shuttingDown = false
            let completions = haltCompletions
            haltCompletions = []
            for completion in completions { completion(exited) }
        }
    }

    /// Stop the guest and its helper, erase this device, then start it fresh
    /// (a running device) or leave it ready (a stopped one). The app keeps
    /// running. No request is left behind for an unrelated future launch.
    func requestFactoryReset() {
        guard !isErasing else { return }
        // Nothing queued can land on an erased device: drop installs first
        // rather than refusing the erase (or leaving Retry rows behind).
        AppInstaller.discard(for: instance.id)
        isErasing = true
        foregroundTask?.cancel()
        orientationTask?.cancel()
        Task {
            if !isDead, state != .notStarted {
                _ = await withCheckedContinuation { continuation in
                    halt { continuation.resume(returning: $0) }
                }
                // The helper must release every NAND/NOR writer (exit) before removal;
                // one whose guest powered itself off is still alive.
                link?.send(.machine(.quit))
                let deadline = ContinuousClock.now + .seconds(15)
                while process?.isDead == false, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard process?.isDead != false else {
                    isErasing = false
                    reportDeviceNotice("Couldn’t stop the device to erase it. Your data has not been erased. Try again.", for: .erase)
                    return
                }
            }
            let overlay = overlayURL
            let snapshots = [snapshotURL, snapshotTmpURL, snapshotBadURL]
            let stateDirectory = stateDir
            let preparedNOR = preparedNORURL
            let owner = instance.id
            do {
                try await Task.detached {
                    try DeviceStateStorage.erase(overlay: overlay, snapshots: snapshots, state: stateDirectory, owner: owner)
                    if let preparedNOR, FileManager.default.fileExists(atPath: preparedNOR.path) {
                        try DeviceStateStorage.checkRemovable(preparedNOR, state: stateDirectory, owner: owner)
                        try FileManager.default.removeItem(at: preparedNOR)
                    }
                }.value
                resolveDeviceNotice(for: .erase)
                resolveDeviceNotice(for: .activation)
                isErasing = false
                if started {
                    logEvent("reset: device erased; starting it fresh")
                    onRestartRequested?()
                } else {
                    logEvent("reset: device erased")
                }
            } catch {
                isErasing = false
                reportDeviceNotice("The device could not be completely erased: \(error.localizedDescription) Choose Erase All Content and Settings to try again.", for: .erase)
            }
        }
    }

    // MARK: - App management
    
    var canManageApps: Bool { usbmux.session != nil && !storageFailed }

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
    var canReachDevice: Bool { usbConnected && canManageApps && isRunning && deviceReachable == true }

    /// Adding to the ready queue opens no guest session. A probe suppressed by
    /// our own install must not disable File → Install App or drag-and-drop.
    var canQueueInstall: Bool {
        usbConnected && canManageApps && isRunning && (deviceReachable == true || AppInstaller.isUsingDevice(instance.id) || isInstalling)
    }
    /// The usbmuxd socket to talk to this device on, for the long-lived
    /// notification_proxy watcher (which owns its own session, not a gated one).
    var usbmuxSession: String? { usbmux.session?.clientSocket }
    
    private func tools() throws -> DeviceTools {
        guard let session = usbmux.session else {
            throw DeviceToolsError.failed("The device is not reachable over USB yet.")
        }
        return DeviceTools(clientSocket: session.clientSocket,
                           proxyDirectory: proxyDirectory, agent: link, agentCache: agentCache,
                           packaged: status?.guestPackage != nil, deviceOS: iosVersion)
    }

    /// This device's firmware, from its catalog entry: what an app's minimum
    /// iOS and architecture are checked against.
    private var catalogEntry: FirmwareCatalog.Entry? { FirmwareCatalog.bundled.entry(id: instance.firmware) }
    var iosVersion: String { catalogEntry?.version ?? "3.1.3" }
    var guestArch: String { catalogEntry?.recipe?.guest?.arch ?? GuestPackage.arch(board: instance.board) ?? "armv6" }
    
    /// Cheap in-process check that the USB bridge sees the guest. App-service
    /// reads establish lockdownd readiness separately.
    /// Bounded and gated. A bare `Task.detached` here had neither: `idevice_new`
    /// against a half-open usbmuxd socket blocks with no timeout, and this is
    /// called from the quit-time snapshot health gate and the restore verifier —
    /// so a wedged socket hung the quit itself. `withDeadline` abandons the
    /// blocked thread; the gate keeps it from racing other device work.
    func deviceReady() async -> Bool {
        (try? await checkDeviceConnection()) != nil
    }

    func checkDeviceConnection() async throws {
        try Task.checkCancellation()
        guard usbConnected, !isPoweredOff, !shuttingDown,
              let socket = usbmux.session?.clientSocket else { throw DeviceError.notAttached }
        // Bounded INCLUDING the wait for the gate. withDeadline bounds the probe
        // itself, but not the queue in front of it, and this is called from the
        // quit path — where waiting out a 120s uninstall means the app's own
        // backstop fires and the guest is killed without ever being asked to
        // power down. Giving up on the answer is safe; every caller treats a
        // silent device as "could not prove it is alive", not "it is dead".
        let result: Result<Void, Error>? = await withSoftDeadline(Timeouts.serviceProbe * 2) {
            do {
                try await DeviceGate.shared.serialized {
                    try await withDeadline(Timeouts.serviceProbe, "USB connection") {
                        try IMobileDevice.checkAttachment(socket: socket)
                    }
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try Task.checkCancellation()
        guard let result else { throw DeviceError.timedOut(operation: "USB connection") }
        try result.get()
    }

    func installedApps() async throws -> [InstalledApp] { try await tools().installedApps() }

    /// nil when we could not ask. Anything other than "Activated"/"FactoryActivated"
    /// means the guest is sitting on the Connect-to-iTunes screen.
    func activationState() async -> String? {
        guard let socket = usbmux.session?.clientSocket else { return nil }
        return await DeviceServices(clientSocket: socket).activationState()
    }

    // MARK: - Activation (verified once per boot; activating is the preparer's job)

    private var activationCheckedGeneration: Int?

    /// On the first lockdown answer of a boot, ask ActivationState once. Anything
    /// but Activated is a persistent issue: commands stay blocked, nothing
    /// retries, the notice offers Erase. An activated guest clears an old notice.
    private func checkActivationIfNeeded() {
        guard deviceReachable == true, activationCheckedGeneration != bootGeneration else { return }
        activationCheckedGeneration = bootGeneration
        let generation = bootGeneration
        Task { [weak self] in
            guard let self else { return }
            let state = await activationState()
            guard generation == bootGeneration else { return }
            guard let state else { activationCheckedGeneration = nil; return }   // couldn't ask: again on the next answer
            logEvent("activation: lockdown reports \(state)")
            guard let issue = DeviceConnectionIssue.activation(state: state, profile: profile) else {
                resolveDeviceNotice(for: .activation)
                return
            }
            connectionIssue = issue
            deviceReachable = false
            readinessTask?.cancel()
            preparingDevice = false
            reportDeviceNotice(issue.summary, for: .activation)
        }
    }
    func uninstall(_ bundleID: String) async throws      { try await tools().uninstall(bundleID) }
    func launchApp(_ bundleID: String) async throws {
        guard acceptsInput else { throw AppLaunchError.unavailable }
        if isSleeping {
            // Wake with the hardware Home button. SpringBoard still enforces
            // the Lock Screen and any passcode when the launch is requested.
            pressHome()
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(100))
                guard acceptsInput else { throw AppLaunchError.unavailable }
                if status?.displaySleeping != true { break }
            }
        }
        try await tools().launchApp(bundleID)
    }
    func syncFilesystem() async throws                   { try await tools().syncFilesystem() }
    func restartSpringBoard() async throws {
        guard isRunning, !isInstalling else { return }
        restartingSpringBoard = true
        defer { restartingSpringBoard = false }
        try await tools().restartSpringBoard()
        try await waitForSpringBoard()
    }

    private func waitForSpringBoard() async throws {
        let deadline = ContinuousClock.now + .seconds(45)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if (try? await springBoard().order()) != nil { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw DeviceToolsError.failed("SpringBoard did not recover. Restart the device to recover; your installed apps are preserved.")
    }

    /// True while any install is running — the quit guard reads this so ⌘Q
    /// mid-install prompts instead of leaving a half-installed app.
    private(set) var isInstalling = false

    func install(_ ipa: URL, placeholderRaised: Bool = false,
                 progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        isInstalling = true
        defer { isInstalling = false }
        return try await tools().install(ipa, placeholderRaised: placeholderRaised, progress: progress)
    }

    func importMedia(_ media: PreparedMedia, progress: @escaping @Sendable (Double) -> Void,
                    willCommit: () -> Void) async throws {
        guard canQueueInstall else { throw DeviceToolsError.failed("The device is not ready for media import.") }
        isInstalling = true
        defer { isInstalling = false }
        let device = try tools()
        try await device.stageMedia(media, progress: progress)
        try Task.checkCancellation()
        willCommit()
        try await device.commitMedia(media)
    }

    /// Fire-and-forget App Store-style "downloading" placeholder on the guest
    /// home screen, mirroring a catalog download the host is running — under
    /// the SAME id the install path uses, so the install adopts it. Cosmetic
    /// by design: a device that can't take it right now costs nothing.
    @discardableResult
    func installPlaceholder(_ action: String, bundleID: String,
                            after previous: Task<Void, Never>? = nil) -> Task<Void, Never>? {
        (try? tools())?.installPlaceholder(action, bundleID: bundleID, after: previous)
    }

    /// The home screen's own icon order, for the sidebar to mirror and reorder.
    private func springBoard() throws -> SpringBoardIcons {
        guard let session = usbmux.session else {
            throw DeviceToolsError.failed("The device is not reachable over USB yet.")
        }
        return SpringBoardIcons(clientSocket: session.clientSocket, profile: profile)
    }

    func homeScreenOrder() async throws -> [String] { try await springBoard().order() }
    /// Returns the order SpringBoard ACCEPTED, which is not always the one asked
    /// for — the caller should adopt it rather than assume its own.
    @discardableResult
    func moveOnHomeScreen(_ bundleID: String, before other: String?) async throws -> [String] {
        try await springBoard().move(bundleID, before: other)
    }
    
    // MARK: - Boot environment
    
    /// UserDefaults key for Settings ▸ verbose boot.
    static let verboseBootDefaultsKey = "verboseBoot"
    static var verboseBoot: Bool {
        UserDefaults.standard.bool(forKey: verboseBootDefaultsKey)
    }

    static let kernelConsoleDefaultsKey = "kernelConsole"
    static var kernelConsole: Bool {
        UserDefaults.standard.bool(forKey: kernelConsoleDefaultsKey)
    }

    /// Early iBoot handoff arguments; serial output is included in diagnostics.
    /// The regression checker compares the base command line with the harness;
    /// verbose boot and kernel-console output remain optional app settings.
    static var bootArgs: String {
        var args = "amfi_allow_any_signature=1 cs_enforcement_disable=1"
        if verboseBoot { args += " -v" }
        if kernelConsole { args += " serial=3 debug=0x8" }
        return args
    }

}
