// Created by Sam on 2026-08-05.
//
// Owns the emulator: builds argv/env from the parsed launch options, starts
// usbmuxd (for app management) before handing the main loop to a background
// thread, and exposes device input + app operations to the UI. QEMU can only
// be started once per process, so this is a single-shot controller.

import Cocoa

@MainActor
final class EmulatorController {

    let options: LaunchOptions
    private let usbmux = USBMux()
    private var started = false

    /// The VM's lifecycle. Everything the UI enables or disables keys off this;
    /// `.dead` is the one that used to be invisible — QEMU would exit and the
    /// app kept a frozen frame with every control live.
    enum VMState: Equatable {
        case notStarted, booting, running, paused, snapshotting
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
        didSet { if oldValue != deviceReachable { onStatusChange?() } }
    }

    init(options: LaunchOptions) {
        self.options = options
        usbmux.onUnexpectedExit = { [weak self] in self?.onStatusChange?() }
    }

    /// Per-user machine state (the NAND copy-on-write overlay, snapshots, logs).
    private var stateDir: URL { Bundled.stateDirectory }

    // MARK: - Boot

    func start() {
        guard !started else { return }
        started = true
        state = .booting

        // One overlay per base image, so an overlay is never replayed onto a
        // different NAND (which would shadow unrelated blocks).
        let overlay = stateDir.appendingPathComponent("nandrw-\(options.nand)", isDirectory: true)
        try? FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)

        setBootEnv()

        // usbmuxd must be listening before the guest USB core comes up.
        if options.appsync,
           let session = usbmux.start(filesRoot: options.filesRoot,
                                      nand: options.nand, overlay: overlay.path) {
            setenv("IT_USB_TCP", session.guestAddress, 1)
            setenv("IT_OSK", "1", 1)   // appsync runs imply the on-screen keyboard
        }

        var machine = "iPod-Touch"
        + ",bootrom=\(options.bootrom)"
        + ",nand=\(options.nandImage)"
        + ",nor=\(options.nor)"
        + ",nandrw=\(overlay.path)"
        if options.network {
            machine += ",wifi=on"          // brings up the emulated BCM4325
        }

        let serialLog = stateDir.appendingPathComponent("serial.log")
        Bundled.rotateLog(at: serialLog)

        var argv = [
            "LightTouchMac",
            "-M", machine,
            "-m", options.memory,
            "-display", "none",
            "-serial", "file:\(serialLog.path)",
        ]
        if options.network {
            argv += ["-netdev", "user,id=wifi0"]   // host networking via slirp
        }
        argv += restoreArgs(overlay: overlay)      // -incoming, if a snapshot is trusted

        logEmulatorBuild()
        qemu_ios_ui_attach(nil, nil)

        let thread = Thread {
            var cargs = argv.map { strdup($0) }
            cargs.append(nil)
            let rc = qemu_ios_main(Int32(argv.count), &cargs)
            // qemu_ios_main only returns when the VM stops. Observe it — a
            // discarded return is why a dead emulator looked alive.
            DispatchQueue.main.async { [weak self] in self?.qemuDidExit(code: rc) }
        }
        thread.name = "qemu-main"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 16 << 20
        thread.start()

        verifyRestoreIfNeeded()   // a bad restore self-heals within one relaunch
    }

    func stop() {
        usbmux.stop()
    }

    /// The QEMU thread returned — the VM is gone for this process (QEMU can't
    /// re-init). Flip to `.dead`; the window shows a relaunch overlay.
    private func qemuDidExit(code: Int32) {
        guard !isDead else { return }
        // A VM that exited on its own ran the overlay PAST any saved snapshot;
        // restoring stale RAM onto an advanced NAND is worse than a cold boot,
        // so drop the snapshot (unless a clean save is in progress).
        if state != .snapshotting { discardSavedState() }
        usbmux.stop()
        state = .dead(exitCode: code)
    }

    // MARK: - Liveness

    /// When the guest last painted a new frame. Advanced by DisplayView on every
    /// fresh serial; the signal behind `booting → running` and the snapshot
    /// health gate — a 100%-CPU wedge stops painting.
    private(set) var lastFrameAdvance = Date.distantPast

    func noteFrameAdvanced() {
        lastFrameAdvance = Date()
        if state == .booting { state = .running }
    }

    /// Frames within the last ~2s. Not sufficient alone for "healthy" — a
    /// locked/idle device legitimately stops painting — so the snapshot gate
    /// (Phase 5) also consults deviceReady(); this is the cheap synchronous half.
    var framesRecentlyAdvanced: Bool {
        Date().timeIntervalSince(lastFrameAdvance) < 2.0
    }

    var isRunning: Bool { state == .running }
    var isPaused:  Bool { state == .paused }
    var isDead:    Bool { if case .dead = state { return true } else { return false } }
    /// The guest can take input only while actually executing.
    var acceptsInput: Bool { state == .running }

    /// One line for the window's status area.
    var statusLine: String {
        switch state {
        case .notStarted: return "Starting…"
        case .booting:    return "Booting…"
        case .running:    return canManageApps ? "Running" : "Running — USB unavailable"
        case .paused:     return "Paused"
        case .snapshotting: return "Saving state…"
        case .dead:       return "Emulator stopped"
        }
    }

    /// Which libqemu-arm.dylib this process actually loaded, and when it was
    /// built. The dylib lives in a build tree other sessions rebuild under our
    /// feet; when "did this run have that fix?" comes up, this answers it.
    var dylibProvenance: String {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */,
                              "qemu_ios_main") else { return "dylib: symbol not found" }
        var info = Dl_info()
        guard dladdr(sym, &info) != 0, let name = info.dli_fname else { return "dylib: unknown" }
        let path = String(cString: name)
        let built = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
        return "dylib: \(path) (built \(built.map(String.init(describing:)) ?? "unknown"))"
    }

    private func logEmulatorBuild() { NSLog("emulator \(dylibProvenance)") }
    
    // MARK: - Hardware buttons
    
    private static let holdInterval: TimeInterval = 0.25
    
    private func tapButton(_ button: Int32) {
        qemu_ios_ui_button(button, true)
        // Release off the main queue: qemu_ios_ui_button is BH-marshalled and
        // thread-safe, so a stalled main runloop must not be what holds a
        // hardware button down in the guest.
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.holdInterval) {
            qemu_ios_ui_button(button, false)
        }
    }
    
    func pressHome()       { tapButton(Int32(QEMU_IOS_BUTTON_HOME)) }
    func pressLock()       { tapButton(Int32(QEMU_IOS_BUTTON_POWER)) }
    func pressVolumeUp()   { tapButton(Int32(QEMU_IOS_BUTTON_VOLUME_UP)) }
    func pressVolumeDown() { tapButton(Int32(QEMU_IOS_BUTTON_VOLUME_DOWN)) }
    func rotateLeft()      { qemu_ios_ui_rotate(false) }
    func rotateRight()     { qemu_ios_ui_rotate(true) }
    func shake()           { qemu_ios_ui_shake() }

    /// Point the accelerometer's gravity at a device tilted `angle` radians
    /// from upright — positive is clockwise as seen on screen, matching the
    /// shell layer's transform. ±0x40 counts is ±1 g in the LIS302DL model;
    /// the axis signs are the ones lis302dl_apply_orientation uses for
    /// orientations 1/3/4, so an angle of exactly ∓π/2 lands on the same
    /// vector a real rotation would.
    func setTilt(angle: Double) {
        qemu_ios_ui_accel(Int32((64 * sin(angle)).rounded()),
                          Int32((-64 * cos(angle)).rounded()), 0)
    }
    
    /// The device's orientation as degrees turned clockwise from portrait —
    /// the same value the LCD model calls its rotation, stepped in lockstep
    /// with the guest's own quarter-turn cycle (ipod_touch_kbd_rotate:
    /// portrait → landscape-right(90) → upside-down(180) → landscape-left(270)).
    /// DisplayView poses the shell from this, so all rotation must go through
    /// rotate(clockwise:) or the shell drifts out of step with the guest.
    private(set) var rotationDegrees = 0
    var isLandscape: Bool { rotationDegrees == 90 || rotationDegrees == 270 }

    /// Toggle between portrait and landscape: enter counter-clockwise (home
    /// button ends up on the right), leave by heading back the short way.
    func toggleRotation() {
        rotate(clockwise: rotationDegrees == 270)
    }

    /// Rotate a quarter turn in a named direction.
    func rotate(clockwise: Bool) {
        clockwise ? rotateRight() : rotateLeft()
        rotationDegrees = (rotationDegrees + (clockwise ? 90 : 270)) % 360
    }
    
    // MARK: - Keyboard passthrough
    
    /// Forward a host key by its macOS virtual keycode; the shim maps it to a
    /// QKeyCode exactly as ui/cocoa.m does.
    func sendKey(macKeyCode: UInt16, down: Bool) {
        qemu_ios_ui_key_mac(Int32(macKeyCode), down)
    }
    
    // MARK: - Machine control

    func pause()  { qemu_ios_ui_pause();  if state == .running { state = .paused } }
    func resume() { qemu_ios_ui_resume(); if state == .paused  { state = .running } }
    func reset()  { qemu_ios_ui_reset();  state = .booting }
    /// Kept for completeness; deliberately NOT in a menu — system_powerdown
    /// provably never completes on 3.1.3 (PMU reg 0x04–0x06 modelling gap), so
    /// exposing it is a trap that hangs the guest at 100% CPU.
    func powerDown() { qemu_ios_ui_powerdown() }

    func pasteToGuest(_ text: String) { qemu_ios_ui_paste(text) }

    // MARK: - Snapshot persistence
    //
    // The snapshot is the durable state (3.1.3 has no clean shutdown, so the
    // overlay is torn on every hard exit). The overriding invariant, B2a: it
    // must be impossible to get STUCK on a bad snapshot. Two gates enforce it —
    // never SAVE a wedged guest (health gate below), and never stay on a bad
    // RESTORE (a restored snapshot is provisional; if it doesn't come alive it
    // is quarantined and the next launch cold-boots). The overlay is never
    // auto-deleted — nuking the device is always the user's deliberate choice.

    private var snapshotURL: URL { stateDir.appendingPathComponent("snapshot-\(options.nand)") }
    private var snapshotTmpURL: URL { snapshotURL.appendingPathExtension("tmp") }
    private var snapshotBadURL: URL { snapshotURL.appendingPathExtension("bad") }
    private var restoringFromSnapshot = false

    /// `-incoming file:…` when a trusted snapshot exists — unless ⌥Option is
    /// held at launch, the muscle-memory escape from a bad saved state.
    private func restoreArgs(overlay: URL) -> [String] {
        if NSEvent.modifierFlags.contains(.option) {
            NSLog("snapshot: Option held at launch — cold boot, ignoring saved state")
            discardSavedState()
            return []
        }
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return [] }
        restoringFromSnapshot = true
        return ["-incoming", "file:\(snapshotURL.path)"]
    }

    /// A restored snapshot is provisional. If the guest doesn't paint or answer
    /// within the window, the restore is bad — quarantine it and cold-relaunch,
    /// so a bad snapshot heals on the VERY NEXT launch instead of looping.
    private func verifyRestoreIfNeeded() {
        guard restoringFromSnapshot else { return }
        Task { [weak self] in
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.framesRecentlyAdvanced { return }        // alive
                if await self.deviceReady() { return }           // alive
            }
            guard let self, !self.isDead else { return }
            NSLog("snapshot: restored state never came alive — quarantining, cold-booting")
            self.quarantineSnapshot()
            self.coldRelaunch()
        }
    }

    /// Health-gate + save + atomic promote. `completion(true)` iff a good
    /// snapshot now exists on disk. Never overwrites a good snapshot with a bad
    /// one: an unhealthy guest is skipped entirely.
    private func performSnapshot(completion: @escaping (Bool) -> Void) {
        guard state == .running else { completion(false); return }
        Task { [weak self] in
            guard let self else { completion(false); return }
            // Alive = painting recently OR answering the device probe (a locked
            // idle device stops painting but still answers). A 100%-CPU wedge
            // fails both — and must not be saved.
            let healthy: Bool
            if self.framesRecentlyAdvanced { healthy = true }
            else { healthy = await self.deviceReady() }
            guard healthy else {
                NSLog("snapshot: guest not healthy — skipping save, keeping last good snapshot")
                completion(false); return
            }
            self.state = .snapshotting
            try? FileManager.default.removeItem(at: self.snapshotTmpURL)
            qemu_ios_snapshot_save2(self.snapshotTmpURL.path)

            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                var buf = [CChar](repeating: 0, count: 256)
                let status = qemu_ios_snapshot_status(&buf, 256)
                if status == QEMU_IOS_SNAPSHOT_DONE {
                    // Atomic promote: a torn snapshot must never shadow a good one.
                    try? FileManager.default.removeItem(at: self.snapshotURL)
                    try? FileManager.default.moveItem(at: self.snapshotTmpURL, to: self.snapshotURL)
                    completion(true); return
                }
                if status == QEMU_IOS_SNAPSHOT_FAILED {
                    NSLog("snapshot: save failed: \(String(cString: buf))")
                    try? FileManager.default.removeItem(at: self.snapshotTmpURL)
                    completion(false); return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            NSLog("snapshot: save timed out")
            try? FileManager.default.removeItem(at: self.snapshotTmpURL)
            completion(false)
        }
    }

    /// Quit path: save, then let the app terminate. `completion` runs whether
    /// or not a snapshot was written (worst case is today's behaviour: a cold
    /// boot next launch).
    func beginQuitSnapshot(completion: @escaping (Bool) -> Void) {
        performSnapshot(completion: completion)
    }

    /// Menu ▸ Save State Now: save, then resume the vCPU (the save stops it).
    func saveSnapshotNow() {
        performSnapshot { [weak self] _ in
            qemu_ios_snapshot_resume()
            self?.state = .running
        }
    }

    /// Menu ▸ Discard Saved State, and the ⌥/coherence paths. Removes the
    /// snapshot and its quarantine — never the overlay.
    func discardSavedState() {
        try? FileManager.default.removeItem(at: snapshotURL)
        try? FileManager.default.removeItem(at: snapshotTmpURL)
    }

    var hasSavedState: Bool { FileManager.default.fileExists(atPath: snapshotURL.path) }

    private func quarantineSnapshot() {
        try? FileManager.default.removeItem(at: snapshotBadURL)
        try? FileManager.default.moveItem(at: snapshotURL, to: snapshotBadURL)
    }

    private func coldRelaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    
    // MARK: - App management
    
    var canManageApps: Bool { usbmux.session != nil }
    
    private func tools() throws -> DeviceTools {
        guard let session = usbmux.session else {
            throw DeviceToolsError.failed("The device is not reachable over USB yet.")
        }
        // nand-ultimate ships the GL engine shim + sblaunch baked in, so the
        // fast in-process install path is safe; other images need the script's
        // ssh engine copy.
        return DeviceTools(clientSocket: session.clientSocket, filesRoot: options.filesRoot,
                           bakedGuestTools: options.nand.contains("ultimate"))
    }
    
    /// Cheap in-process check that the guest is attached and lockdownd is
    /// answering, without spawning a tool to find out the hard way.
    func deviceReady() async -> Bool {
        guard let socket = usbmux.session?.clientSocket else { return false }
        return await Task.detached { IMobileDevice.deviceReady(socket: socket) }.value
    }

    func installedApps() async throws -> [InstalledApp] { try await tools().installedApps() }
    func uninstall(_ bundleID: String) async throws      { try await tools().uninstall(bundleID) }
    func openTerminal() async throws                     { try await tools().openTerminal() }

    /// True while any install is running — the quit guard reads this so ⌘Q
    /// mid-install prompts instead of leaving a half-installed app.
    private(set) var isInstalling = false

    func install(_ ipa: URL, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        isInstalling = true
        defer { isInstalling = false }
        return try await tools().install(ipa, progress: progress)
    }

    /// The home screen's own icon order, for the sidebar to mirror and reorder.
    private func springBoard() throws -> SpringBoardIcons {
        guard let session = usbmux.session else {
            throw DeviceToolsError.failed("The device is not reachable over USB yet.")
        }
        return SpringBoardIcons(clientSocket: session.clientSocket)
    }

    func homeScreenOrder() async throws -> [String] { try await springBoard().order() }
    func moveOnHomeScreen(_ bundleID: String, before other: String?) async throws {
        try await springBoard().move(bundleID, before: other)
    }
    
    // MARK: - Boot environment
    
    private func setBootEnv() {
        // The settings 3.1.3 will not boot without, plus the code-signing gate
        // (values from contrib/run-ipod-touch.sh).
        let env = [
            "IT_LCD_BRIGHT": "255",
            "IT_DIRECT_IBOOT": options.iBoot,
            "IT_WDT_NORESET": "1",
            "IT_TVOUT_READY": "1",
            "IT_TVOUT_VBLANK": "1",
            "IT_IMG3_SIG_ASIS": "1",   // restores the Apple boot logo on 3.1.3
            "IT_BOOT_ARGS": "amfi_allow_any_signature=1 cs_enforcement_disable=1",
            "IT_BOOT_ARGS_DELAY_MS": "1500",
            "IT_BOOT_ARGS_REPEAT": "200",
            "IT_BOOT_ARGS_INTERVAL_MS": "250",
        ]
        for (k, v) in env { setenv(k, v, 1) }
    }
}
