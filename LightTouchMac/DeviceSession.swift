// One device the window can show: its record, the controller that runs it,
// and the view controllers cached for it (docs/multi-device-plan.md, C).
//
// DeviceSessionHost owns the sessions. Each running device is its own
// LightTouchDevice helper (DeviceProcess), so any number can run at once, a
// dead one restarts without the app, and the others never notice.

import Cocoa

// MARK: - Helper process

/// One running device's LightTouchDevice (docs/multi-device-plan.md, A): spawned
/// with its own native.log, its hello checked against the board, booted once.
/// It dies once (`onDeath`, with the reason the row and the dead overlay show);
/// a restart is a new DeviceProcess. Foundation only: tests/sessions/check-sessions.py
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
    /// terminate() was asked: an exit 0 is the stop we requested, whether or not
    /// the qemuExited event made it out before the exit.
    private var stopRequested = false
    /// The spawned helper's pid, for the log: the link zeroes its own on reap.
    private var helperPID: pid_t = 0

    /// `helper` and `requirement` default to the bundled helper and the app's Team (tests pass their own).
    /// `lease` is the device's work/lease: the helper refuses to run beside another holder.
    init(instance: UUID, profile: DeviceProfile, log url: URL, lease: URL? = nil, helper: URL? = nil, requirement: String? = nil) {
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
        if let lease { configuration.arguments = ["--lease", lease.path] }
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
        helperPID = link.pid   // the spawn is synchronous
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
    /// Never after its death (the link also zeroes its pid on reap).
    func terminate() { if !isDead { stopRequested = true; link.terminate() } }
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
        else if stopRequested, termination == .exited(0) { reason = "The emulator stopped." }
        else {
            switch termination {
            case let .signaled(signal): reason = "The device helper was killed (signal \(signal))."
            case let .exited(code): reason = "The device helper exited unexpectedly (code \(code))."
            case .unknown: reason = "The device helper stopped."
            }
        }
        logEvent("device helper \(helperPID): \(termination) — \(reason)")
        died(reason)
    }

    private func died(_ reason: String) {
        guard deathReason == nil else { return }
        deathReason = reason
        log?.flush()
        onDeath?(reason)
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

    let library: DeviceLibrary
    let catalog: FirmwareCatalog
    private(set) var sessions: [DeviceSession] = []
    /// Why a device last failed to start, by catalog entry id.
    private var failures: [String: String] = [:]

    /// The one host this process runs (AppDelegate's), for the places that
    /// need every running device rather than their own: "Install on ▸".
    private(set) static weak var shared: DeviceSessionHost?

    init() {
        library = .shared
        catalog = .bundled
        Self.shared = self
    }

    func session(for entry: FirmwareCatalog.Entry) -> DeviceSession? {
        sessions.first { $0.instance.firmware == entry.id }
    }

    /// The device a row runs: its session's, else the newest record. One per entry for now.
    func instance(for entry: FirmwareCatalog.Entry) -> DeviceInstance? {
        session(for: entry)?.instance ?? library.instances(firmware: entry.id).last
    }

    func row(for entry: FirmwareCatalog.Entry) -> DeviceRow {
        let instance = instance(for: entry)
        return DeviceRow(entry: entry, instanceID: instance?.id, session: session(for: entry)?.phase,
                         job: FirmwareJobs.shared.jobs[entry.id], failure: failures[entry.id],
                         downloaded: entry.source.sha1.map { IPSWStore.shared.existing($0) != nil } ?? false,
                         preparedWithoutActivation: instance.map(lacksActivation) ?? false)
    }

    /// Read once per device: the lock doesn't change while the app runs.
    private var activationless: [UUID: Bool] = [:]
    private func lacksActivation(_ instance: DeviceInstance) -> Bool {
        if let known = activationless[instance.id] { return known }
        let lacks = DeviceInstance.lockLacksActivation(instance.paths.base.appendingPathComponent("device.lock.json"))
        activationless[instance.id] = lacks
        return lacks
    }

    // MARK: Launch

    /// The last selected entry, persisted on every selection change.
    var lastSelection: FirmwareCatalog.Entry? {
        get { UserDefaults.standard.string(forKey: Self.lastDeviceKey).flatMap(catalog.entry(id:)) }
        set { UserDefaults.standard.set(newValue?.id, forKey: Self.lastDeviceKey) }
    }

    /// The last selection, else the built-in device.
    var launchSelection: FirmwareCatalog.Entry? { lastSelection ?? catalog.bundledEntry }

    // MARK: Starting

    /// Starts the entry's device in its own helper, or records why it can't
    /// for the row to show. Any number of devices can run at once.
    @discardableResult
    func start(_ entry: FirmwareCatalog.Entry) -> DeviceSession? {
        if let session = session(for: entry) { return session }
        guard let instance = instance(for: entry), let profile = entry.profile else { return nil }
        let network = NetworkAccessPreference.resolve(profile: profile)
        let session = DeviceSession(instance: instance,
                                    emulator: EmulatorController(instance: instance, profile: profile, network: network))
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
        guard session(for: entry) == nil, let instance = instance(for: entry), let profile = entry.profile else { return nil }
        return EmulatorController(instance: instance, profile: profile)
    }

    private func fail(_ entry: FirmwareCatalog.Entry, _ reason: String) -> DeviceSession? {
        logEvent("device: \(entry.id) did not start: \(reason)")
        failures[entry.id] = reason
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        return nil
    }

    // MARK: Deleting

    /// Removes a stopped device: its directory (record, base, overlay, pairing), its logs and its settings.
    func delete(_ instance: DeviceInstance) throws {
        precondition(!sessions.contains { $0.instance.id == instance.id })
        try library.remove(id: instance.id)
        try? DeviceStateStorage.removeTree(instance.paths.logs)
        for name in DeviceInstance.perDeviceDefaults { UserDefaults.standard.removeObject(forKey: instance.defaultsKey(name)) }
    }
}
