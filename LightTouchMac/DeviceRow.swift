// What the sidebar row, its context menu, the Device menu and the placeholder show for one catalog entry,
// from the record and what the sessions say about it. Pure Foundation, so tests/offline/check-device-rows.py
// compiles it whole.

import Foundation

// MARK: - Row state

/// A command the sidebar, its context menu, the Device menu and the
/// placeholder offer for one catalog entry.
nonisolated enum DeviceAction: CaseIterable, Sendable {
    case start, stop, downloadAndPrepare, importIPSW, cancel, erase, showInFinder, delete
}

/// A download or preparation in flight for a catalog entry (FirmwareJobs).
/// `remaining` is the estimated seconds left, nil until there is one.
nonisolated enum FirmwareJob: Equatable, Sendable {
    case downloading(fraction: Double, remaining: TimeInterval? = nil)
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
    enum Unavailable: Equatable, Sendable { case comingSoon, untested, requiresIPSW }
    case notDownloaded(bytes: Int64?)
    /// Its IPSW is in a store (downloaded or imported), not yet prepared.
    case downloaded
    /// The app ships its prepared base (`entry.bundled`), not yet unpacked.
    case bundled
    case downloading(fraction: Double, remaining: TimeInterval? = nil)
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

    /// `downloaded`: IPSWStore has this entry's IPSW.
    init(entry: FirmwareCatalog.Entry, instanceID: UUID?, session: SessionPhase?,
         job: FirmwareJob?, failure: String?, downloaded: Bool = false, preparedWithoutActivation: Bool = false) {
        self.entry = entry
        self.instanceID = instanceID
        self.preparedWithoutActivation = preparedWithoutActivation
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
        if entry.status == .untested { return .unavailable(.untested) }
        switch job {
        case let .downloading(fraction, remaining)?: return .downloading(fraction: fraction, remaining: remaining)
        case let .preparing(preparation)?: return .preparing(preparation)
        case let .failed(reason)?: return .error(reason)
        case nil: break
        }
        if let failure { return .error(failure) }
        if startable { return .ready }
        if entry.bundled != nil { return .bundled }
        if downloaded { return .downloaded }
        return entry.status == .userIPSW ? .unavailable(.requiresIPSW) : .notDownloaded(bytes: entry.source.bytes)
    }

    var title: String { "iOS \(entry.version)" }
    var isExperimental: Bool { entry.status == .experimental }
    var isStartable: Bool { instanceID != nil }
    var isDimmed: Bool { if case .unavailable = state { true } else { false } }
    var isError: Bool { if case .error = state { true } else { false } }
    /// A download's or preparation's overall progress; nil while it has no steps yet.
    var progress: Double? {
        switch state {
        case let .downloading(fraction, _): fraction
        case let .preparing(preparation): preparation.overall
        default: nil
        }
    }

    /// The sidebar's words beside the ring: "43%", "Step 6 of 7 · 48%".
    var progressSummary: String? {
        let percent = progress.map { "\(Int(($0 * 100).rounded(.down)))%" }
        switch state {
        case .downloading: return percent
        case let .preparing(p): return p.steps > 0 ? "Step \(p.step) of \(p.steps)" + (percent.map { " · \($0)" } ?? "") : p.name
        default: return nil
        }
    }

    /// The placeholder's lines under the bar: the step, what it is doing, and percent with time left.
    var progressLines: [String] {
        let percent = progress.map { "\(Int(($0 * 100).rounded(.down)))%" }
        switch state {
        case let .downloading(_, remaining):
            return [[percent, remaining.map(Self.remainingText)].compactMap { $0 }.joined(separator: " · ")]
        case let .preparing(p) where p.steps > 0:
            return ["Step \(p.step) of \(p.steps): \(p.name)", p.detail,
                    [percent, p.remaining.map(Self.remainingText)].compactMap { $0 }.joined(separator: " · ")].compactMap { $0 }
        case let .preparing(p): return [p.name]
        default: return []
        }
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
    func allows(_ action: DeviceAction, canDownload: Bool) -> Bool {
        let working = switch state { case .downloading, .preparing, .stopping: true; default: false }
        switch action {
        // A dead session's Start is a restart (DeviceSessionHost.restart).
        case .start: return isStartable && (state == .ready || isError)
        case .stop: return state == .running
        // The built-in device needs no preparer to unpack.
        case .downloadAndPrepare:
            return (canDownload || state == .bundled) && !isStartable && !working && !isDimmed
        case .importIPSW:
            return !isStartable && entry.status != .comingSoon && entry.status != .untested && !working
        case .cancel: return !hasSession && working
        case .erase: return instanceID != nil && !working
        case .showInFinder: return instanceID != nil
        case .delete: return instanceID != nil && !hasSession && !working
        }
    }

    /// The placeholder's one button.
    var primaryAction: DeviceAction? {
        switch state {
        case .ready: .start
        case .notDownloaded, .downloaded, .bundled: .downloadAndPrepare
        case .downloading, .preparing: .cancel
        case .error: isStartable ? .start : entry.status == .userIPSW ? .importIPSW : .downloadAndPrepare
        case .unavailable(.requiresIPSW): .importIPSW
        case .unavailable(.comingSoon), .unavailable(.untested), .running, .stopping: nil
        }
    }

    var primaryTitle: String? {
        if isError { return "Try Again" }
        return switch primaryAction {
        case .start: "Start"
        case .downloadAndPrepare: state == .downloaded || state == .bundled ? "Prepare" : "Download & Prepare"
        case .importIPSW: "Import IPSW…"
        case .cancel: "Cancel"
        default: nil
        }
    }

    /// The row's note under the state, when there is one.
    var note: String? { preparedWithoutActivation && instanceID != nil ? "Prepared without activation" : nil }

    /// The accessory's words: what VoiceOver reads after the version.
    var stateDescription: String {
        switch state {
        case let .notDownloaded(bytes):
            bytes.map { "Not downloaded, " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Not downloaded"
        case .downloaded: "Downloaded"
        case .bundled: "Built in"
        case .downloading: "Downloading, " + (progressSummary ?? "")
        case .preparing: "Preparing, " + (progressSummary ?? "")
        case .ready: "Ready"
        case .running: "Running"
        case .stopping: "Stopping"
        case .error: "Error"
        case .unavailable(.comingSoon): "Coming soon"
        case .unavailable(.untested): "Untested"
        case .unavailable(.requiresIPSW): "Requires an IPSW"
        }
    }
}
