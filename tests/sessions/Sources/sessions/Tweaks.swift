import ArgumentParser
import Foundation
import SessionKit

struct TweaksCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tweaks",
        abstract: """
            Device ▸ Tweaks… on a base with guest tools: the app's TweakApplier turns on what the firmware takes and the \
            status bar shows it (signal in dBm, the keynote clock, Core Animation's blended layers, then the Marketing \
            Status Bar: 9:41 AM and a carrier, through a respring), a hidden app opens, all of it goes off again; a second \
            boot with Time Machine starts at 9:41 AM.
            """
    )
    @Argument var base: String
    @OptionGroup var inputs: Inputs

    func run() { tweaksCheck(self) }
}

/// What `sessions tweaks` runs on the base: a boot that applies, reads the status bar and undoes it, and a Time Machine
/// boot. The steps go through helper-driver's `tweaks` (TweakApplier, as DeviceTweaks applies it) and `ocr`.
func tweaksCheck(_ args: TweaksCheck) -> Never {
    let base = Base(args.base, args.inputs)
    guard !base.firstGeneration else { die("iPhone OS 1 has no guest tools: tweaks boots a 2.x or later base") }
    let work = workDirectory(args.inputs, "tweaks")
    let tools = Tools.resolve(args.inputs, work: work)
    let r = Report()
    let version = base.version
    let before = { (v: String) in version.compare(v, options: .numeric) == .orderedAscending }
    let keynote = !before("2.0") && before("4.1")
    // the Marketing Status Bar: SpringBoard's demo keys (with the keynote clock), else UIKit's overrides
    let overrides = !before("4.2") && ["4.2", "4.3", "5.1", "6.1", "7.1"].contains { version.hasPrefix($0) }
    let clean = keynote || overrides
    let colors = !before("3.1")
    let phone = ["n88ap", "n90ap"].contains(base.board)
    let unlock = base.major >= 7 ? "drag 0.2 0.86 0.9 0.86" : "drag 0.18 0.9 0.92 0.9"
    // Home while the display sleeps and the slide while the agent says locked, until neither (helper-driver's wake; a
    // respring has already waited for the new SpringBoard). Each shot is read once the screen shows what it checks,
    // or, where it checks for an absence, once the Home screen shows (its Settings icon), at most 30 s: a fixed wait
    // read a half-drawn screen on a loaded host.
    let wake = [unlock.replacingOccurrences(of: "drag", with: "wake")]
    let settled = "until 30 text Settings"
    let marketingShown = ["until 30 text 9:41", "until 30 text Cupe"]
    // Field Test on an iPhone, else Diagnostics (4.2 on), else Apple's store demo app: each build's hidden apps.
    let hidden =
        phone && !before("4.2")
        ? "com.apple.fieldtest" : !before("4.2") ? "com.apple.iosdiagnostics" : "com.apple.DemoApp"
    let first = ["signalNumbers"] + (keynote ? ["keynoteClock"] : []) + (colors ? ["coreAnimationColors"] : [])
    // Connect Hardware Keyboard off, as the app boots with it off: 7.x on the iPhone 4 refuses the USB keyboard with
    // an alert over the Home screen, which dims the shots.
    let unplugged = ["boot", "lit 0.1 400", "keyboard off", "waitagent 240"]
    var steps = unplugged + wake + [settled, "ocr before"]
    steps += ["tweaks \(first.joined(separator: ","))"] + wake
    steps += ["agentget springboard.plist /var/mobile/Library/Preferences/com.apple.springboard.plist"]
    steps += [#"until 30 text -([4-9][0-9]|1[01][0-9])\b"#, "ocr on"]
    // The same set with the Marketing Status Bar: the overrides need no respring, the keys do. Then a respring from
    // outside: the keys stay; SpringBoard drops the overrides, which the app's poll reads back and posts again.
    if clean {
        steps += ["tweaks \((first + ["cleanStatusBar"]).joined(separator: ","))"] + wake + marketingShown
        steps += ["ocr clean"] + (overrides ? ["sbread clean"] : [])
        steps += ["respring"] + wake
        steps += (overrides ? ["sbread resprung", "sbrestore"] : []) + marketingShown
        steps += (overrides ? ["sbread restored"] : []) + ["ocr restored"]
    }
    steps +=
        ["hidden \(hidden)", "button 0", "wait 3", "tweaks none"] + wake + [settled, "ocr off", "quit", "expectExit 60"]
    func scenario(_ name: String, _ steps: [String], clock: Double? = nil) -> [String: Any] {
        var s = preparedScenario(base, tools: tools, work: work, name: name, steps: steps)
        var prepared = s["prepared"] as? [String: Any] ?? [:]
        prepared["itpack"] =
            tools.guest.appendingPathComponent("guest-tools/\(base.armv7 ? "armv7" : "armv6").itpack").path
        if let clock { prepared["clock"] = clock }
        s["prepared"] = prepared
        return s
    }

    print("apply")
    let d = HelperDriver("apply", tools: tools, work: work, scenario: scenario("apply", steps))
    r.check(d.finish(1200) == 0, "apply: scenario completed")
    let e = d.events
    let applies = e.find("tweaks")
    r.check(
        applies.count == (clean ? 3 : 2) && applies.allSatisfy { $0.bool("ok") },
        "the tweaks applied (\(applies.map { $0.string("result") ?? "" }))"
    )
    r.check(applies.first?.bool("resprung") == true, "SpringBoard restarted for its keys")
    // What the restarted SpringBoard reads: the keys as written, not its own copy flushed over them as it quit.
    let plist = (try? Data(contentsOf: d.dir.appendingPathComponent("springboard.plist"))).flatMap {
        try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
    }
    r.check(
        plist?["SBShowRSSI"] as? Bool == true,
        "the keys are still on the device after the respring (SBShowRSSI \(plist.map { "\($0["SBShowRSSI"] ?? "absent")" } ?? "unread"))"
    )
    let shots = Dictionary(e.find("ocr").map { ($0.string("name") ?? "", $0) }, uniquingKeysWith: { a, _ in a })
    func lines(_ name: String) -> [String] { (shots[name]?["lines"] as? [String]) ?? [] }
    // A shot that reads nothing is the screen not drawn (or the read failing), not a tweak that didn't show.
    let unread = e.find("ocr").compactMap { $0.string("name") }.filter { lines($0).isEmpty }
    r.check(!shots.isEmpty && unread.isEmpty, "every status bar shot read text (none in \(unread))")
    // the status bar's own read too: the whole picture's misses small text (an iPod's "-45" beside "iPod")
    func dBm(_ name: String) -> Bool {
        (lines(name).prefix(4) + ((shots[name]?["statusBar"] as? [String]) ?? [])).contains {
            $0.contains(/-[4-9][0-9]\b|-1[01][0-9]\b/)
        }
    }
    // The iPod's Wi-Fi number shows once Wi-Fi is back after the respring: the clean shot, a moment later, counts too.
    r.check(
        !dBm("before") && (dBm("on") || dBm("clean")),
        "the status bar shows the signal in dBm (\(lines("on").prefix(3)), \(lines("clean").prefix(3)))"
    )
    if keynote {
        r.check(lines("on").prefix(4).contains { $0.contains("9:42") }, "the keynote clock reads 9:42 AM")
    }
    if colors {
        let tint = (shots["before"]?.double("tint") ?? 0, shots["on"]?.double("tint") ?? 0)
        r.check(tint.1 > tint.0 + 40, "Core Animation tints the blended layers (tint \(tint.0) to \(tint.1))")
    }
    if clean {
        for shot in ["clean", "restored"] {
            let top = lines(shot).prefix(6)
            // an iPod's 3.x status bar draws it "Cupe..."
            r.check(
                top.contains { $0.contains("9:41") } && top.contains { $0.contains("Cupe") },
                "the \(shot) status bar reads 9:41 AM and Cupertino (\(top))"
            )
        }
    }
    if overrides {
        let reads = Dictionary(e.find("sbread").map { ($0.string("name") ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        if reads["clean"]?.bool("readable") == true {
            for name in ["clean", "restored"] {
                let read = reads[name] ?? [:]
                r.check(
                    read.bool("held") == true && read.string("time") == "9:41 AM"
                        && read.string("carrier") == "Cupertino" && read.double("battery") == 50,
                    "SpringBoard holds the overrides and its data shows them, \(name) (\(read))"
                )
            }
            r.check(
                reads["resprung"]?.bool("held") == false && e.one("sbrestore").bool("posted") == true,
                "a respring drops them and the app's poll posts them again"
            )
        } else {
            print("SKIP: the base's agent can't read the status bar back (it_agent v4); OCR only")
        }
    }
    let opened = e.one("hidden")
    r.check(
        (opened["apps"] as? [String] ?? []).contains(hidden) && opened.string("front") == hidden,
        "\(hidden) is listed and opens (frontmost \(opened.string("front") ?? "-"))"
    )
    let off = (shots["off"]?.double("tint") ?? 99, shots["before"]?.double("tint") ?? 0)
    r.check(
        !dBm("off") && !lines("off").prefix(4).contains { $0.contains("9:42") || $0.contains("9:41") }
            && off.0 < off.1 + 10,
        "all of it off again (\(lines("off").prefix(3)), tint \(off.0))"
    )

    print("time machine")
    let t = HelperDriver(
        "clock",
        tools: tools,
        work: work,
        scenario: scenario(
            "clock",
            [
                "boot", "lit 0.1 400", "keyboard off", "waitagent 240"
            ] + wake + [
                // Time Machine writes no keys: network time stays on and the machine's network answers NTP in its
                // clock, so 5.x to 7.x timed keeps the pinned time all the boot
                "tweaks timeMachine", "wait 30", "ocr clock", "quit", "expectExit 60"
            ],
            clock: 1_168_364_460  // 9:41 AM in San Francisco, January 9, 2007
        )
    )
    r.check(t.finish(600) == 0, "clock: scenario completed")
    let clock = (t.events.one("ocr")["lines"] as? [String]) ?? []
    r.check(
        clock.prefix(4).contains { $0.contains("9:4") } && clock.prefix(4).contains("Tuesday"),
        "the boot starts at the pinned 9:41 AM, Tuesday (\(clock.prefix(3)))"
    )
    finish(r, work: work)
}
