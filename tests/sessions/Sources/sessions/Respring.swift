import ArgumentParser
import Foundation
import SessionKit

struct RespringCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "respring",
        abstract: """
            Device ▸ Respring on a base with guest tools: it restarts what the era's jailbreak respring restarted \
            (backboardd and SpringBoard from iOS 6, SpringBoard before), Slow Animations (a com.apple.UIKit key) takes \
            effect after it, and the Home screen takes a tap again. SpringBoard alone, the respring before 6.x's fix, \
            is measured first for comparison.
            """
    )
    @Argument var base: String
    @OptionGroup var inputs: Inputs

    func run() { respringCheck(self) }
}

/// How long an app's close animation runs, as frames: Home, then the frames from 1.5 s to 4.5 s after it. At UIKit's
/// own speed the animation is over by then (a still Home screen); at Slow Animations' 10x it is still running.
private let closeApp = [
    "agentop launch com.apple.Preferences", "wait 8", "button 0", "wait 1.5"
]

func respringCheck(_ args: RespringCheck) -> Never {
    let base = Base(args.base, args.inputs)
    guard !base.firstGeneration else { die("iPhone OS 1 has no guest tools: respring boots a 2.x or later base") }
    let work = workDirectory(args.inputs, "respring")
    let tools = Tools.resolve(args.inputs, work: work)
    let r = Report()
    let window = base.major >= 6
    let unlock = base.major >= 7 ? "drag 0.2 0.86 0.9 0.86" : "drag 0.18 0.9 0.92 0.9"
    // Home while the display sleeps and the slide while the agent says locked, until neither (helper-driver's wake).
    let wake = [unlock.replacingOccurrences(of: "drag", with: "wake")]
    let list = "spawn /bin/launchctl list"
    var steps = ["boot", "lit 0.1 400", "waitagent 240"] + wake + ["wait 10"]
    steps += closeApp + ["sample stock 3", list]
    // The key, then SpringBoard alone (what Respring did before)
    steps += [
        "defaults com.apple.UIKit UIAnimationDragCoefficient int 10", "spawn /bin/launchctl stop com.apple.SpringBoard",
        "until 60 locked"
    ]
    steps += wake + [list] + closeApp + ["sample springboard 3"]
    steps += ["respring"] + wake + [list] + closeApp + ["sample respring 3"]
    // A tap on the dock's first icon opens its app, once Slow Animations' Home screen has settled: until the app is
    // in front. Read 15 s on, the iPod touch 2G's Music had already gone again (its first launch on a fresh 3.1.3
    // base ends by itself within seconds).
    steps += [
        "until 30 text Settings", "agentop frontmost", "tap 0.16 0.9", "until 20 front", "dump after-tap", "button 0",
        "wait 5",
        "quit", "expectExit 60"
    ]
    var s = preparedScenario(base, tools: tools, work: work, name: "respring", steps: steps)
    var prepared = s["prepared"] as? [String: Any] ?? [:]
    prepared["itpack"] =
        tools.guest.appendingPathComponent("guest-tools/\(base.armv7 ? "armv7" : "armv6").itpack").path
    s["prepared"] = prepared

    let d = HelperDriver("respring", tools: tools, work: work, scenario: s)
    r.check(d.finish(1200) == 0, "scenario completed")
    let e = d.events
    // launchctl list: "PID Status Label"; "-" for a job that isn't running.
    let lists = e.find("agent", ["op": "spawn"]).compactMap { $0.string("output") }.filter { $0.contains("Label") }
    func pid(_ list: String, _ label: String) -> String? {
        list.split(separator: "\n").first { $0.hasSuffix("\t\(label)") || $0.hasSuffix(" \(label)") }
            .flatMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }
    }
    let sb = lists.map { pid($0, "com.apple.SpringBoard") ?? "?" }
    let bb = lists.map { pid($0, "com.apple.backboardd") ?? "none" }
    print("SpringBoard pids \(sb), backboardd pids \(bb)")
    r.check(lists.count == 3, "launchctl list read before and after each restart (\(lists.count))")
    if lists.count == 3 {
        r.check(
            sb[2] != sb[1] && Int(sb[2]) != nil,
            "Respring restarted SpringBoard (\(sb[1]) to \(sb[2]))"
        )
        if window {
            r.check(
                bb[2] != bb[1] && Int(bb[2]) != nil,
                "Respring restarted backboardd (\(bb[1]) to \(bb[2]))"
            )
        } else {
            r.check(bb.allSatisfy { $0 == "none" }, "no backboardd before 6.x (\(bb))")
        }
    }
    let fps = Dictionary(
        e.find("sample").map { ($0.string("label") ?? "", $0.double("fps") ?? -1) },
        uniquingKeysWith: { a, _ in a }
    )
    print(
        "close-animation frames/s: stock \(fps["stock"] ?? -1), SpringBoard alone \(fps["springboard"] ?? -1), Respring \(fps["respring"] ?? -1)"
    )
    let stock = fps["stock"] ?? 99
    r.check(
        (fps["respring"] ?? 0) > max(5, stock * 3),
        "Slow Animations took effect after Respring (\(fps["respring"] ?? -1) frames/s vs stock \(stock))"
    )
    // SpringBoard's own screen before the tap (not Setup), the dock's app after it.
    let before = e.find("agent").last.map { String($0.string("output")?.split(separator: "\n").first ?? "-") } ?? "-"
    let opened = e.find("until").last ?? [:]
    let app = opened.string("front") ?? ""
    r.check(
        before == "com.apple.springboard" && opened.bool("met") && app.hasPrefix("com.apple.")
            && app != "com.apple.purplebuddy",
        "a tap on the Home screen opens an app (frontmost \(before), then \(app.isEmpty ? "-" : app) after "
            + "\(format(opened.double("seconds"))) s)"
    )
    finish(r, work: work)
}
