import Foundation
import SessionKit

/// `sessions flick BASE [--overlay DIR] [--runs N]`: two-finger trackpad swipes on the Home screen through the app's
/// ScrollDrag (helper-driver's `flicks`, synthetic AppKit scroll events at their own times). Between the first page and
/// the page left of it (Spotlight), each quick short flick must turn the page and each slow short drag must snap back.
/// The helper alone boots the base, as `sessions rotation` does; a 5.x or 6.x base not prepared --skip-setup needs
/// --overlay. 3.0 to 6.x only: iPhone OS 1 and 2 have no Spotlight page, and 7.x's Spotlight is a pull-down.
func flickCheck(_ args: FlickCheck) -> Never {
    let base = Base(args.base, args.inputs)
    guard (3...6).contains(base.major) else {
        die("flick swipes between the first Home page and Spotlight left of it, 3.0 to 6.x: \(base.version) has none")
    }
    let work = workDirectory(args.inputs, "flick")
    let tools = Tools.resolve(args.inputs, work: work)
    let r = Report()
    if let source = args.overlay {
        let overlay = work.appendingPathComponent("flick/overlay")
        try? FileManager.default.createDirectory(
            at: overlay.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        run("/bin/cp", ["-cR", source.path, overlay.path])  // a clone: the source stays as it was
    } else if base.bootsIntoSetup {
        die("a \(base.version) base is in Setup on its first boot: prepare it with --skip-setup or pass --overlay")
    }
    let iPad = base.board == "k48ap"
    let slide = iPad ? "dragshown 0.36 0.935 0.8 0.935" : "dragshown 0.18 0.9 0.92 0.9"
    // The swipe starts mid-screen; the window shows the screen about 576 points wide (iPad) or 400 (iPhone, iPod).
    let at = iPad ? "0.5 0.45 576" : "0.5 0.45 400"
    var scenario = preparedScenario(
        base,
        tools: tools,
        work: work,
        name: "flick",
        steps: [
            // As `sessions rotation`: the second slide is a page swipe on the Home screen, so Home after it.
            "boot", "lit 0.03 300", "wait 5", "button 0", "wait 2", slide, "wait 4", "button 0", "wait 2", slide,
            "wait 4", "button 0", "wait 3",
            // The first page, then Home on it shows the page left of it.
            "dump page", "button 0", "wait 3", "dump left", "button 0", "wait 3"
        ] + args.kinds.split(separator: ",").map { "flicks \($0) \(args.runs) \(at)" } + ["quit", "expectExit 60"]
    )
    if args.refreshHz != 60 || args.angle, var prepared = scenario["prepared"] as? [String: Any] {
        if args.refreshHz != 60 { prepared["refreshHz"] = args.refreshHz }
        if args.angle { prepared["angle"] = true }
        scenario["prepared"] = prepared
    }
    let d = HelperDriver("flick", tools: tools, work: work, scenario: scenario)
    r.check(d.finish(1200) == 0, "flick: scenario completed")
    let flicks = d.events.find("flick")
    for kind in args.kinds.split(separator: ",").map(String.init) {
        let runs = flicks.filter { $0.string("kind") == kind }
        // A picture far from both references (another page, an alert) is neither a turn nor a snap back.
        let lost = runs.filter {
            max(min($0.double("dPage") ?? 1, $0.double("dLeft") ?? 1), $0.double("dStart") ?? 1) > 0.05
        }.count
        let turned = runs.filter { $0.string("from") != $0.string("to") }.count
        if lost > 0 { r.check(false, "flick: \(lost) of \(runs.count) \(kind) started or ended on neither page") }
        // The frames each gesture brought, while it moved: under the floor, frames are lost on the way to the app
        // (published on a 30 ms timer, they reached it at 33 fps although the guest drew every vsync).
        let motion = runs.map { MotionFrames(times: ($0["frameTimes"] as? [NSNumber] ?? []).map(\.doubleValue)) }
        let fps = motion.map(\.fps).sorted()
        let median = fps.isEmpty ? 0 : fps[fps.count / 2]
        let skipped = runs.reduce(0) { $0 + Int($1.double("framesSkipped") ?? 0) }
        print(
            "   \(kind): motion \(format(median)) fps median (\(fps.map { format($0) }.joined(separator: ", "))), "
                + "p95 \(format(motion.map(\.p95).max())) ms, longest \(format(motion.map(\.longest).max())) ms, "
                + "\(skipped) frames the ring skipped"
        )
        r.check(median >= args.minFps, "flick: \(kind) moved at \(format(median)) fps, at least \(format(args.minFps))")
        let slow = kind.hasPrefix("slow")
        r.check(
            runs.count == args.runs && turned == (slow ? 0 : runs.count),
            slow
                ? "flick: \(runs.count - turned) of \(runs.count) slow short drags (\(kind)) snapped back"
                : "flick: \(turned) of \(runs.count) quick short flicks (\(kind)) turned the page"
        )
    }
    finish(r, work: work)
}
