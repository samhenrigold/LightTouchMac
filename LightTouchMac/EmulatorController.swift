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
    private var packedImage: DeviceStateStorage.PackedImage?
    private var retainedPackedImage = false
    private var reportedStorageFailure = false
    private var mediaPreparationTask: Task<Void, Never>?
    private var preparingMedia = false {
        didSet { onStatusChange?() }
    }
    private var mediaPreparationFailure: String?


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
        didSet {
            if oldValue != deviceReachable { onStatusChange?() }
            // First time the guest answers is the one safe moment to clear out
            // staging uploads an earlier run abandoned: nothing of ours can be
            // in flight yet, because installing needs this very flag.
            if deviceReachable == true, !didSweepStaging {
                didSweepStaging = true
                if let socket = usbmux.session?.clientSocket {
                    Task { await DeviceServices(clientSocket: socket).sweepStaging() }
                }
            }
        }
    }
    private var didSweepStaging = false

    /// Set when a requested erase could not be performed at launch; the window
    /// reports it once it exists.
    private(set) var eraseFailure: String?
    func clearEraseFailure() { eraseFailure = nil }

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

        if !FileManager.default.fileExists(atPath: options.nandImage),
           FileManager.default.fileExists(atPath: options.packedNAND + ".sha256") {
            do {
                let selected = try DeviceStateStorage.packedImage(
                    state: stateDir, nand: options.nand, legacyKey: legacyImageKey,
                    manifest: URL(fileURLWithPath: options.packedNAND + ".sha256"))
                packedImage = selected.image
                retainedPackedImage = selected.retained
                if selected.retained {
                    NSLog("nand: preserving existing base and user data; Erase All Content and Settings adopts the bundled image")
                }
            } catch {
                NSLog("nand: could not resolve device image: \(error.localizedDescription)")
                state = .dead(exitCode: 1)
                return
            }
        }
        migrateStateNames()

        // One overlay per base image, so an overlay is never replayed onto a
        // different NAND (which would shadow unrelated blocks).
        let overlay = overlayURL
        // A factory reset requested by the previous process: wipe the overlay
        // (and any snapshot) now, in this fresh process, before it is reopened.
        if FileManager.default.fileExists(atPath: resetMarkerURL.path) {
            NSLog("reset: wiping device overlay back to the base image")
            do {
                if FileManager.default.fileExists(atPath: overlay.path) {
                    try FileManager.default.removeItem(at: overlay)
                }
                // Consume the marker only once the wipe has actually happened.
                // It used to be removed regardless, so a removal that failed
                // (a leaked process holding a page open, a permissions problem)
                // silently downgraded "Erase All Content and Settings" to
                // nothing at all — the device came back with everything the
                // user had just asked to destroy, and no error anywhere.
                try? FileManager.default.removeItem(at: resetMarkerURL)
            } catch {
                NSLog("reset: could not wipe the overlay (\(error.localizedDescription)) — "
                      + "leaving the request armed for the next launch")
                // And SAY so. The user confirmed a destructive, irreversible
                // action, the app quit, and it came back with everything still
                // there — with the erase still armed to fire, unannounced, at
                // some arbitrary later launch.
                eraseFailure = error.localizedDescription
            }
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

        // A raw NAND directory (dev checkout) is used as-is; a packaged app
        // carries only the opaque blob, unpacked into Application Support on
        // first boot — the bundle is signed and read-only, and the notary
        // would have rejected the raw pages inside it.
        let nandBase: String
        let nandUnpack: (packed: String, dest: String)?
        if FileManager.default.fileExists(atPath: options.nandImage) {
            nandBase = options.nandImage
            nandUnpack = nil
        } else {
            let dest = stateDir.appendingPathComponent(packedImage?.directory ?? "device/\(options.nand)",
                                                       isDirectory: true).path
            nandBase = dest
            nandUnpack = FileManager.default.fileExists(atPath: dest)
                ? nil : (options.packedNAND, dest)
        }

        var machine = "iPod-Touch"
        + ",bootrom=\(options.bootrom)"
        + ",nand=\(nandBase)"
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
            "-audio", "driver=coreaudio,out.buffer-count=16",
            "-serial", "file:\(serialLog.path)",
        ]
        if options.network {
            argv += ["-netdev", "user,id=wifi0"]   // host networking via slirp
        }
        argv += restoreArgs(overlay: overlay)      // -incoming, if a snapshot is trusted

        logEmulatorBuild()
        qemu_ios_ui_attach(nil, nil)

        let thread = Thread {
            // First boot of a packaged app: inflate the device image before
            // QEMU opens it. On this thread, not main — it takes a while and
            // the window already says "Booting…".
            if let nandUnpack, !Self.unpackNAND(nandUnpack.packed, into: nandUnpack.dest) {
                DispatchQueue.main.async { self.qemuDidExit(code: 1) }
                return
            }
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

        startMediaPreparation()
        verifyRestoreIfNeeded()   // a bad restore self-heals within one relaunch
        startOrientationWatch()   // idle until the guest is up and reachable
        startTimeZoneSync()       // guest zone follows the Mac's, incl. travel
    }

    /// Existing images need the same media engine/configuration as newly
    /// packaged images before apps can use the native compositor.
    private func startMediaPreparation() {
        guard options.appsync else { return }
        preparingMedia = true
        mediaPreparationFailure = nil
        mediaPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.preparingMedia = false }
            do {
                let deadline = ContinuousClock.now + .seconds(180)
                while true {
                    try Task.checkCancellation()
                    guard !isDead, !storageFailed, ContinuousClock.now < deadline else {
                        throw DeviceToolsError.failed("The device did not become ready for its media update.")
                    }
                    if state == .running, await deviceReady() { break }
                    try await Task.sleep(for: .seconds(2))
                }
                try Task.checkCancellation()
                NSLog("media: checking guest graphics components")
                if try await tools().updateMediaComponents() {
                    try await tools().reloadMediaCompositor()
                    try await waitForSpringBoard()
                    NSLog("media: guest graphics components updated")
                } else {
                    NSLog("media: guest graphics components already current")
                }
            } catch {
                if !Task.isCancelled {
                    mediaPreparationFailure = error.localizedDescription
                    NSLog("media: preparation failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Keep the guest's timezone matched to the Mac's: once when the device
    /// first answers after this boot, and again whenever the host's zone
    /// changes (travel). Set through lockdown's TimeZone value — lockdownd
    /// rewrites /var/db/timezone/localtime and SpringBoard follows live, so
    /// no respring. The guest's clock itself is UTC from the RTC model; only
    /// the zone needs the host's help.
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
            if state == .running, !preparingMedia, canManageApps, await deviceReady(),
               (try? await tools().setTimeZone(TimeZone.current.identifier)) != nil {
                return
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    func stop() {
        mediaPreparationTask?.cancel()
        usbmux.stop()
        // Ends the ssh session, which is what tells the guest-side reporter to
        // exit; leaving it running would strand an iproxy and an ssh behind us.
        orientationWatch?.terminate()
        orientationWatch = nil
    }

    /// Inflate the packed device image with the bundled ipod-helper. Into a
    /// .partial sibling first, renamed only on success, so a first launch
    /// killed mid-unpack can't leave a torn base image that boots corrupt.
    nonisolated private static func unpackNAND(_ packed: String, into dest: String) -> Bool {
        guard let helper = Bundled.tool("ipod-helper") else {
            NSLog("nand: packed image present but no bundled ipod-helper to unpack it")
            return false
        }
        NSLog("nand: first launch — unpacking the device image")
        let fm = FileManager.default
        let tmp = dest + ".partial"
        try? fm.removeItem(atPath: tmp)
        // The helper creates cs0…cs3 INSIDE the directory it is given; the
        // directory itself must already exist. Its absence was an instant
        // "The emulator stopped" on every first packaged boot.
        do {
            try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        } catch {
            NSLog("nand: could not create \(tmp): \(error.localizedDescription)")
            return false
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: helper)
        task.arguments = ["nand-unpack", packed, tmp]
        let errPipe = Pipe()
        task.standardError = errPipe
        do { try task.run() } catch {
            NSLog("nand: could not run ipod-helper: \(error.localizedDescription)")
            return false
        }
        // Drain before waiting: a full stderr pipe otherwise deadlocks unpack.
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            NSLog("nand: unpack failed (exit \(task.terminationStatus)): \(err)")
            return false
        }
        do { try fm.moveItem(atPath: tmp, toPath: dest) } catch {
            NSLog("nand: could not move the unpacked image into place: \(error.localizedDescription)")
            return false
        }
        return true
    }

    /// The QEMU thread returned — the VM is gone for this process (QEMU can't
    /// re-init). Flip to `.dead`; the window shows a relaunch overlay.
    private func qemuDidExit(code: Int32) {
        guard !isDead else { return }
        // A VM that exited on its own ran the overlay PAST any saved snapshot;
        // restoring stale RAM onto an advanced NAND is worse than a cold boot,
        // so drop the snapshot (unless a clean save is in progress).
        if state != .snapshotting { discardSavedState() }
        mediaPreparationTask?.cancel()
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

    var storageFailed: Bool { qemu_ios_ui_storage_failed() }

    func pollStorageFailure() {
        if storageFailed, !reportedStorageFailure {
            reportedStorageFailure = true
            discardSavedState()
            onStatusChange?()
        }
    }

    var isRunning: Bool { state == .running && !storageFailed && !preparingMedia && !restartingSpringBoard }
    var isPaused:  Bool { state == .paused }
    var isDead:    Bool { if case .dead = state { return true } else { return false } }
    /// The guest can take input only while actually executing.
    var acceptsInput: Bool { isRunning }

    /// One line for the window's status area.
    var statusLine: String {
        if storageFailed { return "Storage write failed — device stopped; latest changes were not saved" }
        switch state {
        case .notStarted: return "Starting…"
        case .booting:    return "Booting…"
        case .running:
            if restartingSpringBoard { return "Restarting SpringBoard…" }
            if preparingMedia { return "Preparing device media…" }
            if let mediaPreparationFailure { return "Media update failed — \(mediaPreparationFailure)" }
            if retainedPackedImage { return "Running — existing image retained; erase device to upgrade" }
            return canManageApps ? "Running" : "Running — USB unavailable"
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
    
    private var restartingSpringBoard = false {
        didSet { onStatusChange?() }
    }

    private static let holdInterval: TimeInterval = 0.10
    
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
        // A restored guest can already be in landscape, and the app starts every
        // process at 0 — so on the restore path the FIRST reading is the truth,
        // not a seed. Left seeded, the shell posed portrait over a landscape
        // buffer and every later quarter turn stayed 90° out, which no amount of
        // rotating could fix (the same failure reset() re-derives for).
        if restoringFromSnapshot, lastGuestOrientation == nil,
           let target = hostDegrees(forGuest: degrees), target != rotationDegrees {
            lastGuestOrientation = degrees
            rotate(toward: target)
            return
        }
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
        # EXIT alone is not enough: stop() sends SIGTERM, and a shell killed by an
        # uncaught signal never runs its EXIT trap — so every quit stranded an
        # iproxy holding a port and an ssh holding a guest process.
        trap 'kill $IP 2>/dev/null; rm -f "$ASK"; exit 0' EXIT INT TERM HUP
        printf '#!/bin/sh\\necho %s\\n' "\(password)" > "$ASK"
        chmod 700 "$ASK"
        sleep 1
        SSH_ASKPASS="$ASK" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR -o ConnectTimeout=10 -o NumberOfPasswordPrompts=1 \
            -p \(port) root@127.0.0.1 \
            'pkill -f /tmp/itorient 2>/dev/null; rm -f /tmp/itorient; \
             cat > /tmp/itorient && chmod 755 /tmp/itorient && exec /tmp/itorient'
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
            let data = handle.availableData
            Task { @MainActor [weak self] in
                guard let self else { return }
                for line in pending.take(data) {
                    guard let value = Int(line) else { continue }
                    self.guestOrientationChanged(to: value)
                }
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
    func resume() {
        guard !storageFailed else { return }
        qemu_ios_ui_resume()
        if state == .paused { state = .running }
    }
    /// The guest cold-boots portrait, so our tracked orientation has to follow
    /// it back. Leaving it at 90/270 left DisplayView posing the shell sideways
    /// and sizing the cutout landscape while the guest published a portrait
    /// buffer — a permanently rotated, stretched screen that no amount of
    /// rotating could fix, since every later quarter turn stayed 90° out.
    /// Restart the guest. Refused mid-save: the save has already stopped the
    /// vCPU, so `system_reset` would not restart it, and overwriting the state
    /// with `.booting` meant the save's own completion declined to resume it —
    /// leaving a stopped machine labelled "Booting…" with all input dead, and no
    /// way back except stumbling onto Device ▸ Resume.
    func reset() {
        guard !storageFailed else { return }
        guard state != .snapshotting else {
            NSLog("reset: ignored while a state save is in flight")
            return
        }
        // Flush first. A bare system_reset is the same hard cut as a SIGKILL as
        // far as the guest's filesystem is concerned — it loses the HFS+ catalog
        // updates still in memory, which is how a device ends up on the
        // Connect-to-iTunes screen. The quit path has done this for a while;
        // Restart, which is one menu row away from Erase, was still doing it
        // the dangerous way.
        let preparation = mediaPreparationTask
        preparation?.cancel()
        Task { [weak self] in
            guard let self else { return }
            await preparation?.value
            if self.canManageApps {
                _ = await withSoftDeadline(20) { try? await self.syncFilesystem() }
            }
            guard !self.storageFailed, self.state != .snapshotting else { return }
            qemu_ios_ui_reset()
            self.rotationDegrees = 0
            self.state = .booting
            self.startMediaPreparation()
        }
    }
    /// Kept for completeness; deliberately NOT in a menu — system_powerdown
    /// provably never completes on 3.1.3 (PMU reg 0x04–0x06 modelling gap), so
    /// exposing it is a trap that hangs the guest at 100% CPU.
    func powerDown() { qemu_ios_ui_powerdown() }

    func pasteToGuest(_ text: String) { qemu_ios_ui_paste(text) }

    // MARK: - Snapshot persistence
    //
    // Snapshots persist RAM alongside the NAND overlay. The invariant: it
    // must be impossible to get STUCK on a bad snapshot. Two gates enforce it —
    // never SAVE a wedged guest (health gate below), and never stay on a bad
    // RESTORE (a restored snapshot is provisional; if it doesn't come alive it
    // is quarantined and the next launch cold-boots). The overlay is never
    // auto-deleted — nuking the device is always the user's deliberate choice.

    /// Adopt state written before the key included the files-root.
    ///
    /// Without this, adding the root to the key silently hands every existing
    /// user a factory-fresh device: their overlay is still on disk under the old
    /// name, just no longer looked at. Renaming is the whole migration, and it
    /// only fires when the new name is absent — so it can never overwrite state
    /// that already belongs to this image.
    private func migrateStateNames() {
        // Content-keyed images must never adopt another image's overlay.
        guard packedImage == nil || packedImage?.key == legacyImageKey else { return }
        let fm = FileManager.default
        for (old, new) in [("nandrw-\(options.nand)", "nandrw-\(imageKey)"),
                           ("snapshot-\(options.nand)", "snapshot-\(imageKey)"),
                           (".reset-\(options.nand)", ".reset-\(imageKey)")]
        where old != new {
            let from = stateDir.appendingPathComponent(old)
            let to = stateDir.appendingPathComponent(new)
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            do {
                try fm.moveItem(at: from, to: to)
                NSLog("state: adopted \(old) as \(new)")
            } catch {
                NSLog("state: could not adopt \(old) (\(error.localizedDescription))")
            }
        }
    }

    /// Distinguishes two base images that happen to share a directory name.
    /// Keying on the name alone meant `LTM_FILES=/a` and `LTM_FILES=/b`, both
    /// holding a "nand-ultimate", shared one copy-on-write overlay and one
    /// snapshot — image B read through image A's overlay, and a snapshot taken
    /// on A restored onto B. That is the stale-RAM-over-different-flash
    /// corruption this file's own comments spend paragraphs avoiding.
    private var imageKey: String { packedImage?.key ?? legacyImageKey }

    private var legacyImageKey: String {
        let root = options.filesRoot
        guard !root.isEmpty else { return options.nand }
        // Short, stable, and readable enough to identify in Finder.
        var hash: UInt64 = 5381
        for byte in root.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return "\(options.nand)-\(String(hash, radix: 36))"
    }

    private var snapshotURL: URL { stateDir.appendingPathComponent("snapshot-\(imageKey)") }
    private var snapshotTmpURL: URL { snapshotURL.appendingPathExtension("tmp") }
    private var snapshotBadURL: URL { snapshotURL.appendingPathExtension("bad") }
    private var overlayURL: URL { stateDir.appendingPathComponent("nandrw-\(imageKey)", isDirectory: true) }
    /// Set by a factory reset; the NEXT launch wipes the overlay before opening
    /// it (the current process holds it open, so it can't wipe it itself).
    private var resetMarkerURL: URL { stateDir.appendingPathComponent(".reset-\(imageKey)") }
    private var restoringFromSnapshot = false

    /// UserDefaults key for the Settings toggle.
    ///
    /// Opt-in until resume is validated across the supported guest workloads.
    static let resumeDefaultsKey = "resumeOnLaunch"
    static var resumeOnLaunch: Bool { false }
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
            // IGNORE, not delete — the log said "ignoring" while the code
            // removed the file. Option is held for all sorts of reasons at
            // launch, and this is meant to be the escape hatch from a bad
            // snapshot, not a way to lose a good one by accident. Discarding is
            // what Discard Saved State is for.
            NSLog("snapshot: Option held at launch — cold boot, keeping saved state")
            return []
        }
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return [] }
        // The snapshot holds RAM; the overlay holds flash. They are only a
        // matching pair if nothing wrote to flash after the save. An observed
        // exit already discards for this reason (qemuDidExit), but a crash or a
        // SIGKILL — Xcode's stop button, a force quit — never gets there, so a
        // "Save State Now" followed by an hour of play and a kill would restore
        // hour-old RAM onto an hour-newer filesystem. Stale HFS+ journal and
        // buffer-cache state over live flash is corruption, not a slow boot.
        if overlayIsNewerThanSnapshot(overlay: overlay) {
            NSLog("snapshot: overlay has advanced past the saved state — cold boot, discarding")
            discardSavedState()
            return []
        }
        restoringFromSnapshot = true
        return ["-incoming", "file:\(snapshotURL.path)"]
    }

    private func overlayIsNewerThanSnapshot(overlay: URL) -> Bool {
        DeviceStateStorage.overlayIsNewer(overlay, than: snapshotURL)
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
                // Deliberately not framesRecentlyAdvanced on its own: consuming
                // the incoming stream repaints the framebuffer, so the frame
                // signal says "alive" at t≈0 of the restore, before the vCPU has
                // proven it can execute at all. That made the self-heal a no-op
                // for the exact failure it was written for. proveAlive asks the
                // guest to do something instead of watching for it.
                if await self.proveAlive() { return }
            }
            guard let self, !self.isDead else { return }
            NSLog("snapshot: restored state never came alive — quarantining, cold-booting")
            self.quarantineSnapshot()
            self.quitForRelaunch(reason: "restored state never came alive")
        }
    }

    /// Health-gate + save + atomic promote. `completion(true)` iff a good
    /// snapshot now exists on disk. Never overwrites a good snapshot with a bad
    /// one: an unhealthy guest is skipped entirely.
    /// Worst case for a quit-time save: the liveness probe plus the save poll.
    static let quitSnapshotBudget: TimeInterval = Timeouts.serviceProbe * 2 + 3 + 15

    private func performSnapshot(completion: @escaping (Bool) -> Void) {
        guard isRunning else { completion(false); return }
        Task { [weak self] in
            guard let self else { completion(false); return }
            guard await self.proveAlive() else {
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
            guard self.isRunning else { completion(false); return }
            self.state = .snapshotting
            try? FileManager.default.removeItem(at: self.snapshotTmpURL)
            qemu_ios_snapshot_save2(self.snapshotTmpURL.path)

            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                var buf = [CChar](repeating: 0, count: 256)
                let status = qemu_ios_snapshot_status(&buf, 256)
                if status == QEMU_IOS_SNAPSHOT_DONE {
                    guard !self.storageFailed else {
                        self.resumeAfterFailedSave(); completion(false); return
                    }
                    do {
                        try DeviceStateStorage.promoteSnapshot(from: self.snapshotTmpURL, to: self.snapshotURL)
                    } catch {
                        NSLog("snapshot: could not promote saved state: \(error.localizedDescription)")
                        self.resumeAfterFailedSave(); completion(false); return
                    }
                    completion(true); return
                }
                if status == QEMU_IOS_SNAPSHOT_FAILED {
                    NSLog("snapshot: save failed: \(String(cString: buf))")
                    try? FileManager.default.removeItem(at: self.snapshotTmpURL)
                    self.resumeAfterFailedSave(); completion(false); return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            NSLog("snapshot: save timed out")
            try? FileManager.default.removeItem(at: self.snapshotTmpURL)
            self.resumeAfterFailedSave()
            completion(false)
        }
    }

    /// Put the machine back the way a save found it.
    ///
    /// The save stops the vCPU (`qmp_stop` inside the migration bottom half) and
    /// parks the controller in `.snapshotting`. Every failure exit used to leave
    /// both that way, which is worse than the failed save: `.snapshotting` is
    /// not `.running`, so input is refused, and — the expensive one — the quit
    /// path's clean shutdown checks for a running guest and declined, so a
    /// failed quit-save silently cost the user the filesystem flush as well as
    /// the snapshot. Success deliberately does NOT resume: the caller decides
    /// (Save State Now resumes; the quit path is about to exit).
    private func resumeAfterFailedSave() {
        guard state == .snapshotting else { return }
        qemu_ios_snapshot_resume()
        state = .running
    }

    /// Make the guest prove it is executing, rather than watching for a sign.
    ///
    /// "Is the guest alive" has three answers here and only two used to be
    /// handled. Painting means alive. Answering lockdownd means alive. But
    /// *silence* is ambiguous — a locked, idle device paints nothing and a
    /// wedged one paints nothing, and neither answers when there is no usbmuxd
    /// session at all (`--no-appsync`), when usbmuxd has died, or when the gate
    /// is refusing work after earlier timeouts. Every one of those read as
    /// "unhealthy", which quarantined a perfectly good snapshot and, on the
    /// restore path, force-quit a perfectly good guest.
    ///
    /// So when the passive signals say nothing, ask a question: a Home press
    /// wakes the screen and repaints. A guest that is executing answers within
    /// a frame or two; a wedged one never does.
    func proveAlive() async -> Bool {
        guard !storageFailed else { return false }
        if framesRecentlyAdvanced { return true }
        if canManageApps, await deviceReady() { return true }
        pressHome()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            if framesRecentlyAdvanced { return true }
        }
        return false
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

    /// Request kernel unmount via ithalt, then require the guest's final PMU
    /// power-off write. The helper banner, lost SSH connection, and `sync`
    /// only prove progress; none establish a completed shutdown.
    /// The halt command and its confirmation share a 30-second budget, followed
    /// by a best-effort sync. No guest UI gestures are used on shutdown.
    static let cleanShutdownBudget: TimeInterval = 30 + 20 + 5

    func beginCleanShutdown(completion: @escaping (Bool) -> Void) {
        guard !storageFailed, !isDead, state != .notStarted else { completion(false); return }
        // Never underneath a save. `Save State Now` stops the vCPU and is still
        // writing; resuming it here produced a snapshot captured across a
        // running CPU and then promoted it as good, for the NEXT launch to
        // restore. reset() is guarded for exactly this reason.
        guard state != .snapshotting else {
            NSLog("quit: a state save is in flight — leaving the guest alone")
            completion(false); return
        }
        // A stopped vCPU cannot run any of this. Pause, or a save that stopped
        // it, used to make this give up silently — and giving up here is the one
        // failure that costs the user data.
        qemu_ios_snapshot_resume()   // no-op if already running
        state = .running

        let preparation = mediaPreparationTask
        preparation?.cancel()
        Task { [weak self] in
            guard let self else { completion(false); return }
            await preparation?.value

            let confirmed = { !self.storageFailed && qemu_ios_ui_guest_shutdown_confirmed() }
            let stopped = { self.storageFailed || self.isDead }
            if self.canManageApps {
                let haltDeadline = Date().addingTimeInterval(30)
                _ = await withSoftDeadline(30) { () -> Bool in
                    do { try await self.haltFilesystem(); return true }
                    catch {
                        NSLog("quit: halt command ended without acknowledgement (\(error.localizedDescription)); waiting for guest power-off")
                        return false
                    }
                } ?? false
                // sshd can close before its final stdout packet is delivered.
                // The PMU event is authoritative even if the marker was lost.
                if await DeviceStateStorage.waitForShutdown(until: haltDeadline,
                                                            confirmed: confirmed, stopped: stopped) {
                    NSLog("quit: guest confirmed power-off — volume unmounted")
                    completion(true); return
                }
                if confirmed() { completion(true); return }
                if stopped() { completion(false); return }
                let synced = await withSoftDeadline(20) { () -> Bool in
                    (try? await self.syncFilesystem()) != nil
                } ?? false
                if synced {
                    NSLog("quit: guest synced; unmount still unconfirmed")
                }
            }

            if confirmed() { completion(true); return }
            if stopped() { completion(false); return }
            NSLog("quit: guest did not shut down — this session's writes may be lost")
            completion(false)
        }
    }

    /// Menu ▸ Save State Now: save, then resume the vCPU (the save stops it).
    /// Set by the menu action so a failed save can be reported. The save is
    /// otherwise indistinguishable from a successful one — including the case
    /// where it DISCARDS the user's existing saved state because the guest is
    /// not answering.
    var onSnapshotResult: ((Bool) -> Void)?

    func saveSnapshotNow() {
        skipNextQuitSnapshot = false   // an explicit save clears a prior discard
        performSnapshot { [weak self] ok in
            guard let self else { return }
            self.onSnapshotResult?(ok)
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
        quitForRelaunch(reason: "factory reset requested")
    }

    /// The quit that was going to perform the erase was called off, so disarm
    /// it. Without this the marker survived on disk with the app still running
    /// normally and nothing on screen to say so — and the wipe then fired,
    /// unannounced and unconfirmed, at whatever launch happened next. (Cancel is
    /// reachable: the in-progress-install prompt on the quit path offers it.)
    func cancelFactoryReset() {
        guard FileManager.default.fileExists(atPath: resetMarkerURL.path) else { return }
        NSLog("reset: quit cancelled — disarming the pending erase")
        try? FileManager.default.removeItem(at: resetMarkerURL)
    }

    private func quarantineSnapshot() {
        try? FileManager.default.removeItem(at: snapshotBadURL)
        try? FileManager.default.moveItem(at: snapshotURL, to: snapshotBadURL)
    }

    /// Quit, and leave reopening to the user.
    ///
    /// This used to `open -n` a successor. Two instances then existed at once
    /// whenever our own exit was slow — which a wedged guest guarantees — and
    /// they fought over one NAND overlay and one usbmuxd pid file. An app that
    /// spawns copies of itself behind the user's back is the wrong shape for
    /// this regardless: QEMU cannot re-init in-process, so "relaunch" is only
    /// ever "quit, then the user reopens".
    private func quitForRelaunch(reason: String) {
        NSLog("relaunch: \(reason) — quitting; reopen the app to continue")
        NSApp.terminate(nil)
    }

    // MARK: - App management
    
    var canManageApps: Bool { usbmux.session != nil && !storageFailed }

    /// The question every app-management command actually wants answered.
    ///
    /// `canManageApps` only says the host daemon is alive, and it is true from
    /// the moment usbmuxd starts — through the whole boot and USB enumeration,
    /// which is ~40s on a warm image and past three minutes on a first boot.
    /// Gating on it alone left Install App… and Open SSH enabled that whole
    /// time, so choosing them opened a file picker (or a Terminal window) for a
    /// device that could only answer "not reachable over USB yet". The
    /// inspector's own buttons already waited for a real round trip; the menu
    /// and toolbar were the ones still guessing. `deviceReachable` is that round
    /// trip, set by the list poll, and nil until the first one lands.
    var canReachDevice: Bool { canManageApps && isRunning && deviceReachable == true }

    /// Adding to the ready queue opens no guest session. A probe suppressed by
    /// our own install must not disable File → Install App or drag-and-drop.
    var canQueueInstall: Bool {
        canManageApps && isRunning && (deviceReachable == true || AppInstaller.isUsingDevice || isInstalling)
    }
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
        // Bounded INCLUDING the wait for the gate. withDeadline bounds the probe
        // itself, but not the queue in front of it, and this is called from the
        // quit path — where waiting out a 120s uninstall means the app's own
        // backstop fires and the guest is killed without ever being asked to
        // power down. Giving up on the answer is safe; every caller treats a
        // silent device as "could not prove it is alive", not "it is dead".
        let ok = await withSoftDeadline(Timeouts.serviceProbe * 2) {
            try? await DeviceGate.shared.serialized {
                try await withDeadline(Timeouts.serviceProbe, "device probe") {
                    IMobileDevice.deviceReady(socket: socket)
                }
            }
        }
        return ok.flatMap { $0 } ?? false
    }

    func installedApps() async throws -> [InstalledApp] { try await tools().installedApps() }

    /// nil when we could not ask. Anything other than "Activated"/"FactoryActivated"
    /// means the guest is sitting on the Connect-to-iTunes screen.
    func activationState() async -> String? {
        guard let socket = usbmux.session?.clientSocket else { return nil }
        return await DeviceServices(clientSocket: socket).activationState()
    }
    func uninstall(_ bundleID: String) async throws      { try await tools().uninstall(bundleID) }
    func launchApp(_ bundleID: String) async throws      { try await tools().launchApp(bundleID) }
    func openTerminal() async throws                     { try await tools().openTerminal() }
    func syncFilesystem() async throws                   { try await tools().syncFilesystem() }
    func haltFilesystem() async throws                   { try await tools().haltFilesystem() }
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
        return SpringBoardIcons(clientSocket: session.clientSocket)
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

    /// The code-signing gate 3.1.3 needs, plus `-v` when the user asked for it.
    static var bootArgs: String {
        let base = "amfi_allow_any_signature=1 cs_enforcement_disable=1"
        return verboseBoot ? base + " -v" : base
    }

    private func setBootEnv() {
        // The settings 3.1.3 will not boot without, plus the code-signing gate
        // (values from contrib/run-ipod-touch.sh).
        // No IT_LCD_BRIGHT override: it pinned the panel at full exposure, so
        // the guest turning its backlight off (the Lock button's entire visible
        // effect) never reached the window and Lock read as dead. The harness
        // keeps the override — its checks count lit pixels.
        let env = [
            "IT_DIRECT_IBOOT": options.iBoot,
            "IT_TVOUT_READY": "1",
            "IT_TVOUT_VBLANK": "1",
            "IT_AMC_DECODE": "1",
            "IT_MPVD_DECODE": "1",
            "IT_H264_DECODE": "1",
            "IT_SCALER_DECODE": "1",
            "IT_LCD_PLANES": "1",
            "IT_IMG3_SIG_ASIS": "1",   // restores the Apple boot logo on 3.1.3
            // `-v` when asked: iPhone OS shows the kernel's console output over
            // the boot logo instead of the Apple mark, which is the only view
            // of what the guest is doing between iBoot and SpringBoard. Off by
            // default because it replaces the logo for every boot.
            //
            // NOTE for scripts/regress_app.py: its env-parity check compares
            // IT_BOOT_ARGS against the harness. Verbose is an app-side option
            // the harness has no equivalent for, so parity is asserted on the
            // base string, which is what is shared.
            "IT_BOOT_ARGS": Self.bootArgs,
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
