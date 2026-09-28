// One device the window can show: its record, the controller that runs it,
// and the view controllers cached for it (docs/multi-device-plan.md, C).
//
// DeviceSessionHost owns the sessions. Each running device is its own
// LightTouchDevice helper (DeviceProcess), so any number can run at once, a
// dead one restarts without the app, and the others never notice.

import Cocoa

// MARK: - Row state

/// A command the sidebar, its context menu, the Device menu and the
/// placeholder offer for one catalog entry.
nonisolated enum DeviceAction: CaseIterable, Sendable {
    case start, stop, downloadAndPrepare, importIPSW, cancel, erase, showInFinder, delete
}

/// A download or preparation in flight for a catalog entry (FirmwareJobs).
nonisolated enum FirmwareJob: Equatable, Sendable {
    case downloading(fraction: Double)
    /// `step` is 1-based; 0 of 0 is a job with no steps yet (hashing an import).
    /// `fraction` is the progress within the step.
    case preparing(step: Int, of: Int, name: String, fraction: Double = 0)
    case failed(String)
}

/// A started device, as the sidebar sees it.
nonisolated enum SessionPhase: Equatable, Sendable {
    case running, stopping, stopped
    case dead(String)
}

nonisolated enum DeviceRowState: Equatable, Sendable {
    enum Unavailable: Equatable, Sendable { case comingSoon, requiresIPSW }
    case notDownloaded(bytes: Int64?)
    case downloading(fraction: Double)
    case preparing(step: Int, of: Int, name: String, fraction: Double = 0)
    case ready, running, stopping
    case error(String)
    case unavailable(Unavailable)
}

/// One sidebar row: a catalog entry and what the library, the jobs and the
/// sessions say about it. Pure, so tests/check-device-rows.py can run it.
nonisolated struct DeviceRow: Equatable, Sendable {
    let entry: FirmwareCatalog.Entry
    let instanceID: UUID?
    let hasSession: Bool
    let state: DeviceRowState

    init(entry: FirmwareCatalog.Entry, instanceID: UUID?, session: SessionPhase?,
         job: FirmwareJob?, failure: String?) {
        self.entry = entry
        self.instanceID = instanceID
        hasSession = session != nil
        state = Self.state(entry: entry, startable: instanceID != nil || entry.source.kind == .bundled,
                           session: session, job: job, failure: failure)
    }

    /// A session outranks everything; then the catalog's own verdict, a job
    /// in flight, the last start failure, and finally whether a device exists.
    private static func state(entry: FirmwareCatalog.Entry, startable: Bool, session: SessionPhase?,
                              job: FirmwareJob?, failure: String?) -> DeviceRowState {
        switch session {
        case .running?: return .running
        case .stopping?: return .stopping
        case let .dead(reason)?: return .error(reason)
        case .stopped?: return .ready
        case nil: break
        }
        if entry.status == .comingSoon { return .unavailable(.comingSoon) }
        switch job {
        case let .downloading(fraction)?: return .downloading(fraction: fraction)
        case let .preparing(step, count, name, fraction)?: return .preparing(step: step, of: count, name: name, fraction: fraction)
        case let .failed(reason)?: return .error(reason)
        case nil: break
        }
        if let failure { return .error(failure) }
        if startable { return .ready }
        return entry.status == .userIPSW ? .unavailable(.requiresIPSW) : .notDownloaded(bytes: entry.source.bytes)
    }

    var title: String { "iOS \(entry.version)" }
    var isExperimental: Bool { entry.status == .experimental }
    /// A device exists, or one can be made without a download (the bundled iPod).
    var isStartable: Bool { instanceID != nil || entry.source.kind == .bundled }
    var isDimmed: Bool { if case .unavailable = state { true } else { false } }
    var isError: Bool { if case .error = state { true } else { false } }
    /// A download's or preparation's overall progress; nil while it has no steps yet.
    var progress: Double? {
        switch state {
        case let .downloading(fraction): fraction
        case let .preparing(step, count, _, fraction) where count > 0:
            min(1, (Double(max(step - 1, 0)) + min(max(fraction, 0), 1)) / Double(count))
        default: nil
        }
    }

    /// `canDownload` is FirmwareJobs.canDownload: whether the preparer is present.
    func allows(_ action: DeviceAction, canDownload: Bool) -> Bool {
        let working = switch state { case .downloading, .preparing, .stopping: true; default: false }
        switch action {
        case .start: return isStartable && (state == .ready || (isError && !hasSession))
        case .stop: return state == .running
        case .downloadAndPrepare:
            return canDownload && !isStartable && entry.source.kind == .ipsw && !working && !isDimmed
        case .importIPSW:
            return !isStartable && entry.source.kind == .ipsw && entry.status != .comingSoon && !working
        case .cancel: return !hasSession && working
        case .erase: return instanceID != nil && !working
        case .showInFinder: return instanceID != nil
        case .delete: return instanceID != nil && !hasSession && !working
        }
    }

    /// The placeholder's one button.
    var primaryAction: DeviceAction? {
        switch state {
        case .ready: .start
        case .notDownloaded: .downloadAndPrepare
        case .downloading, .preparing: .cancel
        case .error: isStartable ? .start : .downloadAndPrepare
        case .unavailable(.requiresIPSW): .importIPSW
        case .unavailable(.comingSoon), .running, .stopping: nil
        }
    }

    var primaryTitle: String? {
        if isError { return "Try Again" }
        return switch primaryAction {
        case .start: "Start"
        case .downloadAndPrepare: "Download & Prepare"
        case .importIPSW: "Import IPSW…"
        case .cancel: "Cancel"
        default: nil
        }
    }

    /// The accessory's words: what VoiceOver reads after the version.
    var stateDescription: String {
        switch state {
        case let .notDownloaded(bytes):
            bytes.map { "Not Downloaded, " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Not Downloaded"
        case let .downloading(fraction): "Downloading, \(Int((fraction * 100).rounded()))%"
        case let .preparing(step, count, name, _): count > 0 ? "Preparing, Step \(step) of \(count)" : "Preparing, \(name)"
        case .ready: "Ready"
        case .running: "Running"
        case .stopping: "Stopping"
        case .error: "Error"
        case .unavailable(.comingSoon): "Coming Soon"
        case .unavailable(.requiresIPSW): "Requires IPSW"
        }
    }
}

// MARK: - Firmware jobs: FirmwareJobs.swift

// MARK: - Helper process

/// One running device's LightTouchDevice (docs/multi-device-plan.md, A): spawned
/// with its own native.log, its hello checked against the board, booted once.
/// It dies once (`onDeath`, with the reason the row and the dead overlay show);
/// a restart is a new DeviceProcess. Foundation only: tests/check-sessions.py
/// compiles this section as the app does.
@MainActor final class DeviceProcess {
    let link: DeviceLink
    let profile: DeviceProfile
    private let log: ProcessLogCapture?
    /// `.audio` and `.audioEnded`, for the recorder (GuestAudioCapture).
    var onAudio: ((LinkEvent) -> Void)?
    /// Fires once: the helper is gone, or never came up.
    var onDeath: ((String) -> Void)?
    private(set) var deathReason: String?
    var isDead: Bool { deathReason != nil }
    /// The hello reply (dylib path and mtime, build id, board), nil until it answered.
    var info: HelperInfo? { link.info }
    var status: SharedStatus? { link.status }
    private var qemuExitCode: Int32?
    private var startFailure: String?

    /// `helper` and `requirement` default to the bundled helper and the app's Team (tests pass their own).
    init(instance: UUID, profile: DeviceProfile, log url: URL, helper: URL? = nil, requirement: String? = nil) {
        self.profile = profile
        do { log = try ProcessLogCapture(url: url) }
        catch {
            logEvent("device helper: native.log unavailable at \(url.path): \(error.localizedDescription)")
            log = nil
        }
        var configuration = DeviceLink.Configuration(instance: instance, outputDescriptor: log?.writeDescriptor ?? -1)
        if let helper { configuration.helper = helper }
        configuration.machine = profile.machineName
        configuration.requirement = requirement
        link = DeviceLink(configuration: configuration)
        link.onEvent = { [weak self] event in MainActor.assumeIsolated { self?.received(event) } }
        link.onTerminated = { [weak self] termination in MainActor.assumeIsolated { self?.terminated(termination) } }
    }

    /// Spawn, rendezvous and hello, check the board, then boot what `configure`
    /// builds from the hello (nil: don't boot). `completion` runs once; a
    /// failure is also a death (onDeath follows).
    func start(_ configure: @escaping (HelperInfo) -> BootConfig?,
               completion: @escaping (Result<HelperInfo, DeviceLinkError>) -> Void) {
        link.start { [weak self] result in
            MainActor.assumeIsolated { self?.started(result, configure, completion) }
        }
    }

    private func started(_ result: Result<HelperInfo, DeviceLinkError>, _ configure: (HelperInfo) -> BootConfig?,
                         _ completion: @escaping (Result<HelperInfo, DeviceLinkError>) -> Void) {
        switch result {
        case let .failure(error): failStart(error, completion)
        case let .success(info):
            checkBoard(info)
            guard let config = configure(info) else { return failStart(.helperFailure("not booted"), completion) }
            link.request(.boot(config), timeout: 30) { [weak self] reply in
                MainActor.assumeIsolated { self?.booted(reply, info, completion) }
            }
        }
    }

    private func booted(_ reply: Result<LinkReply, DeviceLinkError>, _ info: HelperInfo,
                        _ completion: (Result<HelperInfo, DeviceLinkError>) -> Void) {
        switch reply {
        case .success(.ok(true)): completion(.success(info))
        case let .success(.failure(message)): failStart(.helperFailure(message), completion)
        case let .success(other): failStart(.helperFailure("unexpected boot reply \(other)"), completion)
        case let .failure(error): failStart(error, completion)
        }
    }

    /// SIGTERM: the helper runs its own clean shutdown (bounded) and exits.
    /// Never after its death: the link keeps the reaped pid, which may be reused.
    func terminate() { if !isDead { link.terminate() } }
    func kill() { if !isDead { link.kill() } }

    /// True once the helper is gone, false after `timeout`.
    func waitForExit(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isDead, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return isDead
    }

    private func received(_ event: LinkEvent) {
        switch event {
        case let .qemuExited(code): qemuExitCode = code
        case .audio, .audioEnded: onAudio?(event)
        }
    }

    /// Geometry is DeviceProfile's constants; the dylib only confirms them.
    private func checkBoard(_ info: HelperInfo) {
        logEvent("emulator dylib: \(info.dylibPath) (built \(Date(timeIntervalSince1970: info.dylibModified)), build \(info.buildID ?? "unknown")) in helper \(info.pid)")
        guard let device = info.deviceInfo else {
            return logEvent("display: libqemu-arm.dylib does not know machine \(profile.machineName)")
        }
        let reported = CGSize(width: device.screenWidth, height: device.screenHeight)
        if reported != profile.screenPixels {
            logEvent("display: \(profile.machineName) is \(profile.screenPixels) in DeviceProfile but \(reported) in the dylib")
        }
    }

    private func failStart(_ error: DeviceLinkError, _ completion: (Result<HelperInfo, DeviceLinkError>) -> Void) {
        let reason = "The device didn’t start: \(error)."
        logEvent("device helper: \(reason)")
        if startFailure == nil { startFailure = reason }
        completion(.failure(error))
        // A spawned helper reports its own end; one that never ran can't.
        if link.pid > 0 { link.kill() } else { died(reason) }
    }

    private func terminated(_ termination: DeviceTermination) {
        let reason: String
        if let startFailure { reason = startFailure }
        else if let code = qemuExitCode { reason = code == 0 ? "The emulator stopped." : "The emulator stopped (exit code \(code))." }
        else {
            switch termination {
            case let .signaled(signal): reason = "The device helper was killed (signal \(signal))."
            case let .exited(code): reason = "The device helper exited unexpectedly (code \(code))."
            case .unknown: reason = "The device helper stopped."
            }
        }
        logEvent("device helper \(link.pid): \(termination) — \(reason)")
        died(reason)
    }

    private func died(_ reason: String) {
        guard deathReason == nil else { return }
        deathReason = reason
        log?.flush()
        onDeath?(reason)
    }
}

/// argv and environment for one boot, from paths alone. EmulatorController
/// fills it from the device record and launch options; tests from fixtures.
nonisolated enum BootRecipe {
    static func escape(_ value: String) -> String { value.replacingOccurrences(of: ",", with: ",,") }

    struct IPod {
        var bootArgs: String
        var iBoot: String
        var bootrom: String
        var nand: String
        var nor: String
        var writableNOR: String
        var overlay: String
        var usbAddress: String?
        var wifi: Bool
        var memory = "128M"
    }

    struct IPad {
        var kboot: String
        var nand: String
        var overlay: String
        /// "0xWORD2:0xWORD3" (identity.json); the machine uses zeros without it.
        var dieID: String?
        var writableNOR: String?
        var usbAddress: String?
        var wifi: Bool
    }

    /// `audio`: the app's CoreAudio arguments, or `-audio driver=none` in tests.
    /// `netdev`: the explicit wifi0 (with the web proxy's guestfwd), if any.
    static func iPod(_ d: IPod, serial: String, audio: [String], netdev: String?, restore: [String]) -> BootConfig {
        var machine = "iPod-Touch,h264-decode=on,scaler-decode=on,mpvd-decode=on,amc-mode=decode,lcd-planes=on"
            + ",boot-args=\(escape(d.bootArgs))"
            + ",boot-args-delay-ms=1500,boot-args-repeat=200,boot-args-interval-ms=250"
            + ",direct-iboot=\(escape(d.iBoot)),direct-llb="
            + ",bootrom=\(escape(d.bootrom)),nand=\(escape(d.nand)),nor=\(escape(d.nor))"
            + ",nor-rw=\(escape(d.writableNOR)),nandrw=\(escape(d.overlay))"
        if let usb = d.usbAddress { machine += ",usb-tcp-addr=\(usb),osk=on" }
        if d.wifi { machine += ",wifi=on" }          // brings up the emulated BCM4325
        let argv = ["LightTouchMac", "-M", machine, "-m", d.memory, "-display", "none", "-no-shutdown"]
            + audio + ["-serial", serial] + (netdev.map { ["-netdev", $0] } ?? []) + restore
        // The settings 3.1.3 will not boot without (contrib/run-ipod-touch.sh). No
        // IT_LCD_BRIGHT: the guest's own backlight is what makes Lock visible.
        return BootConfig(argv: argv, environment: ["IT_TVOUT_READY": "1"], machine: "iPod-Touch")
    }

    /// Wi-Fi is the machine's default (a BCM4329 on its own slirp wifi0); an
    /// explicit `netdev` replaces it. No -m: the machine's default is the K48's 256 MiB.
    static func iPad(_ d: IPad, serial: String, audio: [String], netdev: String?, restore: [String]) -> BootConfig {
        var machine = "ipad1,kboot=\(escape(d.kboot)),nand=\(escape(d.nand)),nand-overlay=\(escape(d.overlay))"
        if let dieID = d.dieID { machine += ",die-id=\(escape(dieID))" }
        if let nor = d.writableNOR { machine += ",nor-rw=\(escape(nor))" }
        // Without a bridge the machine's built-in USB host keeps it charging.
        if let usb = d.usbAddress { machine += ",usb-tcp-addr=\(usb)" }
        if !d.wifi { machine += ",wifi=off" }
        // usb-kbd on the always-on EHCI becomes the active keyboard for key_mac.
        let argv = ["LightTouchMac", "-M", machine, "-display", "none", "-no-shutdown"] + audio
            + ["-serial", serial, "-device", "usb-kbd,bus=usb-bus.0"] + (netdev.map { ["-netdev", $0] } ?? []) + restore
        return BootConfig(argv: argv, machine: "ipad1")
    }

    /// A prepared device's boot files (W5/W6): kboot.bin and nand/ from base, and
    /// on first boot the overlay directory and the writable NOR, cloned from
    /// base/nor.bin (cp -c) and made owner-writable. Nothing is written inside
    /// base/, which is read-only. usbmuxd-conf is created (and seeded) by USBMux.
    static func preparedFiles(base: URL, overlay: URL, writableNOR: URL?) throws -> (kboot: URL, nand: URL, writableNOR: URL?) {
        let fm = FileManager.default
        let kboot = base.appendingPathComponent("kboot.bin"), nand = base.appendingPathComponent("nand", isDirectory: true)
        for file in [kboot, nand] where !fm.fileExists(atPath: file.path) {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: file.path])
        }
        try fm.createDirectory(at: overlay, withIntermediateDirectories: true)
        if let writableNOR, !fm.fileExists(atPath: writableNOR.path) {
            let source = base.appendingPathComponent("nor.bin")
            let staged = writableNOR.deletingLastPathComponent()
                .appendingPathComponent(".\(writableNOR.lastPathComponent)-\(UUID().uuidString).tmp")
            defer { try? fm.removeItem(at: staged) }
            try fm.createDirectory(at: writableNOR.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard copyfile(source.path, staged.path, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: source.path,
                                                              NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
            }
            let mode = (try fm.attributesOfItem(atPath: staged.path)[.posixPermissions] as? NSNumber)?.int16Value ?? 0o444
            try fm.setAttributes([.posixPermissions: mode | 0o200], ofItemAtPath: staged.path)
            try fm.moveItem(at: staged, to: writableNOR)
        }
        return (kboot, nand, writableNOR)
    }
}

// MARK: - Sessions

/// The views one device keeps while it runs, so switching back to it is
/// instant. A hidden DisplayView stops its own display link.
@MainActor final class DeviceWorkspace {
    let deviceVC: DeviceViewController
    let inspectorVC: AppsInspectorViewController
    private(set) lazy var canvasCapture = CanvasCapture(view: deviceVC.screen, profile: deviceVC.emulator.profile)

    init(emulator: EmulatorController) {
        deviceVC = DeviceViewController(emulator: emulator)
        inspectorVC = AppsInspectorViewController(emulator: emulator)
    }
}

/// A started device: its record and the controller that runs its helper.
/// A restart replaces the whole session (DeviceSessionHost.restart).
@MainActor final class DeviceSession {
    /// Posted on the main actor for every emulator status change. The object is the session.
    static let didChangeNotification = Notification.Name("DeviceSessionDidChange")

    let instance: DeviceInstance
    let emulator: EmulatorController
    var profile: DeviceProfile { emulator.profile }
    private(set) lazy var workspace = DeviceWorkspace(emulator: emulator)

    init(instance: DeviceInstance, emulator: EmulatorController) {
        self.instance = instance
        self.emulator = emulator
        emulator.onStatusChange = { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    var phase: SessionPhase {
        if emulator.isDead {
            return .dead(emulator.baseImageMismatch
                ? "This \(profile.shortName)’s data was made with an older system image."
                : emulator.deathReason ?? "The emulator stopped.")
        }
        if emulator.isErasing || (emulator.shuttingDown && !emulator.isPoweredOff) { return .stopping }
        return emulator.isPoweredOff ? .stopped : .running
    }
}

/// Every session this process has started, the library rows, and the one
/// launch-selection default.
@MainActor final class DeviceSessionHost {
    /// Posted on the main actor when sessions or start failures change.
    static let didChangeNotification = Notification.Name("DeviceSessionHostDidChange")
    private static let lastDeviceKey = "lastDevice"

    /// This launch's options; each device's are derived from them.
    let options: LaunchOptions
    let library: DeviceLibrary
    let catalog: FirmwareCatalog
    private(set) var sessions: [DeviceSession] = []
    /// Why a device last failed to start, by catalog entry id.
    private var failures: [String: String] = [:]

    init(options: LaunchOptions) {
        self.options = options
        library = .shared
        catalog = .bundled
    }

    func session(for entry: FirmwareCatalog.Entry) -> DeviceSession? {
        sessions.first { $0.instance.firmware == entry.id }
    }

    /// The device a row runs: its session's, else the record this launch's
    /// files root adopted, else the newest. One per entry for now.
    func instance(for entry: FirmwareCatalog.Entry) -> DeviceInstance? {
        if let session = session(for: entry) { return session.instance }
        let records = library.instances(firmware: entry.id)
        return records.last { $0.legacy?.filesRoot == options.filesRoot } ?? records.last
    }

    func row(for entry: FirmwareCatalog.Entry) -> DeviceRow {
        DeviceRow(entry: entry, instanceID: instance(for: entry)?.id, session: session(for: entry)?.phase,
                  job: FirmwareJobs.shared.jobs[entry.id], failure: failures[entry.id])
    }

    // MARK: Launch

    /// The last selected entry, persisted on every selection change.
    var lastSelection: FirmwareCatalog.Entry? {
        get { UserDefaults.standard.string(forKey: Self.lastDeviceKey).flatMap(catalog.entry(id:)) }
        set { UserDefaults.standard.set(newValue?.id, forKey: Self.lastDeviceKey) }
    }

    /// Today's single-device behavior is the default: LIGHTTOUCH_DEVICE picks
    /// the board, else the last selection, else the iPod.
    var launchSelection: FirmwareCatalog.Entry? {
        switch LaunchOptions.deviceOverride {
        case .iPad1?: catalog.entry(id: FirmwareCatalog.developmentIPadID)
        case .iPodTouch2G?: catalog.entry(id: FirmwareCatalog.legacyIPodID)
        case nil: lastSelection ?? catalog.entry(id: FirmwareCatalog.legacyIPodID)
        }
    }

    /// Adopts the pre-library state on first run, and under LIGHTTOUCH_DEVICE
    /// the development device that LTM_FILES names, so its row can start.
    func adoptLegacyDevices() {
        let profile = LaunchOptions.deviceOverride
        guard profile != nil || library.instances.isEmpty else { return }
        do { _ = try library.resolve(options.adoptionInputs, profile: profile ?? .iPodTouch2G) }
        catch { logEvent("adoption: \(error.localizedDescription)") }
    }

    // MARK: Starting

    /// Starts the entry's device in its own helper, or records why it can't
    /// for the row to show. Any number of devices can run at once.
    @discardableResult
    func start(_ entry: FirmwareCatalog.Entry) -> DeviceSession? {
        if let session = session(for: entry) { return session }
        guard row(for: entry).isStartable, let profile = entry.profile else { return nil }
        let chosen = instance(for: entry)
        var options = options(for: chosen, profile: profile)
        // A prepared device boots its own base (EmulatorController checks it), never LTM_FILES.
        let missing = chosen?.base.kind == .prepared ? [] : options.missingAssets(for: profile)
        guard missing.isEmpty else {
            return fail(entry, "These device files are missing: " + missing.joined(separator: ", "))
        }
        let resolution: LegacyAdoption.Resolution
        do { resolution = try self.resolution(for: entry, options: options, profile: profile) }
        catch { return fail(entry, "Couldn’t open this device’s storage. \(error.localizedDescription)") }
        NetworkAccessPreference.configure(&options, profile: profile)
        let session = DeviceSession(instance: resolution.instance,
                                    emulator: EmulatorController(options: options, profile: profile, resolution: resolution))
        sessions.append(session)
        failures[entry.id] = nil
        session.emulator.onRestartRequested = { [weak self, weak session] in
            if let self, let session { restart(session) }
        }
        // Before any workspace exists: the inspector checks the usbmux
        // session when its view loads.
        session.emulator.start()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        return session
    }

    /// A development device boots the files it was adopted from, not
    /// whatever LTM_FILES says today, so an overlay never meets another image.
    func options(for instance: DeviceInstance?, profile: DeviceProfile) -> LaunchOptions {
        var options = options
        if let instance, instance.base.kind == .development, let legacy = instance.legacy {
            options.filesRoot = legacy.filesRoot
            if profile == .iPodTouch2G { options.nand = legacy.nand }
        }
        return options
    }

    /// Resolving is what keeps the packaged iPod on its active base pointer
    /// (and adopts it when it has no record yet). A record resolution doesn't
    /// return is used as it stands.
    func resolution(for entry: FirmwareCatalog.Entry, options: LaunchOptions,
                    profile: DeviceProfile) throws -> LegacyAdoption.Resolution {
        let chosen = instance(for: entry)
        if chosen == nil || chosen?.legacy != nil {
            let resolved = try library.resolve(options.adoptionInputs, profile: profile)
            if chosen == nil || resolved.instance.id == chosen?.id { return resolved }
        }
        guard let chosen else { throw CocoaError(.fileNoSuchFile) }
        return LegacyAdoption.Resolution(
            instance: chosen,
            packedImage: chosen.base.kind == .legacyBundled
                ? .init(key: chosen.storage.key, directory: chosen.base.path) : nil)
    }

    /// Replaces a session with a fresh helper: the dead overlay's Restart, a
    /// restore that never came alive, and the boot after an erase. The old
    /// helper is gone before the new one opens the same overlay; nothing else
    /// (the app, the other devices) stops.
    func restart(_ session: DeviceSession) {
        let id = session.instance.id
        guard sessions.contains(where: { $0 === session }), !restarting.contains(id),
              let entry = catalog.entry(id: session.instance.firmware) else { return }
        restarting.insert(id)
        logEvent("device: restarting \(session.instance.name)")
        Task {
            let released = await session.emulator.release()
            restarting.remove(id)
            guard released else {
                logEvent("device: \(session.instance.name)'s helper did not exit; not starting a second one on its storage")
                return
            }
            sessions.removeAll { $0 === session }
            start(entry)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
    private var restarting: Set<UUID> = []

    /// A controller for a device that isn't running, which never starts: the
    /// erase it runs is the one a running device gets.
    func stoppedController(for entry: FirmwareCatalog.Entry) -> EmulatorController? {
        guard session(for: entry) == nil, instance(for: entry) != nil, let profile = entry.profile else { return nil }
        let options = options(for: instance(for: entry), profile: profile)
        guard let resolution = try? resolution(for: entry, options: options, profile: profile) else { return nil }
        return EmulatorController(options: options, profile: profile, resolution: resolution)
    }

    private func fail(_ entry: FirmwareCatalog.Entry, _ reason: String) -> DeviceSession? {
        logEvent("device: \(entry.id) did not start: \(reason)")
        failures[entry.id] = reason
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        return nil
    }

    // MARK: Deleting

    /// Removes a stopped device's record and the state it lives on (overlay,
    /// snapshots). Its base image and pairing are left alone: the base may be
    /// the bundled one, and an adopted device's conf may be the shared legacy one.
    func delete(_ instance: DeviceInstance) throws {
        precondition(!sessions.contains { $0.instance.id == instance.id })
        let paths = instance.paths
        try DeviceStateStorage.erase(overlay: paths.overlay,
                                     snapshots: [paths.snapshot, paths.snapshotTmp, paths.snapshotBad],
                                     legacyMarker: paths.resetMarker)
        try library.remove(id: instance.id)
    }
}
