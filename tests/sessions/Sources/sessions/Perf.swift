import Foundation
import SessionKit

/// `sessions perf BASE [--rounds N]`: what the screen costs, measured; judged only on the run completing and each
/// drag bringing frames. The helper alone boots the base to an unlocked Home screen; at a still Home screen it samples
/// the helper's CPU and wakeups (its own and QEMU's, one process) three times; then Home page drags there and back
/// (the finger moved every 16 ms, held a second after) record when each frame reached the ring, as frames/s of motion.
/// 3.0 and later: the drags go to the Spotlight page left of the first.
func perfCheck(_ args: PerfCheck) -> Never {
    let base = Base(args.base, args.inputs)
    guard base.major >= 3 else { die("perf drags to the Spotlight page, 3.0 on: \(base.version) has none") }
    if base.bootsIntoSetup { die("a \(base.version) base is in Setup on its first boot: prepare it with --skip-setup") }
    let work = workDirectory(args.inputs, "perf")
    let tools = Tools.resolve(args.inputs, work: work)
    let r = Report()
    // The unlock slider, as the window shows the picture (the iPad's as `sessions flick` drags it).
    let wake = base.board == "k48ap" ? "wakeshown 0.36 0.935 0.8 0.935" : "wakeshown 0.18 0.9 0.92 0.9"
    let drags = (1...args.rounds).flatMap { _ in
        ["motion right 0.15 0.5 0.85 0.5", "wait 1.5", "motion left 0.85 0.5 0.15 0.5", "wait 1.5"]
    }
    let d = HelperDriver(
        "perf",
        tools: tools,
        work: work,
        scenario: preparedScenario(
            base,
            tools: tools,
            work: work,
            name: "perf",
            steps: [
                "boot", "lit 0.03 300", "wait 5", wake, wake, "wait 10", "dump still", "sample still 5",
                "sample still 5", "sample still 5"
            ] + drags + ["quit", "expectExit 60"]
        )
    )
    r.check(d.finish(900) == 0, "perf: scenario completed")
    let still = d.events.find("sample").sorted { ($0.double("cpuPercent") ?? 0) < ($1.double("cpuPercent") ?? 0) }
    if let x = still.dropFirst(still.count / 2).first {
        let all = still.map { format($0.double("cpuPercent")) }.joined(separator: ", ")
        print(
            "   still Home: \(format(x.double("cpuPercent")))% CPU median (\(all)), "
                + "\(format(x.double("wakeupsPerSecond"))) wakeups/s, \(format(x.double("hz"))) Hz, "
                + "\(format(x.double("fps"))) fps"
        )
    }
    let motion = d.events.find("motion").map {
        MotionFrames(times: ($0["frameTimes"] as? [NSNumber] ?? []).map(\.doubleValue))
    }
    let fps = motion.map(\.fps).sorted()
    print(
        "   drags: motion \(format(fps.isEmpty ? nil : fps[fps.count / 2])) fps median "
            + "(\(fps.map { format($0) }.joined(separator: ", "))), p50 \(format(motion.map(\.p50).sorted().last)) ms, "
            + "p95 \(format(motion.map(\.p95).max())) ms, longest \(format(motion.map(\.longest).max())) ms"
    )
    r.check(
        motion.count == 2 * args.rounds && motion.allSatisfy { $0.frames > 0 },
        "perf: \(motion.count) drags recorded, each with frames"
    )
    finish(r, work: work)
}
