// One device the window can show: its record, the controller that runs it,
// and the view controllers cached for it (docs/multi-device-plan.md, C).
//
// DeviceSessionHost owns the sessions and hides the one limit phase 1b still
// has. QEMU runs in-process and cannot re-initialise, so one device boots per
// launch; starting another means quitting and reopening. When W2 moves each
// device into its own helper, `canStartAnother` is always true, the reopen
// sheet goes away, and nothing else in the UI changes.

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
    case preparing(step: Int, of: Int, name: String)
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
    case preparing(step: Int, of: Int, name: String)
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
        case let .preparing(step, count, name)?: return .preparing(step: step, of: count, name: name)
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

    /// `canDownload` is FirmwareJobs.canDownload: false until W5/W6 land.
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
        case let .preparing(step, count, _): "Preparing, Step \(step) of \(count)"
        case .ready: "Ready"
        case .running: "Running"
        case .stopping: "Stopping"
        case .error: "Error"
        case .unavailable(.comingSoon): "Coming Soon"
        case .unavailable(.requiresIPSW): "Requires IPSW"
        }
    }
}

// MARK: - Firmware jobs (W5/W6)

/// Downloads and preparations per catalog entry. W5 (FirmwareDownloads) and
/// W6 (PreparationJob) fill this in; until they land nothing starts, so every
/// row stays at not downloaded and the UI for the other states is exercised
/// only by setting `jobs` directly.
@MainActor final class FirmwareJobs {
    static let shared = FirmwareJobs()
    /// Posted on the main actor after `jobs` changes.
    static let didChangeNotification = Notification.Name("FirmwareJobsDidChange")

    var jobs: [String: FirmwareJob] = [:] {
        didSet { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
    }

    /// W5/W6: true once a download and preparation can run.
    var canDownload: Bool { false }

    func downloadAndPrepare(_ entry: FirmwareCatalog.Entry) {
        logEvent("firmware: download and prepare \(entry.id) is not available yet")
    }

    /// W5: hash, look up in the catalog and clone into State/IPSW. `entry` is
    /// the row it was dropped on or imported for, if any.
    func importIPSW(_ url: URL, for entry: FirmwareCatalog.Entry?) {
        logEvent("firmware: import \(url.lastPathComponent) for \(entry?.id ?? "any entry") is not available yet")
    }

    func cancel(_ entry: FirmwareCatalog.Entry) { jobs[entry.id] = nil }
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

/// A started device. W2 swaps what runs inside `emulator` (a helper instead of
/// in-process QEMU); the session and everything that uses it stay as they are.
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
                : "The emulator stopped.")
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

    /// ponytail: QEMU is in-process and once per process, so only the first
    /// device may start. W2's helpers make this always true.
    var canStartAnother: Bool { sessions.isEmpty }

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

    /// Starts the entry's device, or records why it can't for the row to show.
    /// The caller has checked `canStartAnother`.
    @discardableResult
    func start(_ entry: FirmwareCatalog.Entry) -> DeviceSession? {
        if let session = session(for: entry) { return session }
        guard canStartAnother, row(for: entry).isStartable, let profile = entry.profile else { return nil }
        var options = options(for: instance(for: entry), profile: profile)
        let missing = options.missingAssets(for: profile)
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
