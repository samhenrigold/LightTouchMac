import DeviceRuntime
import Foundation
import HostRuntime
import IOSurface

// One VM in this process: QEMU's thread, the frame/status pump, commands,
// requests, agent RPC, audio capture and the bounded host halt. Mode-agnostic:
// main.swift wires it to the app's link, or to the headless/one-shot runners.

final class DeviceHost: @unchecked Sendable {
    let qemu: Qemu
    let status: StatusBlock
    let ring: FrameRingWriter

    /// A new ring exists; send it to the reader BEFORE it is activated. On the pump's queue: @Sendable, so a closure
    /// main.swift's @MainActor modes set here isn't main-actor isolated, which Swift 6 checks where it runs (SIGTRAP).
    var onRingChanged: (@Sendable (FrameRingWriter) -> Void)?
    /// On the pump's or the audio queue, as onRingChanged.
    var onEvent: (@Sendable (LinkEvent) -> Void)?
    /// QEMU returned (or the shutdown gave up), on the main queue. Default: exit with the code.
    var onExit: (@MainActor (Int32) -> Void)?
    var bootStorageAuthority: ((StorageBootProof) throws -> Void)?
    /// A sandboxed helper's USB cable (USBBridge): QEMU's usb-tcp-addr points at it. Set before the boot.
    var usbBridge: USBBridge?

    private let pumpQueue = DispatchQueue(label: "LightTouch.frames", qos: .userInteractive)
    private var pump: DispatchSourceTimer?
    private var ticks = 0
    private var frameSerial: UInt64 = 0
    private var guestPasteboardSerial: UInt64 = 0
    private let stateLock = NSLock()
    private var bootConfig: BootConfig?
    /// The device's web proxy (WebProxy.swift), for the life of the process.
    private var webProxy: WebProxy?
    private var exited = false
    private var cleanStopAsked = false
    private var shuttingDown = false
    private var activity: NSObjectProtocol?
    // pumpQueue: what paces the pump (pace()).
    private var activityLive = false
    private var screenVisible = true
    private var paused = false
    private var displayOn = true
    private var lastInput: UInt64 = 0
    private var constrained = DeviceHost.hostConstrained()
    private var live = false
    private var pumpInterval = 0.0
    private var powerObservers: [NSObjectProtocol] = []
    private lazy var agents = AgentDispatcher(qemu: qemu)
    private lazy var audio = AudioPump(qemu: qemu) { [weak self] in self?.onEvent?($0) }

    init(qemu: Qemu, status: StatusBlock) {
        self.qemu = qemu
        self.status = status
        ring = FrameRingWriter(status: status)
        status[.guestPackageSupported] = qemu.guestPackageReport != nil ? 1 : 0
    }

    var booted: Bool { stateLock.withLock { bootConfig != nil } }
    var hasExited: Bool { stateLock.withLock { exited } }

    func info(board: String?) -> HelperInfo {
        HelperInfo(
            protocolVersion: DeviceLinkWire.protocolVersion,
            pid: getpid(),
            dylibPath: qemu.path,
            dylibModified: qemu.modified,
            buildID: qemu.buildID?().map { String(cString: $0) },
            deviceInfo: board.flatMap { board in qemu.machines.first { $0.board == board } },
            storageProofValidation: true
        )
    }

    // MARK: - Pump

    /// Frames at the panel's refresh (BootConfig.refreshHz: 60 Hz, 120 with the experimental setting; 30 under
    /// serious thermal pressure or Low Power Mode) while the app shows the screen and the guest's display is on
    /// (or was just touched) and the machine isn't paused; otherwise 4 Hz, enough for the status block and a hidden
    /// device's first frames. Status at 20 Hz live, every tick otherwise; the heartbeat on every tick (also before
    /// boot). A new rate starts with a tick at once, so a screen shown again gets its frame then.
    func startPump() {
        let timer = DispatchSource.makeTimerSource(queue: pumpQueue)
        timer.setEventHandler { [weak self] in self?.tick() }
        pump = timer
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange]
        {
            powerObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    guard let self else { return }
                    self.pumpQueue.async {
                        self.constrained = DeviceHost.hostConstrained()
                        self.pace()
                    }
                }
            )
        }
        pumpQueue.sync { pace(force: true) }
        timer.resume()
    }

    /// LTM_HOST_CONSTRAINED=1 stands in for either (tests).
    static func hostConstrained() -> Bool {
        ProcessInfo.processInfo.environment["LTM_HOST_CONSTRAINED"] == "1"
            || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
            || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// The app shows (or stopped showing) this device's screen.
    func setScreenVisible(_ visible: Bool) {
        pumpQueue.async { [self] in
            screenVisible = visible
            pace()
        }
    }

    /// Input wakes a dark display: run live at once, so the lit screen's first frames are not 250 ms late.
    private func noteInput() {
        pumpQueue.async { [self] in
            lastInput = DispatchTime.now().uptimeNanoseconds
            pace()
        }
    }

    /// pumpQueue: pick the pump's rate and the process activity for the current state.
    private func pace(force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        let next = screenVisible && !paused && (displayOn || now &- lastInput < 2_000_000_000)
        // Live, a frame per panel refresh (60 Hz, or the experimental 120); 30 under pressure.
        let hz = stateLock.withLock { bootConfig?.refreshHz } ?? 60
        let interval = next ? (constrained ? 1.0 / 30 : 1.0 / Double(hz)) : 0.25
        holdActivity(live: next)
        guard force || interval != pumpInterval else { return }
        live = next
        pumpInterval = interval
        pump?.schedule(deadline: .now(), repeating: interval, leeway: next ? .milliseconds(2) : .milliseconds(50))
    }

    /// pumpQueue. A booted VM keeps App Nap off for good (its timers are the guest's clock); only while
    /// live does it also keep the Mac from idle sleep and turn off timer coalescing.
    private func holdActivity(live: Bool) {
        guard let machine = stateLock.withLock({ exited ? nil : bootConfig?.machine }) else { return }
        guard activity == nil || live != activityLive else { return }
        let next = ProcessInfo.processInfo.beginActivity(
            options: live ? [.userInitiated, .latencyCritical] : .userInitiatedAllowingIdleSystemSleep,
            reason: "Running an emulated device (\(machine))"
        )
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = next
        activityLive = live
    }

    private func tick() {
        ticks += 1
        status.bumpHeartbeat()
        guard booted else { return }
        if !live || ticks % 3 == 0 { refreshStatus() }
        // Every tick, not at the status rate: a buzz's start and end are worth a frame's latency.
        if let vibrator = qemu.vibrator {
            var pulses: UInt64 = 0
            status[.vibrating] = vibrator(&pulses) ? 1 : 0
            status[.vibratorPulses] = pulses
        }
        let on = !qemu.displaySleeping()
        if on != displayOn || (live && !on) {
            displayOn = on
            pace()
        }  // the latter: input's 2 s running out
        var pixels: UnsafeRawPointer?
        var w: Int32 = 0
        var h: Int32 = 0
        var serial = frameSerial
        guard qemu.ready(), qemu.frame(&pixels, &w, &h, &serial), let pixels, w > 0, h > 0 else { return }
        if Int(w) != ring.width || Int(h) != ring.height {
            ring.resize(width: Int(w), height: Int(h))
            onRingChanged?(ring)
            ring.activate()
        }
        // A frame that found no free surface is taken again next tick: the emulator republishes only
        // changed pixels, so a dropped frame would otherwise stay off screen until the guest draws.
        // A new ring's surfaces read as in use until the app has taken their Mach ports.
        if ring.publish({ FrameRingWriter.copy(pixels, width: Int(w), height: Int(h), into: $0) }) {
            frameSerial = serial
        }
    }

    private func refreshStatus() {
        status[.uiReady] = qemu.ready() ? 1 : 0
        status[.storageFailed] = qemu.storageFailed() ? 1 : 0
        status[.shutdownConfirmed] = qemu.shutdownConfirmed() ? 1 : 0
        status[.displaySleeping] = qemu.displaySleeping() ? 1 : 0
        status[.backlightLevel] = UInt64(bitPattern: Int64(qemu.backlightLevel?() ?? -1))
        status[.agentStatus] = UInt64(max(0, qemu.agentStatus()))
        status[.glesContexts] = UInt64(max(0, qemu.glesContexts()))
        status[.iconGeneration] = 0  // Retired content-sniffing field; retain shared-status ABI.
        var serial: Int64 = 0
        var result: Int32 = 0
        if let report = qemu.guestPackageReport, report(&serial, &result) {
            status[.guestPackage] = UInt64(bitPattern: serial)
            status[.guestPackageState] = UInt64(bitPattern: Int64(result))
            status[.guestPackageReported] = 1
        } else {
            status[.guestPackageReported] = 0
        }
        var glSerial: Int64 = 0
        status[.glesProtocol] = UInt64(bitPattern: Int64(qemu.glesProtocol?(&glSerial) ?? 0))
        status[.glesSerial] = UInt64(bitPattern: glSerial)
        // A copy inside the guest, at the status rate (the agent itself looks 4 times a second).
        if let text = qemu.guestPasteboard?(&guestPasteboardSerial) {
            onEvent?(.guestPasteboard(String(cString: text)))
            free(text)
        }
    }

    // MARK: - Boot

    /// Start qemu_ios_main on a 16 MB-stack thread. Once per process.
    func boot(_ config: BootConfig) throws -> Bool {
        guard !booted else { return false }
        if let proof = config.storageProof {
            guard let bootStorageAuthority else { throw StorageBootProof.Failure.missingLease }
            try bootStorageAuthority(proof)
        }
        let first: Bool = stateLock.withLock {
            guard bootConfig == nil else { return false }
            bootConfig = config
            return true
        }
        guard first else { return false }
        for (k, v) in config.environment { setenv(k, v, 1) }
        // A sandboxed helper (it has a bridge to its spawner) names no socket: QEMU hands the web proxy each guest
        // connection over a socket pair (guestfwd fdpass:), and the Debug Port's gdbstub accepts on the listener the
        // app bound in its own temporary directory.
        var argv = config.argv
        if let endpoint = config.webProxy {
            let proxy = WebProxy(config: URL(fileURLWithPath: endpoint.config))
            proxy.offline = config.wifiRestricted  // Setup offline: the PAC's proxy too, not just slirp
            proxy.localNetwork = config.wifiLocalNetwork
            if usbBridge != nil {
                var pair: [Int32] = [-1, -1]
                if socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 {
                    proxy.serve(passedOver: pair[0])
                    argv = BootRecipe.replacingGuestForward(in: argv, withSocket: pair[1])
                    webProxy = proxy
                } else {
                    helperLog("web proxy: no socket pair: \(String(cString: strerror(errno)))")
                }
            } else {
                do {
                    try proxy.listen(socket: endpoint.socket)
                    webProxy = proxy
                } catch { helperLog("web proxy: \(error)") }
            }
        }
        if let bridge = usbBridge, DebugPort.socket(in: argv) != nil {
            let listener = bridge.gdbListener()
            if listener == nil { helperLog("debug port: no listener from the app; the gdbstub is off") }
            argv = DebugPort.replacingSocket(in: argv, withListener: listener)
        }
        pumpQueue.async { [self] in pace() }
        qemu.attach(nil, nil)
        status[.qemuState] = QemuState.running.rawValue
        // A sandboxed helper's QEMU dials its USB bridge, which gets each connection to usbmuxd from the app.
        if let usbBridge { argv = BootRecipe.replacingUSBAddress(in: argv, with: usbBridge.address) }
        let thread = Thread { [self, argv] in
            var cargs = argv.map { strdup($0) }
            cargs.append(nil)
            let rc = qemu.main(Int32(argv.count), &cargs)
            helperLog("qemu_ios_main returned \(rc)")
            refreshStatus()
            status[.exitCode] = UInt64(bitPattern: Int64(rc))
            status[.qemuState] = QemuState.exited.rawValue
            stateLock.withLock { exited = true }
            if rc == 0, stateLock.withLock({ cleanStopAsked }), !qemu.storageFailed() { Self.markCleanStop() }
            pumpQueue.async { [self] in
                if let activity {
                    ProcessInfo.processInfo.endActivity(activity)
                    self.activity = nil
                }
            }
            DispatchQueue.main.async { [self] in
                if let onExit { onExit(rc) } else { exit(rc) }
            }
        }
        thread.name = "qemu-main"
        thread.stackSize = 16 << 20
        thread.qualityOfService = .userInteractive
        thread.start()
        helperLog("booting \(config.machine): \(argv.joined(separator: " "))")
        return true
    }

    // MARK: - Commands and requests

    func perform(_ command: LinkCommand) {
        switch command {
        case .touch(let slot, let phase, let x, let y):
            noteInput()
            qemu.touch(Int32(slot), Int32(phase), x, y)
        case .touch2(let phase, let x, let y):
            noteInput()
            qemu.touch2(Int32(phase), x, y)
        case .button(let button, let down):
            noteInput()
            qemu.button(Int32(button), down)
        case .key(let code, let down):
            noteInput()
            qemu.keyMac(Int32(code), down)
        case .screenVisible(let visible): setScreenVisible(visible)
        case .sandboxExtensions(let tokens):
            let refused = SandboxExtension.consume(tokens)
            helperLog(
                "sandbox: \(tokens.count - refused.count) of \(tokens.count) grants taken"
                    + (refused.isEmpty ? "" : "; refused: \(refused)")
            )
        case .rotate(let clockwise): qemu.rotate(clockwise)
        case .shake: qemu.shake()
        case .attitude(let pitch, let roll, let pose): qemu.attitude(pitch, roll, Int32(pose))
        case .paste(let text): text.withCString { qemu.paste($0) }
        case .machine(let op): machine(op)
        case .snapshotSave(let path): path.withCString { qemu.snapshotSave2($0) }
        case .snapshotResume: qemu.snapshotResume()
        case .agentCancel(let id): agents.cancel(id)
        case .audioStop(let generation): audio.stop(generation)
        case .netRestrict(let on):
            webProxy?.offline = on
            "wifi0".withCString { p in qemu.netRestrict?(p, on) }
        case .netLocalNetwork(let allowed):
            webProxy?.localNetwork = allowed
            "".withCString { p in qemu.netLAN?(p, allowed) }  // every user netdev: an iPhone's cell0 with wifi0
        }
    }

    private func machine(_ op: MachineOp) {
        guard booted, !hasExited else {
            if op == .quit {
                helperLog("quit before boot")
                exit(0)
            }
            return
        }
        switch op {
        case .pause, .resume:
            if op == .pause { qemu.pause() } else { qemu.resume() }
            pumpQueue.async { [self] in
                paused = op == .pause
                pace()
            }
        case .reset: qemu.reset()
        case .powerdown: qemu.powerdown()
        case .shutdown:
            if let shutdown = qemu.shutdown { helperLog("shutdown: path \(shutdown())") } else { qemu.powerdown() }
        case .quit:
            // after the guest powered itself off, QEMU's own exit flushes the storage: a clean stop too
            if qemu.shutdownConfirmed() { stateLock.withLock { cleanStopAsked = true } }
            qemu.quit()
        }
    }

    /// A clean stop (the halt, or a quit after the guest powered off, and QEMU returned 0 from its orderly exit, which
    /// flushes the storage): boot admission retires what it kept for one (the format 1 NAND after the image migration).
    static func markCleanStop() {
        guard let lease = launch.lease else { return }
        FileManager.default.createFile(
            atPath: PreparedDeviceBoot.cleanStopMarker(lease: URL(fileURLWithPath: lease)).path,
            contents: nil
        )
    }

    /// Everything but hello (main.swift answers that).
    func handle(_ request: LinkRequest, reply: @escaping @Sendable (LinkReply) -> Void) {
        switch request {
        case .hello: reply(.failure("hello twice"))
        case .boot(let config):
            do { reply(try boot(config) ? .ok(true) : .failure("already booted")) } catch {
                reply(.failure("Device storage admission refused: \(error)"))
            }
        case .snapshotStatus:
            var buffer = [CChar](repeating: 0, count: 512)
            let code = qemu.snapshotStatus(&buffer, UInt(buffer.count))
            let message = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            reply(.snapshot(status: Int(code), error: code == 3 ? message : nil))
        case .agent(let wire, let deadline): agents.submit(wire, deadline: deadline, reply: reply)
        case .audioStart: reply(audio.start())
        case .battery(let level, let charging): reply(.ok(qemu.battery(Int32(level), Int32(charging))))
        case .usbConnection(let attached): reply(.ok(qemu.usbConnection(attached)))
        case .hardwareKeyboard(let attached): reply(.ok(qemu.hardwareKeyboard?(attached) ?? false))
        case .compass(let heading): reply(.ok(qemu.compass(Int32(heading))))
        case .orientation(let value): reply(.ok(qemu.orientation(Int32(value))))
        case .modemSet(let property, let value):
            reply(
                .ok(
                    qemu.modemSet.map { set in property.withCString { p in value.withCString { set(p, $0) } } } ?? false
                )
            )
        case .modemStatus:
            guard let status = qemu.modemStatus, let raw = status() else { return reply(.modemStatus(nil)) }
            let json = String(cString: raw)
            qemu.modemFree?(raw)
            reply(.modemStatus(json))
        case .inputSequence(let id, let events):
            guard let submit = qemu.inputSequence,
                VirtualInputEvent.valid(events)
            else {
                reply(.failure("Virtual input unavailable or invalid sequence"))
                return
            }
            let at = events.map(\.atMilliseconds)
            let kind = events.map(\.kind)
            let value = events.map(\.value)
            let phase = events.map(\.phase)
            let x = events.map(\.x)
            let y = events.map(\.y)
            let queued = at.withUnsafeBufferPointer { a in
                kind.withUnsafeBufferPointer { k in
                    value.withUnsafeBufferPointer { v in
                        phase.withUnsafeBufferPointer { p in
                            x.withUnsafeBufferPointer { xx in
                                y.withUnsafeBufferPointer { yy in
                                    // valid(_:) refuses an empty sequence, so every column has storage.
                                    guard let a = a.baseAddress, let k = k.baseAddress, let v = v.baseAddress,
                                        let p = p.baseAddress, let xx = xx.baseAddress, let yy = yy.baseAddress
                                    else { return false }
                                    return submit(id, UInt(events.count), a, k, v, p, xx, yy)
                                }
                            }
                        }
                    }
                }
            }
            reply(.ok(queued))
        case .inputSequenceStatus(let id):
            if let status = qemu.inputSequenceStatus {
                reply(.inputSequenceStatus(Int(status(id))))
            } else {
                reply(.failure("Virtual input unavailable"))
            }
        case .inputSequenceCancel(let id):
            if let cancel = qemu.inputSequenceCancel {
                cancel(id)
                reply(.ok(true))
            } else {
                reply(.failure("Virtual input unavailable"))
            }
        }
    }

    // MARK: - Halt

    /// Stop, the app's quit and a vanished app: a hard halt, never a guest
    /// shutdown (a booting or wedged guest cannot be asked to unmount). Pause
    /// the VM, which flushes storage (the iPad IOP msyncs its NAND overlay on
    /// every VM stop; the iPod's pages and both NORs are written through), then
    /// quit QEMU. The guest's filesystems are crash-consistent: HFS+ replays its
    /// journal on the next boot. A guest that already powered off just quits.
    func halt(reason: String) {
        let proceed: Bool = stateLock.withLock {
            guard !shuttingDown else { return false }
            shuttingDown = true
            return true
        }
        guard proceed else { return }
        helperLog("halt: \(reason)")
        stateLock.withLock { cleanStopAsked = true }  // QEMU returns 0 from an orderly stop, which flushes
        guard booted else {
            helperLog("halt: no VM running")
            exit(0)
        }
        // QEMU's own SIGTERM handler (os_setup_signal_handlers overrides our SIG_IGN) may
        // have returned its main loop already: onExit is queued and reports qemuExited
        // before exiting. An exit here would lose that event (the app then can't tell a
        // stop from a crash).
        if hasExited {
            helperLog("halt: QEMU already returned")
            return
        }
        Thread.detachNewThread { [self] in
            let start = Date()
            // Still in qemu_init: nothing can be scheduled on the VM yet, and nothing is written.
            while !qemu.ready(), !hasExited, Date().timeIntervalSince(start) < 5 { usleep(50_000) }
            if qemu.ready() { qemu.pause() }  // vm_stop: storage flushed before the quit runs
            if !hasExited { qemu.quit() }
            let quitDeadline = Date().addingTimeInterval(5)
            while !hasExited, Date() < quitDeadline { usleep(50_000) }
            helperLog(
                String(
                    format: "halt: %@ after %.1f s",
                    hasExited ? "QEMU returned" : "QEMU did not return; exiting",
                    Date().timeIntervalSince(start)
                )
            )
            if !hasExited { exit(1) }
        }
    }
}

// MARK: - Agent RPC

/// Owns qemu_ios_agent_result: routes each result to its request by id, frees
/// it, and cancels what outlives its deadline.
final class AgentDispatcher: @unchecked Sendable {
    private let qemu: Qemu
    private let queue = DispatchQueue(label: "LightTouch.agent")
    private var pending: [String: (deadline: Date, reply: @Sendable (LinkReply) -> Void)] = [:]
    private var timer: DispatchSourceTimer?

    init(qemu: Qemu) { self.qemu = qemu }

    func submit(_ wire: String, deadline: Double, reply: @escaping @Sendable (LinkReply) -> Void) {
        queue.async { [self] in
            guard qemu.ready() else { return reply(.failure("The device is not running.")) }
            let id = String(wire.prefix { $0 != " " && $0 != "\n" })
            if deadline <= 0 { return reply(.ok(wire.withCString { qemu.agentRequest($0) })) }
            guard !id.isEmpty, pending[id] == nil else { return reply(.failure("Bad or duplicate agent request id.")) }
            guard wire.withCString({ qemu.agentRequest($0) }) else {
                return reply(.failure("The device command queue is full or unavailable."))
            }
            pending[id] = (Date().addingTimeInterval(deadline), reply)
            if timer == nil {
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
                t.setEventHandler { [weak self] in self?.poll() }
                timer = t
                t.resume()
            }
        }
    }

    func cancel(_ id: String) {
        queue.async { [self] in
            id.withCString { qemu.agentCancel($0) }
            pending.removeValue(forKey: id)?.reply(.agent(nil))
        }
    }

    private func poll() {
        while let pointer = qemu.agentResult() {
            let wire = String(cString: pointer)
            qemu.agentFreeResult(pointer)
            let id = String(wire.prefix { $0 != " " && $0 != "\n" })
            pending.removeValue(forKey: id)?.reply(.agent(wire))
        }
        let now = Date()
        let running = qemu.ready()
        for (id, entry) in pending where !running || entry.deadline < now {
            pending[id] = nil
            if running { id.withCString { qemu.agentCancel($0) } }
            entry.reply(running ? .agent(nil) : .failure("The device stopped before its command completed."))
        }
        if pending.isEmpty {
            timer?.cancel()
            timer = nil
        }
    }
}

// MARK: - Audio

/// Pushes qemu_ios_audio_capture_read packets as `.audio` events.
final class AudioPump: @unchecked Sendable {
    private let qemu: Qemu
    private let emit: (LinkEvent) -> Void
    private let queue = DispatchQueue(label: "LightTouch.audio", qos: .userInitiated)
    private var generation: UInt64 = 0
    private var stopAt: Date?
    private var timer: DispatchSourceTimer?

    init(qemu: Qemu, emit: @escaping (LinkEvent) -> Void) {
        self.qemu = qemu
        self.emit = emit
    }

    func start() -> LinkReply {
        queue.sync {
            if generation != 0 { finish(failed: false) }
            let g = qemu.audioStart()
            guard g != 0 else { return .failure("The device is not ready to record audio.") }
            generation = g
            stopAt = nil
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
            t.setEventHandler { [weak self] in self?.drain() }
            timer = t
            t.resume()
            return .audio(generation: g)
        }
    }

    /// Stop capturing; what is already queued is still delivered (up to 1 s), then `.audioEnded`.
    func stop(_ g: UInt64) {
        queue.async { [self] in
            guard g == generation, stopAt == nil else { return }
            qemu.audioStop(g)
            stopAt = Date().addingTimeInterval(1)
        }
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 16384)
        for _ in 0..<32 {
            var seconds = -1.0
            let n = buffer.withUnsafeMutableBytes { qemu.audioRead(generation, $0.baseAddress, 16384, &seconds) }
            if n < 0 { return finish(failed: stopAt == nil) }
            if n == 0 && seconds < 0 { break }
            emit(.audio(generation: generation, seconds: seconds, pcm: Data(buffer[0..<Int(n)])))
            if n == 0 { break }
        }
        if let stopAt, Date() >= stopAt { finish(failed: false) }
    }

    private func finish(failed: Bool) {
        timer?.cancel()
        timer = nil
        if stopAt == nil { qemu.audioStop(generation) }
        emit(.audioEnded(generation: generation, failed: failed))
        generation = 0
        stopAt = nil
    }
}
