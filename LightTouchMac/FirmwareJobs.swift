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

    init(catalog: FirmwareCatalog = .bundled, store: IPSWStore = .shared) {
        self.catalog = catalog
        self.store = store
        // Staging a previous launch left behind is never a device.
        let preparing = PreparationJob.preparing(Bundled.stateDirectory)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: preparing.path)) ?? [] {
            IPSWStore.removeTree(preparing.appendingPathComponent(name))
        }
        let bytes = Dictionary(catalog.entries.compactMap { e in e.source.sha1.map { ($0, e.source.bytes ?? 0) } },
                               uniquingKeysWith: { a, _ in a })
        // Made at launch so a download the last launch started reports here.
        downloads = FirmwareDownloads(store: store, expectedBytes: { bytes[$0] }) { [weak self] sha1, event in
            Task { @MainActor in self?.download(sha1, event) }
        }
        downloads.active { sha1s in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for sha1 in sha1s {
                    if let entry = entry(sha1: sha1), jobs[entry.id] == nil { starts[entry.id] = nil; jobs[entry.id] = .downloading(fraction: 0) }
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
        canDownload ? nil : "This build of Light Touch can’t prepare devices: its firmware preparer is missing."
    }

    // MARK: - Commands

    func downloadAndPrepare(_ entry: FirmwareCatalog.Entry) {
        guard jobs[entry.id].map({ if case .failed = $0 { true } else { false } }) ?? true,
              let sha1 = entry.source.sha1 else { return }
        if let ipsw = store.existing(sha1) { return prepare(entry, ipsw: ipsw) }
        guard let url = entry.source.url else { return fail(entry, FirmwareError.unsupported) }
        do {
            try IPSWStore.checkSpace(entry.source.bytes ?? 0, at: store.downloads)
            starts[entry.id] = nil
            jobs[entry.id] = .downloading(fraction: 0)
            try downloads.start(sha1: sha1, url: url)
        } catch { fail(entry, error) }
    }

    /// Hashes, matches in the catalog and clones into State/IPSW, then
    /// prepares. `entry` is the row it was dropped on or imported for, if any.
    func importIPSW(_ url: URL, for entry: FirmwareCatalog.Entry?) {
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

    func cancel(_ entry: FirmwareCatalog.Entry) {
        if let job = preparations[entry.id] { job.cancel() }
        else if case .downloading? = jobs[entry.id], let sha1 = entry.source.sha1 { downloads.cancel(sha1: sha1) }
        jobs[entry.id] = nil
    }

    // MARK: - Steps

    private func download(_ sha1: String, _ event: FirmwareDownloads.Event) {
        guard let entry = entry(sha1: sha1) else { return }
        switch event {
        case let .progress(fraction):
            if case .downloading? = jobs[entry.id] { jobs[entry.id] = .downloading(fraction: fraction, remaining: remaining(entry, fraction)) }
        case .resumed: break
        case let .finished(ipsw):
            logEvent("firmware: downloaded \(entry.id)")
            prepare(entry, ipsw: ipsw)
        case let .failed(error): fail(entry, error)
        case .cancelled: logEvent("firmware: download of \(entry.id) cancelled; resume data kept")
        }
    }

    private func prepare(_ entry: FirmwareCatalog.Entry, ipsw: URL) {
        guard preparations[entry.id] == nil else { return }
        guard let preparer = Self.preparer else { return fail(entry, FirmwareError.failed(unavailableReason ?? "")) }
        do { try IPSWStore.checkSpace(entry.estimates.peakBytes, at: Bundled.stateDirectory) }
        catch { return fail(entry, error) }
        let request = PreparationJob.Request(
            entry: entry, ipsw: ipsw, state: Bundled.stateDirectory, preparer: preparer, helper: Self.helper,
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
