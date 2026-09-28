// Phase 0 spike: a stand-in for the app side of the device link.
//
//   spike-host [--requirement REQ] [--poll-us N] [--dump DIR] [--seconds N]
//              --device "EXE ARGS..." [--device ...]
//
// Checks in "<bundle>.devices.<pid>" with launchd (bootstrap_check_in), spawns each
// device with --connect/--uuid/--token, accepts only the spawned pid + code
// signing requirement + token, then watches each device's status block and
// frame ring, measuring publish -> observe latency and checking for tearing.
import Foundation
import IOSurface
import ImageIO
import UniformTypeIdentifiers
import Security

var opts = [String: [String]]()
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() { opts[a, default: []].append(it.next() ?? "") }
}
let service = "gold.samhenri.LightTouchMac.devices.\(getpid())"
let requirement = opts["--requirement"]?.first ?? "anchor apple generic and certificate leaf[subject.OU] = \"SM75355Y6R\""
let pollUs = UInt32(opts["--poll-us"]?.first ?? "1000")!
let dumpDir = opts["--dump"]?.first
let maxSeconds = Double(opts["--seconds"]?.first ?? "600")!

final class Device {
    let index: Int, uuid = UUID().uuidString, token = UUID().uuidString
    let exe: String, argv: [String]
    var pid: pid_t = 0
    var link: Link?
    var authenticated = false
    var status: Status?
    var ring: [IOSurface] = []
    var lock = NSLock()
    var latencies: [Double] = []
    var observed = 0, missed = 0, torn = 0, retries = 0
    var lastSerial: UInt64 = 0
    var heldIndex = -1
    var exited = false
    var childStats: [String: Any] = [:]
    var exitWatch: DispatchSourceProcess?

    init(index: Int, spec: String) {
        self.index = index
        let parts = spec.split(separator: " ").map(String.init)
        exe = parts[0]
        argv = [exe, "--connect", service, "--uuid", uuid, "--token", token] + parts.dropFirst()
    }

    // helper -> app, over the socketpair; ignored until the Mach hello passed.
    func event(_ m: [String: Any]) {
        guard let op = m["op"] as? String else { return }
        guard authenticated else { log("device \(index): \(op) before a valid hello, dropped"); return }
        switch op {
        case "stats": childStats = m; log("device \(index) child stats \(m)")
        case "dump": dump(m["name"] as? String ?? "frame")
        default: log("device \(index) event \(m)")
        }
    }
    func surfacesChanged(_ surfaces: [IOSurface]) {
        lock.lock(); defer { lock.unlock() }
        if heldIndex >= 0, heldIndex < ring.count { ring[heldIndex].decrementUseCount() }
        heldIndex = -1
        status = Status(surfaces[0])
        ring = Array(surfaces.dropFirst())
        log("device \(index): \(surfaces.count) surfaces, magic ok=\(status![.magic] == statusMagic), ring \(ring.first.map { "\($0.width)x\($0.height)" } ?? "-")")
    }

    /// One poll: if the serial moved, take the front surface (seqlock-style handshake).
    func poll() {
        lock.lock(); defer { lock.unlock() }
        guard let st = status, ring.count == 3 else { return }
        let s1 = ltm_load_seq(st.base + Slot.frameSerial.rawValue)
        guard s1 != lastSerial else { return }
        let front = Int(st[.front]), published = st[.publishTicks]
        ltm_store_seq(st.base + Slot.held.rawValue, UInt64(front + 1))
        let s2 = ltm_load_seq(st.base + Slot.frameSerial.rawValue)
        if s2 != s1 { retries += 1; return }       // it moved under us: take the newer one next poll
        latencies.append(ticksToMs(mach_absolute_time() - published))
        if lastSerial != 0, s1 > lastSerial + 1 { missed += Int(s1 - lastSerial - 1) }
        lastSerial = s1
        observed += 1
        if heldIndex >= 0 { ring[heldIndex].decrementUseCount() }
        ring[front].incrementUseCount()                // what layer.contents would do
        heldIndex = front
        if opts["--check-tear"] != nil {
            let tag = UInt32(truncatingIfNeeded: s1) & 0xFFFFFF | 0xFF00_0000
            let surf = ring[front]
            let p = surf.baseAddress.assumingMemoryBound(to: UInt32.self)
            let n = surf.bytesPerRow / 4 * surf.height
            for k in 0..<64 where p[(n - 1) * k / 63] != tag { torn += 1; break }
        }
    }

    func dump(_ name: String) {
        guard let dumpDir else { return }
        lock.lock(); defer { lock.unlock() }
        guard let st = status, ring.count == 3 else { log("device \(index): no surfaces to dump"); return }
        let surf = ring[heldIndex >= 0 ? heldIndex : Int(st[.front])]
        // BGRA, alpha ignored: the iPod's framebuffer leaves it 0.
        surf.lock(options: .readOnly, seed: nil)
        let data = Data(bytes: surf.baseAddress, count: surf.bytesPerRow * surf.height)
        surf.unlock(options: .readOnly, seed: nil)
        guard let cg = CGImage(width: surf.width, height: surf.height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: surf.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else { return }
        let url = URL(fileURLWithPath: "\(dumpDir)/dev\(index)-\(name).png")
        let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, cg, nil)
        CGImageDestinationFinalize(d)
        log("device \(index): dumped \(url.path)")
    }

    func summary() -> [String: Any] {
        let s = latencies.sorted()
        func pct(_ p: Double) -> Double { s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))] }
        return ["device": index, "observed": observed, "missed": missed, "torn": torn, "retries": retries,
                "latencyMsP50": pct(0.5), "latencyMsP95": pct(0.95), "latencyMsP99": pct(0.99), "latencyMsMax": s.last ?? 0,
                "child": childStats]
    }
}

var devices: [Device] = []

// Rendezvous: launchd check-in of a per-pid name (an XPC listener refuses a name
// launchd doesn't know; raw bootstrap_check_in does not). Every hello is checked:
// sender pid (kernel audit trailer) is a device we spawned and haven't heard from,
// its code satisfies the requirement, and it carries that device's one-time token.
var rx: mach_port_t = 0
let ckr = ltm_check_in(service, &rx)
guard ckr == 0 else { log("bootstrap_check_in failed: \(ckr)"); exit(1) }
log("checked in \(service)")

func validate(_ h: ltm_hello) -> (Device?, String) {
    guard let dev = devices.first(where: { $0.pid == h.pid && !$0.authenticated }) else {
        return (nil, "pid \(h.pid) is not a spawned device (or already connected)")
    }
    var audit = h.audit
    let tokenData = withUnsafeBytes(of: &audit) { Data($0) }
    var code: SecCode?
    var req: SecRequirement?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess, let code,
          SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else {
        return (nil, "pid \(h.pid): no code object")
    }
    let v = SecCodeCheckValidity(code, [], req)
    guard v == errSecSuccess else { return (nil, "pid \(h.pid): code signing requirement failed (\(v))") }
    let t = withUnsafeBytes(of: h.token) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    guard t == dev.token else { return (nil, "pid \(h.pid): wrong token") }
    guard h.nports == 4 else { return (nil, "pid \(h.pid): expected 4 surface ports, got \(h.nports)") }
    return (dev, "ok")
}

Thread.detachNewThread {
    while true {
        var h = ltm_hello()
        guard ltm_recv_hello(rx, -1, &h) == 0 else { continue }
        let (dev, why) = validate(h)
        let ports = withUnsafeBytes(of: h.ports) { Array($0.bindMemory(to: mach_port_t.self).prefix(Int(max(0, h.nports)))) }
        guard let dev else {
            log("REJECT hello: \(why)")
            for p in ports where p != 0 { mach_port_deallocate(mach_task_self_, p) }
            continue
        }
        let surfaces = ports.compactMap { IOSurfaceLookupFromMachPort($0) }
        for p in ports { mach_port_deallocate(mach_task_self_, p) }
        let objs = surfaces.map { unsafeBitCast($0, to: IOSurface.self) }
        dev.authenticated = true
        log("ACCEPT device \(dev.index) pid \(h.pid): requirement + token ok, \(objs.count) surfaces")
        dev.surfacesChanged(objs)
    }
}

let cpu0 = cpuSeconds()
let started = Date()
for (i, spec) in (opts["--device"] ?? []).enumerated() {
    let d = Device(index: i, spec: spec)
    var sv: [Int32] = [0, 0]
    socketpair(AF_UNIX, SOCK_STREAM, 0, &sv)
    fcntl(sv[0], F_SETFD, FD_CLOEXEC)
    var cargs = d.argv.map { strdup($0) }
    cargs.append(nil)
    d.pid = ltm_spawn(d.exe, &cargs, sv[1])
    close(sv[1])
    guard d.pid > 0 else { log("spawn failed \(d.pid)"); exit(1) }
    d.link = Link(fd: sv[0], queue: .main, onMessage: { d.event($0) },
                  onEOF: { log("NOTICED device \(i) link EOF") })
    let w = DispatchSource.makeProcessSource(identifier: d.pid, eventMask: .exit, queue: .main)
    w.setEventHandler {
        var st: Int32 = 0
        waitpid(d.pid, &st, 0)
        log("NOTICED device \(i) exit (process source), wait status \(st)")
        d.exited = true
        w.cancel()
    }
    w.resume()
    d.exitWatch = w
    devices.append(d)
    log("spawned device \(i) pid \(d.pid): \(spec)")
}
print("HOST_READY pid=\(getpid()) service=\(service)")
fflush(stdout)

Thread.detachNewThread {
    while true {
        for d in devices { d.poll() }
        usleep(pollUs)
    }
}

func finish() {
    let wall = Date().timeIntervalSince(started)
    let result: [String: Any] = ["hostCpuSeconds": cpuSeconds() - cpu0, "wall": wall, "pollUs": pollUs,
                                 "devices": devices.map { $0.summary() }]
    let json = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
    print("HOST_RESULT " + String(decoding: json, as: UTF8.self))
    fflush(stdout)
    exit(0)
}

var quitting = false
Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
    if !devices.isEmpty, devices.allSatisfy(\.exited) { finish() }
    if Date().timeIntervalSince(started) > maxSeconds, !quitting {
        quitting = true
        log("time up: asking devices to quit")
        for d in devices where !d.exited {
            d.link?.send(["op": "quit"])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { finish() }
    }
}
RunLoop.main.run()
