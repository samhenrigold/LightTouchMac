import ArgumentParser
import Foundation
import SessionKit

struct ResumeCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resume",
        abstract: """
            Snapshot resume on any base that boots to the Home screen: a cold boot to the Home screen saved there, \
            then booted again from the snapshot on a clone of the overlay it was saved with, Home again, a tap that \
            opens Settings, the guest agent and lockdown over a new usbmuxd; the two times compared.
            """
    )
    @Argument var base: String
    @Option(help: "Resumes from the one snapshot.") var resumes = 1
    @OptionGroup var inputs: Inputs

    func run() { resumeCheck(self) }
}

func resumeCheck(_ args: ResumeCheck) -> Never {
    let base = Base(args.base, args.inputs)
    guard !base.bootsIntoSetup else {
        die("resume needs a base that boots to the Home screen: prepare it --skip-setup")
    }
    let work = workDirectory(args.inputs, "resume")
    let tools = Tools.resolve(args.inputs, work: work)
    let r = Report()
    // iPhone OS 1 has no guest agent: its Home and taps are judged on the screen alone.
    let agent = !base.firstGeneration
    // The device folder is the lease's grandparent: a snapshot is written only inside it (DeviceLink.grantSnapshot).
    let cold = work.appendingPathComponent("cold")
    let snapshot = cold.appendingPathComponent("state.bin")
    // The overlay as the save left it: the machine running on after it writes on (a resume over those writes
    // panicked n90 11D257's yaFTL, "validPagesDNo").
    let savedOverlay = cold.appendingPathComponent("saved-overlay")
    var coldScenario = preparedScenario(
        base,
        tools: tools,
        work: work,
        name: "cold",
        steps: homeSteps(base) + [
            "lockdown 120",
            "snapshot \(snapshot.path)", "clone \(cold.appendingPathComponent("overlay").path) \(savedOverlay.path)",
            "resume",
            "status", "tapword Settings -0.06", "seen Wi-Fi 30", "status",
            "quit",
            "expectExit 60"
        ]
    )
    withUSB(&coldScenario, tools)
    let c = HelperDriver(
        "cold",
        tools: tools,
        work: work,
        scenario: coldScenario,
        extra: ["--lease", cold.appendingPathComponent("work/lease").path],
        environment: driverEnvironment(tools)
    )
    let coldExit = c.finish(1500)
    let saved = c.events.one("snapshot")
    let coldSeen = c.events.find("seen")
    r.check(
        coldExit == 0 && coldSeen.first?.bool("found") == true && saved.int("status") == 2,
        "cold boot to Home in \(format(coldSeen.first?.double("t"))) s, saved there in "
            + "\(format(saved.double("seconds"))) s (\((saved.int("bytes") ?? 0) >> 20) MiB)"
    )
    guard r.allPassed else {
        print(c.tail)
        finish(r, work: work)
    }
    let coldUSB = c.events.one("usb")
    r.check(
        coldUSB.string("productType") == base.productType,
        "cold: lockdown answers in \(format(coldUSB.double("seconds"))) s, before the save"
    )
    // The control: the same machine running on after its save (the link's resume), a tap opens Settings.
    let coldStatus = c.events.find("status")
    r.check(
        coldSeen.count == 2 && coldSeen.last?.bool("found") == true
            && (coldStatus.last?.int("frameSerial") ?? 0) > (coldStatus.first?.int("frameSerial") ?? 0),
        "cold, running on after the save: a tap on Settings opens it"
    )
    for n in 1...args.resumes {
        let name = "resume\(n)"
        let dir = work.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard run("/bin/cp", ["-cR", savedOverlay.path, dir.appendingPathComponent("overlay").path]) == 0 else {
            die("could not clone the overlay", code: 3)
        }
        var scenario = preparedScenario(
            base,
            tools: tools,
            work: work,
            name: name,
            steps: ["boot", "lit 0.03 300", "seen Settings 300"] + (agent ? ["waitagent 120"] : [])
                + ["status", "tapword Settings -0.06"] + (agent ? ["until 20 front"] : [])
                + ["seen Wi-Fi 30", "status", "lockdown 120", "quit", "expectExit 60"]
        )
        withUSB(&scenario, tools)
        if var prepared = scenario["prepared"] as? [String: Any] {
            prepared["restore"] = snapshot.path
            scenario["prepared"] = prepared
        }
        let start = Date()
        let d = HelperDriver(name, tools: tools, work: work, scenario: scenario, environment: driverEnvironment(tools))
        let exit = d.finish(900)
        let seen = d.events.find("seen")
        let home = seen.first
        r.check(
            exit == 0 && home?.bool("found") == true,
            "\(name): Home \(format(d.events.one("lit").double("seconds").map { $0 + (home?.double("seconds") ?? 0) })) s "
                + "after boot (whole run \(format(Date().timeIntervalSince(start))) s)"
        )
        // The guest runs on (its agent answers), and the screen with it: the tap brings new frames.
        let status = d.events.find("status")
        let frames = (status.last?.int("frameSerial") ?? 0) - (status.first?.int("frameSerial") ?? 0)
        r.check(
            status.count == 2 && (!agent || status.last?.int("agentStatus") == 1) && frames > 0,
            "\(name): \(agent ? "the guest's agent answers and " : "")the screen updates (\(frames) new frames after the tap)"
        )
        // The agent says which app the tap opened; the screen is judged on its own (a restored surface that stopped
        // following the guest shows the Home screen it was saved with).
        if agent {
            let front = d.events.one("until")
            r.check(
                front.bool("met") && front.string("front") == "com.apple.Preferences",
                "\(name): a tap on Settings opens it (frontmost \(front.string("front") ?? "-"))"
            )
        }
        r.check(seen.count == 2 && seen.last?.bool("found") == true, "\(name): the screen shows Settings")
        let usb = d.events.one("usb")
        r.check(
            usb.string("productType") == base.productType,
            "\(name): lockdown answers over a new usbmuxd in \(format(usb.double("seconds"))) s "
                + "(\(usb.string("productType").map { $0.isEmpty ? "none" : $0 } ?? "none"))"
        )
        if !r.allPassed { print(d.tail) }
    }
    finish(r, work: work)
}

/// The scenario's guest USB through its own usbmuxd, for its `lockdown` steps.
func withUSB(_ scenario: inout [String: Any], _ tools: Tools) {
    guard var prepared = scenario["prepared"] as? [String: Any] else { return }
    prepared["usbmuxd"] = tools.usbmuxd.path
    scenario["prepared"] = prepared
}

/// From power-on to an unlocked Home screen, as helper-driver steps: lit, the agent up, the lock screen's slider
/// (iOS 10's Home) until the agent says unlocked, and Settings' icon read on the screen. iPhone OS 1 has no agent:
/// Home and the slide, judged by the screen alone.
func homeSteps(_ base: Base) -> [String] {
    let slide =
        base.board == "k48ap"
        ? "0.9365 0.621 0.9365 0.0612" : base.major >= 7 ? "0.2 0.86 0.9 0.86" : "0.18 0.9 0.92 0.9"
    let unlock =
        base.firstGeneration
        ? ["wait 5", "button 0", "wait 2", "drag \(slide)"]
        : ["waitagent 900", base.board == "n42ap" ? "wake home" : "wake \(slide)"]
    return ["boot", "lit 0.03 900"] + unlock + ["seen Settings 120"]
}
