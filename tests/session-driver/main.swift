// Stands in for the app in tests/check-sessions.py: two devices at once, each in
// its own LightTouchDevice helper through the app's own DeviceProcess and
// BootRecipe (DeviceSession.swift), each with its own usbmuxd (USBMux's flags),
// and every libimobiledevice call through the app's DeviceServices and its one
// DeviceGate. JSON lines on stdout.
//
//   session-driver CONFIG.json
//
// config: {helper, requirement, usbmuxd, ipa, bundleID, work, files, ipodNAND, ipadBase, ipadItpack?, guest?, single?, activation?}
// With `guest` it runs the guest-services scenario instead (guest.swift); with `single`, one prepared
// device (single.swift). `frameworks` is where libimobiledevice is loaded from (default Homebrew's).
// `ipadItpack` boots the iPad with the app's composed offer and checks the loader and the agent.

import Foundation
import IOSurface

struct Config: Decodable {
    var helper: String, requirement: String, usbmuxd: String, ipa: String, bundleID: String
    var work: String, files: String, ipodNAND: String, ipadBase: String
    /// The app's armv7.itpack: the iPad boots with the offer EmulatorController composes from it.
    var ipadItpack: String?
    var guest: GuestConfig?
    var single: SingleConfig?
    /// One base's activation question (activation.swift).
    var activation: ActivationConfig?
    /// A base that never starts iOS (deadline.swift).
    var deadline: DeadlineConfig?
    var frameworks: String?
}

let t0 = Date()
nonisolated func emit(_ event: String, _ fields: [String: Any] = [:]) {
    var object = fields
    object["event"] = event
    object["t"] = (Date().timeIntervalSince(t0) * 10).rounded() / 10
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}
nonisolated func logEvent(_ message: String, _ arguments: CVarArg...) { emit("log", ["message": message]) }
func fail(_ why: String) -> Never { emit("fail", ["why": why]); exit(1) }

// App stubs the compiled sources reference.
nonisolated enum Bundled {
    static var frameworksDirectory: String? { config.frameworks ?? "/opt/homebrew/lib" }
    static var logsDirectory: URL { URL(fileURLWithPath: config.work) }
}
struct InstalledApp: Sendable { let id, name, version: String }
struct MediaVideo: Sendable { let id: String; let video: URL }
struct MediaSong: Sendable { let id: String; let audio: URL; static let extensions: Set<String> = ["m4a"] }

nonisolated(unsafe) let config = try! JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let work = URL(fileURLWithPath: config.work)

// MARK: - usbmuxd, as USBMux starts it

final class Mux {
    let clientSocket: String, guestAddress: String
    let process = Process()
    init(name: String) throws {
        func freePort() -> Int {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                   sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
            _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
            return Int(UInt16(bigEndian: addr.sin_port))
        }
        clientSocket = "127.0.0.1:\(freePort())"
        guestAddress = "127.0.0.1:\(freePort())"
        let conf = work.appendingPathComponent("\(name)/usbmuxd-conf")
        try FileManager.default.createDirectory(at: conf, withIntermediateDirectories: true)
        process.executableURL = URL(fileURLWithPath: config.usbmuxd)
        process.arguments = ["-f", "-v", "-S", clientSocket, "-P", "NONE", "-C", conf.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["USBMUXD_QEMU_ADDR": guestAddress, "USBMUXD_QEMU_DELAY": "0"]) { $1 }
        let log = FileHandle(forWritingAtPath: work.appendingPathComponent("\(name)/usbmuxd.log").path)
            ?? { FileManager.default.createFile(atPath: work.appendingPathComponent("\(name)/usbmuxd.log").path, contents: nil)
                 return FileHandle(forWritingAtPath: work.appendingPathComponent("\(name)/usbmuxd.log").path)! }()
        log.seekToEndOfFile()
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        try process.run()
        try "\(process.processIdentifier)\n".appendLine(to: work.appendingPathComponent("pids"))
        emit("usbmuxd", ["device": name, "pid": process.processIdentifier, "client": clientSocket, "guest": guestAddress])
    }
    func stop() { process.terminate(); process.waitUntilExit() }
}

extension String {
    func appendLine(to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try FileHandle(forWritingTo: url); h.seekToEndOfFile(); h.write(Data(utf8)); try h.close()
    }
}

// MARK: - One device

@MainActor final class Device {
    let name: String
    let profile: DeviceProfile
    var process: DeviceProcess!
    var mux: Mux!
    var serial: SerialLogCapture?
    /// The app's serial watch (EmulatorController.openSerialLog): phrases and what to do on the first sight.
    var serialWatch: (phrases: [String], onMatch: @Sendable (String) -> Void)?
    var deaths: [String] = []
    /// An iPod's own files (a device.py device); nil: the shipping image in `files`.
    struct IPodFiles { var nand, nor, iBoot: String; var gidBlobs: String?; var machine: [String: String] = [:] }
    var ipod: IPodFiles?
    init(name: String, profile: DeviceProfile) { self.name = name; self.profile = profile }
    var dir: URL { work.appendingPathComponent(name) }

    /// What EmulatorController.start + iPodBoot/iPadBoot do, with test paths and no audio.
    func boot(generation: Int, guestPackage: String? = nil) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        mux = try Mux(name: name)
        serial = try SerialLogCapture(url: dir.appendingPathComponent("serial.log"), temporaryRoot: work,
                                      watch: serialWatch?.phrases ?? [], onMatch: serialWatch?.onMatch ?? { _ in })
        let overlay = dir.appendingPathComponent("overlay")
        let config: BootConfig
        if profile == .iPad1 {
            // As EmulatorController.iPadBoot: a base with nor.bin (4.x's effaceable storage) boots a private copy.
            let base = URL(fileURLWithPath: Self.ipadBase)
            let nor = FileManager.default.fileExists(atPath: base.appendingPathComponent("nor.bin").path) ? dir.appendingPathComponent("nor.bin") : nil
            let files = try BootRecipe.preparedFiles(base: base, overlay: overlay, writableNOR: nor)
            let identity = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: Self.ipadBase + "/identity.json"))) as! [String: Any]
            let dieID = (identity["die-id"] as? [String])?.joined(separator: ":")
            config = BootRecipe.iPad(.init(kboot: files.boot.path, nand: files.nand.path, overlay: overlay.path, dieID: dieID,
                                           writableNOR: files.writableNOR?.path, usbAddress: mux.guestAddress, wifi: true,
                                           guestPackage: try iPadOffer(base: base),
                                           machineOptions: BootRecipe.lockMachine(base.appendingPathComponent("device.lock.json"))),
                                     serial: serial!.argument, audio: ["-audio", "driver=none"], netdev: nil, restore: [])
        } else {
            let files = ipod ?? IPodFiles(nand: Self.ipodNAND, nor: Self.files + "/ios3/nor_7E18.bin", iBoot: Self.files + "/ios3/iBoot.bin")
            let nor = try DeviceStateStorage.writableNOR(base: URL(fileURLWithPath: files.nor), overlay: overlay)
            config = BootRecipe.iPod(.init(bootArgs: "amfi_allow_any_signature=1 cs_enforcement_disable=1",
                                           iBoot: files.iBoot, bootrom: Self.files + "/bootrom_240_4",
                                           nand: files.nand, nor: files.nor, writableNOR: nor.path,
                                           overlay: overlay.path, usbAddress: mux.guestAddress, wifi: true,
                                           gidBlobs: files.gidBlobs, guestPackage: guestPackage, machineOptions: files.machine),
                                     serial: serial!.argument, audio: ["-audio", "driver=none"], netdev: "user,id=wifi0", restore: [])
        }
        let process = DeviceProcess(instance: UUID(), profile: profile, log: dir.appendingPathComponent("native.log"),
                                    lease: dir.appendingPathComponent("work/lease"), helper: URL(fileURLWithPath: Self.helper), requirement: Self.requirement)
        self.process = process
        process.onDeath = { [weak self] reason in
            self?.deaths.append(reason)
            emit("death", ["device": self?.name ?? "?", "reason": reason, "generation": generation])
        }
        let started = Date()
        process.start({ info in
            emit("hello", ["device": self.name, "pid": info.pid, "dylib": info.dylibPath, "build": info.buildID ?? "",
                           "width": info.deviceInfo?.screenWidth ?? 0, "height": info.deviceInfo?.screenHeight ?? 0])
            return config
        }) { result in
            switch result {
            case .success: emit("booted", ["device": self.name, "pid": process.link.pid, "seconds": Date().timeIntervalSince(started), "generation": generation])
            case let .failure(error): emit("bootFailed", ["device": self.name, "error": "\(error)"])
            }
        }
    }
    /// EmulatorController.composeGuestOffer for a prepared iPad: the bundled itpack, the base's lock record.
    func iPadOffer(base: URL) throws -> String? {
        guard let itpack = config.ipadItpack else { return nil }
        let lockURL = base.appendingPathComponent("device.lock.json")
        let lock = try JSONSerialization.jsonObject(with: Data(contentsOf: lockURL)) as? [String: Any]
        let dir = dir.appendingPathComponent("work/guest-offer")
        try FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        let offer = try GuestPackage.compose(itpack: URL(fileURLWithPath: itpack), board: "k48ap", build: lock?["build"] as? String ?? "",
                                             lock: GuestPackage.lockRecord(lockURL), guest: nil, into: dir)
        emit("offer", ["device": name, "serial": offer?.serial ?? -1, "seed": GuestPackage.lockRecord(lockURL)?.seed ?? -1])
        return offer == nil ? nil : dir.path
    }

    static var helper: String { config.helper }
    static var requirement: String { config.requirement }
    static var files: String { config.files }
    static var ipodNAND: String { config.ipodNAND }
    static var ipadBase: String { config.ipadBase }

    var services: DeviceServices { DeviceServices(clientSocket: mux.clientSocket) }

    func brightness() -> Double? { process.link.frontSurface().map { FrameTools.brightness($0.surface) } }
    /// A screenshot as DisplayView takes one: the newest ring surface under a use count.
    @discardableResult
    func screenshot(_ label: String) -> String? {
        guard let frame = process.link.frontSurface() else { return nil }
        let url = dir.appendingPathComponent("\(label).png")
        guard FrameTools.writePNG(frame.surface, to: url) else { return nil }
        emit("screenshot", ["device": name, "path": url.path, "serial": frame.serial,
                            "width": frame.surface.width, "height": frame.surface.height, "brightness": FrameTools.brightness(frame.surface)])
        return url.path
    }

    func drag(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) async {
        let link = process.link
        link.send(.touch(slot: 0, phase: 0, x: x0, y: y0)); try? await Task.sleep(for: .milliseconds(150))
        for i in 1...30 {
            let f = Double(i) / 30
            link.send(.touch(slot: 0, phase: 1, x: x0 + (x1 - x0) * f, y: y0 + (y1 - y0) * f))
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .milliseconds(300))
        link.send(.touch(slot: 0, phase: 2, x: x1, y: y1))
    }

    /// lockdown's ProductType through this device's socket, under the gate.
    func productType() async -> String? {
        try? await services.run(Timeouts.query, "product type") { imd, device in
            guard let newClient = imd.lockdownd_client_new_with_handshake, let getValue = imd.lockdownd_get_value,
                  let plistFree = imd.plist_free else { throw DeviceError.unavailable }
            var client: OpaquePointer?
            let rc = newClient(device, &client, "LightTouchMac")
            guard rc == imd.success, let client else { throw DeviceError.lockdown(rc) }
            defer { _ = imd.lockdownd_client_free?(client) }
            var value: OpaquePointer?
            let vr = "ProductType".withCString { getValue(client, nil, $0, &value) }
            guard vr == imd.success, let value else { throw DeviceError.lockdown(vr) }
            defer { plistFree(value) }
            return IMobileDevice.decode(value) as? String
        }
    }
}

@MainActor func waitLit(_ d: Device, _ threshold: Double, _ seconds: Double) async {
    let start = Date()
    while true {
        if d.process.isDead { fail("\(d.name) died before it lit: \(d.deaths)") }
        if let b = d.brightness(), b >= threshold {
            emit("lit", ["device": d.name, "seconds": Date().timeIntervalSince(start), "brightness": b])
            return
        }
        if Date().timeIntervalSince(start) > seconds { d.screenshot("never-lit"); fail("\(d.name) never lit") }
        try? await Task.sleep(for: .milliseconds(250))
    }
}

@MainActor func waitUSB(_ d: Device, expecting product: String, _ seconds: Double) async {
    let start = Date()
    while Date().timeIntervalSince(start) < seconds {
        if let type = await d.productType() {
            emit("usb", ["device": d.name, "productType": type, "seconds": Date().timeIntervalSince(start)])
            if type != product { fail("\(d.name)'s usbmuxd answered as \(type), expected \(product): cross-device") }
            return
        }
        try? await Task.sleep(for: .seconds(2))
    }
    fail("\(d.name): lockdown never answered over its usbmuxd")
}

@MainActor func install(_ d: Device) async {
    let start = Date()
    var lastError = ""
    for attempt in 1...6 {
        do {
            let staged = try await d.services.stage(URL(fileURLWithPath: config.ipa)) { _ in }
            try await d.services.install(stagedPath: staged) { _, _ in }
            let apps = try await d.services.installedApps()
            emit("installed", ["device": d.name, "attempt": attempt, "seconds": Date().timeIntervalSince(start),
                               "apps": apps.map(\.id), "has": apps.contains { $0.id == config.bundleID }])
            return
        } catch {
            lastError = error.localizedDescription
            emit("installRetry", ["device": d.name, "attempt": attempt, "error": lastError])
            try? await Task.sleep(for: .seconds(10))
        }
    }
    fail("\(d.name): install failed: \(lastError)")
}

/// With an offer: the loader's report, then the agent through the app's GuestServices (the window
/// title's foreground app, the sidebar's launch) and the lock state.
@MainActor func iPadGuest(_ d: Device) async {
    let start = Date()
    while d.process.status?.guestPackage == nil, Date().timeIntervalSince(start) < 60 { try? await Task.sleep(for: .seconds(1)) }
    let report = d.process.status?.guestPackage
    emit("ipadReport", ["serial": report?.serial ?? -1, "result": report?.result ?? -99])
    let agent = GuestAgent(link: d.process.link, cache: GuestAgentCache())
    let alive = await agent.waitAlive(seconds: 60)
    let guest = GuestServices(agent: agent, packaged: report != nil)
    let home = try? await guest.foregroundAppName()
    let locked = try? await agent.isLocked()
    var launched: String?
    do { try await guest.launch("com.apple.mobilesafari") } catch { emit("ipadLaunchError", ["error": "\(error)"]) }
    for _ in 0..<20 where launched != "Safari" {
        try? await Task.sleep(for: .seconds(1))
        launched = try? await guest.foregroundAppName()
    }
    d.screenshot("ipad-launched")
    emit("ipadAgent", ["alive": alive, "home": home ?? "", "locked": locked.map { $0 ? 1 : 0 } ?? -1, "launched": launched ?? ""])
}

// MARK: - Prepared first-boot files, on a fake base

func checkPreparedFiles() throws {
    let fm = FileManager.default
    let base = work.appendingPathComponent("fake-base"), state = work.appendingPathComponent("fake-state")
    try fm.createDirectory(at: base.appendingPathComponent("nand"), withIntermediateDirectories: true)
    try Data("kboot".utf8).write(to: base.appendingPathComponent("kboot.bin"))
    let nor = Data((0..<1_048_576).map { UInt8($0 % 251) })
    try nor.write(to: base.appendingPathComponent("nor.bin"))
    for path in ["kboot.bin", "nor.bin", "nand", ""] {
        try fm.setAttributes([.posixPermissions: path == "nand" || path == "" ? 0o555 : 0o444], ofItemAtPath: base.appendingPathComponent(path).path)
    }
    let listing = { try fm.subpathsOfDirectory(atPath: base.path).sorted() }
    let before = try listing()
    let overlay = state.appendingPathComponent("overlay"), clone = state.appendingPathComponent("nor.bin")
    let files = try BootRecipe.preparedFiles(base: base, overlay: overlay, writableNOR: clone)
    let cloneMatches = try Data(contentsOf: clone) == nor
    let mode = (try fm.attributesOfItem(atPath: clone.path)[.posixPermissions] as! NSNumber).intValue
    let stamp = try fm.attributesOfItem(atPath: clone.path)[.modificationDate] as! Date
    try Data("guest write".utf8).write(to: clone, options: [])   // owner-writable, as QEMU needs
    _ = try BootRecipe.preparedFiles(base: base, overlay: overlay, writableNOR: clone)
    let kept = try Data(contentsOf: clone) == Data("guest write".utf8)
    var missingThrows = false
    do { _ = try BootRecipe.preparedFiles(base: state, overlay: overlay, writableNOR: nil) } catch { missingThrows = true }
    emit("preparedFiles", ["kboot": files.boot.path == base.appendingPathComponent("kboot.bin").path,
                           "nand": files.nand.path == base.appendingPathComponent("nand").path,
                           "overlay": fm.fileExists(atPath: overlay.path), "cloneMode": mode, "cloneMatches": cloneMatches,
                           "secondBootKeeps": kept, "stamp": stamp.timeIntervalSince1970, "missingThrows": missingThrows,
                           "baseUntouched": try listing() == before && (try Data(contentsOf: base.appendingPathComponent("nor.bin"))) == nor])
}

// MARK: - Scenario

@MainActor func run() async {
    do { try checkPreparedFiles() } catch { fail("prepared files: \(error)") }
    let ipod = Device(name: "ipod", profile: .iPodTouch2G), ipad = Device(name: "ipad", profile: .iPad1)
    do { try ipod.boot(generation: 1); try ipad.boot(generation: 1) } catch { fail("boot: \(error)") }
    async let a: Void = waitLit(ipod, 0.03, 240)
    async let b: Void = waitLit(ipad, 0.2, 240)
    _ = await (a, b)
    // Both helpers are live at once, and distinct.
    emit("concurrent", ["ipodPID": ipod.process.link.pid, "ipadPID": ipad.process.link.pid,
                        "ipodHeartbeat": ipod.process.status?.heartbeat ?? 0, "ipadHeartbeat": ipad.process.status?.heartbeat ?? 0])
    // USB first: lockdown answering means SpringBoard is up (a lit boot logo doesn't).
    // Each socket must reach its own device.
    async let s1: Void = waitUSB(ipod, expecting: "iPod2,1", 240)
    async let s2: Void = waitUSB(ipad, expecting: "iPad1,1", 240)
    _ = await (s1, s2)
    // Wake the iPod (its display may have slept while it booted), then input to each:
    // the lock screen sliders (tests/check-helper-boot.py).
    ipod.process.link.send(.button(0, down: true)); try? await Task.sleep(for: .milliseconds(150))
    ipod.process.link.send(.button(0, down: false))
    try? await Task.sleep(for: .seconds(3))
    ipod.screenshot("ipod-lock"); ipad.screenshot("ipad-lock")
    async let u1: Void = ipod.drag(0.18, 0.9, 0.92, 0.9)
    async let u2: Void = ipad.drag(0.9365, 0.621, 0.9365, 0.0612)
    _ = await (u1, u2)
    try? await Task.sleep(for: .seconds(5))
    ipod.screenshot("ipod-home"); ipad.screenshot("ipad-home")

    // One IPA into each at once: the gate serializes them and points each at its own daemon.
    async let i1: Void = install(ipod)
    async let i2: Void = install(ipad)
    _ = await (i1, i2)
    ipod.screenshot("ipod-installed"); ipad.screenshot("ipad-installed")
    if config.ipadItpack != nil { await iPadGuest(ipad) }

    // kill -9 the iPad's helper: it dies, the iPod doesn't notice.
    let killedPID = ipad.process.link.pid
    let beat0 = ipod.process.status?.heartbeat ?? 0, frames0 = ipod.process.status?.frameSerial ?? 0
    kill(killedPID, SIGKILL)
    let killed = Date()
    while !ipad.process.isDead, Date().timeIntervalSince(killed) < 5 { try? await Task.sleep(for: .milliseconds(10)) }
    emit("killed", ["device": "ipad", "pid": killedPID, "noticed": ipad.process.isDead,
                    "seconds": Date().timeIntervalSince(killed), "reason": ipad.process.deathReason ?? ""])
    ipod.process.link.send(.button(0, down: true)); try? await Task.sleep(for: .milliseconds(150))
    ipod.process.link.send(.button(0, down: false))
    try? await Task.sleep(for: .seconds(3))
    let ipodType = await ipod.productType()
    emit("survivor", ["device": "ipod", "dead": ipod.process.isDead,
                      "heartbeat": (ipod.process.status?.heartbeat ?? 0) - beat0,
                      "frames": (ipod.process.status?.frameSerial ?? 0) - frames0, "productType": ipodType ?? ""])
    ipod.screenshot("ipod-after-kill")

    // Restart: as DeviceSessionHost.restart, a fresh helper (and usbmuxd) on the same overlay.
    ipad.mux.stop()
    ipad.serial?.removeEndpoints()
    do { try ipad.boot(generation: 2) } catch { fail("restart: \(error)") }
    await waitLit(ipad, 0.2, 240)
    try? await Task.sleep(for: .seconds(3))
    ipad.screenshot("ipad-restarted")
    await waitUSB(ipad, expecting: "iPad1,1", 240)
    let apps = (try? await ipad.services.installedApps())?.map(\.id) ?? []
    emit("restartedApps", ["device": "ipad", "has": apps.contains(config.bundleID)])

    // Stop both at once, as EmulatorController.halt does: SIGTERM, and the helper
    // pauses (storage flushed) and quits QEMU without asking the guest.
    let quit = Date()
    ipod.process.terminate(); ipad.process.terminate()
    let exited0 = await ipod.process.waitForExit(timeout: 10), exited1 = await ipad.process.waitForExit(timeout: 10)
    emit("quit", ["ipodExited": exited0, "ipadExited": exited1, "seconds": Date().timeIntervalSince(quit),
                  "ipodReason": ipod.process.deathReason ?? "", "ipadReason": ipad.process.deathReason ?? ""])
    ipod.mux.stop(); ipad.mux.stop()
    ipod.serial?.finish(); ipad.serial?.finish()
    emit("done")
    exit(0)
}

Task { @MainActor in
    if let guest = config.guest { await runGuest(guest) } else if let single = config.single { await runSingle(single) }
    else if let activation = config.activation { await runActivation(activation) }
    else if let deadline = config.deadline { await runDeadline(deadline) } else { await run() }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 560) { fail("driver timed out") }
CFRunLoopRun()
