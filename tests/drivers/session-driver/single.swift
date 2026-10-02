import DeviceRuntime
import HostRuntime
// One prepared device (tests/sessions/check-sessions.py --single, build-release.py's verify, tests/matrix.py): a firmwarekit
// base booted as the app boots it, through the bundled helper, dylib and usbmuxd. It must light, answer lockdown
// over its own usbmuxd, take AFC round trips past 16 KiB (max-packet multiples, whose transfers end in a real ZLP),
// take an IPA, and shut down cleanly. No restore is involved. Screenshots of each stage land in the work directory.
//
// With `itpack` (an iPod) or the config's ipadItpack (an iPad) the boot carries the app's guest-package offer and
// the loader's report is recorded; `reboot` adds a second boot on the same overlay that must light, answer
// lockdown and still hold a file uploaded before the clean shutdown (tests/matrix.py's persist check).

import Foundation
import CoreGraphics
import Vision
import ImageIO

private nonisolated final class NotesOCRRace: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    func claim() -> Bool { lock.withLock { if finished { return false }; finished = true; return true } }
}

private nonisolated func notesEditorLabels(_ image: CGImage) async throws -> [String] {
    try await withCheckedThrowingContinuation { continuation in
        let race = NotesOCRRace()
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .fast
        recognition.usesLanguageCorrection = false
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
            if race.claim() {
                recognition.cancel()
                continuation.resume(throwing: NSError(domain: "NotesProbe", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Notes editor OCR timed out; focus remains unverified"]))
            }
        }
        DispatchQueue.global().async {
            do {
                try VNImageRequestHandler(cgImage: image).perform([recognition])
                let labels = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                if race.claim() { continuation.resume(returning: labels) }
            } catch {
                if race.claim() { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Read-only stock metadata; retained/offscreen views never establish focus.
private nonisolated enum NotesObservedFocus {
    private struct Node {
        var pointer: String, path: String, hidden: Bool, alpha: Double, first: Bool
        var frame: CGRect, name: String = ""
    }
    static func verified(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").map(String.init)
        guard let head = lines.first, head.hasPrefix("keyboard active="),
              head.hasSuffix("delegateFirstResponder=1") else { return false }
        let pieces = head.split(separator: " ")
        guard pieces.count == 4 else { return false }
        let active = String(pieces[1].dropFirst("active=".count))
        let delegate = String(pieces[2].dropFirst("delegate=".count))
        guard active != "0x0", delegate != "0x0" else { return false }
        let pattern = #"^ui view=(0x[0-9a-f]+) depth=([0-9]+) hidden=([01]) alpha=([-0-9.]+) firstResponder=([01]) frameKnown=1 frame=\(([-0-9.]+),([-0-9.]+),([-0-9.]+),([-0-9.]+)\) path=(0(?:\.[0-9]+)*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        var nodes: [String: Node] = [:]
        for (index, line) in lines.enumerated() {
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            func part(_ n: Int) -> String { Range(match.range(at: n), in: line).map { String(line[$0]) } ?? "" }
            guard let depth = Int(part(2)), depth <= 48,
                  let alpha = Double(part(4)), let x = Double(part(6)), let y = Double(part(7)),
                  let width = Double(part(8)), let height = Double(part(9)),
                  [alpha, x, y, width, height].allSatisfy({ $0.isFinite }) else { return false }
            let path = part(10)
            guard path.split(separator: ".").count == depth + 1, nodes[path] == nil else { return false }
            var node = Node(pointer: part(1), path: path, hidden: part(3) == "1", alpha: alpha,
                            first: part(5) == "1", frame: CGRect(x: x, y: y, width: width, height: height))
            if index + 1 < lines.count, lines[index + 1].hasPrefix("<"),
               lines[index + 1].contains(": " + node.pointer + ">") {
                node.name = String(lines[index + 1].dropFirst().prefix { $0 != ":" })
            }
            nodes[path] = node
        }
        func visibleFrame(_ target: Node) -> CGRect? {
            var origin = CGPoint.zero, clip = CGRect(x: 0, y: 0, width: 320, height: 480)
            let parts = target.path.split(separator: ".")
            for length in 1...parts.count {
                let path = parts.prefix(length).joined(separator: ".")
                guard let node = nodes[path], !node.hidden, node.alpha > 0.01,
                      node.frame.width > 0, node.frame.height > 0 else { return nil }
                origin.x += node.frame.origin.x; origin.y += node.frame.origin.y
                clip = clip.intersection(CGRect(origin: origin, size: node.frame.size))
                guard !clip.isNull, clip.width >= 1, clip.height >= 1 else { return nil }
            }
            return clip
        }
        guard let input = nodes.values.first(where: { $0.pointer == delegate }), input.first,
              ["UIWebDocumentView", "UITextView"].contains(input.name), visibleFrame(input) != nil,
              let keyboard = nodes.values.first(where: { $0.pointer == active && $0.name == "UIKeyboardImpl" }),
              let rect = visibleFrame(keyboard), abs(rect.minX) < 0.1, abs(rect.minY - 264) < 0.1,
              abs(rect.width - 320) < 0.1, abs(rect.height - 216) < 0.1 else { return false }
        return nodes.values.contains { $0.name == "UIKeyboardLayoutQWERTY" &&
            $0.path.hasPrefix(keyboard.path + ".") && visibleFrame($0) != nil }
    }
}

struct SingleConfig: Decodable {
    var board: String   // "ipod" | "ipad" | "ipod1g"
    var base: String
    /// AFC upload + download sizes; 16384 and 65536 are 512-byte multiples (a ZLP ends each transfer).
    var afcBytes: [Int]?
    /// An iPod's armv6.itpack: the boot carries the app's composed offer (an iPad's comes from ipadItpack).
    var itpack: String?
    /// A second boot on the same overlay after the clean shutdown, with the persist check.
    var reboot: Bool?
    /// With reboot: boot 1 ends at its home check with the app's Stop (a hard halt, no guest shutdown) instead of
    /// AFC, the install and the clean shutdown; boot 2 must light, answer lockdown and reach home (smoke #70: the
    /// 1.x FTL comes back from that Stop through _FTLRestore). No persist marker: a hard halt may lose it.
    var hardStop: Bool?
    /// smoke.md #5: this many boots, each starting AFC at lockdown's first answer, then the app's Stop.
    var raceBoots: Int?
    var raceDirty: Bool?
    /// The bundled lockdown-tz: set the zone and the Mac's clock once lockdown answers, as the app does on every
    /// connect (EmulatorController.syncTimeZoneWhenReady). Also completes the first-host handshake,
    /// independently of the clock, as EmulatorController.checkActivationIfNeeded does.
    var lockdownTZ: String?
    /// false: skip the IPA install (the entry has no AppSync, so the stock installd refuses it).
    var install: Bool?
    /// Qualify the shared host gesture using generic virtual-time input; never GUI Stop.
    var hostPowerGesture: Bool?
    /// Default migration is limited to the measured N72/5F138 shutdown gate.
    /// Explicit true/false remains available for qualification and comparison.
    func prefersHostPowerGesture(build: String?) -> Bool {
        hostPowerGesture ?? (board == "ipod" && build == "5F138")
    }
    /// Measured portrait typing: stock Notes SQLite readback, no GUI-default switch.
    var hostKeyboardProbe: Bool?
    /// After installation, launch through the app's guest agent where available. An unfitted helper set falls
    /// back to Home-screen reorder and a tap; screenshots alone do not prove the requested foreground identity.
    var launch: Bool?
    /// Where the icon is (normalized), for firmware without a usable host Home-screen reorder service: the reorder
    /// is skipped, and a tap on the first-install "Edit Home Screen" tip's Dismiss goes first.
    var launchAt: [Double]?
    /// A launch goes through the guest agent where the bake installed it (as the app's sidebar launches); then a tap at this
    /// normalized point (the iPad's panel: portrait top is x 0, portrait left is y 1; the iPod's portrait screen) and
    /// screenshots tapped1-2, 3 s apart. tests/matrix.py --gl-tap opens the Harness's "GL: rotating triangle" with it.
    var tapAfterLaunch: [Double]?
}

@MainActor func runSingle(_ s: SingleConfig) async {
    let ipad = s.board == "ipad"
    let d = Device(name: s.board, profile: ipad ? .iPad1 : s.board == "ipod1g" ? .iPodTouch1G : .iPodTouch2G)
    let b = URL(fileURLWithPath: s.base)
    if s.board == "ipod" { d.preparedBase = b }
    if !ipad {
        let iBoot: String
        do { iBoot = try BootRecipe.iPodIBoot(base: b) }
        catch { fail("boot lock: \(error)") }
        d.ipod = .init(nand: b.appendingPathComponent("nand").path, nor: b.appendingPathComponent("nor.bin").path,
                       iBoot: iBoot, gidBlobs: b.appendingPathComponent("gid-blobs.bin").path,
                       machine: BootRecipe.lockMachine(b.appendingPathComponent("device.lock.json")))
    }
    var offer: String?
    if !ipad, let itpack = s.itpack {
        do { offer = try d.offer(base: b, board: s.board == "ipod1g" ? "n45ap" : "n72ap", itpack: itpack) } catch { emit("offerError", ["error": "\(error)"]) }
    }
    let offered = offer != nil || (ipad && config.ipadItpack != nil)
    // The lock says whether the bake installed it_agent, including a fitted legacy build.
    let lock = (try? JSONSerialization.jsonObject(with: Data(contentsOf: b.appendingPathComponent("device.lock.json")))) as? [String: Any]
    let identity = (try? JSONSerialization.jsonObject(with: Data(contentsOf: b.appendingPathComponent("identity.json")))) as? [String: Any]
    let agent = d.profile.hasGuestTools && (((lock?["derived"] as? [String: Any])?["guest_tools"] as? String)?.hasPrefix("installed") ?? true)
    // 2.x reboot(RB_HALT) unmounts then halts the CPU without writing PMU standby.
    // Its stock power sheet does power off, even when a legacy agent is installed.
    let agentCanPowerOff = agent && ((lock?["product_version"] as? String ?? "3.1")
        .compare("3.1", options: .numeric) != .orderedAscending)

    func boot(_ generation: Int) async {
        do { try d.boot(generation: generation, guestPackage: offer) } catch { fail("boot \(generation): \(error)") }
        await waitLit(d, ipad ? 0.2 : 0.03, d.profile.bootBudget)   // the app's own boot budget (iPad 300 s)
        await waitUSB(d, expecting: d.profile.productType, 300)
        if let tool = s.lockdownTZ {
            var completed = false, lastError = ""
            for attempt in 0..<3 where !completed {
                if attempt > 0 { try? await Task.sleep(for: .seconds(10)) }
                do {
                    try await DeviceServices.finishActivation(tool: tool, socket: d.mux.clientSocket)
                    completed = true
                } catch { lastError = error.localizedDescription }
            }
            emit("activationCompleted", ["device": d.name, "generation": generation, "ok": completed,
                                         "error": completed ? "" : lastError])
            var zone: String?
            // with the agent where the boot has one, as the app's (EmulatorController.guest): a zone 4.x kept is retried after it
            let guest = agent || (ipad && offered)
                ? GuestServices(agent: GuestAgent(link: d.process.link, cache: GuestAgentCache()), packaged: offered) : nil
            for _ in 0..<12 where zone == nil {   // services come up after lockdown answers; the app retries every 5 s
                do { zone = try await DeviceServices.setTimeZone(TimeZone.current.identifier, tool: tool, socket: d.mux.clientSocket, guest: guest) }
                catch DeviceToolsError.zoneKept(let kept) { emit("timezoneKept", ["device": d.name, "generation": generation, "zone": kept]); break }
                catch {}
                if zone == nil { try? await Task.sleep(for: .seconds(5)) }
            }
            emit("timezone", ["device": d.name, "generation": generation, "zone": zone ?? ""])
        }
        emit("activation", ["device": d.name, "generation": generation, "state": await d.lockdownValue("ActivationState") ?? ""])
        if s.board == "ipod", let identity {
            let keys = [("SerialNumber", "serial-number"), ("UniqueDeviceID", "udid"),
                        ("WiFiAddress", "wifi-mac"), ("BluetoothAddress", "bt-mac")]
            let expected = Dictionary(uniqueKeysWithValues: keys.compactMap { key, field in
                (identity[field] as? String).map { (key, $0.lowercased()) }
            })
            let start = Date()
            var values: [String: String] = [:]
            repeat {
                for (key, _) in keys where expected[key] != nil {
                    values[key] = (await d.lockdownValue(key) ?? "").lowercased()
                }
                if values == expected || Date().timeIntervalSince(start) >= 60 { break }
                emit("identityPending", ["device": d.name, "generation": generation, "values": values])
                try? await Task.sleep(for: .seconds(2))
            } while !d.process.isDead
            emit("identity", ["device": d.name, "generation": generation,
                              "want": expected["BluetoothAddress"] ?? "", "bt": values["BluetoothAddress"] ?? "",
                              "expected": expected, "values": values, "matches": !expected.isEmpty && values == expected,
                              "seconds": Date().timeIntervalSince(start)])
        }
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
        let asks = agent || (ipad && offered)
        let guestAgent = GuestAgent(link: d.process.link, cache: GuestAgentCache())
        if asks { _ = await guestAgent.waitAlive(seconds: 60) }
        await d.slideToUnlock(generation, agent: asks ? guestAgent : nil)
        // A fresh 5.x iPad slides into the Setup Assistant instead of the home screen: walk it as a user would.
        // Ask until the agent answers (under load it comes up after the slide; one unanswered probe skipped the
        // walk on 9B176's first boot and left Setup up through the install and launch).
        var setupFront: (bundleID: String, name: String)?
        if ipad, offered {
            let t0 = Date()
            while setupFront == nil, Date().timeIntervalSince(t0) < d.profile.bootBudget / 2.5 {
                setupFront = try? await GuestAgent(link: d.process.link, cache: GuestAgentCache()).frontmost()
                if setupFront == nil { try? await Task.sleep(for: .seconds(3)) }
            }
        }
        if let setupFront, setupFront.bundleID == Setup5.bundleID {
            let (ok, detail) = await Setup5.walk(d)
            let after = try? await GuestAgent(link: d.process.link, cache: GuestAgentCache()).frontmost().bundleID
            emit("setup", ["device": d.name, "generation": generation, "ok": ok && after != Setup5.bundleID, "detail": detail,
                           "frontmost": after ?? ""])
            try? await Task.sleep(for: .seconds(5))
        }
        let hp = await d.wakeForShot(generation == 1 ? "home" : "home\(generation)")
        // Judge the home screen, not just a lit boot: the panel sleeps ~12 s after `lit` (audit
        // finding 3), so a later shot lands black. wakeForShot woke it; report the frontmost app
        // (SpringBoard where an agent can say) and the brightness so the matrix fails a slept/black
        // or wrong-app home instead of passing it on the single `lit` threshold (audit gap #2).
        // The iPad's agent comes from the seed package (offered). `screen` is the agent's name for what is up
        // (`Home Screen`, `Lock Screen`, an app's name): the lock screen is SpringBoard too, so the bundle id
        // alone cannot tell it from home. Without a fitted/offered agent, the matrix reports unknown.
        var front = "", screen = ""
        if asks, let f = try? await guestAgent.frontmost() { (front, screen) = f }
        emit("home", ["device": d.name, "generation": generation, "brightness": d.brightness() ?? -1,
                      "agent": asks, "frontmost": front, "screen": screen, "path": hp ?? ""])
    }

    /// Test-only clean shutdown: stock gesture or qualified agent halt, confirmed by PMU.
    /// GUI Stop is a separate hard halt and does not establish guest unmount.
    func shutdown(_ generation: Int) async {
        let quit = Date()
        if s.prefersHostPowerGesture(build: lock?["build"] as? String) && !ipad {
            do {
                try await HostInputAutomation.shutdown(d.process, firstGeneration: s.board == "ipod1g")
                emit("hostPowerGesture", ["device": d.name, "generation": generation, "confirmed": d.process.status?.shutdownConfirmed == true])
            } catch {
                emit("hostPowerGesture", ["device": d.name, "generation": generation, "error": "\(error)"])
            }
        }
        else if ipad { d.process.link.send(.machine(.powerdown)) }
        else if agentCanPowerOff { _ = try? await d.process.link.request(.agent(request: "\(UUID().uuidString) halt \n", deadline: 0), timeout: 5) }
        else {   // the machine's own hold-power-and-slide sequence
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
        await d.services.stopWorker()
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
            await d.services.stopWorker()
        d.mux.stop()
            d.serial?.removeEndpoints()
        }
        d.serial?.finish()
        emit("done")
        exit(0)
    }


    func keyboardProbe() async {
        let guest = GuestAgent(link: d.process.link, cache: GuestAgentCache())
        let preferences = "/var/mobile/Library/Preferences/com.apple.Preferences.plist"
        func physical(_ events: [VirtualInputEvent], heldCapture: String? = nil) async throws {
                let id = UInt64.random(in: 1...UInt64.max)
                guard VirtualInputEvent.valid(events),
                      case .ok(true) = try await d.process.link.request(.inputSequence(id: id, events: events), timeout: 5) else {
                    throw DeviceError.preflight("Notes setup input refused")
                }
                do {
                    if let heldCapture {
                        try await Task.sleep(for: .milliseconds(300))
                        guard case .inputSequenceStatus(1) = try await d.process.link.request(.inputSequenceStatus(id: id), timeout: 5) else {
                            throw DeviceError.preflight("held-contact diagnostic completed before capture")
                        }
                        d.screenshot(heldCapture)
                    }
                    let deadline = ContinuousClock.now + .seconds(30)
                    while ContinuousClock.now < deadline {
                        try Task.checkCancellation()
                        guard case let .inputSequenceStatus(status) = try await d.process.link.request(.inputSequenceStatus(id: id), timeout: 5) else {
                            throw DeviceError.preflight("Notes setup input status absent")
                        }
                        if status == 2 { return }
                        if status != 1 { throw DeviceError.preflight("Notes setup input interrupted") }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    throw DeviceError.preflight("Notes setup input timed out")
                } catch {
                    _ = try? await d.process.link.request(.inputSequenceCancel(id: id), timeout: 5)
                    throw error
                }
            }
        do {
            guard !ipad, s.board == "ipod", await guest.waitAlive(seconds: 30) else {
                throw DeviceError.preflight("Notes portrait probe requires the N72 guest agent")
            }
            // Disposable native fixture only: the existing read-only uidump
            // addition may be rebuilt with view visibility/responder metadata.
            if let diagnostic = ProcessInfo.processInfo.environment["LTM_UIDUMP_DYLIB"] {
                guard s.board == "ipod", lock?["build"] as? String == "5F138" else {
                    throw DeviceError.preflight("uidump diagnostic artifact is qualified for N72/5F138 only")
                }
                let bytes = try Data(contentsOf: URL(fileURLWithPath: diagnostic))
                try await guest.put("/usr/lib/it_typein.dylib", mode: 0o755, bytes)
                try await guest.chown(0, 0, "/usr/lib/it_typein.dylib")
                emit("hostKeyboardUIDumpArtifact", ["source": diagnostic, "bytes": bytes.count])
                // The existing stock SpringBoard job restart below reloads it
                // before Notes launches. No in-process code changes are made.
            }
            let original = try await guest.get(preferences)
            var prefs = original.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
            prefs["KeyboardAutocapitalization"] = false
            prefs["KeyboardAutocorrection"] = false
            prefs["KeyboardCapsLock"] = false
            let bytes = try PropertyListSerialization.data(fromPropertyList: prefs, format: .binary, options: 0)
            try await guest.put(preferences, mode: 0o644, bytes)
            try await guest.chown(501, 501, preferences)
            try await guest.sync()
            // UIKit caches keyboard preferences. Reload the stock SpringBoard job;
            // writing a plist without this is not evidence that the keys changed.
            try await guest.spawn(["/bin/launchctl", "stop", "com.apple.SpringBoard"])
            try await Task.sleep(for: .seconds(15))
            guard await guest.waitAlive(seconds: 30) else { throw DeviceError.preflight("agent did not return after preference reload") }
            await d.slideToUnlock(1, agent: guest)
            try await guest.launch("com.apple.mobilenotes")
            try await Task.sleep(for: .seconds(4))
            guard try await guest.frontmost().bundleID == "com.apple.mobilenotes" else {
                throw DeviceError.preflight("Notes foreground identity unavailable")
            }
            d.screenshot("keyboard-notes-before")
            var baselinePath = ""
            if let baseline = try await guest.get("/var/mobile/Library/Notes/notes.db") {
                let local = d.dir.appendingPathComponent("keyboard-notes-before.db")
                try baseline.write(to: local)
                baselinePath = local.path
                for suffix in ["-journal", "-wal", "-shm"] {
                    if let sidecar = try await guest.get("/var/mobile/Library/Notes/notes.db" + suffix) {
                        try sidecar.write(to: URL(fileURLWithPath: local.path + suffix))
                    }
                }
            }
            if let diagnostic = ProcessInfo.processInfo.environment["LTM_TOUCH_DIAGNOSTIC"] {
                let remote = "/var/tmp/ltm-mt-registry-" + UUID().uuidString
                do {
                    try await guest.put(remote, mode: 0o755, Data(contentsOf: URL(fileURLWithPath: diagnostic)))
                    let bytes = try await guest.spawn([remote])
                    try bytes.write(to: d.dir.appendingPathComponent("keyboard-mt-registry.xml"))
                    try await guest.unlink(remote)
                } catch {
                    try? await guest.unlink(remote)
                    throw error
                }
            }
            // Read the stock view tree independently of framebuffer/OCR.
            // An unsupported route is diagnostic evidence, never a focus pass.
            let inspectUI = true // every probe requires actual responder/visibility evidence
            func observeUI(_ phase: String) async -> String? {
                guard inspectUI else { return nil }
                var observed: String?
                let started = ContinuousClock.now
                var receipt: [String: Any] = ["phase": phase, "deadline": 5]
                do {
                    let response = try await guest.raw("uidump", deadline: 5)
                    let file = d.dir.appendingPathComponent("keyboard-notes-" + phase + "-ui.txt")
                    try response.output.write(to: file)
                    receipt["status"] = response.status
                    receipt["output"] = file.path
                    receipt["bytes"] = response.output.count
                    if response.status == 0 { observed = String(decoding: response.output, as: UTF8.self) }
                } catch {
                    receipt["error"] = String(describing: error)
                }
                receipt["elapsed"] = String(describing: started.duration(to: .now))
                let file = d.dir.appendingPathComponent("keyboard-notes-" + phase + "-ui.json")
                if let bytes = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]) {
                    try? bytes.write(to: file)
                }
                emit("hostKeyboardUIObservation", receipt)
                return observed
            }
            let beforeUI = await observeUI("before-contact")
            var focused = beforeUI.map(NotesObservedFocus.verified) ?? false
            emit("hostKeyboardInitialUI", ["focused": focused])
            if !focused {
                // Navigate only when the live stock responder proves we are not
                // already in the editor. Pixel snapshots cannot choose Add.
                guard beforeUI?.contains("keyboard active=") == true else {
                    throw DeviceError.preflight("Notes uidump lacks qualified responder metadata")
                }
                let heldDiagnostic = ProcessInfo.processInfo.environment["LTM_TOUCH_HELD_TRACE"] == "1"
                try await physical([.touch(phase: 0, x: 299.0 / 320, y: 42.0 / 480, at: 0),
                                    .touch(phase: 2, x: 299.0 / 320, y: 42.0 / 480, at: heldDiagnostic ? 1000 : 200)],
                                   heldCapture: heldDiagnostic ? "keyboard-notes-contact-held" : nil)
                focused = (await observeUI("after-contact")).map(NotesObservedFocus.verified) ?? false
            }
            guard focused else { throw DeviceError.preflight("Notes live editor/keyboard focus remains unverified") }
            try await Task.sleep(for: .seconds(2))
            guard let editorShot = d.screenshot("keyboard-notes-editor"),
                  let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: editorShot) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw DeviceError.preflight("Notes editor screenshot absent")
            }
            let labels = try await notesEditorLabels(image)
            let normalized = labels.joined().lowercased().filter { $0.isLetter }
            // Assert the actual stock editor and visible keyboard, not delivery.
            // OCR evidence is retained for diagnosis and never replaces DB text.
            try labels.joined(separator: "\n").write(to: d.dir.appendingPathComponent("keyboard-notes-editor-ocr.txt"), atomically: true, encoding: .utf8)
            let pixelsAgree = normalized.contains("done") && !normalized.contains("nonotes") &&
                (normalized.contains("qwerty") || normalized.contains("asdfgh"))
            emit("hostKeyboardPixelObservation", ["agreesWithLiveFocus": pixelsAgree, "labels": labels])
            if let tree = try? await guest.raw("uidump", deadline: 5), tree.status == 0 {
                try tree.output.write(to: d.dir.appendingPathComponent("keyboard-notes-editor-ui.txt"))
                let text = String(decoding: tree.output, as: UTF8.self)
                guard NotesObservedFocus.verified(text) else {
                    throw DeviceError.preflight("Notes live responder changed before typing")
                }
            }
            emit("hostKeyboardFocused", ["screenshot": editorShot, "labels": labels])
            var state = PortraitKeyboardState(numeric: false, shifted: false,
                                              automaticCapitalizationDisabled: true)
            state = try await HostInputAutomation.typePortraitText("qwerty 42", on: d.process, initialState: state)
            state = try await HostInputAutomation.typePortraitText("\nZz", on: d.process, initialState: state)
            // Stop virtual time before submitting: no character may be acquired
            // by a paused guest. Matching cancellation must invalidate the plan.
            d.process.link.send(.machine(.pause))
            let cancelledID: UInt64 = 0x4e6f746573
            let cancelled = try PortraitKeyboardPlan.make("BAD", initialState: state)
            guard case .ok(true) = try await d.process.link.request(.inputSequence(id: cancelledID, events: cancelled.events), timeout: 5) else {
                throw DeviceError.preflight("paused keyboard sequence refused")
            }
            try await Task.sleep(for: .milliseconds(200))
            guard case .inputSequenceStatus(1) = try await d.process.link.request(.inputSequenceStatus(id: cancelledID), timeout: 5) else {
                throw DeviceError.preflight("paused sequence advanced or was rejected")
            }
            _ = try await d.process.link.request(.inputSequenceCancel(id: cancelledID), timeout: 5)
            guard case .inputSequenceStatus(3) = try await d.process.link.request(.inputSequenceStatus(id: cancelledID), timeout: 5) else {
                throw DeviceError.preflight("matching keyboard cancellation not observed")
            }
            d.process.link.send(.machine(.resume))
            d.screenshot("keyboard-notes-after")
            // Background Notes through an ordinary Home press so UIKit commits
            // its document, then snapshot stock bytes through the guest service.
            try await physical([.button(0, down: true, at: 0), .button(0, down: false, at: 150)])
            try await Task.sleep(for: .seconds(3))
            try await guest.sync()
            guard let database = try await guest.get("/var/mobile/Library/Notes/notes.db") else {
                throw DeviceError.preflight("stock Notes database absent")
            }
            let local = d.dir.appendingPathComponent("keyboard-notes.db")
            try database.write(to: local)
            for suffix in ["-journal", "-wal", "-shm"] {
                if let sidecar = try await guest.get("/var/mobile/Library/Notes/notes.db" + suffix) {
                    try sidecar.write(to: URL(fileURLWithPath: local.path + suffix))
                }
            }
            emit("hostKeyboardProbe", ["ok": true, "database": local.path, "baseline": baselinePath,
                                       "expected": "qwerty 42\nZz", "cancelled": true])
        } catch {
            d.process.link.send(.machine(.resume))
            emit("hostKeyboardProbe", ["ok": false, "error": "\(error)"])
            // A failed optional probe must not leave the subsequent lifecycle
            // checks asleep, locked, or parked in Notes.
            await d.slideToUnlock(1, agent: guest)
            try? await physical([.button(0, down: true, at: 0), .button(0, down: false, at: 150)])
            try? await Task.sleep(for: .seconds(2))
            d.screenshot("keyboard-probe-recovered-home")
            emit("hostKeyboardProbeRecovery", ["foreground": (try? await guest.frontmost().bundleID) ?? "unavailable",
                                                "locked": (try? await guest.isLocked()) ?? true])
        }
    }
    await boot(1)
    if s.hostKeyboardProbe == true { await keyboardProbe() }

    if s.reboot == true, s.hardStop == true {
        d.process.terminate()   // the app's Stop: pause, flush the overlay, quit QEMU at once
        let exited = await d.process.waitForExit(timeout: 30)
        emit("quit", ["device": d.name, "generation": 1, "hard": true, "exited": exited, "reason": d.process.deathReason ?? ""])
        d.mux.stop()
        d.serial?.removeEndpoints()
        await boot(2)
        await shutdown(2)
        d.serial?.finish()
        emit("done")
        exit(0)
    }

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
    await d.wakeForShot("installed")   // wake first: the panel may have slept during the install
    // launch() goes through the guest agent wherever it answers (judged on the frontmost app), else taps the icon.
    if s.launch == true { await launch(d, at: s.launchAt, tap: s.tapAfterLaunch) }

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
/// "Continue without Wi-Fi?"; 5.1.1 then skips the Apple ID page and 5.0.1 does not, so the walk looks (smoke #39).
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

    /// A panel that slept during the walk (idle under host load: 9A5288d went dark before the country page) is
    /// woken with Home and slid back into Setup, as the driver's own unlock does; a lit panel is left alone.
    static func wake(_ d: Device) async {
        for _ in 0..<3 where (d.brightness() ?? 1) < 0.05 {
            d.process.link.send(.button(0, down: true)); try? await Task.sleep(for: .milliseconds(150))
            d.process.link.send(.button(0, down: false))
            try? await Task.sleep(for: .seconds(2))
            await d.drag(0.9365, 0.621, 0.9365, 0.0612)
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// The Apple ID page is up: its two white buttons ("Sign In with an Apple ID", "Create a Free Apple ID") fill
    /// the two button columns and the gap between them is dark. Set Up iPad's white list fills the gap too (0.98 white
    /// against the Apple ID page's 0); Terms, Diagnostics and Thank You leave a button column dark.
    static let appleID: [Box] = [(795, 170, 830, 600), (860, 170, 895, 600)], appleIDGap: Box = (840, 170, 852, 600)
    static func whiteFraction(_ d: Device, _ b: Box) -> Double {
        guard let px = region(d, b) else { return 0 }
        var white = 0, n = 0
        for i in stride(from: 0, to: px.count, by: 16) { n += 1; if px[i] > 225 && px[i + 1] > 225 && px[i + 2] > 225 { white += 1 } }
        return n == 0 ? 0 : Double(white) / Double(n)
    }
    static func appleIDUp(_ d: Device) -> Bool { kind(fingerprint(d)) == "apple id" }

    /// A Setup page's fingerprint: the white fraction of seven boxes (the two button columns and the gap between them,
    /// a strip left of the centre art, the iPad outline's left edge, the centre, the left list column), measured on
    /// 5.0 beta 1 to 5.1.1.
    static let printBoxes: [Box] = [(795, 170, 830, 600), (860, 170, 895, 600), (840, 170, 852, 600),
                                    (180, 300, 230, 450), (255, 300, 285, 450), (330, 300, 560, 450), (100, 150, 135, 700)]
    static func fingerprint(_ d: Device) -> [Double] { printBoxes.map { whiteFraction(d, $0) } }

    /// Which kind of Setup page a fingerprint is: "list" (language, country), "location", "wi-fi", "set up",
    /// "apple id", "diagnostics", "thank you"; nil for anything else (Terms, a page mid-transition, a dark panel).
    static func kind(_ f: [Double]) -> String? {
        guard f.count == 7 else { return nil }
        let (b1, b2, gap, left, frame, mid, list) = (f[0], f[1], f[2], f[3], f[4], f[5], f[6])
        if b1 > 0.85, b2 > 0.85, gap < 0.2, frame < 0.1 { return "apple id" }
        if b1 > 0.85, b2 > 0.85, gap > 0.9, left < 0.1, frame > 0.9, mid < 0.1 { return "set up" }
        if b1 > 0.85, gap > 0.7, left > 0.8, frame > 0.9, mid > 0.8 { return "list" }
        if b1 > 0.85, b2 < 0.1, gap > 0.85 { return "location" }
        if b1 < 0.1, b2 < 0.1, left > 0.9, frame > 0.15, frame < 0.45 { return "diagnostics" }
        if b1 < 0.1, b2 < 0.1, left < 0.2, frame < 0.1, mid < 0.1, list > 0.9 { return "diagnostics" }   // 5.0 beta 1
        if b1 < 0.1, b2 > 0.7 { return "thank you" }
        if b1 < 0.1, b2 < 0.1, gap < 0.1, left > 0.15, left < 0.45, frame < 0.1, mid < 0.1 { return "wi-fi" }
        return nil
    }
    /// The page kind each walk step shows (Terms has no fingerprint of its own).
    static func kind(of page: String) -> String? {
        ["language": "list", "country": "list", "location": "location", "wi-fi": "wi-fi", "set up": "set up",
         "apple id": "apple id", "diagnostics": "diagnostics", "thank you": "thank you"][page]
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
    /// Taps until `answered` holds on `hold` consecutive one-second polls, or `budget` runs out, tapping again every
    /// `every` seconds while nothing answered. A lost tap (a page still sliding in, a frame the host was too loaded to
    /// deliver) is retried instead of failing the walk; a pressed button's flash (the title bar changes for a moment,
    /// the page stays: 9B176's Set Up Next) is not an answer; a tap that did land is not repeated.
    static func tapUntil(budget: Double, every: Double, hold: Int = 3, tap: () async -> Void, answered: () -> Bool) async -> Bool {
        let t0 = Date()
        var streak = 0
        while Date().timeIntervalSince(t0) < budget {
            await tap()
            let t1 = Date()
            while Date().timeIntervalSince(t1) < every || streak > 0, Date().timeIntervalSince(t0) < budget {
                streak = answered() ? streak + 1 : 0
                if streak >= hold { return true }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return false
    }

    /// tapUntil's contract, with a fake page: a lost tap is retried, a landed tap is not repeated, a page that never
    /// answers gives up once the budget is spent (one tap per `every`).
    static func selfTest() async -> Bool {
        var ok = true
        func expect(_ label: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + label); ok = ok && cond }
        var taps = 0
        var r = await tapUntil(budget: 6, every: 1.5, tap: { taps += 1 }, answered: { taps >= 2 })
        expect("the first tap lost: tapped again, answered", r && taps == 2)
        taps = 0
        r = await tapUntil(budget: 6, every: 1.5, tap: { taps += 1 }, answered: { taps >= 1 })
        expect("a landed tap is not repeated", r && taps == 1)
        taps = 0
        r = await tapUntil(budget: 5, every: 2, tap: { taps += 1 }, answered: { false })
        expect("a page that never answers fails after the budget, one tap per interval", !r && taps == 3)
        taps = 0
        var polls = 0
        r = await tapUntil(budget: 12, every: 3, tap: { taps += 1; polls = 0 }, answered: { polls += 1; return taps >= 2 || polls == 1 })
        expect("a one-poll flash is not an answer: tapped again", r && taps == 2)
        // fingerprints measured off real Setup screenshots (9A5220p, 9A334, 9A405, 9B176, 9B206)
        let measured: [(String?, [Double])] = [
            ("list", [0.97, 0.92, 0.83, 0.92, 1.0, 0.95, 0.8]), ("list", [0.98, 0.92, 0.83, 0.92, 1.0, 0.96, 0.79]),
            ("location", [0.97, 0.0, 0.95, 0.05, 0.0, 0.34, 0.0]), ("wi-fi", [0.0, 0.0, 0.0, 0.28, 0.0, 0.0, 0.75]),
            ("set up", [0.93, 0.92, 0.99, 0.0, 1.0, 0.0, 0.0]), ("set up", [0.94, 0.92, 0.99, 0.0, 1.0, 0.0, 0.0]),
            ("apple id", [0.92, 0.92, 0.0, 0.07, 0.0, 0.09, 0.0]), ("apple id", [0.92, 0.92, 0.0, 0.04, 0.0, 0.1, 0.0]),
            ("diagnostics", [0.0, 0.0, 0.0, 1.0, 0.27, 0.01, 0.0]), ("diagnostics", [0.0, 0.0, 0.0, 1.0, 0.29, 0.0, 0.0]),
            ("diagnostics", [0.0, 0.0, 0.0, 0.12, 0.0, 0.0, 0.95]), ("thank you", [0.0, 0.83, 0.17, 0.05, 0.0, 0.18, 0.0]),
            (nil, [0.0, 0.0, 0.0, 0.0, 0.0, 0.04, 0.0]), (nil, [0.78, 0.69, 0.86, 1.0, 1.0, 0.74, 0.92])]
        for (want, f) in measured { expect("page \(want ?? "unrecognised") from \(f)", kind(f) == want) }
        return ok
    }

    /// From the first Setup page (the driver has already slid "slide to set up"): (walked, detail). Each page is
    /// entered only once its title bar has settled and differs from the page before (the previous Next landed);
    /// each tap is retried inside a per-page budget scaled from the board's boot budget (the iPad's 300 s: 120 s).
    static func walk(_ d: Device) async -> (Bool, String) {
        var walked: [String] = [], lastTitle: [UInt8]? = nil
        let budget = d.profile.bootBudget / 2.5
        var skipTo: Int? = nil
        page: for (index, (name, taps)) in pages.enumerated() {
            if let skipTo, index < skipTo { walked.append("\(name) (absent)"); continue }
            await wake(d)
            if let lastTitle {   // the previous page's Next took: wait for this page's title to replace it
                let t0 = Date()
                while Date().timeIntervalSince(t0) < budget, await settled(d, title) == lastTitle { await wake(d) }
            }
            // The page on screen decides, not the list's order: 5.0 beta 1 opens on Set Up iPad (no language,
            // country, location or Wi-Fi pages), 5.1.1 drops Apple ID after "Continue without Wi-Fi?" and 5.0.1 keeps it.
            // Wait for this step's page, or skip ahead to a later step whose page is showing.
            if let want = kind(of: name) {
                let t0 = Date()
                var seen: String? = nil, unknown = 0
                while Date().timeIntervalSince(t0) < budget {
                    _ = await settled(d, title)
                    seen = kind(fingerprint(d))
                    if seen == want { break }
                    if let seen, let later = pages.indices.first(where: { $0 > index && kind(of: pages[$0].0) == seen }) {
                        walked.append("\(name) (absent)"); skipTo = later; continue page
                    }
                    // Terms has no fingerprint: a lit, settled page nothing recognises, read twice, is it when it is the
                    // next step (5.1.1 goes Wi-Fi -> Terms without Apple ID)
                    unknown = seen == nil && (d.brightness() ?? 0) > 0.05 ? unknown + 1 : 0
                    if unknown >= 2, index + 1 < pages.count, kind(of: pages[index + 1].0) == nil {
                        walked.append("\(name) (absent)"); continue page
                    }
                    await wake(d); try? await Task.sleep(for: .seconds(2))
                }
                guard seen == want else {
                    d.screenshot("setup-\(name.replacingOccurrences(of: " ", with: "-"))-unknown")
                    return (false, "the \(name) page never showed in \(Int(budget)) s (screen: \(seen ?? "unrecognised"); after \(walked.joined(separator: ", ")))")
                }
            }
            if name == "wi-fi" { try? await Task.sleep(for: .seconds(15)) }   // give the join time before Next
            for (i, t) in taps.enumerated() {
                let pageTitle = await settled(d, title)
                let isAlert = t.box == alert
                let ref = isAlert ? nil : await settled(d, t.box)
                // An alert tap is also answered when the page itself moves on: 5.0 beta 1's "Skip this step" goes
                // straight to the next page with no confirmation; the page's remaining (alert) taps are then moot.
                let answered = { isAlert ? alertUp(d) || region(d, title) != pageTitle : region(d, t.box) != ref }
                d.screenshot("setup-\(name.replacingOccurrences(of: " ", with: "-"))-\(i)")
                // A choice the emulator does not care about (Diagnostics' "Don't Send") is best-effort: 5.0 beta 1
                // lays that page out differently, and its Next still has to be taken.
                let optional = name == "diagnostics" && t.box != title
                // behind a modal alert a second tap does nothing, so an alert tap is retried sooner
                let ok = await tapUntil(budget: isAlert || optional ? 60 : budget, every: 20, tap: { await tap(d, t.x, t.y, hold: t.hold) },
                                        answered: answered)
                // Terms' button highlight can look like a page transition. Let
                // it settle before deciding that Agree advanced without an alert.
                if name == "terms", i == 0, ok {
                    try? await Task.sleep(for: .seconds(3))
                    if !alertUp(d), kind(fingerprint(d)) == nil {
                        await tap(d, t.x, t.y, hold: 0.3)
                        try? await Task.sleep(for: .seconds(3))
                    }
                    d.screenshot("terms-retry")
                }
                if isAlert, ok, !alertUp(d) { lastTitle = pageTitle; walked.append(name + " (no alert)"); continue page }
                if !ok, optional { continue }
                // 5.0 beta 5 has no Terms page: its Agree tap (an empty corner elsewhere) raises no alert
                if !ok, name == "terms", i == 0 { walked.append("terms (absent)"); continue page }
                guard ok else { return (false, "the \(name) page did not answer tap \(i + 1) in \(Int(isAlert ? 60 : budget)) s (after \(walked.joined(separator: ", ")))") }
                if t.box == title { lastTitle = pageTitle }
            }
            if name == "wi-fi", alertUp(d) {   // "Continue without Wi-Fi?": no join (the Apple ID page may still follow)
                let ref = await settled(d, title)
                _ = await tapUntil(budget: budget, every: 20, tap: { await tap(d, wifiContinue.0, wifiContinue.1) },
                                   answered: { region(d, title) != ref })
                lastTitle = ref
                walked.append("wi-fi (not joined: continued without)")
            } else {
                walked.append(name)
            }
        }
        return (true, "walked \(walked.joined(separator: ", "))")
    }
}
