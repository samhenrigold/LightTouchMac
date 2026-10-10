import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceClient
import HostServiceWire
import ImageIO
import SessionKit
import Vision

@testable import LightTouchCore

// One prepared device (`sessions single`, ReleaseBootTests): a firmwarekit
// base booted as the app boots it, through the bundled helper, dylib and usbmuxd. It must light, answer lockdown
// over its own usbmuxd, take AFC round trips past 16 KiB (max-packet multiples, whose transfers end in a real ZLP),
// take an IPA, and shut down cleanly. No restore is involved. Screenshots of each stage land in the work directory.
//
// With `itpack` (an iPod) or the config's ipadItpack (an iPad) the boot carries the app's guest-package offer and
// the loader's report is recorded; `reboot` adds a second boot on the same overlay that must light, answer
// lockdown and still hold a file uploaded before the clean shutdown (the persist check).

struct SingleConfig: Decodable {
    var board: String  // "ipod" | "ipad" | "ipod1g" | "iphone2g" | "ipod4g" | "iphone4" | "ipod3g" | "iphone3gs"
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
    /// connect (TimeZoneSync). Also completes the first-host handshake,
    /// independently of the clock, as ActivationCheck.checkIfNeeded does.
    var lockdownTZ: String?
    /// With reboot: boot 2 asks for this zone instead of the Mac's (the Mac's zone changed between boots).
    var secondZone: String?
    /// false: skip the IPA install (the entry has no AppSync, so the stock installd refuses it).
    var install: Bool?
    /// Qualify the shared host gesture using generic virtual-time input; never GUI Stop.
    var hostPowerGesture: Bool?
    /// Default migration is limited to the measured N72/5F138 shutdown gate.
    /// Explicit true/false remains available for qualification and comparison.
    func prefersHostPowerGesture(build: String?) -> Bool {
        hostPowerGesture ?? (board == "ipod" && build == "5F138")
    }
    /// After installation, launch through the app's guest agent where available. An unfitted helper set falls
    /// back to Home-screen reorder and a tap; screenshots alone do not prove the requested foreground identity.
    var launch: Bool?
    /// Where the icon is (normalized), for firmware without a usable host Home-screen reorder service: the reorder
    /// is skipped, and a tap on the first-install "Edit Home Screen" tip's Dismiss goes first.
    var launchAt: [Double]?
    /// A launch goes through the guest agent where the bake installed it (as the app's sidebar launches); then a tap at this
    /// normalized point (the iPad's panel: portrait top is x 0, portrait left is y 1; the iPod's portrait screen) and
    /// screenshots tapped1-2, 3 s apart.
    var tapAfterLaunch: [Double]?
    /// The same bundle id at a newer version, installed over the first (issue #22): it must install as an upgrade,
    /// keeping a file written into the app's data before it (judged through the agent). installd may move the data
    /// to a fresh container UUID; the data is what an upgrade keeps.
    var upgradeIPA: String?
    /// The guest's audio to this WAV instead of none (a playback check); never the Mac's speakers.
    var audioWAV: String?
    /// A file the guest agent reads back at home (fileRead), e.g. a marker a stopped edit wrote into the root FS.
    var readFile: String?
    /// Tweaks' Developer Settings: at the first Home this Developer Disk Image (its .signature beside it) is mounted
    /// through LockdownTools.mountDeveloperImage, the settings bundle Preferences looks for is read before and after,
    /// and Settings is opened to show its Developer row (`developerImage`, screenshot developer-settings).
    var developerImage: String?
    /// The base was prepared with firmwarekit create --skip-setup: what is frontmost when the agent first answers, and
    /// at Home what Setup's preferences say (`setupSeed`).
    var skipSetup: Bool?
    /// The base was prepared with firmwarekit create --jailbreak: Files through afc2 lists "/", reads the build's
    /// SystemVersion.plist and round-trips a file in root's home (`afc2`).
    var jailbreak: Bool?
    /// contrib/it-proxy/httpget (armv6): at the first Home the guest fetches `WiFiProbe.url`, which only wifi0's
    /// guestfwd answers, so the board's Wi-Fi joined (`wifi`).
    var httpget: String?
    /// Free-form Apply at this panel ("WxH" as it scans): after boot 1's home, the app's Stop and a fresh boot at
    /// panel=WxH on the same overlay (EmulatorController.setPanel); then the frame's size, the dock row in the new
    /// bottom band, and a tap on a dock icon launching its app.
    var panel: String?
}

/// A page only wifi0 serves (a guestfwd to a shell that answers any request), so a cellular route can't stand in for
/// Wi-Fi. "offline" (-1009) until the card has joined and taken its lease.
nonisolated enum WiFiProbe {
    static let url = "http://10.0.2.101/"
    static let body = "wifi0"
    static let guestForward =
        #",guestfwd=tcp:10.0.2.101:80-cmd:/bin/sh -c "while read -r l && [ ${#l} -gt 1 ]; do :; done; "#
        + #"printf 'HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\n\#(body)'""#
}

@MainActor func runSingle(_ s: SingleConfig) async {
    let ipad = s.board == "ipad"
    // The S5L8900 boards (the 1G and the original iPhone) share the 1.x paths; boardID is FirmwareKit's.
    let (profile, boardID): (Board, String) =
        switch s.board {
        case "ipad": (.k48, "k48ap")
        case "ipod1g": (.n45, "n45ap")
        case "iphone2g": (.m68, "m68ap")
        case "ipod4g": (.n81, "n81ap")
        case "iphone4": (.n90, "n90ap")
        case "ipod3g": (.n18, "n18ap")
        case "iphone3gs": (.n88, "n88ap")
        default: (.n72, "n72ap")
        }
    // The A4 and S5L8920 boards boot as the iPad does (kboot, the armv7 offer from ipadItpack); input, wake and
    // power-off stay the phone's.
    let a4 = profile.isKBoot
    let b = URL(fileURLWithPath: s.base)
    let d = Device(name: s.board, profile: profile, base: b)
    if s.httpget != nil { d.netdevExtra = WiFiProbe.guestForward }
    // Composed per boot from the device's verdicts, as the app's GuestPackageWatch.compose (an iPad's in Device.boot);
    // `offered`: this boot carries one (compose gives none for a stub seed).
    var offered = a4 && config.ipadItpack != nil
    func offer() -> String? {
        guard !a4, let itpack = s.itpack else { return nil }
        do {
            let dir = try d.offer(base: b, board: boardID, itpack: itpack)
            offered = dir != nil
            return dir
        } catch {
            emit("offerError", ["error": "\(error)"])
            offered = false
            return nil
        }
    }
    // The lock says whether the bake installed it_agent, including a fitted legacy build.
    let lock = (try? DeviceLock.read(base: b)) ?? nil
    let identity =
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: b.appendingPathComponent("identity.json"))))
        as? [String: Any]
    // 7.x boots, pairs and walks Setup far slower (qemu-ios e7ec3ded6a: about 1400 s of QEMU for app-install).
    let slow = Double((lock?.productVersion ?? "").split(separator: ".").first ?? "").map { $0 >= 7 ? 2.5 : 1 } ?? 1
    let lockAgent = lock?.guestPackage?["jobs"]?.strings?.contains("com.qemu.it-agent.plist") ?? false
    let agent = d.profile.hasGuestTools && (lock?.derived?["guest_tools"]?.string?.hasPrefix("installed") ?? true)
    // 2.x reboot(RB_HALT) unmounts then halts the CPU without writing PMU standby.
    // Its stock power sheet does power off, even when a legacy agent is installed.
    let agentCanPowerOff =
        agent
        && ((lock?.productVersion ?? "3.1")
            .compare("3.1", options: .numeric) != .orderedAscending)

    func boot(_ generation: Int) async {
        do { try d.boot(generation: generation, guestPackage: offer()) } catch { fail("boot \(generation): \(error)") }
        await waitLit(d, ipad ? 0.2 : 0.03, d.profile.bootBudget * slow)  // the app's own boot budget (iPad 300 s)
        await waitUSB(d, expecting: d.profile.productType, 300 * slow)
        // The app's readiness answer (ReadinessWatch through DeviceApps.waitForSpringBoard): SpringBoard's layout
        // service, or the agent naming SpringBoard or Setup frontmost. Until wave 2.5 the app gave up after one 45 s
        // wait and refused input on a live screen (Sam 10-07, iOS 7's Setup); `seconds` past 45 is that case.
        // Before 3.1 there is no springboardservices: the app takes lockdown's answer as the Home screen's
        // (DeviceApps.hasSpringBoardServices), and so does this probe.
        do {
            let t0 = Date()
            let probe = GuestAgent(link: d.process.link, cache: GuestAgentCache())
            var by =
                (lock?.productVersion ?? "3.1").compare("3.1", options: .numeric) == .orderedAscending
                ? "lockdown (no springboardservices)" : ""
            while by.isEmpty, Date().timeIntervalSince(t0) < 600 {
                if (try? await d.services.homeScreenOrder()) != nil {
                    by = "layout"
                    break
                }
                if let front = try? await probe.frontmost(),
                    front.bundleID == "com.apple.springboard" || front.bundleID == "com.apple.purplebuddy"
                {
                    by = "agent: \(front.bundleID)"
                    break
                }
                try? await Task.sleep(for: .seconds(1))
            }
            emit(
                "springBoard",
                ["device": d.name, "generation": generation, "seconds": Date().timeIntervalSince(t0), "by": by]
            )
        }
        if let tool = s.lockdownTZ {
            var completed = false
            var lastError = ""
            for attempt in 0..<3 where !completed {
                if attempt > 0 { try? await Task.sleep(for: .seconds(10)) }
                do {
                    try await DeviceServices.finishActivation(tool: tool, socket: d.mux.clientSocket)
                    completed = true
                } catch { lastError = error.localizedDescription }
            }
            emit(
                "activationCompleted",
                [
                    "device": d.name, "generation": generation, "ok": completed,
                    "error": completed ? "" : lastError,
                ]
            )
            var zone: String?
            // with the agent where the boot has one, as the app's (EmulatorController.guest): a zone 4.x kept is retried after it
            let guest =
                agent || (a4 && offered)
                ? GuestServices(agent: GuestAgent(link: d.process.link, cache: GuestAgentCache()), packaged: offered)
                : nil
            let want = generation == 2 ? s.secondZone ?? TimeZone.current.identifier : TimeZone.current.identifier
            for _ in 0..<12 where zone == nil {  // services come up after lockdown answers; the app retries every 5 s
                do {
                    zone = try await DeviceServices.setTimeZone(
                        want,
                        keepClock: lock?.machineOptions(base: b)["rtc-epoch"] != nil,
                        tool: tool,
                        socket: d.mux.clientSocket,
                        guest: guest,
                        region: nil
                    )
                } catch DeviceToolsError.zoneKept(let kept) {
                    emit("timezoneKept", ["device": d.name, "generation": generation, "zone": kept])
                    break
                } catch {}
                if zone == nil { try? await Task.sleep(for: .seconds(5)) }
            }
            emit("timezone", ["device": d.name, "generation": generation, "zone": zone ?? "", "want": want])
        }
        emit(
            "activation",
            ["device": d.name, "generation": generation, "state": await d.lockdownValue("ActivationState") ?? ""]
        )
        if s.board == "ipod" || ipad, let identity {
            let keys =
                ipad
                ? [("WiFiAddress", "wifi-mac")]
                : [
                    ("SerialNumber", "serial-number"), ("UniqueDeviceID", "udid"),
                    ("WiFiAddress", "wifi-mac"), ("BluetoothAddress", "bt-mac"),
                ]
            let expected = Dictionary(
                uniqueKeysWithValues: keys.compactMap { key, field in
                    (identity[field] as? String).map { (key, $0.lowercased()) }
                }
            )
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
            emit(
                "identity",
                [
                    "device": d.name, "generation": generation,
                    "want": expected["BluetoothAddress"] ?? "", "bt": values["BluetoothAddress"] ?? "",
                    "expected": expected, "values": values, "matches": !expected.isEmpty && values == expected,
                    "seconds": Date().timeIntervalSince(start),
                ]
            )
        }
        if offered {  // the loader's report: it_boot reports the serial it ran and R_* (GuestPackage.ReportCode)
            let start = Date()
            while d.process.status?.guestPackage == nil, Date().timeIntervalSince(start) < 60 {
                try? await Task.sleep(for: .seconds(1))
            }
            let r = d.process.status?.guestPackage
            emit(
                "guestPackage",
                ["device": d.name, "generation": generation, "serial": r?.serial ?? -1, "result": r?.result ?? -99]
            )
            // GuestPackageSession's verdict, recorded as the app records it: the next offer carries `verdict good`.
            var record = d.guestRecord
            if let r { record.active = r.serial }
            let judging = ContinuousClock.now
            var healthySince: ContinuousClock.Instant?
            var verdict: GuestPackage.Verdict?
            while verdict == nil, ContinuousClock.now - judging < .seconds(120), let status = d.process.status,
                !d.process.isDead
            {
                if status.uiReady && (!agent || status.agentStatus == 1) {
                    healthySince = healthySince ?? .now
                } else {
                    healthySince = nil
                }
                verdict = GuestPackage.verdict(
                    report: status.guestPackage,
                    healthyFor: healthySince.map { .now - $0 } ?? .zero,
                    elapsed: .now - judging,
                    record: record,
                    restored: false
                )
                if verdict == nil { try? await Task.sleep(for: .seconds(1)) }
            }
            switch verdict {
            case .good(let serial)?:
                record.lastGood = serial
                record.bad.removeAll { $0 == serial }
            case .bad(let serial)?: if !record.bad.contains(serial) { record.bad.append(serial) }
            default: break
            }
            d.guestRecord = record
            emit(
                "guestVerdict",
                [
                    "device": d.name, "generation": generation, "verdict": verdict.map { "\($0)" } ?? "none",
                    "lastGood": record.lastGood ?? -1,
                ]
            )
        }
        func home() async {
            d.process.link.send(.button(0, down: true))
            try? await Task.sleep(for: .milliseconds(150))
            d.process.link.send(.button(0, down: false))
        }
        if !ipad { await home() }  // wake: the display may have slept while it booted
        try? await Task.sleep(for: .seconds(3))
        // an iPad's lock screen turns the panel off ~10 s after it appears; Home wakes it
        for _ in 0..<3 where ipad && (d.brightness() ?? 1) < 0.05 {
            await home()
            try? await Task.sleep(for: .seconds(2))
        }
        d.screenshot(generation == 1 ? "lock" : "lock\(generation)")
        // A lock whose guest package carries the agent (framecheck's home judge expects its answer) gets the wait
        // even when this run made no offer (no --ipad-itpack): its seed package starts the agent.
        let asks = agent || (a4 && offered) || lockAgent
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
            emit(
                "setup",
                [
                    "device": d.name, "generation": generation, "ok": ok && after != Setup5.bundleID, "detail": detail,
                    "frontmost": after ?? "",
                ]
            )
            try? await Task.sleep(for: .seconds(5))
        }
        // A fresh 6.x phone: Setup's welcome slider (SpringBoard's lock screen) and then purplebuddy's pages.
        // Ask until the agent answers, as the iPad's walk does (n90 6.0.1's first boot, at load 30: no answer at 60 s).
        var phoneFront: (bundleID: String, name: String)?
        if a4, !ipad, asks {
            let t0 = Date()
            while phoneFront == nil, Date().timeIntervalSince(t0) < d.profile.bootBudget / 2.5 {
                phoneFront = try? await guestAgent.frontmost()
                if phoneFront == nil { try? await Task.sleep(for: .seconds(3)) }
            }
        }
        if let front = phoneFront, front.bundleID == Setup5.bundleID || front.name == "Lock Screen" {
            let (ok, detail) = await SetupPhone.walk(d, agent: guestAgent, generation: generation)
            emit("setup", ["device": d.name, "generation": generation, "ok": ok, "detail": detail])
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
        var front = ""
        var screen = ""
        if asks, let f = try? await guestAgent.frontmost() { (front, screen) = f }
        emit(
            "home",
            [
                "device": d.name, "generation": generation, "brightness": d.brightness() ?? -1,
                "backlight": d.process.status?.backlightLevel ?? -1, "agent": asks, "frontmost": front,
                "screen": screen, "path": hp ?? "",
            ]
        )
        if generation == 1, let httpget = s.httpget {
            var output = ""
            if asks, let bytes = try? Data(contentsOf: URL(fileURLWithPath: httpget)) {
                for attempt in 0..<9 {
                    if attempt > 0 { try? await Task.sleep(for: .seconds(10)) }
                    do {
                        try await guestAgent.put("/tmp/ltm-httpget", mode: 0o755, bytes)
                        let page = try await guestAgent.spawn(["/tmp/ltm-httpget", WiFiProbe.url])
                        output = String(decoding: page, as: UTF8.self)
                    } catch let error as GuestAgentError {
                        output = String(decoding: error.output.prefix(300), as: UTF8.self)
                    } catch { output = "\(error)" }
                    if output.hasPrefix("HTTP 200") { break }
                }
            }
            emit(
                "wifi",
                [
                    "device": d.name, "agent": asks, "output": String(output.prefix(200)),
                    "ok": output.hasPrefix("HTTP 200") && output.hasSuffix(WiFiProbe.body),
                ]
            )
        }
        if s.skipSetup == true, generation == 1 {
            var values: [String: Any] = [
                "device": d.name, "agent": asks,
                "firstFront": (setupFront ?? phoneFront).map { "\($0.bundleID) \($0.name)" } ?? "",
            ]
            func plist(_ name: String) async -> [String: Any] {
                guard asks, let data = try? await guestAgent.get("/var/mobile/Library/Preferences/\(name).plist") else {
                    return [:]
                }
                return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
            }
            let buddy = await plist("com.apple.purplebuddy")
            let global = await plist(".GlobalPreferences")
            let location = await plist("com.apple.locationd")
            values["setupDone"] = buddy["SetupDone"] as? Bool ?? false
            values["locale"] = global["AppleLocale"] as? String ?? ""
            values["language"] = (global["AppleLanguages"] as? [String])?.first ?? ""
            values["location"] =
                (location["LocationServicesEnabledIn7.0"] ?? location["LocationServicesEnabled"]).map { "\($0)" } ?? ""
            emit("setupSeed", values)
        }
        if let image = s.developerImage, generation == 1 {
            let bundle = "/Developer/Library/PreferenceBundles/Developer Settings.bundle/Info.plist"
            let before = asks ? (try? await guestAgent.get(bundle)) != nil : false
            var mounted: String
            do {
                mounted =
                    try await d.services.mountDeveloperImage(URL(fileURLWithPath: image), tool: s.lockdownTZ)
                    ? "mounted" : "already"
            } catch { mounted = "\(error)" }
            let after = asks ? (try? await guestAgent.get(bundle)) != nil : false
            if asks { try? await guestAgent.launch("com.apple.Preferences") }
            try? await Task.sleep(for: .seconds(6))
            d.screenshot("developer-settings")
            emit(
                "developerImage",
                ["device": d.name, "agent": asks, "before": before, "after": after, "mounted": mounted]
            )
        }
        if let path = s.readFile {
            let data = asks ? try? await guestAgent.get(path) : nil
            emit(
                "fileRead",
                [
                    "device": d.name, "generation": generation, "path": path, "agent": asks,
                    "found": data != nil, "content": data.map { String(decoding: $0, as: UTF8.self) } ?? "",
                ]
            )
        }
    }

    /// Test-only clean shutdown: stock gesture or qualified agent halt, confirmed by PMU.
    /// GUI Stop is a separate hard halt and does not establish guest unmount.
    func shutdown(_ generation: Int) async {
        let quit = Date()
        if s.prefersHostPowerGesture(build: lock?.build) && !ipad {
            do {
                try await HostInputAutomation.shutdown(d.process, firstGeneration: profile == .n45)
                emit(
                    "hostPowerGesture",
                    [
                        "device": d.name, "generation": generation,
                        "confirmed": d.process.status?.shutdownConfirmed == true,
                    ]
                )
            } catch {
                emit("hostPowerGesture", ["device": d.name, "generation": generation, "error": "\(error)"])
            }
        } else if ipad {
            d.process.link.send(.machine(.powerdown))
        }
        // The A4/S5L8920 phones: the agent their offer carries (the machine's hold-and-slide is the iPad's, and on
        // the iPod touch 4G it confirmed in 45 s once and not at all the next boot).
        else if agentCanPowerOff || (a4 && offered) {
            _ = try? await d.process.link.request(
                .agent(request: "\(UUID().uuidString) halt \n", deadline: 0),
                timeout: 5
            )
        } else {  // the machine's own hold-power-and-slide sequence
            d.process.link.send(.machine(.powerdown))
        }
        var confirmed = -1.0
        var shots = ipad ? [7.0, 12.0] : []  // the iPad gesture's power-off sheet, then after its drag
        while Date().timeIntervalSince(quit) < 50 {
            if d.process.status?.shutdownConfirmed == true {
                confirmed = Date().timeIntervalSince(quit)
                break
            }
            if let s = shots.first, Date().timeIntervalSince(quit) >= s {
                shots.removeFirst()
                d.screenshot("powerdown\(generation)-\(Int(s))s")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        d.process.terminate()
        let exited = await d.process.waitForExit(timeout: 30)
        emit(
            "quit",
            [
                "device": d.name, "generation": generation, "confirmed": confirmed, "exited": exited,
                "reason": d.process.deathReason ?? "",
            ]
        )
        await d.services.stopWorker()
        d.mux.stop()
    }

    // smoke.md #5: AFC (the app's listing: StartService, connect, stat of each entry) at lockdown's first
    // answer, polled at 100 ms from power-on; then the app's Stop. raceDirty first installs, uploads a file and
    // starts the agent halt, stopping 20-45 s into the shutdown (the sequence that preceded the one code 1).
    if let n = s.raceBoots {
        for g in 1...n {
            do { try d.boot(generation: g, guestPackage: offer()) } catch { fail("boot \(g): \(error)") }
            let start = Date()
            while await d.productType() == nil {
                if d.process.isDead || Date().timeIntervalSince(start) > 300 {
                    fail("boot \(g): lockdown never answered")
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let answered = Date()
            var race: [String: Any] = [
                "device": d.name, "generation": g, "lockdown": answered.timeIntervalSince(start),
            ]
            do { race["entries"] = try await d.services.files(in: "").count } catch { race["error"] = "\(error)" }
            race["seconds"] = Date().timeIntervalSince(answered)
            emit("race", race)
            if s.raceDirty == true {
                await install(d)
                let local = d.dir.appendingPathComponent("race-\(g).bin")
                try? Data(count: 65_536).write(to: local)
                var stop: [String: Any] = ["device": d.name, "generation": g]
                do { try await d.services.uploadFile(local, into: "") { _ in } } catch {
                    stop["uploadError"] = "\(error)"
                }
                _ = try? await d.process.link.request(
                    .agent(request: "\(UUID().uuidString) halt \n", deadline: 0),
                    timeout: 5
                )
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

    await boot(1)

    if let panel = s.panel {
        await resize(d, to: panel, boot: boot, shutdown: shutdown)
        d.serial?.finish()
        emit("done")
        exit(0)
    }

    if s.reboot == true, s.hardStop == true {
        d.process.terminate()  // the app's Stop: pause, flush the overlay, quit QEMU at once
        let exited = await d.process.waitForExit(timeout: 30)
        emit(
            "quit",
            ["device": d.name, "generation": 1, "hard": true, "exited": exited, "reason": d.process.deathReason ?? ""]
        )
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
        let local = d.dir.appendingPathComponent(name)
        let back = d.dir.appendingPathComponent("back-" + name)
        var bytes = [UInt8](repeating: 0, count: size)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 2_654_435_761 >> 13) }
        let start = Date()
        do {
            try Data(bytes).write(to: local)
            try await d.services.uploadFile(local, into: "") { _ in }
            guard let file = try await d.services.files(in: "").first(where: { $0.name == name }) else {
                throw DeviceError.preflight("\(name) not listed")
            }
            try await d.services.download(file, to: back) { _ in }
            let same = try Data(contentsOf: back) == Data(bytes)
            await d.services.removeStaged(name)
            emit(
                "afc",
                [
                    "device": d.name, "bytes": size, "listed": Int(file.size), "same": same,
                    "seconds": Date().timeIntervalSince(start),
                ]
            )
        } catch {
            emit("afc", ["device": d.name, "bytes": size, "same": false, "error": "\(error)"])
        }
        try? FileManager.default.removeItem(at: local)
        try? FileManager.default.removeItem(at: back)
    }

    if s.jailbreak == true {  // the Files browser's own calls, as the app makes them for a jailbroken device
        var root = d.services
        root.wholeFileSystem = true
        let back = d.dir.appendingPathComponent("afc2-SystemVersion.plist")
        var top: [String] = []
        do {
            top = try await root.files(in: "").map(\.name)
            let dir = "System/Library/CoreServices"
            guard let file = try await root.files(in: dir).first(where: { $0.name == "SystemVersion.plist" }) else {
                throw DeviceError.preflight("\(dir)/SystemVersion.plist not listed")
            }
            try await root.download(file, to: back) { _ in }
            let version =
                (try PropertyListSerialization.propertyList(from: Data(contentsOf: back), format: nil)
                as? [String: Any])?["ProductVersion"] as? String
            // A file round trip in root's home, which only root may write, outside the media folder.
            let local = d.dir.appendingPathComponent("ltm-afc2.bin")
            let bytes = Data((0..<70_001).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 9) })
            try bytes.write(to: local)
            try await root.uploadFile(local, into: "private/var/root") { _ in }
            guard
                let copy = try await root.files(in: "private/var/root").first(where: {
                    $0.name == local.lastPathComponent
                })
            else { throw DeviceError.preflight("the copy isn't listed in private/var/root") }
            try await root.download(copy, to: back) { _ in }
            let same = try Data(contentsOf: back) == bytes
            try await root.delete("private/var/root/\(copy.name)")
            let gone = try await !root.files(in: "private/var/root").contains { $0.name == copy.name }
            try? FileManager.default.removeItem(at: local)
            emit("afc2", ["device": d.name, "top": top, "version": version ?? "", "roundTrip": same && gone])
        } catch {
            emit("afc2", ["device": d.name, "top": top, "error": "\(error)"])
        }
        await cydia(d)
    }
    if s.install != false {
        await install(d)
        await appFiles(d, agent: agent || (a4 && offered) || lockAgent, jailbreak: s.jailbreak == true)
    }
    if let upgrade = s.upgradeIPA { await upgradeInPlace(d, upgrade) }
    try? await Task.sleep(for: .seconds(3))
    await d.wakeForShot("installed")  // wake first: the panel may have slept during the install
    // launch() goes through the guest agent wherever it answers (judged on the frontmost app), else taps the icon.
    if s.launch == true { await launch(d, at: s.launchAt, tap: s.tapAfterLaunch) }
    if let list = ProcessInfo.processInfo.environment["LTM_APPS_LIST"] { await appsSurvey(d, list: list) }

    // The persist marker: a file that must still be there after the clean shutdown and the second boot.
    let marker = "ltm-matrix-persist.bin"
    let markerBytes = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 11) })
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
            guard let file = try await d.services.files(in: "").first(where: { $0.name == marker }) else {
                throw DeviceError.preflight("\(marker) not listed")
            }
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

/// Free-form Apply (SingleConfig.panel), from boot 1's Home screen: the app's Stop, boot 2 at the panel, its frame's
/// size, its dock (the bottom band of boot 1's Home screen, as tall, the same picture at the new bottom), and a tap on
/// the first dock icon: the agent names an app frontmost, and the screen changes. Emits `resized`, `dock`, `tapLanded`.
@MainActor func resize(
    _ d: Device,
    to panel: String,
    boot: (Int) async -> Void,
    shutdown: (Int) async -> Void
) async {
    d.process.terminate()  // Apply on a running device: the app's Stop (a hard halt), then a fresh helper
    let exited = await d.process.waitForExit(timeout: 30)
    emit(
        "quit",
        ["device": d.name, "generation": 1, "hard": true, "exited": exited, "reason": d.process.deathReason ?? ""]
    )
    await d.services.stopWorker()
    d.mux.stop()
    d.serial?.removeEndpoints()
    d.panel = panel
    await boot(2)
    let want = Board.panelScan(panel) ?? .zero
    let surface = d.process.link.frontSurface()?.surface
    emit(
        "resized",
        [
            "device": d.name, "width": surface?.width ?? 0, "height": surface?.height ?? 0,
            "wantWidth": Int(want.width), "wantHeight": Int(want.height),
        ]
    )
    // The dock: the bottom fifth of the shipped screen, then and now (the same width, so the same picture).
    let before = d.dir.appendingPathComponent("home.png")
    let after = d.dir.appendingPathComponent("home2.png")
    let band = d.profile.screenPixels.height / 5
    emit(
        "dock",
        ["device": d.name, "rows": Int(band), "differs": DockBand.differs(before, after, rows: Int(band)) ?? -1]
    )
    // A tap on the first dock icon, half a dock above the bottom edge. A first boot's "Edit Home Screen" tip (an
    // alert centered on the new screen) is dismissed first, as launch() does at 320x480: its button sits in a gap
    // between icons when there is no tip.
    let agent = GuestAgent(link: d.process.link, cache: GuestAgentCache())
    let points = Double(want.height) * 320 / Double(want.width)
    await d.tap(0.5, (345 + (points - 480) / 2) / points)
    try? await Task.sleep(for: .seconds(2))
    d.screenshot("tip")
    let y = 1 - Double(band) / 2 / Double(want.height)
    await d.tap(1 / 8, y)
    try? await Task.sleep(for: .seconds(6))
    let front = try? await agent.frontmost()
    let tapped = await d.wakeForShot("tapped") == nil ? nil : d.dir.appendingPathComponent("tapped.png")
    emit(
        "tapLanded",
        [
            "device": d.name, "x": 1.0 / 8, "y": y, "frontmost": front?.bundleID ?? "", "screen": front?.name ?? "",
            "changed": tapped.flatMap { DockBand.differs(after, $0, rows: Int(want.height)) } ?? -1,
        ]
    )
    d.process.link.send(.button(0, down: true))
    try? await Task.sleep(for: .milliseconds(150))
    d.process.link.send(.button(0, down: false))
    try? await Task.sleep(for: .seconds(3))
    await shutdown(2)
}

/// The share of 8 x 8-pixel blocks of two captures' bottom `rows` that differ (any channel's mean by more than 24):
/// nil when either can't be read or they are not the same width.
enum DockBand {
    static func differs(_ a: URL, _ b: URL, rows: Int) -> Double? {
        guard let x = bottom(a, rows: rows), let y = bottom(b, rows: rows), x.width == y.width else { return nil }
        let w = x.width / 8
        let h = rows / 8
        var differing = 0
        for by in 0..<h {
            for bx in 0..<w {
                for c in 0..<3 {
                    var sa = 0
                    var sb = 0
                    for yy in by * 8..<by * 8 + 8 {
                        for xx in bx * 8..<bx * 8 + 8 {
                            sa += Int(x.bytes[(yy * x.width + xx) * 4 + c])
                            sb += Int(y.bytes[(yy * y.width + xx) * 4 + c])
                        }
                    }
                    if abs(sa - sb) / 64 > 24 {
                        differing += 1
                        break
                    }
                }
            }
        }
        return w * h == 0 ? nil : Double(differing) / Double(w * h)
    }

    /// The bottom `rows` of a PNG as RGBX.
    static func bottom(_ url: URL, rows: Int) -> (width: Int, bytes: [UInt8])? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.height >= rows,
            let crop = image.cropping(to: CGRect(x: 0, y: image.height - rows, width: image.width, height: rows))
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: crop.width * rows * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: crop.width,
                    height: rows,
                    bitsPerComponent: 8,
                    bytesPerRow: crop.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                )
            else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: rows))
            return true
        }
        return drawn ? (crop.width, bytes) : nil
    }
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
        s.incrementUseCount()
        s.lock(options: .readOnly, seed: nil)
        defer {
            s.unlock(options: .readOnly, seed: nil)
            s.decrementUseCount()
        }
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
        var navy = 0
        var n = 0
        for y in stride(from: 0, to: alert.y1 - alert.y0, by: 4) {
            for x in stride(from: 0, to: w, by: 4) {
                let i = (y * w + x) * 4
                let b = Int(px[i])
                let r = Int(px[i + 2])
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
            d.process.link.send(.button(0, down: true))
            try? await Task.sleep(for: .milliseconds(150))
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
        var white = 0
        var n = 0
        for i in stride(from: 0, to: px.count, by: 16) {
            n += 1
            if px[i] > 225 && px[i + 1] > 225 && px[i + 2] > 225 { white += 1 }
        }
        return n == 0 ? 0 : Double(white) / Double(n)
    }
    static func appleIDUp(_ d: Device) -> Bool { SetupPages.kind(fingerprint(d)) == "apple id" }

    /// A Setup page's fingerprint: the white fraction of seven boxes (the two button columns and the gap between them,
    /// a strip left of the center art, the iPad outline's left edge, the center, the left list column), measured on
    /// 5.0 beta 1 to 5.1.1.
    static let printBoxes: [Box] = [
        (795, 170, 830, 600), (860, 170, 895, 600), (840, 170, 852, 600),
        (180, 300, 230, 450), (255, 300, 285, 450), (330, 300, 560, 450), (100, 150, 135, 700),
    ]
    static func fingerprint(_ d: Device) -> [Double] { printBoxes.map { whiteFraction(d, $0) } }

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
        let nx = Double(x) / 1024
        let ny = Double(y) / 768
        d.process.link.send(.touch(slot: 0, phase: 0, x: nx, y: ny))
        try? await Task.sleep(for: .seconds(hold))
        d.process.link.send(.touch(slot: 0, phase: 2, x: nx, y: ny))
    }

    /// From the first Setup page (the driver has already slid "slide to set up"): (walked, detail). Each page is
    /// entered only once its title bar has settled and differs from the page before (the previous Next landed);
    /// each tap is retried inside a per-page budget scaled from the board's boot budget (the iPad's 300 s: 120 s).
    static func walk(_ d: Device) async -> (Bool, String) {
        var walked: [String] = []
        var lastTitle: [UInt8]? = nil
        let budget = d.profile.bootBudget / 2.5
        var skipTo: Int? = nil
        page: for (index, (name, taps)) in pages.enumerated() {
            if let skipTo, index < skipTo {
                walked.append("\(name) (absent)")
                continue
            }
            await wake(d)
            if let lastTitle {  // the previous page's Next took: wait for this page's title to replace it
                let t0 = Date()
                while Date().timeIntervalSince(t0) < budget, await settled(d, title) == lastTitle { await wake(d) }
            }
            // The page on screen decides, not the list's order: 5.0 beta 1 opens on Set Up iPad (no language,
            // country, location or Wi-Fi pages), 5.1.1 drops Apple ID after "Continue without Wi-Fi?" and 5.0.1 keeps it.
            // Wait for this step's page, or skip ahead to a later step whose page is showing.
            if let want = SetupPages.kind(of: name) {
                let t0 = Date()
                var seen: String? = nil
                var unknown = 0
                while Date().timeIntervalSince(t0) < budget {
                    _ = await settled(d, title)
                    seen = SetupPages.kind(fingerprint(d))
                    if seen == want { break }
                    if let seen,
                        let later = pages.indices.first(where: {
                            $0 > index && SetupPages.kind(of: pages[$0].0) == seen
                        })
                    {
                        walked.append("\(name) (absent)")
                        skipTo = later
                        continue page
                    }
                    // Terms has no fingerprint: a lit, settled page nothing recognizes, read twice, is it when it is the
                    // next step (5.1.1 goes Wi-Fi -> Terms without Apple ID)
                    unknown = seen == nil && (d.brightness() ?? 0) > 0.05 ? unknown + 1 : 0
                    if unknown >= 2, index + 1 < pages.count, SetupPages.kind(of: pages[index + 1].0) == nil {
                        walked.append("\(name) (absent)")
                        continue page
                    }
                    await wake(d)
                    try? await Task.sleep(for: .seconds(2))
                }
                guard seen == want else {
                    d.screenshot("setup-\(name.replacingOccurrences(of: " ", with: "-"))-unknown")
                    return (
                        false,
                        "the \(name) page never showed in \(Int(budget)) s (screen: \(seen ?? "unrecognized"); after \(walked.joined(separator: ", ")))"
                    )
                }
            }
            if name == "wi-fi" { try? await Task.sleep(for: .seconds(15)) }  // give the join time before Next
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
                let ok = await SetupPages.tapUntil(
                    budget: isAlert || optional ? 60 : budget,
                    every: 20,
                    tap: { await tap(d, t.x, t.y, hold: t.hold) },
                    answered: answered
                )
                // Terms' button highlight can look like a page transition. Let
                // it settle before deciding that Agree advanced without an alert.
                if name == "terms", i == 0, ok {
                    try? await Task.sleep(for: .seconds(3))
                    if !alertUp(d), SetupPages.kind(fingerprint(d)) == nil {
                        await tap(d, t.x, t.y, hold: 0.3)
                        try? await Task.sleep(for: .seconds(3))
                    }
                    d.screenshot("terms-retry")
                }
                if isAlert, ok, !alertUp(d) {
                    lastTitle = pageTitle
                    walked.append(name + " (no alert)")
                    continue page
                }
                if !ok, optional { continue }
                // 5.0 beta 5 has no Terms page: its Agree tap (an empty corner elsewhere) raises no alert
                if !ok, name == "terms", i == 0 {
                    walked.append("terms (absent)")
                    continue page
                }
                guard ok else {
                    return (
                        false,
                        "the \(name) page did not answer tap \(i + 1) in \(Int(isAlert ? 60 : budget)) s (after \(walked.joined(separator: ", ")))"
                    )
                }
                if t.box == title { lastTitle = pageTitle }
            }
            if name == "wi-fi", alertUp(d) {  // "Continue without Wi-Fi?": no join (the Apple ID page may still follow)
                let ref = await settled(d, title)
                _ = await SetupPages.tapUntil(
                    budget: budget,
                    every: 20,
                    tap: { await tap(d, wifiContinue.0, wifiContinue.1) },
                    answered: { region(d, title) != ref }
                )
                lastTitle = ref
                walked.append("wi-fi (not joined: continued without)")
            } else {
                walked.append(name)
            }
        }
        return (true, "walked \(walked.joined(separator: ", "))")
    }
}

/// The Files window's Apps source, through its own calls (DeviceServices.app: house_arrest's VendContainer): the
/// installed app's container listed, Documents made where installd made none, a file copied into Documents and back,
/// read by the guest agent from inside the app's container, renamed, a folder made with a file in it, and both
/// deleted. On a jailbroken device afc2 shows the same file at the container's path under "/". Emits `appFiles`.
@MainActor func appFiles(_ d: Device, agent hasAgent: Bool, jailbreak: Bool) async {
    var services = d.services
    services.app = config.bundleID
    let guest = GuestAgent(link: d.process.link, cache: GuestAgentCache())
    let alive = hasAgent ? await guest.waitAlive(seconds: 30) : false
    let home = alive ? await container(guest, config.bundleID) : nil
    var event: [String: Any] = ["device": d.name, "agent": alive, "container": home ?? ""]
    let bytes = Data((0..<70_001).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 7) })
    let local = d.dir.appendingPathComponent("ltm-app-file.bin")
    let back = d.dir.appendingPathComponent("back-ltm-app-file.bin")
    defer {
        try? FileManager.default.removeItem(at: local)
        try? FileManager.default.removeItem(at: back)
    }
    func names(_ path: String) async throws -> [String] { try await services.files(in: path).map(\.name) }
    func read(_ path: String) async -> Data? {
        guard let home else { return nil }
        return try? await guest.get("\(home)/\(path)")
    }
    func absent(_ path: String) async -> Bool {
        guard let home else { return false }
        do { return try await guest.get("\(home)/\(path)") == nil } catch { return false }
    }
    do {
        let top = try await names("")
        event["top"] = top
        if !top.contains("Documents") {
            try await services.makeFolder("Documents")
            event["madeDocuments"] = true
        }
        try bytes.write(to: local)
        try await services.uploadFile(local, into: "Documents") { _ in }
        guard let file = try await services.files(in: "Documents").first(where: { $0.name == local.lastPathComponent })
        else { throw DeviceError.preflight("the copy isn't listed in Documents") }
        try await services.download(file, to: back) { _ in }
        event["listed"] = Int(file.size) == bytes.count
        event["same"] = try Data(contentsOf: back) == bytes
        if home != nil {
            let read = await read("Documents/\(file.name)")
            event["agentRead"] = read == bytes
        }
        if jailbreak, let home {
            var root = d.services
            root.wholeFileSystem = true
            let path = String(home.drop { $0 == "/" }) + "/Documents"
            event["afc2"] = (try? await root.files(in: path).map(\.name).contains(file.name)) ?? false
        }
        try await services.rename("Documents/\(file.name)", to: "ltm-renamed.bin")
        let renamed = try await names("Documents")
        event["renamed"] = renamed.contains("ltm-renamed.bin") && !renamed.contains(file.name)
        if home != nil {
            let read = await read("Documents/ltm-renamed.bin")
            event["agentRenamed"] = read == bytes
        }
        try await services.makeFolder("Documents/LTM Folder")
        try await services.uploadFile(local, into: "Documents/LTM Folder") { _ in }
        event["folder"] = try await names("Documents/LTM Folder") == [file.name]
        try await services.delete("Documents/ltm-renamed.bin")
        try await services.delete("Documents/LTM Folder")
        let left = try await names("Documents")
        event["deleted"] = !left.contains("ltm-renamed.bin") && !left.contains("LTM Folder")
        if home != nil {
            let file = await absent("Documents/ltm-renamed.bin")
            let folder = await absent("Documents/LTM Folder/\(local.lastPathComponent)")
            event["agentDeleted"] = file && folder
        }
    } catch { event["error"] = "\(error)" }
    emit("appFiles", event)
}

/// Cydia on a jailbroken device: in SpringBoard's icon state, then launched through the guest agent and frontmost,
/// and Home again. Emits `cydia`.
@MainActor func cydia(_ d: Device) async {
    let id = "com.saurik.Cydia"
    var event: [String: Any] = ["device": d.name]
    do { event["onHome"] = try await d.services.homeScreenOrder().contains(id) } catch {
        event["homeError"] = "\(error)"
    }
    let agent = GuestAgent(link: d.process.link, cache: GuestAgentCache())
    if await agent.waitAlive(seconds: 20) {
        do { try await agent.launch(id) } catch { event["launchError"] = "\(error)" }
        for (i, wait) in [8, 12, 20].enumerated() {
            try? await Task.sleep(for: .seconds(wait))
            if let path = d.screenshot("cydia\(i + 1)") { event["shot\(i + 1)"] = path }
            event["frontmost\(i + 1)"] = (try? await agent.frontmost())?.bundleID ?? ""
        }
    } else {
        event["launchError"] = "no guest agent"
    }
    emit("cydia", event)
    d.process.link.send(.button(0, down: true))
    try? await Task.sleep(for: .milliseconds(150))
    d.process.link.send(.button(0, down: false))
    try? await Task.sleep(for: .seconds(3))
}

/// installd's own record of where each app lives (iOS 2-5): the container an upgrade must keep.
@MainActor func container(_ agent: GuestAgent, _ id: String) async -> String? {
    guard let data = try? await agent.get("/var/mobile/Library/Caches/com.apple.mobile.installation.plist"),
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
        let app = (plist["User"] as? [String: Any])?[id] as? [String: Any]
    else { return nil }
    return (app["Container"] as? String) ?? (app["Path"] as? String).map { ($0 as NSString).deletingLastPathComponent }
}

/// Install `ipa` over the installed config.bundleID, as the app's install does (stage + installation_proxy).
@MainActor func upgradeInPlace(_ d: Device, _ ipa: String) async {
    let agent = GuestAgent(link: d.process.link, cache: GuestAgentCache())
    var event: [String: Any] = ["device": d.name]
    let alive = await agent.waitAlive(seconds: 30)
    let before = alive ? await container(agent, config.bundleID) : nil
    let marker = Data("kept across the upgrade\n".utf8)
    var file: String?  // Documents where installd made one (not every version does before a first launch), else Library
    for dir in ["Documents", "Library"] where file == nil {
        guard let before else { break }
        do {
            try await agent.put("\(before)/\(dir)/ltm-upgrade.txt", mode: 0o644, marker)
            file = "\(dir)/ltm-upgrade.txt"
        } catch { event["markerError"] = "\(error)" }
    }
    event["marker"] = file ?? ""
    do {
        let staged = try await d.services.stage(URL(fileURLWithPath: ipa)) { _ in }
        try await d.services.install(URL(fileURLWithPath: ipa), staged: staged, bundleID: config.bundleID) { _, _ in }
        await d.services.removeStaged(staged)
        event["error"] = ""
    } catch { event["error"] = "\(error)" }
    let apps = (try? await d.services.installedApps()) ?? []
    event["version"] = apps.first { $0.id == config.bundleID }?.version ?? ""
    let after = alive ? await container(agent, config.bundleID) : nil
    event["before"] = before ?? ""
    event["after"] = after ?? ""
    if let after, let file {
        event["kept"] = (try? await agent.get("\(after)/\(file)")) == marker
    } else {
        event["kept"] = false
    }
    emit("upgraded", event)
}

/// A phone's Setup Assistant (6.x and 7.x on the iPod touch 4G, iPhone 4 and 3GS), walked as qemu-ios
/// tests/ipad1/app-install.py walk_setup does: Vision reads each page's labels off a screenshot; an alert's
/// button labeled exactly as one of `alertYes` goes first, then the first of `picks` the page shows, then its
/// Next (the language page's is an arrow, top right). The welcome page (SpringBoard's "slide to set up", in a
/// rotating language) has none of those and is slid. Done when the agent says the home screen is up.
@MainActor enum SetupPhone {
    /// Each label Vision reads on the screenshot, at its center as a touch point (top-left origin, 0...1).
    static func labels(_ path: String) -> [String: (x: Double, y: Double)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        guard (try? VNImageRequestHandler(url: URL(fileURLWithPath: path)).perform([request])) != nil else {
            return [:]
        }
        var found: [String: (x: Double, y: Double)] = [:]
        for o in request.results ?? [] {
            guard let text = o.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces) else { continue }
            found[text] = found[text] ?? (o.boundingBox.midX, 1 - o.boundingBox.midY)
        }
        return found
    }

    static func walk(_ d: Device, agent: GuestAgent, generation: Int) async -> (Bool, String) {
        var pages: [String] = []
        // 80 pages: 7.x's Apple ID page ignores Skip This Step while its spinner runs (about a minute: 12-13 tries),
        // and 7.x's country list takes 12-15 scrolls to United States. The boot's 1400 s cap still bounds it.
        for n in 0..<80 {
            try? await Task.sleep(for: .seconds(3))
            if let f = try? await agent.frontmost(), f.bundleID == "com.apple.springboard", f.name == "Home Screen" {
                return (true, "Setup walked: " + pages.joined(separator: ", "))
            }
            // LTM_SETUP_SHEET_PROBE=1 (a live check of the sheet path): once past the welcome page, press Home in Setup,
            // which opens the Emergency Call / Start Over sheet over the page; the walk must dismiss it and go on.
            if ProcessInfo.processInfo.environment["LTM_SETUP_SHEET_PROBE"] == "1", !pages.contains("(sheet probe)"),
                n > 0,
                let f = try? await agent.frontmost(), f.name != "Lock Screen"
            {
                d.process.link.send(.button(0, down: true))
                try? await Task.sleep(for: .milliseconds(150))
                d.process.link.send(.button(0, down: false))
                try? await Task.sleep(for: .seconds(1.5))
                pages.append("(sheet probe)")
            }
            guard let shot = await d.wakeForShot("setup\(generation)-\(n)") else { continue }
            for step in SetupPlan.plan(labels(shot), pages: pages) {
                switch step {
                case .tap(let x, let y, let log):
                    await d.tap(x, y)
                    if let log { pages.append(log) }
                    if log?.hasPrefix("(") == true, ProcessInfo.processInfo.environment["LTM_SETUP_BURST"] == "1" {
                        await burst(d, "setup\(generation)-\(n)-burst")
                    }
                case .pause(let seconds):
                    try? await Task.sleep(for: .seconds(seconds))
                case .scroll(let y0, let y1, let fast):
                    if fast {  // four moves in 64 ms: a fling the list carries on
                        let link = d.process.link
                        link.send(.touch(slot: 0, phase: 0, x: 0.5, y: y0))
                        for i in 1...4 {
                            try? await Task.sleep(for: .milliseconds(16))
                            link.send(.touch(slot: 0, phase: 1, x: 0.5, y: y0 + (y1 - y0) * Double(i) / 4))
                        }
                        link.send(.touch(slot: 0, phase: 2, x: 0.5, y: y1))
                    } else {
                        await d.drag(0.5, y0, 0.5, y1)
                    }
                    pages.append("(scroll)")
                case .slideIfLockScreen:
                    guard (try? await agent.frontmost())?.name == "Lock Screen" else { break }
                    // The welcome page (SpringBoard's lock screen) and its slider. Home first, as app-install's unlock():
                    // the S5L8920 boards power the digitizer down on the lock screen (DisablePowerForUILock), and a slide
                    // then does nothing (n88 6.0.1: 40 slides, still welcome). Only there: in Setup, Home opens a sheet.
                    d.process.link.send(.button(0, down: true))
                    try? await Task.sleep(for: .milliseconds(150))
                    d.process.link.send(.button(0, down: false))
                    try? await Task.sleep(for: .seconds(1.5))
                    await d.drag(0.18, 0.9, 0.92, 0.9)
                    pages.append("(slide)")
                }
            }
        }
        return (false, "Setup still up after 80 pages: " + pages.joined(separator: ", "))
    }

    /// Every new frame for 8 s after an alert's button (LTM_SETUP_BURST=1, issue 46): a PNG each and the status bar's
    /// mean level (its top 20/480 rows). `flips` counts frames whose level jumps against the step before it (both steps
    /// over 1): a status bar alternating between a stale and a current display buffer.
    static func burst(_ d: Device, _ label: String) async {
        var last: UInt64 = 0
        var levels: [Double] = []
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 8 {
            if let f = d.process.link.frontSurface(), f.serial != last {
                last = f.serial
                let s = f.surface
                s.lock(options: .readOnly, seed: nil)
                let rows = s.height * 20 / 480
                let bytes = UnsafeRawBufferPointer(start: s.baseAddress, count: s.bytesPerRow * rows)
                levels.append(Double(bytes.reduce(0) { $0 + Int($1) }) / Double(bytes.count))
                s.unlock(options: .readOnly, seed: nil)
                d.screenshot("\(label)-\(levels.count)")
            }
            try? await Task.sleep(for: .milliseconds(4))
        }
        let steps = zip(levels.dropFirst(), levels).map { $0 - $1 }
        let flips = zip(steps.dropFirst(), steps).filter { abs($0) > 1 && abs($1) > 1 && $0 * $1 < 0 }.count
        emit("burst", ["device": d.name, "label": label, "frames": levels.count, "flips": flips, "levels": levels])
    }
}
