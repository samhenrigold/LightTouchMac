import Foundation
import SessionKit

/// A check's scenario. Cold (the default): `cold` then `steps` on a fresh overlay. With --from-snapshot: `steps` on a
/// resumed Home screen (homeSnapshot), the overlay a clone of the one it was saved with, so the cold prefix is
/// skipped. `prepared` adds to the scenario's prepared fields (itpack, refreshHz), in the snapshot's key too.
func homeScenario(
    _ base: Base,
    tools: Tools,
    work: URL,
    name: String,
    inputs: Inputs,
    cold: [String],
    steps: [String],
    prepared extra: [String: Any] = [:]
) -> [String: Any] {
    func with(_ scenario: [String: Any], _ more: [String: Any]) -> [String: Any] {
        var scenario = scenario
        let prepared = (scenario["prepared"] as? [String: Any] ?? [:]).merging(more) { $1 }
        scenario["prepared"] = prepared
        return scenario
    }
    guard inputs.fromSnapshot else {
        return with(preparedScenario(base, tools: tools, work: work, name: name, steps: cold + steps), extra)
    }
    // ANGLE keeps no GL state a snapshot holds; the restore boots CGL (PreparedDeviceBoot).
    if extra["angle"] as? Bool == true { die("--from-snapshot resumes on CGL: not with --angle") }
    let overlay = work.appendingPathComponent("\(name)/overlay")
    if FileManager.default.fileExists(atPath: overlay.path) {
        die("--from-snapshot resumes the overlay it was saved with: not with --overlay")
    }
    let snapshot = homeSnapshot(base, tools: tools, work: work, prepared: extra)
    try? FileManager.default.createDirectory(at: overlay.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard run("/bin/cp", ["-cR", snapshot.dir.appendingPathComponent("overlay").path, overlay.path]) == 0 else {
        die("could not clone the snapshot's overlay", code: 3)
    }
    let resumed = ["boot", "lit 0.03 300"] + (base.firstGeneration ? [] : ["waitagent 120"])
    return with(
        preparedScenario(base, tools: tools, work: work, name: name, steps: resumed + steps),
        extra.merging(["restore": snapshot.dir.appendingPathComponent("state.bin").path, "argv": snapshot.argv]) { $1 }
    )
}

/// The cached Home-screen snapshot for this base, dylib, helper and guest package, taken now if there is none:
/// homeSteps, 45 s more (the agent starts its clipboard 40 s after it comes up), saved, and the machine quit with the
/// overlay as it was at the save. Under ~/Developer/ltm-scratch.noindex/.sessions-snapshots/<key> (LTM_SNAPSHOT_DIR),
/// which scripts/clean removes once unused for its days; one run takes a key at a time.
func homeSnapshot(_ base: Base, tools: Tools, work: URL, prepared extra: [String: Any]) -> (dir: URL, argv: [String]) {
    let fm = FileManager.default
    func bytes(_ url: URL) -> Data { (try? Data(contentsOf: url, options: .alwaysMapped)) ?? Data() }
    let steps = homeSteps(base) + ["wait 45"]
    let parts =
        [
            bytes(base.url.appendingPathComponent("device.lock.json")), bytes(tools.dylib), bytes(tools.helper),
            Data(base.board.utf8), Data(steps.joined(separator: "\n").utf8),
            // The guest package by its contents: each run unpacks it somewhere else.
            (try? JSONSerialization.data(withJSONObject: extra.filter { $0.key != "itpack" }, options: [.sortedKeys]))
                ?? Data()
        ] + ((extra["itpack"] as? String).map { [bytes(URL(fileURLWithPath: $0))] } ?? [])
    let key = SnapshotKey.key(parts)
    let root = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["LTM_SNAPSHOT_DIR"]
            ?? NSHomeDirectory() + "/Developer/ltm-scratch.noindex/.sessions-snapshots"
    )
    let dir = root.appendingPathComponent(key)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    let lock = open(root.appendingPathComponent("\(key).lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    if lock >= 0, flock(lock, LOCK_EX | LOCK_NB) != 0 {
        print("waiting for another run's snapshot \(dir.path)")
        flock(lock, LOCK_EX)
    }
    defer { close(lock) }
    let argvFile = dir.appendingPathComponent("argv.json")
    if let data = try? Data(contentsOf: argvFile), let argv = try? JSONDecoder().decode([String].self, from: data) {
        print("snapshot: \(dir.path)")
        return (dir, argv)
    }
    let name = "home-snapshot"
    let device = work.appendingPathComponent(name)
    // Written only inside the device's folder, the lease's grandparent (DeviceLink.grantSnapshot).
    let state = device.appendingPathComponent("state.bin")
    var scenario = preparedScenario(
        base,
        tools: tools,
        work: work,
        name: name,
        steps: steps + ["snapshot \(state.path)", "quit", "expectExit 60"]
    )
    scenario["prepared"] = (scenario["prepared"] as? [String: Any] ?? [:]).merging(extra) { $1 }
    let started = Date()
    let d = HelperDriver(
        name,
        tools: tools,
        work: work,
        scenario: scenario,
        extra: ["--lease", device.appendingPathComponent("work/lease").path]
    )
    let exit = d.finish(1500)
    let saved = d.events.one("snapshot")
    guard exit == 0, d.events.find("seen").first?.bool("found") == true, saved.int("status") == 2,
        let argv = d.events.one("argv")["normalized"] as? [String]
    else {
        print(d.tail)
        die("no Home snapshot of \(base.entryID): the cold boot or the save failed (\(device.path))", code: 1)
    }
    let staging = root.appendingPathComponent("\(key).tmp")
    try? fm.removeItem(at: staging)
    do {
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try fm.moveItem(at: state, to: staging.appendingPathComponent("state.bin"))
        try fm.moveItem(at: device.appendingPathComponent("overlay"), to: staging.appendingPathComponent("overlay"))
        try JSONEncoder().encode(argv).write(to: staging.appendingPathComponent("argv.json"))
        try fm.moveItem(at: staging, to: dir)
    } catch { die("could not store the snapshot in \(dir.path): \(error)", code: 3) }
    print(
        "snapshot: \(dir.path), taken in \(format(Date().timeIntervalSince(started))) s "
            + "(\((saved.int("bytes") ?? 0) >> 20) MiB)"
    )
    return (dir, argv)
}
