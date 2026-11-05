import DeviceRuntime
import Foundation
import HostRuntime
import IOSurface
import os

// LightTouchDevice: one emulated device per process. Its one argument is its launch (HostRuntime HelperLaunch) as JSON:
// connect (spawned by the app, DeviceLink), headless, oneshot (firmwarekit's boots) or machines.
//
// libqemu-arm.dylib: $LTM_QEMU_DYLIB, else ../Frameworks, else the build rpath.
// Exit codes: QEMU's, or 64 usage, 70 no dylib, 72 rendezvous failed, 124 one-shot timeout.

signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IOLBF, 0)

/// The launch, read once; read from the link, boot and main threads.
let launch: HelperLaunch = {
    do { return try HelperLaunch(arguments: Array(CommandLine.arguments.dropFirst())) } catch {
        writeStandardError("LightTouchDevice: \(error.localizedDescription)\n")
        exit(64)
    }
}()

// A sandboxed helper's grants from DeviceLink, firmwarekit or DeviceInfo.list, on standard input (a pipe they close), before anything
// opens a file (HostRuntime SandboxExtension); given back at exit. Unsandboxed, standard input is /dev/null.
switch launch.mode {
case .connect, .oneshot, .machines:
    let (tokens, refused) = SandboxExtension.consumeStandardInput()
    if tokens > 0 {
        helperLog(
            "sandbox: \(tokens - refused.count) of \(tokens) grants taken\(refused.isEmpty ? "" : "; refused: \(refused)")"
        )
    }
    atexit { SandboxExtension.releaseAll() }
case .headless: break
}

/// Never dispatchMain(): it pthread_exit()s the main thread, and the dylib's
/// rcu_init constructor registered that thread as an RCU reader, so
/// call_rcu_thread then walks a freed TLS record (random heap corruption in
/// qemu_init: SIGSEGVs, "unknown migration protocol: (null)", restores that
/// never paint). Keep it in a run loop.
func parkMainThread() -> Never {
    while true { CFRunLoopRun() }
}

/// SIGTERM / SIGINT run the same halt as a vanished parent. Main thread only.
var signalSources: [DispatchSourceSignal] = []
@MainActor func onTerminationSignals(_ handler: @escaping @MainActor (String) -> Void) {
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler(sig == SIGTERM ? "SIGTERM" : "SIGINT") } }
        source.resume()
        signalSources.append(source)
    }
}

func loadQemu() -> Qemu? {
    do {
        let q = try Qemu.load()
        helperLog("loaded \(q.path)")
        return q
    } catch {
        helperLog("\(error)")
        return nil
    }
}

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    try? FileHandle.standardOutput.write(contentsOf: data + Data("\n".utf8))
}

/// The device's lease, held until this process exits (HostRuntime HeldLease).
let storageLease = HeldLease()
func takeLease(_ path: String?) -> Bool { storageLease.take(path, log: { helperLog($0) }) }

/// Every helper mode verifies managed boot records under the same held lease.
func installBootStorageAuthority(_ host: DeviceHost) {
    host.bootStorageAuthority = { proof in
        guard let lease = storageLease.lease, let path = launch.lease else {
            throw StorageBootProof.Failure.missingLease
        }
        let record = URL(fileURLWithPath: path).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(DeviceRecord.name)
        try proof.verify(record: record, lease: lease)
    }
}

switch launch.mode {
case .connect(let service, let token, _):
    runLinked(service: service, token: token)
case .headless(let path):
    runHeadless(configPath: path)
case .oneshot(let path):
    runOneShot(configPath: path)
case .machines:
    // Every machine the emulator library runs, with its facts (HostRuntime DeviceInfo.list).
    guard let qemu = loadQemu() else { exit(70) }
    struct Listing: Encodable {
        let dylibPath: String
        let machines: [DeviceInfo]
    }
    do {
        FileHandle.standardOutput.write(
            try JSONEncoder().encode(Listing(dylibPath: qemu.path, machines: qemu.machines)) + Data("\n".utf8)
        )
    } catch {
        writeStandardError("LightTouchDevice: \(error)\n")
        exit(1)
    }
    exit(0)
}

// MARK: - Linked (spawned by the app)

@MainActor func runLinked(service: String, token: String) -> Never {
    guard fcntl(3, F_GETFD) != -1 else {
        helperLog("no link on fd 3: not spawned by DeviceLink")
        exit(64)
    }
    let parent = getppid()
    let qemu = loadQemu()
    let status = StatusBlock.create()
    let host = qemu.map { DeviceHost(qemu: $0, status: status) }
    if let host { installBootStorageAuthority(host) }
    host?.usbBridge = USBBridge.start()  // a sandboxed helper's (DeviceLink gave it fd 4)

    let kr = DeviceRendezvous.sendHello(service: service, token: token, generation: 0, surfaces: [status.surface])
    guard kr == 0 else {
        helperLog("rendezvous with \(service) failed: \(kr)")
        exit(72)
    }

    let linkQueue = DispatchQueue(label: "LightTouch.link")
    // nonisolated(unsafe): assigned once, below, before the channel reads its first message; only read after.
    nonisolated(unsafe) var channel: LinkChannel<AppMessage, HelperMessage>?
    func shutdown(_ reason: String) {
        guard let host else { exit(0) }
        host.halt(reason: reason)
    }
    channel = LinkChannel<AppMessage, HelperMessage>(
        fd: 3,
        queue: linkQueue,
        onMessage: { message in
            switch message {
            case .command(let command):
                host?.perform(command)
            case .request(let id, .hello(let version, let board)):
                guard version == DeviceLinkWire.protocolVersion else {
                    channel?.send(
                        .reply(id: id, .failure("protocol \(version) is not \(DeviceLinkWire.protocolVersion)"))
                    )
                    return
                }
                guard let host else {
                    channel?.send(.reply(id: id, .failure("The device helper could not load libqemu-arm.dylib.")))
                    channel?.drain()
                    exit(70)
                }
                guard takeLease(launch.lease) else {
                    channel?.send(.reply(id: id, .failure(storageLease.failure ?? DeviceLinkWire.leaseRefusal)))
                    channel?.drain()
                    exit(75)
                }
                channel?.send(.reply(id: id, .hello(host.info(board: board))))
            case .request(let id, let request):
                guard let host else {
                    channel?.send(.reply(id: id, .failure("no emulator")))
                    return
                }
                host.handle(request) { channel?.send(.reply(id: id, $0)) }
            }
        },
        onClose: { error in
            helperLog("link closed\(error.map { ": \($0)" } ?? "")")
            DispatchQueue.main.async { shutdown("link closed") }
        }
    )

    host?.onRingChanged = { ring in
        let kr = DeviceRendezvous.sendHello(
            service: service,
            token: token,
            generation: ring.generation,
            surfaces: [status.surface] + ring.surfaces
        )
        if kr != 0 { helperLog("ring hello failed: \(kr)") }
    }
    host?.onEvent = { channel?.send(.event($0)) }
    host?.onExit = { rc in
        channel?.send(.event(.qemuExited(rc)))
        channel?.drain()
        exit(rc)
    }
    host?.startPump()

    // Parent death: a process-exit source on the parent, plus EOF on the link.
    let parentWatch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
    parentWatch.setEventHandler {
        helperLog("parent \(parent) exited")
        shutdown("parent exited")
    }
    parentWatch.resume()
    if getppid() != parent || parent == 1 { shutdown("parent already gone") }
    onTerminationSignals { shutdown($0) }
    withExtendedLifetime(parentWatch) { parkMainThread() }
}

// MARK: - Headless (tests)

struct HeadlessConfig: Decodable {
    var dylib: String?
    var boot: BootConfig
    /// Once lit, in order: "wait S", "dump NAME", "tap X Y", "drag X0 Y0 X1 Y1",
    /// "button N", "key CODE", "snapshot PATH", "resume", "shutdown", "quit".
    var actions: [String]?
    var dumpDir: String?
    var litFraction: Double?
    var maxSeconds: Double?
}

func decodeConfig<T: Decodable>(_ path: String, _: T.Type) -> T {
    do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: URL(fileURLWithPath: path))) } catch {
        helperLog("bad config \(path): \(error)")
        exit(64)
    }
}

/// A config's emulator library, for Qemu.candidates: Debug only; a Release helper loads its bundle's.
func useDylib(_ dylib: String?) {
    #if DEBUG
        if let dylib { setenv("LTM_QEMU_DYLIB", dylib, 1) }
    #endif
}

@MainActor func runHeadless(configPath: String) -> Never {
    let config = decodeConfig(configPath, HeadlessConfig.self)
    useDylib(config.dylib)
    guard let qemu = loadQemu() else { exit(70) }
    let status = StatusBlock.create()
    let host = DeviceHost(qemu: qemu, status: status)
    guard takeLease(launch.lease) else { exit(75) }
    installBootStorageAuthority(host)
    let reader = OSAllocatedUnfairLock<FrameRingReader?>(uncheckedState: nil)
    host.onRingChanged = { ring in
        reader.withLockUnchecked {
            $0 = FrameRingReader(status: status, generation: ring.generation, surfaces: ring.surfaces)
        }
        emit(["event": "ring", "generation": ring.generation, "width": ring.width, "height": ring.height])
    }
    host.onExit = { rc in
        emit(["event": "exit", "code": rc, "status": describe(status.snapshot())])
        exit(rc)
    }
    host.startPump()
    onTerminationSignals { host.halt(reason: $0) }
    do { _ = try host.boot(config.boot) } catch {
        helperLog("boot storage admission: \(error)")
        exit(75)
    }

    @Sendable func front() -> IOSurface? { reader.withLockUnchecked { $0?.front()?.surface } }
    let start = Date()
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        emit(["event": "status", "t": Date().timeIntervalSince(start), "status": describe(status.snapshot())])
    }
    Thread.detachNewThread {
        let need = config.litFraction ?? 0.2
        var lit = 0.0
        while lit < need {
            if Date().timeIntervalSince(start) > (config.maxSeconds ?? 500) {
                emit(["event": "never-lit", "brightness": lit])
                if let dir = config.dumpDir, let s = front() {
                    FrameTools.writePNG(s, to: URL(fileURLWithPath: "\(dir)/never-lit.png"))
                }
                qemu.quit()
                return
            }
            usleep(250_000)
            lit = front().map(FrameTools.brightness) ?? 0
        }
        emit(["event": "lit", "seconds": Date().timeIntervalSince(start), "brightness": lit])
        for action in config.actions ?? [] {
            let p = action.split(separator: " ").map(String.init)
            let v = p.dropFirst().compactMap(Double.init)
            emit(["event": "action", "action": action, "glesContexts": qemu.glesContexts()])
            switch p.first ?? "" {
            case "wait": usleep(UInt32((v.first ?? 1) * 1e6))
            case "dump":
                guard let dir = config.dumpDir, let s = front() else { break }
                let url = URL(fileURLWithPath: "\(dir)/\(p[1]).png")
                emit([
                    "event": "dump", "path": url.path, "ok": FrameTools.writePNG(s, to: url),
                    "brightness": FrameTools.brightness(s)
                ])
            case "tap":
                host.perform(.touch(slot: 0, phase: 0, x: v[0], y: v[1]))
                usleep(80_000)
                host.perform(.touch(slot: 0, phase: 2, x: v[0], y: v[1]))
            case "drag":
                host.perform(.touch(slot: 0, phase: 0, x: v[0], y: v[1]))
                usleep(150_000)
                for i in 1...30 {
                    let f = Double(i) / 30
                    host.perform(.touch(slot: 0, phase: 1, x: v[0] + (v[2] - v[0]) * f, y: v[1] + (v[3] - v[1]) * f))
                    usleep(30_000)
                }
                usleep(300_000)
                host.perform(.touch(slot: 0, phase: 2, x: v[2], y: v[3]))
            case "button":
                host.perform(.button(Int(v[0]), down: true))
                usleep(150_000)
                host.perform(.button(Int(v[0]), down: false))
            case "key":
                host.perform(.key(macKeyCode: Int(v[0]), down: true))
                usleep(80_000)
                host.perform(.key(macKeyCode: Int(v[0]), down: false))
            case "snapshot":
                let t0 = Date()
                host.perform(.snapshotSave(path: p[1]))
                let result = OSAllocatedUnfairLock<(code: Int, error: String?)>(initialState: (1, nil))
                while Date().timeIntervalSince(t0) < 60 {
                    usleep(100_000)
                    let done = DispatchSemaphore(value: 0)
                    host.handle(.snapshotStatus) { reply in
                        if case .snapshot(let c, let e) = reply { result.withLock { $0 = (c, e) } }
                        done.signal()
                    }
                    done.wait()
                    if result.withLock({ $0.code }) >= 2 { break }
                }
                let (code, error) = result.withLock { $0 }
                emit([
                    "event": "snapshot", "status": code, "error": error ?? "", "seconds": Date().timeIntervalSince(t0)
                ])
            case "resume": host.perform(.snapshotResume)
            case "shutdown": host.halt(reason: "action")
            case "quit": host.perform(.machine(.quit))
            default: emit(["event": "unknown-action", "action": action])
            }
        }
    }
    parkMainThread()
}

func describe(_ s: SharedStatus) -> [String: Any] {
    [
        "heartbeat": s.heartbeat, "frameSerial": s.frameSerial, "width": s.width, "height": s.height,
        "uiReady": s.uiReady, "storageFailed": s.storageFailed, "shutdownConfirmed": s.shutdownConfirmed,
        "displaySleeping": s.displaySleeping, "agentStatus": s.agentStatus, "glesContexts": s.glesContexts,
        "iconGeneration": s.iconGeneration, "qemuState": s.qemuState.rawValue, "exitCode": s.exitCode,
        "guestPackage": s.guestPackage.map { ["serial": $0.serial, "result": $0.result] } ?? NSNull(),
        "glesProtocol": s.glesProtocol, "glesSerial": s.glesSerial, "backlightLevel": s.backlightLevel,
        "vibrating": s.vibrating, "vibratorPulses": s.vibratorPulses
    ]
}

// MARK: - One-shot (seal / keybag boots)

struct OneShotConfig: Decodable {
    var dylib: String?
    /// argv should route the serial port to `serialLog` ("-serial file:<path>").
    var boot: BootConfig
    var serialLog: String
    /// Stop (quit QEMU) as soon as the serial log contains this.
    var stopMarker: String?
    /// Or as soon as this regular expression matches the log with its newlines removed: other kernel
    /// messages interleave with a line on the serial log (qemu-ios ipad1_seal.py FTL_OPEN_RE).
    var stopPattern: String?
    var timeout: Double
}

@MainActor func runOneShot(configPath: String) -> Never {
    let config = decodeConfig(configPath, OneShotConfig.self)
    useDylib(config.dylib)
    guard let qemu = loadQemu() else { exit(70) }
    let host = DeviceHost(qemu: qemu, status: StatusBlock.create())
    guard takeLease(launch.lease) else { exit(75) }
    installBootStorageAuthority(host)
    let start = Date()
    /// Whether the serial log showed the stop marker, and whether we asked QEMU to stop: set on the watch thread and
    /// the main queue, read wherever QEMU's exit lands.
    struct Flags { var marker = false, stopping = false }
    let flags = OSAllocatedUnfairLock(initialState: Flags())
    /// exited: QEMU returned by itself (the guest halted), not because we quit it.
    @Sendable func finish(exited: Bool, code: Int32) -> Never {
        let marker = flags.withLock { $0.marker }
        emit([
            "event": "oneshot", "exited": exited, "exitCode": code, "marker": marker,
            "seconds": Date().timeIntervalSince(start)
        ])
        exit(marker ? 0 : exited ? code : 124)
    }
    host.onExit = { rc in finish(exited: !flags.withLock { $0.stopping }, code: rc) }
    onTerminationSignals { _ in qemu.quit() }
    // The preparer (firmwarekit) died: nobody will read this boot's result.
    let parent = getppid()
    let parentWatch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
    parentWatch.setEventHandler {
        helperLog("parent \(parent) exited")
        flags.withLock { $0.stopping = true }
        qemu.quit()
    }
    parentWatch.resume()
    do { _ = try host.boot(config.boot) } catch {
        helperLog("boot storage admission: \(error)")
        exit(75)
    }
    if getppid() != parent || parent == 1 {
        flags.withLock { $0.stopping = true }
        qemu.quit()
    }
    Thread.detachNewThread {
        while !host.hasExited {
            usleep(500_000)
            if config.stopMarker != nil || config.stopPattern != nil,
                let text = try? String(contentsOfFile: config.serialLog, encoding: .isoLatin1)
            {
                if let stop = config.stopMarker, text.contains(stop) { flags.withLock { $0.marker = true } }
                if let pattern = config.stopPattern,
                    text.replacingOccurrences(of: "\n", with: "").range(of: pattern, options: .regularExpression) != nil
                {
                    flags.withLock { $0.marker = true }
                }
            }
            if flags.withLock({ $0.marker }) || Date().timeIntervalSince(start) > config.timeout {
                flags.withLock { $0.stopping = true }
                qemu.quit()
                let deadline = Date().addingTimeInterval(5)
                while !host.hasExited, Date() < deadline { usleep(50_000) }
                DispatchQueue.main.async { finish(exited: false, code: -1) }
                return
            }
        }
    }
    withExtendedLifetime(parentWatch) { parkMainThread() }
}
