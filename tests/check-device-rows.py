#!/usr/bin/env python3
"""Sidebar row states and commands from the shipped catalog, library and sessions.

Compiles DeviceSession.swift's row model with the real FirmwareCatalog against
Resources/firmware-catalog.json and checks every state, its accessory words,
the placeholder's one button, and which commands each state allows. No app,
no guest, no state directory.
"""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[1] / 'LightTouchMac'
source = (root / 'DeviceSession.swift').read_text()
rows = source[source.index('// MARK: - Row state'):source.index('// MARK: - Firmware jobs')]

check = r'''
import Foundation
@main struct Check {
    static func main() throws {
        let catalog = try FirmwareCatalog.load(from: URL(fileURLWithPath: CommandLine.arguments[1]))
        func entry(_ id: String) -> FirmwareCatalog.Entry { catalog.entry(id: id)! }
        let iPod = entry("n72ap-7E18"), iPad = entry("k48ap-7B500"), iPad32 = entry("k48ap-7B367")
        let iPad4 = entry("k48ap-8C148"), iPod4 = entry("n72ap-8C148")
        let id = UUID()
        func row(_ e: FirmwareCatalog.Entry, instance: UUID? = nil, session: SessionPhase? = nil,
                 job: FirmwareJob? = nil, failure: String? = nil) -> DeviceRow {
            DeviceRow(entry: e, instanceID: instance, session: session, job: job, failure: failure)
        }
        func allowed(_ r: DeviceRow, canDownload: Bool = false) -> Set<String> {
            Set(DeviceAction.allCases.filter { r.allows($0, canDownload: canDownload) }.map { "\($0)" })
        }

        // The bundled iPod is ready without a record: starting adopts it.
        var r = row(iPod)
        precondition(r.state == .ready && r.isStartable && r.primaryTitle == "Start")
        precondition(allowed(r) == ["start"], "\(allowed(r))")
        precondition(r.title == "iOS 3.1.3" && !r.isExperimental && r.stateDescription == "Ready")

        // An IPSW entry without a device is not downloaded, with its size.
        r = row(iPad)
        guard case let .notDownloaded(bytes) = r.state, bytes == 479001595 else { fatalError("\(r.state)") }
        precondition(r.primaryAction == .downloadAndPrepare && r.primaryTitle == "Download & Prepare")
        precondition(allowed(r) == ["importIPSW"], "download stays off until W5/W6: \(allowed(r))")
        precondition(allowed(r, canDownload: true) == ["importIPSW", "downloadAndPrepare"])
        precondition(r.stateDescription.hasPrefix("Not Downloaded, ") && r.stateDescription.contains("MB"))

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
        r = row(iPod, instance: id, session: .dead("The emulator stopped."))
        precondition(r.state == .error("The emulator stopped.") && r.stateDescription == "Error")
        precondition(!r.allows(.start, canDownload: false), "a dead in-process session can't start again")

        // Jobs: downloading and preparing, with progress and Cancel.
        r = row(iPad32, job: .downloading(fraction: 0.425))
        precondition(r.state == .downloading(fraction: 0.425) && r.stateDescription == "Downloading, 43%")
        precondition(r.primaryTitle == "Cancel" && allowed(r) == ["cancel"], "\(allowed(r))")
        r = row(iPad32, job: .preparing(step: 2, of: 5, name: "Decrypting"))
        precondition(r.stateDescription == "Preparing, Step 2 of 5" && allowed(r, canDownload: true) == ["cancel"])
        r = row(iPad32, job: .failed("Download corrupted."))
        precondition(r.state == .error("Download corrupted.") && r.primaryTitle == "Try Again")
        precondition(r.primaryAction == .downloadAndPrepare, "retrying a failed download downloads again")

        // A start failure: Try Again starts again.
        r = row(iPod, failure: "These device files are missing: /x")
        precondition(r.state == .error("These device files are missing: /x") && r.primaryAction == .start)
        precondition(r.primaryTitle == "Try Again" && r.allows(.start, canDownload: false))

        // Unavailable entries are dimmed and offer nothing but their reason.
        r = row(iPod4)
        precondition(r.state == .unavailable(.comingSoon) && r.isDimmed && r.primaryAction == nil)
        precondition(allowed(r, canDownload: true).isEmpty && r.stateDescription == "Coming Soon")
        precondition(row(iPod4, job: .downloading(fraction: 0.5)).state == .unavailable(.comingSoon))
        var beta = iPad
        beta.status = .userIPSW
        beta.source.url = nil
        r = row(beta)
        precondition(r.state == .unavailable(.requiresIPSW) && r.primaryTitle == "Import IPSW…")
        precondition(allowed(r, canDownload: true) == ["importIPSW"] && r.stateDescription == "Requires IPSW")
        precondition(row(beta, instance: id).state == .ready, "an imported beta runs like any device")

        // Experimental carries a tag and a note.
        r = row(iPad4)
        precondition(r.isExperimental && iPad4.statusNote != nil)
        print("PASS: row states, accessories, primary buttons and commands for every catalog status")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='ltm-device-rows-') as tmp:
    tmp = Path(tmp)
    (tmp / 'rows.swift').write_text('import Foundation\n' + rows)
    (tmp / 'main.swift').write_text(check)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(tmp / 'modules'),
                    str(root / 'FirmwareCatalog.swift'), str(root / 'DeviceProfile.swift'),
                    str(tmp / 'rows.swift'), str(tmp / 'main.swift'), '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check'), str(root / 'Resources/firmware-catalog.json')], check=True)
