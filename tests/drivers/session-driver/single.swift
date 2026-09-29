// One prepared device (tests/sessions/check-sessions.py --single, build-release.py's verify, tests/matrix.py): a firmwarekit
// base booted as the app boots it, through the bundled helper, dylib and usbmuxd. It must light, answer lockdown
// over its own usbmuxd, take AFC round trips past 16 KiB (max-packet multiples, whose transfers end in a real ZLP),
// take an IPA, and shut down cleanly. No restore is involved. Screenshots of each stage land in the work directory.
//
// With `itpack` (an iPod) or the config's ipadItpack (an iPad) the boot carries the app's guest-package offer and
// the loader's report is recorded; `reboot` adds a second boot on the same overlay that must light, answer
// lockdown and still hold a file uploaded before the clean shutdown (tests/matrix.py's persist check).

import Foundation

struct SingleConfig: Decodable {
    var board: String   // "ipod" | "ipad" | "ipod1g"
    var base: String
    /// AFC upload + download sizes; 16384 and 65536 are 512-byte multiples (a ZLP ends each transfer).
    var afcBytes: [Int]?
    /// An iPod's armv6.itpack: the boot carries the app's composed offer (an iPad's comes from ipadItpack).
    var itpack: String?
    /// A second boot on the same overlay after the clean shutdown, with the persist check.
    var reboot: Bool?
    /// smoke.md #5: this many boots, each starting AFC at lockdown's first answer, then the app's Stop.
    var raceBoots: Int?
    var raceDirty: Bool?
    /// The bundled lockdown-tz: set the zone and the Mac's clock once lockdown answers, as the app does on every
    /// connect (EmulatorController.syncTimeZoneWhenReady). The clock is what clears a 2.x iPod's BrickState.
    var lockdownTZ: String?
    /// false: skip the IPA install (the entry has no AppSync, so the stock installd refuses it).
    var install: Bool?
    /// After the install, open the installed app (config.bundleID) as a user would on an iPod without the guest agent:
    /// the app's own Home-screen reorder puts its icon in the first slot, then a tap there; screenshots launched*.
    var launch: Bool?
    /// Where the icon is (normalized), for firmware whose SpringBoard has no springboardservices (2.x): the reorder
    /// is skipped, and a tap on the first-install "Edit Home Screen" tip's Dismiss goes first.
    var launchAt: [Double]?
}

@MainActor func runSingle(_ s: SingleConfig) async {
    let ipad = s.board == "ipad"
    let d = Device(name: s.board, profile: ipad ? .iPad1 : s.board == "ipod1g" ? .iPodTouch1G : .iPodTouch2G)
    let b = URL(fileURLWithPath: s.base)
    if !ipad {
        d.ipod = .init(nand: b.appendingPathComponent("nand").path, nor: b.appendingPathComponent("nor.bin").path,
                       iBoot: BootRecipe.iPodIBoot(base: b), gidBlobs: b.appendingPathComponent("gid-blobs.bin").path,
                       machine: BootRecipe.lockMachine(b.appendingPathComponent("device.lock.json")))
    }
    var offer: String?
    if !ipad, let itpack = s.itpack {
        do { offer = try d.offer(base: b, board: s.board == "ipod1g" ? "n45ap" : "n72ap", itpack: itpack) } catch { emit("offerError", ["error": "\(error)"]) }
    }
    let offered = offer != nil || (ipad && config.ipadItpack != nil)
    // The lock says whether the bake installed it_agent (3.1+); 2.x and 3.0 have none to halt the guest.
    let lock = (try? JSONSerialization.jsonObject(with: Data(contentsOf: b.appendingPathComponent("device.lock.json")))) as? [String: Any]
    let agent = d.profile.hasGuestTools && (((lock?["derived"] as? [String: Any])?["guest_tools"] as? String)?.hasPrefix("installed") ?? true)

    func boot(_ generation: Int) async {
        do { try d.boot(generation: generation, guestPackage: offer) } catch { fail("boot \(generation): \(error)") }
        await waitLit(d, ipad ? 0.2 : 0.03, 240)
        await waitUSB(d, expecting: d.profile.productType, 300)
        if let tool = s.lockdownTZ {
            var zone: String?
            for _ in 0..<12 where zone == nil {   // services come up after lockdown answers; the app retries every 5 s
                zone = try? await DeviceServices.setTimeZone(TimeZone.current.identifier, tool: tool, socket: d.mux.clientSocket)
                if zone == nil { try? await Task.sleep(for: .seconds(5)) }
            }
            emit("timezone", ["device": d.name, "generation": generation, "zone": zone ?? ""])
        }
        emit("activation", ["device": d.name, "generation": generation, "state": await d.lockdownValue("ActivationState") ?? ""])
        if offered {   // the loader's report: it_boot reports the serial it ran and R_* (GuestPackage.ReportCode)
            let start = Date()
            while d.process.status?.guestPackage == nil, Date().timeIntervalSince(start) < 60 { try? await Task.sleep(for: .seconds(1)) }
            let r = d.process.status?.guestPackage
            emit("guestPackage", ["device": d.name, "generation": generation, "serial": r?.serial ?? -1, "result": r?.result ?? -99])
        }
        func home() async {
            d.process.link.send(.button(0, down: true)); try? await Task.sleep(for: .milliseconds(150))
            d.process.link.send(.button(0, down: false))
        }
        if !ipad { await home() }   // wake: the display may have slept while it booted
        try? await Task.sleep(for: .seconds(3))
        // an iPad's lock screen turns the panel off ~10 s after it appears; Home wakes it
        for _ in 0..<3 where ipad && (d.brightness() ?? 1) < 0.05 {
            await home()
            try? await Task.sleep(for: .seconds(2))
        }
        d.screenshot(generation == 1 ? "lock" : "lock\(generation)")
        if ipad { await d.drag(0.9365, 0.621, 0.9365, 0.0612) } else { await d.drag(0.18, 0.9, 0.92, 0.9) }
        try? await Task.sleep(for: .seconds(5))
        // A fresh 5.x iPad slides into the Setup Assistant instead of the home screen: walk it as a user would.
        if ipad, offered, let front = try? await GuestAgent(link: d.process.link, cache: GuestAgentCache()).frontmost(),
           front.bundleID == Setup5.bundleID {
            let (ok, detail) = await Setup5.walk(d)
            let after = try? await GuestAgent(link: d.process.link, cache: GuestAgentCache()).frontmost().bundleID
            emit("setup", ["device": d.name, "generation": generation, "ok": ok && after != Setup5.bundleID, "detail": detail,
                           "frontmost": after ?? ""])
            try? await Task.sleep(for: .seconds(5))
        }
        let hp = await wakeForShot(d, generation == 1 ? "home" : "home\(generation)")
        // Judge the home screen, not just a lit boot: the panel sleeps ~12 s after `lit` (audit
        // finding 3), so a later shot lands black. wakeForShot woke it; report the frontmost app
        // (SpringBoard where an agent can say) and the brightness so the matrix fails a slept/black
        // or wrong-app home instead of passing it on the single `lit` threshold (audit gap #2).
        var front = ""
        if agent, let f = try? await GuestAgent(link: d.process.link, cache: GuestAgentCache()).frontmost() { front = f.bundleID }
        emit("home", ["device": d.name, "generation": generation, "brightness": d.brightness() ?? -1,
                      "frontmost": front, "path": hp ?? ""])
    }

    /// Wake the panel, then capture. The display sleeps ~12 s after `lit`, so an unqualified
    /// screenshot lands on a black panel (audit finding 3). Press Home, re-check brightness, and
    /// capture only once it is lit -- or capture the black frame after the last try, so the matrix
    /// fails the row honestly rather than passing a slept panel.
    @discardableResult
    func wakeForShot(_ d: Device, _ label: String, floor: Double = 0.05, tries: Int = 5) async -> String? {
        for _ in 0..<tries {
            if (d.brightness() ?? 0) >= floor { break }
            d.process.link.send(.button(0, down: true)); try? await Task.sleep(for: .milliseconds(150))
            d.process.link.send(.button(0, down: false))
            try? await Task.sleep(for: .seconds(2))
        }
        return d.screenshot(label)
    }

    /// Clean shutdown, as the app's quit path starts it: iPad powerdown, iPod agent halt.
    func shutdown(_ generation: Int) async {
        let quit = Date()
        if ipad { d.process.link.send(.machine(.powerdown)) }
        else if agent { _ = try? await d.process.link.request(.agent(request: "\(UUID().uuidString) halt \n", deadline: 0), timeout: 5) }
        else {   // no guest agent (2.x, 3.0): the machine's own hold-power-and-slide sequence
            d.process.link.send(.machine(.powerdown))
        }
        var confirmed = -1.0, shots = ipad ? [7.0, 12.0] : []   // the iPad gesture's power-off sheet, then after its drag
        while Date().timeIntervalSince(quit) < 50 {
            if d.process.status?.shutdownConfirmed == true { confirmed = Date().timeIntervalSince(quit); break }
            if let s = shots.first, Date().timeIntervalSince(quit) >= s {
                shots.removeFirst()
                d.screenshot("powerdown\(generation)-\(Int(s))s")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        d.process.terminate()
        let exited = await d.process.waitForExit(timeout: 30)
        emit("quit", ["device": d.name, "generation": generation, "confirmed": confirmed, "exited": exited, "reason": d.process.deathReason ?? ""])
        d.mux.stop()
    }

    // smoke.md #5: AFC (the app's listing: StartService, connect, stat of each entry) at lockdown's first
    // answer, polled at 100 ms from power-on; then the app's Stop. raceDirty first installs, uploads a file and
    // starts the agent halt, stopping 20-45 s into the shutdown (the sequence that preceded the one code 1).
    if let n = s.raceBoots {
        for g in 1...n {
            do { try d.boot(generation: g, guestPackage: offer) } catch { fail("boot \(g): \(error)") }
            let start = Date()
            while await d.productType() == nil {
                if d.process.isDead || Date().timeIntervalSince(start) > 300 { fail("boot \(g): lockdown never answered") }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let answered = Date()
            var race: [String: Any] = ["device": d.name, "generation": g, "lockdown": answered.timeIntervalSince(start)]
            do { race["entries"] = try await d.services.files(in: "").count } catch { race["error"] = "\(error)" }
            race["seconds"] = Date().timeIntervalSince(answered)
            emit("race", race)
            if s.raceDirty == true {
                await install(d)
                let local = d.dir.appendingPathComponent("race-\(g).bin")
                try? Data(count: 65_536).write(to: local)
                var stop: [String: Any] = ["device": d.name, "generation": g]
                do { try await d.services.uploadFile(local, into: "") { _ in } } catch { stop["uploadError"] = "\(error)" }
                _ = try? await d.process.link.request(.agent(request: "\(UUID().uuidString) halt \n", deadline: 0), timeout: 5)
                let wait = [20.0, 25, 30, 35, 40, 45][g % 6]
                try? await Task.sleep(for: .seconds(wait))
                stop["afterHalt"] = wait
                stop["confirmed"] = d.process.status?.shutdownConfirmed == true
                emit("raceStop", stop)
            }
            d.process.terminate()
            _ = await d.process.waitForExit(timeout: 30)
            d.mux.stop()
            d.serial?.removeEndpoints()
        }
        d.serial?.finish()
        emit("done")
        exit(0)
    }

    await boot(1)

    for size in s.afcBytes ?? [16384, 16385, 65536, 1_048_583] {
        let name = "ltm-verify-\(size).bin"
        let local = d.dir.appendingPathComponent(name), back = d.dir.appendingPathComponent("back-" + name)
        var bytes = [UInt8](repeating: 0, count: size)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 2654435761 >> 13) }
        let start = Date()
        do {
            try Data(bytes).write(to: local)
            try await d.services.uploadFile(local, into: "") { _ in }
            guard let file = try await d.services.files(in: "").first(where: { $0.name == name }) else { throw DeviceError.preflight("\(name) not listed") }
            try await d.services.download(file, to: back) { _ in }
            let same = try Data(contentsOf: back) == Data(bytes)
            await d.services.removeStaged(name)
            emit("afc", ["device": d.name, "bytes": size, "listed": Int(file.size), "same": same, "seconds": Date().timeIntervalSince(start)])
        } catch {
            emit("afc", ["device": d.name, "bytes": size, "same": false, "error": "\(error)"])
        }
        try? FileManager.default.removeItem(at: local); try? FileManager.default.removeItem(at: back)
    }

    if s.install != false { await install(d) }
    try? await Task.sleep(for: .seconds(3))
    await wakeForShot(d, "installed")   // wake first: the panel may have slept during the install
    if s.launch == true { await launch(d, at: s.launchAt) }

    // The persist marker: a file that must still be there after the clean shutdown and the second boot.
    let marker = "ltm-matrix-persist.bin"
    let markerBytes = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 11) })
    if s.reboot == true {
        let local = d.dir.appendingPathComponent(marker)
        do {
            try markerBytes.write(to: local)
            try await d.services.uploadFile(local, into: "") { _ in }
        } catch { emit("persist", ["device": d.name, "kept": false, "same": false, "error": "upload: \(error)"]) }
    }

    await shutdown(1)

    if s.reboot == true {
        d.serial?.removeEndpoints()
        await boot(2)
        let back = d.dir.appendingPathComponent("back-" + marker)
        do {
            guard let file = try await d.services.files(in: "").first(where: { $0.name == marker }) else { throw DeviceError.preflight("\(marker) not listed") }
            try await d.services.download(file, to: back) { _ in }
            let same = try Data(contentsOf: back) == markerBytes
            await d.services.removeStaged(marker)
            emit("persist", ["device": d.name, "kept": true, "same": same])
        } catch {
            emit("persist", ["device": d.name, "kept": false, "same": false, "error": "\(error)"])
        }
        let apps = (try? await d.services.installedApps())?.map(\.id) ?? []
        emit("restartedApps", ["device": d.name, "has": apps.contains(config.bundleID)])
        await shutdown(2)
    }
    d.serial?.finish()
    emit("done")
    exit(0)
}

/// iOS 5's Setup Assistant on a fresh iPad, walked as qemu-ios tests/ipad1/regress.py's gles leg walks it (SETUP_5):
/// framebuffer pixels (1024x768, the panel's landscape scan; portrait top is x 0). A tap counts as answered when
/// its box changes, or, for an alert's button, once an alert's navy buttons fill ALERT; only those taps are
/// retried (behind a modal alert a second tap does nothing). When Wi-Fi has not joined by its page, Setup asks
/// "Continue without Wi-Fi?" and then skips the Apple ID page, so the walk does too (smoke #39).
@MainActor enum Setup5 {
    static let bundleID = "com.apple.purplebuddy"
    typealias Box = (x0: Int, y0: Int, x1: Int, y1: Int)
    static let title: Box = (20, 150, 65, 620), alert: Box = (548, 255, 605, 515)
    static let wifiContinue = (575, 450)
    static let pages: [(String, [(x: Int, y: Int, hold: Double, box: Box)])] = [
        ("language", [(42, 28, 0.12, title)]),
        ("country", [(470, 400, 0.12, (95, 150, 1000, 620)), (42, 28, 0.12, title)]),
        ("location", [(833, 500, 0.12, (765, 150, 860, 620)), (42, 28, 0.12, alert), (585, 315, 0.12, title)]),
        ("wi-fi", [(42, 28, 0.12, title)]), ("set up", [(42, 28, 0.12, title)]),
        ("apple id", [(981, 385, 0.2, alert), (585, 450, 0.12, title)]),
        ("terms", [(1002, 32, 0.12, alert), (565, 315, 0.12, title)]),
        ("diagnostics", [(242, 500, 0.12, (150, 150, 265, 620)), (42, 28, 0.12, title)]),
        ("thank you", [(870, 385, 0.12, title)]),
    ]

    /// The box's BGRA bytes from the newest frame (nil without a 1024x768 frame).
    static func region(_ d: Device, _ b: Box) -> [UInt8]? {
        guard let s = d.process.link.frontSurface()?.surface, s.width == 1024, s.height == 768 else { return nil }
        s.incrementUseCount(); s.lock(options: .readOnly, seed: nil)
        defer { s.unlock(options: .readOnly, seed: nil); s.decrementUseCount() }
        var out: [UInt8] = []
        for y in b.y0..<b.y1 {
            out += UnsafeRawBufferPointer(start: s.baseAddress + y * s.bytesPerRow + b.x0 * 4, count: (b.x1 - b.x0) * 4)
        }
        return out
    }

    /// An alert is up: over 15% of ALERT's samples navy (blue well above red).
    static func alertUp(_ d: Device) -> Bool {
        guard let px = region(d, alert) else { return false }
        let w = alert.x1 - alert.x0
        var navy = 0, n = 0
        for y in stride(from: 0, to: alert.y1 - alert.y0, by: 4) {
            for x in stride(from: 0, to: w, by: 4) {
                let i = (y * w + x) * 4, b = Int(px[i]), r = Int(px[i + 2])
                if b > r + 40 && b > 80 { navy += 1 }
                n += 1
            }
        }
        return navy * 100 > 15 * n
    }

    /// The box once it holds still for a second (a page still sliding in under load).
    static func settled(_ d: Device, _ box: Box, timeout: Double = 20) async -> [UInt8]? {
        var last = region(d, box)
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout {
            try? await Task.sleep(for: .seconds(1))
            let now = region(d, box)
            if now == last { break }
            last = now
        }
        return last
    }

    static func tap(_ d: Device, _ x: Int, _ y: Int, hold: Double = 0.12) async {
        let nx = Double(x) / 1024, ny = Double(y) / 768
        d.process.link.send(.touch(slot: 0, phase: 0, x: nx, y: ny))
        try? await Task.sleep(for: .seconds(hold))
        d.process.link.send(.touch(slot: 0, phase: 2, x: nx, y: ny))
    }

    /// From the first Setup page (the driver has already slid "slide to set up"): (walked, detail).
    static func walk(_ d: Device) async -> (Bool, String) {
        var skipAppleID = false, walked: [String] = []
        page: for (name, taps) in pages {
            if name == "apple id", skipAppleID { continue }
            if name == "wi-fi" { try? await Task.sleep(for: .seconds(15)) }   // give the join time before Next
            for (i, t) in taps.enumerated() {
                _ = await settled(d, title)
                let isAlert = t.box == alert
                var ref: [UInt8]?
                if !isAlert { ref = await settled(d, t.box) }
                let answered = { isAlert ? alertUp(d) : region(d, t.box) != ref }
                d.screenshot("setup-\(name.replacingOccurrences(of: " ", with: "-"))-\(i)")
                var ok = false
                for _ in 0..<(isAlert ? 3 : 1) where !ok {
                    await tap(d, t.x, t.y, hold: t.hold)
                    let t0 = Date()
                    while Date().timeIntervalSince(t0) < (isAlert ? 20 : 60), !answered() { try? await Task.sleep(for: .seconds(1)) }
                    ok = answered()
                }
                // 5.0 beta 5 has no Terms page: its Agree tap (an empty corner elsewhere) raises no alert
                if !ok, name == "terms", i == 0 { walked.append("terms (absent)"); continue page }
                guard ok else { return (false, "the \(name) page did not answer tap \(i + 1) (after \(walked.joined(separator: ", ")))") }
            }
            if name == "wi-fi", alertUp(d) {   // "Continue without Wi-Fi?": no join, so no Apple ID page follows
                let ref = await settled(d, title)
                await tap(d, wifiContinue.0, wifiContinue.1)
                let t0 = Date()
                while Date().timeIntervalSince(t0) < 60, region(d, title) == ref { try? await Task.sleep(for: .seconds(1)) }
                skipAppleID = true
                walked.append("wi-fi (not joined: continued without)")
            } else {
                walked.append(name)
            }
        }
        return (true, "walked \(walked.joined(separator: ", "))")
    }
}
