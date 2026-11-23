import Foundation
import SessionKit

/// `sessions clipboard BASE` (iOS 3.0 or later): Share clipboard with devices, both ways, through the helper as the
/// app drives it. A copy inside the guest (it_pbtool set, spawned by the guest agent) reaches the host as the
/// helper's guestPasteboard event, once; the host's text (LinkCommand.paste) lands on the guest's pasteboard
/// (it_pbtool get), and isn't reported back. Both strings carry non-ASCII text. The guest agent starts its clipboard
/// 40 s after it comes up, so the check waits that long first.
func clipboardCheck(_ args: ClipboardCheck) -> Never {
    let base = Base(args.base, args.inputs)
    guard base.major >= 3 else { die("iPhone OS 3.0 brought the pasteboard: boot a 3.0 or later base") }
    let work = workDirectory(args.inputs, "clipboard")
    let tools = Tools.resolve(args.inputs, work: work)
    let r = Report()
    let qemu = checkout("qemu-ios")
    let tool =
        args.pbtool
        ?? qemu.appendingPathComponent(base.armv7 ? "build/ipad1-guest/it_pbtool" : "contrib/it-pasteboard/it_pbtool")
    guard FileManager.default.isExecutableFile(atPath: tool.path) else {
        die("no \(tool.path): build it (contrib/it-pasteboard/build.sh, armv7: contrib/ipad1-guest/build.sh)")
    }
    let itpack =
        args.itpack
        ?? tools.guest.appendingPathComponent("guest-tools/\(base.armv7 ? "armv7" : "armv6").itpack")
    let fromGuest = "Copied on the device: ü 🍎 https://example.com/?q=1&r=ß"
    let fromMac = "Pasted from the Mac: é ✓ 漢字"
    let remote = "/var/tmp/it_pbtool"
    let wake = "wake 0.18 0.9 0.92 0.9"  // Home, then the lock screen's slider
    let scenario = homeScenario(
        base,
        tools: tools,
        work: work,
        name: "clipboard",
        inputs: args.inputs,
        // Awake and unlocked for each turn: a sleeping guest runs no agent (the text waits for it).
        cold: ["boot", "waitagent 900", "wait 50", wake],
        steps: [
            "agentput \(tool.path) \(remote)", "guestpb \(remote) set \(fromGuest)", "wait 4",
            "hostpb \(fromMac)", "wait 4", wake, "guestpb \(remote) get", "wait 2",
            "quit", "expectExit 60"
        ],
        prepared: ["itpack": itpack.path]
    )
    let d = HelperDriver("clipboard", tools: tools, work: work, scenario: scenario)
    r.check(d.finish(1500) == 0, "clipboard: scenario completed")
    let alive = d.events.one("waitagent")["alive"] as? Bool == true
    r.check(alive, "clipboard: the guest agent is up")
    let reported = d.events.find("guestPasteboard").compactMap { $0["text"] as? String }
    r.check(
        reported == [fromGuest],
        "clipboard: guest -> host: the device's copy arrived once, nothing else reported (got \(reported))"
    )
    let readBack = d.events.find("guestpb").last
    r.check(
        readBack?["status"] as? String == "0" && readBack?["text"] as? String == fromMac,
        "clipboard: host -> guest: the guest's pasteboard holds the host's text (got \(readBack?["text"] ?? "nothing"))"
    )
    if r.failed > 0 { print(d.tail) }
    finish(r, work: work)
}
