import Foundation
import SessionKit

/// helper-driver (DeviceLink straight to the helper) running one scenario in work/<name>.
final class HelperDriver {
    let name: String, dir: URL, log: URL
    let driver: DriverProcess

    init(
        _ name: String,
        tools: Tools,
        helper: URL? = nil,
        work: URL,
        scenario: [String: Any],
        extra: [String] = [],
        environment: [String: String] = [:]
    ) {
        self.name = name
        dir = work.appendingPathComponent(name)
        log = dir.appendingPathComponent("native.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var scenario = scenario
        if scenario["dylib"] == nil { scenario["dylib"] = tools.dylib.path }
        let file = dir.appendingPathComponent("scenario.json")
        try? JSONSerialization.data(withJSONObject: scenario, options: [.prettyPrinted, .sortedKeys]).write(to: file)
        driver = DriverProcess(
            "helper-driver",
            [
                "--helper", (helper ?? tools.helper).path, "--scenario", file.path, "--dump", dir.path,
                "--log", log.path, "--requirement", Tools.teamRequirement,
            ] + extra,
            out: dir.appendingPathComponent("driver.jsonl"),
            environment: environment
        )
    }
    var events: Events { driver.events }
    var nativeLog: String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
    var tail: String { events.all.suffix(12).map { "\($0)" }.joined(separator: "\n") }
    /// Waits, then kills whatever it started that is still alive.
    @discardableResult
    func finish(_ seconds: Double) -> Int32? {
        let status = driver.wait(seconds)
        killLeftovers(events)
        return status
    }
}

/// A prepared base booted by helper-driver as the app boots it (PreparedDeviceBoot with the hello's machine facts).
func preparedScenario(
    _ base: Base,
    tools: Tools,
    work: URL,
    name: String,
    steps: [String],
    carrier: [String: Any]? = nil
) -> [String: Any] {
    let dir = work.appendingPathComponent(name)
    var prepared: [String: Any] = [
        "base": base.url.path, "overlay": dir.appendingPathComponent("overlay").path,
        "serial": dir.appendingPathComponent("serial.log").path, "files": tools.files.path,
    ]
    if let carrier { prepared["carrier"] = carrier }
    return ["board": base.board, "prepared": prepared, "steps": steps]
}

let unlockSlide = "drag 0.18 0.9 0.92 0.9"  // a phone's or iPod's lock-screen slider, portrait

/// SIGKILL the driver (the "app") once it holds: the helper must notice, hard-halt (pause, flush, quit QEMU; no guest
/// shutdown) and exit.
func parentKill(_ d: HelperDriver, _ r: Report, budget: Double) {
    guard let hold = d.driver.waitFor("hold", 400) else {
        r.check(false, "\(d.name): reached hold")
        print(d.tail)
        return
    }
    let helper = hold.int("helperPid") ?? 0
    kill(d.driver.pid, SIGKILL)
    d.driver.process.waitUntilExit()
    let gone = waitGone(helper, budget)
    r.check(gone != nil, "\(d.name): the helper exited \(format(gone)) s after the parent died")
    if gone == nil { kill(pid_t(helper), SIGKILL) }
    let log = d.nativeLog
    r.check(
        log.contains("halt: parent exited") || log.contains("halt: link closed"),
        "\(d.name): the helper noticed the parent's death"
    )
    r.check(
        !log.contains("did not return") && !log.contains("powerdown"),
        "\(d.name): hard halt (paused, storage flushed, QEMU quit; no guest shutdown)"
    )
}

/// `sessions helper`: the helper without a guest. An ad-hoc re-signed helper is refused by the Team requirement; two
/// helpers on one device's lease (the second refused, another device's not, the lease taken again once the holder's
/// parent dies); the lease admission cases (ordinary and external leases, busy, pending edit and symlink refused), a
/// kill before hello and a preparation failure, each reaped exactly once with its lease released.
func helperChecks(_ args: HelperCheck) -> Never {
    let work = workDirectory(args.inputs, "helper")
    let tools = Tools.resolve(args.inputs, work: work)
    let r = Report()

    print("reject")
    let impostor = work.appendingPathComponent("LightTouchDevice-adhoc")
    let entitlements = work.appendingPathComponent("helper.entitlements")
    try? FileManager.default.copyItem(at: tools.helper, to: impostor)
    try? output("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", tools.helper.path]).write(
        to: entitlements,
        atomically: true,
        encoding: .utf8
    )
    run("/usr/bin/codesign", ["-f", "-o", "runtime", "-s", "-", "--entitlements", entitlements.path, impostor.path])
    let reject = HelperDriver(
        "reject",
        tools: tools,
        helper: impostor,
        work: work,
        scenario: ["steps": [String]()],
        extra: ["--expect-reject"]
    )
    let rejected = reject.finish(30) == 0
    let rejectOutput = (try? String(contentsOf: reject.driver.out, encoding: .utf8)) ?? ""
    r.check(
        rejected && rejectOutput.contains("requirement failed"),
        "an ad-hoc re-signed helper is refused at the rendezvous"
    )

    print("lease")
    let state = work.appendingPathComponent("lease-state")
    let lease = state.appendingPathComponent("Devices/\(UUID().uuidString)/work/lease").path
    let other = state.appendingPathComponent("Devices/\(UUID().uuidString)/work/lease").path
    let a = HelperDriver("lease-a", tools: tools, work: work, scenario: ["steps": ["hold"]], extra: ["--lease", lease])
    let holding = a.driver.waitFor("hold", 30)
    r.check(holding != nil, "the first helper takes the lease and connects")
    let b = HelperDriver(
        "lease-b",
        tools: tools,
        work: work,
        scenario: ["steps": [String]()],
        extra: ["--lease", lease, "--expect-failure", "in use by another copy of Light Touch"]
    )
    r.check(b.finish(30) == 0, "a second helper on the same device is refused")
    let o = HelperDriver(
        "lease-other",
        tools: tools,
        work: work,
        scenario: ["steps": [String]()],
        extra: ["--lease", other]
    )
    r.check(o.finish(30) == 0 && o.events.any("connected"), "another device's helper connects meanwhile")
    let holder = a.events.one("connected").int("pid") ?? 0
    kill(a.driver.pid, SIGKILL)
    a.driver.process.waitUntilExit()
    r.check(holder > 0 && waitGone(holder, 60) != nil, "the holder exits after its parent dies")
    killLeftovers(a.events)
    let c = HelperDriver(
        "lease-c",
        tools: tools,
        work: work,
        scenario: ["steps": [String]()],
        extra: ["--lease", lease]
    )
    r.check(c.finish(30) == 0 && c.events.any("connected"), "the lease is taken again once released")

    // session-driver's hello-only modes: each verifies itself and exits 0.
    for (mode, verified, what) in [
        (
            "leaseAdmission", "leaseAdmissionVerified",
            "lease admission: ordinary and external admitted; busy, pending and symlink refused before hello"
        ),
        ("killBeforeBoot", "killBeforeBootVerified", "a helper killed before hello is reaped once, its lease free"),
        (
            "preparationFailure", "preparationFailureVerified",
            "a preparation failure after hello keeps its diagnostic; helper reaped, lease released, nothing published"
        ),
    ] {
        print(mode)
        let dir = work.appendingPathComponent(mode)
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("work"),
            withIntermediateDirectories: true
        )
        var config = driverConfig(tools, work: dir.appendingPathComponent("work"))
        config[mode] = true
        config["timeout"] = 65
        let (e, status) = sessionDriver(
            config,
            work: dir.appendingPathComponent("work"),
            timeout: 65,
            environment: driverEnvironment(tools)
        )
        let checks = e.find(verified)
        r.check(
            status == 0 && !checks.isEmpty && checks.allSatisfy { !$0.bool("guestStarted") },
            what
                + (status == 0
                    ? "" : ": \(e.one("fail").string("why") ?? "exit \(status.map(String.init) ?? "timeout")")")
        )
    }
    finish(r, work: work)
}

/// `sessions helper-boot BASE` (an n72 base): the helper booting a guest with no app around it. `ipod`: lit through the
/// frame ring, the slider, rotation (the landscape Home screen is shown), a battery request, then the parent SIGKILLed:
/// hard halt. `meddle`: the app's DeviceFileWatch on the overlay sees its NOR unlinked under the
/// running helper (the app's notice); SIGTERM halts the helper. `power`: the pump at 60 Hz before boot (30 with the host
/// constrained); shown 60 Hz with an idle-sleep assertion, hidden at most 5 Hz and none, back to 60 Hz within 100 ms,
/// paused at most 5 Hz and none, resumed 60 Hz, the guest's display asleep at most 5 Hz, woken 60 Hz again. `--only a,b`
/// picks cases.
func helperBoot(_ args: HelperBootCheck) -> Never {
    let base = Base(args.base)
    guard base.board == "n72ap" else { die("helper-boot boots an n72ap base") }
    let work = workDirectory(args.inputs, "helper-boot")
    let tools = Tools.resolve(args.inputs, work: work)
    let only = Set(args.only.split(separator: ",").map(String.init))
    let r = Report()

    if only.contains("ipod") {
        print("ipod")
        let d = HelperDriver(
            "ipod",
            tools: tools,
            work: work,
            scenario: preparedScenario(
                base,
                tools: tools,
                work: work,
                name: "ipod",
                steps: [
                    "boot", "lit 0.03 240", "dump lock", unlockSlide, "wait 4", "dump home", "rotate cw", "wait 2",
                    "dump rotated",
                    "rotate ccw", "wait 2", "battery 50 0", "wait 2", "status", "hold",
                ]
            )
        )
        parentKill(d, r, budget: 10)
        let e = d.events
        r.check(e.any("lit"), "ipod: lit through the ring after \(format(e.one("lit").double("seconds"))) s")
        var dumps: [String: Event] = [:]
        for x in e.find("dump") { dumps[x.string("name") ?? ""] = x }
        r.check(dumps["home"]?.bool("ok") == true && dumps["lock"]?.bool("ok") == true, "ipod: lock and home dumps")
        // The rotated Home screen is one new frame: a frame the ring dropped would stay black.
        let rotated = dumps["rotated"] ?? [:]
        let home = dumps["home"] ?? [:]
        r.check(
            rotated.int("width") == 480 && (rotated.double("brightness") ?? 0) > 0.5 * (home.double("brightness") ?? 1),
            "ipod: the rotated Home screen is shown (\(rotated.int("width") ?? 0)x\(rotated.int("height") ?? 0), brightness "
                + "\(format(rotated.double("brightness"), 2)) vs \(format(home.double("brightness"), 2)))"
        )
        r.check(
            e.find("reply").contains { ($0.string("reply") ?? "").contains("ok(true)") },
            "ipod: battery request -> ok(true)"
        )
        // The agent through the link is `sessions single`'s (frontmost, launch, file read-back): it needs the USB host
        // and the package offer this bare boot leaves out.
    }
    if only.contains("meddle") {
        print("meddle")
        let overlay = work.appendingPathComponent("meddle/overlay")
        let d = HelperDriver(
            "meddle",
            tools: tools,
            work: work,
            scenario: preparedScenario(
                base,
                tools: tools,
                work: work,
                name: "meddle",
                steps: [
                    "boot", "lit 0.03 240", "wait 3", "watch \(overlay.path)", "hold",
                ]
            )
        )
        if let hold = d.driver.waitFor("hold", 400), r.check(true, "meddle: lit and holding with the overlay watched") {
            let helper = hold.int("helperPid") ?? 0
            r.check(
                (d.events.one("watching").int("count") ?? 0) >= 2,
                "meddle: the watch covers the overlay and its files"
            )
            // the writable NOR QEMU has open
            try? FileManager.default.removeItem(at: overlay.appendingPathComponent("nor.bin"))
            let m = d.driver.waitFor("meddled", 5)
            r.check(
                (m?.string("path") ?? "").hasSuffix("nor.bin")
                    && (m?.string("notice") ?? "").hasPrefix("Files of this iPod were changed while it was running."),
                "meddle: the watch reported \(m?.string("path") ?? "nothing") with the app's notice"
            )
            r.check(
                alive(helper) && d.driver.process.isRunning,
                "meddle: the helper and guest kept running on the unlinked inode"
            )
            kill(pid_t(helper), SIGTERM)
            let gone = waitGone(helper, 15)
            r.check(gone != nil, "meddle: SIGTERM, the helper exited \(format(gone)) s later")
            r.check(d.nativeLog.contains("halt:"), "meddle: the helper logged its halt")
            kill(d.driver.pid, SIGKILL)
            d.finish(5)
        } else {
            r.check(false, "meddle: lit and holding")
            print(d.tail)
            d.finish(1)
        }
    }
    if only.contains("power") {
        print("power")
        for (name, env, low, high) in [
            ("power-free", [String: String](), 50.0, 65.0),
            ("power-constrained", ["LTM_HOST_CONSTRAINED": "1"], 25, 33),
        ] {
            let d = HelperDriver(
                name,
                tools: tools,
                work: work,
                scenario: ["steps": ["wait 1", "sample preboot 3"]],
                environment: env
            )
            let hz = d.finish(60) == 0 ? d.events.one("sample").double("hz") ?? -1 : -1
            r.check(low <= hz && hz <= high, "\(name): the pump at \(format(hz)) Hz before boot")
        }
        // Unlocked first: the lock screen's display sleeps within seconds, the Home screen's not for a minute.
        var steps = [
            "boot", "lit 0.03 300", "wait 2", "button 0", "wait 2", unlockSlide, "wait 3", "sample shown 5",
            "pause", "wait 1", "sample paused 3", "unpause", "wait 1", "sample resumed 2",
            "visible off", "sample hidden 5",
        ]
        // Shown again 40-240 ms before the next 4 Hz tick (hidden starts its ticks when the command lands).
        for gap in [0.51, 0.56, 0.61, 0.66, 0.71] { steps += ["visible on", "wait 0.5", "visible off", "wait \(gap)"] }
        steps += [
            "visible on", "button 1", "waitSleep 20", "wait 3", "sample asleep 5", "button 1", "wait 1",
            "sample woken 2", "quit", "expectExit 60",
        ]
        let d = HelperDriver(
            "power",
            tools: tools,
            work: work,
            scenario: preparedScenario(base, tools: tools, work: work, name: "power", steps: steps)
        )
        r.check(d.finish(500) == 0, "power: scenario completed")
        var s: [String: Event] = [:]
        for x in d.events.find("sample") { s[x.string("label") ?? ""] = x }
        for label in ["shown", "hidden", "asleep", "woken", "paused", "resumed"] {
            let x = s[label] ?? [:]
            print(
                "   \(label): \(format(x.double("hz"))) Hz, \(format(x.double("fps"))) fps, \(format(x.double("cpuPercent")))% CPU, "
                    + "\(format(x.double("wakeupsPerSecond"))) wakeups/s, \(format(x.double("milliwatts"))) mW, "
                    + "idle-sleep assertion \(x.bool("preventsIdleSleep")), display asleep \(x.bool("displaySleeping"))"
            )
        }
        func rate(_ label: String, _ low: Double, _ high: Double, holds: Bool) -> Bool {
            guard let x = s[label], let hz = x.double("hz") else { return false }
            return low <= hz && hz <= high && x.bool("preventsIdleSleep") == holds
        }
        r.check(rate("shown", 50, 65, holds: true), "power: shown, 60 Hz, holds off idle sleep")
        r.check(rate("hidden", 0.5, 5, holds: false), "power: hidden, at most 5 Hz, lets the Mac idle-sleep")
        r.check(
            s["asleep"]?.bool("displaySleeping") == true && rate("asleep", 0.5, 5, holds: false),
            "power: the guest's display asleep, at most 5 Hz, lets the Mac idle-sleep"
        )
        r.check(rate("woken", 50, 65, holds: true), "power: woken by the power button, 60 Hz again")
        r.check(rate("paused", 0.5, 5, holds: false), "power: paused, at most 5 Hz, lets the Mac idle-sleep")
        r.check(rate("resumed", 50, 65, holds: true), "power: resumed, 60 Hz again")
        let ticks = d.events.find("visible").filter { $0.bool("on") }.prefix(5).compactMap { $0.double("tickMs") }
        r.check(
            ticks.count == 5 && ticks.allSatisfy { 0 <= $0 && $0 < 100 },
            "power: shown again, back at 60 Hz within 100 ms (\(ticks) ms)"
        )
    }
    finish(r, work: work)
}

/// helper-driver's vibrator events as buzzes: when each started and, unless the poll missed its end, how long it ran.
private func vibratorBuzzes(_ events: Events) -> [(start: Double, seconds: Double?)] {
    var buzzes: [(start: Double, seconds: Double?)] = []
    var pulses = 0
    var open = false
    for x in events.find("vibrator") {
        let t = x.double("t") ?? 0
        let next = x.int("pulses") ?? 0
        if open, !x.bool("on") || next > pulses {
            buzzes[buzzes.count - 1].seconds = t - buzzes[buzzes.count - 1].start
            open = false
        }
        // Each start since the last sample; all but a running last one ended unseen (shorter than a frame).
        if next > pulses {
            buzzes += (pulses..<next).map { _ in (start: t, seconds: nil) }
            open = x.bool("on")
        }
        pulses = max(pulses, next)
    }
    return buzzes
}

private func describe(_ buzzes: [(start: Double, seconds: Double?)]) -> String {
    "\(buzzes.count) buzz(es): " + buzzes.map { $0.seconds.map { format($0, 2) + " s" } ?? "?" }.joined(separator: ", ")
}

/// `sessions phone BASE [--overlay DIR]` (an n90, n88 or m68 base): the Carrier panel's path (app -> link ->
/// qemu_ios_ui_modem_set/_status -> the modem), once the boot's CommCenter restarts are over (modemSettle: the
/// status's power-offs and attached): booted registered with saved settings, renamed, a bad MCC/MNC refused,
/// signal moved, an incoming SMS delivered and its tone heard, a call rung (its ringtone heard, through the app's audio
/// capture) and hung up, an unknown property refused, and the vibration motor buzzing for the SMS and while ringing, as
/// the status block reports it (issue 38). `rotate`: a new frame within 1 s of the app's rotation request,
/// different from portrait. `shutdown`: the guest confirms its own power-off. `keyboard` (A4): Connect Hardware Keyboard
/// off and on. A 5.x+ first boot sits in Setup, which rejects calls and stays portrait: the carrier and rotate cases then
/// need --overlay, the overlay of a boot that walked Setup (`sessions single --keep` leaves one in its work
/// directory), cloned, never changed.
/// `emergency` (4.x and 7.x): 911 from the emergency dialer, which asks the modem first (issue 32).
func phone(_ args: PhoneCheck) -> Never {
    let base = Base(args.base)
    guard ["n90ap", "n88ap", "m68ap"].contains(base.board) else { die("phone boots an n90ap, n88ap or m68ap base") }
    let work = workDirectory(args.inputs, "phone")
    let tools = Tools.resolve(args.inputs, work: work)
    var only = Set(args.only.split(separator: ",").map(String.init))
    if base.board != "n90ap" { only.remove("keyboard") }
    let r = Report()
    // A 5.x+ first boot on these boards sits in Setup, which rejects calls and stays portrait (as Rotation.swift's
    // guard): the carrier and rotate cases boot a clone of --overlay instead.
    if base.armv7, base.major >= 5, args.overlay == nil, !only.isDisjoint(with: ["carrier", "rotate"]) {
        die(
            "a \(base.version) base is in Setup on its first boot, which rejects calls and does not turn: pass --overlay (or --only emergency,location,shutdown,keyboard)"
        )
    }
    func cloneOverlay(_ name: String) {
        guard let source = args.overlay else { return }
        let overlay = work.appendingPathComponent("\(name)/overlay")
        try? FileManager.default.createDirectory(
            at: overlay.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        run("/bin/cp", ["-cR", source.path, overlay.path])  // a clone: the source stays as it was
    }

    if only.contains("carrier") {
        print("carrier")
        cloneOverlay("carrier")
        let saved: [String: Any] = [
            "carrier": "Saved, Carrier", "mccMNC": "00101", "registered": true, "simPresent": true, "bars": 4,
        ]
        let d = HelperDriver(
            "carrier",
            tools: tools,
            work: work,
            scenario: preparedScenario(
                base,
                tools: tools,
                work: work,
                name: "carrier",
                steps: [
                    "boot", "lit 0.1 300", "wait 60", "modemSettle 80 240", "dump registered", "modemStatus",
                    "modem incoming-sms +15555550100|hello from the panel", "audio 10", "modemStatus",
                    "modem incoming-call 15555550100", "audio 12", "modemStatus",
                    "modem remote-hangup 1", "wait 3", "modemStatus",
                    // The panel's changes come after the SMS and the call: a rename re-registers (the model's
                    // +CREG 2 then 1, so CommCenter re-reads the name), and on 6.x that new serving network has
                    // imagent re-register iMessage and wait on Apple's servers, sometimes for minutes, taking no
                    // SMS until it is done. No wait before the SMS covered that.
                    "modem carrier Cell Panel", "modem signal-dbm -97", "modem mcc-mnc 001", "wait 1", "modemStatus",
                    "modem no-such-property x", "quit", "expectExit 60",
                ],
                carrier: saved
            )
        )
        r.check(d.finish(600) == 0, "carrier: scenario completed")
        let e = d.events
        // The boot's CommCenter restarts (it_prefs's Data Roaming reload) are over before the panel's steps.
        let settled = e.one("modemSettled")
        r.check(
            !settled.isEmpty && !settled.bool("timedOut"),
            "carrier: the modem settled \(format(settled.double("secondsSinceBoot"), 0)) s after boot "
                + "(new power-offs noticed at \((settled["powerOffsAt"] as? [Double] ?? []).map { format($0, 0) }) s)"
        )
        let st: [Event] = e.find("modemStatus").map {
            ($0.string("json").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? Event) ?? [:]
        }
        var replies: [String: String] = [:]
        for x in e.find("reply") { if let m = x.string("modem") { replies[m] = x.string("reply") ?? "" } }
        if r.check(st.count == 5, "carrier: five statuses (\(st.count))") {
            r.check(
                st[0].string("carrier") == "Saved, Carrier" && st[0].int("signal-dbm") == -81
                    && st[0].string("mcc-mnc") == "00101"
                    && st[0].bool("registered"),
                "carrier: booted registered with the saved settings (\(st[0]))"
            )
            r.check(
                !st[1].has("error") && (replies["incoming-sms"] ?? "").contains("ok(true)"),
                "carrier: the SMS delivered (\(st[1]))"
            )
            r.check(st[2].string("call-state") == "incoming", "carrier: ringing: \(st[2].string("call-state") ?? "")")
            r.check(
                st[4].string("carrier") == "Cell Panel" && st[4].int("signal-dbm") == -97
                    && st[4].string("mcc-mnc") == "00101"
                    && (st[4].string("error") ?? "").contains("mcc-mnc"),
                "carrier: renamed, signal moved, the bad MCC/MNC refused (\(st[4]))"
            )
        }
        // The app's audio capture through each: the SMS tone, then the ringtone (AAC through the A4's AMC).
        let heard = e.find("audioEnded").map { $0.int("loud") ?? 0 }
        if r.check(heard.count == 2, "carrier: two captures (\(heard.count))") {
            r.check(heard[0] > 2000, "carrier: the SMS tone is heard (\(heard[0]) loud samples)")
            r.check(heard[1] > 20000, "carrier: the ringtone is heard (\(heard[1]) loud samples in 12 s of ringing)")
            if st.count == 5 {
                r.check(st[3].string("call-state") == "idle", "carrier: hung up: \(st[3].string("call-state") ?? "")")
            }
        }
        r.check(
            (replies["no-such-property"] ?? "").contains("ok(false)"),
            "carrier: an unknown property is refused at the link"
        )
        // The vibration motor as the app reads it (the status block; helper-driver's vibrator events), issue 38.
        let step = { (prefix: String) in
            e.find("step").first { $0.string("step")?.hasPrefix(prefix) == true }?.double("t") ?? .infinity
        }
        let (sms, call, hangup) = (step("modem incoming-sms"), step("modem incoming-call"), step("modem remote-hangup"))
        let buzzes = vibratorBuzzes(e)
        let smsBuzzes = buzzes.filter { $0.start >= sms && $0.start < call }
        let ringBuzzes = buzzes.filter { $0.start >= call && $0.start < hangup }
        r.check(!smsBuzzes.isEmpty, "carrier: the SMS buzzes the vibrator (\(describe(smsBuzzes)))")
        r.check(
            ringBuzzes.count >= 3 && e.find("vibrator").last?.bool("on") == false,
            "carrier: the vibrator buzzes while ringing and stops (\(describe(ringBuzzes)))"
        )
    }
    if only.contains("emergency") {
        emergencyCall(base, tools: tools, work: work, r)
    }
    if only.contains("simpin") {
        simPIN(base, tools: tools, work: work, r)
    }
    if only.contains("location") {
        location(base, tools: tools, work: work, r)
    }
    if only.contains("compass") {
        compass(base, tools: tools, work: work, r)
    }
    if only.contains("rotate") {
        print("rotate")
        cloneOverlay("rotate")
        let d = HelperDriver(
            "rotate",
            tools: tools,
            work: work,
            scenario: preparedScenario(
                base,
                tools: tools,
                work: work,
                name: "rotate",
                steps: [
                    // Home wakes the lock screen first: 5.x+ puts the display to sleep within 8 s of lighting it.
                    "boot", "lit 0.03 300", "wait 8", "button 0", "wait 2", "dump lock", unlockSlide, "wait 4",
                    "tap 0.617 0.9", "wait 8",
                    "dump home", "status",
                    "orientation 4", "wait 1", "dump turned", "status", "wait 4", "dump turned5", "status", "quit",
                    "expectExit 60",
                ]
            )
        )
        r.check(d.finish(600) == 0, "rotate: scenario completed")
        let serials = d.events.find("status").map { (($0["status"] as? Event) ?? $0).int("frameSerial") }
        r.check(
            serials.count == 3 && (serials[1] ?? 0) > (serials[0] ?? Int.max),
            "rotate: a new frame within 1 s of the rotation (frame serials \(serials.map { $0 ?? -1 }))"
        )
        let home = d.dir.appendingPathComponent("home.png")
        let turned = d.dir.appendingPathComponent("turned.png")
        let same = (try? Data(contentsOf: home)) == (try? Data(contentsOf: turned))
        let dumped = d.events.find("dump").contains { $0.string("name") == "turned" && $0.bool("ok") }
        r.check(dumped && !same, "rotate: the turned frame differs from portrait")
    }
    if only.contains("shutdown") {
        print("shutdown")
        let d = HelperDriver(
            "shutdown",
            tools: tools,
            work: work,
            scenario: preparedScenario(
                base,
                tools: tools,
                work: work,
                name: "shutdown",
                steps: [
                    "boot", "lit 0.03 300", "wait 20", "shutdown 120", "status", "quit", "expectExit 60",
                ]
            )
        )
        r.check(d.finish(600) == 0, "shutdown: scenario completed")
        let done = d.events.one("shutdown")
        r.check(
            done.bool("confirmed"),
            "shutdown: the guest powered itself off (\(format(done.double("seconds"), 0)) s)"
        )
    }
    if only.contains("keyboard") {
        print("keyboard")
        let d = HelperDriver(
            "keyboard",
            tools: tools,
            work: work,
            scenario: preparedScenario(
                base,
                tools: tools,
                work: work,
                name: "keyboard",
                steps: [
                    "boot", "lit 0.03 300", "wait 5", "keyboard off", "wait 2", "keyboard on", "quit", "expectExit 60",
                ]
            )
        )
        r.check(d.finish(400) == 0, "keyboard: scenario completed")
        let replies = d.events.find("reply").map { $0.string("reply") ?? "" }
        r.check(
            replies.count == 2 && replies.allSatisfy { $0.contains("ok(true)") },
            "keyboard: unplugged and replugged: \(replies)"
        )
    }
    finish(r, work: work)
}

/// 911 from the emergency-only dialer (issue 32): on 4.x the passcode screen's after setting passcode 1111 in Settings;
/// on 7.x Setup's Home sheet (a fresh overlay, first boot). CommCenter asks the modem `+XEMN="911"` first and dials only
/// if it answers that this is an emergency number; the Carrier panel's status then shows the call as an emergency call.
func emergencyCall(_ base: Base, tools: Tools, work: URL, _ r: Report) {
    print("emergency")
    let dialing: [String]
    switch base.major {
    case 4:
        let one = ["tap 0.165 0.594", "wait 0.5"]
        let code = Array([[String]](repeating: one, count: 4).joined())
        dialing =
            ["boot", "lit 0.5 400", "wait 40", "button 0", "wait 2", unlockSlide, "wait 4"]
            // Settings, General, Passcode Lock (the last row, unscrolled), Turn Passcode On, 1111 twice.
            + [
                "tap 0.385 0.68", "wait 4", "tap 0.5 0.84", "wait 3", "tap 0.5 0.972", "wait 3", "tap 0.5 0.21",
                "wait 3",
            ]
            + code + ["wait 2"] + code + ["wait 3"]
            // Lock, wake, slide: the passcode screen, then its Emergency Call button.
            + ["button 1", "wait 3", "button 0", "wait 2", unlockSlide, "wait 3", "tap 0.165 0.94", "wait 4"]
            + [
                "tap 0.784 0.556", "wait 0.5", "tap 0.207 0.33", "wait 0.5", "tap 0.207 0.33", "wait 1",
                "tap 0.728 0.906",
            ]
    case 7:
        dialing = [
            "boot", "lit 0.9 600", "wait 10", "button 0", "wait 3", "drag 0.2 0.86 0.9 0.86", "wait 5", "button 0",
            "wait 3", "tap 0.5 0.735", "wait 4",
            "tap 0.75 0.54", "wait 0.5", "tap 0.26 0.22", "wait 0.5", "tap 0.26 0.22", "wait 1", "tap 0.5 0.825",
        ]
    default:
        print("  skip: no emergency dialer route for \(base.version)")
        return
    }
    let d = HelperDriver(
        "emergency",
        tools: tools,
        work: work,
        scenario: preparedScenario(
            base,
            tools: tools,
            work: work,
            name: "emergency",
            steps: dialing + [
                "wait 4", "modemStatus", "modem remote-answer 1", "wait 3", "dump call", "modemStatus",
                "modem remote-hangup 1", "wait 3", "modemStatus", "quit", "expectExit 60",
            ]
        ),
        environment: ["IOS_BB_TRACE": "2"]
    )
    r.check(d.finish(900) == 0, "emergency: scenario completed")
    let st: [Event] = d.events.find("modemStatus").map {
        ($0.string("json").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? Event) ?? [:]
    }
    let log = d.nativeLog
    r.check(
        log.contains(#"> at+xemn="911""#) && log.contains(#"+XEMN: "911",1"#),
        "emergency: CommCenter asked whether 911 is an emergency number and the modem said yes"
    )
    r.check(log.contains("> atd911;"), "emergency: then dialed it")
    if r.check(st.count == 3, "emergency: three statuses (\(st.count))") {
        r.check(
            st[0].string("last-dialed") == "911" && st[0].bool("emergency-call")
                && ["dialing", "alerting"].contains(st[0].string("call-state") ?? ""),
            "emergency: an emergency call going out (\(st[0]))"
        )
        r.check(
            st[1].string("call-state") == "active" && st[1].bool("emergency-call"),
            "emergency: answered (\(st[1].string("call-state") ?? ""))"
        )
        r.check(
            st[2].string("call-state") == "idle" && !st[2].bool("emergency-call"),
            "emergency: hung up (\(st[2].string("call-state") ?? ""))"
        )
    }
}

/// The SIM's PIN through Settings > Phone > SIM PIN (issue 49), 4.x: turned on (a wrong PIN first: refused, a try
/// spent), a clean power-off, then the next boot's SIM Locked sheet (a wrong PIN refused, the right one unlocks and the
/// phone registers), Change PIN, and off with the new PIN. The modem keeps the SIM in the overlay's sim file.
func simPIN(_ base: Base, tools: Tools, work: URL, _ r: Report) {
    print("simpin")
    guard base.major == 4 else { return print("  skip: no SIM PIN route for \(base.version)") }
    let keys: [Character: String] = [
        "1": "0.165 0.59", "2": "0.5 0.59", "3": "0.835 0.59", "4": "0.165 0.70", "5": "0.5 0.70", "6": "0.835 0.70",
        "7": "0.165 0.82", "8": "0.5 0.82", "9": "0.835 0.82", "0": "0.5 0.93",
    ]
    func type(_ code: String) -> [String] { code.flatMap { ["tap \(keys[$0]!)", "wait 0.6"] } }
    let done = ["tap 0.9 0.145", "wait 5"]  // the Settings sheets' Done and Save
    let toggle = ["tap 0.83 0.2", "wait 3"]
    let simPINPage = [
        "tap 0.385 0.68", "wait 4", "drag 0.5 0.85 0.5 0.35", "wait 3", "tapword Phone", "wait 4",
        "drag 0.5 0.85 0.5 0.4", "wait 3", "tapword SIM_PIN", "wait 4",
    ]
    func boot(_ name: String, _ steps: [String]) -> HelperDriver {
        let d = HelperDriver(
            name,
            tools: tools,
            work: work,
            scenario: preparedScenario(base, tools: tools, work: work, name: name, steps: ["boot"] + steps),
            environment: ["IOS_BB_TRACE": "2"]
        )
        r.check(d.finish(600) == 0, "\(name): scenario completed")
        return d
    }
    func read(_ d: HelperDriver) -> [String: String] {
        var lines: [String: String] = [:]
        for e in d.events.find("ocr") {
            lines[e.string("name") ?? ""] = (e["lines"] as? [String] ?? []).joined(separator: " | ")
        }
        return lines
    }
    let on = boot(
        "simpin",
        ["lit 0.5 400", "keyboard off", "modemSettle 80 240", "button 0", "wait 2", unlockSlide, "wait 4"]
            + simPINPage + toggle + type("1234") + done + ["ocr wrong"] + type("1111") + done
            + ["button 0", "wait 3", "shutdown 120", "quit", "expectExit 60"]
    )
    var seen = read(on)
    r.check(
        (seen["wrong"] ?? "").contains("2 attempts remaining"),
        "simpin: a wrong PIN is refused with the tries left (\(seen["wrong"] ?? ""))"
    )
    r.check(
        on.nativeLog.contains(#"> at+clck="sc",1,"1234""#) && on.nativeLog.contains("+CME ERROR: 16")
            && on.nativeLog.contains(#"> at+clck="sc",1,"1111""#),
        "simpin: CommCenter turned the PIN on through +CLCK, and the modem refused the wrong one"
    )
    let first = work.appendingPathComponent("simpin/overlay")
    r.check(
        (try? String(contentsOf: first.appendingPathComponent("sim"), encoding: .utf8))
            == "sim-pin 1 1111 12345678 3 10\n",
        "simpin: the SIM keeps the PIN, on, in the overlay"
    )
    // The next power-on, on a clone of that overlay.
    let second = work.appendingPathComponent("simpin2/overlay")
    try? FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
    run("/bin/cp", ["-cR", first.path, second.path])
    let locked = boot(
        "simpin2",
        [
            // Home again after the read: the lock screen may have gone dark meanwhile.
            "lit 0.5 400", "keyboard off", "wait 60", "button 0", "wait 2", "ocr lock", "button 0", "wait 2",
            unlockSlide, "wait 4",
            "tapword Unlock", "wait 3",
        ]
            + type("2222") + ["tap 0.82 0.45", "wait 5", "ocr incorrect"]
            + type("1111") + ["tap 0.82 0.45", "wait 20", "modemStatus"]
            // Change PIN: Current, New, Confirm, Save; then off, with the new PIN.
            + simPINPage + ["tap 0.5 0.29", "wait 3", "tap 0.6 0.258", "wait 2"] + type("1111")
            + ["wait 2", "tap 0.6 0.348", "wait 2"] + type("4321") + ["wait 2", "tap 0.6 0.439", "wait 2"]
            + type("4321") + ["wait 2"] + done
            + toggle + type("4321") + done + ["ocr off", "quit", "expectExit 60"]
    )
    seen = read(locked)
    r.check(
        (seen["lock"] ?? "").contains("SIM Locked"),
        "simpin: the next boot's SIM is locked (\(seen["lock"] ?? ""))"
    )
    r.check(
        (seen["incorrect"] ?? "").contains("Incorrect PIN") && (seen["incorrect"] ?? "").contains("2 attempts"),
        "simpin: a wrong PIN at the unlock sheet is refused (\(seen["incorrect"] ?? ""))"
    )
    let st = locked.events.find("modemStatus").first?.string("json") ?? ""
    r.check(
        st.contains(#""sim-lock": "ready""#) && st.contains(#""registered": true"#)
            && locked.nativeLog.contains("+CREG: 1,"),
        "simpin: the right PIN unlocks the SIM and the phone registers (\(st))"
    )
    r.check(
        locked.nativeLog.contains(#"> at+cpwd="sc","1111","4321""#)
            && locked.nativeLog.contains(#"> at+clck="sc",0,"4321""#) && (seen["off"] ?? "").contains("OFF")
            && (try? String(contentsOf: second.appendingPathComponent("sim"), encoding: .utf8))
                == "sim-pin 0 4321 12345678 3 10\n",
        "simpin: changed to 4321, then off with it (\(seen["off"] ?? ""))"
    )
}

/// The 3GS's GPS (issue 40): the modem's receiver (gps-fix through the link, as the Carrier panel's Location sets it)
/// answers locationd's +XLSR session, and CoreLocation in the guest reports that position: contrib/it-location's probe,
/// run from /usr/local/bin through the agent (locationd lets executables under /usr/ in without a prompt). Then the
/// fix moves (walking, a course) and the probe sees the new one.
func location(_ base: Base, tools: Tools, work: URL, _ r: Report) {
    print("location")
    guard base.board == "n88ap" else { return noReceiver(base, tools: tools, work: work, r) }
    let probe = checkout("qemu-ios").appendingPathComponent("contrib/it-location/it_location")
    guard FileManager.default.fileExists(atPath: probe.path) else {
        die("no it_location at \(probe.path) (contrib/it-location/build.sh)")
    }
    let fixes = [(37.3349, -122.0090, 0.0, -1.0), (37.33182, -122.03118, 1.4, 45.0)]
    let d = HelperDriver(
        "location",
        tools: tools,
        work: work,
        scenario: preparedScenario(
            base,
            tools: tools,
            work: work,
            name: "location",
            steps: [
                // 0.1, as compass: 3.x's lock screen lights at about 0.36 and sleeps before ever reaching 0.5.
                "boot", "lit 0.1 400", "wait 30", "modem gps-fix \(fixes[0].0),\(fixes[0].1),30,0,-1,5", "modemStatus",
                "agentput \(probe.path) /usr/local/bin/it_location", "spawn /usr/local/bin/it_location 15",
                "modem gps-fix \(fixes[1].0),\(fixes[1].1),20,\(fixes[1].2),\(fixes[1].3),10",
                "spawn /usr/local/bin/it_location 15", "quit", "expectExit 60",
            ]
        ),
        environment: ["IOS_BB_TRACE": "2"]
    )
    r.check(d.finish(900) == 0, "location: scenario completed")
    let status = d.events.find("modemStatus").first.flatMap {
        $0.string("json").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? Event
    }
    let fix = status?.string("gps-fix") ?? "-"
    r.check(status?.bool("gps") == true, "location: the modem reports its GPS receiver (\(fix))")
    let log = d.nativeLog
    r.check(
        log.contains("> at+xlsr=2,") && log.contains("+XLSR: 2,"),
        "location: locationd started a +XLSR session and the receiver reported fixes"
    )
    // "<+37.33490000, -122.00900000> +/- 4.87m (speed 1.40 mps / course 90.00) @ …", CLLocation's description (no
    // space after the comma from 6.x on).
    let pattern = /<([-+0-9.]+), ?([-+0-9.]+)> \+\/- ([0-9.]+)m \(speed ([-0-9.]+) mps \/ course ([-0-9.]+)\)/
    let runs = d.events.find("agent").filter { $0.string("op") == "spawn" }.map { $0.string("output") ?? "" }
    guard r.check(runs.count == 2, "location: the probe ran twice (\(runs.count))") else { return }
    for (run, fix) in zip(runs, fixes) {
        let seen = run.matches(of: pattern).compactMap { m -> [Double]? in
            let v = [m.1, m.2, m.3, m.4, m.5].compactMap { Double($0) }
            return v.count == 5 ? v : nil
        }
        let near = seen.last.map { abs($0[0] - fix.0) < 1e-5 && abs($0[1] - fix.1) < 1e-5 } ?? false
        r.check(near, "location: CoreLocation reports \(fix.0), \(fix.1) (last of \(seen.count): \(seen.last ?? []))")
        if fix.2 > 0, let last = seen.last {
            r.check(
                abs(last[3] - fix.2) < 0.05 && abs(last[4] - fix.3) < 0.5,
                "location: speed \(fix.2) m/s, course \(fix.3) (\(last[3]), \(last[4]))"
            )
        }
    }
}

/// The app's Compass Heading as CoreLocation reports it (contrib/it-heading's probe), face up and upright at two
/// headings each: the 3GS's AK8973 sits turned against the iPad's (its DT compass node's orientation, which the
/// driver undoes); the iPhone 4's AK8975B reads unturned. The M68 has no magnetometer and refuses the heading.
/// Not checked: the 3GS on iOS 4-5, whose locationd adds 16 µT per offset-DAC step to the AK8973's readings
/// (qemu-ios hw/arm/s5l8930_i2c.c, AK8973), and the iPhone 4 on 7.x, whose read-only root takes no probe.
func compass(_ base: Base, tools: Tools, work: URL, _ r: Report) {
    print("compass")
    if base.board == "n88ap" && (4...5).contains(base.major) {
        return print("  (not checked on the 3GS on iOS 4-5: its locationd adds the AK8973's offset DACs)")
    }
    if base.board == "n90ap" && base.major >= 7 {
        return print("  (not checked on the iPhone 4 on 7.x: the probe needs a writable /usr/local/bin)")
    }
    // (UIDeviceOrientation, heading): face up, the top edge's heading; portrait upright, the screen's.
    let cases = [(5, 90), (5, 200), (1, 90), (1, 200)]
    let probe = checkout("qemu-ios").appendingPathComponent("contrib/it-heading/it_heading")
    let modeled = base.board == "n88ap" || base.board == "n90ap"
    guard !modeled || FileManager.default.fileExists(atPath: probe.path) else {
        die("no it_heading at \(probe.path) (contrib/it-heading/build.sh)")
    }
    let steps =
        modeled
        ? ["boot", "lit 0.1 400", "wait 30", "agentput \(probe.path) /usr/local/bin/it_heading"]
            + cases.flatMap { ["orientation \($0.0)", "compass \($0.1)", "spawn /usr/local/bin/it_heading"] }
            + ["quit", "expectExit 60"]
        : ["boot", "lit 0.1 400", "compass 90", "quit", "expectExit 60"]
    let d = HelperDriver(
        "compass",
        tools: tools,
        work: work,
        scenario: preparedScenario(base, tools: tools, work: work, name: "compass", steps: steps)
    )
    r.check(d.finish(600) == 0, "compass: scenario completed")
    let replies = d.events.find("reply").filter { $0.has("compass") }.map { $0.string("reply") ?? "" }
    guard modeled else {
        r.check(
            replies.first?.contains("ok(false)") == true,
            "compass: no magnetometer, the heading refused (\(replies))"
        )
        return
    }
    r.check(replies.allSatisfy { $0.contains("ok(true)") }, "compass: the heading taken (\(replies))")
    let runs = d.events.find("agent").filter { $0.string("op") == "spawn" }.map { $0.string("output") ?? "" }
    guard r.check(runs.count == cases.count, "compass: the probe ran \(cases.count) times (\(runs.count))") else {
        return
    }
    for (run, (pose, heading)) in zip(runs, cases) {
        // "magnetic 90.0 accuracy 25.0"; an accuracy below 0 is an invalid (uncalibrated) heading
        let seen = run.matches(of: /it_heading: magnetic ([-0-9.]+) accuracy ([-0-9.]+)/).compactMap { m in
            Double(m.1).flatMap { h in Double(m.2).map { (h, $0) } }
        }
        let off = seen.last.map { abs(($0.0 - Double(heading) + 540).truncatingRemainder(dividingBy: 360) - 180) }
        let last = seen.last.map { "\($0.0), accuracy \($0.1)" } ?? "none"
        r.check(
            off.map { $0 < 5 } ?? false,
            "compass: CoreLocation reads \(heading) degrees \(pose == 5 ? "face up" : "upright") "
                + "(last of \(seen.count): \(last))" + (seen.isEmpty ? ": " + run.suffix(200) : "")
        )
    }
}

/// The iPhone 4's and the M68's modems have no receiver: they take the app's gps-fix (sent with the carrier at every
/// boot) and report `gps` false, so the panel shows no Location section.
private func noReceiver(_ base: Base, tools: Tools, work: URL, _ r: Report) {
    let d = HelperDriver(
        "location",
        tools: tools,
        work: work,
        scenario: preparedScenario(
            base,
            tools: tools,
            work: work,
            name: "location",
            steps: ["boot", "lit 0.1 400", "modem gps-fix 37.3349,-122.009", "modemStatus", "quit", "expectExit 60"]
        )
    )
    r.check(d.finish(600) == 0, "location: scenario completed")
    let status = d.events.find("modemStatus").first.flatMap {
        $0.string("json").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? Event
    }
    r.check(
        status?.bool("gps") == false && status?.has("error") == false
            && status?.string("gps-fix")?.hasPrefix("37.3349") == true,
        "location: no GPS receiver on \(base.board), the position taken without one (\(status ?? [:]))"
    )
}
