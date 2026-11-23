import Foundation
import SessionKit

/// `sessions scrolltop BASE [--overlay DIR] [--y Y] [--hold S]`: a tap on the status bar scrolls the frontmost list to
/// the top. Settings' list is dragged down, then tapped at the status bar's middle, released at once by default (a
/// trackpad's tap to click, which reached the guest as a lone TOUCH_ENDED until the digitizer kept its TOUCH_START
/// frame): each drag must change the picture and each tap bring the top's back. Whether the guest read the press before
/// the release came is a race, so a lost press failed about half the taps: --taps rounds (default 4) make a miss
/// near certain to show. A 5.x-7.x base needs --skip-setup or --overlay.
func scrollTopCheck(_ args: ScrollTopCheck) -> Never {
    let base = Base(args.base, args.inputs)
    // ponytail: not the iPad, whose Settings is a split view with no list long enough to scroll.
    guard base.board != "k48ap" else { die("scrolltop boots an iPhone or iPod base") }
    let work = workDirectory(args.inputs, "scrolltop")
    let tools = Tools.resolve(args.inputs, work: work)
    let r = Report()
    if let source = args.overlay {
        let overlay = work.appendingPathComponent("scrolltop/overlay")
        try? FileManager.default.createDirectory(
            at: overlay.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        run("/bin/cp", ["-cR", source.path, overlay.path])  // a clone: the source stays as it was
    }
    let d = HelperDriver(
        "scrolltop",
        tools: tools,
        work: work,
        scenario: homeScenario(
            base,
            tools: tools,
            work: work,
            name: "scrolltop",
            inputs: args.inputs,
            // wake twice: on a loaded host the first can run out of tries while the display is still asleep.
            cold: ["boot", "lit 0.03 300", "wait 5", "wake 0.18 0.9 0.92 0.9", "wake 0.18 0.9 0.92 0.9"],
            steps: ["agentop launch com.apple.Preferences", "wait 10", "agentop frontmost", "dump top"]
                + (1...args.taps).flatMap {
                    [
                        "dragshown 0.5 0.8 0.5 0.3", "wait 4", "dump scrolled\($0)",
                        "tapshown 0.5 \(args.y) \(args.hold)", "wait 4", "dump after\($0)"
                    ]
                } + ["quit", "expectExit 60"]
        )
    )
    r.check(d.finish(600) == 0, "scrolltop: scenario completed")
    let front = d.events.find("agent").compactMap { $0.string("output") }.contains {
        $0.hasPrefix("com.apple.Preferences")
    }
    r.check(front, "scrolltop: Settings is frontmost")
    // By the picture, status bar masked: the drag moved it, the tap brought the top back.
    func differing(_ a: String, _ b: String) -> Double {
        func sig(_ name: String) throws -> FrameCheck.Signature {
            try FrameCheck.signature(d.dir.appendingPathComponent("\(name).png"))
        }
        return (try? FrameCheck.fractionDiffering(sig(a), sig(b))) ?? 1
    }
    for i in 1...args.taps {
        let moved = differing("scrolled\(i)", "top")
        let back = differing("after\(i)", "top")
        r.check(moved > 0.1, "scrolltop: drag \(i) changed the picture (\(String(format: "%.3f", moved)) of it)")
        r.check(
            back < FrameCheck.threshold,
            "scrolltop: after tap \(i) the picture is the top's (\(String(format: "%.3f", back)) differs)"
        )
    }
    finish(r, work: work)
}
