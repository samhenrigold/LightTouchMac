import ArgumentParser
import Foundation
import LightTouchCore
import SessionKit

struct ToldCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "told",
        abstract: """
            A base past Setup whose guest agent reports (it_agent v6): without being asked, it tells the host that \
            SpringBoard answers, that the device is unlocked, which app came to the front and that it left, which way \
            the interface turned, and that a respring brought another SpringBoard, and what it tells is what its own \
            ops answer; a tap and a button made on the guest's clock reach the guest's digitizer driver and open and \
            leave an app; a request for an app's it_typein is answered at once where the guest has none.
            """
    )
    @Argument var base: String
    @Option(
        help: "The guest package offered at boot (default: the guest archive's for the base's arch).",
        transform: path
    )
    var itpack: URL?
    @OptionGroup var inputs: Inputs

    func run() { toldCheck(self) }
}

func toldCheck(_ args: ToldCheck) -> Never {
    let base = Base(args.base, args.inputs)
    guard !base.firstGeneration else { die("iPhone OS 1 has no guest agent: told boots a 2.x or later base") }
    let work = workDirectory(args.inputs, "told")
    let tools = Tools.resolve(args.inputs, work: work)
    let r = Report()
    let pad = base.board == "k48ap"
    // The lock screen's slider, as the panel scans (an iPad's panel is landscape), and an icon in the dock as shown.
    let slide = pad ? "0.9365 0.621 0.9365 0.0612" : base.major >= 7 ? "0.2 0.86 0.9 0.86" : "0.18 0.9 0.92 0.9"
    let dock = pad ? "0.39 0.945" : "0.16 0.9"
    let settings = "com.apple.Preferences"
    let calculator = "com.apple.calculator"
    // SpringBoardServices tells the interface's orientation as degrees on 3.1.3 and as a UIInterfaceOrientation from
    // 3.2 (the agent reports whichever the firmware has). The app's Rotate Right puts Home on the left.
    let degrees = base.version.compare("3.2", options: .numeric) == .orderedAscending
    let (turnKey, upright, turned) = degrees ? ("uidegrees", "0", "-90") : ("interface", "1", "4")

    // The steps, and beside each wait and gesture what its passing shows.
    var steps = ["boot", "waitagent 900"]
    var waits: [(what: String, after: String)] = []
    var gestures: [String] = []
    func told(_ seconds: Int, _ line: String, _ what: String, after: String) {
        steps.append("told \(seconds) \(line)")
        waits.append((what, after))
    }
    func gesture(_ made: String, _ what: String) {
        steps.append("gesture \(made)")
        gestures.append(what)
    }
    /// Home until the app has left, and the frame then (to see what stands in its place when it hasn't).
    var homes: [String] = []
    func home(_ what: String) {
        steps += ["home", "dump home-\(homes.count + 1)"]
        homes.append(what)
    }
    told(900, "springboard ~", "SpringBoard answers", after: "the agent came up")
    steps.append("wake \(slide)")
    told(60, "locked 0", "the device is unlocked", after: "the slide")
    gesture("tapshown \(dock)", "a tap on the dock")
    told(60, "front +", "an app came to the front", after: "the tap")
    home("it")
    steps.append("launch \(settings)")
    told(10, "front \(settings)", "Settings is at the front", after: "its launch returned")
    steps += ["agentop frontmost", "agentop lockstatus", "agentop uidump"]
    home("Settings")
    steps.append("agentop frontmost")
    // What turns with the device: an iPad's Home screen, elsewhere Calculator (no network to wait for).
    if !pad {
        steps.append("launch \(calculator)")
        told(10, "front \(calculator)", "Calculator is at the front", after: "its launch returned")
    }
    told(60, "\(turnKey) \(upright)", "the interface stands upright", after: "that")
    steps.append("turn cw")
    told(60, "\(turnKey) ~", "the interface turned with the device", after: "Rotate Right")
    steps.append("turn ccw")
    told(60, "\(turnKey) \(upright)", "the interface turned back", after: "Rotate Left")
    if !pad {
        home("Calculator")
    }
    steps.append("respring")
    told(240, "springboard ~", "a respring brought another SpringBoard", after: "it")
    steps += ["quit", "expectExit 60"]

    var scenario = preparedScenario(base, tools: tools, work: work, name: "told", steps: steps)
    if var prepared = scenario["prepared"] as? [String: Any] {
        prepared["itpack"] =
            (args.itpack ?? tools.guest.appendingPathComponent("guest-tools/\(base.armv7 ? "armv7" : "armv6").itpack"))
            .path
        scenario["prepared"] = prepared
    }
    let d = HelperDriver("told", tools: tools, work: work, scenario: scenario)
    r.check(d.finish(1500) == 0, "scenario completed")
    // First, so a guest that panicked or lost a volume is the failure the run names, not the waits it then missed.
    let serial = (try? String(contentsOf: work.appendingPathComponent("told/serial.log"), encoding: .utf8)) ?? ""
    let faults = GuestFaults.faults(log: serial, dataVolume: base.dataVolume)
    r.check(
        faults.isEmpty,
        "no guest faults in the serial log" + (faults.isEmpty ? "" : ": " + faults.joined(separator: "; ")))
    let toldEvents = d.events.find("told")
    let gestureEvents = d.events.find("gesture")
    func line(_ key: String, in e: [String: Any]?) -> String? {
        (e?.string("report") ?? "").split(separator: "\n").first { $0.hasPrefix(key + " ") }
            .map { String($0.dropFirst(key.count + 1)) }
    }
    r.check(
        toldEvents.count == waits.count && gestureEvents.count == gestures.count
            && d.events.find("home").count == homes.count,
        "every step ran (\(toldEvents.count) of \(waits.count) waits, \(gestureEvents.count) of \(gestures.count) "
            + "gestures, \(d.events.find("home").count) of \(homes.count) Homes)"
    )
    let version = line("agent", in: toldEvents.first)
    r.check(version != nil, "the agent reports (\(version.map { "agent \($0)" } ?? "nothing: an agent before v6?"))")
    for (i, wait) in waits.enumerated() {
        let e = toldEvents.count > i ? toldEvents[i] : nil
        let passed = e?["ok"] as? Bool == true
        r.check(
            passed,
            "told \(wait.what) (\(e?.string("key") ?? "-") \(e?.string("got") ?? "-")), "
                + String(format: "%.1f s after \(wait.after)", e?.double("seconds") ?? -1)
                + (i == 0 ? String(format: ", %.0f s into the boot", e?.double("sinceBoot") ?? -1) : "")
        )
    }
    let homeEvents = d.events.find("home")
    for (i, what) in homes.enumerated() {
        let e = homeEvents.count > i ? homeEvents[i] : nil
        let presses = e?.int("presses") ?? 0
        r.check(
            e?["ok"] as? Bool == true,
            "told \(what) left the front, " + String(format: "%.1f s after Home", e?.double("seconds") ?? -1)
                + (presses > 1 ? " (pressed \(presses) times: something over it, an alert, took the others)" : "")
        )
    }
    for (i, what) in gestures.enumerated() {
        let e = gestureEvents.count > i ? gestureEvents[i] : nil
        r.check(
            e?["ok"] as? Bool == true,
            "\(what), made on the guest's clock, reached its digitizer driver (\(e?.string("result") ?? "not made"), "
                + String(format: "%.2f s)", e?.double("seconds") ?? -1)
        )
    }
    let turn = toldEvents.first { $0.string("key") == turnKey && $0.string("want") == "~" }?.string("got")
    r.check(turn == turned, "turned right, Home on the left, is \(turnKey) \(turned) (\(turn ?? "-"))")
    let launches = d.events.find("launch")
    r.check(
        launches.count == (pad ? 1 : 2) && launches.allSatisfy { $0.string("result") == "success()" },
        "the app's launch opened Settings right after Home"
            + launches.map { String(format: " (%.1f s)", $0.double("seconds") ?? -1) }.joined()
    )
    // The agent's own ops, asked right after: the same answers.
    let asked = d.events.find("agent").compactMap { $0.string("output") }
    let front = asked.first { $0.hasPrefix(settings + "\n") }?.split(separator: "\n").map(String.init) ?? []
    let name = line("name", in: toldEvents.first { $0.string("want") == settings })
    r.check(
        front.count == 2 && name == front[1],
        "its report names the app as its frontmost op does (\(name ?? "-") and \(front.dropFirst().first ?? "-"))"
    )
    r.check(
        asked.contains { $0.hasPrefix("locked=0 ") } && asked.contains { $0.hasPrefix("com.apple.springboard\n") },
        "its lockstatus, and its frontmost at Home, agree with the report (\(asked.suffix(3)))"
    )
    // The frontmost app's views are asked of an it_typein inside it, which the iPod touch 2G's packages carry. Where
    // no app has one, the emulator refuses the request at once: it used to wait out its five seconds.
    let all = d.events.all
    let dumped = all.firstIndex { $0.string("step") == "agentop uidump" }
    let dump = dumped.flatMap { at in all[at...].first { $0.string("event") == "agent" } }
    let took = (dump?.double("t") ?? 99) - (dumped.map { all[$0].double("t") ?? 0 } ?? 0)
    let views = dump?.string("output") ?? ""
    if base.board == "n72ap" {
        r.check(views.contains("UIWindow"), String(format: "Settings' views came from its it_typein (%.1f s)", took))
    } else {
        r.check(
            took < 1.5 && !views.contains("UIWindow"),
            String(format: "with no it_typein in the guest's apps, a request for one is refused at once (%.1f s)", took)
        )
    }
    if r.failed > 0 { print(d.tail) }
    finish(r, work: work)
}
