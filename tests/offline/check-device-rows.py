#!/usr/bin/env python3
"""Sidebar row states and commands from the shipped catalog, library and sessions.

Compiles DeviceSession.swift's row model with the real FirmwareCatalog against
Resources/firmware-catalog.json and checks every state, its accessory words,
the placeholder's one button, and which commands each state allows. No app,
no guest, no state directory.
"""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[2] / 'LightTouchMac'

check = r'''
import Foundation
@main struct Check {
    static func main() throws {
        let catalog = try FirmwareCatalog.load(from: URL(fileURLWithPath: CommandLine.arguments[1]))
        func entry(_ id: String) -> FirmwareCatalog.Entry { catalog.entry(id: id)! }
        let iPod = entry("n72ap-7E18"), iPad = entry("k48ap-7B500"), iPad32 = entry("k48ap-7B367")
        let iPad4 = entry("k48ap-8C148"), iPod4 = entry("n72ap-8C148"), iPod2 = entry("n72ap-5F138")
        let id = UUID()
        func row(_ e: FirmwareCatalog.Entry, instance: UUID? = nil, session: SessionPhase? = nil,
                 job: FirmwareJob? = nil, failure: String? = nil) -> DeviceRow {
            DeviceRow(entry: e, instanceID: instance, session: session, job: job, failure: failure)
        }
        func allowed(_ r: DeviceRow, canDownload: Bool = false) -> Set<String> {
            Set(DeviceAction.allCases.filter { r.allows($0, canDownload: canDownload) }.map { "\($0)" })
        }

        // iPod 3.1.3 is the built-in device (a packed prepared base in the bundle, unpacked at first
        // launch); with no record its Prepare needs no preparer. It is also a user_ipsw entry.
        var r = row(iPod)
        precondition(iPod.bundled == "device/n72ap-7E18.itbase" && r.state == .bundled && r.primaryTitle == "Prepare")
        precondition(r.stateDescription == "Built in" && !r.isStartable)
        precondition(allowed(r) == ["importIPSW", "downloadAndPrepare"], "\(allowed(r))")
        precondition(iPod4.bundled == nil && row(iPod4).state != .bundled)
        r = row(iPod, instance: id)
        precondition(r.state == .ready && r.isStartable && r.primaryTitle == "Start")
        precondition(allowed(r) == ["start", "erase", "showInFinder", "delete"], "\(allowed(r))")
        precondition(r.title == "iOS 3.1.3" && !r.isExperimental && r.stateDescription == "Ready")

        // An IPSW entry without a device is not downloaded, with its size.
        r = row(iPad)
        guard case let .notDownloaded(bytes) = r.state, bytes == 479001595 else { fatalError("\(r.state)") }
        precondition(r.primaryAction == .downloadAndPrepare && r.primaryTitle == "Download & Prepare")
        precondition(allowed(r) == ["importIPSW"], "download stays off until W5/W6: \(allowed(r))")
        precondition(allowed(r, canDownload: true) == ["importIPSW", "downloadAndPrepare"])
        precondition(r.stateDescription.hasPrefix("Not downloaded, ") && r.stateDescription.contains("MB"))

        // Its IPSW already in a store: Downloaded, and the button prepares.
        r = DeviceRow(entry: iPad, instanceID: nil, session: nil, job: nil, failure: nil, downloaded: true)
        precondition(r.state == .downloaded && r.primaryTitle == "Prepare" && r.stateDescription == "Downloaded")
        precondition(allowed(r, canDownload: true) == ["importIPSW", "downloadAndPrepare"])

        // Adopted or prepared: ready, with the record's commands.
        r = row(iPad, instance: id)
        precondition(r.state == .ready && allowed(r) == ["start", "erase", "showInFinder", "delete"], "\(allowed(r))")

        // Sessions outrank everything else.
        r = row(iPad, instance: id, session: .running, job: .failed("x"), failure: "y")
        precondition(r.state == .running && r.primaryAction == nil && r.stateDescription == "Running")
        precondition(allowed(r) == ["stop", "erase", "showInFinder"], "no delete while running: \(allowed(r))")
        r = row(iPad, instance: id, session: .stopping)
        precondition(r.state == .stopping && allowed(r) == ["showInFinder"], "\(allowed(r))")
        r = row(iPad, instance: id, session: .stopped)
        precondition(r.state == .ready && allowed(r) == ["start", "erase", "showInFinder"], "powered off starts again: \(allowed(r))")
        r = row(iPod, instance: id, session: .dead("The iPod stopped."))
        precondition(r.state == .error("The iPod stopped.") && r.stateDescription == "Error")
        precondition(r.allows(.start, canDownload: false), "a dead session's Start restarts it")

        // Jobs: downloading and preparing, with progress and Cancel.
        r = row(iPad32, job: .downloading(fraction: 0.425))
        precondition(r.state == .downloading(fraction: 0.425) && r.stateDescription == "Downloading, 42%", r.stateDescription)
        precondition(r.primaryTitle == "Cancel" && allowed(r) == ["cancel"], "\(allowed(r))")
        precondition(r.progress == 0.425 && r.progressLines == ["42%"], "\(r.progressLines)")
        r = row(iPad32, job: .downloading(fraction: 0.5, remaining: 125))
        precondition(r.progressLines == ["50% · About 2 min remaining"] && r.progressSummary == "50%", "\(r.progressLines)")
        r = row(iPad32, job: .preparing(.init(step: 2, steps: 5, name: "Decrypting")))
        precondition(r.stateDescription == "Preparing, Step 2 of 5 · 20%" && allowed(r, canDownload: true) == ["cancel"], r.stateDescription)

        // Overall progress: equal steps without the preparer's seconds, weighted by them with.
        var p = Preparation(step: 6, steps: 7, name: "Sealing the NAND", fraction: 0.5)
        precondition(abs(row(iPad32, job: .preparing(p)).progress! - 5.5 / 7) < 1e-9)
        p.seconds = [2, 5, 1, 12, 4, 71, 3]
        precondition(abs(p.overall! - (24 + 35.5) / 98) < 1e-9, "\(p.overall!)")
        p.detail = "Booting to seal the flash — 42 s"
        p.remaining = 45
        r = row(iPad32, job: .preparing(p))
        precondition(r.progressSummary == "Step 6 of 7 · 60%", r.progressSummary ?? "nil")
        precondition(r.progressLines == ["Step 6 of 7: Sealing the NAND", "Booting to seal the flash — 42 s", "60% · About 50 s remaining"],
                     "\(r.progressLines)")
        p.step = 7; p.fraction = 1
        precondition(p.overall == 1)
        r = row(iPad32, job: .preparing(.init(name: "Checking the IPSW")))
        precondition(r.progress == nil && r.progressLines == ["Checking the IPSW"] && r.stateDescription == "Preparing, Checking the IPSW")

        // Time remaining: nothing for the first 5 s or 2 %, then the rate so far.
        precondition(estimatedRemaining(elapsed: 4, from: 0, to: 0.5) == nil && estimatedRemaining(elapsed: 60, from: 0.3, to: 0.31) == nil)
        precondition(estimatedRemaining(elapsed: 30, from: 0, to: 0.25) == 90 && estimatedRemaining(elapsed: 10, from: 0.5, to: 0.75) == 10)
        precondition(DeviceRow.remainingText(5) == "Almost done" && DeviceRow.remainingText(41) == "About 50 s remaining"
                     && DeviceRow.remainingText(3000) == "About 50 min remaining" && DeviceRow.remainingText(7200) == "About 2 h remaining")
        r = row(iPad32, job: .failed("The download is damaged. Try again."))
        precondition(r.state == .error("The download is damaged. Try again.") && r.primaryTitle == "Try Again")
        precondition(r.primaryAction == .downloadAndPrepare, "retrying a failed download downloads again")

        // A start failure: Try Again starts again.
        r = row(iPod, instance: id, failure: "These device files are missing: /x")
        precondition(r.state == .error("These device files are missing: /x") && r.primaryAction == .start)
        precondition(r.primaryTitle == "Try Again" && r.allows(.start, canDownload: false))

        // Unavailable entries are dimmed and offer nothing but their reason.
        r = row(iPod2)
        precondition(r.state == .unavailable(.comingSoon) && r.isDimmed && r.primaryAction == nil)
        precondition(allowed(r, canDownload: true).isEmpty && r.stateDescription == "Coming soon")
        precondition(row(iPod2, job: .downloading(fraction: 0.5)).state == .unavailable(.comingSoon))
        var beta = iPad
        beta.status = .userIPSW
        beta.source.url = nil
        r = row(beta)
        precondition(r.state == .unavailable(.requiresIPSW) && r.primaryTitle == "Import IPSW…")
        precondition(allowed(r, canDownload: true) == ["importIPSW"] && r.stateDescription == "Requires an IPSW")
        precondition(row(beta, instance: id).state == .ready, "an imported beta runs like any device")
        precondition(row(beta, failure: "x").primaryAction == .importIPSW, "a failed import offers the import again")

        // Experimental carries a tag and a note.
        r = row(iPad4)
        precondition(r.isExperimental && iPad4.statusNote != nil)
        // iPod 4.2.1 downloads and prepares like the iPads.
        r = row(iPod4)
        precondition(r.isExperimental && iPod4.statusNote != nil && r.primaryAction == .downloadAndPrepare)
        print("PASS: row states, accessories, primary buttons and commands for every catalog status")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='ltm-device-rows-') as tmp:
    tmp = Path(tmp)
    (tmp / 'main.swift').write_text(check)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(tmp / 'modules'),
                    str(root / 'FirmwareCatalog.swift'), str(root / 'DeviceProfile.swift'),
                    str(root / 'DeviceRow.swift'), str(tmp / 'main.swift'), '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check'), str(root / 'Resources/firmware-catalog.json')], check=True)
