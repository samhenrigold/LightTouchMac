import ArgumentParser
import Foundation
import SessionKit

struct ResumeCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resume",
        abstract: """
            Snapshot resume on an n72ap base: a cold boot to the Home screen saved there, then booted again from the \
            snapshot on a clone of the overlay it was saved with, Home again and a tap that opens Settings; the two \
            times compared.
            """
    )
    @Argument var base: String
    @Option(help: "Resumes from the one snapshot.") var resumes = 1
    @OptionGroup var inputs: Inputs

    func run() { resumeCheck(self) }
}

func resumeCheck(_ args: ResumeCheck) -> Never {
    let base = Base(args.base, args.inputs)
    guard base.board == "n72ap" else { die("resume takes an n72ap base") }
    let work = workDirectory(args.inputs, "resume")
    let tools = Tools.resolve(args.inputs, work: work)
    let r = Report()
    // The device folder is the lease's grandparent: a snapshot is written only inside it (DeviceLink.grantSnapshot).
    let cold = work.appendingPathComponent("cold")
    let snapshot = cold.appendingPathComponent("state.bin")
    let c = HelperDriver(
        "cold",
        tools: tools,
        work: work,
        scenario: preparedScenario(
            base,
            tools: tools,
            work: work,
            name: "cold",
            steps: [
                "boot", "lit 0.03 300", "waitagent 300", "wait 5", "button 0", "wait 2", unlockSlide,
                "seen Settings 60",
                "snapshot \(snapshot.path)", "resume", "status", "tapword Settings", "seen General 30", "status",
                "quit",
                "expectExit 60"
            ]
        ),
        extra: ["--lease", cold.appendingPathComponent("work/lease").path]
    )
    let coldExit = c.finish(700)
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
        guard run("/bin/cp", ["-cR", cold.appendingPathComponent("overlay").path, dir.path]) == 0 else {
            die("could not clone the overlay", code: 3)
        }
        var scenario = preparedScenario(
            base,
            tools: tools,
            work: work,
            name: name,
            steps: [
                "boot", "lit 0.03 120", "seen Settings 120", "waitagent 120", "status", "tapword Settings",
                "until 20 front", "seen General 30", "status", "quit", "expectExit 60"
            ]
        )
        if var prepared = scenario["prepared"] as? [String: Any] {
            prepared["restore"] = snapshot.path
            scenario["prepared"] = prepared
        }
        let start = Date()
        let d = HelperDriver(name, tools: tools, work: work, scenario: scenario)
        let exit = d.finish(400)
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
            status.count == 2 && status.last?.int("agentStatus") == 1 && frames > 0,
            "\(name): the guest's agent answers and the screen updates (\(frames) new frames after the tap)"
        )
        // The agent says which app the tap opened; the screen is judged on its own: a restored iPod touch 2G opens
        // Settings and goes on showing the Home screen it was saved with.
        let front = d.events.one("until")
        r.check(
            front.bool("met") && front.string("front") == "com.apple.Preferences",
            "\(name): a tap on Settings opens it (frontmost \(front.string("front") ?? "-"))"
        )
        r.check(seen.count == 2 && seen.last?.bool("found") == true, "\(name): the screen shows Settings")
        if !r.allPassed { print(d.tail) }
    }
    finish(r, work: work)
}
