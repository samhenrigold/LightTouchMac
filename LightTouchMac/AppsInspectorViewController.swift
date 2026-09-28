// Created by Sam on 2026-08-05.
//
// The right-hand inspector: a plain AppKit table of the apps installed on the
// device, in the order they sit on the home screen, with add (install an .ipa)
// and remove (uninstall) controls beneath it, source-list style. Rows can be
// dragged to reorder the home screen itself, and right-clicked for the same
// operations. While an install runs, the app appears as a pending row carrying
// the script's own progress, cancellable from its context menu.

import Cocoa
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted after an install/uninstall completes so any open list refreshes.
    static let ltmAppsChanged = Notification.Name("LTMAppsChanged")
    /// Posted when an install begins; object is the InstallJob.
    static let ltmInstallStarted = Notification.Name("LTMInstallStarted")
    /// Posted as an install reports progress; object is the InstallJob.
    static let ltmInstallProgress = Notification.Name("LTMInstallProgress")
    /// An app was launched on the guest from the sidebar (post-success).
    static let ltmAppLaunched = Notification.Name("LTMAppLaunched")
}

/// One install in flight. The sidebar shows it as a row; cancelling it tears
/// down the script, which takes its own home-screen placeholder with it (the
/// script traps TERM for exactly this).
@MainActor
final class InstallJob {
    /// Starts as the .ipa's filename and is replaced by the app's real display
    /// name as soon as the archive has been read.
    fileprivate(set) var name: String
    fileprivate(set) var status = "Installing…"
    /// Set when the install has stopped, however it stopped. Two .ipas can be
    /// in flight at once and each one's finish notification reaches the list —
    /// without this, the first to land clears the other's row too.
    fileprivate(set) var isFinished = false
    /// Learned from the .ipa while the install runs. The list keeps this row up
    /// until an app with this id actually shows up, so a finished install never
    /// leaves a gap where neither the placeholder nor the real row is present.
    fileprivate(set) var bundleID: String?
    fileprivate(set) var finishedAt: Date?
    /// Set when the install ENDED BADLY. A finished job renders as an ordinary
    /// app row, which for a failed one was a lie: the sidebar showed the app,
    /// with its real icon and name, for ~30 s (forever, if the failure was the
    /// device going away) while nothing had been installed at all.
    fileprivate(set) var failed = false
    fileprivate var task: Task<Void, Never>?
    fileprivate var retry: (() -> Void)?
    fileprivate var dismissed = false
    func dismiss() {
        dismissed = true
        NotificationCenter.default.post(name: .ltmAppsChanged, object: nil)
    }

    fileprivate init(name: String) { self.name = name }

    /// False once the install has passed the last point cancellation can reach.
    /// instproxy_install runs on a detached thread that ignores cancellation, so
    /// after it starts the install WILL finish — the row used to say
    /// "Cancelling…" for the rest of it and then the app appeared anyway.
    fileprivate(set) var isCancellable = true

    /// While a Legacy Store copy is still coming down: 0…1 (negative when the
    /// total size is unknown), nil once staged or for a local-file install.
    fileprivate(set) var downloadProgress: Double?
    /// The catalog copy this job installs, so search results recognize it.
    fileprivate(set) var catalogIpaID: Int?
    /// The catalog icon, so the pending row can show it before the .ipa lands.
    fileprivate(set) var catalogIconURL: URL?

    var isCancelled: Bool { task?.isCancelled ?? false }
    func cancel() { task?.cancel() }
}

/// Shared install flow used by the inspector's Add button and by drag-and-drop
/// onto the device. Announces start, progress and finish so the list can follow
/// along, and owns the task so the row can cancel it.
@MainActor
enum AppInstaller {

    /// Queued removals need the same quit/restart protection as installs.
    static var hasPendingWork: Bool { !jobs.isEmpty || !removals.isEmpty }
    private static var jobs: [InstallJob] = []
    private static var removals: [UUID: Task<Void, Never>] = [:]

    static func cancelPendingWork() {
        for job in jobs where job.isCancellable { job.cancel() }
        for task in removals.values { task.cancel() }
    }

    /// Every row this session put up, including failed ones still offering
    /// Retry (they have left `jobs`), so an erase can take them all down.
    private static let rows = NSHashTable<InstallJob>.weakObjects()

    /// The device is being erased or powered off: nothing queued or failed can
    /// land on it any more, and a Retry would target a wiped device. Cancel
    /// what can be cancelled and drop every install row. An install already
    /// inside installation_proxy can't be stopped; its row goes too and the
    /// erase makes the outcome moot.
    static func discardAll() {
        for job in rows.allObjects {
            job.task?.cancel()
            job.dismissed = true
        }
        for task in removals.values { task.cancel() }
        if readyQueue.isPaused { readyQueue.resume() }
        NotificationCenter.default.post(name: .ltmAppsChanged, object: nil)
    }

    private static let readyQueue = InstallationQueue()
    static var isUsingDevice: Bool { readyQueue.isBusy }
    static var isPaused: Bool { readyQueue.isPaused }

    static func resume() {
        readyQueue.resume()
        for job in jobs where job.status.hasPrefix("Paused") {
            job.status = "Waiting for device…"
            NotificationCenter.default.post(name: .ltmInstallProgress, object: job)
        }
    }

    @discardableResult
    static func start(_ ipa: URL, with emulator: EmulatorController,
                      presenting window: NSWindow?) -> InstallJob {
        // The row goes up on the filename immediately — reading the .ipa costs
        // a couple of unzips, and the point of the row is to appear the moment
        // the drop happens — then takes the app's real display name as soon as
        // the archive has been read.
        let job = InstallJob(name: ipa.deletingPathExtension().lastPathComponent)
        job.retry = { [weak job, weak emulator, weak window] in
            guard let emulator else { return }
            job?.dismiss()
            start(ipa, with: emulator, presenting: window)
        }
        jobs.append(job)
        rows.add(job)
        NotificationCenter.default.post(name: .ltmInstallStarted, object: job)
        job.task = Task {
            defer { finish(job) }
            job.bundleID = await AppMetadataCache.bundleID(of: ipa)
            // Read the archive's name/icon for the ROW, but do not commit them
            // to the cache yet. Committing here overwrote the entry for an app
            // that is still installed, so a cancelled or failed install left the
            // sidebar showing the name and icon of a build that never landed —
            // and the cache has no invalidation path, so it stayed that way.
            let preview = await AppMetadataCache.shared.preview(of: ipa)
            if let name = preview?.name {
                job.name = name
                NotificationCenter.default.post(name: .ltmInstallProgress, object: job)
            }
            await install(job, ipa: ipa, with: emulator, presenting: window)
        }
        return job
    }

    /// Media shares the ready queue and progress rows with app installation,
    /// so AFC uploads cannot race installs or device lifecycle operations.
    @discardableResult
    static func startMedia(_ source: URL, with emulator: EmulatorController,
                           presenting window: NSWindow?) -> InstallJob {
        let job = InstallJob(name: source.deletingPathExtension().lastPathComponent)
        job.retry = { [weak job, weak emulator, weak window] in
            guard let emulator else { return }
            job?.dismiss()
            startMedia(source, with: emulator, presenting: window)
        }
        job.status = "Preparing media…"
        jobs.append(job)
        rows.add(job)
        NotificationCenter.default.post(name: .ltmInstallStarted, object: job)
        job.task = Task {
            var acquired = false
            defer {
                if acquired { readyQueue.release() }
                finish(job)
            }
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            do {
                let media = try await PreparedMedia.prepare(source, profile: emulator.profile)
                defer { try? FileManager.default.removeItem(at: media.directory) }
                job.name = media.title
                job.status = readyQueue.isPaused ? "Paused" : "Waiting for other transfers…"
                NotificationCenter.default.post(name: .ltmInstallProgress, object: job)
                try await readyQueue.acquire()
                acquired = true
                try Task.checkCancellation()
                job.status = "Copying media…"
                job.downloadProgress = 0
                NotificationCenter.default.post(name: .ltmInstallProgress, object: job)
                try await emulator.importMedia(media) { fraction in
                    Task { @MainActor in
                        guard !job.isFinished, job.isCancellable else { return }
                        job.downloadProgress = fraction
                        job.status = "Copying media… \(Int(fraction * 100))%"
                        NotificationCenter.default.post(name: .ltmInstallProgress, object: job)
                    }
                } willCommit: {
                    job.isCancellable = false
                    job.downloadProgress = nil
                    job.status = "Adding to \(media.destination)…"
                    NotificationCenter.default.post(name: .ltmInstallProgress, object: job)
                }
                job.status = "Added to \(media.destination)"
            } catch is CancellationError {
                // The uploader removes incomplete files. A completed staged
                // file is retained if the library outcome could be uncertain.
            } catch {
                guard !Task.isCancelled else { return }
                job.failed = true
                pauseIfNeeded(error, with: emulator, excluding: job)
                job.status = error.localizedDescription
            }
        }
        return job
    }

    /// A Legacy Store copy: same pipeline, same queue, but the row exists —
    /// including in the installed list — from the first downloaded byte, so
    /// clearing the search can never lose sight of a transfer in flight.
    /// Downloads run independently. Completed files join the device queue, so
    /// a slow large download cannot block lightweight apps that are ready.
    @discardableResult
    static func startCatalog(_ app: CatalogApp, with emulator: EmulatorController,
                             presenting window: NSWindow?) -> InstallJob {
        let job = InstallJob(name: app.name)
        job.retry = { [weak job, weak emulator, weak window] in
            guard let emulator else { return }
            job?.dismiss()
            startCatalog(app, with: emulator, presenting: window)
        }
        // Known from the catalog up front — so a reinstall hides the old row
        // and the search results recognize the job — and confirmed against the
        // .ipa's own Info.plist by the install pre-flight.
        job.bundleID = app.bundleID
        job.catalogIpaID = app.ipaID
        job.catalogIconURL = app.iconURL
        job.status = "Downloading…"
        job.downloadProgress = app.size.map { _ in 0 } ?? -1
        jobs.append(job)
        rows.add(job)
        NotificationCenter.default.post(name: .ltmInstallStarted, object: job)
        job.task = Task {
            defer { finish(job) }
            guard !Task.isCancelled else { return }
            job.status = "Downloading…"
            job.downloadProgress = -1
            NotificationCenter.default.post(name: .ltmInstallProgress, object: job)
            var scratch: URL?
            defer {
                // learn(from:) has read the file by now; the temp copy is done.
                if let scratch { try? FileManager.default.removeItem(at: scratch) }
            }
            // Mirror the whole pipeline on the guest's home screen with ONE App
            // Store placeholder: raised here at the first byte, under the same
            // id the install phase derives from the bundle id, so the install
            // adopts it (placeholderRaised) and cancels it when done. The
            // job-end cancel below is the backstop for every early exit —
            // cancel of an id already gone is a no-op on SpringBoard.
            var raised: Task<Void, Never>?
            if let bundleID = app.bundleID {
                raised = emulator.installPlaceholder("add", bundleID: bundleID)
            }
            defer {
                if let bundleID = app.bundleID {
                    emulator.installPlaceholder("cancel", bundleID: bundleID, after: raised)
                }
            }
            do {
                let ipa = try await CatalogClient.download(app) { fraction in
                    guard !job.isFinished, !job.isCancelled, job.downloadProgress != nil else { return }
                    let percent = fraction < 0 ? -1 : Int(fraction * 100)
                    let previousPercent = job.downloadProgress.map { $0 < 0 ? -1 : Int($0 * 100) }
                    guard percent != previousPercent else { return }
                    job.downloadProgress = fraction
                    job.status = fraction >= 0
                        ? "Downloading… \(Int(fraction * 100))%" : "Downloading…"
                    NotificationCenter.default.post(name: .ltmInstallProgress, object: job)
                }
                scratch = ipa.deletingLastPathComponent()
                job.downloadProgress = nil
                guard let actualID = await AppMetadataCache.bundleID(of: ipa),
                      actualID == app.bundleID else {
                    throw CatalogError.invalidCopy("The downloaded IPA does not contain the selected app.")
                }
                await install(job, ipa: ipa, with: emulator, presenting: window,
                              placeholderRaised: raised != nil)
            } catch {
                // Task.cancel() surfaces as URLError.cancelled out of
                // URLSession, not CancellationError — and cancelling is a
                // decision, not a failure, either way.
                guard !Task.isCancelled else { return }
                job.failed = true
                job.status = error.localizedDescription
            }
        }
        return job
    }

    private static func finish(_ job: InstallJob) {
        jobs.removeAll { $0 === job }
        job.isFinished = true
        job.finishedAt = Date()
        job.downloadProgress = nil
        NotificationCenter.default.post(name: .ltmAppsChanged, object: nil)
    }

    /// Queue when bytes are ready, not when the app was selected.
    private static func install(_ job: InstallJob, ipa: URL,
                                with emulator: EmulatorController,
                                presenting window: NSWindow?,
                                placeholderRaised: Bool = false) async {
        if readyQueue.isBusy || readyQueue.isPaused {
            job.status = readyQueue.isPaused ? "Paused" : "Waiting for device…"
            NotificationCenter.default.post(name: .ltmInstallProgress, object: job)
        }
        do { try await readyQueue.acquire() }
        catch { return }
        defer { readyQueue.release() }
        guard !Task.isCancelled else { return }
        job.status = "Installing…"
        NotificationCenter.default.post(name: .ltmInstallProgress, object: job)
        do {
            let output = try await emulator.install(ipa, placeholderRaised: placeholderRaised) { line in
                Task { @MainActor in
                    job.status = line
                    // The upload is still interruptible; the install itself
                    // is not (DeviceTools checks cancellation between them).
                    if line.hasPrefix("Installing") { job.isCancellable = false }
                    NotificationCenter.default.post(name: .ltmInstallProgress, object: job)
                }
            }
            // Only when the app's own MinimumOSVersion is above 3.1.3 —
            // the version iPhone OS actually enforces. (Gating on the SDK
            // it was BUILT with fired on most of a 2009-era library and
            // taught people to click straight through this.)
            // It is really installed now, so the cache may adopt it — and the
            // library keeps the bytes, which is what makes the installed row
            // draggable out of the app as a file.
            await AppMetadataCache.shared.learn(from: ipa)
            if let id = job.bundleID { await IPALibrary.adopt(ipa, for: id) }
            if output.contains("newer than the device's") {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "“\(job.name)” installed, but may not launch"
                alert.informativeText = "It requires a newer version of iOS than 3.1.3, "
                    + "and iPhone OS refuses to launch such apps. "
                    + "Look for a version of this app built for iOS 3 or earlier."
                if let window { alert.beginSheetModal(for: window) { _ in } }
                else { alert.runModal() }
            }
        } catch is CancellationError {
            // Cancelling is a decision, not a failure. The placeholder icon
            // is already down: the script path has a TERM trap and the
            // in-process path a defer that survives cancellation.
        } catch {
            job.failed = true
            guard !Task.isCancelled else { return }
            pauseIfNeeded(error, with: emulator, excluding: job)
            job.status = error.localizedDescription
        }
    }

    /// A confirmed removal joins the same FIFO as ready installs. Keeping the
    /// task here makes pending removals visible to Quit even if the inspector
    /// is hidden. Cancellation skips queued work; an active guest operation
    /// finishes before the device slot is released.
    static func remove(_ apps: [InstalledApp], with emulator: EmulatorController,
                       presenting window: NSWindow?,
                       willRemove: @escaping (InstalledApp) -> Void,
                       didRemove: @escaping (InstalledApp) -> Void,
                       didFinish: @escaping () -> Void) {
        let id = UUID()
        removals[id] = Task {
            var acquired = false
            defer {
                if acquired { readyQueue.release() }
                removals[id] = nil
                didFinish()
                NotificationCenter.default.post(name: .ltmAppsChanged, object: nil)
            }
            do {
                try await readyQueue.acquire()
                acquired = true
                for app in apps {
                    try Task.checkCancellation()
                    willRemove(app)
                    try await emulator.uninstall(app.id)
                    AppMetadataCache.shared.forget(app.id)
                    IPALibrary.forget(app.id)
                    didRemove(app)
                }
            } catch is CancellationError {
                // Quit can cancel a waiting batch, never an active C call.
            } catch {
                guard !Task.isCancelled else { return }
                pauseIfNeeded(error, with: emulator)
                presentError(error, in: window)
            }
        }
    }

    /// Every queued device mutation shares this policy: an unavailable guest
    /// must not receive another write immediately after a failed removal.
    private static func pauseIfNeeded(_ error: Error, with emulator: EmulatorController,
                                      excluding failedJob: InstallJob? = nil) {
        guard let deviceError = error as? DeviceError, deviceError.shouldPauseInstallQueue else { return }
        readyQueue.pause()
        emulator.reportConnectionFailure(error, operation: "Transfer interrupted")
        for waiting in jobs where waiting !== failedJob && waiting.downloadProgress == nil {
            waiting.status = "Paused"
            NotificationCenter.default.post(name: .ltmInstallProgress, object: waiting)
        }
    }

    @MainActor
    static func presentError(_ error: Error, in window: NSWindow?) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}

final class AppsInspectorViewController: NSViewController {

    private let emulator: EmulatorController
    private let tableView = NSTableView()
    private let addRemove = NSSegmentedControl()
    private let searchField = NSSearchField()
    private let placeholder = NSTextField(labelWithString: "")
    private let emptyActions = NSStackView()
    private let browseButton = NSButton(title: "Browse Store", target: nil, action: nil)
    private let installButton = NSButton(title: "Install App…", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let resumeButton = NSButton(title: "Resume", target: nil, action: nil)
    private var queries: [PaneMode: String] = [:]
    private var catalogFailed = false

    /// Shown over a populated list when the device stops answering: the list is
    /// kept (it was correct a moment ago) but no longer silently pretends to be
    /// current.
    private let banner = NSTextField(labelWithString: "")
    private var bannerHeight: NSLayoutConstraint?
    private var lastLoaded: Date?
    private var apps: [InstalledApp] = []
    private var pending: [InstallJob] = []
    /// Bundle IDs in home-screen order, empty until SpringBoard tells us. The
    /// list is sorted by this when we have it, so the sidebar and the icons
    /// read the same way down the screen.
    private var homeOrder: [String] = []
    /// Set once the device has answered at all — until then an empty list means
    /// "we don't know yet", not "nothing is installed".
    private var haveLoaded = false
    private var loadTask: Task<Void, Never>?
    // MARK: Catalog (Store) state
    //
    // The table has exactly two modes, switched by the Installed/Store
    // segmented control (typing a search flips to Store; Store with an empty
    // search shows the suggested list): the installed list (pending +
    // visibleApps, whose index arithmetic is deliberately untouched) or the
    // Legacy Store results. Never both — a third section interleaved into the
    // installed list would have to reconcile with prunePending/visibleApps at
    // every step.
    enum PaneMode: Int { case installed = 0, store = 1 }
    /// Store first: the default view is the suggested list, ready to install.
    private var mode: PaneMode = .store
    private let modeControl = NSSegmentedControl(labels: ["Installed", "Store"],
                                                 trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private var catalogResults: [CatalogApp] = []
    private var searchTask: Task<Void, Never>?
    /// The table is showing Legacy Store content.
    private var searching: Bool { mode == .store }
    /// One list read at a time; see loadOnce.
    private var isLoading = false
    /// A refresh arrived while one was running; run once more when it finishes.
    private var needsReload = false
    private var notifications: GuestNotifications?

    init(emulator: EmulatorController) {
        self.emulator = emulator
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = NSView()

        let column = NSTableColumn(identifier: .init("app"))
        column.title = "Installed Apps"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        // A source list, which is what an inspector's list of things is: it
        // brings the standard row inset, selection material and — the reason
        // the old reordering looked homemade — AppKit's own drag feedback.
        tableView.style = .sourceList
        tableView.rowHeight = 56
        tableView.dataSource = self
        tableView.delegate = self
        // .string is the internal reorder drag; .fileURL is an .ipa dropped
        // from the Finder. The list of installed apps is the obvious place to
        // drop an app, and it silently ignored one — two inches to the left, on
        // the device screen, the same drop installed it.
        tableView.registerForDraggedTypes([.string, .fileURL])
        // Rows leave the app: installed rows as .ipa files (to the Finder),
        // Store rows as links — and both drop on the device view (local .copy).
        tableView.setDraggingSourceOperationMask([.copy], forLocal: false)
        tableView.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        let menu = NSMenu()
        menu.delegate = self
        // menuNeedsUpdate decides what is enabled; automatic enabling would
        // overrule it and re-enable Cancel Install on a job already cancelling.
        menu.autoenablesItems = false
        tableView.menu = menu
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        configureAddRemove()

        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.font = .systemFont(ofSize: NSFont.systemFontSize)
        placeholder.maximumNumberOfLines = 0
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isHidden = true

        // A quiet caption, the way Mail dates its last check — no fill at all.
        // Both a yellow band and a gray quaternary strip were tried; any
        // edge-to-edge fill under the segmented control reads as a broken
        // control, not a status line.
        banner.font = .systemFont(ofSize: 11)
        banner.textColor = .secondaryLabelColor
        banner.alignment = .center
        banner.lineBreakMode = .byTruncatingMiddle
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = true
        let bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        self.bannerHeight = bannerHeight

        modeControl.selectedSegment = mode.rawValue
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.segmentDistribution = .fillEqually
        modeControl.controlSize = .large
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        // Both modes act on several rows at once: bulk install in the Store,
        // bulk uninstall in Installed.
        tableView.allowsMultipleSelection = true

        for (button, action) in [(browseButton, #selector(browseStore)), (installButton, #selector(installLocal)),
                                 (retryButton, #selector(refreshClicked(_:))), (resumeButton, #selector(resumeInstallsClicked(_:)))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        for button in [browseButton, installButton, retryButton] { emptyActions.addArrangedSubview(button) }
        emptyActions.spacing = 8
        emptyActions.translatesAutoresizingMaskIntoConstraints = false
        emptyActions.isHidden = true
        resumeButton.translatesAutoresizingMaskIntoConstraints = false
        resumeButton.isHidden = true
        [modeControl, banner, scroll, placeholder, emptyActions, resumeButton].forEach(container.addSubview)
        // Everything hangs below the safe area — a hard edge at the toolbar,
        // so rows can never slide behind the search field (full-bleed +
        // automatic insets let them scroll under the glass, unblurred and
        // unreadable; the only system knob for that edge,
        // preferredScrollEdgeEffectStyle, exists on accessory controllers,
        // not plain toolbars). Pre-26 the safe area is simply the pane.
        var constraints = [
            modeControl.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 6),
            modeControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            modeControl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            banner.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 6),
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            bannerHeight,

            scroll.topAnchor.constraint(equalTo: banner.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            emptyActions.topAnchor.constraint(equalTo: placeholder.bottomAnchor, constant: 12),
            emptyActions.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            resumeButton.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            resumeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            placeholder.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            placeholder.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            placeholder.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ]
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footer)
        footer.addSubview(addRemove)
        footerHeight = footer.heightAnchor.constraint(equalToConstant: 0)
        constraints += [
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor), footerHeight!,
            addRemove.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 10),
            addRemove.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ]
        NSLayoutConstraint.activate(constraints)

        view = container
        updateFooterVisibility()
    }

    /// The catalog search lives in the window toolbar (the standard Mac home
    /// for search — App Store, Mail), riding above the inspector thanks to the
    /// tracking separator. A custom top-accessory strip was tried first and
    /// fought the scroll-edge system: rows rendered over the toolbar.
    private weak var searchToolbarItem: NSSearchToolbarItem?

    func attachSearchField(to item: NSSearchToolbarItem) {
        configureSearchField()
        item.searchField = searchField
        searchToolbarItem = item
    }

    private func configureSearchField() {
        searchField.placeholderString = mode == .store ? "Search Store" : "Search Installed Apps"
        searchField.delegate = self
        // The cancel button clears the text and sends the action without a
        // controlTextDidChange; route both through the same handler.
        searchField.target = self
        searchField.action = #selector(searchEdited)
    }

    private var footerHeight: NSLayoutConstraint?
    private func updateFooterVisibility() {
        addRemove.isHidden = mode == .store
        footerHeight?.constant = mode == .store ? 0 : 34
    }

    private func configureAddRemove() {
        addRemove.segmentStyle = .smallSquare
        addRemove.trackingMode = .momentary
        addRemove.segmentCount = 2
        addRemove.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: "Install App"), forSegment: 0)
        addRemove.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: "Uninstall App"), forSegment: 1)
        addRemove.target = self
        addRemove.action = #selector(addOrRemove(_:))
        addRemove.translatesAutoresizingMaskIntoConstraints = false
        // Start disabled and let updateButtons() turn them on. Enabled-by-
        // default meant they were live all through the boot wait.
        addRemove.setEnabled(false, forSegment: 0)
        addRemove.setEnabled(false, forSegment: 1)
        updateButtons()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appsChanged), name: .ltmAppsChanged, object: nil)
        nc.addObserver(self, selector: #selector(installStarted(_:)), name: .ltmInstallStarted, object: nil)
        nc.addObserver(self, selector: #selector(installProgressed(_:)), name: .ltmInstallProgress, object: nil)
        nc.addObserver(self, selector: #selector(refreshIconDimming), name: NSApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(refreshIconDimming), name: NSApplication.didResignActiveNotification, object: nil)
        startInitialLoad()
        scheduleSearch()   // Store is the default view — fetch the suggested list
    }

    // MARK: - Loading / refresh

    /// Keep polling for the life of the view, not just until the device answers
    /// once: right after boot, ideviceinstaller can connect and report an empty
    /// list before installd has finished registering apps, which used to read
    /// as "answered" and stop the loop — leaving the sidebar empty until an
    /// install/uninstall notification forced a reload. Polling forever instead
    /// self-heals within one more tick either way.
    private func startInitialLoad() {
        guard emulator.canManageApps else {
            showInstalledPlaceholder("App management needs a usbmux session. Relaunch with app sync enabled.")
            updateButtons()
            return
        }
        // Push, so an install or uninstall shows up at once instead of on the
        // next tick. The poll below stays as the backstop.
        startGuestNotifications()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                // Ask "is the device even up?" in-process before spawning
                // anything: the probe answers in milliseconds, so a cold boot
                // no longer costs one failing ideviceinstaller launch per
                // second, and a transient lockdown wobble skips a poll
                // instead of failing it. Not while installing — the probe is
                // itself a lockdown session, the very thing being avoided.
                if self.readsSuppressed {
                    // Reads are suppressed while our own device work runs, but
                    // "unknown" is not "reachable": leaving the last value
                    // frozen meant Install App…, the toolbar and drag-to-install
                    // all kept claiming a device that might have gone away ten
                    // minutes ago. The type already models this as nil.
                    self.emulator.deviceReachable = nil
                } else {
                    do {
                        try await self.emulator.checkDeviceConnection()
                        // A transfer may have started while the probe waited
                        // for its service slot. Its wait is not a device fault.
                        guard !Task.isCancelled else { return }
                        if !self.readsSuppressed { await self.loadOnce() }
                    } catch is CancellationError {
                        return
                    } catch {
                        if !self.readsSuppressed {
                            self.emulator.reportConnectionFailure(error, operation: "Checking USB connection")
                            if !self.haveLoaded, self.pending.isEmpty {
                                self.showInstalledPlaceholder(self.emulator.connectionIssue?.summary ?? "Connecting to \(self.emulator.profile.shortName)…")
                            } else if self.haveLoaded {
                                self.showStaleBanner()
                            }
                            self.updateButtons()
                        }
                    }
                }
                // Press hard until the device has answered once — a cold boot
                // takes ~40 s and the list is the first thing anyone looks at.
                // After that this is only a BACKSTOP: notification_proxy pushes
                // install/uninstall the moment they happen, so the poll exists
                // for what the guest never publishes (icon reordering) and for
                // a dropped session, neither of which needs a 3 s cadence.
                try? await Task.sleep(for: .seconds(self.haveLoaded ? 15 : 1))
            }
        }
    }

    @objc private func refreshIconDimming() {
        // Catalog mode: different row count, and pending.count may exceed it —
        // the range below would raise. Catalog rows redraw on reload anyway.
        guard !searching else { return }
        for row in pending.count..<numberOfRows(in: tableView) {
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView)?
                .imageView?.layer?.opacity = NSApp.isActive ? 1 : 0.5
        }
    }

    /// Drop finished install rows, but not before the device admits the app
    /// exists. instproxy does not list a newly installed app the instant the
    /// install call returns, so removing the row on completion left a window
    /// with neither the pending row nor a real one — the app appeared to vanish
    /// and only came back on a manual refresh. Bounded, so a failed install (or
    /// one whose bundle id we never learned) cannot strand a row forever.
    private func prunePending() {
        pending.removeAll { job in
            if job.dismissed { return true }
            guard job.isFinished else { return false }
            if job.failed { return false }
            if job.isCancelled { return true }   // nothing will ever appear
            guard let id = job.bundleID else {
                return Date().timeIntervalSince(job.finishedAt ?? Date()) > 15
            }
            if apps.contains(where: { $0.id == id }) { return true }
            // Two bounds, not one. At 20s ask the device again rather than
            // dropping the row blind — deleting it reopened the "app vanished
            // from the sidebar" gap this row exists to close, just 20 seconds
            // later. At 60s give up anyway, because a row that can never leave
            // is its own bug.
            let age = Date().timeIntervalSince(job.finishedAt ?? Date())
            if age > 60 { return true }
            if age > 20 { Task { await self.loadOnce() } }
            return false
        }
    }

    private enum RowIdentity: Hashable {
        case job(ObjectIdentifier), app(String), catalog(Int)
    }
    private var displayedRows: [RowIdentity] = []
    private var rowIdentities: [RowIdentity] {
        if searching { return catalogResults.map { .catalog($0.ipaID) } }
        return pending.map { .job(ObjectIdentifier($0)) } + visibleApps.map { .app($0.id) }
    }

    private struct RowAppearance: Equatable {
        enum Kind { case app, install, open, progress, failed, resume }
        var title: String
        var subtitle: String
        var icon: ObjectIdentifier?
        var kind: Kind = .app
        var progress: Double?
        var enabled = true
    }
    private var displayedAppearances: [RowAppearance] = []

    /// Capture only values that affect a row's presentation. A device poll or
    /// unrelated transfer must not replace buttons under the pointer or reset
    /// VoiceOver's current element.
    private var rowAppearances: [RowAppearance] {
        func transfer(_ job: InstallJob, icon: NSImage?) -> RowAppearance {
            RowAppearance(title: job.name, subtitle: job.isCancelled ? "Cancelling…" : job.status,
                          icon: icon.map(ObjectIdentifier.init),
                          kind: job.failed ? .failed : job.status == "Paused" ? .resume : .progress,
                          progress: job.downloadProgress, enabled: job.failed || job.isCancellable)
        }
        if searching {
            return catalogResults.map { app in
                let icon = catalogIcon(app).map(ObjectIdentifier.init)
                if let id = app.bundleID, uninstalling.contains(id) {
                    return RowAppearance(title: app.name, subtitle: removalStatus(for: id), icon: icon, kind: .progress)
                }
                if let failed = pending.last(where: {
                    $0.failed && !$0.dismissed && ($0.catalogIpaID == app.ipaID || ($0.bundleID != nil && $0.bundleID == app.bundleID))
                }) { return transfer(failed, icon: catalogIcon(app)) }
                let state = catalogState(of: app)
                if let job = catalogJob(for: app), !job.isFinished {
                    return transfer(job, icon: catalogIcon(app))
                }
                return RowAppearance(title: app.name, subtitle: app.subtitle, icon: icon,
                                     kind: state == .installed ? .open : .install,
                                     enabled: state == .installed
                                        ? emulator.canReachDevice && !busyWithDevice && apps.contains { $0.id == app.bundleID }
                                        : state == .installable)
            }
        }
        let transfers = pending.map { job in
            if job.isFinished, !job.isCancelled, !job.failed {
                return RowAppearance(title: job.name, subtitle: job.bundleID ?? job.status,
                                     icon: job.bundleID.flatMap { AppMetadataCache.shared.icon(for: $0) }.map(ObjectIdentifier.init))
            }
            return transfer(job, icon: pendingIcon(job))
        }
        return transfers + visibleApps.map { app in
            RowAppearance(title: displayName(app),
                          subtitle: uninstalling.contains(app.id) ? removalStatus(for: app.id) : "\(app.id) · \(app.version)",
                          icon: AppMetadataCache.shared.icon(for: app.id).map(ObjectIdentifier.init),
                          kind: uninstalling.contains(app.id) ? .progress : .app)
        }
    }

    /// Keep selection attached to objects, rebuilding only changed rows. An
    /// unchanged background poll leaves native views and accessibility intact.
    private func reloadTablePreservingSelection() {
        let identities = rowIdentities
        let appearances = rowAppearances
        if identities == displayedRows {
            let changed = IndexSet(appearances.indices.filter {
                !displayedAppearances.indices.contains($0) || appearances[$0] != displayedAppearances[$0]
            })
            displayedAppearances = appearances
            if !changed.isEmpty { tableView.reloadData(forRowIndexes: changed, columnIndexes: [0]) }
            return
        }
        let selected = Set(tableView.selectedRowIndexes.compactMap {
            displayedRows.indices.contains($0) ? displayedRows[$0] : nil
        })
        displayedRows = identities
        displayedAppearances = appearances
        tableView.reloadData()
        let indexes = IndexSet(displayedRows.indices.filter { selected.contains(displayedRows[$0]) })
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    @objc private func appsChanged() {
        prunePending()
        // Reload NOW, not from loadOnce: its failure path doesn't touch the
        // table, and an install that failed because the device died is exactly
        // the case where the next read fails too — leaving a phantom pending
        // row on screen while every data-source index has shifted up one (the
        // right-click-hits-the-wrong-app bug).
        reloadTablePreservingSelection()
        updateButtons()
        Task { await loadOnce() }
    }

    @objc private func installStarted(_ note: Notification) {
        guard let job = note.object as? InstallJob else { return }
        pending.append(job)
        // Files dropped on the canvas have no Store row to carry their
        // progress. Reveal the accepted transfer immediately, even when the
        // inspector was closed or the user was browsing the Store.
        if job.catalogIpaID == nil {
            setMode(.installed)
            if let split = parent as? NSSplitViewController,
               let item = split.splitViewItem(for: self) { item.animator().isCollapsed = false }
        }
        showInstalledPlaceholder(nil)
        reloadTablePreservingSelection()
        if job.catalogIpaID == nil { tableView.scrollRowToVisible(pending.count - 1) }
        updateButtons()
    }

    @objc private func installProgressed(_ note: Notification) {
        guard note.object is InstallJob else { return }
        reloadTablePreservingSelection()
        updateButtons()
    }

    /// One attempt to read the installed list.
    ///
    /// A failed read leaves the previous list on screen. It used to replace it
    /// with an empty one — every transient "could not start the service" blanked
    /// a sidebar that was perfectly correct a second earlier, and read as the
    /// list having lost its contents for no reason.
    private func loadOnce() async {
        guard emulator.canManageApps else { return }
        // Nothing talks to the device while an install runs (see `installing`);
        // the finish notification reloads the list anyway.
        guard !readsSuppressed else { return }
        // One at a time. Every .ltmAppsChanged used to spawn another of these,
        // and an upgrade publishes two notifications back to back — so two
        // reads queued on the gate for up to 20s each and the SLOWER, older one
        // assigned `apps` last, putting a stale list on screen.
        // Coalesce, don't drop. A refresh that arrives while one is in flight
        // used to be discarded outright — and the read already running was
        // started BEFORE the change that prompted it, so the list it publishes
        // is already stale. Notification-driven refreshes, the post-reorder
        // re-read and the user's own Refresh all went through this path, which
        // is a large part of "the list and the home screen fall out of sync".
        guard !isLoading else { needsReload = true; return }
        isLoading = true
        defer {
            isLoading = false
            if needsReload { needsReload = false; Task { await loadOnce() } }
        }
        do {
            let live = try await emulator.installedApps()
            // Read the home-screen order BEFORE publishing anything. Assigning
            // `apps` and then awaiting left the data source reporting a row
            // count the table had never been told about, and anything that
            // re-queried it during that window (a layout pass, the
            // active/inactive icon dimming) asked for a row that did not exist
            // — an out-of-range raise, not a glitch.
            let order = (try? await emulator.homeScreenOrder()) ?? homeOrder
            // No suspension points from here to reloadData().
            apps = live
            homeOrder = order
            haveLoaded = true
            lastLoaded = Date()
            emulator.deviceReachable = true
            hideStaleBanner()
            // SpringBoard publishes no notification when icons are rearranged
            // on the device — notification_proxy carries application_installed
            // and application_uninstalled, but nothing for the icon layout — so
            // a reorder made on the guest can only be noticed by asking again,
            // every time round, or the sidebar disagrees with the home screen
            // until something else happens to refresh it.
            //
            sortApps()
            prunePending()   // the list just changed; a row may have earned its exit
            reloadTablePreservingSelection()
            showInstalledPlaceholder(installedPlaceholderText)
            updateButtons()
        } catch is CancellationError {
            // Closing the inspector or ending a poll is not a failed device.
            return
        } catch {
            emulator.reportConnectionFailure(error, operation: "Refreshing apps")
            // Prune here too. This path never touched `pending`, so a row whose
            // install failed because the device went away stayed on screen —
            // and the failing list read is exactly when that happens.
            prunePending()
            reloadTablePreservingSelection()
            // The reason rides along so a manual Refresh that fails says why,
            // instead of sitting on the same three words the boot wait shows.
            if !haveLoaded, pending.isEmpty {
                if case DeviceError.unavailable = error {
                    // Permanent and host-side: "Waiting" is the wrong frame and
                    // names no remedy.
                    showInstalledPlaceholder("App services are missing from this copy of Light Touch. Reinstall the app to restore app management.")
                } else {
                    showInstalledPlaceholder(emulator.connectionIssue?.summary ?? "Couldn’t update apps. Retrying…")
                }
                placeholder.toolTip = emulator.connectionIssue?.detail
            } else if haveLoaded {
                showStaleBanner()   // keep the list, mark it stale
            }
            // Also on the failure path: when usbmuxd dies the session goes away
            // and canManageApps flips false, but nothing told the inspector, so
            // "+" stayed enabled, opened a file picker, and the install failed
            // with an error blaming the guest for a host daemon that had died.
            updateButtons()
        }
    }

    /// True when the HOST side is gone rather than the guest — worth saying,
    /// because "device not responding" points the user at the wrong thing.
    private var usbUnavailable: Bool { !emulator.canManageApps }

    /// Subscribe to the guest's own install/uninstall notifications.
    private func startGuestNotifications() {
        guard notifications == nil, let session = emulator.usbmuxSession else { return }
        let watcher = GuestNotifications(clientSocket: session) { [weak emulator] in emulator?.status?.iconGeneration }
        notifications = watcher
        let emulator = self.emulator
        watcher.start(attachAllowed: {
            await MainActor.run {
                emulator.isRunning && !emulator.preparingMedia && emulator.usbConnected && !AppInstaller.isUsingDevice
                    && !emulator.isInstalling && !emulator.hasFileTransfer && !emulator.isReconnecting
            }
        }) {
            // Off the library's callback thread and onto ours.
            Task { @MainActor in
                NotificationCenter.default.post(name: .ltmAppsChanged, object: nil)
            }
        }
    }

    // GuestNotifications cancels its own loops in its deinit, which is what
    // this releasing it triggers; nothing else here may touch main-actor state.
    deinit { loadTask?.cancel(); searchTask?.cancel() }

    static func freshnessText(since date: Date?, now: Date = Date()) -> String {
        guard let date else { return "not yet refreshed" }
        guard now.timeIntervalSince(date) >= 60 else { return "last updated just now" }
        let relative = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
        return "last updated \(relative)"
    }

    private func showStaleBanner() {
        let when = Self.freshnessText(since: lastLoaded)
        if emulator.isPoweredOff { banner.stringValue = "Device powered off" }
        else if emulator.shuttingDown { banner.stringValue = "Device powering off…" }
        else if emulator.isReconnecting { banner.stringValue = "Reconnecting app services…" }
        else {
            banner.stringValue = usbUnavailable
                ? "USB connection unavailable"
                : emulator.connectionIssue?.summary ?? "Connecting to \(emulator.profile.shortName)…"
        }
        banner.toolTip = [emulator.connectionIssue?.detail, when, "Open Device Logs for details."]
            .compactMap { $0 }.joined(separator: "\n")
        banner.isHidden = false
        bannerHeight?.constant = 18
    }

    private func hideStaleBanner() {
        guard !banner.isHidden else { return }
        banner.isHidden = true
        bannerHeight?.constant = 0
    }

    /// Home-screen order when SpringBoard has told us one, and the *displayed*
    /// name otherwise — sorting by the reported name while showing the cached
    /// one is what made the list look unsorted and shuffle as metadata landed.
    private func sortApps() {
        // Sorted on a key, not a mix of two rules: comparing home-screen index
        // when both are known and names otherwise is not a consistent ordering,
        // and sort() is free to produce nonsense from one.
        apps.sort { a, b in
            let i = homeOrder.firstIndex(of: a.id) ?? .max
            let j = homeOrder.firstIndex(of: b.id) ?? .max
            if i != j { return i < j }
            return displayName(a).localizedCaseInsensitiveCompare(displayName(b)) == .orderedAscending
        }
    }

    private func displayName(_ app: InstalledApp) -> String {
        AppMetadataCache.shared.name(for: app.id) ?? app.name
    }

    private func showPlaceholder(_ text: String?) {
        placeholder.stringValue = text ?? ""
        placeholder.isHidden = (text == nil)
        let empty = !searching && haveLoaded && apps.isEmpty && pending.isEmpty
        browseButton.isHidden = !empty
        installButton.isHidden = !empty
        installButton.isEnabled = emulator.canQueueInstall
        retryButton.isHidden = !catalogFailed || !searching
        emptyActions.isHidden = text == nil || (!empty && (!catalogFailed || !searching))
    }

    /// Installed-list placeholders only — a no-op while the catalog results own
    /// the table, so the background poll can't clobber "No compatible apps
    /// found" with "Waiting for the device…" mid-search.
    private func showInstalledPlaceholder(_ text: String?) {
        guard !searching else { return }
        showPlaceholder(text)
    }

    /// What the installed list's placeholder should say right now — for
    /// restoring it when a search is cleared. The poll re-corrects within a
    /// tick if this guesses wrong.
    private var installedPlaceholderText: String? {
        if !haveLoaded { return pending.isEmpty ? "Waiting for the device…" : nil }
        return visibleApps.isEmpty && pending.isEmpty ? (queries[.installed, default: ""].isEmpty ? "No apps installed" : "No matching apps") : nil
    }

    /// Network downloads and waiting rows do not hold a device session.
    private var installing: Bool { AppInstaller.isUsingDevice || emulator.isInstalling }

    /// Apps with an uninstall in flight. Without this the row stayed, the
    /// buttons stayed live, and nothing said anything for up to two minutes —
    /// so the obvious thing to do was press Uninstall again.
    private var uninstalling: Set<String> = []
    private var removingApp: String?

    private func canUninstall(_ selection: [InstalledApp]) -> Bool {
        emulator.canQueueInstall && !selection.isEmpty
            && !selection.contains { uninstalling.contains($0.id) }
    }

    private func removalStatus(for bundleID: String) -> String {
        if removingApp == bundleID { return "Removing…" }
        return AppInstaller.isPaused ? "Removal paused" : "Waiting to remove…"
    }

    /// Any device operation of ours in flight.
    private var busyWithDevice: Bool { installing || !uninstalling.isEmpty }

    /// Waiting removals must not suppress recovery: a paused transfer queue can
    /// contain them indefinitely. Only the operation actually owning the guest
    /// connection (or a recovery in progress) needs reads to stand aside.
    private var readsSuppressed: Bool { installing || emulator.preparingMedia || emulator.hasFileTransfer || emulator.isReconnecting }

    private func updateButtons() {
        // A cached list can outlive the connection. Match the removal action's
        // reachability gate so stale rows never advertise a usable Uninstall.
        resumeButton.isHidden = !AppInstaller.isPaused
        if AppInstaller.isPaused {
            banner.stringValue = "Transfers paused"
            banner.isHidden = false
            bannerHeight?.constant = 28
        }
        addRemove.setEnabled(emulator.canQueueInstall, forSegment: 0)
        addRemove.setEnabled(haveLoaded && canUninstall(selectedApps), forSegment: 1)
    }

    /// Every selected installed app — pending rows and catalog rows resolve to
    /// nil through app(at:) and drop out.
    private var selectedApps: [InstalledApp] {
        tableView.selectedRowIndexes.compactMap { app(at: $0) }
    }

    /// The installed apps actually shown. An app being replaced by a newer
    /// build is hidden while its pending row is up — otherwise a reinstall
    /// lists the same app twice, once installing and once as the old version,
    /// and the old row's Uninstall would remove what is being installed.
    private var visibleApps: [InstalledApp] {
        let replacing = Set(pending.compactMap { $0.isFinished ? nil : $0.bundleID })
        let query = queries[.installed, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        return apps.filter { !replacing.contains($0.id) && (query.isEmpty || displayName($0).localizedStandardContains(query) || $0.id.localizedStandardContains(query)) }
    }

    private func app(at row: Int) -> InstalledApp? {
        // Catalog mode: the rows are CatalogApps, and every installed-list
        // interaction that resolves a row through here (uninstall, reorder,
        // context menu) must come up empty.
        guard !searching else { return nil }
        let index = row - pending.count
        let shown = visibleApps
        return shown.indices.contains(index) ? shown[index] : nil
    }

    // MARK: - Actions

    @objc private func addOrRemove(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? add() : remove(selectedApps)
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa")].compactMap { $0 }
        // Several at once: ready files install one at a time.
        panel.allowsMultipleSelection = true
        panel.message = "Choose one or more decrypted .ipa files to install."
        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard let self, response == .OK else { return }
            for url in panel.urls {
                AppInstaller.start(url, with: self.emulator, presenting: self.view.window)
            }
        }
    }

    private func remove(_ appsToRemove: [InstalledApp]) {
        guard canUninstall(appsToRemove) else { return }
        let alert = NSAlert()
        alert.messageText = appsToRemove.count == 1
            ? "Uninstall “\(displayName(appsToRemove[0]))”?"
            : "Uninstall \(appsToRemove.count) apps?"
        alert.informativeText = appsToRemove.count == 1
            ? "This removes the app and its data from the device."
            : "This removes the apps and their data from the device."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: view.window!) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            // An install can finish while this confirmation is open, leaving
            // reachability temporarily unknown until the next probe. The
            // already accepted removal must still enter the queue.
            guard self.emulator.isRunning, self.emulator.canManageApps else {
                AppInstaller.presentError(DeviceToolsError.failed("The \(emulator.profile.shortName) is unavailable. Try again when it reconnects."),
                                          in: self.view.window)
                return
            }
            let remaining = appsToRemove.filter { !self.uninstalling.contains($0.id) }
            guard !remaining.isEmpty else { return }
            for app in remaining { self.uninstalling.insert(app.id) }
            self.reloadTablePreservingSelection()
            self.updateButtons()
            AppInstaller.remove(remaining, with: self.emulator, presenting: self.view.window) { app in
                self.removingApp = app.id
                self.reloadTablePreservingSelection()
            } didRemove: { app in
                self.uninstalling.remove(app.id)
                self.removingApp = nil
                self.apps.removeAll { $0.id == app.id }
                self.reloadTablePreservingSelection()
            } didFinish: {
                for app in remaining { self.uninstalling.remove(app.id) }
                self.removingApp = nil
                self.reloadTablePreservingSelection()
                self.updateButtons()
            }
        }
    }

    @objc private func uninstallClicked(_ sender: NSMenuItem) {
        if let apps = sender.representedObject as? [InstalledApp] { remove(apps) }
        else if let app = sender.representedObject as? InstalledApp { remove([app]) }
    }

    @objc private func dismissInstallClicked(_ sender: NSMenuItem) {
        (sender.representedObject as? InstallJob)?.dismiss()
    }

    @objc private func cancelInstallClicked(_ sender: NSMenuItem) {
        (sender.representedObject as? InstallJob)?.cancel()
    }

    @objc private func showInLegacyStoreClicked(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? InstalledApp else { return }
        // /app/<bundle_id> is a first-class route on the site (301s to the
        // canonical page); apps the archive doesn't know 404 there, which is
        // an honest answer.
        NSWorkspace.shared.open(CatalogClient.baseURL.appendingPathComponent("app/\(app.id)"))
    }

    @objc private func resumeInstallsClicked(_ sender: Any?) {
        Task {
            guard await emulator.deviceReady() else {
                AppInstaller.presentError(DeviceError.notAttached, in: view.window)
                return
            }
            emulator.deviceReachable = true
            AppInstaller.resume()
            hideStaleBanner()
            reloadTablePreservingSelection()
            updateButtons()
        }
    }

    @objc private func refreshClicked(_ sender: Any?) {
        if searching { scheduleSearch(); return }
        Task { await loadOnce() }
    }

    // MARK: - Legacy Store (mode + search)

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        setMode(PaneMode(rawValue: sender.selectedSegment) ?? .installed)
    }

    private func setMode(_ newMode: PaneMode) {
        searchTask?.cancel()
        queries[mode] = searchField.stringValue
        mode = newMode
        searchField.stringValue = queries[newMode, default: ""]
        searchField.placeholderString = newMode == .store ? "Search Store" : "Search Installed Apps"
        modeControl.selectedSegment = newMode.rawValue
        tableView.deselectAll(nil)
        reloadTablePreservingSelection()
        updateButtons()
        updateFooterVisibility()
        switch newMode {
        case .installed:
            showPlaceholder(installedPlaceholderText)
        case .store:
            scheduleSearch()
        }
    }

    /// Find / Search Apps: put the caret in the toolbar search field.
    func focusSearch() {
        guard let window = view.window ?? parent?.view.window else { return }
        if let split = window.contentViewController as? NSSplitViewController,
           let item = split.splitViewItem(for: self) { item.isCollapsed = false }
        window.contentView?.layoutSubtreeIfNeeded()
        // The field may be collapsed into a search icon or toolbar overflow.
        // AppKit owns attaching and expanding it before assigning focus.
        searchToolbarItem?.beginSearchInteraction()
    }

    @objc private func browseStore() { setMode(.store) }
    @objc private func installLocal() { add() }
    @objc private func searchEdited() {
        queries[mode] = searchField.stringValue
        if mode == .installed {
            reloadTablePreservingSelection()
            showPlaceholder(installedPlaceholderText)
        } else { scheduleSearch() }
    }

    /// Fetch what the Store view should show for the current search text —
    /// results for a query, the suggested (most-archived compatible) list for
    /// an empty one. No-op outside Store mode.
    private func scheduleSearch() {
        searchTask?.cancel()
        guard mode == .store else { return }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        catalogFailed = false
        catalogResults = []
        reloadTablePreservingSelection()
        // Replace the other mode's overlay before any debounce/network await.
        // Cached Store rows remain usable while their refresh is in flight.
        showPlaceholder(catalogResults.isEmpty
            ? (query.isEmpty ? "Loading Legacy Store…" : "Searching Legacy Store…")
            : nil)
        searchTask = Task { [weak self] in
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(300))   // debounce typing
            }
            guard let self, !Task.isCancelled else { return }
            // Only the response to what's in the field now may land — a slower
            // older query resolving late must not overwrite a newer list.
            let current = {
                self.mode == .store
                    && self.searchField.stringValue.trimmingCharacters(in: .whitespaces) == query
            }
            do {
                let results = try await CatalogClient.search(query)
                guard !Task.isCancelled, current() else { return }
                self.catalogResults = results
                self.reloadTablePreservingSelection()
                self.showPlaceholder(results.isEmpty
                    ? (query.isEmpty ? "Legacy Store is empty right now."
                                     : "No compatible apps found for “\(query)”.")
                    : nil)
                self.fetchCatalogIcons(results)
            } catch {
                guard !Task.isCancelled, current() else { return }
                self.catalogResults = []
                self.catalogFailed = true
                self.reloadTablePreservingSelection()
                self.showPlaceholder("Couldn’t reach Legacy Store — \(error.localizedDescription)")
            }
            self.updateButtons()
        }
    }

    /// Warm the icon memo for these results, repainting each row as its icon
    /// lands. Content-addressed URLs, so a memo hit never goes stale.
    private func fetchCatalogIcons(_ results: [CatalogApp]) {
        for app in results {
            guard let url = app.iconURL,
                  CatalogClient.iconMemo.object(forKey: url.absoluteString as NSString) == nil
            else { continue }
            Task { [weak self] in
                guard await CatalogClient.icon(for: app) != nil else { return }
                self?.reloadCatalogRow(app.ipaID)
            }
        }
    }

    private func reloadCatalogRow(_ ipaID: Int) {
        guard searching, catalogResults.contains(where: { $0.ipaID == ipaID }) else { return }
        reloadTablePreservingSelection()
    }

    /// The job working on this catalog app, if one is. Matched by the copy's
    /// own id first, then bundle id (a local .ipa install of the same app
    /// counts too). Failed and cancelled jobs don't claim the row — the user
    /// should be able to try again.
    fileprivate func catalogJob(for app: CatalogApp) -> InstallJob? {
        pending.first { job in
            guard !job.failed, !job.isCancelled else { return false }
            if job.catalogIpaID == app.ipaID { return true }
            return job.bundleID != nil && job.bundleID == app.bundleID
        }
    }

    /// Is this catalog app already on the device, or on its way there?
    fileprivate func catalogState(of app: CatalogApp) -> CatalogRowState {
        if let job = catalogJob(for: app) {
            // A cleanly finished job reads as installed even before the device
            // lists it — otherwise Install flashed back for the second between
            // the install completing and installd admitting the app exists.
            if job.isFinished { return .installed }
            if let fraction = job.downloadProgress { return .downloading(fraction) }
            return .installing
        }
        if let id = app.bundleID, apps.contains(where: { $0.id == id }) { return .installed }
        // Busy with our own install means the device is fine, just serialized —
        // more jobs may queue behind it. (The poll deliberately parks
        // deviceReachable at nil while device work runs, so canReachDevice
        // alone would disable every Install button for the whole install.)
        if emulator.canQueueInstall { return .installable }
        return .unavailable
    }

    @objc fileprivate func catalogInstallClicked(_ sender: NSButton) {
        guard searching, catalogResults.indices.contains(sender.tag) else { return }
        let app = catalogResults[sender.tag]
        if let installed = apps.first(where: { $0.id == app.bundleID }) { launch(installed) }
        else { install(catalog: app) }
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        if searching {
            guard catalogResults.indices.contains(row) else { return }
            let item = NSMenuItem()
            item.representedObject = catalogResults[row]
            catalogDetailsClicked(item)
            return
        }
        launch(app(at: row))
    }

    /// Launch an installed app on the guest, exactly as tapping its icon would.
    private func launch(_ app: InstalledApp?) {
        guard let app, !busyWithDevice, !uninstalling.contains(app.id) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await emulator.launchApp(app.id)
                NotificationCenter.default.post(name: .ltmAppLaunched, object: nil)
            } catch is CancellationError {
                return
            } catch {
                let alert = NSAlert()
                if case AppLaunchError.locked = error {
                    alert.alertStyle = .informational
                    alert.messageText = "Unlock the \(emulator.profile.shortName)"
                    alert.informativeText = "Unlock the \(emulator.profile.shortName), then try opening “\(displayName(app))” again."
                } else {
                    alert.alertStyle = .warning
                    alert.messageText = "Couldn’t open “\(displayName(app))”"
                    if let launchError = error as? AppLaunchError {
                        alert.informativeText = launchError.message(for: emulator.profile)
                    } else {
                        logEvent("launch \(app.id): \(error.localizedDescription)")
                        alert.informativeText = AppLaunchError.failed.message(for: emulator.profile)
                    }
                }
                if let window = view.window { _ = await alert.beginSheetModal(for: window) }
                else { alert.runModal() }
            }
        }
    }

    @objc fileprivate func openClicked(_ sender: NSMenuItem) {
        launch(sender.representedObject as? InstalledApp)
    }

    @objc fileprivate func viewOnLegacyStoreClicked(_ sender: NSMenuItem) {
        guard let url = (sender.representedObject as? CatalogApp)?.appURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func catalogDetailsClicked(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? CatalogApp else { return }
        let canInstall = { [weak self] in
            guard let self else { return false }
            return self.emulator.canQueueInstall && self.catalogJob(for: app)?.isFinished != false
        }
        let sheet = CatalogDetailsViewController(app: app, canInstall: canInstall) { [weak self] copy in
            guard let self, canInstall() else { return }
            AppInstaller.startCatalog(copy, with: self.emulator, presenting: self.view.window)
        }
        presentAsSheet(sheet)
    }

    @objc fileprivate func installCatalogClicked(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? CatalogApp else { return }
        install(catalog: app)
    }

    @objc fileprivate func installSelectedCatalogClicked(_ sender: NSMenuItem) {
        for app in (sender.representedObject as? [CatalogApp]) ?? [] {
            install(catalog: app)
        }
    }

    private func install(catalog app: CatalogApp) {
        guard catalogState(of: app) == .installable else { return }
        // The job owns the whole pipeline — download included — so the row is
        // in `pending` (and visible in the installed list) from the first byte.
        AppInstaller.startCatalog(app, with: emulator, presenting: view.window)
    }
}

/// What a catalog row can offer right now.
enum CatalogRowState: Equatable {
    case installable
    /// 0…1, or negative when the total size is unknown (indeterminate).
    case downloading(Double)
    case installing, installed, unavailable
}

// MARK: - Search field

extension AppsInspectorViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { searchEdited() }
}

// MARK: - Context menu

extension AppsInspectorViewController: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let isMainMenu = menu !== tableView.menu
        if isMainMenu {
            let install = menu.addItem(withTitle: "Install App…", action: #selector(MainWindowController.installApp(_:)),
                                       keyEquivalent: "i")
            install.keyEquivalentModifierMask = [.shift, .command]
            install.isEnabled = emulator.canQueueInstall
            let media = menu.addItem(withTitle: "Import Media…", action: #selector(MainWindowController.syncMedia(_:)), keyEquivalent: "")
            media.isEnabled = emulator.canQueueInstall
            menu.addItem(.separator())
        }
        appendAppActions(to: menu, row: isMainMenu ? tableView.selectedRow : tableView.clickedRow)
        if isMainMenu, tableView.selectedRow < 0 {
            for title in ["Open", "Uninstall…"] {
                let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
            }
        }
        if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
        let refresh = menu.addItem(withTitle: isMainMenu ? "Refresh Apps" : "Refresh", action: #selector(refreshClicked(_:)),
                                   keyEquivalent: "")
        refresh.target = self
        // These explicit targets must obey the same window scope as the
        // responder-chain device commands. Never refresh or delete a selection
        // behind the Files, Help, or log window.
        if isMainMenu, view.window !== NSApp.mainWindow {
            for item in menu.items { item.isEnabled = false }
        }
    }

    private func appendAppActions(to menu: NSMenu, row: Int) {
        if AppInstaller.isPaused {
            menu.addItem(withTitle: "Resume Transfers", action: #selector(resumeInstallsClicked(_:)),
                         keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        if searching {
            guard catalogResults.indices.contains(row) else { return }
            let app = catalogResults[row]
            // A right-click inside a multi-row selection offers the batch; the
            // whole queue machinery (independent downloads and serial installs,
            // per-row progress) already handles N jobs.
            let selection = tableView.selectedRowIndexes
            if selection.count > 1, selection.contains(row) {
                let installable = selection
                    .compactMap { catalogResults.indices.contains($0) ? catalogResults[$0] : nil }
                    .filter { catalogState(of: $0) == .installable }
                if installable.count > 1 {
                    let batch = menu.addItem(withTitle: "Install \(installable.count) Apps",
                                             action: #selector(installSelectedCatalogClicked(_:)),
                                             keyEquivalent: "")
                    batch.target = self
                    batch.representedObject = installable
                    return
                }
            }
            let installedApp = apps.first { $0.id == app.bundleID }
            if let job = catalogJob(for: app), !job.isFinished {
                let cancel = menu.addItem(withTitle: "Cancel Install",
                                          action: #selector(cancelInstallClicked(_:)), keyEquivalent: "")
                cancel.target = self
                cancel.representedObject = job
                cancel.isEnabled = !job.isCancelled && job.isCancellable
            } else if installedApp == nil {
                let install = menu.addItem(withTitle: "Install",
                                           action: #selector(installCatalogClicked(_:)), keyEquivalent: "")
                install.target = self
                install.representedObject = app
                install.isEnabled = catalogState(of: app) == .installable
            }
            if let installed = installedApp {
                if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
                let open = menu.addItem(withTitle: "Open",
                                        action: #selector(openClicked(_:)), keyEquivalent: "")
                open.target = self
                open.representedObject = installed
                open.isEnabled = !busyWithDevice && emulator.canReachDevice
                let uninstall = menu.addItem(withTitle: "Uninstall…",
                                             action: #selector(uninstallClicked(_:)), keyEquivalent: "")
                uninstall.target = self
                uninstall.representedObject = installed
                uninstall.isEnabled = canUninstall([installed])
                    && catalogJob(for: app)?.isFinished != false
                menu.addItem(.separator())
            }
            let details = menu.addItem(withTitle: "Choose Version…",
                                       action: #selector(catalogDetailsClicked(_:)), keyEquivalent: "")
            details.target = self
            details.representedObject = app
            if app.appURL != nil {
                let view = menu.addItem(withTitle: "View on Legacy Store",
                                        action: #selector(viewOnLegacyStoreClicked(_:)), keyEquivalent: "")
                view.target = self
                view.representedObject = app
            }
            return
        }
        // `!isFinished`, not just the index: a finished job is DRAWN as an
        // ordinary app row, so classifying by index alone offered "Cancel
        // Install" (which by then does nothing) on a row showing an installed
        // app's own icon and name, and never offered Uninstall.
        if row >= 0, row < pending.count, pending[row].failed {
            let item = menu.addItem(withTitle: "Dismiss", action: #selector(dismissInstallClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pending[row]
        } else if row >= 0, row < pending.count, !pending[row].isFinished {
            let job = pending[row]
            let item = menu.addItem(withTitle: "Cancel Install",
                                    action: #selector(cancelInstallClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = job
            item.isEnabled = !job.isCancelled && job.isCancellable
        } else if let app = app(at: row) {
            // A right-click inside a multi-row selection acts on the batch.
            let selection = selectedApps
            let batch = selection.count > 1 && selection.contains(where: { $0.id == app.id })
            if batch {
                let uninstall = menu.addItem(withTitle: "Uninstall \(selection.count) Apps…",
                                             action: #selector(uninstallClicked(_:)), keyEquivalent: "")
                uninstall.target = self
                uninstall.representedObject = selection
                uninstall.isEnabled = canUninstall(selection)
            } else {
                let open = menu.addItem(withTitle: "Open",
                                        action: #selector(openClicked(_:)), keyEquivalent: "")
                open.target = self
                open.representedObject = app
                open.isEnabled = !busyWithDevice && emulator.canReachDevice && !uninstalling.contains(app.id)
                let uninstall = menu.addItem(withTitle: "Uninstall…",
                                             action: #selector(uninstallClicked(_:)), keyEquivalent: "")
                uninstall.target = self
                uninstall.representedObject = app
                uninstall.isEnabled = canUninstall([app])

                let store = menu.addItem(withTitle: "View on Legacy Store",
                                         action: #selector(showInLegacyStoreClicked(_:)), keyEquivalent: "")
                store.target = self
                store.representedObject = app
                menu.addItem(.separator())
            }
        }
    }
}

// MARK: - Table data

extension AppsInspectorViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        searching ? catalogResults.count : pending.count + visibleApps.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        if searching {
            guard catalogResults.indices.contains(row) else { return nil }
            return catalogCell(for: catalogResults[row], row: row)
        }
        if row < pending.count {
            let job = pending[row]
            // A finished job renders as an ORDINARY app row — icon, name, no
            // spinner, no percentage — even though it is still a pending entry
            // underneath. Two things fall out of that. It stops claiming
            // "Installing… 90%" for an app already sitting on the home screen
            // (instproxy's last progress callback is 90, then "Complete", so
            // that number was simply the last one anyone heard). And when the
            // real row finally replaces it, the two look the same, so the swap
            // that used to make the whole list flicker is now invisible.
            if job.isFinished, !job.isCancelled, !job.failed {
                let cell = appCell(tableView)
                cell.textField?.stringValue = job.name
                (cell.viewWithTag(Self.appSubtitleTag) as? NSTextField)?.stringValue =
                    job.bundleID ?? job.status
                Self.setIcon(job.bundleID.flatMap { AppMetadataCache.shared.icon(for: $0) },
                             on: cell.imageView)
                cell.imageView?.layer?.opacity = NSApp.isActive ? 1 : 0.5
                return cell
            }
            return progressCell(icon: pendingIcon(job), title: job.name,
                                subtitle: job.isCancelled ? "Cancelling…" : job.status,
                                fraction: job.downloadProgress, job: job)
        }
        guard let app = app(at: row) else { return nil }
        if uninstalling.contains(app.id) {
            return progressCell(icon: AppMetadataCache.shared.icon(for: app.id),
                                title: displayName(app), subtitle: removalStatus(for: app.id))
        }
        let cell = appCell(tableView)
        cell.textField?.stringValue = displayName(app)
        (cell.viewWithTag(Self.appSubtitleTag) as? NSTextField)?.stringValue =
            "\(app.id)\(app.version.isEmpty ? "" : " · \(app.version)")"
        Self.setIcon(AppMetadataCache.shared.icon(for: app.id), on: cell.imageView)
        // AppKit only dims a *selected* row when the window resigns key,
        // leaving every other icon at full strength — inconsistent with the
        // rest of the sidebar, which dims as a whole. Set explicitly instead
        // of relying on that per-row behavior; refreshed by the app-active
        // observers below whenever it changes with no reload otherwise due.
        cell.imageView?.layer?.opacity = NSApp.isActive ? 1 : 0.5
        cell.toolTip = "\(app.id)\(app.version.isEmpty ? "" : " — \(app.version)")"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // Every row selects, pending installs included — an unselectable row in a
    // source list reads as broken. What a pending row can't do (uninstall) is
    // decided where the buttons are enabled, not by refusing the selection.

    // MARK: Dragging — reorder within, files/links out, .ipas in

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        if searching {
            // A Store row travels as its Legacy Store link, plus a private
            // payload the device view recognizes for drag-to-install.
            guard catalogResults.indices.contains(row) else { return nil }
            let app = catalogResults[row]
            let item = NSPasteboardItem()
            if let url = app.appURL { item.setString(url.absoluteString, forType: .URL) }
            if let payload = try? JSONEncoder().encode(app) {
                item.setData(payload, forType: .ltmCatalogApp)
            }
            return item
        }
        guard let app = app(at: row) else { return nil }
        // An installed row travels as its bundle id (the internal reorder
        // token) and, when the library kept the bytes, the .ipa file itself —
        // draggable straight into the Finder.
        let item = NSPasteboardItem()
        item.setString(app.id, forType: .string)
        if let file = IPALibrary.url(for: app.id) {
            item.setString(file.absoluteString, forType: .fileURL)
        }
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        if info.draggingSource as? NSTableView !== tableView {
            // From outside: an .ipa to install, if the device can take one.
            guard emulator.canReachDevice, !Self.droppedIPAs(info).isEmpty else { return [] }
            tableView.setDropRow(-1, dropOperation: .on)   // the list as a whole
            return .copy
        }
        // Reorder: only the installed list, only against a known home-screen
        // order, never during an install (the SpringBoard write is one more
        // lockdown session the install can't afford), and one row at a time
        // (moveOnHomeScreen takes one id).
        guard !searching, queries[.installed, default: ""].isEmpty, !homeOrder.isEmpty, !installing,
              info.draggingPasteboard.pasteboardItems?.count == 1,
              operation == .above, row >= pending.count else { return [] }
        return .move
    }

    private static func droppedIPAs(_ info: NSDraggingInfo) -> [URL] {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self])
                as? [URL] else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == "ipa" }
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let ipas = Self.droppedIPAs(info)
        if !ipas.isEmpty, info.draggingSource as? NSTableView !== tableView {
            ipas.forEach { AppInstaller.start($0, with: emulator, presenting: view.window) }
            return true
        }
        guard let id = info.draggingPasteboard.string(forType: .string) else { return false }
        // Dropping above row N means "put it where the app now at N sits", and
        // past the last row means the end. The bundle ID travels rather than the
        // index, so the answer survives the list reloading mid-drag.
        let target = app(at: row)?.id
        // Dropping an app on its OWN top edge is the no-op AppKit normally
        // treats as "nothing happened". Here `target` was the dragged app
        // itself, which the remove() below takes out of `apps` — so the
        // firstIndex lookup found nothing, the ?? fired, and the app was sent
        // to the END of the home screen. That got written to SpringBoard, so a
        // few pixels of accidental drag really moved the icon to the last page.
        guard target != id else { return false }

        // Move it locally first: the device round trip is slow enough that a row
        // snapping back and then jumping looks like a failed drag. Moved with
        // the table's own row animation rather than reloadData() — a reload in
        // the middle of a drop is what made this look homemade.
        if let from = apps.firstIndex(where: { $0.id == id }) {
            let app = apps.remove(at: from)
            let to = target.flatMap { t in apps.firstIndex { $0.id == t } } ?? apps.count
            apps.insert(app, at: to)
            tableView.beginUpdates()
            tableView.moveRow(at: pending.count + from, to: pending.count + to)
            tableView.endUpdates()
        }

        Task {
            do {
                // Adopt the order SpringBoard ACCEPTED. Dropping it meant the
                // next list read fell back to the pre-drag `homeOrder` and
                // re-sorted the sidebar back to where it started, while the
                // device kept the new arrangement.
                homeOrder = try await emulator.moveOnHomeScreen(id, before: target)
            } catch {
                AppInstaller.presentError(error, in: view.window)
            }
            await loadOnce()
        }
        return true
    }

    /// The row's icon well: the image when we have one, else a quiet
    /// system-fill square as the view's own background (rounded by its mask).
    /// The color is resolved for the current appearance here; rows rebuild on
    /// every reload, so a theme switch catches up on the next one.
    private static func setIcon(_ image: NSImage?, on view: NSImageView?) {
        view?.image = image
        view?.layer?.backgroundColor = NSColor.systemFill.cgColor
    }

    private func appCell(_ tableView: NSTableView) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("appCell")
        if let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = id
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        image.wantsLayer = true
        image.layer?.cornerRadius = 6
        image.layer?.cornerCurve = .circular
        image.layer?.masksToBounds = true
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.cell?.wraps = false
        // A narrow inspector truncates app names; hovering shows the whole one.
        text.allowsExpansionToolTips = true
        text.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = NSTextField(labelWithString: "")
        subtitle.tag = Self.appSubtitleTag
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.lineBreakMode = .byTruncatingMiddle   // bundle ids differ at both ends
        subtitle.allowsExpansionToolTips = true
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        [image, text, subtitle].forEach(cell.addSubview)
        cell.imageView = image
        cell.textField = text
        cell.backgroundStyle = .lowered
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 32),
            image.heightAnchor.constraint(equalToConstant: 32),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.bottomAnchor.constraint(equalTo: cell.centerYAnchor, constant: 0),
            subtitle.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            subtitle.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 1),
        ])
        return cell
    }

    private static let appSubtitleTag = 8

    /// A Legacy Store result: icon, name, "developer · iOS 2.2+ · 66 MB", and
    /// an Install button. Built fresh each time, like pendingCell — a page of
    /// results is small, and the button's tag has to track the row it was
    /// built for (every state change reloads the row, so tags never go stale).
    private func catalogCell(for app: CatalogApp, row: Int) -> NSTableCellView {
        if let bundleID = app.bundleID, uninstalling.contains(bundleID) {
            return progressCell(icon: catalogIcon(app), title: app.name,
                                subtitle: removalStatus(for: bundleID))
        }
        // In-flight states use the same row the installed list uses for its
        // own pending work — icon, status subtitle, trailing circular
        // progress — so the two modes can never drift apart visually.
        if let failed = pending.last(where: {
            $0.failed && !$0.dismissed && ($0.catalogIpaID == app.ipaID || ($0.bundleID != nil && $0.bundleID == app.bundleID))
        }) {
            return progressCell(icon: catalogIcon(app), title: app.name, subtitle: failed.status, job: failed)
        }
        let state = catalogState(of: app)
        if case .downloading(let fraction) = state {
            return progressCell(icon: catalogIcon(app), title: app.name,
                                subtitle: catalogJob(for: app)?.status ?? "Downloading…",
                                fraction: fraction, job: catalogJob(for: app))
        }
        if state == .installing {
            return progressCell(icon: catalogIcon(app), title: app.name,
                                subtitle: catalogJob(for: app)?.status ?? "Installing…", job: catalogJob(for: app))
        }
        let cell = NSTableCellView()
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 6
        image.layer?.cornerCurve = .circular
        image.layer?.masksToBounds = true
        image.translatesAutoresizingMaskIntoConstraints = false
        Self.setIcon(catalogIcon(app), on: image)

        let text = NSTextField(labelWithString: app.name)
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.cell?.wraps = false
        text.allowsExpansionToolTips = true
        text.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: app.subtitle)
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton(title: "Install", target: self,
                              action: #selector(catalogInstallClicked(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.tag = row
        button.translatesAutoresizingMaskIntoConstraints = false
        switch catalogState(of: app) {
        case .installable:
            break
        case .installed:
            button.title = "Open"
            button.isEnabled = emulator.canReachDevice && !busyWithDevice && apps.contains { $0.id == app.bundleID }
        case .unavailable:
            // The device can't take an install right now (booting, or gone) —
            // same gate as every other install entry point.
            button.isEnabled = false
        case .downloading, .installing:
            break   // returned above as a progressCell; not reachable here
        }

        [image, text, subtitle, button].forEach(cell.addSubview)
        cell.imageView = image
        cell.textField = text
        cell.toolTip = [app.bundleID, app.version.map { "v\($0)" }]
            .compactMap { $0 }.joined(separator: " — ")
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 32),
            image.heightAnchor.constraint(equalToConstant: 32),
            button.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 60),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -6),
            text.bottomAnchor.constraint(equalTo: cell.centerYAnchor, constant: 0),
            subtitle.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -6),
            subtitle.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 1),
        ])
        return cell
    }

    /// The catalog's icon for a result, if it has arrived.
    private func catalogIcon(_ app: CatalogApp) -> NSImage? {
        app.iconURL.flatMap { CatalogClient.iconMemo.object(forKey: $0.absoluteString as NSString) }
    }

    /// The best icon we have for a job that hasn't landed yet: the catalog's
    /// (already fetched for the search row), else a cached one for the same
    /// bundle id (reinstalls), else the generic placeholder.
    private func pendingIcon(_ job: InstallJob) -> NSImage? {
        if let url = job.catalogIconURL,
           let memo = CatalogClient.iconMemo.object(forKey: url.absoluteString as NSString) {
            return memo
        }
        return job.bundleID.flatMap { AppMetadataCache.shared.icon(for: $0) }
    }

    /// A row for work in flight — icon, title, status subtitle and a trailing
    /// circular progress indicator, determinate when a download knows its
    /// size. One style for installs, downloads, removals and catalog rows.
    /// Built fresh each time (such rows are few) so the indicator animates.
    private func progressCell(icon: NSImage?, title: String, subtitle subtitleText: String,
                              fraction: Double? = nil, job: InstallJob? = nil) -> NSTableCellView {
        let cell = NSTableCellView()
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 6
        image.layer?.cornerCurve = .circular
        image.layer?.masksToBounds = true
        image.translatesAutoresizingMaskIntoConstraints = false
        Self.setIcon(icon, on: image)
        image.layer?.opacity = NSApp.isActive ? 1 : 0.5
        let text = NSTextField(labelWithString: title)
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.cell?.wraps = false
        text.allowsExpansionToolTips = true
        text.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = NSTextField(labelWithString: subtitleText)
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.translatesAutoresizingMaskIntoConstraints = false
        if let fraction, fraction >= 0 {
            progress.isIndeterminate = false
            progress.minValue = 0
            progress.maxValue = 1
            progress.doubleValue = fraction
        } else {
            progress.startAnimation(nil)
        }
        let action = InlineActionButton(title: job?.failed == true ? "Retry" : job?.status == "Paused" ? "Resume" : "Cancel") { [weak self, weak job] in
            guard let job else { return }
            if job.failed { job.retry?() }
            else if AppInstaller.isPaused { self?.resumeInstallsClicked(nil) }
            else { job.cancel() }
        }
        action.isHidden = job == nil
        action.isEnabled = job?.failed == true || job?.isCancellable == true
        action.translatesAutoresizingMaskIntoConstraints = false
        progress.isHidden = job?.failed == true
        [image, text, subtitle, progress, action].forEach(cell.addSubview)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 32),
            image.heightAnchor.constraint(equalToConstant: 32),
            action.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            action.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            action.widthAnchor.constraint(equalToConstant: job == nil ? 0 : 54),
            progress.trailingAnchor.constraint(equalTo: action.leadingAnchor, constant: -4),
            progress.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 16),
            progress.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: progress.leadingAnchor, constant: -6),
            text.bottomAnchor.constraint(equalTo: cell.centerYAnchor, constant: 0),
            subtitle.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: progress.leadingAnchor, constant: -6),
            subtitle.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 1),
        ])
        return cell
    }
}
