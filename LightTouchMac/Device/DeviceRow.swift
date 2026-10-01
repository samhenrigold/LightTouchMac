// What the sidebar row, its context menu, the Device menu and the placeholder show for one catalog entry,
// from the record and what the sessions say about it. Pure Foundation, so tests/offline/check-device-rows.py
// compiles it whole.

import Foundation

// MARK: - Row state

/// A command the sidebar, its context menu, the Device menu and the
/// placeholder offer for one catalog entry.
nonisolated enum DeviceAction: CaseIterable, Sendable {
    case start, stop, downloadAndPrepare, importIPSW, cancel, erase, showInFinder, delete, prepareAgain
}

/// A download or preparation in flight for a catalog entry (FirmwareJobs).
/// `remaining` is the estimated seconds left, nil until there is one; `files` is how many
/// IPSWs the one job fetches (2 for a build that boots its sibling's ramdisk), `fraction` all of them.
nonisolated enum FirmwareJob: Equatable, Sendable {
    case downloading(fraction: Double, remaining: TimeInterval? = nil, files: Int = 1)
    case preparing(Preparation)
    case failed(String)
}

/// Where a preparation stands (the preparer contract's begin, step and progress events).
nonisolated struct Preparation: Equatable, Sendable {
    /// 1-based; 0 of 0 is a job with no steps yet (hashing an import).
    var step = 0, steps = 0
    var name: String
    /// Within the step, 0...1.
    var fraction = 0.0
    /// The preparer's expected seconds per step; equal steps without them.
    var seconds: [Double] = []
    /// The preparer's words for what the step is doing now.
    var detail: String?
    var remaining: TimeInterval?

    /// Finished steps plus this one's fraction, weighted by expected seconds; nil with no steps yet.
    var overall: Double? {
        guard steps > 0 else { return nil }
        let weights = seconds.count == steps && seconds.allSatisfy({ $0 > 0 }) ? seconds : Array(repeating: 1, count: steps)
        let done = weights.prefix(min(max(step - 1, 0), steps)).reduce(0, +)
        let current = (1...steps).contains(step) ? weights[step - 1] * min(max(fraction, 0), 1) : 0
        return min(1, (done + current) / weights.reduce(0, +))
    }
}

/// Seconds left for a job that went from `start` to `now` (0...1) in `elapsed` seconds; nil until
/// it has run 5 s and moved 2 %, so the first guesses don't swing.
nonisolated func estimatedRemaining(elapsed: TimeInterval, from start: Double, to now: Double) -> TimeInterval? {
    guard elapsed >= 5, now - start >= 0.02 else { return nil }
    return elapsed * (1 - now) / (now - start)
}

/// A started device, as the sidebar sees it.
nonisolated enum SessionPhase: Equatable, Sendable {
    case running, stopping, stopped
    case dead(String)
}

nonisolated enum DeviceRowState: Equatable, Sendable {
    enum Unavailable: Equatable, Sendable { case comingSoon, requiresIPSW }
    case notDownloaded(bytes: Int64?)
    /// Its IPSW is in a store (downloaded or imported), not yet prepared.
    case downloaded
    case downloading(fraction: Double, remaining: TimeInterval? = nil, files: Int = 1)
    case preparing(Preparation)
    case ready, running, stopping
    case error(String)
    case unavailable(Unavailable)
}

/// One sidebar row: a catalog entry and what the library, the jobs and the
/// sessions say about it. Pure, so tests/offline/check-device-rows.py can run it.
nonisolated struct DeviceRow: Equatable, Sendable {
    let entry: FirmwareCatalog.Entry
    let instanceID: UUID?
    let hasSession: Bool
    let state: DeviceRowState
    /// The device's lock records no activation (DeviceInstance.lockLacksActivation).
    let preparedWithoutActivation: Bool
    /// The device's base was made by a recipe older than its catalog entry's (`baseRecipe` below the entry's
    /// recipe.version): Erase keeps the old base, so only preparing it again brings the fix.
    let preparedByOlderRecipe: Bool

    /// `downloaded`: IPSWStore has this entry's IPSW. `baseRecipe`: DeviceRow.baseRecipeVersion of the device's lock.
    init(entry: FirmwareCatalog.Entry, instanceID: UUID?, session: SessionPhase?,
         job: FirmwareJob?, failure: String?, downloaded: Bool = false, preparedWithoutActivation: Bool = false,
         baseRecipe: Int? = nil) {
        self.entry = entry
        self.instanceID = instanceID
        self.preparedWithoutActivation = preparedWithoutActivation
        preparedByOlderRecipe = instanceID != nil && baseRecipe.map { $0 < entry.recipe?.version ?? 0 } ?? false
        hasSession = session != nil
        state = Self.state(entry: entry, startable: instanceID != nil,
                           session: session, job: job, failure: failure, downloaded: downloaded)
    }

    /// A session outranks everything; then the catalog's own verdict, a job
    /// in flight, the last start failure, and finally whether a device exists.
    private static func state(entry: FirmwareCatalog.Entry, startable: Bool, session: SessionPhase?,
                              job: FirmwareJob?, failure: String?, downloaded: Bool) -> DeviceRowState {
        switch session {
        case .running?: return .running
        case .stopping?: return .stopping
        case let .dead(reason)?: return .error(reason)
        case .stopped?: return .ready
        case nil: break
        }
        if entry.status == .comingSoon { return .unavailable(.comingSoon) }
        switch job {
        case let .downloading(fraction, remaining, files)?: return .downloading(fraction: fraction, remaining: remaining, files: files)
        case let .preparing(preparation)?: return .preparing(preparation)
        case let .failed(reason)?: return .error(reason)
        case nil: break
        }
        if let failure { return .error(failure) }
        if startable { return .ready }
        if downloaded { return .downloaded }
        return entry.status == .userIPSW ? .unavailable(.requiresIPSW) : .notDownloaded(bytes: entry.source.bytes)
    }

    var title: String { "iOS \(entry.version)" }
    var isExperimental: Bool { entry.status == .experimental }
    /// The tag beside the title, in secondary text: a developer build's "Beta 3"/"GM 1". How well a build is
    /// tested isn't the row's to shout: that is `supportNote`, in the tooltip, VoiceOver and the placeholder's popover.
    var badge: String? { entry.prereleaseBadge }
    var supportNote: String? { entry.status == .untested ? "Untested" : isExperimental ? "Experimental" : nil }
    var isStartable: Bool { instanceID != nil }
    var isDimmed: Bool { if case .unavailable = state { true } else { false } }
    var isError: Bool { if case .error = state { true } else { false } }
    /// A download's or preparation's overall progress; nil while it has no steps yet.
    var progress: Double? {
        switch state {
        case let .downloading(fraction, _, _): fraction
        case let .preparing(preparation): preparation.overall
        default: nil
        }
    }

    /// The sidebar's words beside the ring: "43%"; nil while there is no fraction yet (the ring spins).
    var progressSummary: String? { progress.map { "\(Int(($0 * 100).rounded(.down)))%" } }

    /// What the sidebar shows after the title. Only what differs from the usual: a downloaded or
    /// ready build shows nothing; one that isn't here yet shows a download glyph (its size is in VoiceOver).
    enum Accessory: Equatable, Sendable {
        case none, notDownloaded, running, stopping, error
        case progress(Double?, String?)
        case text(String)
    }
    var accessory: Accessory {
        switch state {
        case .notDownloaded: .notDownloaded
        case .downloaded, .ready: .none
        case .downloading, .preparing: .progress(progress, progressSummary)
        case .running: .running
        case .stopping: .stopping
        case .error: .error
        case .unavailable(.comingSoon): .text("Coming soon")
        case .unavailable(.requiresIPSW): .text("Requires an IPSW")
        }
    }

    /// The placeholder's one line under the bar: percent and time left ("34% · About 1 min remaining").
    var progressLine: String? {
        let remaining: TimeInterval? = switch state {
        case let .downloading(_, remaining, _): remaining
        case let .preparing(p): p.remaining
        default: nil
        }
        let parts = [progress.map { "\(Int(($0 * 100).rounded(.down)))%" }, remaining.map(Self.remainingText)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What the job is doing inside, for the bar's tooltip only: the preparer's step and its words, or the IPSW count.
    var progressDetail: [String] {
        switch state {
        case let .downloading(_, _, files): files > 1 ? ["\(files) IPSWs"] : []
        case let .preparing(p) where p.steps > 0: ["Step \(p.step) of \(p.steps): \(p.name)", p.detail].compactMap { $0 }
        case let .preparing(p): [p.name]
        default: []
        }
    }

    /// "Untested." or "Experimental." and the catalog's note (source); the placeholder shows its ⓘ when there is one.
    var catalogNote: String? {
        let tag = entry.status == .untested ? "Untested." : isExperimental ? "Experimental." : nil
        let text = [tag, entry.statusNote].compactMap { $0 }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// What `supportNote` means, the line under it in the ⓘ popover.
    var supportExplanation: String? {
        switch entry.status {
        case .untested: "Light Touch hasn’t run this build yet. It may not prepare or start."
        case .experimental: "This build prepares and starts, but it hasn’t been through every check. Some features may not work."
        default: nil
        }
    }

    /// "Released June 7, 2011", from the catalog's `released` date.
    var releaseLine: String? {
        guard let released = entry.released, let date = try? Date(released + "T12:00:00Z", strategy: .iso8601) else { return nil }
        return "Released " + date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: TimeZone(identifier: "UTC")!))
    }

    /// Before a download or preparation, when `available` bytes can't hold it: the copy's words; nil when there is room.
    func spaceShortage(available: Int64) -> String? {
        let download: Int64 = if case let .notDownloaded(bytes) = state { bytes ?? 0 } else { 0 }
        let needed = download + entry.estimates.peakBytes
        guard state == .downloaded || download > 0, needed > available else { return nil }
        let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return "Not enough disk space: this needs \(format(needed)), and \(format(available)) is available."
    }

    static func remainingText(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<10: "Almost done"
        case ..<60: "About \(Int((seconds / 10).rounded(.up)) * 10) s remaining"
        case ..<5400: "About \(Int((seconds / 60).rounded())) min remaining"
        default: "About \(Int((seconds / 3600).rounded())) h remaining"
        }
    }

    /// `canDownload` is FirmwareJobs.canDownload: whether the preparer is present.
    private var working: Bool { switch state { case .downloading, .preparing, .stopping: true; default: false } }

    /// Whether the sidebar may drop this row now: a prepared device when it may be deleted (which asks first),
    /// any other when nothing is running or in flight for it.
    var canRemoveFromSidebar: Bool { instanceID != nil ? allows(.delete, canDownload: false) : !hasSession && !working }

    /// A prepared device's data goes with it, after asking; a row with nothing on disk just leaves the list.
    var removeTitle: String { instanceID != nil ? "Delete Device…" : "Remove Device" }

    func allows(_ action: DeviceAction, canDownload: Bool) -> Bool {
        switch action {
        // A dead session's Start is a restart (DeviceSessionHost.restart).
        case .start: return isStartable && (state == .ready || isError)
        case .stop: return state == .running
        case .downloadAndPrepare:
            return canDownload && !isStartable && !working && !isDimmed
        case .importIPSW:
            return !isStartable && entry.status != .comingSoon && !working
        case .cancel: return !hasSession && working
        case .erase: return instanceID != nil && !working
        case .showInFinder: return instanceID != nil
        case .delete: return instanceID != nil && !hasSession && !working
        case .prepareAgain: return preparedByOlderRecipe && canDownload && allows(.delete, canDownload: canDownload)
        }
    }

    /// The placeholder's one button.
    var primaryAction: DeviceAction? {
        switch state {
        case .ready: .start
        case .notDownloaded, .downloaded: .downloadAndPrepare
        case .downloading, .preparing: .cancel
        case .error: isStartable ? .start : entry.status == .userIPSW ? .importIPSW : .downloadAndPrepare
        case .unavailable(.requiresIPSW): .importIPSW
        case .unavailable(.comingSoon), .running, .stopping: nil
        }
    }

    var primaryTitle: String? {
        if isError { return "Try Again" }
        return switch primaryAction {
        case .start: "Start"
        case .downloadAndPrepare: state == .downloaded ? "Prepare" : "Download and Prepare"
        case .importIPSW: "Import IPSW…"
        case .cancel: "Cancel"
        default: nil
        }
    }

    /// The row's note beside a quiet accessory: a device prepared without activation says so.
    var note: String? { preparedWithoutActivation && instanceID != nil ? "Prepared without activation" : nil }

    /// The placeholder's line for a base made by an older recipe, beside Prepare Again.
    var olderRecipeNote: String? {
        preparedByOlderRecipe ? "This \(entry.profile?.shortName ?? "device") was prepared by an older version of Light Touch." : nil
    }

    /// The recipe version that made a base: firmwarekit's lock keeps the catalog entry it was prepared from
    /// (`entry.content.recipe.version`, every lock since the first firmwarekit). Nil for an unreadable lock or one
    /// without it (a device.py base): nothing to claim.
    static func baseRecipeVersion(_ lock: URL) -> Int? {
        guard let data = try? Data(contentsOf: lock),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = json["entry"] as? [String: Any], let content = entry["content"] as? [String: Any],
              let recipe = content["recipe"] as? [String: Any] else { return nil }
        return recipe["version"] as? Int
    }

    /// The accessory's words: what VoiceOver reads after the version.
    var stateDescription: String {
        switch state {
        case let .notDownloaded(bytes):
            bytes.map { "Not downloaded, " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Not downloaded"
        case .downloaded: "Downloaded"
        case .downloading: "Downloading" + (progressSummary.map { ", " + $0 } ?? "…")
        case .preparing: "Preparing" + (progressSummary.map { ", " + $0 } ?? "…")
        case .ready: "Ready"
        case .running: "Running"
        case .stopping: "Stopping"
        case .error: "Error"
        case .unavailable(.comingSoon): "Coming soon"
        case .unavailable(.requiresIPSW): "Requires an IPSW"
        }
    }
}
