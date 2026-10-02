import DeviceRuntime
import HostRuntime
// Stands in for the app in tests/sessions/check-helper-boot.py: spawns LightTouchDevice
// through DeviceLink (rendezvous, validation, status block, frame ring, link)
// and runs a scripted scenario. JSON lines on stdout; built by the test with
// swiftc from Shared/*.swift + LightTouchDevice/FrameTools.swift.
//
//   helper-driver --helper PATH --scenario scenario.json --dump DIR [--log native.log] [--requirement R]
//                 [--lease PATH] [--expect-failure TEXT]   (exit 0 if the start fails with TEXT)
//
// scenario: {"dylib": "...", "machine": "ipad1", "boot": BootConfig, "steps": ["boot", "lit 0.2 300", ...]}
// "watch DIR" starts the app's DeviceFileWatch on DIR (and its children): "meddled" events follow any change.

import Foundation
import IOSurface

var opts = [String: String]()
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() { opts[a] = it.next() ?? "" }
}

struct Scenario: Decodable {
    var dylib: String?
    var machine: String?
    var boot: BootConfig?
    var steps: [String]
}

let t0 = Date()
func emit(_ event: String, _ fields: [String: Any] = [:]) {
    var object = fields
    object["event"] = event
    object["t"] = (Date().timeIntervalSince(t0) * 1000).rounded() / 1000
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}
func fail(_ why: String) -> Never { emit("fail", ["why": why]); exit(1) }

let scenario = try! JSONDecoder().decode(Scenario.self, from: Data(contentsOf: URL(fileURLWithPath: opts["--scenario"]!)))
let dumpDir = opts["--dump"] ?? "/tmp"
let queue = DispatchQueue(label: "driver.link")

var logFD: Int32 = -1
if let log = opts["--log"] { logFD = open(log, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644) }
var configuration = DeviceLink.Configuration(instance: UUID(), outputDescriptor: logFD)
configuration.helper = URL(fileURLWithPath: opts["--helper"]!)
configuration.dylib = scenario.dylib
configuration.machine = scenario.machine
configuration.requirement = opts["--requirement"]
if let lease = opts["--lease"] { configuration.arguments = ["--lease", lease] }
let link = DeviceLink(configuration: configuration, queue: queue)

let exitedEvent = DispatchSemaphore(value: 0)
let invalidated = DispatchSemaphore(value: 0)
let terminated = DispatchSemaphore(value: 0)
var noticed: [String: Double] = [:]
let noticeLock = NSLock()
func notice(_ what: String) { noticeLock.withLock { noticed[what] = Date().timeIntervalSince1970 } }
var audioBytes = 0
var watches: [DeviceFileWatch] = []

link.onEvent = { event in
    switch event {
    case .qemuExited(let rc): emit("qemuExited", ["code": rc]); exitedEvent.signal()
    case .audio(_, _, let pcm): audioBytes += pcm.count
    case .audioEnded(let g, let failed): emit("audioEnded", ["generation": g, "failed": failed, "bytes": audioBytes])
    }
}
link.onInvalidated = { error in notice("invalidated"); emit("invalidated", ["error": "\(error)"]); invalidated.signal() }
link.onTerminated = { termination in
    notice("terminated")
    emit("terminated", ["termination": "\(termination)"])
    terminated.signal()
}

func sync<T>(_ body: (@escaping (T) -> Void) -> Void) -> T {
    let done = DispatchSemaphore(value: 0)
    var value: T?
    body { value = $0; done.signal() }
    done.wait()
    return value!
}

func request(_ r: LinkRequest, timeout: TimeInterval = 10) -> Result<LinkReply, DeviceLinkError> {
    sync { link.request(r, timeout: timeout, reply: $0) }
}

func statusFields() -> [String: Any] {
    guard let s = link.status else { return [:] }
    return ["heartbeat": s.heartbeat, "frameSerial": s.frameSerial, "width": s.width, "height": s.height,
            "uiReady": s.uiReady, "storageFailed": s.storageFailed, "shutdownConfirmed": s.shutdownConfirmed,
            "displaySleeping": s.displaySleeping, "agentStatus": s.agentStatus, "glesContexts": s.glesContexts,
            "iconGeneration": s.iconGeneration, "qemuState": s.qemuState.rawValue]
}

// The display link: sample the ring at 60 Hz, like DisplayView will.
var lastSurface: IOSurface?
var framesSeen = 0
let frameLock = NSLock()
let display = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "driver.display"))
display.schedule(deadline: .now(), repeating: 1.0 / 60)
display.setEventHandler {
    if let f = link.frontSurface(), f.isNew { frameLock.withLock { lastSurface = f.surface; framesSeen += 1 } }
}

let started: Result<HelperInfo, DeviceLinkError> = sync { link.start(completion: $0) }
switch started {
case .success(let info):
    emit("connected", ["pid": info.pid, "protocol": info.protocolVersion, "dylib": info.dylibPath,
                       "dylibModified": info.dylibModified, "buildID": info.buildID ?? "",
                       "deviceInfo": info.deviceInfo.map { "\($0.machine) \($0.screenWidth)x\($0.screenHeight) scale \($0.screenScale)" } ?? "",
                       "status": statusFields()])
case .failure(let error):
    emit("startFailed", ["error": "\(error)"])
    if let text = opts["--expect-failure"] { exit("\(error)".contains(text) ? 0 : 1) }
    exit(opts["--expect-reject"] != nil && "\(error)".contains("rejected") ? 0 : 1)
}
if opts["--expect-reject"] != nil { fail("an impostor was accepted") }
if opts["--expect-failure"] != nil { fail("the start was expected to fail") }
display.resume()

Thread.detachNewThread {
    for step in scenario.steps {
        let p = step.split(separator: " ").map(String.init)
        let v = p.dropFirst().compactMap(Double.init)
        emit("step", ["step": step])
        switch p[0] {
        case "boot":
            guard let boot = scenario.boot, case .success(.ok(true)) = request(.boot(boot)) else { fail("boot refused") }
        case "wait":
            usleep(UInt32(v[0] * 1e6))
        case "lit":
            let start = Date()
            var b = 0.0
            while b < v[0] {
                if noticeLock.withLock({ noticed["terminated"] != nil }) { fail("the helper exited before the screen lit") }
                if Date().timeIntervalSince(start) > v[1] { dump("never-lit"); fail("never lit (brightness \(b))") }
                usleep(100_000)
                b = frameLock.withLock { lastSurface }.map(FrameTools.brightness) ?? 0
            }
            emit("lit", ["seconds": Date().timeIntervalSince(start), "brightness": b, "frames": framesSeen, "status": statusFields()])
        case "dump":
            dump(p[1])
        case "tap":
            link.send(.touch(slot: 0, phase: 0, x: v[0], y: v[1])); usleep(80_000)
            link.send(.touch(slot: 0, phase: 2, x: v[0], y: v[1]))
        case "drag":
            link.send(.touch(slot: 0, phase: 0, x: v[0], y: v[1])); usleep(150_000)
            for i in 1...30 {
                let f = Double(i) / 30
                link.send(.touch(slot: 0, phase: 1, x: v[0] + (v[2] - v[0]) * f, y: v[1] + (v[3] - v[1]) * f))
                usleep(30_000)
            }
            usleep(300_000)
            link.send(.touch(slot: 0, phase: 2, x: v[2], y: v[3]))
        case "button":
            link.send(.button(Int(v[0]), down: true)); usleep(150_000)
            link.send(.button(Int(v[0]), down: false))
        case "battery":
            emit("reply", ["reply": "\(request(.battery(level: Int(v[0]), charging: Int(v[1]))))"])
        case "orientation":
            emit("reply", ["reply": "\(request(.orientation(Int(v[0]))))"])
        case "agent":
            let command = p.dropFirst().joined(separator: " ")
            let r = request(.agent(request: "\(UUID().uuidString) exec \(command)\n", deadline: 20), timeout: 25)
            var output = "\(r)"
            if case .success(.agent(let wire?)) = r, let body = wire.split(separator: "\n", maxSplits: 1).last {
                output = String(decoding: Data(base64Encoded: String(body)) ?? Data(), as: UTF8.self)
            }
            emit("agent", ["output": output])
        case "audio":
            guard case .success(.audio(let g)) = request(.audioStart) else { emit("audio", ["error": "no capture"]); break }
            usleep(UInt32(v[0] * 1e6))
            link.send(.audioStop(generation: g))
            usleep(1_500_000)
        case "snapshot":
            let start = Date()
            link.send(.snapshotSave(path: p[1]))
            var code = 1, error = ""
            while Date().timeIntervalSince(start) < 60 {
                usleep(100_000)
                if case .success(.snapshot(let c, let e)) = request(.snapshotStatus) { code = c; error = e ?? "" }
                if code >= 2 { break }
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: p[1])[.size] as? Int) ?? -1
            emit("snapshot", ["status": code, "error": error, "seconds": Date().timeIntervalSince(start), "bytes": bytes,
                              "glesContexts": link.status?.glesContexts ?? -1])
            if code != 2 { fail("snapshot failed") }
        case "resume":
            link.send(.snapshotResume)
        case "status":
            emit("status", statusFields())
        case "watch":
            let watch = DeviceFileWatch(directories: [URL(fileURLWithPath: p[1])], base: nil) { path in
                emit("meddled", ["path": path, "notice": DeviceFileWatch.notice(shortName: "iPod")])
            }
            watches.append(watch)
            emit("watching", ["count": watch.count])
        case "quit":
            link.send(.machine(.quit))
        case "expectExit":
            guard exitedEvent.wait(timeout: .now() + v[0]) == .success,
                  terminated.wait(timeout: .now() + 5) == .success else { fail("no qemuExited + termination") }
        case "hold":
            emit("hold", ["helperPid": link.pid, "driverPid": getpid()])
            while true { sleep(60) }
        case "killHelper":
            let killed = Date().timeIntervalSince1970
            kill(link.pid, SIGKILL)
            guard invalidated.wait(timeout: .now() + 5) == .success,
                  terminated.wait(timeout: .now() + 5) == .success else { fail("the client did not notice the helper's death") }
            let n = noticeLock.withLock { noticed }
            emit("noticed", ["invalidatedMs": ((n["invalidated"] ?? 0) - killed) * 1000,
                             "terminatedMs": ((n["terminated"] ?? 0) - killed) * 1000])
        default:
            fail("unknown step \(step)")
        }
    }
    emit("done")
    exit(0)
}

func dump(_ name: String) {
    guard let surface = frameLock.withLock({ lastSurface }) else { return emit("dump", ["name": name, "ok": false]) }
    let url = URL(fileURLWithPath: "\(dumpDir)/\(name).png")
    emit("dump", ["name": name, "path": url.path, "ok": FrameTools.writePNG(surface, to: url),
                  "brightness": FrameTools.brightness(surface), "width": surface.width, "height": surface.height])
}

while true { CFRunLoopRun() }
