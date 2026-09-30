// Downloads and preparations per catalog entry, for the sidebar rows and the
// placeholder (DeviceSession.swift's DeviceRow reads `jobs`).
//
// Download & Prepare: an IPSW either store already has, else a CDN download;
// then `firmwarekit create` (PreparationJob), then a device in the library.
// Import: hash, match, clone into State/IPSW, then the same preparation.

import Cocoa

@MainActor final class FirmwareJobs {
    static let shared = FirmwareJobs()
    /// Posted on the main actor after `jobs` changes.
    static let didChangeNotification = Notification.Name("FirmwareJobsDidChange")
    /// Posted on the main actor when a preparation becomes a device; `object` is its catalog entry id.
    static let didPublishNotification = Notification.Name("FirmwareJobsDidPublish")

    var jobs: [String: FirmwareJob] = [:] {
        didSet { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
    }

    private let catalog: FirmwareCatalog
    private let store: IPSWStore
    private var downloads: FirmwareDownloads!
    private var preparations: [String: PreparationJob] = [:]
    /// When each job's current phase started and how far along it was, for time remaining.
    private var starts: [String: (date: Date, fraction: Double)] = [:]
    /// The IPSWs (sha1s) each downloading job waits for: the entry's own and, for a recipe with
    /// keybag_ramdisk_from, its sibling's. One job, one bar, weighted by size; prepared when all are here.
    private var waiting: [String: [String]] = [:]
    /// Downloads with a live task, and how far each is.
    private var inFlight: [String: Double] = [:]
    private let bytes: [String: Int64]

    /// `configuration`: tests use an ephemeral session and file URLs.
    init(catalog: FirmwareCatalog = .bundled, store: IPSWStore = .shared,
         configuration: URLSessionConfiguration = .background(withIdentifier: FirmwareDownloads.identifier)) {
        self.catalog = catalog
        self.store = store
        // Staging a previous launch left behind is never a device; nor is a
        // torn download or import. Only the app holding the library's lock
        // may sweep: another copy's jobs could be live.
        if (try? Bundled.requireStorage()) != nil {
            PreparationJob.sweep(state: Bundled.stateDirectory)
            store.sweep()
        }
        let bytes = Dictionary(catalog.entries.compactMap { e in e.source.sha1.map { ($0, e.source.bytes ?? 0) } },
                               uniquingKeysWith: { a, _ in a })
        self.bytes = bytes
        // Made at launch so a download the last launch started reports here.
        downloads = FirmwareDownloads(store: store, configuration: configuration, expectedBytes: { bytes[$0] }) { [weak self] sha1, event in
            Task { @MainActor in self?.download(sha1, event) }
        }
        // ponytail: a resumed download reports under its own entry, so a sibling IPSW the last
        // launch was fetching for 4.3.x prepares its own entry; persist `waiting` if that matters.
        downloads.active { sha1s in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for sha1 in sha1s {
                    inFlight[sha1] = inFlight[sha1] ?? 0
                    if let entry = entry(sha1: sha1), jobs[entry.id] == nil {
                        starts[entry.id] = nil
                        waiting[entry.id] = [sha1]
                        jobs[entry.id] = .downloading(fraction: 0)
                    }
                }
            }
        }
    }

    private func entry(sha1: String) -> FirmwareCatalog.Entry? { catalog.entries.first { $0.source.sha1 == sha1 } }

    // MARK: - Preparer

    /// Contents/MacOS/firmwarekit; a Debug build may name another with LTM_FIRMWAREKIT.
    static var preparer: URL? {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["LTM_FIRMWAREKIT"] {
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        #endif
        return Bundle.main.executableURL.map { $0.deletingLastPathComponent().appendingPathComponent("firmwarekit") }
            .flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    /// Contents/MacOS/LightTouchDevice, for the preparer's one-shot boots.
    static var helper: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/LightTouchDevice")
    }

    /// True once a download and preparation can run: the preparer is present.
    var canDownload: Bool { Self.preparer != nil }

    /// Why Download & Prepare is off, for the placeholder.
    var unavailableReason: String? {
        canDownload ? nil : "This copy of Light Touch can’t prepare devices because a component is missing. Reinstall Light Touch."
    }

    // MARK: - Commands

    func downloadAndPrepare(_ entry: FirmwareCatalog.Entry) {
        guard jobs[entry.id].map({ if case .failed = $0 { true } else { false } }) ?? true else { return }
        guard let sha1 = entry.source.sha1, !refuseExisting(entry) else { return }
        // The entry's IPSW and its keybag sibling's (4.3.1–4.3.5 boot 4.3's ramdisk), whichever aren't here yet.
        let sources = ([entry] + [entry.recipe?.keybagRamdiskFrom.flatMap(catalog.entry(id:))].compactMap { $0 })
            .filter { $0.source.sha1.flatMap(store.existing) == nil }
        if sources.isEmpty, let ipsw = store.existing(sha1) { return prepare(entry, ipsw: ipsw) }
        fetch(entry, sources)
    }

    /// Downloads `sources`' IPSWs as one job for `entry`, which is prepared once they're all here.
    /// A download another job already started is shared, not started twice.
    private func fetch(_ entry: FirmwareCatalog.Entry, _ sources: [FirmwareCatalog.Entry]) {
        let wanted = sources.compactMap { source in source.source.sha1.flatMap { sha1 in source.source.url.map { (sha1, $0) } } }
        guard wanted.count == sources.count, !wanted.isEmpty else { return fail(entry, FirmwareError.unsupported) }
        do {
            // The IPSWs, then the preparation, beside every job already under way.
            let size = sources.reduce(0) { $0 + ($1.source.bytes ?? 0) }
            try IPSWStore.checkSpace(size + entry.estimates.peakBytes + inFlightPeakBytes, at: store.downloads)
            starts[entry.id] = nil
            waiting[entry.id] = wanted.map(\.0)
            jobs[entry.id] = .downloading(fraction: downloadFraction(entry.id), files: wanted.count)
            for (sha1, url) in wanted where inFlight[sha1] == nil {
                inFlight[sha1] = 0
                try downloads.start(sha1: sha1, url: url)
            }
        } catch {
            waiting[entry.id] = nil
            fail(entry, error)
        }
    }

    /// How far a job's downloads are together, by their catalog sizes.
    private func downloadFraction(_ id: String) -> Double {
        let sha1s = waiting[id] ?? []
        let weight = { (sha1: String) in Double(max(self.bytes[sha1] ?? 1, 1)) }
        let total = sha1s.reduce(0) { $0 + weight($1) }
        let done = sha1s.reduce(0) { $0 + weight($1) * (self.inFlight[$1] ?? (self.store.existing($1) != nil ? 1 : 0)) }
        return total > 0 ? done / total : 0
    }

    /// Hashes, matches in the catalog and clones into State/IPSW, then
    /// prepares. `entry` is the row it was dropped on or imported for, if any.
    func importIPSW(_ url: URL, for entry: FirmwareCatalog.Entry?) {
        if let entry, refuseExisting(entry) { return }
        if let entry { jobs[entry.id] = .preparing(.init(name: "Checking the IPSW")) }
        let catalog = catalog, store = store
        Task.detached {
            let result = Result { try store.importIPSW(url, catalog: catalog) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case let .success((matched, ipsw)):
                    if let entry {
                        guard jobs[entry.id] != nil else { return }   // cancelled while hashing
                        jobs[entry.id] = nil
                    }
                    jobs[matched.id] = nil
                    prepare(matched, ipsw: ipsw)
                case let .failure(error):
                    if let entry { fail(entry, error) } else { NSApp.presentError(error) }
                }
            }
        }
    }

    /// App quit: every preparer gets SIGTERM (its own cancel path detaches
    /// its images); the next launch's sweep removes what's left.
    func cancelAll() {
        for job in preparations.values { job.cancel() }
    }

    /// Peak disk use of the downloads and preparations under way.
    private var inFlightPeakBytes: Int64 {
        jobs.compactMap { id, job -> Int64? in
            switch job {
            case .downloading, .preparing: catalog.entry(id: id)?.estimates.peakBytes
            case .failed: nil
            }
        }.reduce(0, +)
    }

    /// One device per entry: an IPSW for an entry that has one (a drop, an
    /// import, a download) is refused rather than prepared again.
    private func refuseExisting(_ entry: FirmwareCatalog.Entry) -> Bool {
        guard !DeviceLibrary.shared.instances(firmware: entry.id).isEmpty else { return false }
        logEvent("firmware: \(entry.id) already has a device; not preparing another")
        NSApp.presentError(FirmwareError.failed("\(entry.profile?.displayName ?? entry.productType) iOS \(entry.version) already has a device."))
        return true
    }

    func cancel(_ entry: FirmwareCatalog.Entry) {
        if let job = preparations[entry.id] { job.cancel() }
        else if let sha1s = waiting.removeValue(forKey: entry.id) {
            // A download another job still waits for goes on.
            for sha1 in sha1s where inFlight[sha1] != nil && !waiting.values.contains(where: { $0.contains(sha1) }) {
                inFlight[sha1] = nil
                downloads.cancel(sha1: sha1)
            }
        }
        jobs[entry.id] = nil
    }

    // MARK: - Steps

    /// One IPSW's event, for every job waiting on it.
    private func download(_ sha1: String, _ event: FirmwareDownloads.Event) {
        let name = entry(sha1: sha1)?.id ?? sha1
        let ids = waiting.filter { $0.value.contains(sha1) }.map(\.key).sorted()
        switch event {
        case let .progress(fraction):
            guard inFlight[sha1] != nil else { return }
            inFlight[sha1] = fraction
            for id in ids {
                guard let entry = catalog.entry(id: id), case .downloading? = jobs[id], let sha1s = waiting[id] else { continue }
                let overall = downloadFraction(id)
                jobs[id] = .downloading(fraction: overall, remaining: remaining(entry, overall), files: sha1s.count)
            }
        case .resumed: break
        case .finished:
            inFlight[sha1] = nil
            logEvent("firmware: downloaded \(name)")
            // A job with nothing left to fetch prepares; one still fetching the other IPSW waits.
            for id in ids {
                guard let entry = catalog.entry(id: id), let sha1s = waiting[id], sha1s.allSatisfy({ inFlight[$0] == nil }) else { continue }
                waiting[id] = nil
                guard let own = entry.source.sha1, let ipsw = store.existing(own) else { fail(entry, FirmwareError.failed("The download of iOS \(entry.version) is missing.")); continue }
                prepare(entry, ipsw: ipsw)
            }
            // Nobody waits (the other IPSW of a job that failed): it stays downloaded.
            if ids.isEmpty { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
        case let .failed(error):
            inFlight[sha1] = nil
            for id in ids {
                waiting[id] = nil
                if let entry = catalog.entry(id: id) { fail(entry, error) }
            }
        case .cancelled: logEvent("firmware: download of \(name) cancelled and discarded")
        }
    }

    private func prepare(_ entry: FirmwareCatalog.Entry, ipsw: URL) {
        guard preparations[entry.id] == nil else { return }
        if refuseExisting(entry) { jobs[entry.id] = nil; return }
        guard let preparer = Self.preparer else { return fail(entry, FirmwareError.failed(unavailableReason ?? "")) }
        let others = jobs.filter { $0.key != entry.id }.compactMap { id, job -> Int64? in
            if case .preparing = job { return catalog.entry(id: id)?.estimates.peakBytes } else { return nil }
        }.reduce(0, +)
        do { try IPSWStore.checkSpace(entry.estimates.peakBytes + others, at: Bundled.stateDirectory) }
        catch { return fail(entry, error) }
        var sibling: (entry: FirmwareCatalog.Entry, ipsw: URL)?
        if let from = entry.recipe?.keybagRamdiskFrom {
            guard let sib = catalog.entry(id: from), let sha1 = sib.source.sha1 else { return fail(entry, FirmwareError.failed("catalog names no \(from)")) }
            // An imported IPSW whose sibling isn't here yet: that download first, as this entry's job.
            guard let sibIPSW = store.existing(sha1) else { return fetch(entry, [sib]) }
            sibling = (sib, sibIPSW)
        }
        let request = PreparationJob.Request(
            entry: entry, ipsw: ipsw, sibling: sibling, state: Bundled.stateDirectory, preparer: preparer, helper: Self.helper,
            cache: IPSWStore.cachesDirectory.appendingPathComponent("Decrypted", isDirectory: true),
            log: Bundled.logsDirectory.appendingPathComponent("Preparing/\(entry.id).log"))
        let job = PreparationJob(request) { event in
            Task { @MainActor [weak self] in self?.preparation(entry, event) }
        }
        preparations[entry.id] = job
        starts[entry.id] = (Date(), 0)
        jobs[entry.id] = .preparing(.init(name: "Starting"))
        logEvent("firmware: preparing \(entry.id) as \(job.id.uuidString)")
        job.start()
    }

    /// Seconds left from this phase's start (the first report of a resumed download) to `fraction` now.
    private func remaining(_ entry: FirmwareCatalog.Entry, _ fraction: Double) -> TimeInterval? {
        guard let start = starts[entry.id] else { starts[entry.id] = (Date(), fraction); return nil }
        return estimatedRemaining(elapsed: Date().timeIntervalSince(start.date), from: start.fraction, to: fraction)
    }

    private func preparation(_ entry: FirmwareCatalog.Entry, _ event: PreparationJob.Event) {
        func update(_ change: (inout Preparation) -> Void) {
            guard preparations[entry.id] != nil, case var .preparing(p)? = jobs[entry.id] else { return }
            change(&p)
            p.remaining = p.overall.flatMap { remaining(entry, $0) }
            jobs[entry.id] = .preparing(p)
        }
        switch event {
        case let .begin(seconds): update { $0.seconds = seconds }
        case let .step(index, count, name):
            update { $0.step = index; $0.steps = count; $0.name = name; $0.fraction = 0; $0.detail = nil }
        case let .progress(fraction, detail):
            update { $0.fraction = fraction; $0.detail = detail ?? $0.detail }
        case let .warning(message): logEvent("firmware: \(entry.id): \(message)")
        case let .published(instance):
            preparations[entry.id] = nil
            jobs[entry.id] = nil
            logEvent("firmware: \(entry.id) is device \(instance.id.uuidString)")
            DeviceLibrary.shared.reload()
            NotificationCenter.default.post(name: Self.didPublishNotification, object: entry.id)
        case let .failed(message):
            preparations[entry.id] = nil
            fail(entry, FirmwareError.failed(message))
        case .cancelled:
            preparations[entry.id] = nil
            logEvent("firmware: preparation of \(entry.id) cancelled")
        }
    }

    private func fail(_ entry: FirmwareCatalog.Entry, _ error: any Error) {
        logEvent("firmware: \(entry.id): \(error.localizedDescription)")
        jobs[entry.id] = .failed(error.localizedDescription)
    }
}
