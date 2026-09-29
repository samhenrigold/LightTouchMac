// One VM in this process: QEMU's thread, the frame/status pump, commands,
// requests, agent RPC, audio capture and the clean shutdown. Mode-agnostic:
// main.swift wires it to the app's link, or to the headless/one-shot runners.

import Foundation
import IOSurface

final class DeviceHost: @unchecked Sendable {
    let qemu: Qemu
    let status: StatusBlock
    let ring: FrameRingWriter

    /// A new ring exists; send it to the reader BEFORE it is activated.
    var onRingChanged: ((FrameRingWriter) -> Void)?
    var onEvent: ((LinkEvent) -> Void)?
    /// QEMU returned (or the shutdown gave up). Default: exit with the code.
    var onExit: ((Int32) -> Void)?

    private let pumpQueue = DispatchQueue(label: "LightTouch.frames", qos: .userInteractive)
    private var pump: DispatchSourceTimer?
    private var ticks = 0
    private var frameSerial: UInt64 = 0
    private let stateLock = NSLock()
    private var bootConfig: BootConfig?
    /// The device's web proxy (WebProxy.swift), for the life of the process.
    private var webProxy: WebProxy?
    private var exited = false
    private var shuttingDown = false
    private var activity: NSObjectProtocol?
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

    func info(machine: String?) -> HelperInfo {
        HelperInfo(protocolVersion: DeviceLinkWire.protocolVersion, pid: getpid(), dylibPath: qemu.path,
                   dylibModified: qemu.modified, buildID: qemu.buildID?().map { String(cString: $0) },
                   deviceInfo: machine.flatMap { qemu.info(machine: $0) })
    }

    // MARK: Pump

    /// 60 Hz frames, 20 Hz status, heartbeat on every tick (also before boot).
    func startPump() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: pumpQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        pump = timer
        timer.resume()
    }

    private func tick() {
        ticks += 1
        status.bumpHeartbeat()
        guard booted else { return }
        if ticks % 3 == 0 { refreshStatus() }
        var pixels: UnsafeRawPointer?
        var w: Int32 = 0, h: Int32 = 0
        var serial = frameSerial
        guard qemu.ready(), qemu.frame(&pixels, &w, &h, &serial), let pixels, w > 0, h > 0 else { return }
        frameSerial = serial
        if Int(w) != ring.width || Int(h) != ring.height {
            ring.resize(width: Int(w), height: Int(h))
            onRingChanged?(ring)
            ring.activate()
        }
        ring.publish { FrameRingWriter.copy(pixels, width: Int(w), height: Int(h), into: $0) }
    }

    private func refreshStatus() {
        status[.uiReady] = qemu.ready() ? 1 : 0
        status[.storageFailed] = qemu.storageFailed() ? 1 : 0
        status[.shutdownConfirmed] = qemu.shutdownConfirmed() ? 1 : 0
        status[.displaySleeping] = qemu.displaySleeping() ? 1 : 0
        status[.agentStatus] = UInt64(max(0, qemu.agentStatus()))
        status[.glesContexts] = UInt64(max(0, qemu.glesContexts()))
        status[.iconGeneration] = qemu.iconGeneration()
        var serial: Int64 = 0, result: Int32 = 0
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
    }

    // MARK: Boot

    /// Start qemu_ios_main on a 16 MB-stack thread. Once per process.
    func boot(_ config: BootConfig) -> Bool {
        let first: Bool = stateLock.withLock {
            guard bootConfig == nil else { return false }
            bootConfig = config
            return true
        }
        guard first else { return false }
        for (k, v) in config.environment { setenv(k, v, 1) }
        if let endpoint = config.webProxy {
            let proxy = WebProxy(config: URL(fileURLWithPath: endpoint.config))
            do { try proxy.listen(socket: endpoint.socket); webProxy = proxy } catch { helperLog("web proxy: \(error)") }
        }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Running an emulated device")
        qemu.attach(nil, nil)
        status[.qemuState] = QemuState.running.rawValue
        let argv = config.argv
        let thread = Thread { [self] in
            var cargs = argv.map { strdup($0) }
            cargs.append(nil)
            let rc = qemu.main(Int32(argv.count), &cargs)
            helperLog("qemu_ios_main returned \(rc)")
            refreshStatus()
            status[.exitCode] = UInt64(bitPattern: Int64(rc))
            status[.qemuState] = QemuState.exited.rawValue
            stateLock.withLock { exited = true }
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
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

    // MARK: Commands and requests

    func perform(_ command: LinkCommand) {
        switch command {
        case let .touch(slot, phase, x, y): qemu.touch(Int32(slot), Int32(phase), x, y)
        case let .touch2(phase, x, y): qemu.touch2(Int32(phase), x, y)
        case let .button(button, down): qemu.button(Int32(button), down)
        case let .key(code, down): qemu.keyMac(Int32(code), down)
        case let .rotate(clockwise): qemu.rotate(clockwise)
        case .shake: qemu.shake()
        case let .attitude(pitch, roll, pose): qemu.attitude(pitch, roll, Int32(pose))
        case let .paste(text): text.withCString { qemu.paste($0) }
        case let .machine(op): machine(op)
        case let .snapshotSave(path): path.withCString { qemu.snapshotSave2($0) }
        case .snapshotResume: qemu.snapshotResume()
        case let .agentCancel(id): agents.cancel(id)
        case let .audioStop(generation): audio.stop(generation)
        case let .netRestrict(on): "wifi0".withCString { p in qemu.netRestrict?(p, on) }
        }
    }

    private func machine(_ op: MachineOp) {
        guard booted, !hasExited else {
            if op == .quit { helperLog("quit before boot"); exit(0) }
            return
        }
        switch op {
        case .pause: qemu.pause()
        case .resume: qemu.resume()
        case .reset: qemu.reset()
        case .powerdown: qemu.powerdown()
        case .quit: qemu.quit()
        }
    }

    /// Everything but hello (main.swift answers that).
    func handle(_ request: LinkRequest, reply: @escaping (LinkReply) -> Void) {
        switch request {
        case .hello: reply(.failure("hello twice"))
        case let .boot(config): reply(boot(config) ? .ok(true) : .failure("already booted"))
        case .snapshotStatus:
            var buffer = [CChar](repeating: 0, count: 512)
            let code = qemu.snapshotStatus(&buffer, UInt(buffer.count))
            reply(.snapshot(status: Int(code), error: code == 3 ? String(cString: buffer) : nil))
        case let .agent(wire, deadline): agents.submit(wire, deadline: deadline, reply: reply)
        case .audioStart: reply(audio.start())
        case let .battery(level, charging): reply(.ok(qemu.battery(Int32(level), Int32(charging))))
        case let .usbConnection(attached): reply(.ok(qemu.usbConnection(attached)))
        case let .compass(heading): reply(.ok(qemu.compass(Int32(heading))))
        case let .usbCharger(high): reply(.ok(qemu.usbCharger(high)))
        case let .orientation(value): reply(.ok(qemu.orientation(Int32(value))))
        }
    }

    // MARK: Halt

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
        guard booted else { helperLog("halt: no VM running"); exit(0) }
        // QEMU's own SIGTERM handler (os_setup_signal_handlers overrides our SIG_IGN) may
        // have returned its main loop already: onExit is queued and reports qemuExited
        // before exiting. An exit here would lose that event (the app then can't tell a
        // stop from a crash).
        if hasExited { helperLog("halt: QEMU already returned"); return }
        Thread.detachNewThread { [self] in
            let start = Date()
            // Still in qemu_init: nothing can be scheduled on the VM yet, and nothing is written.
            while !qemu.ready(), !hasExited, Date().timeIntervalSince(start) < 5 { usleep(50_000) }
            if qemu.ready() { qemu.pause() }   // vm_stop: storage flushed before the quit runs
            if !hasExited { qemu.quit() }
            let quitDeadline = Date().addingTimeInterval(5)
            while !hasExited, Date() < quitDeadline { usleep(50_000) }
            helperLog(String(format: "halt: %@ after %.1f s", hasExited ? "QEMU returned" : "QEMU did not return; exiting",
                             Date().timeIntervalSince(start)))
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
    private var pending: [String: (deadline: Date, reply: (LinkReply) -> Void)] = [:]
    private var timer: DispatchSourceTimer?

    init(qemu: Qemu) { self.qemu = qemu }

    func submit(_ wire: String, deadline: Double, reply: @escaping (LinkReply) -> Void) {
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
        if pending.isEmpty { timer?.cancel(); timer = nil }
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

func helperLog(_ message: String) {
    var tv = timeval()
    gettimeofday(&tv, nil)
    let line = String(format: "[LightTouchDevice %d %.3f] ", getpid(), Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6) + message + "\n"
    FileHandle.standardError.write(Data(line.utf8))
}
