import ArgumentParser
import BuildSupport
import FirmwareSchema
import Foundation
import LightTouchCore
import SessionKit

struct AffectedCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "affected",
        abstract: "What a change needs checked, from the paths it touches: the Unit plan, and which family rows boot.",
        discussion: """
            RANGE is what git diff takes (main: the work tree against main; main...HEAD: the branch's commits). \
            Documentation needs nothing; the app target's code, tests and scripts the Unit plan; preparation code \
            for one board family (FirmwareKit's K48, N45, N72, KBoot) that family's rows; anything else (the rest of \
            FirmwareKit, the helper, the emulator's pin, guest code, the drivers, a path no rule names) a boot of every \
            family: \(Affected.families.map { $0.row + ($0.create.isEmpty ? "" : " " + $0.create.joined(separator: " ")) }.joined(separator: ", ")). \
            With --run, the Unit plan and then those rows through sessions matrix: a fresh base from --bases \
            (DIR/ROW) when there is one, else prepared from its IPSW (the app's downloads and imports, or \
            --ipsw-dir); missing firmware refuses --run (exit 2), so a partial gate cannot pass.
            """
    )
    @Argument(help: "The change, as git diff takes it.") var range: String
    @Flag(name: .customLong("run"), help: "Run the plan, not only print it.") var execute = false
    @Option(help: "Prepared bases to reuse, as DIR/ROW.", transform: path) var bases: URL?
    @Option(help: "Where to look for IPSWs by name (repeatable).", transform: path)
    var ipswDir: [URL] = [
        home.appendingPathComponent("Developer/qemu-ios-files"), home.appendingPathComponent("Downloads")
    ]
    @Option(help: "Jobs at once (sessions matrix --lanes).") var lanes = 3
    @OptionGroup var inputs: Inputs

    func run() { affected(self) }
}

/// The catalog row's IPSW on this Mac: the app's store by SHA-1, else a file of its name under `dirs`.
func localIPSW(_ row: String, dirs: [URL]) -> URL? {
    guard let entry = catalogEntries.first(where: { $0.id == row }) else { return nil }
    if let sha1 = entry.source.sha1, let stored = IPSWStore.shared.existing(sha1) { return stored }
    guard let name = entry.source.url?.lastPathComponent else { return nil }
    for dir in dirs {
        let found = output("/usr/bin/find", [dir.path, "-maxdepth", "5", "-name", name, "-type", "f"])
            .split(separator: "\n").first
        if let found { return URL(fileURLWithPath: String(found)) }
    }
    return nil
}

func affected(_ args: AffectedCheck) -> Never {
    let diff: CommandResult
    do {
        diff = try Shell.run([
            "/usr/bin/git", "-C", repository.path, "diff", "--name-only", "-z", args.range, "--"
        ])
    } catch { die("could not read the change: \(error)", code: 3) }
    guard diff.succeeded else { die("git diff refused \(args.range): \(diff.error)") }
    let changed = diff.output.split(separator: "\0").map(String.init)
    let plan = Affected.plan(paths: changed)
    print("changed: \(changed.count) paths (git diff --name-only \(args.range))")
    if !plan.nothing.isEmpty { print("nothing for: \(plan.nothing.joined(separator: ", "))") }
    if !plan.unitOnly.isEmpty { print("unit only: \(plan.unitOnly.count) paths") }
    let unit = [
        "test", "-project", repository.appendingPathComponent("LightTouchMac.xcodeproj").path, "-scheme",
        "LightTouchMac", "-testPlan", "Unit", "-skipMacroValidation"
    ]
    let needsUnit = changed.count > plan.nothing.count
    print(needsUnit ? "unit: xcodebuild \(unit.joined(separator: " "))" : "unit: none")
    // Preparation code: its volumes against the recorded listings first, booting nothing (they can't see boot-time
    // regressions: the family boots still run).
    let preparation = changed.contains {
        $0.hasPrefix("Packages/FirmwareKit/Sources/") || $0.hasPrefix("LightTouchMac/Resources/firmware-catalog")
    }
    if preparation { print("listings: sessions listings (every family row's volumes)") }
    let rows = Affected.families.filter { plan.boards.contains(String($0.row.prefix { $0 != "-" })) }
    if rows.isEmpty { print("boot: none") }
    var jobs: [String] = []
    var skipped: [String] = []
    for (row, create) in rows {
        let board = String(row.prefix { $0 != "-" })
        let reason = "\(row)\(create.isEmpty ? "" : " " + create.joined(separator: " ")) (\(plan.reasons[board] ?? ""))"
        if let base = args.bases?.appendingPathComponent(row),
            let lock = (try? Data(contentsOf: base.appendingPathComponent("device.lock.json")))
                .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
            PreparationChanges.verdict(lock: lock, catalog: catalogEntries).stale.isEmpty
        {
            print("boot: \(reason) on \(base.path)")
            jobs.append("\(row) \(base.path)")
        } else if let ipsw = localIPSW(row, dirs: args.ipswDir) {
            print("boot: \(reason), prepared from \(ipsw.path)")
            jobs.append("\(row) --id \(row) --ipsw \(ipsw.path) \(create.joined(separator: " "))")
        } else {
            print("boot: \(reason) SKIPPED: no IPSW for it on this Mac")
            skipped.append(row)
        }
    }
    guard args.execute else { exit(0) }

    guard skipped.isEmpty else {
        die("incomplete affected gate; missing firmware for \(skipped.joined(separator: ", "))")
    }
    let work = workDirectory(args.inputs, "affected")
    if needsUnit {
        let log = work.appendingPathComponent("unit.log")
        print("running the Unit plan (log \(log.path))")
        fflush(stdout)
        guard run("/usr/bin/xcodebuild", unit, log: log) == 0 else {
            print("FAIL the Unit plan \(log.path)")
            exit(1)
        }
    }
    if preparation {
        var listings = ["listings", "--work", work.appendingPathComponent("listings").path]
        listings += args.ipswDir.flatMap { ["--ipsw-dir", $0.path] }
        guard sessions(listings, args.inputs) == 0 else { exit(1) }
    }
    guard !jobs.isEmpty else {
        print("PASS \(needsUnit ? "the Unit plan" : "no checks required") \(work.path)")
        exit(0)
    }
    let file = work.appendingPathComponent("jobs.txt")
    do {
        try (jobs.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    } catch { die("could not write the affected jobs: \(error)", code: 3) }
    var matrix = ["matrix", file.path, "--lanes", "\(args.lanes)", "--work", work.appendingPathComponent("matrix").path]
    if args.inputs.keepWork { matrix.append("--keep-work") }
    exit(sessions(matrix, args.inputs))
}
