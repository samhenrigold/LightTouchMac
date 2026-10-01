// One device the window can show: its record, the controller that runs it,
// and the view controllers cached for it (docs/multi-device-plan.md, C).
//
// DeviceSessionHost owns the sessions. Each running device is its own
// LightTouchDevice helper (DeviceProcess), so any number can run at once, a
// dead one restarts without the app, and the others never notice.

import Cocoa

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
                : emulator.deathReason ?? profile.stoppedReason)
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
                         preparedWithoutActivation: instance.map(lacksActivation) ?? false,
                         baseRecipe: instance.flatMap(baseRecipe))
    }

    /// Read once per device, like lacksActivation.
    private var baseRecipes: [UUID: Int?] = [:]
    private func baseRecipe(_ instance: DeviceInstance) -> Int? {
        if let known = baseRecipes[instance.id] { return known }
        let version = DeviceRow.baseRecipeVersion(instance.paths.base.appendingPathComponent("device.lock.json"))
        baseRecipes[instance.id] = version
        return version
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

    /// The last selection, else the catalog's first-run device.
    var launchSelection: FirmwareCatalog.Entry? { lastSelection ?? catalog.firstRunEntry }

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
