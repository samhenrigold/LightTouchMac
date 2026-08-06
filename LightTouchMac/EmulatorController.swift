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
        let overlay = overlayURL
        // A factory reset requested by the previous process: wipe the overlay
        // (and any snapshot) now, in this fresh process, before it is reopened.
        if FileManager.default.fileExists(atPath: resetMarkerURL.path) {
            NSLog("reset: wiping device overlay back to the base image")
            try? FileManager.default.removeItem(at: overlay)
            try? FileManager.default.removeItem(at: resetMarkerURL)
            discardSavedState()
        }
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
            // discarded return is why a dead emulator looked alive. self is the
            // app-lifetime controller and the thread ends right after this, so a
            // strong capture just bridges the hop to main (weak here only warred
            // with the outer closure's implicit strong capture).
            DispatchQueue.main.async { self.qemuDidExit(code: rc) }
        }
        thread.name = "qemu-main"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 16 << 20
        thread.start()

        verifyRestoreIfNeeded()   // a bad restore self-heals within one relaunch
        startOrientationWatch()   // idle until the guest is up and reachable
    }

    func stop() {
        usbmux.stop()
        // Ends the ssh session, which is what tells the guest-side reporter to
        // exit; leaving it running would strand an iproxy and an ssh behind us.
        orientationWatch?.terminate()
        orientationWatch = nil
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
        clockwise ? rotateRight() : rotateLeft()
        rotationDegrees = (rotationDegrees + (clockwise ? 90 : 270)) % 360
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
    // So a 50 KB armv6 helper (qemu-ios/contrib/it-orientation) is streamed onto
    // the guest over the ssh path the app already uses and left running; it
    // polls SpringBoardServices' SBGetUIOrientation MIG stub — no injection, no
    // respring, nothing baked into the NAND image — and prints a line every time
    // the answer changes. Its header documents the whole chain.
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

    /// Off switch, for anyone who would rather the device never move on its own:
    /// `defaults write <bundle-id> autoRotateWithGuest -bool NO`. On by default —
    /// it is only ever driven by an explicit change on the guest's side.
    static let autoRotateDefaultsKey = "autoRotateWithGuest"
    static var autoRotateEnabled: Bool {
        UserDefaults.standard.object(forKey: autoRotateDefaultsKey) as? Bool ?? true
    }

    /// The last value SpringBoard reported, in SpringBoard's degrees (0, 90,
    /// 180, -90). nil until the first line arrives — that first one only seeds
    /// this, so a watcher that attaches to an already-running guest never yanks
    /// the shell around on connect.
    private var lastGuestOrientation: Int?
    private var orientationWatch: Process?

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
        guard Self.autoRotateEnabled, state == .running else { return }
        rotate(toward: target)
    }

    /// Where the guest-side reporter comes from: the app bundle in a packaged
    /// build, the qemu-ios checkout in a dev one. Same shape as the ssh terminal
    /// script — no helper, no auto-rotation, and nothing else changes.
    private var orientationHelperPath: String? {
        Bundled.resolve("itorient", fallbacks: [
            "\(options.filesRoot)/../qemu-ios/contrib/it-orientation/itorient",
            "\(NSHomeDirectory())/Developer/qemu-ios/contrib/it-orientation/itorient",
        ])
    }

    /// Keeps one reporter alive for as long as the app runs, re-attaching after
    /// a boot, a respring, or a dropped USB session — the same "the guest drops
    /// its services and comes back" reality GuestNotifications backs off around.
    private func startOrientationWatch() {
        guard Self.autoRotateEnabled,
              let helper = orientationHelperPath,
              let binary = try? Data(contentsOf: URL(fileURLWithPath: helper)),
              let iproxy = Bundled.tool("iproxy")
                ?? Bundled.binarySearchPaths.map({ "\($0)/iproxy" })
                    .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return }

        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.state == .running, self.canManageApps {
                    await self.runOrientationWatch(iproxy: iproxy, binary: binary)
                    // The session ended: SpringBoard restarted, the link dropped,
                    // or sshd is not there at all (an image without it). Either
                    // way the retry is cheap and silent.
                    self.lastGuestOrientation = nil
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// One session. Streams the helper into the guest over ssh's stdin, runs it
    /// in place, and reads its lines until the connection dies.
    ///
    /// `cat > … && exec …` rather than scp: it needs one connection instead of
    /// two, and it is the only way to be sure the binary that just landed is the
    /// one that runs. The write end is closed straight after the bytes go in,
    /// which is what gives `cat` its EOF.
    private func runOrientationWatch(iproxy: String, binary: Data) async {
        let port = Int.random(in: 29400...29599)
        let password = ProcessInfo.processInfo.environment["DEVICE_PASSWORD"] ?? "alpine"
        // ControlPath is deliberately absent here too — the 104-byte socket-path
        // limit is what silently disabled every guest command once before.
        let script = """
        export PATH=/usr/bin:/bin:$PATH
        "\(iproxy)" \(port) 22 >/dev/null 2>&1 &
        IP=$!
        ASK="$(mktemp -t ltorient)"
        trap 'kill $IP 2>/dev/null; rm -f "$ASK"' EXIT
        printf '#!/bin/sh\\necho %s\\n' "\(password)" > "$ASK"
        chmod 700 "$ASK"
        sleep 1
        SSH_ASKPASS="$ASK" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR -o ConnectTimeout=10 -o NumberOfPasswordPrompts=1 \
            -p \(port) root@127.0.0.1 \
            'cat > /tmp/itorient && chmod 755 /tmp/itorient && exec /tmp/itorient'
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", script]
        let input = Pipe(), output = Pipe()
        task.standardInput = input
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice

        // The handler runs on Foundation's own queue and a read can split a line
        // anywhere, so the tail lives in a box that outlives each call. Every
        // complete line hops to the main actor; nothing is parsed off it.
        let pending = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            for line in pending.take(handle.availableData) {
                guard let value = Int(line) else { continue }
                Task { @MainActor in self?.guestOrientationChanged(to: value) }
            }
        }

        orientationWatch = task
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Set before run(): a process that exits immediately would otherwise
            // finish before there was a handler to notice, and park us forever.
            task.terminationHandler = { _ in continuation.resume() }
            do {
                try task.run()
                input.fileHandleForWriting.write(binary)
                try? input.fileHandleForWriting.close()
            } catch {
                task.terminationHandler = nil
                continuation.resume()
            }
        }
        output.fileHandleForReading.readabilityHandler = nil
        if orientationWatch === task { orientationWatch = nil }
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
    /// The guest cold-boots portrait, so our tracked orientation has to follow
    /// it back. Leaving it at 90/270 left DisplayView posing the shell sideways
    /// and sizing the cutout landscape while the guest published a portrait
    /// buffer — a permanently rotated, stretched screen that no amount of
    /// rotating could fix, since every later quarter turn stayed 90° out.
    func reset()  { qemu_ios_ui_reset();  rotationDegrees = 0; state = .booting }
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
    private var overlayURL: URL { stateDir.appendingPathComponent("nandrw-\(options.nand)", isDirectory: true) }
    /// Set by a factory reset; the NEXT launch wipes the overlay before opening
    /// it (the current process holds it open, so it can't wipe it itself).
    private var resetMarkerURL: URL { stateDir.appendingPathComponent(".reset-\(options.nand)") }
    private var restoringFromSnapshot = false

    /// UserDefaults key for the Settings toggle.
    ///
    /// Back to ON now that the resume path works end to end: the guest no
    /// longer comes back frozen (store_global_state), and usbmuxd detects a
    /// resumed guest from the migrated USB address and adopts the live session
    /// instead of driving a reset+re-enumeration into it. The self-heal is also
    /// real now (it requires deviceReady, not the restore's own repaint), so a
    /// bad snapshot quarantines and cold-boots on the next launch rather than
    /// looping. Off remains one click away in Settings.
    static let resumeDefaultsKey = "resumeOnLaunch"
    static var resumeOnLaunch: Bool {
        UserDefaults.standard.object(forKey: resumeDefaultsKey) as? Bool ?? true
    }
    /// Set when the user explicitly discards saved state, so the very next quit
    /// doesn't silently re-save the current guest and drop them right back into
    /// the state they just cleared (the "discard doesn't stick" bug).
    private var skipNextQuitSnapshot = false

    /// `-incoming file:…` when a trusted snapshot exists — unless ⌥Option is
    /// held at launch, the muscle-memory escape from a bad saved state.
    private func restoreArgs(overlay: URL) -> [String] {
        if !EmulatorController.resumeOnLaunch {
            NSLog("snapshot: resume disabled in Settings — cold boot, discarding saved state")
            discardSavedState()
            return []
        }
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
                // deviceReady ONLY — deliberately not framesRecentlyAdvanced.
                // Consuming the incoming stream repaints the framebuffer, which
                // advances the frame serial at t≈0 of the restore, so the frame
                // signal reported "alive" on the first poll before the vCPU had
                // proven it can execute at all. That made the self-heal a no-op
                // for the exact failure it was written for (restore paints the
                // home screen, then wedges), so a bad snapshot looped forever
                // instead of healing. Answering the device probe requires the
                // guest to actually be running code.
                if await self.deviceReady() { return }
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
                // Do NOT keep the older snapshot. The NAND overlay is not part
                // of the snapshot and every guest write since it was taken is
                // already durable (fmss_store_page renames per page), so an old
                // snapshot restored now would put stale RAM — stale HFS journal,
                // buffer cache, inode state — on top of a NAND that has moved
                // on. That is corruption, not just a wedge. qemuDidExit already
                // discards for exactly this reason; the health-gate path must
                // agree. Quarantine (never delete the overlay) so it stays
                // diagnosable and the next launch cold-boots.
                NSLog("snapshot: guest not healthy — quarantining stale snapshot, next launch cold-boots")
                self.quarantineSnapshot()
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
                    // Never destroy a good snapshot for a save that produced no
                    // file: a premature DONE once deleted the saved state and
                    // renamed a .tmp that did not exist, reporting success.
                    // Promote only what actually exists and has bytes.
                    let size = (try? FileManager.default
                        .attributesOfItem(atPath: self.snapshotTmpURL.path))?[.size] as? Int ?? 0
                    guard size > 0 else {
                        NSLog("snapshot: reported DONE with no output — keeping existing snapshot")
                        completion(false); return
                    }
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
        // Respect the user's intent: resume turned off, or a just-issued discard.
        // Either way, saving now would resurrect exactly the state they don't want.
        guard EmulatorController.resumeOnLaunch, !skipNextQuitSnapshot else {
            NSLog("snapshot: skipping quit-save (resume off or state discarded)")
            completion(false); return
        }
        performSnapshot(completion: completion)
    }

    /// Menu ▸ Save State Now: save, then resume the vCPU (the save stops it).
    func saveSnapshotNow() {
        skipNextQuitSnapshot = false   // an explicit save clears a prior discard
        performSnapshot { [weak self] _ in
            guard let self else { return }
            // Only un-stop what THIS save stopped. Flipping to .running
            // unconditionally resurrected a VM that died during the save: the
            // dead-overlay vanished and input went to a process with no VM —
            // exactly the "dead emulator looked alive" failure .dead exists to
            // prevent. It also silently un-paused a deliberately paused guest.
            guard self.state == .snapshotting else { return }
            qemu_ios_snapshot_resume()
            self.state = .running
        }
    }

    /// The user explicitly chose Discard Saved State. Arms the quit guard so the
    /// next quit won't re-save — otherwise discarding then quitting recreates
    /// the snapshot and the next launch resumes it anyway.
    ///
    /// Separate from `discardSavedState()` on purpose: the automatic callers
    /// (resume-off at launch, ⌥, the exited-VM coherence rule) must NOT latch
    /// it. When resume-off latched the flag at launch, ticking "resume" on in
    /// Settings couldn't take effect until the launch after next — the setting
    /// read as broken and the log blamed a discard the user never performed.
    func discardSavedStateByUser() {
        skipNextQuitSnapshot = true
        discardSavedState()
    }

    /// Removes the snapshot and its quarantine — never the overlay.
    func discardSavedState() {
        try? FileManager.default.removeItem(at: snapshotURL)
        try? FileManager.default.removeItem(at: snapshotTmpURL)
        try? FileManager.default.removeItem(at: snapshotBadURL)
    }

    var hasSavedState: Bool {
        FileManager.default.fileExists(atPath: snapshotURL.path)
            || FileManager.default.fileExists(atPath: snapshotBadURL.path)
    }

    /// The full nuke: erase the device back to the base image. The overlay is
    /// open in this process, so mark it for the next launch, drop any snapshot,
    /// and cold-relaunch — start() does the wipe before reopening. Destructive
    /// and deliberate (caller confirms); the base NAND image is never touched.
    func requestFactoryReset() {
        discardSavedState()
        try? "reset".write(to: resetMarkerURL, atomically: true, encoding: .utf8)
        coldRelaunch()
    }

    private func quarantineSnapshot() {
        try? FileManager.default.removeItem(at: snapshotBadURL)
        try? FileManager.default.moveItem(at: snapshotURL, to: snapshotBadURL)
    }

    /// Relaunch, with THIS process fully gone before the next one starts.
    ///
    /// Launching first and terminating in the completion handler overlapped the
    /// two: the callback fires only after the new instance is up, by which point
    /// its start() has already wiped and reopened the overlay — while this
    /// process's QEMU was still writing pages into that same directory. A
    /// factory reset could therefore keep orphan pages from the pre-erase
    /// filesystem, and the new instance's usbmuxd reaper would SIGTERM the old,
    /// still-live daemon. `open -n` detached with a short delay lets us exit
    /// first; the successor owns the overlay alone.
    private func coldRelaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c",
                          "sleep 1; open -n \"$1\"", "sh", Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }
    
    // MARK: - App management
    
    var canManageApps: Bool { usbmux.session != nil }
    /// The usbmuxd socket to talk to this device on, for the long-lived
    /// notification_proxy watcher (which owns its own session, not a gated one).
    var usbmuxSession: String? { usbmux.session?.clientSocket }
    
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
    /// Bounded and gated. A bare `Task.detached` here had neither: `idevice_new`
    /// against a half-open usbmuxd socket blocks with no timeout, and this is
    /// called from the quit-time snapshot health gate and the restore verifier —
    /// so a wedged socket hung the quit itself. `withDeadline` abandons the
    /// blocked thread; the gate keeps it from racing other device work.
    func deviceReady() async -> Bool {
        guard let socket = usbmux.session?.clientSocket else { return false }
        let ok = try? await DeviceGate.shared.serialized {
            try await withDeadline(Timeouts.serviceProbe, "device probe") {
                IMobileDevice.deviceReady(socket: socket)
            }
        }
        return ok ?? false
    }

    func installedApps() async throws -> [InstalledApp] { try await tools().installedApps() }
    func uninstall(_ bundleID: String) async throws      { try await tools().uninstall(bundleID) }
    func openTerminal() async throws                     { try await tools().openTerminal() }
    func restartSpringBoard() async throws               { try await tools().restartSpringBoard() }

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

/// Splits a byte stream into whole lines across reads.
///
/// `@unchecked Sendable` with no lock is deliberate: Foundation serialises a
/// pipe's readability callbacks, so `take` is only ever on one thread at a time.
/// A line-per-read assumption would have been shorter and is very nearly always
/// true here — but "very nearly" on a parser that decides which way a device
/// turns is how you get a 9 out of a torn "90".
private final class LineBuffer: @unchecked Sendable {
    private var tail = Data()

    func take(_ chunk: Data) -> [String] {
        tail.append(chunk)
        var lines: [String] = []
        while let newline = tail.firstIndex(of: 0x0a) {
            lines.append(String(decoding: tail[tail.startIndex..<newline], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces))
            tail.removeSubrange(tail.startIndex...newline)
        }
        return lines
    }
}
