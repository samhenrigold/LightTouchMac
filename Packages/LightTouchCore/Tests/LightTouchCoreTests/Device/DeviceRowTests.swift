import FirmwareSchema
import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// Sidebar row states and commands (DeviceRow) from the shipped catalog: every state, its accessory and words, the
/// placeholder's one button, and which commands each state allows.
struct DeviceRowTests {
    let catalog = ShippedResources.catalog
    let id = UUID()
    func entry(_ id: String) -> FirmwareCatalog.Entry { catalog.entry(id: id)! }
    var iPod: FirmwareCatalog.Entry { entry("n72ap-7E18") }
    var iPad: FirmwareCatalog.Entry { entry("k48ap-7B500") }
    var iPad32: FirmwareCatalog.Entry { entry("k48ap-7B367") }
    var iPad4: FirmwareCatalog.Entry { entry("k48ap-8C148") }
    var iPod4: FirmwareCatalog.Entry { entry("n72ap-8C148") }
    var beta1: FirmwareCatalog.Entry { entry("n72ap-8C5091e") }
    var iPad5: FirmwareCatalog.Entry { entry("k48ap-9B206") }
    /// A coming_soon entry (no catalog entry is one today).
    var soon: FirmwareCatalog.Entry {
        var e = entry("n72ap-5F138")
        e.status = .comingSoon
        return e
    }
    /// A beta the user must bring the IPSW for.
    var userBeta: FirmwareCatalog.Entry {
        var e = iPad
        e.status = .userIPSW
        e.source.url = nil
        return e
    }

    func row(_ e: FirmwareCatalog.Entry, instance: UUID? = nil, session: SessionPhase? = nil, job: FirmwareJob? = nil)
        -> DeviceRow
    {
        DeviceRow(entry: e, instanceID: instance, session: session, job: job)
    }
    func allowed(_ r: DeviceRow, canDownload: Bool = false) -> Set<String> {
        Set(DeviceAction.allCases.filter { r.allows($0, canDownload: canDownload) }.map { "\($0)" })
    }
    /// A stopped device's commands before iOS 5, which takes no jailbreak yet.
    static let recordCommands: Set = [
        "start", "erase", "showInFinder", "delete", "openFilesystem", "commitFilesystem", "discardFilesystem",
        "recoverFilesystem"
    ]

    /// Jailbreak…: a prepared device while it is stopped where the sandbox patch resolves, as the preparation's
    /// checkbox allows it (FirmwareJobs.jailbreakWorks: 1.x, iOS 5 on, iOS 4 on the ARMv7 boards; elsewhere Safari
    /// crashes jailbroken).
    @Test func jailbreakIsForAStoppedDeviceWhoseSandboxPatchResolves() throws {
        let m68 = try #require(catalog.entries.first { $0.board == "m68ap" })
        #expect(row(iPad5, instance: id).allows(.jailbreak, canDownload: false))
        #expect(row(iPad4, instance: id).allows(.jailbreak, canDownload: false), "4.x on an ARMv7 board")
        #expect(!row(iPod4, instance: id).allows(.jailbreak, canDownload: false), "4.x on the ARMv6 iPod touch 2G")
        #expect(!row(iPod, instance: id).allows(.jailbreak, canDownload: false), "3.x")
        #expect(row(m68, instance: id).allows(.jailbreak, canDownload: false), "1.x: no Substrate to break Safari")
        #expect(!row(iPad5).allows(.jailbreak, canDownload: true), "not prepared")
        #expect(!row(iPad5, instance: id, session: .running).allows(.jailbreak, canDownload: false), "running")
    }

    /// Several rows: each command acts on the rows its one-row version allows and says how many; none, dimmed.
    @Test func severalRowsActOnTheRowsEachCommandAllows() throws {
        // 4 selected: 2 running, 2 prepared and stopped (one of them the iPod touch 2G's iOS 4, which takes no jailbreak yet).
        let rows = [
            row(iPod, instance: UUID(), session: .running), row(iPad, instance: UUID(), session: .running),
            row(iPad5, instance: UUID()), row(iPod4, instance: UUID())
        ]
        func batch(_ action: DeviceAction, _ rows: [DeviceRow] = rows) throws -> DeviceBatch<DeviceRow> {
            try #require(DeviceBatch(action, rows) { $0.allows(action, canDownload: true) })
        }
        let stop = try batch(.forceStop)
        let start = try batch(.start)
        #expect(stop.title == "Force Stop 2 Devices…" && stop.isEnabled && stop.targets == Array(rows[..<2]))
        #expect(start.title == "Start 2 Devices" && start.isEnabled && start.targets == Array(rows[2...]))
        let jailbreak = try batch(.jailbreak)
        #expect(jailbreak.title == "Jailbreak 1 Device…" && jailbreak.targets == [rows[2]])
        #expect(jailbreak.skipped == [rows[0], rows[1], rows[3]], "running, and iOS 4")
        #expect(try batch(.erase).title == "Erase 4 Devices…")
        // None running: Stop is there, dimmed.
        let none = try batch(.forceStop, Array(rows[2...]))
        #expect(none.title == "Force Stop Devices…" && !none.isEnabled && none.skipped.count == 2)
        // One-row commands have no several-row form (Delete is the sidebar's own Batch).
        #expect(DeviceBatch(.delete, rows) { _ in true } == nil && DeviceBatch(.stop, rows) { _ in true } == nil)
    }

    /// A first launch selects a build Apple still serves, ready to Download and Prepare: no device ships in the app.
    @Test func firstRunIsADownloadFromApple() throws {
        let first = try #require(catalog.firstRunEntry)
        #expect(
            first.status == .available && first.source.url?.host == "secure-appldnld.apple.com",
            "first run: \(first.id)"
        )
        let r = row(first)
        guard case .notDownloaded = r.state else {
            Issue.record("first run: \(r.state)")
            return
        }
        #expect(
            r.primaryTitle == "Download and Prepare"
                && allowed(r, canDownload: true) == ["importIPSW", "downloadAndPrepare"]
        )
    }

    /// iPod 3.1.3 ships prepared (the catalog's `bundled`): with no record it is "Built in" and Prepare unpacks it,
    /// which needs the preparer like any preparation. Without the packed base it downloads like any other entry.
    @Test func bundledEntryIsBuiltIn() {
        #expect(catalog.bundledEntry?.id == iPod.id && iPod.bundled == "Device/n72ap-7E18.itbase")
        var r = row(iPod)
        #expect(
            r.state == .bundled && r.primaryTitle == "Prepare" && r.stateDescription == "Built in" && !r.isStartable
        )
        #expect(allowed(r, canDownload: true) == ["importIPSW", "downloadAndPrepare"] && allowed(r) == ["importIPSW"])
        #expect(
            r.accessory == .none && row(iPod, job: .failed("x")).primaryAction == .downloadAndPrepare,
            "a failed unpack offers Prepare again"
        )
        var unpacked = iPod
        unpacked.bundled = nil
        r = row(unpacked)
        guard case .notDownloaded = r.state else {
            Issue.record("unpacked: \(r.state)")
            return
        }
        #expect(
            r.primaryTitle == "Download and Prepare"
                && allowed(r, canDownload: true) == ["importIPSW", "downloadAndPrepare"]
        )
        // A user_ipsw entry (no public download) asks for the user's IPSW.
        unpacked.status = .userIPSW
        r = row(unpacked)
        #expect(r.state == .unavailable(.requiresIPSW) && r.primaryTitle == "Import IPSW…" && !r.isStartable)
        #expect(allowed(r, canDownload: true) == ["importIPSW"])
        r = row(iPod, instance: id)
        #expect(r.state == .ready && r.isStartable && r.primaryTitle == "Start")
        #expect(allowed(r) == Self.recordCommands)
        #expect(r.title == "iOS 3.1.3" && !r.isExperimental && r.stateDescription == "Ready")
    }

    @Test func notDownloadedDownloadedAndReady() {
        // An IPSW entry without a device is not downloaded, with its size.
        var r = row(iPad)
        guard case .notDownloaded(let bytes) = r.state, bytes == 479_001_595 else {
            Issue.record("\(r.state)")
            return
        }
        #expect(r.primaryAction == .downloadAndPrepare && r.primaryTitle == "Download and Prepare")
        #expect(allowed(r) == ["importIPSW"], "download is off without canDownload")
        #expect(allowed(r, canDownload: true) == ["importIPSW", "downloadAndPrepare"])
        #expect(r.stateDescription.hasPrefix("Not downloaded, ") && r.stateDescription.contains("MB"))
        // Its IPSW already in a store: Downloaded, and the button prepares.
        r = DeviceRow(entry: iPad, instanceID: nil, session: nil, job: nil, downloaded: true)
        #expect(r.state == .downloaded && r.primaryTitle == "Prepare" && r.stateDescription == "Downloaded")
        #expect(allowed(r, canDownload: true) == ["importIPSW", "downloadAndPrepare"])
        // Adopted or prepared: ready, with the record's commands.
        r = row(iPad, instance: id)
        #expect(r.state == .ready && allowed(r) == Self.recordCommands)
    }

    @Test func sessionsOutrankEverythingElse() {
        var r = row(iPad, instance: id, session: .running, job: .failed("x"))
        #expect(r.state == .running && r.primaryAction == nil && r.stateDescription == "Running")
        #expect(allowed(r) == ["stop", "forceStop", "erase", "showInFinder"], "no delete while running")
        r = row(iPad, instance: id, session: .stopping)
        #expect(
            r.state == .stopping && allowed(r) == ["forceStop", "showInFinder"],
            "a Shut Down the guest never finishes can be forced"
        )
        // Shut down or dead: its session lets go of the storage for Delete (state audit B-4), no quit needed.
        r = row(iPad, instance: id, session: .stopped)
        #expect(r.state == .ready && allowed(r) == Self.recordCommands, "powered off starts again, or is deleted")
        r = row(iPod, instance: id, session: .dead("The iPod stopped."))
        #expect(r.state == .error("The iPod stopped.") && r.stateDescription == "Error")
        #expect(r.allows(.delete, canDownload: false) && r.canRemoveFromSidebar, "a dead device can be deleted")
        #expect(r.allows(.start, canDownload: false), "a dead session's Start restarts it")
        // A start failure: Try Again starts again.
        r = row(iPod, instance: id, session: .dead("These device files are missing: /x"))
        #expect(r.state == .error("These device files are missing: /x") && r.primaryAction == .start)
        #expect(r.primaryTitle == "Try Again" && r.allows(.start, canDownload: false))
    }

    /// One bar for the job: the download is its first half.
    @Test func downloadProgress() {
        var r = row(iPad32, job: .downloading(fraction: 0.425))
        #expect(r.state == .downloading(fraction: 0.425) && r.stateDescription == "Downloading, 21%")
        #expect(r.primaryTitle == "Cancel" && allowed(r) == ["cancel"])
        #expect(r.progress == 0.2125 && r.progressHeadline == "Downloading…" && r.progressDetail.isEmpty)
        #expect(r.progressLine == "21%")
        r = row(iPad32, job: .downloading(fraction: 0.5, remaining: 125))
        #expect(r.progressHeadline == "Downloading…" && r.progressSummary == "25%")
        #expect(r.progressLine == "25% — About 2 minutes remaining")
        // A slow download (under 2 MB/s) shows its speed; a fast, short one doesn't; a long one does.
        #expect(
            row(iPad32, job: .downloading(fraction: 0.5, remaining: 125, speed: 1_200_000)).progressLine
                == "25% — About 2 minutes remaining — 1.2 MB/s"
        )
        #expect(
            row(iPad32, job: .downloading(fraction: 0.5, remaining: 125, speed: 9_000_000)).progressLine
                == "25% — About 2 minutes remaining"
        )
        #expect(
            row(iPad32, job: .downloading(fraction: 0.5, remaining: 1800, speed: 9_000_000)).progressLine
                == "25% — About 30 minutes remaining — 9 MB/s"
        )
        // A build that boots its sibling's ramdisk: one job, both IPSWs, one bar.
        r = row(iPad32, job: .downloading(fraction: 0.25, files: 2))
        #expect(
            r.progressSummary == "12%" && r.progressHeadline == "Downloading…" && r.progressDetail == ["2 IPSWs"]
                && r.progress == 0.125
        )
        #expect(r.stateDescription == "Downloading, 12%" && r.primaryTitle == "Cancel")
        // From a third-party host (archive.org, a mirror): the headline and the bar's tooltip name it.
        r = row(iPad32, job: .downloading(fraction: 0.25, mirror: "archive.org"))
        #expect(r.progressHeadline == "Downloading from archive.org…")
        #expect(r.progressDetail == ["From archive.org, a third-party mirror"])
        #expect(
            FirmwareJob.thirdParty("archive.org") == "archive.org"
                && FirmwareJob.thirdParty("secure-appldnld.apple.com") == nil
        )
    }

    /// The preparation after a download is the bar's second half: it starts at 50%, never back at 0.
    @Test func preparationProgress() {
        var r = row(iPad32, job: .preparing(.init(name: "Starting", startsAt: 0.5)))
        #expect(r.progress == 0.5 && r.progressSummary == "50%" && r.accessory == .progress(0.5))
        r = row(iPad32, job: .preparing(.init(step: 2, steps: 4, name: "Decrypting", fraction: 0.5, startsAt: 0.5)))
        #expect(r.progress == 0.6875 && r.progressHeadline == "Decrypting…")
        r = row(iPad32, job: .preparing(.init(step: 2, steps: 5, name: "Decrypting")))
        #expect(r.stateDescription == "Preparing, 20%" && allowed(r, canDownload: true) == ["cancel"])
        // Overall progress: equal steps without the preparer's seconds, weighted by them with.
        var p = Preparation(step: 6, steps: 7, name: "Finishing setup", fraction: 0.5)
        #expect(abs(row(iPad32, job: .preparing(p)).progress! - 5.5 / 7) < 1e-9)
        p.seconds = [2, 5, 1, 12, 4, 71, 3]
        #expect(abs(p.overall! - (24 + 35.5) / 98) < 1e-9)
        p.detail = "Starting iOS — 42 s"
        p.remaining = 45
        r = row(iPad32, job: .preparing(p))
        #expect(r.progressSummary == "60%")
        // The placeholder's headline is the time left, no percent; the preparer's step and its words are the bar's tooltip.
        #expect(r.progressHeadline == "Finishing setup…" && r.progressLine == "60% — About 50 seconds remaining")
        #expect(r.progressDetail == ["Step 6 of 7: Finishing setup", "Starting iOS — 42 s"])
        var done = p
        done.step = 7
        done.fraction = 1
        #expect(done.overall == 1)
        #expect(row(iPad32, job: .preparing(done)).accessory == .progress(1))
        r = row(iPad32, job: .preparing(.init(name: "Checking the IPSW")))
        #expect(
            r.progress == nil && r.progressHeadline == "Preparing…" && r.progressDetail == ["Checking the IPSW"]
                && r.stateDescription == "Preparing…"
        )
        #expect(r.accessory == .progress(nil), "no fraction yet: the ring spins")
        #expect(row(iPad32, instance: id).progressHeadline == nil, "no headline outside a job")
        r = row(iPad32, job: .failed("The download is damaged. Try again."))
        #expect(r.state == .error("The download is damaged. Try again.") && r.primaryTitle == "Try Again")
        #expect(r.primaryAction == .downloadAndPrepare, "retrying a failed download downloads again")
    }

    /// Time remaining: nothing for the first 5 s or 2 %, then the rate so far.
    @Test func timeRemaining() {
        #expect(
            estimatedRemaining(elapsed: 4, from: 0, to: 0.5) == nil
                && estimatedRemaining(elapsed: 60, from: 0.3, to: 0.31) == nil
        )
        #expect(
            estimatedRemaining(elapsed: 30, from: 0, to: 0.25) == 90
                && estimatedRemaining(elapsed: 10, from: 0.5, to: 0.75) == 10
        )
        #expect(
            DeviceRow.remainingText(5) == "Almost done…" && DeviceRow.remainingText(41) == "About 50 seconds remaining"
                && DeviceRow.remainingText(65) == "About 1 minute remaining"
                && DeviceRow.remainingText(3000) == "About 50 minutes remaining"
                && DeviceRow.remainingText(7200) == "About 2 hours remaining"
        )
    }

    /// Unavailable entries are dimmed and offer nothing but their reason.
    @Test func unavailableEntries() {
        var r = row(soon)
        #expect(r.state == .unavailable(.comingSoon) && r.isDimmed && r.primaryAction == nil)
        #expect(allowed(r, canDownload: true).isEmpty && r.stateDescription == "Coming soon")
        #expect(row(soon, job: .downloading(fraction: 0.5)).state == .unavailable(.comingSoon))
        r = row(userBeta)
        #expect(r.state == .unavailable(.requiresIPSW) && r.primaryTitle == "Import IPSW…")
        #expect(allowed(r, canDownload: true) == ["importIPSW"] && r.stateDescription == "Requires an IPSW")
        #expect(row(userBeta, instance: id).state == .ready, "an imported beta runs like any device")
        #expect(
            row(userBeta, job: .failed("x")).primaryAction == .importIPSW,
            "a failed import offers the import again"
        )
    }

    /// Experimental carries the tag (a status note is the catalog's to add); a developer build's badge is its ordinal.
    @Test func experimentalAndPrereleaseBadges() {
        #expect(row(entry("k48ap-8L1")).isExperimental)  // 4.2.1 is available since 09-29; 4.3.5 is still experimental
        #expect(!row(iPad4).isExperimental)
        // iPod 4.2.1 downloads and prepares like the iPads.
        let r = row(iPod4)
        #expect(r.isExperimental && r.primaryAction == .downloadAndPrepare)
        #expect(
            r.badge == nil && r.supportNote == "Experimental" && row(iPad).badge == nil && row(iPad).supportNote == nil,
            "Experimental is the tooltip's and VoiceOver's, not a capsule in the row"
        )
        #expect(
            row(entry("k48ap-8C5115c")).badge == "beta 3" && row(entry("k48ap-8C134b")).badge == "GM 2"
                && row(beta1).badge == "beta 1"
        )
        var unnumbered = beta1
        unnumbered.prereleaseNumber = nil
        #expect(
            row(unnumbered).badge == "beta 1" && entry("k48ap-8C134").prereleaseBadge == "GM 1",
            "a first beta/GM without a number is 1"
        )
        #expect(row(entry("n72ap-8B117")).badge == nil, "a release has no badge")
        #expect(row(iPad).note == nil && row(iPod4).note == nil, "tested builds carry no note")
    }

    /// Untested builds download and prepare like any other, with an Untested note; coming soon stays shut.
    @Test func untestedBuildsAreOffered() throws {
        let e = entry("n45ap-3B48b")  // the only entry still untested after the 10-02 sweep
        #expect(e.status == .untested && e.source.url?.scheme == "https")
        let r = row(e)
        guard case .notDownloaded = r.state else {
            Issue.record("\(r.state)")
            return
        }
        #expect(!r.isDimmed && r.primaryAction == .downloadAndPrepare && r.primaryTitle == "Download and Prepare")
        #expect(allowed(r, canDownload: true) == ["importIPSW", "downloadAndPrepare"])
        #expect(r.note == nil && r.supportNote == "Untested" && r.stateDescription.hasPrefix("Not downloaded"))
        #expect(row(e, job: .downloading(fraction: 0.5)).state == .downloading(fraction: 0.5))
        #expect(row(e, instance: id).state == .ready && row(e, instance: id).isStartable)
    }

    /// The sidebar shows only what differs from the usual (DeviceRow.accessory, what the cell draws).
    @Test func accessories() {
        #expect(
            DeviceRow(entry: iPad, instanceID: nil, session: nil, job: nil, downloaded: true).accessory == .none,
            "Downloaded is the normal state"
        )
        #expect(row(iPad, instance: id).accessory == .none, "ready: nothing")
        #expect(
            row(iPad).accessory == .notDownloaded && row(beta1).accessory == .notDownloaded,
            "not here yet: the download glyph"
        )
        #expect(row(iPad32, job: .downloading(fraction: 0.425)).accessory == .progress(0.2125))
        #expect(
            row(iPad, instance: id, session: .running).accessory == .running
                && row(iPad, instance: id, session: .stopping).accessory == .stopping
        )
        #expect(
            row(iPod, instance: id, session: .dead("x")).accessory == .error
                && row(soon).accessory == .text("Coming soon")
        )
        #expect(row(userBeta).accessory == .text("Requires an IPSW"))
        let running = row(beta1, instance: id, session: .running)
        #expect(running.accessory == .running && running.note == nil, "a running untested build: the dot alone")
        #expect(
            DeviceRow(entry: iPad, instanceID: id, session: nil, job: nil, preparedWithoutActivation: true).note
                == "Prepared without activation"
        )
    }

    /// The prepare screen: the catalog note is one popover's text, and disk numbers appear only when the volume can't
    /// hold the download and the preparation.
    @Test func catalogNoteAndSpaceShortage() {
        #expect(
            row(beta1).catalogNote?.hasPrefix("Experimental. ") == true
                && row(entry("n45ap-3B48b")).catalogNote?.hasPrefix("Untested") == true
                && row(iPad).catalogNote == nil
        )
        #expect(row(iPod4).catalogNote?.hasPrefix("Experimental.") == true)
        let needed = 479_001_595 + iPad.estimates.peakBytes
        #expect(needed > 479_001_595 && row(iPad).spaceShortage(available: needed) == nil)
        #expect(row(iPad).spaceShortage(available: needed - 1)?.hasPrefix("Not enough disk space: this needs ") == true)
        #expect(row(iPad, instance: id).spaceShortage(available: 0) == nil, "a prepared device needs no space")
        #expect(
            row(iPad32, job: .downloading(fraction: 0.5)).spaceShortage(available: 0) == nil,
            "nor does one already downloading"
        )
    }

    /// The sidebar lists in catalog order: version order, a version's betas right before its release.
    @Test func catalogOrderPutsBetasBeforeTheirRelease() {
        let ids = catalog.entries.map(\.id)
        #expect(
            ids.firstIndex(of: "k48ap-8L1")! < ids.firstIndex(of: "k48ap-9A5220p")!
                && ids.firstIndex(of: "k48ap-9A5288d")! < ids.firstIndex(of: "k48ap-9A334")!
                && ids.firstIndex(of: "n72ap-8A400")! < ids.firstIndex(of: "n72ap-8B5080c")!
        )
    }
}
