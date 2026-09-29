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
/// `remaining` is the estimated seconds left, nil until there is one.
nonisolated enum FirmwareJob: Equatable, Sendable {
    case downloading(fraction: Double, remaining: TimeInterval? = nil)
    case preparing(Preparation)
    case failed(String)
}

/// Where a preparation stands (the preparer contract's begin, step and progress events).
nonisolated struct Preparation: Equatable, Sendable {
    /// 1-based; 0 of 0 is a job with no steps yet (hashing an import).
    var step = 0, steps = 0
    var name: String
    /// Within the step, 0...1.
    var fraction = 0.0
    /// The preparer's expected seconds per step; equal steps without them.
    var seconds: [Double] = []
    /// The preparer's words for what the step is doing now.
    var detail: String?
    var remaining: TimeInterval?

    /// Finished steps plus this one's fraction, weighted by expected seconds; nil with no steps yet.
    var overall: Double? {
        guard steps > 0 else { return nil }
        let weights = seconds.count == steps && seconds.allSatisfy({ $0 > 0 }) ? seconds : Array(repeating: 1, count: steps)
        let done = weights.prefix(min(max(step - 1, 0), steps)).reduce(0, +)
        let current = (1...steps).contains(step) ? weights[step - 1] * min(max(fraction, 0), 1) : 0
        return min(1, (done + current) / weights.reduce(0, +))
    }
}

/// Seconds left for a job that went from `start` to `now` (0...1) in `elapsed` seconds; nil until
/// it has run 5 s and moved 2 %, so the first guesses don't swing.
nonisolated func estimatedRemaining(elapsed: TimeInterval, from start: Double, to now: Double) -> TimeInterval? {
    guard elapsed >= 5, now - start >= 0.02 else { return nil }
    return elapsed * (1 - now) / (now - start)
}

/// A started device, as the sidebar sees it.
nonisolated enum SessionPhase: Equatable, Sendable {
    case running, stopping, stopped
    case dead(String)
}

nonisolated enum DeviceRowState: Equatable, Sendable {
    enum Unavailable: Equatable, Sendable { case comingSoon, untested, requiresIPSW }
    case notDownloaded(bytes: Int64?)
    /// Its IPSW is in a store (downloaded or imported), not yet prepared.
    case downloaded
    /// The app ships its prepared base (`entry.bundled`), not yet unpacked.
    case bundled
    case downloading(fraction: Double, remaining: TimeInterval? = nil)
    case preparing(Preparation)
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
    /// The device's lock records no activation (DeviceInstance.lockLacksActivation).
    let preparedWithoutActivation: Bool

    /// `downloaded`: IPSWStore has this entry's IPSW.
    init(entry: FirmwareCatalog.Entry, instanceID: UUID?, session: SessionPhase?,
         job: FirmwareJob?, failure: String?, downloaded: Bool = false, preparedWithoutActivation: Bool = false) {
        self.entry = entry
        self.instanceID = instanceID
        self.preparedWithoutActivation = preparedWithoutActivation
        hasSession = session != nil
        state = Self.state(entry: entry, startable: instanceID != nil,
                           session: session, job: job, failure: failure, downloaded: downloaded)
    }

    /// A session outranks everything; then the catalog's own verdict, a job
    /// in flight, the last start failure, and finally whether a device exists.
    private static func state(entry: FirmwareCatalog.Entry, startable: Bool, session: SessionPhase?,
                              job: FirmwareJob?, failure: String?, downloaded: Bool) -> DeviceRowState {
        switch session {
        case .running?: return .running
        case .stopping?: return .stopping
        case let .dead(reason)?: return .error(reason)
        case .stopped?: return .ready
        case nil: break
        }
        if entry.status == .comingSoon { return .unavailable(.comingSoon) }
        if entry.status == .untested { return .unavailable(.untested) }
        switch job {
        case let .downloading(fraction, remaining)?: return .downloading(fraction: fraction, remaining: remaining)
        case let .preparing(preparation)?: return .preparing(preparation)
        case let .failed(reason)?: return .error(reason)
        case nil: break
        }
        if let failure { return .error(failure) }
        if startable { return .ready }
        if entry.bundled != nil { return .bundled }
        if downloaded { return .downloaded }
        return entry.status == .userIPSW ? .unavailable(.requiresIPSW) : .notDownloaded(bytes: entry.source.bytes)
    }

    var title: String { "iOS \(entry.version)" }
    var isExperimental: Bool { entry.status == .experimental }
    var isStartable: Bool { instanceID != nil }
    var isDimmed: Bool { if case .unavailable = state { true } else { false } }
    var isError: Bool { if case .error = state { true } else { false } }
    /// A download's or preparation's overall progress; nil while it has no steps yet.
    var progress: Double? {
        switch state {
        case let .downloading(fraction, _): fraction
        case let .preparing(preparation): preparation.overall
        default: nil
        }
    }

    /// The sidebar's words beside the ring: "43%", "Step 6 of 7 · 48%".
    var progressSummary: String? {
        let percent = progress.map { "\(Int(($0 * 100).rounded(.down)))%" }
        switch state {
        case .downloading: return percent
        case let .preparing(p): return p.steps > 0 ? "Step \(p.step) of \(p.steps)" + (percent.map { " · \($0)" } ?? "") : p.name
        default: return nil
        }
    }

    /// The placeholder's lines under the bar: the step, what it is doing, and percent with time left.
    var progressLines: [String] {
        let percent = progress.map { "\(Int(($0 * 100).rounded(.down)))%" }
        switch state {
        case let .downloading(_, remaining):
            return [[percent, remaining.map(Self.remainingText)].compactMap { $0 }.joined(separator: " · ")]
        case let .preparing(p) where p.steps > 0:
            return ["Step \(p.step) of \(p.steps): \(p.name)", p.detail,
                    [percent, p.remaining.map(Self.remainingText)].compactMap { $0 }.joined(separator: " · ")].compactMap { $0 }
        case let .preparing(p): return [p.name]
        default: return []
        }
    }

    static func remainingText(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<10: "Almost done"
        case ..<60: "About \(Int((seconds / 10).rounded(.up)) * 10) s remaining"
        case ..<5400: "About \(Int((seconds / 60).rounded())) min remaining"
        default: "About \(Int((seconds / 3600).rounded())) h remaining"
        }
    }

    /// `canDownload` is FirmwareJobs.canDownload: whether the preparer is present.
    func allows(_ action: DeviceAction, canDownload: Bool) -> Bool {
        let working = switch state { case .downloading, .preparing, .stopping: true; default: false }
        switch action {
        // A dead session's Start is a restart (DeviceSessionHost.restart).
        case .start: return isStartable && (state == .ready || isError)
        case .stop: return state == .running
        // The built-in device needs no preparer to unpack.
        case .downloadAndPrepare:
            return (canDownload || state == .bundled) && !isStartable && !working && !isDimmed
        case .importIPSW:
            return !isStartable && entry.status != .comingSoon && entry.status != .untested && !working
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
        case .notDownloaded, .downloaded, .bundled: .downloadAndPrepare
        case .downloading, .preparing: .cancel
        case .error: isStartable ? .start : entry.status == .userIPSW ? .importIPSW : .downloadAndPrepare
        case .unavailable(.requiresIPSW): .importIPSW
        case .unavailable(.comingSoon), .unavailable(.untested), .running, .stopping: nil
        }
    }

    var primaryTitle: String? {
        if isError { return "Try Again" }
        return switch primaryAction {
        case .start: "Start"
        case .downloadAndPrepare: state == .downloaded || state == .bundled ? "Prepare" : "Download & Prepare"
        case .importIPSW: "Import IPSW…"
        case .cancel: "Cancel"
        default: nil
        }
    }

    /// The row's note under the state, when there is one.
    var note: String? { preparedWithoutActivation && instanceID != nil ? "Prepared without activation" : nil }

    /// The accessory's words: what VoiceOver reads after the version.
    var stateDescription: String {
        switch state {
        case let .notDownloaded(bytes):
            bytes.map { "Not Downloaded, " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Not Downloaded"
        case .downloaded: "Downloaded"
        case .bundled: "Built In"
        case .downloading: "Downloading, " + (progressSummary ?? "")
        case .preparing: "Preparing, " + (progressSummary ?? "")
        case .ready: "Ready"
        case .running: "Running"
        case .stopping: "Stopping"
        case .error: "Error"
        case .unavailable(.comingSoon): "Coming Soon"
        case .unavailable(.untested): "Untested"
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

/// argv and environment for one boot, from paths alone. EmulatorController
/// fills it from the device record; tests from fixtures.
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
        /// A device.py/prepared device's KBAG table (the emulated AES has no GID key).
        var gidBlobs: String? = nil
        /// This boot's guest-package offer directory (GuestPackage).
        var guestPackage: String? = nil
        /// The -machine options the device was made for (device.lock.json "machine", e.g. aes-uid=engine).
        var machineOptions: [String: String] = [:]
    }

    struct IPad {
        /// The boot image: kboot.bin (direct-kernel) or, when `gidBlobs` is set, iBoot.bin (real iBoot chain).
        var kboot: String
        var nand: String
        var overlay: String
        /// "0xWORD2:0xWORD3" (identity.json); the machine uses zeros without it.
        var dieID: String?
        var writableNOR: String?
        /// Set for the iboot strategy: the base's gid-blobs.bin (the emulated AES has no GID key). Its presence
        /// picks `iboot=` over `kboot=`.
        var gidBlobs: String? = nil
        var usbAddress: String?
        var wifi: Bool
        var guestPackage: String? = nil
        var machineOptions: [String: String] = [:]
    }

    /// A prepared base's device.lock.json "machine" options; none for a missing lock or field.
    static func lockMachine(_ lock: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: lock),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let machine = object["machine"] as? [String: Any] else { return [:] }
        return machine.mapValues { "\($0)" }
    }

    /// A prepared base's boot_strategy ("iboot"/"kboot"); nil for a missing lock or field (the two older prepared
    /// iPads are kboot and carry no boot_strategy).
    static func bootStrategy(_ lock: URL) -> String? {
        guard let data = try? Data(contentsOf: lock),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["boot_strategy"] as? String
    }

    static func options(_ machine: [String: String]) -> String {
        machine.sorted { $0.key < $1.key }.map { ",\($0.key)=\(escape($0.value))" }.joined()
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
        if let blobs = d.gidBlobs { machine += ",gid-blobs=\(escape(blobs))" }
        if let offer = d.guestPackage { machine += ",guest-package=\(escape(offer))" }
        machine += options(d.machineOptions)
        let argv = ["LightTouchMac", "-M", machine, "-m", d.memory, "-display", "none", "-no-shutdown"]
            + audio + ["-serial", serial] + (netdev.map { ["-netdev", $0] } ?? []) + restore
        // The settings 3.1.3 will not boot without (contrib/run-ipod-touch.sh). No
        // IT_LCD_BRIGHT: the guest's own backlight is what makes Lock visible.
        return BootConfig(argv: argv, environment: ["IT_TVOUT_READY": "1"], machine: "iPod-Touch")
    }

    /// Wi-Fi is the machine's default (a BCM4329 on its own slirp wifi0); an
    /// explicit `netdev` replaces it. No -m: the machine's default is the K48's 256 MiB.
    static func iPad(_ d: IPad, serial: String, audio: [String], netdev: String?, restore: [String]) -> BootConfig {
        // iboot strategy: enter the pattern-patched iBoot with the catalog keys and boot the kernel from NAND, off a
        // private writable NOR (no base nor=, as ipad1_boot's writable path). kboot: the direct-kernel bundle.
        var machine: String
        if let gid = d.gidBlobs {
            machine = "ipad1,iboot=\(escape(d.kboot)),gid-blobs=\(escape(gid))"
            if let nor = d.writableNOR { machine += ",nor-rw=\(escape(nor))" }
            machine += ",nand=\(escape(d.nand)),nand-overlay=\(escape(d.overlay))"
        } else {
            machine = "ipad1,kboot=\(escape(d.kboot)),nand=\(escape(d.nand)),nand-overlay=\(escape(d.overlay))"
            if let nor = d.writableNOR { machine += ",nor-rw=\(escape(nor))" }
        }
        if let dieID = d.dieID { machine += ",die-id=\(escape(dieID))" }
        // Without a bridge the machine's built-in USB host keeps it charging.
        if let usb = d.usbAddress { machine += ",usb-tcp-addr=\(usb)" }
        if !d.wifi { machine += ",wifi=off" }
        if let offer = d.guestPackage { machine += ",guest-package=\(escape(offer))" }
        machine += options(d.machineOptions)
        // usb-kbd on the always-on EHCI becomes the active keyboard for key_mac. 20 mA: 4.x gives the
        // dock's host side AAPL,power-supply 50 and refuses the default 100 mA device ("not enough power").
        let argv = ["LightTouchMac", "-M", machine, "-display", "none", "-no-shutdown"] + audio
            + ["-serial", serial, "-device", "usb-kbd,bus=usb-bus.0,max-power=20"] + (netdev.map { ["-netdev", $0] } ?? []) + restore
        return BootConfig(argv: argv, machine: "ipad1")
    }

    /// A prepared device's boot files (W5/W6): the board's boot file (the iPad's
    /// kboot.bin, the iPod's iBoot.bin), nand/ and any `also` files from base, and
    /// on first boot the overlay directory and the writable NOR, cloned from
    /// base/nor.bin (cp -c) and made owner-writable. Nothing is written inside
    /// base/, which is read-only. usbmuxd-conf is created (and seeded) by USBMux.
    static func preparedFiles(base: URL, overlay: URL, writableNOR: URL?, boot: String = "kboot.bin",
                              also: [String] = []) throws -> (boot: URL, nand: URL, writableNOR: URL?) {
        let fm = FileManager.default
        let kboot = base.appendingPathComponent(boot), nand = base.appendingPathComponent("nand", isDirectory: true)
        for file in [kboot, nand] + also.map(base.appendingPathComponent) where !fm.fileExists(atPath: file.path) {
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
