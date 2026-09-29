// Downloads and preparations per catalog entry, for the sidebar rows and the
// placeholder (DeviceSession.swift's DeviceRow reads `jobs`).
//
// Download & Prepare: an IPSW either store already has, else a CDN download;
// then `firmwarekit create` (PreparationJob), then a device in the library.
// Import: hash, match, clone into State/IPSW, then the same preparation.
// The built-in device (the catalog entry with `bundled`): its packed base
// unpacked into Preparing/<id>/ and published the same way.

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
    /// Entries whose built-in base is being unpacked (not cancellable: seconds, no child process).
    private var unpacking: Set<String> = []
    /// When each job's current phase started and how far along it was, for time remaining.
    private var starts: [String: (date: Date, fraction: Double)] = [:]

    init(catalog: FirmwareCatalog = .bundled, store: IPSWStore = .shared) {
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
        guard jobs[entry.id].map({ if case .failed = $0 { true } else { false } }) ?? true else { return }
        if entry.bundled != nil { return prepareBundled(entry) }
        guard let sha1 = entry.source.sha1, !refuseExisting(entry) else { return }
        if let ipsw = store.existing(sha1) { return prepare(entry, ipsw: ipsw) }
        guard let url = entry.source.url else { return fail(entry, FirmwareError.unsupported) }
        do {
            // The IPSW, then its preparation, beside every job already under way.
            try IPSWStore.checkSpace((entry.source.bytes ?? 0) + entry.estimates.peakBytes + inFlightPeakBytes, at: store.downloads)
            starts[entry.id] = nil
            jobs[entry.id] = .downloading(fraction: 0)
            try downloads.start(sha1: sha1, url: url)
        } catch { fail(entry, error) }
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
        guard !unpacking.contains(entry.id) else { return }
        if let job = preparations[entry.id] { job.cancel() }
        else if case .downloading? = jobs[entry.id], let sha1 = entry.source.sha1 { downloads.cancel(sha1: sha1) }
        jobs[entry.id] = nil
    }

    /// The entry's packed base in this bundle (a development build has none).
    static func bundledBlob(_ entry: FirmwareCatalog.Entry) -> URL? {
        guard let resource = entry.bundled, let blob = Bundle.main.resourceURL?.appendingPathComponent(resource),
              FileManager.default.fileExists(atPath: blob.path) else { return nil }
        return blob
    }

    /// The built-in device: its packed base (Resources/<entry.bundled>,
    /// scripts/pack-base.py) unpacked into Preparing/<id>/ off the main actor
    /// and published as any preparation is. A host pairing the legacy erase
    /// kept (State/work/usbmuxd-conf, LegacyState) seeds the device and goes.
    func prepareBundled(_ entry: FirmwareCatalog.Entry) {
        guard entry.bundled != nil, !unpacking.contains(entry.id), !refuseExisting(entry) else { return }
        guard let blob = Self.bundledBlob(entry) else {
            return fail(entry, FirmwareError.failed("This build of Light Touch has no built-in \(entry.profile?.shortName ?? "device")."))
        }
        let state = Bundled.stateDirectory
        do { try IPSWStore.checkSpace(entry.estimates.preparedBytes + inFlightPeakBytes, at: state) }
        catch { return fail(entry, error) }
        let id = UUID()
        let staging = PreparationJob.preparing(state).appendingPathComponent(id.uuidString, isDirectory: true)
        let pairing = state.appendingPathComponent("work/usbmuxd-conf", isDirectory: true)
        unpacking.insert(entry.id)
        starts[entry.id] = (Date(), 0)
        jobs[entry.id] = .preparing(.init(step: 1, steps: 1, name: "Unpacking the built-in \(entry.profile?.shortName ?? "device")"))
        logEvent("firmware: unpacking the built-in \(entry.id) as \(id.uuidString)")
        Task.detached { [weak self] in
            let result = Result {
                try StorageLocations.privateDirectory(staging)
                StorageLocations.excludeFromBackup(PreparationJob.preparing(state))
                try BundledBase.unpack(blob, into: staging) { fraction in
                    Task { @MainActor in self?.preparation(entry, .progress(fraction, detail: nil)) }
                }
                let instance = try PreparationJob.publish(staging: staging, entry: entry, id: id, state: state, pairing: pairing)
                try? DeviceStateStorage.removeTree(pairing)
                return instance
            }
            if case .failure = result { try? DeviceStateStorage.removeTree(staging) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                unpacking.remove(entry.id)
                switch result {
                case let .success(instance): preparation(entry, .published(instance))
                case let .failure(error): preparation(entry, .failed("Couldn’t unpack the built-in device: \(error.localizedDescription)"))
                }
            }
        }
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
        case .cancelled: logEvent("firmware: download of \(entry.id) cancelled and discarded")
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
            // ponytail: the sibling IPSW must already be in the store; queueing its download first is the upgrade
            guard let sib = catalog.entry(id: from), let sha1 = sib.source.sha1 else { return fail(entry, FirmwareError.failed("catalog names no \(from)")) }
            guard let sibIPSW = store.existing(sha1) else {
                return fail(entry, FirmwareError.failed("needs the \(sib.profile?.displayName ?? sib.productType) iOS \(sib.version) firmware downloaded first (its restore ramdisk creates this build's keybag)"))
            }
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
            guard preparations[entry.id] != nil || unpacking.contains(entry.id), case var .preparing(p)? = jobs[entry.id] else { return }
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
