import ArgumentParser
import FirmwareKit
import Foundation
import LightTouchCore
import SessionKit

struct ListingsCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "listings",
        abstract: "Preparation's gate, booting nothing: each row's volumes against their recorded listings.",
        discussion: """
            Each row is prepared with firmwarekit create --stop-after volumes (a fixed seed, en-US and no other \
            keyboard, so two runs of one tree write the same files), in parallel, and every volume image is listed \
            (VolumeListing: paths, owners, modes, flags, sizes, content hashes, link targets; no dates) and compared \
            with tests/sessions/listings/ROW/IMAGE.txt.gz. A row whose IPSW is missing is reported; an incomplete gate exits 2. \
            --record writes what this tree makes, printing every change: a commit that re-records says why each \
            changed path changed. It can't see what only a boot shows; sessions affected says when to boot.
            """
    )
    @Argument(help: "Rows (default: sessions affected's family rows), each ROW or ROW+FLAG,… (n81ap-9B176+jailbreak).")
    var rows: [String] = []
    @Flag(help: "Write the listings this tree makes over the recorded ones (the change printed).") var record = false
    @Option(help: "Where to look for IPSWs by name (repeatable).", transform: path)
    var ipswDir: [URL] = [
        home.appendingPathComponent("Developer/qemu-ios-files"), home.appendingPathComponent("Downloads")
    ]
    @Option(help: "Rows at once.") var lanes = 4
    @Option(help: "Changed lines printed per volume.") var show = 40
    @OptionGroup var inputs: Inputs

    func run() { listings(self) }
}

let listingsDirectory = repository.appendingPathComponent("tests/sessions/listings")

/// A volume image's listing (VolumeListing's format).
func volumeListing(_ image: URL) throws -> String {
    let v = try HFSPlusVolume(image)
    var lines = [
        "# \(v.signature) bs=\(v.blockSize) total=\(v.totalBlocks) free=\(v.freeBlocks) files=\(v.fileCount) dirs=\(v.folderCount)"
    ]
    for e in try v.listing() {
        lines.append(
            [
                e.path, "\(e.uid):\(e.gid)", String(e.mode, radix: 8), String(e.flags, radix: 16), "\(e.size)",
                "\(e.resourceSize)", e.sha256.map { String($0.prefix(16)) } ?? "-", e.link ?? "-"
            ].joined(separator: "\t")
        )
    }
    return lines.joined(separator: "\n") + "\n"
}

func listings(_ args: ListingsCheck) -> Never {
    let rows =
        args.rows.isEmpty
        ? Affected.families.map { $0.row + $0.create.map { "+" + $0.dropFirst(2) }.joined() } : args.rows
    var inputs = args.inputs
    inputs.keepWork = true
    let work = workDirectory(inputs, "listings")
    let app = Tools.bundle(args.inputs, work: work)
    let firmwarekit = app.appendingPathComponent("Contents/MacOS/firmwarekit")
    let guestTools = Tools.unpack(app.appendingPathComponent("Contents/Resources/Guest/guest.aar"), into: work)
        .appendingPathComponent("guest-tools")
    var env = ProcessInfo.processInfo.environment
    env["FIRMWAREKIT_IBOOT_PATCHER"] = app.appendingPathComponent("Contents/MacOS/iBoot32Patcher").path
    let environment = env
    let (record, show, dirs) = (args.record, args.show, args.ipswDir)

    final class Results: @unchecked Sendable {
        let lock = NSLock()
        var lines: [String] = []
        var failed = 0, skipped = 0
    }
    let results = Results()
    let lanes = DispatchSemaphore(value: max(1, args.lanes))
    let group = DispatchGroup()
    let started = Date()
    for name in rows {
        lanes.wait()
        group.enter()
        Thread.detachNewThread {
            defer {
                lanes.signal()
                group.leave()
            }
            var said: [String] = []
            var pass = true
            var skip = false
            defer {
                results.lock.lock()
                print(said.joined(separator: "\n"))
                fflush(stdout)
                results.lines.append(said.first ?? name)
                if !pass { results.failed += 1 }
                if skip { results.skipped += 1 }
                results.lock.unlock()
            }
            let parts = name.split(separator: "+").map(String.init)
            let row = parts[0]
            guard let ipsw = localIPSW(row, dirs: dirs) else {
                skip = true
                said.append("SKIP \(name): no IPSW for it on this Mac")
                return
            }
            let dir = work.appendingPathComponent(name)
            let out = dir.appendingPathComponent("out")
            let t = Date()
            let status = run(
                firmwarekit.path,
                [
                    "create", "--catalog",
                    repository.appendingPathComponent("LightTouchMac/Resources/firmware-catalog.json").path, "--id",
                    row, "--ipsw", ipsw.path, "--out", out.path, "--cache", dir.appendingPathComponent("cache").path,
                    "--guest-tools", guestTools.path, "--stop-after", "volumes", "--seed", "listings", "--language",
                    "en-US", "--keyboards", ""
                ] + parts.dropFirst().map { "--" + $0 },
                log: dir.appendingPathComponent("create.log"),
                environment: environment
            )
            guard status == 0 else {
                pass = false
                said.append("FAIL \(name): firmwarekit create exited \(status) (\(dir.path)/create.log)")
                return
            }
            let images =
                ((try? FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("volumes").path))
                ?? []).sorted()
            let recordedDir = listingsDirectory.appendingPathComponent(name)
            var changes: [String] = []
            var notes: [String] = []
            var wrote = false
            for image in images {
                let file = recordedDir.appendingPathComponent(image + ".txt.gz")
                let current: String
                do { current = try volumeListing(out.appendingPathComponent("volumes/" + image)) } catch {
                    pass = false
                    notes.append("  \(image): can't list it: \(error)")
                    continue
                }
                let recorded =
                    FileManager.default.fileExists(atPath: file.path)
                    ? output("/usr/bin/gzip", ["-dc", file.path]) : nil
                let diff = recorded.map { VolumeListing.diff(recorded: $0, current: current) }
                if recorded == nil { notes.append("  \(image): nothing recorded") }
                if let diff, !diff.isEmpty {
                    changes.append(image)
                    notes.append("  \(image): \(diff.count) lines differ")
                    notes += diff.prefix(show).map { "    " + $0 }
                    if diff.count > show { notes.append("    … \(diff.count - show) more") }
                }
                if record, diff?.isEmpty != true {
                    try? FileManager.default.createDirectory(at: recordedDir, withIntermediateDirectories: true)
                    let plain = URL(fileURLWithPath: String(file.path.dropLast(3)))
                    let written = (try? current.write(to: plain, atomically: true, encoding: .utf8)) != nil
                    if !written || run("/usr/bin/gzip", ["-9nf", plain.path]) != 0 {
                        pass = false
                        notes.append("  \(image): can't write \(file.path)")
                    }
                    wrote = true
                } else if diff?.isEmpty != true {
                    pass = false
                }
            }
            if images.isEmpty {
                pass = false
                notes.append("  no volume images in \(out.path)/volumes")
            }
            let seconds = Int(Date().timeIntervalSince(t))
            said.append(
                "\(pass ? (wrote ? "RECORDED" : "PASS") : "FAIL") \(name): "
                    + "\(images.count) volumes in \(seconds) s"
                    + (changes.isEmpty ? "" : ", changed: \(changes.joined(separator: ", "))")
            )
            said += notes
            if pass { try? DeviceStateStorage.removeTree(dir) }
        }
    }
    group.wait()
    let (lines, failed, skipped) = (results.lines, results.failed, results.skipped)
    try? FileManager.default.removeItem(at: work.appendingPathComponent("tools"))
    let summary =
        "\(rows.count - failed - skipped)/\(rows.count) rows as recorded"
        + (skipped > 0 ? ", \(skipped) skipped" : "") + " in \(Int(Date().timeIntervalSince(started))) s"
    let first = lines.first { $0.hasPrefix("FAIL") }.map { String($0.dropFirst(5)) + " " } ?? ""
    let status = failed > 0 ? 1 : (skipped > 0 ? 2 : 0)
    print("\(status == 0 ? "PASS" : "FAIL") \(first)(\(summary)) \(work.path)")
    exit(Int32(status))
}
