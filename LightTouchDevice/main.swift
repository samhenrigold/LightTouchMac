// LightTouchDevice: one emulated device per process (docs/multi-device-plan.md, section A).
//
//   LightTouchDevice --connect SERVICE --token T --instance UUID   spawned by the app (DeviceLink);
//                                                                  the link socket is fd 3
//   LightTouchDevice --headless config.json   boot, run scripted actions, PNG dumps, status on stdout
//   LightTouchDevice --oneshot config.json    boot until QEMU exits or a serial marker (seal/keybag)
//   LightTouchDevice --probe MACHINE          load the dylib, print the hello's HelperInfo (packaging tests)
//
// libqemu-arm.dylib: $LTM_QEMU_DYLIB, else ../Frameworks, else the build rpath.
// Exit codes: QEMU's, or 64 usage, 70 no dylib, 72 rendezvous failed, 124 one-shot timeout.

import Foundation
import IOSurface

signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IOLBF, 0)

var arguments = [String: String]()
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        guard a.hasPrefix("--"), let v = it.next() else { FileHandle.standardError.write(Data("usage: see main.swift\n".utf8)); exit(64) }
        arguments[a] = v
    }
}

/// Never dispatchMain(): it pthread_exit()s the main thread, and the dylib's
/// rcu_init constructor registered that thread as an RCU reader, so
/// call_rcu_thread then walks a freed TLS record (random heap corruption in
/// qemu_init: SIGSEGVs, "unknown migration protocol: (null)", restores that
/// never paint; docs/multi-device-spikes.md, section 2). Keep it in a run loop.
func parkMainThread() -> Never {
    while true { CFRunLoopRun() }
}

/// SIGTERM / SIGINT run the same halt as a vanished parent.
var signalSources: [DispatchSourceSignal] = []
func onTerminationSignals(_ handler: @escaping (String) -> Void) {
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { handler(sig == SIGTERM ? "SIGTERM" : "SIGINT") }
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
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

if let service = arguments["--connect"] {
    runLinked(service: service, token: arguments["--token"] ?? "")
} else if let path = arguments["--headless"] {
    runHeadless(configPath: path)
} else if let path = arguments["--oneshot"] {
    runOneShot(configPath: path)
} else if let machine = arguments["--probe"] {
    guard let qemu = loadQemu() else { exit(70) }
    let info = DeviceHost(qemu: qemu, status: StatusBlock.create()).info(machine: machine)
    FileHandle.standardOutput.write(try! JSONEncoder().encode(info) + Data("\n".utf8))
    exit(0)
} else {
    FileHandle.standardError.write(Data("usage: LightTouchDevice --connect S --token T --instance U | --headless config.json | --oneshot config.json | --probe MACHINE\n".utf8))
    exit(64)
}

// MARK: - Linked (spawned by the app)

func runLinked(service: String, token: String) -> Never {
    guard fcntl(3, F_GETFD) != -1 else { helperLog("no link on fd 3: not spawned by DeviceLink"); exit(64) }
    let parent = getppid()
    let qemu = loadQemu()
    let status = StatusBlock.create()
    let host = qemu.map { DeviceHost(qemu: $0, status: status) }

    let kr = DeviceRendezvous.sendHello(service: service, token: token, generation: 0, surfaces: [status.surface])
    guard kr == 0 else { helperLog("rendezvous with \(service) failed: \(kr)"); exit(72) }

    let linkQueue = DispatchQueue(label: "LightTouch.link")
    var channel: LinkChannel<AppMessage, HelperMessage>!
    func shutdown(_ reason: String) {
        guard let host else { exit(0) }
        host.halt(reason: reason)
    }
    channel = LinkChannel<AppMessage, HelperMessage>(fd: 3, queue: linkQueue, onMessage: { message in
        switch message {
        case .command(let command):
            host?.perform(command)
        case .request(let id, .hello(let version, let machine)):
            guard version == DeviceLinkWire.protocolVersion else {
                channel.send(.reply(id: id, .failure("protocol \(version) is not \(DeviceLinkWire.protocolVersion)")))
                return
            }
            guard let host else {
                channel.send(.reply(id: id, .failure("The device helper could not load libqemu-arm.dylib.")))
                channel.drain()
                exit(70)
            }
            channel.send(.reply(id: id, .hello(host.info(machine: machine))))
        case .request(let id, let request):
            guard let host else { channel.send(.reply(id: id, .failure("no emulator"))); return }
            host.handle(request) { channel.send(.reply(id: id, $0)) }
        }
    }, onClose: { error in
        helperLog("link closed\(error.map { ": \($0)" } ?? "")")
        DispatchQueue.main.async { shutdown("link closed") }
    })

    host?.onRingChanged = { ring in
        let kr = DeviceRendezvous.sendHello(service: service, token: token, generation: ring.generation,
                                            surfaces: [status.surface] + ring.surfaces)
        if kr != 0 { helperLog("ring hello failed: \(kr)") }
    }
    host?.onEvent = { channel.send(.event($0)) }
    host?.onExit = { rc in
        channel.send(.event(.qemuExited(rc)))
        channel.drain()
        exit(rc)
    }
    host?.startPump()

    // Parent death: a process-exit source on the parent, plus EOF on the link.
    let parentWatch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
    parentWatch.setEventHandler { helperLog("parent \(parent) exited"); shutdown("parent exited") }
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

func runHeadless(configPath: String) -> Never {
    let config = decodeConfig(configPath, HeadlessConfig.self)
    if let dylib = config.dylib { setenv("LTM_QEMU_DYLIB", dylib, 1) }
    guard let qemu = loadQemu() else { exit(70) }
    let status = StatusBlock.create()
    let host = DeviceHost(qemu: qemu, status: status)
    let readerLock = NSLock()
    var reader: FrameRingReader?
    host.onRingChanged = { ring in
        readerLock.withLock { reader = FrameRingReader(status: status, generation: ring.generation, surfaces: ring.surfaces) }
        emit(["event": "ring", "generation": ring.generation, "width": ring.width, "height": ring.height])
    }
    host.onExit = { rc in
        emit(["event": "exit", "code": rc, "status": describe(status.snapshot())])
        exit(rc)
    }
    host.startPump()
    onTerminationSignals { host.halt(reason: $0) }
    _ = host.boot(config.boot)

    func front() -> IOSurface? { readerLock.withLock { reader?.front()?.surface } }
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
                if let dir = config.dumpDir, let s = front() { FrameTools.writePNG(s, to: URL(fileURLWithPath: "\(dir)/never-lit.png")) }
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
                emit(["event": "dump", "path": url.path, "ok": FrameTools.writePNG(s, to: url), "brightness": FrameTools.brightness(s)])
            case "tap":
                host.perform(.touch(slot: 0, phase: 0, x: v[0], y: v[1])); usleep(80_000)
                host.perform(.touch(slot: 0, phase: 2, x: v[0], y: v[1]))
            case "drag":
                host.perform(.touch(slot: 0, phase: 0, x: v[0], y: v[1])); usleep(150_000)
                for i in 1...30 {
                    let f = Double(i) / 30
                    host.perform(.touch(slot: 0, phase: 1, x: v[0] + (v[2] - v[0]) * f, y: v[1] + (v[3] - v[1]) * f))
                    usleep(30_000)
                }
                usleep(300_000)
                host.perform(.touch(slot: 0, phase: 2, x: v[2], y: v[3]))
            case "button":
                host.perform(.button(Int(v[0]), down: true)); usleep(150_000)
                host.perform(.button(Int(v[0]), down: false))
            case "key":
                host.perform(.key(macKeyCode: Int(v[0]), down: true)); usleep(80_000)
                host.perform(.key(macKeyCode: Int(v[0]), down: false))
            case "snapshot":
                let t0 = Date()
                host.perform(.snapshotSave(path: p[1]))
                var code = 1
                var error: String?
                while Date().timeIntervalSince(t0) < 60 {
                    usleep(100_000)
                    let done = DispatchSemaphore(value: 0)
                    host.handle(.snapshotStatus) { reply in
                        if case let .snapshot(c, e) = reply { code = c; error = e }
                        done.signal()
                    }
                    done.wait()
                    if code >= 2 { break }
                }
                emit(["event": "snapshot", "status": code, "error": error ?? "", "seconds": Date().timeIntervalSince(t0)])
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
    ["heartbeat": s.heartbeat, "frameSerial": s.frameSerial, "width": s.width, "height": s.height,
     "uiReady": s.uiReady, "storageFailed": s.storageFailed, "shutdownConfirmed": s.shutdownConfirmed,
     "displaySleeping": s.displaySleeping, "agentStatus": s.agentStatus, "glesContexts": s.glesContexts,
     "iconGeneration": s.iconGeneration, "qemuState": s.qemuState.rawValue, "exitCode": s.exitCode,
     "guestPackage": s.guestPackage.map { ["serial": $0.serial, "result": $0.result] } ?? NSNull(),
     "glesProtocol": s.glesProtocol, "glesSerial": s.glesSerial]
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

func runOneShot(configPath: String) -> Never {
    let config = decodeConfig(configPath, OneShotConfig.self)
    if let dylib = config.dylib { setenv("LTM_QEMU_DYLIB", dylib, 1) }
    guard let qemu = loadQemu() else { exit(70) }
    let host = DeviceHost(qemu: qemu, status: StatusBlock.create())
    let start = Date()
    var marker = false
    var stopping = false
    /// exited: QEMU returned by itself (the guest halted), not because we quit it.
    func finish(exited: Bool, code: Int32) -> Never {
        emit(["event": "oneshot", "exited": exited, "exitCode": code, "marker": marker,
              "seconds": Date().timeIntervalSince(start)])
        exit(marker ? 0 : exited ? code : 124)
    }
    host.onExit = { rc in finish(exited: !stopping, code: rc) }
    onTerminationSignals { _ in qemu.quit() }
    _ = host.boot(config.boot)
    Thread.detachNewThread {
        while !host.hasExited {
            usleep(500_000)
            if config.stopMarker != nil || config.stopPattern != nil,
               let text = try? String(contentsOfFile: config.serialLog, encoding: .isoLatin1) {
                if let stop = config.stopMarker, text.contains(stop) { marker = true }
                if let pattern = config.stopPattern,
                   text.replacingOccurrences(of: "\n", with: "").range(of: pattern, options: .regularExpression) != nil { marker = true }
            }
            if marker || Date().timeIntervalSince(start) > config.timeout {
                stopping = true
                qemu.quit()
                let deadline = Date().addingTimeInterval(5)
                while !host.hasExited, Date() < deadline { usleep(50_000) }
                DispatchQueue.main.async { finish(exited: false, code: -1) }
                return
            }
        }
    }
    parkMainThread()
}
