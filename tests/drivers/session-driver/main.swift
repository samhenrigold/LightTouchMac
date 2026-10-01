import HostRuntime
// Stands in for the app in tests/sessions/check-sessions.py: two devices at once, each in
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
    var helper: String, usbmuxd: String, ipa: String, bundleID: String
    var requirement: String?
    var work: String, files: String, ipodNAND: String, ipadBase: String
    /// The app's armv7.itpack: the iPad boots with the offer EmulatorController composes from it.
    var ipadItpack: String?
    var guest: GuestConfig?
    var single: SingleConfig?
    /// One base's activation question (activation.swift).
    var activation: ActivationConfig?
    /// A base that never starts iOS (deadline.swift).
    var deadline: DeadlineConfig?
    /// The web proxy's certificate trusted through the guest agent, no profile screen (proxy.swift).
    var proxy: ProxyConfig?
    var frameworks: String?
    /// The driver's own deadline in seconds (default 560; tests/matrix.py's second boot needs more).
    var timeout: Double?
    /// Hello/lease followed by a preparation error; never sends a boot request.
    var preparationFailure: Bool?
    /// Actual helper lease admission/refusal at hello; never sends a boot request.
    var leaseAdmission: Bool?
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
/// Devices whose serial log must reach disk before a failing exit (the capture flushes on finish).
@MainActor var liveDevices: [Device] = []
func fail(_ why: String) -> Never {
    emit("fail", ["why": why])
    MainActor.assumeIsolated { for d in liveDevices { d.process?.kill(); d.serial?.finish() } }
    exit(1)
}

// App stubs the compiled sources reference.
nonisolated enum Bundled {
    static var frameworksDirectory: String? { config.frameworks ?? "/opt/homebrew/lib" }
    static var logsDirectory: URL { URL(fileURLWithPath: config.work) }
    static var stateDirectory: URL { URL(fileURLWithPath: config.work) }
    static var workDirectory: URL { URL(fileURLWithPath: config.work) }
    static func tool(_ name: String) -> String? { nil }
    static func resolve(_ name: String, fallbacks: [String]) -> String? { nil }
    static var binarySearchPaths: [String] { [] }
}
extension DeviceInstance { var paths: Paths { paths(state: Bundled.stateDirectory, logs: Bundled.logsDirectory) } }
struct MediaVideo: Sendable { let id: String; let video: URL }
struct MediaSong: Sendable { let id: String; let audio: URL; var artwork: URL? = nil; static let extensions: Set<String> = ["m4a"] }

// --selftest-walk: the Setup walk's retry core (Setup5.tapUntil) against fake taps, no emulator
// (tests/sessions/check-setup-walk.py).
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--selftest-walk" {
    Task { @MainActor in exit(await Setup5.selfTest() ? 0 : 1) }
    CFRunLoopRun()
}
nonisolated(unsafe) let config = try! JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
// Standalone matrix callers pass resource paths in config, while the app gets
// them from its bundle. Forward the fixed library directory to owned children.
setenv("LTM_SERVICE_FRAMEWORKS", config.frameworks ?? "/opt/homebrew/lib", 1)
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
    private var serviceSession = UUID()
    var serial: SerialLogCapture?
    /// The app's serial watch (EmulatorController.openSerialLog): phrases and what to do on the first sight.
    var serialWatch: (phrases: [String], onMatch: @Sendable (String) -> Void)?
    var deaths: [String] = []
    private(set) var preparationError: String?
    private(set) var bootError: String?
    private(set) var helloPID: pid_t?
    /// An iPod's own files (a device.py device); nil: the shipping image in `files`.
    struct IPodFiles { var nand, nor, iBoot: String; var gidBlobs: String?; var machine: [String: String] = [:] }
    var ipod: IPodFiles?
    /// Prepared bases use typed runtime strategy validation; raw historical fixtures use legacyN72.
    var preparedBase: URL?
    /// EmulatorController.proxyForward's guestfwd, appended to the wifi netdev, and the proxy the helper serves (proxy.swift).
    var netdevExtra: String?
    var webProxy: WebProxyEndpoint?
    init(name: String, profile: DeviceProfile) { self.name = name; self.profile = profile }
    var dir: URL { work.appendingPathComponent(name) }

    /// The same runtime boot preparation as the GUI, with explicit test paths and no audio.
    func boot(generation: Int, guestPackage: String? = nil) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        serviceSession = UUID()
        preparationError = nil
        bootError = nil
        helloPID = nil
        mux = try Mux(name: name)
        serial = try SerialLogCapture(url: dir.appendingPathComponent("serial.log"), temporaryRoot: work,
                                      watch: serialWatch?.phrases ?? [], onMatch: serialWatch?.onMatch ?? { _ in })
        // Preparation runs after hello, when the helper owns the storage lease.
        func configuration() throws -> BootConfig {
            let overlay = dir.appendingPathComponent("overlay")
            let prepared: PreparedDeviceBoot
            var offer = guestPackage
            if profile == .iPad1 || profile == .iPodTouch1G {
                let base = profile == .iPad1 ? URL(fileURLWithPath: Self.ipadBase)
                    : URL(fileURLWithPath: ipod!.nand).deletingLastPathComponent()
                let nor = profile == .iPodTouch1G || FileManager.default.fileExists(atPath: base.appendingPathComponent("nor.bin").path)
                    ? dir.appendingPathComponent("nor.bin") : nil
                prepared = try PreparedDeviceBoot.prepare(board: profile == .iPad1 ? .k48 : .n45,
                    base: base, overlay: overlay, writableNOR: nor, storageKey: nil,
                    bootrom: BootRecipe.bootrom(profile.bootromName, filesRoot: Self.files))
                if profile == .iPad1 { offer = try iPadOffer(base: base) }
            } else if let base = preparedBase {
                prepared = try PreparedDeviceBoot.prepare(board: .n72, base: base, overlay: overlay,
                    writableNOR: dir.appendingPathComponent("nor.bin"), storageKey: nil,
                    bootrom: BootRecipe.bootrom(profile.bootromName, filesRoot: Self.files))
            } else {
                let files = ipod ?? IPodFiles(nand: Self.ipodNAND, nor: Self.files + "/ios3/nor_7E18.bin", iBoot: Self.files + "/ios3/iBoot.bin")
                prepared = try PreparedDeviceBoot.legacyN72(nand: URL(fileURLWithPath: files.nand),
                    nor: URL(fileURLWithPath: files.nor), iBoot: files.iBoot, gidBlobs: files.gidBlobs,
                    machine: files.machine, overlay: overlay, bootrom: Self.files + "/bootrom_240_4")
            }
            let netdev = profile == .iPad1 ? netdevExtra.map { "user,id=wifi0" + $0 }
                : "user,id=wifi0" + (netdevExtra ?? "")
            return try prepared.configuration(bootArgs: "amfi_allow_any_signature=1 cs_enforcement_disable=1",
                usbAddress: mux.guestAddress, wifi: true, guestPackage: offer, serial: serial!.argument,
                audio: ["-audio", "driver=none"], netdev: netdev, webProxy: webProxy)
        }
        let process = DeviceProcess(instance: UUID(), profile: profile, log: dir.appendingPathComponent("native.log"),
                                    lease: dir.appendingPathComponent("work/lease"), helper: URL(fileURLWithPath: Self.helper), requirement: Self.requirement)
        self.process = process
        process.onDeath = { [weak self] reason in
            self?.deaths.append(reason)
            emit("death", ["device": self?.name ?? "?", "reason": reason, "generation": generation])
        }
        if !liveDevices.contains(where: { $0 === self }) { liveDevices.append(self) }
        let started = Date()
        process.start({ info in
            self.helloPID = info.pid
            emit("hello", ["device": self.name, "pid": info.pid, "dylib": info.dylibPath, "build": info.buildID ?? "",
                           "width": info.deviceInfo?.screenWidth ?? 0, "height": info.deviceInfo?.screenHeight ?? 0])
            do { return try configuration() }
            catch {
                self.preparationError = "\(error)"
                emit("configurationFailed", ["device": self.name, "error": self.preparationError!])
                return nil
            }
        }) { result in
            switch result {
            case .success: emit("booted", ["device": self.name, "pid": process.link.pid, "seconds": Date().timeIntervalSince(started), "generation": generation])
            case let .failure(error):
                self.bootError = self.preparationError ?? "\(error)"
                emit("bootFailed", ["device": self.name, "error": self.bootError!])
            }
        }
    }
    /// EmulatorController.composeGuestOffer for a prepared iPad: the bundled itpack, the base's lock record.
    func iPadOffer(base: URL) throws -> String? {
        guard let itpack = config.ipadItpack else { return nil }
        return try offer(base: base, board: "k48ap", itpack: itpack)
    }

    /// EmulatorController.composeGuestOffer for any prepared base: the itpack, the base's lock record.
    func offer(base: URL, board: String, itpack: String) throws -> String? {
        let lockURL = base.appendingPathComponent("device.lock.json")
        let lock = try JSONSerialization.jsonObject(with: Data(contentsOf: lockURL)) as? [String: Any]
        let dir = dir.appendingPathComponent("work/guest-offer")
        try FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        let offer = try GuestPackage.compose(itpack: URL(fileURLWithPath: itpack), board: board, build: lock?["build"] as? String ?? "",
                                             lock: GuestPackage.lockRecord(lockURL), guest: nil, into: dir)
        emit("offer", ["device": name, "serial": offer?.serial ?? -1, "seed": GuestPackage.lockRecord(lockURL)?.seed ?? -1])
        return offer == nil ? nil : dir.path
    }

    static var helper: String { config.helper }
    static var requirement: String? { config.requirement }
    static var files: String { config.files }
    static var ipodNAND: String { config.ipodNAND }
    static var ipadBase: String { config.ipadBase }

    var services: DeviceServices { DeviceServices(clientSocket: mux.clientSocket, session: serviceSession) }

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

    /// Wake the panel, then capture. The display sleeps ~12 s after `lit`, so an unqualified
    /// screenshot lands on a black panel (audit finding 3). Press Home, re-check brightness, and
    /// capture only once it is lit -- or capture the black frame after the last try, so the matrix
    /// fails the row honestly rather than passing a slept panel.
    @discardableResult
    func wakeForShot(_ label: String, floor: Double = 0.05, tries: Int = 5) async -> String? {
        for _ in 0..<tries {
            if (brightness() ?? 0) >= floor { break }
            process.link.send(.button(0, down: true)); try? await Task.sleep(for: .milliseconds(150))
            process.link.send(.button(0, down: false))
            try? await Task.sleep(for: .seconds(2))
        }
        return screenshot(label)
    }

    /// Slide to unlock, again while the guest agent (where the boot has one) says it is still locked: a slide can
    /// miss (4.2.1's iPod, rejudge 09-29; 4.2.1's iPad first boot under host load, smoke #66), and the lock screen
    /// sleeps a few seconds after a miss, so each retry wakes the panel first (`unlockN-M.png`). Emits `unlock`.
    func slideToUnlock(_ generation: Int, agent: GuestAgent?) async {
        var attempts = 0, locked: Bool?
        for attempt in 0..<3 {
            if attempt > 0 { await wakeForShot("unlock\(generation)-\(attempt)") }
            if profile == .iPad1 { await drag(0.9365, 0.621, 0.9365, 0.0612) } else { await drag(0.18, 0.9, 0.92, 0.9) }
            attempts += 1
            try? await Task.sleep(for: .seconds(5))
            locked = try? await agent?.isLocked()
            guard locked == true else { break }
        }
        emit("unlock", ["device": name, "generation": generation, "attempts": attempts, "locked": locked.map { $0 ? 1 : 0 } ?? -1])
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

    /// A short tap (a drag holds long enough to start SpringBoard's icon editing).
    func tap(_ x: Double, _ y: Double) async {
        process.link.send(.touch(slot: 0, phase: 0, x: x, y: y)); try? await Task.sleep(for: .milliseconds(80))
        process.link.send(.touch(slot: 0, phase: 2, x: x, y: y))
    }

    /// lockdown's ProductType through this device's socket, under the gate.
    func productType() async -> String? { await lockdownValue("ProductType") }

    /// One lockdown value (a string) through this device's socket, under the gate.
    func lockdownValue(_ key: String) async -> String? {
        try? await services.lockdownValue(key)
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

/// The installed app, opened from the Home screen: moved into page 1's first slot through SpringBoardServices (the
/// Apps inspector's reorder), then tapped there (iPhone OS 2.x/3.x 320x480 grid: slot 0 centred at 47,62). With
/// `point` (2.x: no springboardservices) the icon is tapped where the caller says it is. The first install's
/// "Edit Home Screen" tip is dismissed first (its button sits in a gap between icons when there is no tip).
@MainActor func launch(_ d: Device, at point: [Double]? = nil, tap: [Double]? = nil) async {
    var event: [String: Any] = ["device": d.name, "bundleID": config.bundleID]
    // Where it_agent answers, launch as the app does (GuestAgent.launch) and ask it what is frontmost: the
    // tap below assumes the iPhone 320x480 grid, which misses on the iPad's home screen.
    let agent = GuestAgent(link: d.process.link, cache: GuestAgentCache())
    if await agent.waitAlive(seconds: 20) {
        event["via"] = "agent"
        do { try await agent.launch(config.bundleID) } catch { event["launchError"] = "\(error)" }
        for (i, wait) in [8, 12, 20].enumerated() {
            try? await Task.sleep(for: .seconds(wait))
            if let path = d.screenshot("launched\(i + 1)") { event["shot\(i + 1)"] = path }
            if let f = try? await agent.frontmost() { event["frontmost\(i + 1)"] = f.bundleID }
        }
        if let tap, tap.count >= 2 {   // a row of the launched app (Harness: "GL: rotating triangle"), two frames apart
            await d.tap(tap[0], tap[1])
            try? await Task.sleep(for: .seconds(8))
            if let path = d.screenshot("gl1") { event["gl1"] = path }
            try? await Task.sleep(for: .seconds(5))
            if let path = d.screenshot("gl2") { event["gl2"] = path }
        }
        emit("launched", event)
        return
    }
    var target = (47.0 / 320, 62.0 / 480)
    try? await Task.sleep(for: .seconds(3))
    d.screenshot("tip")
    await d.tap(0.5, 330.0 / 480)
    try? await Task.sleep(for: .seconds(2))
    if let point, point.count >= 2 {   // [x, y, page]: page 1+ is a swipe left per page
        target = (point[0], point[1])
        event["at"] = point
        for _ in 0..<Int(point.count > 2 ? point[2] : 0) {
            await d.drag(0.85, 0.45, 0.15, 0.45)
            try? await Task.sleep(for: .seconds(2))
        }
    } else {
        do {
            let order = try await d.services.homeScreenOrder()
            event["slot"] = order.firstIndex(of: config.bundleID) ?? -1
            if let first = order.first, first != config.bundleID {
                let moved = try await d.services.moveOnHomeScreen(config.bundleID, before: first, profile: d.profile)
                event["movedTo"] = moved.firstIndex(of: config.bundleID) ?? -1
            }
        } catch { event["reorderError"] = "\(error)" }
    }
    try? await Task.sleep(for: .seconds(3))
    d.screenshot("prelaunch")
    await d.tap(target.0, target.1)
    for (i, wait) in [8, 12, 20].enumerated() {
        try? await Task.sleep(for: .seconds(wait))
        if let path = d.screenshot("launched\(i + 1)") { event["shot\(i + 1)"] = path }
    }
    if let tap, tap.count >= 2 {   // single.swift tapAfterLaunch (normalized portrait on the iPod)
        await d.tap(tap[0], tap[1])
        for i in 1...2 {
            try? await Task.sleep(for: .seconds(3))
            if let path = d.screenshot("tapped\(i)") { event["tapped\(i)"] = path }
        }
    }
    emit("launched", event)
    d.process.link.send(.button(0, down: true)); try? await Task.sleep(for: .milliseconds(150))
    d.process.link.send(.button(0, down: false))
    try? await Task.sleep(for: .seconds(3))
    d.screenshot("afterlaunch")
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
    // The app's key path (EmulatorController.sendKey -> .key -> the helper's usb-kbd): tap Safari's address
    // field (panel frame: portrait top is x≈0, portrait left is y≈1) and type "hello"; ipad-typed.png shows it.
    if launched == "Safari" {
        await d.drag(0.065, 0.55, 0.065, 0.55)
        try? await Task.sleep(for: .seconds(2))
        for code in [4, 14, 37, 37, 31] {   // h e l l o (macOS virtual key codes)
            d.process.link.send(.key(macKeyCode: code, down: true)); try? await Task.sleep(for: .milliseconds(80))
            d.process.link.send(.key(macKeyCode: code, down: false)); try? await Task.sleep(for: .milliseconds(120))
        }
        try? await Task.sleep(for: .seconds(2))
        d.screenshot("ipad-typed")
    }
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
    // the lock screen sliders (tests/sessions/check-helper-boot.py).
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

    // Stop both through SIGTERM and the bounded helper halt, as GUI Stop does.
    // Semantic guest shutdown (system_powerdown) is a separate regression contract.
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

/// Exercise the actual helper hello and owned-process reaping without booting QEMU.
@MainActor func runPreparationFailure() async {
    let d = Device(name: "preparation-failure", profile: .iPodTouch2G)
    let missing = work.appendingPathComponent("missing-nor.bin")
    d.ipod = .init(nand: work.appendingPathComponent("missing-nand").path,
                   nor: missing.path, iBoot: "unused")
    do { try d.boot(generation: 1) } catch { fail("preparation scenario could not start: \(error)") }
    let exited = await d.process.waitForExit(timeout: 20)
    if !exited { d.process.kill(); _ = await d.process.waitForExit(timeout: 5) }
    d.mux.stop()
    d.serial?.finish()
    guard exited, let pid = d.helloPID else { fail("helper did not reach hello and reap after preparation failure") }
    var status: Int32 = 0
    errno = 0
    guard waitpid(pid, &status, WNOHANG) == -1, errno == ECHILD else { fail("owned helper was not reaped") }
    guard let original = d.preparationError, d.bootError == original,
          !original.isEmpty, original != "not booted" else { fail("original preparation diagnostic lost") }
    guard d.deaths.count == 1, d.process.link.pid == 0, !d.mux.process.isRunning else { fail("owned process cleanup incomplete") }
    let lease = d.dir.appendingPathComponent("work/lease")
    let fd = open(lease.path, O_RDWR)
    guard fd >= 0 else { fail("helper lease missing") }
    let acquired = flock(fd, LOCK_EX | LOCK_NB) == 0
    close(fd)
    guard acquired else { fail("reaped helper still owns storage lease") }
    let overlay = d.dir.appendingPathComponent("overlay")
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: overlay.path)) ?? []
    guard entries.isEmpty, !FileManager.default.fileExists(atPath: missing.path) else { fail("preparation failure published storage files") }
    emit("preparationFailureVerified", ["pid": pid, "error": original, "reaped": true, "leaseReleased": true, "guestStarted": false])
    exit(0)
}

/// Explicit lease directories remain caller policy; only a symlink at the file is refused.
@MainActor func runLeaseAdmission() async {
    let fm = FileManager.default
    let external = work.deletingLastPathComponent().appendingPathComponent("external-lease")
    let target = external.appendingPathComponent("target")
    try! fm.createDirectory(at: external, withIntermediateDirectories: true)
    let sentinel = Data("lease-target-must-stay-unchanged".utf8)
    try! sentinel.write(to: target)
    let alias = work.appendingPathComponent("alias/lease")
    try! fm.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! fm.createSymbolicLink(at: alias, withDestinationURL: target)
    let cases: [(String, URL, Bool)] = [
        ("ordinary", work.appendingPathComponent("Devices/\(UUID().uuidString)/work/lease"), true),
        ("external", external.appendingPathComponent("lease"), true),
        ("busy", external.appendingPathComponent("lease"), false),
        ("pending", external.appendingPathComponent("lease"), false),
        ("symlink", alias, false),
    ]
    for (name, lease, admitted) in cases {
        let held = name == "busy" ? try! StorageLease(lease) : nil
        let intent = lease.deletingLastPathComponent().appendingPathComponent("edit.json")
        if name == "pending" { try! Data("unfinished-edit".utf8).write(to: intent) }
        let process = DeviceProcess(instance: UUID(), profile: .iPodTouch2G,
            log: work.appendingPathComponent("\(name).log"), lease: lease,
            helper: URL(fileURLWithPath: config.helper), requirement: config.requirement)
        var hello = false
        var completionError: DeviceLinkError?
        var deaths = 0
        process.onDeath = { _ in deaths += 1 }
        process.start({ _ in hello = true; return nil }) { result in
            if case let .failure(error) = result { completionError = error }
            else { fail("lease test unexpectedly booted") }
        }
        let pid = process.link.pid
        let exited = await process.waitForExit(timeout: 20)
        if !exited { process.kill(); _ = await process.waitForExit(timeout: 5) }
        var status: Int32 = 0
        errno = 0
        let reaped = pid > 0 && waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD
        let expected: DeviceLinkError = .helperFailure(admitted ? "not booted" : DeviceLinkWire.leaseRefusal)
        guard exited, reaped, deaths == 1, process.link.pid == 0,
              hello == admitted, completionError == expected else {
            fail("\(name) lease: expected admission \(admitted), hello \(hello), error \(String(describing: completionError)), reaped \(reaped)")
        }
        if name == "busy" || name == "pending" {
            let diagnostic = (try? String(contentsOf: work.appendingPathComponent("\(name).log"), encoding: .utf8)) ?? ""
            let reason = name == "busy" ? "is held" : "unfinished storage edit"
            guard diagnostic.contains(reason) else { fail("\(name) lease missed actual helper diagnostic: \(diagnostic)") }
        }
        if admitted {
            let fd = open(lease.path, O_RDWR | O_NOFOLLOW)
            guard fd >= 0 else { fail("admitted lease missing") }
            let released = flock(fd, LOCK_EX | LOCK_NB) == 0
            close(fd)
            guard released else { fail("admitted lease still locked") }
        }
        guard (try? Data(contentsOf: target)) == sentinel else { fail("lease symlink target mutated") }
        if name == "pending" {
            guard (try? Data(contentsOf: intent)) == Data("unfinished-edit".utf8) else { fail("helper mutated pending intent") }
            try! fm.removeItem(at: intent)
        }
        withExtendedLifetime(held) {}
        emit("leaseAdmissionVerified", ["case": name, "admitted": admitted, "hello": hello,
            "reaped": reaped, "targetUnchanged": true, "guestStarted": false])
    }
    exit(0)
}

Task { @MainActor in
    if config.leaseAdmission == true { await runLeaseAdmission() }
    else if config.preparationFailure == true { await runPreparationFailure() }
    else if let guest = config.guest { await runGuest(guest) } else if let single = config.single { await runSingle(single) }
    else if let activation = config.activation { await runActivation(activation) }
    else if let deadline = config.deadline { await runDeadline(deadline) }
    else if let proxy = config.proxy { await runProxy(proxy) } else { await run() }
}
DispatchQueue.main.asyncAfter(deadline: .now() + (config.timeout ?? 560)) { fail("driver timed out") }
CFRunLoopRun()
