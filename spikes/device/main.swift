// Phase 0 spike: a stand-in for LightTouchDevice.
//
//   LightTouchDevice --connect SERVICE --uuid U --token T (--synthetic | --config boot.json)
//
// Connects to the parent's NSXPCListener, sends the one-time token, then the
// status block + 3-surface frame ring, and writes frames into the ring at 60 Hz:
// synthetic solid frames (latency/CPU measurement) or qemu_ios_ui_frame from a
// dlopened libqemu-arm.dylib running qemu_ios_main on a 16 MB-stack thread.
import Foundation
import IOSurface

// MARK: - arguments
var args = [String: String]()
var flags = Set<String>()
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        if ["--synthetic", "--headless", "--bad-token"].contains(a) { flags.insert(a) } else { args[a] = it.next() }
    }
}
let parentPID = getppid()

// MARK: - qemu (dlopen)
struct Config: Decodable {
    var dylib: String
    var argv: [String]
    var env: [String: String]?
    var actions: [String]?          // run in order once the screen is lit
    var litFraction: Double?
    var maxSeconds: Double?
}
typealias FMain = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
typealias FAttach = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void
typealias FFrame = @convention(c) (UnsafeMutablePointer<UnsafeRawPointer?>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<UInt64>) -> Bool
typealias FVoid = @convention(c) () -> Void
typealias FInt = @convention(c) () -> Int32
typealias FBool = @convention(c) () -> Bool
typealias FPath = @convention(c) (UnsafePointer<CChar>) -> Void
typealias FStatus = @convention(c) (UnsafeMutablePointer<CChar>, UInt) -> Int32
typealias FTouch = @convention(c) (Int32, Int32, Double, Double) -> Void
typealias FButton = @convention(c) (Int32, Bool) -> Void

final class Qemu {
    let h: UnsafeMutableRawPointer
    init(_ path: String) {
        guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            log("dlopen failed: \(String(cString: dlerror()))"); exit(70)
        }
        self.h = h
    }
    func sym<T>(_ name: String, _: T.Type) -> T {
        guard let p = dlsym(h, name) else { log("missing \(name)"); exit(71) }
        return unsafeBitCast(p, to: T.self)
    }
    lazy var main = sym("qemu_ios_main", FMain.self)
    lazy var attach = sym("qemu_ios_ui_attach", FAttach.self)
    lazy var frame = sym("qemu_ios_ui_frame", FFrame.self)
    lazy var ready = sym("qemu_ios_ui_ready", FBool.self)
    lazy var glContexts = sym("qemu_ios_gles_contexts", FInt.self)
    lazy var save2 = sym("qemu_ios_snapshot_save2", FPath.self)
    lazy var snapStatus = sym("qemu_ios_snapshot_status", FStatus.self)
    lazy var snapResume = sym("qemu_ios_snapshot_resume", FVoid.self)
    lazy var quit = sym("qemu_ios_ui_quit", FVoid.self)
    lazy var powerdown = sym("qemu_ios_ui_powerdown", FVoid.self)
    lazy var shutdownConfirmed = sym("qemu_ios_ui_guest_shutdown_confirmed", FBool.self)
    lazy var touch = sym("qemu_ios_ui_touch", FTouch.self)
    lazy var button = sym("qemu_ios_ui_button", FButton.self)
}

// MARK: - link: fd 3 is our end of the parent's socketpair; surfaces go by Mach.
let service = args["--connect"] ?? ""
var link: Link?
func send(_ d: [String: Any]) { link?.send(d) }
var qemu: Qemu?
var shuttingDown = false
func shutdown(reason: String) {
    DispatchQueue.main.async {
        guard !shuttingDown else { return }
        shuttingDown = true
        log("shutdown: \(reason)")
        guard let q = qemu, q.ready() else { exit(0) }
        // Parent gone: power the guest down (bounded), then exit.
        q.powerdown()
        DispatchQueue.global().async {
            let t0 = Date()
            while Date().timeIntervalSince(t0) < 20, !q.shutdownConfirmed() { usleep(50_000) }
            log("powerdown confirmed=\(q.shutdownConfirmed()) after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
            q.quit()
            usleep(2_000_000)
            exit(0)
        }
    }
}

// Parent death: a process-exit source on the parent pid, plus EOF on the socketpair.
let parentWatch = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .main)
parentWatch.setEventHandler { log("NOTICED parent exit (process source)"); shutdown(reason: "parent exited") }
parentWatch.resume()
if parentPID == 1 { log("parent already gone"); exit(0) }
if fcntl(3, F_GETFD) != -1 {
    link = Link(fd: 3, queue: .main, onMessage: { m in
        log("command \(m)")
        if m["op"] as? String == "quit" { shutdown(reason: "parent asked") }
    }, onEOF: { log("NOTICED link EOF"); shutdown(reason: "link closed") })
} else { log("no fd 3: not spawned by a host") }

// MARK: - surfaces
let status = makeSurface(width: 512, height: 1, bytesPerElement: 8)   // 4 KB
let st = Status(status)
st[.magic] = statusMagic
var ring: [IOSurface] = []
var ringW = 0, ringH = 0
func makeRing(_ w: Int, _ h: Int) {
    ring = (0..<3).map { _ in makeSurface(width: w, height: h) }
    ringW = w; ringH = h
    st[.width] = UInt64(w); st[.height] = UInt64(h)
    // surfacesChanged: token + [status] + ring as Mach send rights, one message.
    let ports = ([status] + ring).map { IOSurfaceCreateMachPort($0) }
    let token = flags.contains("--bad-token") ? "not-the-token" : (args["--token"] ?? "")
    let kr = ports.withUnsafeBufferPointer { ltm_send_hello(service, token, $0.baseAddress, Int32($0.count)) }
    log("hello with \(ports.count) surface ports -> \(kr == 0 ? "sent" : "kr \(kr)")")
    if kr != 0 { exit(72) }
    log("ring \(w)x\(h) bytesPerRow=\(ring[0].bytesPerRow)")
}

var serial: UInt64 = 0
var noFreeSurface = 0
var writeMs: [Double] = []
/// Pick a surface that is neither front, nor held by the parent, nor in use (CA).
func publish(_ fill: (IOSurface) -> Void) {
    let front = Int(st[.front])
    let held = Int(ltm_load_seq(st.base + Slot.held.rawValue)) - 1
    guard let i = (0..<3).first(where: { $0 != front && $0 != held && !ring[$0].isInUse }) else {
        noFreeSurface += 1; return
    }
    let t0 = mach_absolute_time()
    ring[i].lock(options: [], seed: nil)
    fill(ring[i])
    ring[i].unlock(options: [], seed: nil)
    writeMs.append(ticksToMs(mach_absolute_time() - t0))
    serial += 1
    st[.front] = UInt64(i)
    st[.publishTicks] = mach_absolute_time()
    ltm_store_seq(st.base + Slot.frameSerial.rawValue, serial)
}

/// Never dispatchMain(): it pthread_exit()s the main thread, and the dylib's RCU
/// constructor registered that thread as a reader, so call_rcu_thread then walks a
/// freed TLS record (seen here as random heap corruption in qemu_init: SIGSEGVs,
/// "unknown migration protocol: (null)" from a clobbered argv). Keep it alive.
func parkMainThread() -> Never { while true { CFRunLoopRun() } }

// MARK: - modes
let cpu0 = cpuSeconds(), wall0 = Date()
func report() -> [String: Any] {
    let s = writeMs.sorted()
    return ["op": "stats", "frames": serial, "noFreeSurface": noFreeSurface,
            "cpuSeconds": cpuSeconds() - cpu0, "wall": Date().timeIntervalSince(wall0),
            "writeMsP50": s.isEmpty ? 0 : s[s.count / 2], "writeMsMax": s.last ?? 0]
}

if flags.contains("--synthetic") {
    let w = Int(args["--width"] ?? "1024")!, h = Int(args["--height"] ?? "768")!
    let seconds = Double(args["--seconds"] ?? "10")!
    makeRing(w, h)
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue(label: "frames", qos: .userInteractive))
    timer.schedule(deadline: .now() + 0.2, repeating: 1.0 / 60)
    timer.setEventHandler {
        st[.heartbeat] &+= 1
        publish { s in
            let tag = UInt32(truncatingIfNeeded: serial + 1) & 0xFFFFFF | 0xFF00_0000
            let p = s.baseAddress.assumingMemoryBound(to: UInt32.self)
            let n = s.bytesPerRow / 4 * s.height
            p.update(repeating: tag, count: n)
        }
        if Date().timeIntervalSince(wall0) > seconds + 0.2 {
            timer.cancel()
            send(report())
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
        }
    }
    timer.resume()
    parkMainThread()
}

// qemu mode
let cfg = try! JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: args["--config"]!)))
for (k, v) in cfg.env ?? [:] { setenv(k, v, 1) }
let q = Qemu(cfg.dylib)
qemu = q
q.attach(nil, nil)
let qthread = Thread {
    var cargs = cfg.argv.map { strdup($0) }
    cargs.append(nil)
    let rc = q.main(Int32(cfg.argv.count), &cargs)
    log("qemu_ios_main returned \(rc)")
    send(report())
    send(["op": "qemuExited", "rc": rc])
    usleep(300_000)
    exit(rc)
}
qthread.name = "qemu-main"
qthread.stackSize = 16 << 20
qthread.qualityOfService = .userInteractive
qthread.start()
log("booting \(cfg.argv.joined(separator: " "))")

var lastQemuSerial: UInt64 = 0
var litSince: Date?
var brightness = 0.0
let frameQueue = DispatchQueue(label: "frames", qos: .userInteractive)
let timer = DispatchSource.makeTimerSource(flags: .strict, queue: frameQueue)
timer.schedule(deadline: .now() + 0.5, repeating: 1.0 / 60)
var ticks = 0
timer.setEventHandler {
    ticks += 1
    st[.heartbeat] &+= 1
    if ticks % 20 == 0 { st[.glesContexts] = UInt64(max(0, q.glContexts())); st[.uiReady] = q.ready() ? 1 : 0 }
    var px: UnsafeRawPointer?
    var w: Int32 = 0, h: Int32 = 0, s = lastQemuSerial
    guard q.ready(), q.frame(&px, &w, &h, &s), let px, w > 0 else { return }
    lastQemuSerial = s
    if Int(w) != ringW || Int(h) != ringH { makeRing(Int(w), Int(h)) }
    publish { surf in
        let dst = surf.baseAddress, rowBytes = Int(w) * 4
        for y in 0..<Int(h) { memcpy(dst + y * surf.bytesPerRow, px + y * rowBytes, rowBytes) }
        // Lit: share of sampled bytes over 60.
        var bright = 0, total = 0
        var o = 0
        let n = rowBytes * Int(h)
        while o < n { if px.load(fromByteOffset: o, as: UInt8.self) > 60 { bright += 1 }; total += 1; o += 997 }
        brightness = Double(bright) / Double(total)
    }
}
timer.resume()

// Actions, run on a plain thread once lit.
Thread.detachNewThread {
    let t0 = Date()
    let need = cfg.litFraction ?? 0.2
    while brightness < need {
        if Date().timeIntervalSince(t0) > (cfg.maxSeconds ?? 500) { log("never lit (brightness \(brightness))"); send(["op": "dump", "name": "never-lit"]); usleep(500_000); q.quit(); return }
        usleep(250_000)
    }
    log(String(format: "LIT after %.1f s (brightness %.2f, frames %llu)", Date().timeIntervalSince(t0), brightness, serial))
    send(["op": "lit", "seconds": Date().timeIntervalSince(t0)])
    for a in cfg.actions ?? [] {
        let p = a.split(separator: " ").map(String.init)
        log("action \(a) (gl contexts \(q.glContexts()), brightness \(String(format: "%.2f", brightness)))")
        switch p[0] {
        case "wait": usleep(UInt32(Double(p[1])! * 1e6))
        case "dump": send(["op": "dump", "name": p[1]]); usleep(300_000)
        case "button": q.button(Int32(p[1])!, true); usleep(150_000); q.button(Int32(p[1])!, false)
        case "drag":   // drag x0 y0 x1 y1 (normalised)
            let v = p[1...4].map { Double($0)! }
            q.touch(0, 0, v[0], v[1]); usleep(150_000)
            for i in 1...30 { q.touch(0, 1, v[0] + (v[2] - v[0]) * Double(i) / 30, v[1] + (v[3] - v[1]) * Double(i) / 30); usleep(30_000) }
            usleep(300_000); q.touch(0, 2, v[2], v[3])
        case "tap":
            let x = Double(p[1])!, y = Double(p[2])!
            q.touch(0, 0, x, y); usleep(80_000); q.touch(0, 2, x, y)
        case "snapshot":
            let gl = q.glContexts()
            let ts = Date()
            q.save2(p[1])
            var buf = [CChar](repeating: 0, count: 256)
            var r: Int32 = 1
            while Date().timeIntervalSince(ts) < 30 { r = q.snapStatus(&buf, 256); if r >= 2 { break }; usleep(100_000) }
            let size = (try? FileManager.default.attributesOfItem(atPath: p[1])[.size] as? Int) ?? -1
            log(String(format: "snapshot status=%d (%@) in %.2f s, %d bytes, gl contexts at save=%d", r, String(cString: buf), Date().timeIntervalSince(ts), size, gl))
            send(["op": "snapshot", "status": r, "seconds": Date().timeIntervalSince(ts), "bytes": size, "gl": gl])
        case "resume": q.snapResume()
        case "powerdown": shutdown(reason: "action powerdown")
        case "quit": send(report()); usleep(200_000); q.quit()
        default: log("unknown action \(a)")
        }
    }
}
parkMainThread()
