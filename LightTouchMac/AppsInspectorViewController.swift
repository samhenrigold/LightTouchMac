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

    fileprivate init(name: String) { self.name = name }

    /// False once the install has passed the last point cancellation can reach.
    /// instproxy_install runs on a detached thread that ignores cancellation, so
    /// after it starts the install WILL finish — the row used to say
    /// "Cancelling…" for the rest of it and then the app appeared anyway.
    fileprivate(set) var isCancellable = true

    var isCancelled: Bool { task?.isCancelled ?? false }
    func cancel() { task?.cancel() }
}

/// Shared install flow used by the inspector's Add button and by drag-and-drop
/// onto the device. Announces start, progress and finish so the list can follow
/// along, and owns the task so the row can cancel it.
@MainActor
enum AppInstaller {

    /// Is any install still outstanding — running OR waiting its turn?
    /// `EmulatorController.isInstalling` covers only the one executing, so the
    /// quit guard used to wave through a queue of .ipas and drop them silently.
    static var hasPendingWork: Bool { lastJob.map { !$0.isFinished } ?? false }

    /// The most recently started job, so the next one can queue behind it.
    /// Installs run strictly one at a time: the script pins iproxy to a single
    /// port (a second iproxy on it fails silently and every guest command just
    /// times out), and one lockdown session is all the guest reliably serves.
    private static var lastJob: InstallJob?

    @discardableResult
    static func start(_ ipa: URL, with emulator: EmulatorController,
                      presenting window: NSWindow?) -> InstallJob {
        // The row goes up on the filename immediately — reading the .ipa costs
        // a couple of unzips, and the point of the row is to appear the moment
        // the drop happens — then takes the app's real display name as soon as
        // the archive has been read.
        let job = InstallJob(name: ipa.deletingPathExtension().lastPathComponent)
        let previous = lastJob
        lastJob = job
        if let previous, !previous.isFinished { job.status = "Waiting…" }
        NotificationCenter.default.post(name: .ltmInstallStarted, object: job)
        job.task = Task {
            defer {
                job.isFinished = true
                job.finishedAt = Date()
                NotificationCenter.default.post(name: .ltmAppsChanged, object: nil)
            }
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
            // Queue behind the previous install, finished or not — awaiting a
            // done task returns immediately. Cancelling a queued job takes
            // effect the moment its turn comes.
            await previous?.task?.value
            guard !Task.isCancelled else { return }
            job.status = "Installing…"
            NotificationCenter.default.post(name: .ltmInstallProgress, object: job)
            do {
                let output = try await emulator.install(ipa) { line in
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
                // It is really installed now, so the cache may adopt it.
                await AppMetadataCache.shared.learn(from: ipa)
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
                presentError(error, in: window)
            }
        }
        return job
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
    private let placeholder = NSTextField(labelWithString: "")
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
        tableView.rowHeight = 40
        tableView.dataSource = self
        tableView.delegate = self
        // .string is the internal reorder drag; .fileURL is an .ipa dropped
        // from the Finder. The list of installed apps is the obvious place to
        // drop an app, and it silently ignored one — two inches to the left, on
        // the device screen, the same drop installed it.
        tableView.registerForDraggedTypes([.string, .fileURL])
        let menu = NSMenu()
        menu.delegate = self
        // menuNeedsUpdate decides what is enabled; automatic enabling would
        // overrule it and re-enable Cancel Install on a job already cancelling.
        menu.autoenablesItems = false
        tableView.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        configureAddRemove()

        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.font = .systemFont(ofSize: 11)
        placeholder.maximumNumberOfLines = 0
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isHidden = true

        banner.font = .systemFont(ofSize: 11, weight: .medium)
        banner.textColor = .secondaryLabelColor
        banner.alignment = .center
        banner.lineBreakMode = .byTruncatingTail
        // drawsBackground with an NSColor (not a captured layer cgColor) so the
        // tint re-resolves when the user switches Light/Dark.
        // A quiet inline notice, not a warning stripe. The flat yellow band
        // read as an error and clashed with the sidebar; a subtle fill plus a
        // hairline separator matches how AppKit sidebars carry status.
        banner.drawsBackground = true
        banner.backgroundColor = NSColor.quaternarySystemFill
        banner.lineBreakMode = .byTruncatingMiddle
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = true
        let bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        self.bannerHeight = bannerHeight

        [banner, scroll, placeholder].forEach(container.addSubview)
        var constraints = [
            banner.topAnchor.constraint(equalTo: container.topAnchor),
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bannerHeight,

            scroll.topAnchor.constraint(equalTo: banner.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            placeholder.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            placeholder.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            placeholder.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ]
        if Self.hasAccessoryBottomBar {
            // The window controller hangs the +/- controls off the split view
            // item as a real bottom bar, with the separator and material that
            // come with it; the list gets the whole pane.
            constraints.append(scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor))
        } else {
            container.addSubview(addRemove)
            constraints += [
                scroll.bottomAnchor.constraint(equalTo: addRemove.topAnchor, constant: -8),
                addRemove.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                addRemove.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            ]
        }
        NSLayoutConstraint.activate(constraints)

        view = container
    }

    /// macOS 26 gives an inspector a proper bottom bar. Both this and the
    /// window controller ask the same question, so they always agree on who
    /// owns the +/- controls.
    static var hasAccessoryBottomBar: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    @available(macOS 26.0, *)
    func makeBottomBar() -> NSSplitViewItemAccessoryViewController {
        configureAddRemove()
        let container = NSView()
        container.addSubview(addRemove)
        NSLayoutConstraint.activate([
            addRemove.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            addRemove.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            addRemove.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        let controller = NSSplitViewItemAccessoryViewController()
        controller.view = container
        return controller
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
            showPlaceholder("App management needs a usbmux session. Relaunch with app sync enabled.")
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
                if self.busyWithDevice {
                    // Reads are suppressed while our own device work runs, but
                    // "unknown" is not "reachable": leaving the last value
                    // frozen meant Install App…, the toolbar and drag-to-install
                    // all kept claiming a device that might have gone away ten
                    // minutes ago. The type already models this as nil.
                    self.emulator.deviceReachable = nil
                } else if await self.emulator.deviceReady() {
                    await self.loadOnce()
                } else {
                    self.emulator.deviceReachable = false
                    if !self.haveLoaded, self.pending.isEmpty {
                        self.showPlaceholder("Waiting for the device…")
                    } else if self.haveLoaded {
                        self.showStaleBanner()   // keep the list, mark it stale
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
        for row in pending.count..<numberOfRows(in: tableView) {
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView)?
                .imageView?.alphaValue = NSApp.isActive ? 1 : 0.5
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
            guard job.isFinished else { return false }
            if job.failed || job.isCancelled { return true }   // nothing will ever appear
            guard let id = job.bundleID, !apps.contains(where: { $0.id == id }) else { return true }
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

    @objc private func appsChanged() {
        prunePending()
        // Reload NOW, not from loadOnce: its failure path doesn't touch the
        // table, and an install that failed because the device died is exactly
        // the case where the next read fails too — leaving a phantom pending
        // row on screen while every data-source index has shifted up one (the
        // right-click-hits-the-wrong-app bug).
        tableView.reloadData()
        updateButtons()
        Task { await loadOnce() }
    }

    @objc private func installStarted(_ note: Notification) {
        guard let job = note.object as? InstallJob else { return }
        pending.append(job)
        showPlaceholder(nil)
        tableView.reloadData()
        updateButtons()
    }

    @objc private func installProgressed(_ note: Notification) {
        guard let job = note.object as? InstallJob,
              let row = pending.firstIndex(where: { $0 === job }) else { return }
        // A per-row reload does not re-ask for the row COUNT, and the count can
        // change here: as soon as a job learns its bundle id, `visibleApps`
        // hides the app it is replacing. On a reinstall that left a blank row
        // stranded at the bottom of the sidebar for the whole install, because
        // the poll that would have fixed it is suppressed while installing.
        if job.bundleID != nil, !apps.isEmpty { tableView.reloadData() }
        else { tableView.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
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
        guard !busyWithDevice else { return }
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
            tableView.reloadData()
            showPlaceholder(apps.isEmpty && pending.isEmpty ? "No third-party apps installed." : nil)
            updateButtons()
        } catch {
            emulator.deviceReachable = false
            // Prune here too. This path never touched `pending`, so a row whose
            // install failed because the device went away stayed on screen —
            // and the failing list read is exactly when that happens.
            prunePending()
            tableView.reloadData()
            // The reason rides along so a manual Refresh that fails says why,
            // instead of sitting on the same three words the boot wait shows.
            if !haveLoaded, pending.isEmpty {
                // A guest sitting on the Connect-to-iTunes screen still answers
                // lockdownd but refuses every service, so this path is all the
                // user ever saw of it: "Install service error (connect): code
                // -256", with nothing to act on. Ask why before blaming the
                // wait, and name the fix.
                if let activation = await emulator.activationState(),
                   !activation.hasSuffix("Activated") || activation == "Unactivated" {
                    showPlaceholder("""
                        The device needs to be erased.\n\nIts filesystem was damaged — usually by the emulator being force-quit before the guest could unmount — and it booted to the Connect to iTunes screen.\n\nChoose Device ▸ Erase All Content and Settings to start clean. Installed apps will be lost; the base image is untouched.
                        """)
                } else if case DeviceError.unavailable = error {
                    // Permanent and host-side: "Waiting" is the wrong frame and
                    // names no remedy.
                    showPlaceholder("LightTouchMac can't find libimobiledevice, so it can't "
                        + "manage apps on the device.\n\nReinstall LightTouchMac, or install "
                        + "it with: brew install libimobiledevice")
                } else {
                    showPlaceholder("Waiting for the device — \(error.localizedDescription)")
                }
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
        let watcher = GuestNotifications(clientSocket: session)
        notifications = watcher
        let emulator = self.emulator
        watcher.start(probe: { await emulator.deviceReady() }) {
            // Off the library's callback thread and onto ours.
            Task { @MainActor in
                NotificationCenter.default.post(name: .ltmAppsChanged, object: nil)
            }
        }
    }

    // GuestNotifications cancels its own loops in its deinit, which is what
    // this releasing it triggers; nothing else here may touch main-actor state.
    deinit { loadTask?.cancel() }

    private func showStaleBanner() {
        let when = lastLoaded.map {
            let f = RelativeDateTimeFormatter()
            return f.localizedString(for: $0, relativeTo: Date())
        } ?? "a while ago"
        banner.stringValue = usbUnavailable
            ? "USB unavailable — list from \(when)"
            : "Device not responding — list from \(when)"
        banner.isHidden = false
        bannerHeight?.constant = 24
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
    }

    /// True while any install is running or queued. Every other device
    /// operation waits it out — uninstall, reorder, the list poll — because a
    /// second lockdown session is what makes the install's own services start
    /// failing ("Invalid service").
    private var installing: Bool { pending.contains { !$0.isFinished } }

    /// Apps with an uninstall in flight. Without this the row stayed, the
    /// buttons stayed live, and nothing said anything for up to two minutes —
    /// so the obvious thing to do was press Uninstall again.
    private var uninstalling: Set<String> = []

    /// Any device operation of ours in flight.
    private var busyWithDevice: Bool { installing || !uninstalling.isEmpty }

    private func updateButtons() {
        // Disabled until the device has answered at least once: canManageApps
        // only means the usbmux session exists, not that the guest is up —
        // without haveLoaded these stayed clickable through the entire boot
        // wait shown by the "Waiting for the device…" placeholder.
        // isRunning as well as haveLoaded: during the ~40s boot the daemon is
        // alive (so canManageApps is true) and the list has never loaded, but
        // the buttons started out enabled because nothing had called this yet —
        // clicking + opened a picker for a device that could not install.
        let ready = emulator.canManageApps && emulator.isRunning && haveLoaded
        addRemove.setEnabled(ready && !installing, forSegment: 0)
        addRemove.setEnabled(ready && selectedApp != nil && !installing, forSegment: 1)
    }

    /// The selected row's app, or nil if nothing (or a pending row) is selected.
    private var selectedApp: InstalledApp? { app(at: tableView.selectedRow) }

    /// The installed apps actually shown. An app being replaced by a newer
    /// build is hidden while its pending row is up — otherwise a reinstall
    /// lists the same app twice, once installing and once as the old version,
    /// and the old row's Uninstall would remove what is being installed.
    private var visibleApps: [InstalledApp] {
        let replacing = Set(pending.compactMap { $0.isFinished ? nil : $0.bundleID })
        return replacing.isEmpty ? apps : apps.filter { !replacing.contains($0.id) }
    }

    private func app(at row: Int) -> InstalledApp? {
        let index = row - pending.count
        let shown = visibleApps
        return shown.indices.contains(index) ? shown[index] : nil
    }

    // MARK: - Actions

    @objc private func addOrRemove(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? add() : remove(selectedApp)
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa")].compactMap { $0 }
        // Several at once: AppInstaller already queues them (each job awaits the
        // previous), because the guest serves ~one lockdown session.
        panel.allowsMultipleSelection = true
        panel.message = "Choose one or more decrypted .ipa files to install."
        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard let self, response == .OK else { return }
            for url in panel.urls {
                AppInstaller.start(url, with: self.emulator, presenting: self.view.window)
            }
        }
    }

    private func remove(_ app: InstalledApp?) {
        guard let app else { return }
        let alert = NSAlert()
        alert.messageText = "Uninstall “\(displayName(app))”?"
        alert.informativeText = "This removes the app and its data from the device."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: view.window!) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.uninstalling.insert(app.id)
            self.tableView.reloadData()
            self.updateButtons()
            Task {
                defer {
                    self.uninstalling.remove(app.id)
                    self.tableView.reloadData()
                    self.updateButtons()
                    NotificationCenter.default.post(name: .ltmAppsChanged, object: nil)
                }
                do {
                    try await self.emulator.uninstall(app.id)
                    AppMetadataCache.shared.forget(app.id)
                    // Drop it locally rather than waiting for the device to stop
                    // listing it: the poll is up to 15s away and the row it
                    // leaves behind is one the user just removed.
                    self.apps.removeAll { $0.id == app.id }
                } catch {
                    AppInstaller.presentError(error, in: self.view.window)
                }
            }
        }
    }

    @objc private func uninstallClicked(_ sender: NSMenuItem) {
        remove(sender.representedObject as? InstalledApp)
    }

    @objc private func cancelInstallClicked(_ sender: NSMenuItem) {
        (sender.representedObject as? InstallJob)?.cancel()
    }

    @objc private func copyBundleIDClicked(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? InstalledApp else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(app.id, forType: .string)
    }

    @objc private func refreshClicked(_ sender: Any?) {
        Task { await loadOnce() }
    }
}

// MARK: - Context menu

extension AppsInspectorViewController: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        // `!isFinished`, not just the index: a finished job is DRAWN as an
        // ordinary app row, so classifying by index alone offered "Cancel
        // Install" (which by then does nothing) on a row showing an installed
        // app's own icon and name, and never offered Uninstall.
        if row >= 0, row < pending.count, !pending[row].isFinished {
            let job = pending[row]
            let item = menu.addItem(withTitle: "Cancel Install",
                                    action: #selector(cancelInstallClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = job
            item.isEnabled = !job.isCancelled && job.isCancellable
        } else if let app = app(at: row) {
            let uninstall = menu.addItem(withTitle: "Uninstall “\(displayName(app))”…",
                                         action: #selector(uninstallClicked(_:)), keyEquivalent: "")
            uninstall.target = self
            uninstall.representedObject = app
            uninstall.isEnabled = !busyWithDevice

            let copy = menu.addItem(withTitle: "Copy Bundle Identifier",
                                    action: #selector(copyBundleIDClicked(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = app
            menu.addItem(.separator())
        }
        // Always offered: a list that has gone stale or empty because the
        // device stopped answering has to be recoverable without relaunching.
        menu.addItem(withTitle: "Refresh", action: #selector(refreshClicked(_:)),
                     keyEquivalent: "").target = self
    }
}

// MARK: - Table data

extension AppsInspectorViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { pending.count + visibleApps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
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
            if job.isFinished, !job.isCancelled {
                let cell = appCell(tableView)
                cell.textField?.stringValue = job.name
                cell.imageView?.image = job.bundleID.flatMap {
                    AppMetadataCache.shared.icon(for: $0)
                } ?? Self.genericAppIcon
                cell.imageView?.alphaValue = NSApp.isActive ? 1 : 0.5
                return cell
            }
            let cell = pendingCell(tableView)
            cell.textField?.stringValue = job.name
            (cell.viewWithTag(Self.subtitleTag) as? NSTextField)?.stringValue =
                job.isCancelled ? "Cancelling…" : job.status
            return cell
        }
        guard let app = app(at: row) else { return nil }
        if uninstalling.contains(app.id) {
            let cell = pendingCell(tableView)
            cell.textField?.stringValue = displayName(app)
            (cell.viewWithTag(Self.subtitleTag) as? NSTextField)?.stringValue = "Removing…"
            return cell
        }
        let cell = appCell(tableView)
        cell.textField?.stringValue = displayName(app)
        cell.imageView?.image = AppMetadataCache.shared.icon(for: app.id) ?? Self.genericAppIcon
        // AppKit only dims a *selected* row when the window resigns key,
        // leaving every other icon at full strength — inconsistent with the
        // rest of the sidebar, which dims as a whole. Set explicitly instead
        // of relying on that per-row behavior; refreshed by the app-active
        // observers below whenever it changes with no reload otherwise due.
        cell.imageView?.alphaValue = NSApp.isActive ? 1 : 0.5
        cell.toolTip = "\(app.id)\(app.version.isEmpty ? "" : " — \(app.version)")"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // Every row selects, pending installs included — an unselectable row in a
    // source list reads as broken. What a pending row can't do (uninstall) is
    // decided where the buttons are enabled, not by refusing the selection.

    // MARK: Drag to reorder the home screen

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        // Without a known home-screen order there is nothing to reorder
        // *against* — the list is alphabetical and dragging would be a lie.
        // And not during an install: the SpringBoard write is one more
        // lockdown session the install can't afford.
        guard !homeOrder.isEmpty, !installing, let app = app(at: row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(app.id, forType: .string)
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
        guard operation == .above, row >= pending.count else { return [] }
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

    /// Generic app placeholder for apps we have no cached icon for (installed
    /// from within the guest rather than through our Add button).
    private static let genericAppIcon = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
    private static let subtitleTag = 7

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
        image.layer?.cornerCurve = .continuous
        image.layer?.masksToBounds = true
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        // A narrow inspector truncates app names; hovering shows the whole one.
        text.allowsExpansionToolTips = true
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 28),
            image.heightAnchor.constraint(equalToConstant: 28),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func pendingCell(_ tableView: NSTableView) -> NSTableCellView {
        // Built fresh each time (pending rows are few) so the spinner animates.
        let cell = NSTableCellView()
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)
        let text = NSTextField(labelWithString: "")
        text.textColor = .secondaryLabelColor
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = NSTextField(labelWithString: "")
        subtitle.tag = Self.subtitleTag
        subtitle.textColor = .tertiaryLabelColor
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(spinner)
        cell.addSubview(text)
        cell.addSubview(subtitle)
        cell.textField = text
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            spinner.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
            subtitle.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            subtitle.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 1),
        ])
        return cell
    }
}
