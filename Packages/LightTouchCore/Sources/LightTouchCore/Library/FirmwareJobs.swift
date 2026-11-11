// Downloads and preparations per catalog entry, for the sidebar rows and the
// placeholder (DeviceSession.swift's DeviceRow reads `jobs`). Each entry's job is
// one state in a FirmwareJobTable; this class runs what the table asks for and
// feeds every download, import and preparer event back to it, in order, through
// one stream.
//
// Download and Prepare: an IPSW either store already has, else a CDN download;
// then `firmwarekit create` (PreparationJob), then a device in the library.
// Import: hash, match, clone into State/IPSW (or refer to a file on another
// volume), then the same preparation.
// The built-in device (the catalog's `bundled`): its packed base unpacked by
// `firmwarekit unpack-base` with an identity of its own, published the same way.

import FirmwareSchema
import Foundation
import HostRuntime

/// The app's instance is FirmwareJobs.shared (FirmwareJobs+App.swift); tests make their own over temporary roots.
@MainActor public final class FirmwareJobs {
    /// Posted on the main actor after `jobs` changes.
    public static let didChangeNotification = Notification.Name("FirmwareJobsDidChange")
    /// Posted on the main actor when a preparation becomes a device; `object` is its catalog entry id.
    public static let didPublishNotification = Notification.Name("FirmwareJobsDidPublish")
    /// Each preparation's step under way, for its failure's report.
    private var steps: [String: String] = [:]

    /// What each entry's row shows.
    public var jobs: [String: FirmwareJob] { table.shown }
    /// Preparers at work, for Quit's question.
    public var preparing: Int { table.preparing }
    /// The IPSWs a job under way reads or waits for, by sha1: each such entry's own and its keybag sibling's (4.3.x
    /// boots 4.3's ramdisk). Remove IPSW leaves them alone.
    public var ipswsInUse: Set<String> {
        let busy = table.jobs.keys.filter { !table.isIdle($0) }.compactMap(catalog.entry(id:))
        let sources = busy + busy.compactMap { $0.recipe?.keybagRamdiskFrom.flatMap(catalog.entry(id:)) }
        return Set(sources.compactMap(\.source.sha1))
    }

    private var table: FirmwareJobTable {
        didSet {
            guard table != oldValue else { return }
            if table.intents != oldValue.intents { saveIntents() }
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// What reaches the table from elsewhere, in the order it happened.
    nonisolated enum Input: Sendable {
        case download(String, FirmwareDownloads.Event)
        /// The session's download tasks at launch, by sha1.
        case tasks([String])
        case preparation(String, UUID, PreparationJob.Event)
        case imported(UUID, String?, Result<(entry: FirmwareCatalog.Entry, ipsw: URL), any Error>)
    }
    private nonisolated let inputs: AsyncStream<Input>.Continuation

    private let catalog: FirmwareCatalog
    private let store: IPSWStore
    /// Made in init, once self can be captured by its event handler.
    private var downloads: FirmwareDownloads?
    /// The preparers and import checks running, by the id their events carry.
    private var preparations: [UUID: PreparationJob] = [:]
    private var imports: [UUID: Task<Void, Never>] = [:]
    /// The downloading jobs (FirmwareJobTable.intents), for the next launch.
    private let intentsFile: URL
    /// Each IPSW's first URL by sha1.
    private let urls: [String: URL]
    /// The state root (Preparing/ and Devices/), the log root, and ~/Library/Caches/<bundle> (the preparer's Decrypted/).
    private let state: URL, logs: URL, caches: URL
    /// firmwarekit, if this build has it (FirmwareJobs.preparer).
    public let preparer: URL?
    /// The bundle's Resources (the built-in device's packed base).
    private let resources: URL?
    private let library: DeviceLibrary
    /// Errors with no row to show them on (an IPSW dropped on the window, a second device for an entry).
    private let presentError: (any Error) -> Void
    private let defaults: UserDefaults

    /// The entries to prepare past Setup Assistant (the preparation screen's checkbox; off unless chosen).
    public var skipsSetup: Set<String> {
        get { Set(defaults.stringArray(forKey: "skipSetupEntries") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "skipSetupEntries") }
    }
    /// The entries to prepare without the jailbreak (the preparation screen's checkbox; on unless turned off).
    public var keepsStock: Set<String> {
        get { Set(defaults.stringArray(forKey: "stockEntries") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "stockEntries") }
    }
    /// Settings ▸ General ▸ Prepare devices without mounting disk images (experimental; off unless turned on): each
    /// preparation started with it on edits the volumes in their images (firmwarekit --hfs writer), mounting nothing.
    public nonisolated static let withoutMountingKey = "ExperimentalPrepareWithoutMounting"
    /// The jailbreak can be chosen where FirmwareKit's SandboxPatch lets Substrate's library into Safari's sandbox:
    /// iOS 5 on, and iOS 4 on the ARMv7 boards. Elsewhere (iOS 3, the ARMv6 iPod touch 2G's iOS 4) the patch doesn't
    /// resolve yet and Safari crashes at launch on a jailbroken device, so the checkbox is off and disabled.
    public nonisolated static func jailbreakWorks(_ entry: FirmwareCatalog.Entry) -> Bool {
        let major = Int(entry.version.split(separator: ".").first ?? "") ?? 0
        return major >= 5 || (major == 4 && Board(rawValue: entry.board)?.arch == "armv7")
    }
    /// The preparation screen's Jailbreak checkbox for an entry.
    public func jailbreaks(_ id: String) -> Bool {
        guard let entry = catalog.entry(id: id) else { return false }
        return Self.offersJailbreak(entry) && Self.jailbreakWorks(entry) && !keepsStock.contains(id)
    }
    public func setJailbreaks(_ id: String, _ on: Bool) {
        if on { keepsStock.remove(id) } else { keepsStock.insert(id) }
    }
    /// afc2 and Cydia from iPhone OS 2.0 on (FirmwareKit refuses the option on 1.x).
    public nonisolated static func offersJailbreak(_ entry: FirmwareCatalog.Entry) -> Bool {
        (Int(entry.version.split(separator: ".").first ?? "") ?? 0) >= 2
    }
    /// Setup Assistant runs on a fresh device from iOS 5 on; before that iTunes activated it.
    public static func offersSkipSetup(_ entry: FirmwareCatalog.Entry) -> Bool {
        BootRecipe.setupPhonesHome(iosVersion: entry.version)
    }

    /// `configuration`: tests use an ephemeral session and file URLs. `sweep`: this process holds the library's
    /// lock (Bundled.requireStorage), so staging and torn downloads a previous launch left can go.
    public init(
        catalog: FirmwareCatalog = .bundled,
        store: IPSWStore = .shared,
        configuration: URLSessionConfiguration = .background(withIdentifier: FirmwareDownloads.identifier),
        state: URL = Bundled.stateDirectory,
        logs: URL = Bundled.logsDirectory,
        caches: URL = IPSWStore.cachesDirectory,
        preparer: URL? = FirmwareJobs.preparer,
        resources: URL? = Bundle.main.resourceURL,
        library: DeviceLibrary = .shared,
        sweep: Bool = (try? Bundled.requireStorage()) != nil,
        defaults: UserDefaults = .standard,
        presentError: @escaping (any Error) -> Void
    ) {
        self.defaults = defaults
        self.catalog = catalog
        self.store = store
        self.state = state
        self.logs = logs
        self.caches = caches
        self.preparer = preparer
        self.resources = resources
        self.library = library
        self.presentError = presentError
        // Staging a previous launch left behind is never a device; nor is a
        // torn download or import. Only the app holding the library's lock
        // may sweep: another copy's jobs could be live.
        if sweep {
            PreparationJob.sweep(state: state, preparer: preparer)
            store.sweep()
        }
        // Keyed by the IPSW's sha1 (a task's name); what is downloaded and weighed is the archive for a "rar" source.
        let bytes = Dictionary(
            catalog.entries.compactMap { e in e.source.sha1.map { ($0, e.source.downloadBytes ?? 0) } },
            uniquingKeysWith: { a, _ in a }
        )
        let entries = Dictionary(
            catalog.entries.compactMap { e in e.source.sha1.map { ($0, e) } },
            uniquingKeysWith: { a, _ in a }
        )
        let urls = Dictionary(
            catalog.entries.compactMap { e in e.source.sha1.map { ($0, e.source.urls) } },
            uniquingKeysWith: { a, _ in a }
        )
        self.urls = Dictionary(
            catalog.entries.compactMap { e in e.source.sha1.flatMap { sha1 in e.source.url.map { (sha1, $0) } } },
            uniquingKeysWith: { a, _ in a }
        )
        table = FirmwareJobTable(
            bytes: bytes,
            hosts: urls.compactMapValues { $0.first?.host },
            seconds: Dictionary(catalog.entries.map { ($0.id, $0.estimates.seconds) }, uniquingKeysWith: { a, _ in a })
        )
        // The downloads the last launch's jobs were waiting for; their tasks are checked once the session answers.
        intentsFile = state.appendingPathComponent("FirmwareJobs.json")
        let intents =
            ((try? Data(contentsOf: intentsFile)).flatMap {
                try? JSONDecoder().decode([String: [String]].self, from: $0)
            } ?? [:]).filter { catalog.entry(id: $0.key) != nil }
        table.restore(intents, stored: Set(intents.values.joined().filter { store.existing($0) != nil }))
        let (stream, inputs) = AsyncStream.makeStream(of: Input.self)
        self.inputs = inputs
        // Made at launch so a download the last launch started reports here.
        // The source or mirror the file came from decides how it is checked: a "rar" one is unwrapped.
        let install: @Sendable (String, URL, URL?) throws -> URL = { sha1, file, from in
            guard var entry = entries[sha1] else { return try store.install(file, sha1: sha1, bytes: bytes[sha1]) }
            entry.source = entry.source.alternative(for: from)
            guard entry.source.isArchive else { return try store.install(file, sha1: sha1, bytes: entry.source.bytes) }
            return try store.installArchive(file, entry: entry, preparer: preparer)
        }
        let downloads = FirmwareDownloads(
            store: store,
            configuration: configuration,
            expectedBytes: { bytes[$0] },
            sources: { urls[$0] ?? [] },
            install: install,
            onEvent: { sha1, event in inputs.yield(.download(sha1, event)) }
        )
        self.downloads = downloads
        Task { [weak self] in
            for await input in stream { self?.receive(input) }
        }
        downloads.active { inputs.yield(.tasks($0)) }
    }

    deinit { inputs.finish() }

    private func entry(sha1: String) -> FirmwareCatalog.Entry? { catalog.entries.first { $0.source.sha1 == sha1 } }

    // MARK: - Preparer

    /// Contents/MacOS/firmwarekit; a Debug build may name another with LTM_FIRMWAREKIT.
    public nonisolated static var preparer: URL? {
        #if DEBUG
            if let path = ProcessInfo.processInfo.environment["LTM_FIRMWAREKIT"] {
                return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
            }
        #endif
        return Bundle.main.executableURL.map { $0.deletingLastPathComponent().appendingPathComponent("firmwarekit") }
            .flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    /// Contents/MacOS/LightTouchDevice, for the preparer's one-shot boots.
    public static var helper: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/LightTouchDevice")
    }

    /// True once a download and preparation can run: the preparer is present.
    public var canDownload: Bool { preparer != nil }

    /// Why Download and Prepare is off, for the placeholder.
    public var unavailableReason: String? {
        canDownload
            ? nil
            : "This copy of Light Touch can’t prepare devices because a component is missing. Reinstall Light Touch."
    }

    // MARK: - Commands

    public func downloadAndPrepare(_ entry: FirmwareCatalog.Entry) {
        guard table.request(entry.id) else { return }
        if let blob = Self.bundledBlob(entry, resources: resources) { return prepare(entry, ipsw: blob, bundled: true) }
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
        let wanted = sources.compactMap { source in
            source.source.sha1.flatMap { sha1 in source.source.url.map { (sha1, $0) } }
        }
        guard wanted.count == sources.count, !wanted.isEmpty else { return fail(entry, FirmwareError.unsupported) }
        do {
            // The IPSWs, then the preparation, beside every job already under way.
            let size = sources.reduce(0) {
                $0 + ($1.source.bytes ?? 0) + ($1.source.isArchive ? $1.source.archiveBytes ?? 0 : 0)
            }
            try IPSWStore.checkSpace(size + entry.estimates.peakBytes + inFlightPeakBytes, at: store.downloads)
        } catch {
            return fail(entry, error)
        }
        for sha1 in table.download(entry.id, wanted.map(\.0)) { startDownload(sha1) }
    }

    /// A download that can't start fails every job waiting for it.
    private func startDownload(_ sha1: String) {
        do {
            guard let url = urls[sha1], let downloads else { throw FirmwareError.unsupported }
            try downloads.start(sha1: sha1, url: url)
        } catch {
            receive(.download(sha1, .failed(error as? FirmwareError ?? .failed(error.localizedDescription))))
        }
    }

    /// Hashes, matches in the catalog and clones into State/IPSW, then
    /// prepares. `entry` is the row it was dropped on or imported for, if any.
    /// An IPSW dropped on a row whose entry has a job under way, or one that matches such an entry, leaves that job
    /// alone (the IPSW is stored all the same).
    public func importIPSW(_ url: URL, for entry: FirmwareCatalog.Entry?) {
        if let entry {
            guard table.isIdle(entry.id) else {
                return logEvent("firmware: \(entry.id) has a job under way; not importing \(url.lastPathComponent)")
            }
            if refuseExisting(entry) { return }
        }
        let token = UUID()
        if let entry { table.importing(entry.id, token) }
        let catalog = catalog
        let store = store
        let inputs = inputs
        imports[token] = Task.detached {
            inputs.yield(.imported(token, entry?.id, Result { try store.importIPSW(url, catalog: catalog) }))
        }
    }

    /// IPSWs and folders of them (Import IPSW… for no row, a drop, Finder's Open), matched by sha1 off the main
    /// thread. One file is imported and prepared as above. Several, or a folder, are only stored, one after another,
    /// so their rows say Downloaded and Download and Prepare uses them: one that matches no entry is skipped and
    /// logged, and if none matches, one error says so.
    public func importIPSWs(_ urls: [URL]) {
        let catalog = catalog
        let store = store
        let inputs = inputs
        Task.detached {
            if urls.count == 1, !DroppedFiles.isFolder(urls[0]) {
                inputs.yield(.imported(UUID(), nil, Result { try store.importIPSW(urls[0], catalog: catalog) }))
                return
            }
            let found = DroppedFiles.ipsws(in: urls)
            var matched = 0
            for url in found {
                do {
                    let result = try store.importIPSW(url, catalog: catalog)
                    matched += 1
                    logEvent("firmware: import: stored \(url.lastPathComponent) for \(result.entry.id)")
                } catch is CancellationError {
                    return
                } catch {
                    logEvent("firmware: import: skipped \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            logEvent("firmware: import: \(matched) of \(found.count) IPSWs matched")
            guard matched > 0 else {
                inputs.yield(.imported(UUID(), nil, .failure(FirmwareError.noneSupported)))
                return
            }
            // The rows (and Add Device, next opened) read the store again: the cue that the IPSWs are here.
            await MainActor.run { NotificationCenter.default.post(name: IPSWStore.didChangeNotification, object: nil) }
        }
    }

    /// App quit: every preparer gets SIGTERM (its own cancel path detaches
    /// its images); the next launch's sweep removes what's left.
    public func cancelAll() {
        for job in preparations.values { job.cancel() }
    }

    /// Peak disk use of the downloads and preparations under way.
    private var inFlightPeakBytes: Int64 {
        table.jobs.compactMap { id, job -> Int64? in
            if case .failed = job.phase { nil } else { catalog.entry(id: id)?.estimates.peakBytes }
        }.reduce(0, +)
    }

    /// One device per entry: an IPSW for an entry that has one (a drop, an
    /// import, a download) is refused rather than prepared again.
    private func refuseExisting(_ entry: FirmwareCatalog.Entry) -> Bool {
        guard !library.instances(firmware: entry.id).isEmpty else { return false }
        logEvent("firmware: \(entry.id) already has a device; not preparing another")
        presentError(FirmwareError.failed("\(entry.marketingName) iOS \(entry.version) already has a device."))
        return true
    }

    public func cancel(_ entry: FirmwareCatalog.Entry) { run(table.cancel(entry.id)) }

    /// The entry's row left the sidebar: a failure it showed is forgotten, so adding the row again starts clean.
    public func dismissFailure(_ entry: FirmwareCatalog.Entry) { table.dismiss(entry.id) }

    // MARK: - Steps

    func receive(_ input: Input) {
        let now = Date()
        switch input {
        case .download(let sha1, let event):
            let name = entry(sha1: sha1)?.id ?? sha1
            switch event {
            case .finished: logEvent("firmware: downloaded \(name)")
            case .failed(let error):
                logEvent("firmware: download of \(name) failed: \(error.localizedDescription)")
                AppReports.failed("Firmware.downloadFailed", error, ["firmware": name])
            case .cancelled: logEvent("firmware: download of \(name) cancelled and discarded")
            case .progress, .mirror, .resumed: break
            }
            run(table.download(sha1, event, now: now))
        case .tasks(let sha1s): run(table.resume(tasks: Set(sha1s)))
        case .preparation(let id, let job, let event):
            let effects = table.preparation(id, job, event, now: now)
            switch event {
            case .step(_, _, let name): steps[id] = name
            case .begin, .progress: break
            case .warning(let message): logEvent("firmware: \(id): \(message)")
            case .published(let instance):
                preparations[job] = nil
                steps[id] = nil
                logEvent("firmware: \(id) is device \(instance.id.uuidString)")
                AppReports.used("Firmware.prepared", ["firmware": id])
                library.reload()
                NotificationCenter.default.post(name: Self.didPublishNotification, object: id)
            case .failed(let message):
                preparations[job] = nil
                logEvent("firmware: \(id): \(message)")
                AppReports.failed(
                    "Firmware.preparationFailed",
                    nil,
                    ["firmware": id, "step": steps.removeValue(forKey: id) ?? "starting"]
                )
            case .cancelled:
                preparations[job] = nil
                steps[id] = nil
                logEvent("firmware: preparation of \(id) cancelled")
            }
            run(effects)
        case .imported(let token, let id, let result):
            imports[token] = nil
            switch result {
            case .success((let matched, let ipsw)):
                if table.imported(token, onto: id, matched: matched.id) {
                    prepare(matched, ipsw: ipsw)
                } else {
                    logEvent("firmware: imported \(matched.id)'s IPSW; not preparing (cancelled, or a job under way)")
                }
            case .failure(let error):
                guard !(error is CancellationError) else { return logEvent("firmware: import cancelled") }
                logEvent("firmware: import: \(error.localizedDescription)")
                AppReports.failed("Firmware.importFailed", error, ["firmware": id ?? ""])
                if let id {
                    _ = table.importFailed(token, onto: id, error.localizedDescription)
                } else {
                    presentError(error)
                }
            }
        }
    }

    private func run(_ effects: [FirmwareJobTable.Effect]) {
        for effect in effects {
            switch effect {
            case .startDownload(let sha1): startDownload(sha1)
            case .cancelDownload(let sha1): downloads?.cancel(sha1: sha1)
            case .cancelImport(let token): imports.removeValue(forKey: token)?.cancel()
            case .cancelPreparation(let job): preparations[job]?.cancel()
            case .prepare(let id):
                guard let entry = catalog.entry(id: id) else { continue }
                guard let own = entry.source.sha1, let ipsw = store.existing(own) else {
                    fail(entry, FirmwareError.failed("The download of iOS \(entry.version) is missing."))
                    continue
                }
                prepare(entry, ipsw: ipsw, afterDownload: true)
            case .retry(let id): catalog.entry(id: id).map(downloadAndPrepare)
            }
        }
    }

    /// The entry's packed base in this bundle (a development build has none).
    public static func bundledBlob(_ entry: FirmwareCatalog.Entry, resources: URL? = Bundle.main.resourceURL) -> URL? {
        guard let resource = entry.bundled, let blob = resources?.appendingPathComponent(resource),
            FileManager.default.fileExists(atPath: blob.path)
        else { return nil }
        return blob
    }

    /// A fresh install (`sidebarSaved` false: no launch has saved a sidebar yet; and no device in the library): the
    /// built-in device is unpacked and returned, for the launch to select. A Mac that already has a library gets
    /// nothing new; its Prepare is the user's (the row offers it once added with +, and after a Delete).
    public func prepareBundledIfFresh(sidebarSaved: Bool) -> FirmwareCatalog.Entry? {
        guard !sidebarSaved, DeviceInstance.all(state: state).isEmpty,
            let entry = catalog.bundledEntry, let blob = Self.bundledBlob(entry, resources: resources)
        else { return nil }
        prepare(entry, ipsw: blob, bundled: true)
        return entry
    }

    /// `bundled`: `ipsw` is the entry's packed base, unpacked rather than prepared. `afterDownload`: the job's
    /// download filled the first half of its bar.
    private func prepare(_ entry: FirmwareCatalog.Entry, ipsw: URL, bundled: Bool = false, afterDownload: Bool = false)
    {
        guard table.mayPrepare(entry.id) else { return }
        if refuseExisting(entry) { return table.clear(entry.id) }
        guard let preparer else { return fail(entry, FirmwareError.failed(unavailableReason ?? "")) }
        let others = table.jobs.filter { $0.key != entry.id }.compactMap { id, job -> Int64? in
            if case .preparing = job.phase { return catalog.entry(id: id)?.estimates.peakBytes } else { return nil }
        }.reduce(0, +)
        do { try IPSWStore.checkSpace(entry.estimates.peakBytes + others, at: state) } catch {
            return fail(entry, error)
        }
        var sibling: (entry: FirmwareCatalog.Entry, ipsw: URL)?
        if !bundled, let from = entry.recipe?.keybagRamdiskFrom {
            guard let sib = catalog.entry(id: from), let sha1 = sib.source.sha1 else {
                return fail(entry, FirmwareError.failed("catalog names no \(from)"))
            }
            // An imported IPSW whose sibling isn't here yet: that download first, as this entry's job.
            guard let sibIPSW = store.existing(sha1) else { return fetch(entry, [sib]) }
            sibling = (sib, sibIPSW)
        }
        let request = PreparationJob.Request(
            entry: entry,
            ipsw: ipsw,
            sibling: sibling,
            state: state,
            preparer: preparer,
            helper: Self.helper,
            cache: caches.appendingPathComponent("Decrypted", isDirectory: true),
            log: logs.appendingPathComponent("Preparing/\(entry.id).log"),
            blob: bundled ? ipsw : nil,
            skipSetup: !bundled && Self.offersSkipSetup(entry) && skipsSetup.contains(entry.id),
            jailbreak: !bundled && jailbreaks(entry.id),
            hfs: defaults.bool(forKey: Self.withoutMountingKey) ? .writer : nil
        )
        let id = UUID()
        let job = PreparationJob(request, id: id) { [inputs, entryID = entry.id] event in
            inputs.yield(.preparation(entryID, id, event))
        }
        preparations[id] = job
        table.preparing(entry.id, id, afterDownload: afterDownload, now: Date())
        logEvent("firmware: \(bundled ? "unpacking the built-in" : "preparing") \(entry.id) as \(job.id.uuidString)")
        job.start()
    }

    private func saveIntents() {
        let intents = table.intents
        do {
            if intents.isEmpty {
                if FileManager.default.fileExists(atPath: intentsFile.path) {
                    try FileManager.default.removeItem(at: intentsFile)
                }
            } else {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                try encoder.encode(intents).write(to: intentsFile, options: .atomic)
            }
        } catch {
            logEvent("firmware: couldn’t save the downloads under way: \(error.localizedDescription)")
        }
    }

    private func fail(_ entry: FirmwareCatalog.Entry, _ error: any Error) {
        logEvent("firmware: \(entry.id): \(error.localizedDescription)")
        table.fail(entry.id, error.localizedDescription)
    }
}
