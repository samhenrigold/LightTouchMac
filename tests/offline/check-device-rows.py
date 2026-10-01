#!/usr/bin/env python3
"""Sidebar row states and commands from the shipped catalog, library and sessions.

Compiles DeviceSession.swift's row model with the real FirmwareCatalog against
Resources/firmware-catalog.json and checks every state, its accessory words,
the placeholder's one button, and which commands each state allows. No app,
no guest, no state directory.
"""
from pathlib import Path
from firmwarekit_leaf import schema_sources
import subprocess, tempfile

root = Path(__file__).resolve().parents[2] / 'LightTouchMac'

check = r'''
import Foundation
@main struct Check {
    static func main() throws {
        let catalog = try FirmwareCatalog.load(from: URL(fileURLWithPath: CommandLine.arguments[1]))
        func entry(_ id: String) -> FirmwareCatalog.Entry { catalog.entry(id: id)! }
        let iPod = entry("n72ap-7E18"), iPad = entry("k48ap-7B500"), iPad32 = entry("k48ap-7B367")
        let iPad4 = entry("k48ap-8C148"), iPod4 = entry("n72ap-8C148")
        var soon = entry("n72ap-5F138")   // a coming_soon entry (no catalog entry is one today)
        soon.status = .comingSoon
        let id = UUID()
        func row(_ e: FirmwareCatalog.Entry, instance: UUID? = nil, session: SessionPhase? = nil,
                 job: FirmwareJob? = nil, failure: String? = nil) -> DeviceRow {
            DeviceRow(entry: e, instanceID: instance, session: session, job: job, failure: failure)
        }
        func allowed(_ r: DeviceRow, canDownload: Bool = false) -> Set<String> {
            Set(DeviceAction.allCases.filter { r.allows($0, canDownload: canDownload) }.map { "\($0)" })
        }

        // A first launch selects a build Apple still serves, ready to Download & Prepare: no device ships in the app.
        let first = catalog.firstRunEntry!
        precondition(first.status == .available && first.source.url?.host == "secure-appldnld.apple.com", "first run: \(first.id)")
        var r = row(first)
        guard case .notDownloaded = r.state else { fatalError("first run: \(r.state)") }
        precondition(r.primaryTitle == "Download & Prepare" && allowed(r, canDownload: true) == ["importIPSW", "downloadAndPrepare"])
        // iPod 3.1.3 (user_ipsw) with no record asks for its IPSW; nothing prepares it without one.
        r = row(iPod)
        precondition(r.state == .unavailable(.requiresIPSW) && r.primaryTitle == "Import IPSW…" && !r.isStartable, "\(r.state)")
        precondition(allowed(r, canDownload: true) == ["importIPSW"], "\(allowed(r, canDownload: true))")
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
        precondition(r.progress == 0.425 && r.progressLine == "42%" && r.progressDetail.isEmpty, "\(r.progressDetail)")
        r = row(iPad32, job: .downloading(fraction: 0.5, remaining: 125))
        precondition(r.progressLine == "50% · About 2 min remaining" && r.progressSummary == "50%", r.progressLine ?? "nil")
        // A build that boots its sibling's ramdisk: one job, both IPSWs, one bar.
        r = row(iPad32, job: .downloading(fraction: 0.25, files: 2))
        precondition(r.progressSummary == "25%" && r.progressLine == "25%" && r.progressDetail == ["2 IPSWs"] && r.progress == 0.25, "\(r.progressDetail)")
        precondition(r.stateDescription == "Downloading, 25%" && r.primaryTitle == "Cancel", r.stateDescription)
        r = row(iPad32, job: .preparing(.init(step: 2, steps: 5, name: "Decrypting")))
        precondition(r.stateDescription == "Preparing, 20%" && allowed(r, canDownload: true) == ["cancel"], r.stateDescription)

        // Overall progress: equal steps without the preparer's seconds, weighted by them with.
        var p = Preparation(step: 6, steps: 7, name: "Sealing the NAND", fraction: 0.5)
        precondition(abs(row(iPad32, job: .preparing(p)).progress! - 5.5 / 7) < 1e-9)
        p.seconds = [2, 5, 1, 12, 4, 71, 3]
        precondition(abs(p.overall! - (24 + 35.5) / 98) < 1e-9, "\(p.overall!)")
        p.detail = "Booting to seal the flash — 42 s"
        p.remaining = 45
        r = row(iPad32, job: .preparing(p))
        precondition(r.progressSummary == "60%", r.progressSummary ?? "nil")
        // The placeholder shows one plain line; the preparer's step and its words are the bar's tooltip.
        precondition(r.progressLine == "60% · About 50 s remaining", r.progressLine ?? "nil")
        precondition(r.progressDetail == ["Step 6 of 7: Sealing the NAND", "Booting to seal the flash — 42 s"], "\(r.progressDetail)")
        p.step = 7; p.fraction = 1
        precondition(p.overall == 1)
        r = row(iPad32, job: .preparing(.init(name: "Checking the IPSW")))
        precondition(r.progress == nil && r.progressLine == nil && r.progressDetail == ["Checking the IPSW"] && r.stateDescription == "Preparing…")
        precondition(r.accessory == .progress(nil, nil), "no fraction yet: the ring spins, no words")

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
        r = row(soon)
        precondition(r.state == .unavailable(.comingSoon) && r.isDimmed && r.primaryAction == nil)
        precondition(allowed(r, canDownload: true).isEmpty && r.stateDescription == "Coming soon")
        precondition(row(soon, job: .downloading(fraction: 0.5)).state == .unavailable(.comingSoon))
        var beta = iPad
        beta.status = .userIPSW
        beta.source.url = nil
        r = row(beta)
        precondition(r.state == .unavailable(.requiresIPSW) && r.primaryTitle == "Import IPSW…")
        precondition(allowed(r, canDownload: true) == ["importIPSW"] && r.stateDescription == "Requires an IPSW")
        precondition(row(beta, instance: id).state == .ready, "an imported beta runs like any device")
        precondition(row(beta, failure: "x").primaryAction == .importIPSW, "a failed import offers the import again")

        // Experimental carries the tag; a status note is the catalog's to add when it says more than the tag.
        r = row(entry("k48ap-8L1"))   // 4.2.1 is available since 09-29; 4.3.5 is still experimental
        precondition(r.isExperimental)
        precondition(!row(iPad4).isExperimental)
        // iPod 4.2.1 downloads and prepares like the iPads.
        r = row(iPod4)
        precondition(r.isExperimental && r.primaryAction == .downloadAndPrepare)
        precondition(r.badge == nil && r.supportNote == "Experimental" && row(iPad).badge == nil && row(iPad).supportNote == nil,
                     "Experimental is the tooltip's and VoiceOver's, not a capsule in the row")
        // A developer build: its badge is the beta/GM ordinal.
        let beta3 = entry("k48ap-8C5115c"), gm2 = entry("k48ap-8C134b"), beta1 = entry("n72ap-8C5091e")   // an untested Beta 1 (8A230m went experimental 09-30)
        precondition(row(beta3).badge == "Beta 3" && row(gm2).badge == "GM 2" && row(beta1).badge == "Beta 1", "\(row(beta1).badge ?? "nil")")
        var unnumbered = beta1
        unnumbered.prereleaseNumber = nil
        precondition(row(unnumbered).badge == "Beta 1" && entry("k48ap-8C134").prereleaseBadge == "GM 1", "a first beta/GM without a number is 1")

        // Untested builds (betas from archive.org, releases the matrix hasn't run) download and
        // prepare like any other, with an Untested note; coming soon stays shut (above).
        for e in [entry("n72ap-8C5091e"), entry("n45ap-3B48b"), entry("n72ap-7A341")] {   // still untested after the 09-30 sweep
            precondition(e.status == .untested && e.source.url?.scheme == "https", e.id)
            r = row(e)
            guard case .notDownloaded = r.state else { fatalError("\(e.id): \(r.state)") }
            precondition(!r.isDimmed && r.primaryAction == .downloadAndPrepare && r.primaryTitle == "Download & Prepare", e.id)
            precondition(allowed(r, canDownload: true) == ["importIPSW", "downloadAndPrepare"], "\(e.id): \(allowed(r, canDownload: true))")
            precondition(r.note == nil && r.supportNote == "Untested" && r.stateDescription.hasPrefix("Not downloaded"), e.id)
            precondition(row(e, job: .downloading(fraction: 0.5)).state == .downloading(fraction: 0.5), e.id)
            precondition(row(e, instance: id).state == .ready && row(e, instance: id).isStartable, e.id)
        }
        precondition(row(beta1).badge == "Beta 1" && row(entry("n72ap-8B117")).badge == nil, "the badge stays on an offered beta")
        precondition(row(iPad).note == nil && row(iPod4).note == nil, "tested builds carry no note")
        // The sidebar shows only what differs from the usual (DeviceRow.accessory, what the cell draws).
        let downloaded = DeviceRow(entry: iPad, instanceID: nil, session: nil, job: nil, failure: nil, downloaded: true)
        precondition(downloaded.accessory == .none, "Downloaded is the normal state: nothing after the title")
        precondition(row(iPad, instance: id).accessory == .none, "ready: nothing")
        precondition(row(iPad).accessory == .notDownloaded && row(beta1).accessory == .notDownloaded, "not here yet: the download glyph")
        precondition(row(iPad32, job: .downloading(fraction: 0.425)).accessory == .progress(0.425, "42%"))
        precondition(row(iPad32, job: .preparing(p)).accessory == .progress(1, "100%"))
        precondition(row(iPad, instance: id, session: .running).accessory == .running && row(iPad, instance: id, session: .stopping).accessory == .stopping)
        precondition(row(iPod, instance: id, session: .dead("x")).accessory == .error && row(soon).accessory == .text("Coming soon"))
        precondition(row(beta).accessory == .text("Requires an IPSW"))
        let running = row(beta1, instance: id, session: .running)
        precondition(running.accessory == .running && running.note == nil, "a running untested build: the dot alone, no \"Untested\" beside it")
        precondition(DeviceRow(entry: iPad, instanceID: id, session: nil, job: nil, failure: nil, preparedWithoutActivation: true).note
                     == "Prepared without activation")
        // The prepare screen: the catalog note (untested, experimental, a beta's source) is one popover's text,
        // and disk numbers appear only when the volume can't hold the download and the preparation.
        precondition(row(beta1).catalogNote?.hasPrefix("Untested. ") == true && row(iPad).catalogNote == nil, row(beta1).catalogNote ?? "nil")
        precondition(row(iPod4).catalogNote?.hasPrefix("Experimental.") == true, row(iPod4).catalogNote ?? "nil")
        let needed = 479001595 + iPad.estimates.peakBytes
        precondition(needed > 479001595 && row(iPad).spaceShortage(available: needed) == nil)
        precondition(row(iPad).spaceShortage(available: needed - 1)?.hasPrefix("Not enough disk space: this needs ") == true)
        precondition(row(iPad, instance: id).spaceShortage(available: 0) == nil, "a prepared device needs no space")
        precondition(row(iPad32, job: .downloading(fraction: 0.5)).spaceShortage(available: 0) == nil, "nor does one already downloading")
        // The sidebar lists in catalog order: version order, a version's betas right before its release.
        let ids = catalog.entries.map(\.id)
        precondition(ids.firstIndex(of: "k48ap-8L1")! < ids.firstIndex(of: "k48ap-9A5220p")! && ids.firstIndex(of: "k48ap-9A5288d")! < ids.firstIndex(of: "k48ap-9A334")!
                     && ids.firstIndex(of: "n72ap-8A400")! < ids.firstIndex(of: "n72ap-8B5080c")!, "sidebar order: \(ids)")
        print("PASS: row states, accessories, primary buttons and commands for every catalog status")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='ltm-device-rows-') as tmp:
    tmp = Path(tmp)
    (tmp / 'main.swift').write_text(check)
    subprocess.run(['xcrun', 'swiftc', *schema_sources(), '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(tmp / 'modules'),
                    str(root / 'Library/FirmwareCatalog.swift'), str(root / 'Device/DeviceProfile.swift'),
                    str(root / 'Device/DeviceRow.swift'), str(tmp / 'main.swift'), '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check'), str(root / 'Resources/firmware-catalog.json')], check=True)
