import ArgumentParser
import DeviceRuntime
import Foundation
import HostRuntime
import IOSurface
import LightTouchCore
import SessionKit

// Stands in for the app in `sessions helper`, `helper-boot` and `phone` (Sources/sessions/Helper.swift): spawns LightTouchDevice
// through DeviceLink (rendezvous, validation, status block, frame ring, link)
// and runs a scripted scenario. JSON lines on stdout; built by the test with
// swiftc from Packages/DeviceRuntime/Sources/DeviceRuntime/*.swift + LightTouchDevice/FrameTools.swift.
//
//   helper-driver --helper PATH --scenario scenario.json --dump DIR [--log native.log] [--requirement R]
//                 [--lease PATH] [--expect-failure TEXT]   (exit 0 if the start fails with TEXT)
//
// scenario: {"dylib": "...", "board": "k48ap", "boot": BootConfig, "steps": ["boot", "lit 0.2 300", ...]}; or, for a
// FirmwareKit base booted as the app boots it (PreparedDeviceBoot with the hello's machine facts), "prepared":
// {"base": DIR, "overlay": DIR, "serial": FILE, "carrier": CarrierSettings} in place of "boot".
// "watch DIR" starts the app's DeviceFileWatch on DIR (and its children): "meddled" events follow any change.
// "sample LABEL S" measures the helper for S seconds: pump rate (heartbeats/s), frames/s, CPU, wakeups and energy
// (proc_pid_rusage), and whether it holds an idle-sleep assertion (pmset). "visible on|off" is the window's
// occlusion (LinkCommand.screenVisible): how long until the pump has ticked 3 times (back at speed) and, if one was
// pending, the next frame.

struct Options: ParsableArguments {
    @Option(help: "LightTouchDevice.") var helper: String
    @Option(help: "The scenario, as JSON.") var scenario: String
    @Option(help: "Where frames are dumped.") var dump = "/tmp"
    @Option(help: "The helper's output.") var log: String?
    @Option(help: "The signing requirement the link pins the helper to.") var requirement: String?
    @Option(help: "The device's lease.") var lease: String?
    @Option(help: "The start must fail with this text.") var expectFailure: String?
    @Flag(help: "The start must be rejected (an impostor).") var expectReject = false
}
TextReader.serveChild()  // a screen read's child process (TextReader): reads, prints and exits
let opts = Options.parseOrExit()

struct Scenario: Decodable {
    struct Prepared: Decodable {
        var base: String, overlay: String, serial: String
        /// The SecureROMs (BootRecipe.bootrom); default ~/Developer/qemu-ios-files.
        var files: String?
        /// The Carrier panel's saved settings, as the app boots a radio board with them.
        var carrier: CarrierSettings?
        /// Tweaks' Time Machine: Unix seconds the guest clock starts at.
        var clock: Double?
        /// An itpack whose package for the base is offered, as the app offers its bundled one.
        var itpack: String?
        /// The panel's refresh, as Settings ▸ General's experimental 120 Hz boots it; default 60.
        var refreshHz: Int?
        /// Settings ▸ General's experimental ANGLE renderer; default off.
        var angle: Bool?
        /// The Debug Port's gdbstub on this Unix socket, as the app adds it (DebugPort.arguments); "gdb" attaches.
        var debugPort: String?
        /// A snapshot ("snapshot PATH") the boot resumes from (QEMU's -incoming), on the overlay as it was saved.
        var restore: String?
    }
    var dylib: String?
    var board: String?
    var boot: BootConfig?
    var prepared: Prepared?
    var steps: [String]
}

/// `prepared` as the app boots it: PreparedDeviceBoot and BootRecipe with the hello's DeviceInfo.
func preparedBoot(_ p: Scenario.Prepared, hardware: DeviceInfo?) throws -> BootConfig {
    guard let board = scenario.board.flatMap(Board.init(rawValue:)) else { throw CocoaError(.featureUnsupported) }
    let overlay = URL(fileURLWithPath: p.overlay)
    let prepared = try PreparedDeviceBoot.prepare(
        board: board,
        base: URL(fileURLWithPath: p.base),
        overlay: overlay,
        writableNOR: overlay.appendingPathComponent("nor.bin"),
        storageKey: nil,
        bootrom: BootRecipe.bootrom(
            board.bootrom,
            filesRoot: p.files ?? NSHomeDirectory() + "/Developer/qemu-ios-files"
        ),
        clock: p.clock.map(Date.init(timeIntervalSince1970:))
    )
    var config = try prepared.configuration(
        hardware: hardware,
        bootArgs: "amfi_allow_any_signature=1 cs_enforcement_disable=1",  // the app's default (DeviceOptions.bootArgs)
        usbAddress: nil,
        wifi: true,
        guestPackage: try p.itpack.flatMap { pack -> String? in
            let lock = try? DeviceLock.read(base: URL(fileURLWithPath: p.base)) ?? nil
            let dir = URL(fileURLWithPath: dumpDir).appendingPathComponent("offer")
            let offer = try GuestPackage.compose(
                itpack: URL(fileURLWithPath: pack),
                board: board.rawValue,
                build: lock?.build ?? "",
                lock: nil,
                guest: nil,
                into: dir
            )
            return offer == nil ? nil : dir.path
        },
        serial: "file:\(p.serial)",
        audio: ["-audio", "driver=none"],
        netdev: "user,id=wifi0",
        restore: p.restore.map { ["-incoming", "file:" + $0] } ?? [],
        carrier: p.carrier,
        refreshHz: p.refreshHz ?? 60,
        angle: p.angle ?? false
    )
    if let restore = p.restore {
        config.files?.readOnly.append(URL(fileURLWithPath: restore).deletingLastPathComponent().path)
    }
    if let socket = p.debugPort { config.argv += DebugPort.arguments(socket: socket) }
    return config
}

let t0 = Date()
func emit(_ event: String, _ fields: [String: Any] = [:]) {
    var object = fields
    object["event"] = event
    object["t"] = (Date().timeIntervalSince(t0) * 1000).rounded() / 1000
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}
func fail(_ why: String) -> Never {
    emit("fail", ["why": why])
    exit(1)
}

let scenario = try! JSONDecoder().decode(
    Scenario.self,
    from: Data(contentsOf: URL(fileURLWithPath: opts.scenario))
)
let dumpDir = opts.dump
let queue = DispatchQueue(label: "driver.link")

var logFD: Int32 = -1
if let log = opts.log { logFD = open(log, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644) }
var configuration = DeviceLink.Configuration(instance: UUID(), outputDescriptor: logFD)
configuration.helper = URL(fileURLWithPath: opts.helper)
HelperSandbox.use(helper: configuration.helper)
configuration.dylib = scenario.dylib
configuration.board = scenario.board
configuration.requirement = opts.requirement
configuration.lease = opts.lease.map { URL(fileURLWithPath: $0) }
let link = DeviceLink(configuration: configuration, queue: queue)

let exitedEvent = DispatchSemaphore(value: 0)
let invalidated = DispatchSemaphore(value: 0)
let terminated = DispatchSemaphore(value: 0)
var noticed: [String: Double] = [:]
let noticeLock = NSLock()
func notice(_ what: String) { noticeLock.withLock { noticed[what] = Date().timeIntervalSince1970 } }
var audioBytes = 0
/// S16 samples of the capture above a quiet floor (|s| > 1000): sound, not silence or dither.
var audioLoud = 0
var watches: [DeviceFileWatch] = []

link.onEvent = { event in
    switch event {
    case .qemuExited(let rc):
        emit("qemuExited", ["code": rc])
        exitedEvent.signal()
    case .audio(_, _, let pcm):
        audioBytes += pcm.count
        pcm.withUnsafeBytes { raw in
            audioLoud += raw.bindMemory(to: Int16.self).reduce(0) { $0 + (abs(Int($1)) > 1000 ? 1 : 0) }
        }
    case .audioEnded(let g, let failed):
        emit("audioEnded", ["generation": g, "failed": failed, "bytes": audioBytes, "loud": audioLoud])
        audioBytes = 0
        audioLoud = 0
    case .guestPasteboard(let text):
        emit("guestPasteboard", ["text": text])
    case .agentReport(let text):
        emit("agentReport", ["text": text])
    case .glesRefusals(let text):
        emit("glesRefusals", ["text": text])
    }
}
link.onInvalidated = { error in
    notice("invalidated")
    emit("invalidated", ["error": "\(error)"])
    invalidated.signal()
}
link.onTerminated = { termination in
    notice("terminated")
    emit("terminated", ["termination": "\(termination)"])
    terminated.signal()
}

func sync<T>(_ body: (@escaping @Sendable (T) -> Void) -> Void) -> T {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var value: T?
    body {
        value = $0
        done.signal()
    }
    done.wait()
    return value!
}

func request(_ r: LinkRequest, timeout: TimeInterval = 10) -> Result<LinkReply, DeviceLinkError> {
    sync { link.request(r, timeout: timeout, reply: $0) }
}

func statusFields() -> [String: Any] {
    guard let s = link.status else { return [:] }
    return [
        "heartbeat": s.heartbeat, "frameSerial": s.frameSerial, "width": s.width, "height": s.height,
        "uiReady": s.uiReady, "storageFailed": s.storageFailed, "shutdownConfirmed": s.shutdownConfirmed,
        "displaySleeping": s.displaySleeping, "agentStatus": s.agentStatus, "glesContexts": s.glesContexts,
        "iconGeneration": s.iconGeneration, "qemuState": s.qemuState.rawValue, "vibrating": s.vibrating,
        "vibratorPulses": s.vibratorPulses
    ]
}

// The display link: sample the ring at 60 Hz, like DisplayView will.
var lastSurface: IOSurface?
// The vibration motor as the app reads it (the status block), sampled with the frames: one event per change.
var lastVibrator = (false, UInt64(0))
var framesSeen = 0
let frameLock = NSLock()
let display = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "driver.display"))
display.schedule(deadline: .now(), repeating: 1.0 / 60)
display.setEventHandler {
    if let s = link.status, (s.vibrating, s.vibratorPulses) != lastVibrator {
        lastVibrator = (s.vibrating, s.vibratorPulses)
        emit("vibrator", ["on": s.vibrating, "pulses": s.vibratorPulses])
    }
    if let f = link.frontSurface(), f.isNew {
        frameLock.withLock {
            lastSurface = f.surface
            framesSeen += 1
        }
    }
}

let started: Result<HelperInfo, DeviceLinkError> = sync { link.start(completion: $0) }
var hardware: DeviceInfo?
switch started {
case .success(let info):
    hardware = info.deviceInfo
    emit(
        "connected",
        [
            "pid": info.pid, "protocol": info.protocolVersion, "dylib": info.dylibPath,
            "dylibModified": info.dylibModified, "buildID": info.buildID ?? "",
            "deviceInfo": info.deviceInfo.map {
                "\($0.machine) \($0.screenWidth)x\($0.screenHeight) scale \($0.screenScale)"
            } ?? "",
            "status": statusFields()
        ]
    )
case .failure(let error):
    emit("startFailed", ["error": "\(error)"])
    if let text = opts.expectFailure { exit("\(error)".contains(text) ? 0 : 1) }
    exit(opts.expectReject && "\(error)".contains("rejected") ? 0 : 1)
}
if opts.expectReject { fail("an impostor was accepted") }
if opts.expectFailure != nil { fail("the start was expected to fail") }
display.resume()
// `turn`/`shot`/`tapshown`: the app's rotation for this board (Rotation.swift); the scan is the hello's.
let rotationDriver: RotationDriver? = MainActor.assumeIsolated {
    guard let board = scenario.board.flatMap(Board.init(rawValue:)), let hardware else { return nil }
    return RotationDriver(
        link: link,
        board: board,
        scan: CGSize(width: hardware.screenWidth, height: hardware.screenHeight),
        settings: URL(fileURLWithPath: dumpDir).appendingPathComponent("settings")
    )
}
func onMain<T>(_ body: @MainActor () -> T) -> T { DispatchQueue.main.sync { MainActor.assumeIsolated { body() } } }

/// The modem's status JSON (qemu_ios_ui_modem_status), polled twice a beat apart: one poll returns the previous one's.
func modemStatusNow() -> [String: Any] {
    _ = request(.modemStatus)
    usleep(300_000)
    guard case .success(.modemStatus(let json)) = request(.modemStatus), let json,
        let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    else { return [:] }
    return o
}

var bootAt = Date()
let guest = GuestServices(agent: GuestAgent(link: link, cache: GuestAgentCache()))
/// The base's firmware version, and what the scenario's `tweaks` steps have written and applied this boot.
let baseVersion =
    scenario.prepared.flatMap { try? DeviceLock.read(base: URL(fileURLWithPath: $0.base)) }?.productVersion ?? ""
nonisolated(unsafe) var tweaksWritten: [String] = []
nonisolated(unsafe) var tweaksApplied = false
/// The Marketing Status Bar the `tweaks` steps set: a carrier and a battery level the real ones never show (the
/// Carrier panel's network is "Light Touch").
let marketing = {
    var style = StatusBarStyle()
    style.carrier = "Cupertino"
    style.battery = 50
    return style
}()
/// An async call's result, from the scenario's thread.
func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
    sync { done in Task { done(await Result { try await body() }) } }
}

/// What each `told` step last read for its key (its `~` waits for another value).
nonisolated(unsafe) var toldLast: [String: String] = [:]
Thread.detachNewThread {
    for step in scenario.steps {
        let p = step.split(separator: " ").map(String.init)
        let v = p.dropFirst().compactMap(Double.init)
        emit("step", ["step": step])
        switch p[0] {
        case "boot":
            let boot: BootConfig
            do { boot = try scenario.boot ?? preparedBoot(scenario.prepared!, hardware: hardware) } catch {
                fail("boot configuration: \(error)")
            }
            emit("argv", ["argv": boot.argv])
            bootAt = Date()
            guard case .success(.ok(true)) = request(.boot(boot)) else { fail("boot refused") }
        case "wait":
            usleep(UInt32(v[0] * 1e6))
        // told SECONDS KEY VALUE…: until the guest agent's report says `KEY VALUE` (`-`: it has no KEY line, `+`: it
        // has one, `~`: one with another value than the last told of KEY got, and not 0), which it does within a
        // quarter second of the guest changing: a wait for the fact, not for a time
        case "told":
            let want = p.dropFirst(3).joined(separator: " ")
            let before = toldLast[p[2]]
            let start = Date()
            var got = "-"
            func met() -> Bool {
                guard got != "no report" else { return false }
                return want == "+" ? got != "-" : want == "~" ? !["-", "0", before].contains(got) : got == want
            }
            repeat {
                // No report (none yet, or its session ended) tells nothing, the absence of a line included.
                let report = link.agentReport ?? ""
                got =
                    report.isEmpty
                    ? "no report"
                    : report.split(separator: "\n").first { $0.hasPrefix(p[2] + " ") }
                        .map { String($0.dropFirst(p[2].count + 1)) } ?? "-"
                if met() { break }
                usleep(50_000)
            } while Date().timeIntervalSince(start) < v[0]
            toldLast[p[2]] = got
            emit(
                "told",
                [
                    "key": p[2], "want": want, "got": got, "ok": met(),
                    "report": link.agentReport ?? "", "seconds": Date().timeIntervalSince(start),
                    "sinceBoot": Date().timeIntervalSince(bootAt)
                ]
            )
        // home [PRESSES]: Home (on the guest's clock) until the agent's report shows no app in front, at most PRESSES
        // (3) times 5 s apart: an alert standing over the app takes a press for itself (7.x's notice of the USB
        // keyboard does at every boot). `presses`, and `ok` when the app left
        case "home":
            var presses = 0
            var left = false
            let start = Date()
            while !left, presses < (v.first.map(Int.init) ?? 3) {
                presses += 1
                _ = blocking {
                    try await HostInputAutomation.perform(HostInputAutomation.press(0)) {
                        try await link.request($0, timeout: 5)
                    }
                }
                left =
                    (try? blocking {
                        await guest.agent.waitForReport(seconds: 5) { $0.isAnswering && $0.frontmost == nil }
                    }
                    .get()) == true
            }
            emit("home", ["presses": presses, "ok": left, "seconds": Date().timeIntervalSince(start)])
        // launch BUNDLE-ID: the app's own launch (GuestServices.launch, which asks a busy SpringBoard again)
        case "launch":
            let start = Date()
            let r = blocking { try await guest.launch(p[1]) }
            emit("launch", ["bundle": p[1], "result": "\(r)", "seconds": Date().timeIntervalSince(start)])
        // gesture tap X Y | drag X0 Y0 X1 Y1 | press BUTTON: made on the guest's clock, until the emulator made all
        // of it and the guest's digitizer driver read the touch (HostInputAutomation.perform); `ok` or why not.
        // tapshown and dragshown: the points as the window shows the picture (tapshown's mapping)
        case "gesture":
            var v = v
            if p[1].hasSuffix("shown"), let r = rotationDriver {
                v = onMain {
                    stride(from: 0, to: v.count - 1, by: 2).flatMap { i -> [Double] in
                        let point = r.touchPoint(shown: v[i], v[i + 1])
                        return [point.0, point.1]
                    }
                }
            }
            let events =
                p[1].hasPrefix("tap")
                ? HostInputAutomation.tap(v[0], v[1])
                : p[1].hasPrefix("drag")
                    ? HostInputAutomation.drag(from: (v[0], v[1]), to: (v[2], v[3]))
                    : HostInputAutomation.press(Int32(v[0]))
            let start = Date()
            let r = blocking {
                try await HostInputAutomation.perform(events) { try await link.request($0, timeout: 5) }
            }
            emit(
                "gesture",
                [
                    "kind": p[1], "ok": (try? r.get()) != nil, "result": "\(r)",
                    "seconds": Date().timeIntervalSince(start)
                ]
            )
        case "lit":
            let start = Date()
            var b = 0.0
            while b < v[0] {
                if noticeLock.withLock({ noticed["terminated"] != nil }) {
                    fail("the helper exited before the screen lit")
                }
                if Date().timeIntervalSince(start) > v[1] {
                    dump("never-lit")
                    fail("never lit (brightness \(b))")
                }
                usleep(100_000)
                b = frameLock.withLock { lastSurface }.map(FrameTools.brightness) ?? 0
            }
            emit(
                "lit",
                [
                    "seconds": Date().timeIntervalSince(start), "brightness": b, "frames": framesSeen,
                    "status": statusFields()
                ]
            )
        case "dump":
            dump(p[1])
        case "tap":
            link.send(.touch(slot: 0, phase: 0, x: v[0], y: v[1]))
            usleep(80_000)
            link.send(.touch(slot: 0, phase: 2, x: v[0], y: v[1]))
        case "drag", "dragshown":  // dragshown: from and to as the window shows the picture (tapshown's mapping)
            var v = v
            if p[0] == "dragshown", let r = rotationDriver {
                let (a, b) = onMain { (r.touchPoint(shown: v[0], v[1]), r.touchPoint(shown: v[2], v[3])) }
                v = [a.0, a.1, b.0, b.1]
            }
            link.send(.touch(slot: 0, phase: 0, x: v[0], y: v[1]))
            usleep(150_000)
            for i in 1...30 {
                let f = Double(i) / 30
                link.send(.touch(slot: 0, phase: 1, x: v[0] + (v[2] - v[0]) * f, y: v[1] + (v[3] - v[1]) * f))
                usleep(30_000)
            }
            usleep(300_000)
            link.send(.touch(slot: 0, phase: 2, x: v[2], y: v[3]))
        // wake X0 Y0 X1 Y1 [SECONDS]: until the display is on and the agent says unlocked, at most SECONDS (60): Home
        // (then Sleep/Wake) while it sleeps, the unlock drag while locked, nothing while SpringBoard doesn't answer (a
        // respring) or its lock screen doesn't take the drag yet
        case "wake":
            var tries = 0
            var lockedNow: Bool?
            let start = Date()
            while Date().timeIntervalSince(start) < (v.count > 4 ? v[4] : 60) {
                tries += 1
                if link.status?.displaySleeping == true {
                    let button = tries > 2 ? 1 : 0  // Home, then Sleep/Wake
                    link.send(.button(button, down: true))
                    usleep(150_000)
                    link.send(.button(button, down: false))
                    usleep(2_000_000)
                }
                lockedNow = try? blocking({ try await guest.agent.isLocked() }).get()
                guard let locked = lockedNow else {
                    usleep(1_000_000)
                    continue
                }
                guard locked else {
                    if link.status?.displaySleeping == false { break }
                    continue
                }
                link.send(.touch(slot: 0, phase: 0, x: v[0], y: v[1]))
                usleep(150_000)
                for i in 1...30 {
                    let f = Double(i) / 30
                    link.send(.touch(slot: 0, phase: 1, x: v[0] + (v[2] - v[0]) * f, y: v[1] + (v[3] - v[1]) * f))
                    usleep(30_000)
                }
                usleep(300_000)
                link.send(.touch(slot: 0, phase: 2, x: v[2], y: v[3]))
                usleep(3_000_000)
            }
            emit(
                "wake",
                [
                    "tries": tries, "sleeping": link.status?.displaySleeping ?? true, "locked": lockedNow ?? true,
                    "seconds": Date().timeIntervalSince(start)
                ]
            )
        case "button":
            link.send(.button(Int(v[0]), down: true))
            usleep(150_000)
            link.send(.button(Int(v[0]), down: false))
        case "battery":
            emit("reply", ["reply": "\(request(.battery(level: Int(v[0]), charging: Int(v[1]))))"])
        case "modem":  // modem <property> <value…>: qemu_ios_ui_modem_set through the link
            let value = p.dropFirst(2).joined(separator: " ")
            emit("reply", ["reply": "\(request(.modemSet(property: p[1], value: value)))", "modem": p[1]])
        case "modemSettle":
            // modemSettle QUIET MAX: an iPhone's early boot restarts CommCenter (it_prefs's Data Roaming reload), and
            // each restart switches the modem off (+CPWROFF; the status's power-offs) for seconds to ~30 s. Wait
            // until no restart can still be coming (QUIET seconds after boot) and the modem has been attached for
            // 5 s since the last one, at most MAX seconds after boot. Without power-offs/attached (an older emulator)
            // it waits QUIET.
            var powerOffs = 0
            var attachedSince: Date? = nil
            var offs: [Double] = []
            while true {
                let st = modemStatusNow()
                let since = Date().timeIntervalSince(bootAt)
                let n = st["power-offs"] as? Int ?? 0
                if n > powerOffs {
                    offs.append(since)
                    powerOffs = n
                    attachedSince = nil
                }
                let attached = st["attached"] as? Bool ?? (st["power-offs"] == nil)
                if !attached {
                    attachedSince = nil
                } else if attachedSince == nil {
                    attachedSince = Date()
                }
                let steady = attachedSince.map { Date().timeIntervalSince($0) >= 5 } ?? false
                if (since >= v[0] && steady) || since >= v[1] {
                    emit(
                        "modemSettled",
                        [
                            "secondsSinceBoot": since, "powerOffsAt": offs, "powerOffs": powerOffs,
                            "attached": attached,
                            "timedOut": !(since >= v[0] && steady)
                        ]
                    )
                    break
                }
                usleep(700_000)
            }
        case "modemStatus":  // the status as of the previous poll: poll twice, a beat apart
            _ = request(.modemStatus)
            usleep(300_000)
            if case .success(.modemStatus(let json)) = request(.modemStatus) {
                emit("modemStatus", ["json": json ?? ""])
            } else {
                emit("modemStatus", ["json": ""])
            }
        case "rotate":  // rotate cw|ccw: the app's ⌘-arrow (LinkCommand.rotate)
            link.send(.rotate(clockwise: p[1] == "cw"))
        case "turn":  // turn cw|ccw: the app's Rotate Right/Left (DeviceRotation.rotate(clockwise:))
            guard let r = rotationDriver else { fail("turn: no board") }
            let degrees = onMain {
                r.rotation.rotate(clockwise: p[1] == "cw")
                return r.rotation.degrees
            }
            emit("turned", ["degrees": degrees])
        // follow NAME: the app's watch of the guest's interface for one reading, read off the frame as published
        // (NAME.png: where the status bar's clock stands) and handed to DeviceRotation.interfaceRead as the watch does
        case "follow":
            guard let r = rotationDriver else { fail("follow: no board") }
            dump(p[1])
            let frame = URL(fileURLWithPath: "\(dumpDir)/\(p[1]).png")
            let interface = interfaceDegrees(frame: frame, scan: r.scan)
            let (degrees, held) = onMain {
                // UIInterfaceOrientation, as springboardservices reads it (DeviceRotation.iPadDegrees, inverted)
                if let interface, let reading = [0: 1, 90: 4, 180: 2, 270: 3][interface] {
                    r.lastInterface = r.rotation.interfaceRead(reading, last: r.lastInterface)
                }
                return (r.rotation.degrees, r.rotation.heldDegrees)
            }
            emit("followed", ["name": p[1], "interface": interface ?? -1, "degrees": degrees, "held": held])
        case "autorotate":  // autorotate on|off: the app's Auto-Rotate with Device (DeviceRotation.toggleAutoRotate)
            guard let r = rotationDriver else { fail("autorotate: no board") }
            onMain { if r.rotation.autoRotateEnabled != (p[1] == "on") { r.rotation.toggleAutoRotate() } }
        case "shot":  // shot NAME: the frame (NAME.png) and the picture as the window shows it (NAME-shown.png)
            guard let r = rotationDriver else { fail("shot: no board") }
            dump(p[1])
            let source = URL(fileURLWithPath: "\(dumpDir)/\(p[1]).png")
            let shown = URL(fileURLWithPath: "\(dumpDir)/\(p[1])-shown.png")
            let (ok, turns, degrees) = onMain { (r.writeShown(source, to: shown), r.turns, r.rotation.degrees) }
            emit("shot", ["name": p[1], "path": shown.path, "ok": ok, "turns": turns, "degrees": degrees])
        case "tapshown":  // tapshown U V [S]: a tap at (U, V) on the picture as the window shows it, held S (0.08) s
            guard let r = rotationDriver else { fail("tapshown: no board") }
            let (x, y) = onMain { r.touchPoint(shown: v[0], v[1]) }
            link.send(.touch(slot: 0, phase: 0, x: x, y: y))
            usleep(UInt32((v.count > 2 ? v[2] : 0.08) * 1e6))
            link.send(.touch(slot: 0, phase: 2, x: x, y: y))
        // flicks flick|slow N U V WIDTH: N trackpad gestures between the first Home page and the page left of it, after
        // `dump page` and `dump left` of each: right from the first page, left from the other; each a "flick" event
        // with the page before and after, by which reference the frame is nearer
        case "flicks":
            let page = URL(fileURLWithPath: "\(dumpDir)/page.png")
            let left = URL(fileURLWithPath: "\(dumpDir)/left.png")
            func onPage(_ name: String) -> (Bool, Double, Double) {
                dump(name)
                let url = URL(fileURLWithPath: "\(dumpDir)/\(name).png")
                let (a, b) = (pictureDistance(url, page), pictureDistance(url, left))
                return (a < b, a, b)
            }
            guard let r = rotationDriver else { fail("flicks: no board") }
            for i in 0..<Int(v[0]) {
                let (fromPage, fromPageD, fromLeftD) = onPage("flick\(i)a")
                let sign = fromPage ? 1.0 : -1.0
                let (a, b) = onMain { (r.touchPoint(shown: v[1], v[2]), r.touchPoint(shown: v[1] + sign / v[3], v[2])) }
                var log: [String] = []
                let frames = recordFrames {
                    log = playTrackpad(
                        trackpadGesture(p[1]),
                        start: CGPoint(x: a.0, y: a.1),
                        unit: CGVector(dx: b.0 - a.0, dy: b.1 - a.1),
                        link: link
                    )
                    usleep(1_500_000)
                }
                let (toPage, dPage, dLeft) = onPage("flick\(i)b")
                emit(
                    "flick",
                    [
                        "kind": p[1], "from": fromPage ? "page" : "left", "to": toPage ? "page" : "left",
                        "dPage": dPage, "dLeft": dLeft, "dStart": min(fromPageD, fromLeftD), "touches": log,
                        "frameTimes": frames.times, "framesSkipped": frames.skipped
                    ]
                )
            }
        // tapword WORD [DY]: tap where Vision reads WORD (_ for a space) on the window's picture, DY below it, looking
        // again for up to 10 s (a page still sliding in, a loaded host); else nothing
        case "tapword":
            guard let r = rotationDriver else { fail("tapword: no board") }
            let shown = URL(fileURLWithPath: "\(dumpDir)/tapword-shown.png")
            var at: (x: Double, y: Double)?
            for attempt in 0..<6 where at == nil {
                if attempt > 0 { usleep(2_000_000) }
                dump("tapword")
                _ = onMain { r.writeShown(URL(fileURLWithPath: "\(dumpDir)/tapword.png"), to: shown) }
                at = findWord(p[1].replacingOccurrences(of: "_", with: " "), in: shown)
            }
            emit("tapword", ["word": p[1], "found": at != nil])
            if let at {
                let (x, y) = onMain { r.touchPoint(shown: at.x, at.y + (v.first ?? 0)) }
                link.send(.touch(slot: 0, phase: 0, x: x, y: y))
                usleep(80_000)
                link.send(.touch(slot: 0, phase: 2, x: x, y: y))
            }
        case "orientation":
            emit("reply", ["reply": "\(request(.orientation(Int(v[0]))))"])
        case "compass":  // compass DEGREES: the app's Compass Heading (qemu_ios_ui_compass)
            emit("reply", ["reply": "\(request(.compass(Int(v[0]))))", "compass": p[1]])
        case "compass":  // compass DEGREES: the app's Compass Heading (qemu_ios_ui_compass)
            emit("reply", ["reply": "\(request(.compass(Int(v[0]))))", "compass": p[1]])
        case "agent", "agentop":  // agent COMMAND: exec in the guest; agentop OP [ARGS]: an agent operation
            let command = (p[0] == "agent" ? ["exec"] : []) + p.dropFirst()
            let r = request(
                .agent(request: "\(UUID().uuidString) \(command.joined(separator: " "))\n", deadline: 20),
                timeout: 25
            )
            var output = "\(r)"
            if case .success(.agent(let wire?)) = r, let body = wire.split(separator: "\n", maxSplits: 1).last {
                output = String(decoding: Data(base64Encoded: String(body)) ?? Data(), as: UTF8.self)
            }
            emit("agent", ["output": output])
        case "agentput", "spawn":
            // agentput LOCAL REMOTE: the file onto the guest (0755); spawn ARGV…: run it, no shell (the agent's ops)
            let body =
                p[0] == "spawn"
                ? Data(p.dropFirst().map { $0 + "\0" }.joined().utf8)
                : (try? Data(contentsOf: URL(fileURLWithPath: p[1]))) ?? Data()
            let op = p[0] == "spawn" ? "spawn" : "put \(p[2]) 755"
            let r = request(
                .agent(request: "\(UUID().uuidString) \(op)\n\(body.base64EncodedString())", deadline: 50),
                timeout: 55
            )
            var output = "\(r)"
            if case .success(.agent(let wire?)) = r {
                let parts = wire.split(separator: "\n", maxSplits: 1)
                let status = parts.first.map { String($0.split(separator: " ").last ?? "") } ?? ""
                let text = Data(base64Encoded: String(parts.last ?? "")) ?? Data()
                output = "status \(status)\n" + String(decoding: text, as: UTF8.self)
            }
            emit("agent", ["output": output, "op": p[0]])
        case "hostpb":  // hostpb TEXT…: the Mac's text to the guest's pasteboard (LinkCommand.paste)
            link.send(.paste(p.dropFirst().joined(separator: " ")))
        case "guestpb":  // guestpb TOOL get | TOOL set TEXT…: the guest's pasteboard through the agent's spawn of TOOL
            var argv = [p[1], p[2]]
            if p[2] == "set" { argv.append(p.dropFirst(3).joined(separator: " ")) }
            let body = Data(argv.map { $0 + "\0" }.joined().utf8)
            let r = request(
                .agent(request: "\(UUID().uuidString) spawn\n\(body.base64EncodedString())", deadline: 30),
                timeout: 35
            )
            var fields: [String: Any] = ["reply": "\(r)"]
            if case .success(.agent(let wire?)) = r {
                let parts = wire.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                fields["status"] = parts.first.map { String($0.split(separator: " ").last ?? "") } ?? ""
                let output = Data(base64Encoded: String(parts.last ?? "")) ?? Data()
                fields["text"] = String(decoding: output, as: UTF8.self)
            }
            emit("guestpb", fields)
        case "defaults":  // defaults DOMAIN KEY bool|int|float|string|delete [VALUE…]: GuestServices.writeDefaults
            let value: GuestDefaultValue? =
                switch p[3] {
                case "bool": .bool(p[4] == "1" || p[4] == "true")
                case "int": .int(Int(p[4]) ?? 0)
                case "float": .double(Double(p[4]) ?? 0)
                case "string": .string(p.dropFirst(4).joined(separator: " "))
                default: nil
                }
            let changed = blocking { try await guest.writeDefaults([GuestDefault(p[1], p[2], value)]) }
            emit("defaults", ["changed": "\(changed)"])
        case "agentget":  // agentget NAME REMOTE…: the guest's file into the dump directory as NAME
            let remote = p.dropFirst(2).joined(separator: " ")
            let data = blocking { try await guest.agent.get(remote, limit: 256 << 20) }
            if case .success(let d?) = data { try? d.write(to: URL(fileURLWithPath: "\(dumpDir)/\(p[1])")) }
            emit("agentget", ["path": remote, "result": "\(data.map { $0?.count ?? -1 })"])
        case "statusbar":  // statusbar clean|clear: the Marketing Status Bar's default, for the base's version
            guard let layout = StatusBarOverride.layout(version: baseVersion) else {
                emit("statusbar", ["error": "no layout for \(baseVersion)"])
                break
            }
            let body = p[1] == "clean" ? layout.data(StatusBarStyle()) : layout.cleared
            let r = blocking { try await guest.agent.raw("statusbar", body: body) }
            emit("statusbar", ["result": "\(r.map { $0.status })"])
        // tweaks NAME,NAME…: TweakApplier with those on, for the base's version, as DeviceTweaks applies
        case "tweaks":
            var settings = TweakSettings()
            settings.statusBar = marketing
            settings.on = Set(
                (p.count > 1 ? p[1] : "").split(separator: ",").compactMap { Tweak(rawValue: String($0)) }
            )
            settings.written = tweaksWritten
            let r = blocking {
                try await TweakApplier.apply(settings, version: baseVersion, guest: guest, again: tweaksApplied)
            }
            if case .success(let result) = r {
                tweaksWritten = result.written
                tweaksApplied = true
            }
            let resprung = (try? r.get().resprung) ?? false
            emit(
                "tweaks",
                [
                    "result": "\(r.map { "written \($0.written) resprung \($0.resprung) missing \($0.missing)" })",
                    "resprung": resprung, "ok": (try? r.get()) != nil,
                    "landedSeconds": resprung ? respringLanded() : 0
                ]
            )
        // sbread NAME: what SpringBoard's status bar server holds (the agent's statusbarget): whether its overrides
        // are the Marketing Status Bar's for the base's version, and the clock, carrier and battery its data shows
        case "sbread":
            guard let layout = StatusBarOverride.layout(version: baseVersion) else {
                emit("sbread", ["name": p[1], "error": "no layout for \(baseVersion)"])
                break
            }
            let held = blocking { try await guest.agent.perform("statusbarget", "override \(layout.cleared.count)") }
            let raw = blocking { try await guest.agent.perform("statusbarget", "data \(layout.rawSize)") }
            let shown = (try? raw.get()).map { layout.shown($0) }
            let ops = try? blocking { try await guest.agent.capabilities() }.get()
            emit(
                "sbread",
                [
                    "name": p[1], "readable": ops?.has("statusbarget") == true,
                    "held": (try? held.get()) == layout.data(marketing), "time": shown?.time ?? "",
                    "carrier": shown?.carrier ?? "", "battery": shown?.battery ?? -1, "result": "\(raw.map(\.count))"
                ]
            )
        // sbrestore: DeviceTweaks' check at every poll (TweakApplier.restoreStatusBar) with the Marketing Status Bar on
        case "sbrestore":
            var settings = TweakSettings()
            settings.statusBar = marketing
            settings.on = [.cleanStatusBar]
            let r = blocking { try await TweakApplier.restoreStatusBar(settings, version: baseVersion, guest: guest) }
            emit("sbrestore", ["posted": (try? r.get()) == true, "result": "\(r)"])
        case "ocr":  // ocr NAME: the picture as the window shows it, and every line Vision reads on it
            guard let r = rotationDriver else { fail("ocr: no board") }
            dump(p[1])
            let shown = URL(fileURLWithPath: "\(dumpDir)/\(p[1])-shown.png")
            _ = onMain { r.writeShown(URL(fileURLWithPath: "\(dumpDir)/\(p[1]).png"), to: shown) }
            emit(
                "ocr",
                [
                    "name": p[1], "lines": readText(in: shown), "statusBar": readStatusBar(in: shown),
                    "tint": tint(of: shown)
                ]
            )
        case "seen":  // seen WORD SECONDS: until Vision reads WORD on the screen (an icon's label: Home is up)
            guard let r = rotationDriver else { fail("seen: no board") }
            let start = Date()
            var found = false
            while !found, Date().timeIntervalSince(start) < Double(p[2]) ?? 60 {
                dump("seen")
                let shown = URL(fileURLWithPath: "\(dumpDir)/seen-shown.png")
                _ = onMain { r.writeShown(URL(fileURLWithPath: "\(dumpDir)/seen.png"), to: shown) }
                found = readText(in: shown).contains { $0.contains(p[1]) }
                if !found { usleep(1_000_000) }
            }
            emit("seen", ["word": p[1], "found": found, "seconds": Date().timeIntervalSince(start)])
        case "hidden":  // hidden [BUNDLE-ID]: the hidden apps the guest has (HiddenApp.present); with an id, open it
            let found = blocking { try await HiddenApp.present(on: guest) }
            var opened = ""
            if p.count > 1 {
                opened = "\(blocking { try await guest.launch(p[1]) })"
                usleep(8_000_000)
            }
            let front = blocking { try await guest.agent.frontmost() }
            emit(
                "hidden",
                [
                    "apps": (try? found.get().map(\.bundleID)) ?? [], "opened": opened,
                    "front": (try? front.get().bundleID) ?? ""
                ]
            )
        case "respring":  // Device ▸ Respring and Tweaks' restart (GuestServices.respring)
            let r = blocking { try await guest.respring() }
            emit("respring", ["result": "\(r)", "landedSeconds": respringLanded()])
        case "reset":  // the app's Restart (MachineOp.reset): the guest reboots in place
            link.send(.machine(.reset))
        // until SECONDS CONDITION: polls until CONDITION holds, at most SECONDS, where a fixed wait would stand in for
        // it; an "until" event says whether it was met. `text REGEX` (_ for a space): Vision reads a line matching
        // REGEX on the window's picture or its status bar; `locked`: the agent says locked (a restarted SpringBoard is
        // at its lock screen); `front`: an app, not SpringBoard, is frontmost (an app that quits soon after counts).
        case "until":
            let condition = p.dropFirst(2).joined(separator: " ")
            let start = Date()
            var met = false
            var front = ""
            while !met {
                switch p[2] {
                case "text":
                    dump("until")
                    var shown = URL(fileURLWithPath: "\(dumpDir)/until.png")
                    if let r = rotationDriver {
                        let turned = URL(fileURLWithPath: "\(dumpDir)/until-shown.png")
                        if onMain({ r.writeShown(shown, to: turned) }) { shown = turned }
                    }
                    let lines = readText(in: shown) + readStatusBar(in: shown)
                    let pattern = p[3].replacingOccurrences(of: "_", with: " ")
                    met = lines.contains { $0.range(of: pattern, options: .regularExpression) != nil }
                case "locked":
                    met = (try? blocking({ try await guest.agent.isLocked() }).get()) == true
                case "front":
                    front = (try? blocking({ try await guest.agent.frontmost() }).get())?.bundleID ?? ""
                    met = !front.isEmpty && front != "com.apple.springboard"
                default:
                    fail("unknown condition \(condition)")
                }
                if met || Date().timeIntervalSince(start) >= v[0] { break }
                usleep(500_000)
            }
            emit(
                "until",
                ["condition": condition, "met": met, "seconds": Date().timeIntervalSince(start), "front": front]
            )
        case "waitagent":  // waitagent SECONDS: until the agent is alive
            let start = Date()
            while link.status?.agentStatus != 1, Date().timeIntervalSince(start) < v[0] { usleep(250_000) }
            emit("waitagent", ["alive": link.status?.agentStatus == 1, "seconds": Date().timeIntervalSince(start)])
        case "audio":
            guard case .success(.audio(let g)) = request(.audioStart) else {
                emit("audio", ["error": "no capture"])
                break
            }
            usleep(UInt32(v[0] * 1e6))
            link.send(.audioStop(generation: g))
            usleep(1_500_000)
        case "snapshot", "snapshot-refused":  // snapshot-refused: the save must end in an error (status 3)
            let start = Date()
            link.send(.snapshotSave(path: p[1]))
            var code = 1
            var error = ""
            while Date().timeIntervalSince(start) < 60 {
                usleep(100_000)
                if case .success(.snapshot(let c, let e)) = request(.snapshotStatus) {
                    code = c
                    error = e ?? ""
                }
                if code >= 2 { break }
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: p[1])[.size] as? Int) ?? -1
            emit(
                "snapshot",
                [
                    "status": code, "error": error, "seconds": Date().timeIntervalSince(start), "bytes": bytes,
                    "glesContexts": link.status?.glesContexts ?? -1
                ]
            )
            if code != (p[0] == "snapshot" ? 2 : 3) { fail("snapshot ended with status \(code)") }
        case "gdb":  // gdb SOCKET: a debugger attaches to the Debug Port (lldb's unix-connect) and asks why it stopped
            guard let s = BridgeSocket.connect(p[1]) else { fail("no gdbstub at \(p[1])") }
            var tv = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            _ = write(s, "$?#3f", 5)
            // the stub's "+" ack, then its packet: read until a whole "$…#xx" came, or the 10 s timeout
            var text = ""
            var chunk = [UInt8](repeating: 0, count: 64)
            while !(text.contains("$") && text.range(of: "#[0-9a-f]{2}", options: .regularExpression) != nil) {
                let n = read(s, &chunk, chunk.count)
                guard n > 0 else { break }
                text += String(decoding: chunk.prefix(n), as: UTF8.self)
            }
            close(s)
            emit("gdb", ["socket": p[1], "reply": text])
            guard text.contains("$T") || text.contains("$S") else { fail("the gdbstub didn't answer ?: \(text)") }
        case "resume":
            link.send(.snapshotResume)
        case "pause", "unpause":  // the app's Pause and Resume (MachineOp.pause, .resume)
            link.send(.machine(p[0] == "pause" ? .pause : .resume))
        case "status":
            emit("status", statusFields())
        case "watch":
            let watch = DeviceFileWatch(directories: [URL(fileURLWithPath: p[1])], base: nil) { path in
                emit("meddled", ["path": path, "notice": DeviceFileWatch.notice(shortName: "iPod")])
            }
            watches.append(watch)
            emit("watching", ["count": watch.count])
        case "shutdown":  // shutdown <seconds>: Shut Down (MachineOp.shutdown), until the guest has powered off
            let start = Date()
            link.send(.machine(.shutdown))
            while link.status?.shutdownConfirmed != true, Date().timeIntervalSince(start) < v[0] { usleep(200_000) }
            emit(
                "shutdown",
                ["confirmed": link.status?.shutdownConfirmed == true, "seconds": Date().timeIntervalSince(start)]
            )
        case "keyboard":  // keyboard on|off: Connect Hardware Keyboard (qemu_ios_ui_hardware_keyboard)
            emit("reply", ["reply": "\(request(.hardwareKeyboard(p[1] == "on")))", "keyboard": p[1]])
        case "keys":  // keys WORD: lowercase letters as the Mac's keys (the app's key path: .key -> usb-kbd)
            let codes: [Character: Int] = [
                "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38, "k": 40, "l": 37,
                "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13,
                "x": 7, "y": 16, "z": 6
            ]
            for code in p[1].compactMap({ codes[$0] }) {
                link.send(.key(macKeyCode: code, down: true))
                usleep(100_000)
                link.send(.key(macKeyCode: code, down: false))
                usleep(150_000)
            }
        case "sample":  // sample LABEL SECONDS
            let pid = link.pid
            let h0 = link.status?.heartbeat ?? 0
            let f0 = link.status?.frameSerial ?? 0
            let u0 = usage(pid)
            let start = Date()
            usleep(UInt32(v[0] * 1e6))
            let u1 = usage(pid)
            let s = Date().timeIntervalSince(start)
            let h1 = link.status?.heartbeat ?? 0
            let f1 = link.status?.frameSerial ?? 0
            emit(
                "sample",
                [
                    "label": p[1], "seconds": s, "hz": Double(h1 &- h0) / s, "fps": Double(f1 &- f0) / s,
                    "cpuPercent": (u1.cpu - u0.cpu) / s * 100, "wakeupsPerSecond": Double(u1.wakeups &- u0.wakeups) / s,
                    "milliwatts": Double(u1.energy &- u0.energy) / s / 1e6, "preventsIdleSleep": preventsIdleSleep(pid),
                    "displaySleeping": link.status?.displaySleeping ?? false
                ]
            )
        case "visible":  // visible on|off
            let h0 = link.status?.heartbeat ?? 0
            let f0 = link.status?.frameSerial ?? 0
            let start = Date()
            link.send(.screenVisible(p[1] == "on"))
            var tick: Double?
            var frame: Double?
            while Date().timeIntervalSince(start) < 1, tick == nil || frame == nil {
                let ms = Date().timeIntervalSince(start) * 1000
                if tick == nil, (link.status?.heartbeat ?? 0) &- h0 >= 3 { tick = ms }
                if frame == nil, (link.status?.frameSerial ?? 0) != f0 { frame = ms }
                usleep(500)
            }
            emit("visible", ["on": p[1] == "on", "tickMs": tick ?? -1, "frameMs": frame ?? -1])
        case "waitSleep":  // waitSleep SECONDS: until the guest's display is asleep
            let start = Date()
            while link.status?.displaySleeping != true, Date().timeIntervalSince(start) < v[0] { usleep(200_000) }
            emit(
                "waitSleep",
                ["sleeping": link.status?.displaySleeping == true, "seconds": Date().timeIntervalSince(start)]
            )
        case "quit":
            link.send(.machine(.quit))
        case "expectExit":
            guard exitedEvent.wait(timeout: .now() + v[0]) == .success,
                terminated.wait(timeout: .now() + 5) == .success
            else { fail("no qemuExited + termination") }
        case "hold":
            emit("hold", ["helperPid": link.pid, "driverPid": getpid()])
            while true { sleep(60) }
        case "killHelper":
            let killed = Date().timeIntervalSince1970
            kill(link.pid, SIGKILL)
            guard invalidated.wait(timeout: .now() + 5) == .success,
                terminated.wait(timeout: .now() + 5) == .success
            else { fail("the client did not notice the helper's death") }
            let n = noticeLock.withLock { noticed }
            emit(
                "noticed",
                [
                    "invalidatedMs": ((n["invalidated"] ?? 0) - killed) * 1000,
                    "terminatedMs": ((n["terminated"] ?? 0) - killed) * 1000
                ]
            )
        default:
            fail("unknown step \(step)")
        }
    }
    emit("done")
    exit(0)
}

/// After a respring, until the new SpringBoard is up at its lock screen (the agent says locked; the old one, still
/// answering, says unlocked), at most 60 s: the seconds it took.
func respringLanded() -> Double {
    let start = Date()
    while (try? blocking({ try await guest.agent.isLocked() }).get()) != true, Date().timeIntervalSince(start) < 60 {
        usleep(500_000)
    }
    return Date().timeIntervalSince(start)
}

/// The helper's CPU seconds, wakeups and energy (nJ) so far.
func usage(_ pid: Int32) -> (cpu: Double, wakeups: UInt64, energy: UInt64) {
    var info = rusage_info_v6()
    let rc = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
    }
    guard rc == 0 else { return (0, 0, 0) }
    var base = mach_timebase_info_data_t()
    mach_timebase_info(&base)
    let cpu = Double(info.ri_user_time + info.ri_system_time) * Double(base.numer) / Double(base.denom) / 1e9
    return (cpu, info.ri_pkg_idle_wkups + info.ri_interrupt_wkups, info.ri_energy_nj)
}

/// pmset lists the helper as preventing idle system sleep.
func preventsIdleSleep(_ pid: Int32) -> Bool {
    let p = Process()
    let out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g", "assertions"]
    p.standardOutput = out
    guard (try? p.run()) != nil else { return false }
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return text.split(separator: "\n").contains {
        $0.contains("pid \(pid)(") && $0.contains("PreventUserIdleSystemSleep")
    }
}

/// While `body` runs: when each new frame reached the ring (s from the call), and how many of the emulator's frames
/// it never took (the serial moving by more than one).
func recordFrames(_ body: () -> Void) -> (times: [Double], skipped: UInt64) {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var times: [Double] = [], skipped: UInt64 = 0, done = false
    }
    let box = Box()
    let start = DispatchTime.now().uptimeNanoseconds
    let poller = Thread {
        var last = link.status?.frameSerial ?? 0
        while !box.lock.withLock({ box.done }) {
            if let serial = link.status?.frameSerial, serial != last {
                let t = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                box.lock.withLock {
                    box.times.append(t)
                    box.skipped += serial &- last &- 1
                }
                last = serial
            }
            usleep(250)
        }
    }
    poller.start()
    body()
    box.lock.withLock { box.done = true }
    while poller.isExecuting { usleep(1000) }
    return box.lock.withLock { (box.times, box.skipped) }
}

func dump(_ name: String) {
    guard let surface = frameLock.withLock({ lastSurface }) else { return emit("dump", ["name": name, "ok": false]) }
    let url = URL(fileURLWithPath: "\(dumpDir)/\(name).png")
    emit(
        "dump",
        [
            "name": name, "path": url.path, "ok": FrameTools.writePNG(surface, to: url),
            "brightness": FrameTools.brightness(surface), "width": surface.width, "height": surface.height
        ]
    )
}

while true { CFRunLoopRun() }
