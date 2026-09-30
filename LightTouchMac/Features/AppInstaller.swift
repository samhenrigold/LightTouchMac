// The install and removal queue, per device: InstallJob (one row's state) and
// AppInstaller (starts .ipa, media and Legacy Store installs, queues removals,
// pauses a device's queue on a transport failure). The inspector shows the rows
// and the device menus ask it for busy state; the steps on the device are
// AppInstallPipeline's and MediaImport's, through EmulatorController.

import Cocoa

extension Notification.Name {
    /// Posted after an install/uninstall completes so any open list refreshes;
    /// object is the device's instance id (nil: every device).
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
    /// The device this job lands on (DeviceInstance.id): each inspector shows
    /// its own device's rows, and an erase drops only that device's jobs.
    let deviceID: UUID
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
    fileprivate(set) var retry: (() -> Void)?
    fileprivate(set) var dismissed = false
    func dismiss() {
        dismissed = true
        NotificationCenter.default.post(name: .ltmAppsChanged, object: deviceID)
    }

    fileprivate init(name: String, device: UUID) { self.name = name; deviceID = device }

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
/// along, and owns the task so the row can cancel it. Jobs, removals and the
/// ready queue are per device (the job's `deviceID`): one device's erase,
/// pause or long install never touches another's.
@MainActor
enum AppInstaller {

    /// Queued removals need the same quit/restart protection as installs.
    /// Any device's: the quit guard.
    static var hasPendingWork: Bool { !jobs.isEmpty || !removals.isEmpty }
    static func hasPendingWork(for device: UUID) -> Bool {
        jobs.contains { $0.deviceID == device } || removals.values.contains { $0.device == device }
    }
    private static var jobs: [InstallJob] = []
    private static var removals: [UUID: (device: UUID, task: Task<Void, Never>)] = [:]

    static func cancelPendingWork() {
        for job in jobs where job.isCancellable { job.cancel() }
        for removal in removals.values { removal.task.cancel() }
    }

    /// Every row this session put up, including failed ones still offering
    /// Retry (they have left `jobs`), so an erase can take them all down.
    private static let rows = NSHashTable<InstallJob>.weakObjects()

    /// The device is being erased or powered off: nothing queued or failed can
    /// land on it any more, and a Retry would target a wiped device. Cancel
    /// what can be cancelled and drop every install row of that device. An
    /// install already inside installation_proxy can't be stopped; its row goes
    /// too and the erase makes the outcome moot. Other devices' work continues.
    static func discard(for device: UUID) {
        for job in rows.allObjects where job.deviceID == device {
            job.task?.cancel()
            job.dismissed = true
        }
        for removal in removals.values where removal.device == device { removal.task.cancel() }
        if let queue = queues[device], queue.isPaused { queue.resume() }
        NotificationCenter.default.post(name: .ltmAppsChanged, object: device)
    }

    /// One ready queue per device; a queue outlives its jobs (it is tiny).
    private static var queues: [UUID: InstallationQueue] = [:]
    /// Internal so the queue checks (tests/offline) can hold a device's slot.
    static func queue(for device: UUID) -> InstallationQueue {
        if let queue = queues[device] { return queue }
        let queue = InstallationQueue()
        queues[device] = queue
        return queue
    }
    static func isUsingDevice(_ device: UUID) -> Bool { queues[device]?.isBusy ?? false }
    static func isPaused(_ device: UUID) -> Bool { queues[device]?.isPaused ?? false }

    static func resume(_ device: UUID) {
        queue(for: device).resume()
        for job in jobs where job.deviceID == device && job.status.hasPrefix("Paused") {
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
        let job = InstallJob(name: ipa.deletingPathExtension().lastPathComponent, device: emulator.instance.id)
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
        let job = InstallJob(name: source.deletingPathExtension().lastPathComponent, device: emulator.instance.id)
        job.retry = { [weak job, weak emulator, weak window] in
            guard let emulator else { return }
            job?.dismiss()
            startMedia(source, with: emulator, presenting: window)
        }
        job.status = "Preparing media…"
        jobs.append(job)
        rows.add(job)
        NotificationCenter.default.post(name: .ltmInstallStarted, object: job)
        let readyQueue = queue(for: emulator.instance.id)
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
                job.status = failureText(error, job)
            }
        }
        return job
    }

    /// A failed job's row text, with the whole error in app.log first: the row's words alone
    /// ("isn't in the correct format") left diagnostics with nothing to go on. A decoding error
    /// never reaches the row as Foundation's text.
    static func failureText(_ error: Error, _ job: InstallJob) -> String {
        logEvent("install: \(job.name) failed: \(String(reflecting: error)) [\((error as NSError).domain) \((error as NSError).code)]")
        return error is DecodingError ? CatalogError.unreadable.localizedDescription : error.localizedDescription
    }

    /// A Legacy Store copy: same pipeline, same queue, but the row exists —
    /// including in the installed list — from the first downloaded byte, so
    /// clearing the search can never lose sight of a transfer in flight.
    /// Downloads run independently. Completed files join the device queue, so
    /// a slow large download cannot block lightweight apps that are ready.
    @discardableResult
    static func startCatalog(_ app: CatalogApp, with emulator: EmulatorController,
                             presenting window: NSWindow?) -> InstallJob {
        let job = InstallJob(name: app.name, device: emulator.instance.id)
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
                raised = (try? emulator.installPipeline)?.installPlaceholder("add", bundleID: bundleID)
            }
            defer {
                if let bundleID = app.bundleID {
                    (try? emulator.installPipeline)?.installPlaceholder("cancel", bundleID: bundleID, after: raised)
                }
            }
            do {
                let ipa = try await CatalogClient.download(app, device: emulator.productType, deviceOS: emulator.iosVersion, arch: emulator.guestArch) { fraction in
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
                job.status = failureText(error, job)
            }
        }
        return job
    }

    private static func finish(_ job: InstallJob) {
        jobs.removeAll { $0 === job }
        job.isFinished = true
        job.finishedAt = Date()
        job.downloadProgress = nil
        NotificationCenter.default.post(name: .ltmAppsChanged, object: job.deviceID)
    }

    /// Queue when bytes are ready, not when the app was selected.
    private static func install(_ job: InstallJob, ipa: URL,
                                with emulator: EmulatorController,
                                presenting window: NSWindow?,
                                placeholderRaised: Bool = false) async {
        let readyQueue = queue(for: emulator.instance.id)
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
                    // is not (AppInstallPipeline checks cancellation between them).
                    if line.hasPrefix("Installing") { job.isCancellable = false }
                    NotificationCenter.default.post(name: .ltmInstallProgress, object: job)
                }
            }
            // Only when the app's own MinimumOSVersion is above the device's —
            // the version iPhone OS actually enforces. (Gating on the SDK
            // it was BUILT with fired on most of a 2009-era library and
            // taught people to click straight through this.)
            // It is really installed now, so the cache may adopt it — and the
            // library keeps the bytes, which is what makes the installed row
            // draggable out of the app as a file.
            await AppMetadataCache.shared.learn(from: ipa)
            if let id = job.bundleID {
                let info = await AppMetadataCache.info(of: ipa) ?? [:]
                await IPALibrary.adopt(ipa, .init(bundleID: id, name: job.name,
                                                  version: (info["CFBundleShortVersionString"] ?? info["CFBundleVersion"]) as? String,
                                                  minOS: info["MinimumOSVersion"] as? String, catalogIpaID: job.catalogIpaID),
                                       device: emulator.instance)
            }
            if output.contains("newer than the device's") {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "“\(job.name)” installed, but may not launch"
                let version = emulator.iosVersion
                alert.informativeText = "It needs a newer version of iOS than \(version). "
                    + "Look for a version built for iOS \(version.split(separator: ".").first ?? "3") or earlier."
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
            job.status = failureText(error, job)
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
        let id = UUID(), device = emulator.instance.id, readyQueue = queue(for: device)
        removals[id] = (device, Task {
            var acquired = false
            defer {
                if acquired { readyQueue.release() }
                removals[id] = nil
                didFinish()
                NotificationCenter.default.post(name: .ltmAppsChanged, object: device)
            }
            do {
                try await readyQueue.acquire()
                acquired = true
                for app in apps {
                    try Task.checkCancellation()
                    willRemove(app)
                    try await emulator.services.uninstall(app.id)
                    IPALibrary.forget(app.id, device: emulator.instance)
                    // The name and icon are app-wide: another device that still has the app keeps them.
                    if !IPALibrary.retained(app.id, by: DeviceLibrary.shared.instances) { AppMetadataCache.shared.forget(app.id) }
                    didRemove(app)
                }
            } catch is CancellationError {
                // Quit can cancel a waiting batch, never an active C call.
            } catch {
                guard !Task.isCancelled else { return }
                logEvent("uninstall failed: \(String(reflecting: error))")
                pauseIfNeeded(error, with: emulator)
                presentError(error, window)
            }
        })
    }

    /// Every queued mutation of one device shares this policy: an unavailable
    /// guest must not receive another write immediately after a failed removal.
    private static func pauseIfNeeded(_ error: Error, with emulator: EmulatorController,
                                      excluding failedJob: InstallJob? = nil) {
        guard let deviceError = error as? DeviceError, deviceError.shouldPauseInstallQueue else { return }
        let device = emulator.instance.id
        queue(for: device).pause()
        emulator.reportConnectionFailure(error, operation: "Transfer interrupted")
        for waiting in jobs where waiting.deviceID == device && waiting !== failedJob && waiting.downloadProgress == nil {
            waiting.status = "Paused"
            NotificationCenter.default.post(name: .ltmInstallProgress, object: waiting)
        }
    }

    /// A failed removal's (or a refused command's) alert. A variable so the
    /// queue checks, which compile this file whole, count alerts instead.
    static var presentError: (Error, NSWindow?) -> Void = { error, window in
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}
