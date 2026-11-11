import Cocoa
import FirmwareSchema
import HostRuntime
import HostServiceWire
import LightTouchCore
import SwiftUI
import UniformTypeIdentifiers

extension MainWindowController {
    /// Runtime conditions on top of what the row allows.
    func canPerform(_ action: DeviceAction, for entry: FirmwareCatalog.Entry) -> Bool {
        guard host.row(for: entry).allows(action, canDownload: FirmwareJobs.shared.canDownload) else { return false }
        let emulator = host.session(for: entry)?.emulator
        if let instance = host.instance(for: entry) {
            switch action {
            case .start:
                if DeviceFilesystemEdits.shared.blocksStart(instance) { return false }
            case .erase, .delete:
                if DeviceFilesystemEdits.shared.blocked(instance) { return false }
            case .openFilesystem, .commitFilesystem, .discardFilesystem, .recoverFilesystem, .jailbreak:
                return DeviceFilesystemEdits.shared.canPerform(action, instance: instance)
            default: break
            }
        }
        switch action {
        case .start: return emulator.map { $0.isDead || ($0.isPoweredOff && !$0.shuttingDown) } ?? true
        case .stop: return emulator?.canShutDown == true
        case .forceStop: return emulator?.canForceStop == true
        case .erase:
            // A copy holds its own device only (FilesConnection).
            let copying = host.instance(for: entry).map { FilesConnection.shared.isTransferring($0.id) } ?? false
            return emulator?.isErasing != true && !copying && !recording.isActive
        default: return true
        }
    }

    func perform(_ action: DeviceAction, for entry: FirmwareCatalog.Entry) {
        guard canPerform(action, for: entry) else { return }
        switch action {
        case .openFilesystem, .commitFilesystem, .discardFilesystem, .recoverFilesystem:
            DeviceFilesystemEdits.shared.perform(action, entry: entry, host: host)
        case .jailbreak: confirmJailbreak(entry)
        case .start: start(entry)
        // The same questions as Device ▸ Shut Down… and Force Stop…, from the sidebar and File menu too.
        case .stop: if let emulator = host.session(for: entry)?.emulator { confirmShutDown(emulator) }
        case .forceStop: if let emulator = host.session(for: entry)?.emulator { confirmForceStop(emulator) }
        case .downloadAndPrepare: FirmwareJobs.shared.downloadAndPrepare(entry)
        case .importIPSW: chooseIPSW(for: entry)
        case .cancel: FirmwareJobs.shared.cancel(entry)
        case .erase: erase(entry)
        case .showInFinder:
            // Every device has its Devices/<uuid> (an adopted one keeps its record, work and IPAs there).
            if let instance = host.instance(for: entry) {
                NSWorkspace.shared.activateFileViewerSelecting([instance.paths.directory])
            }
        case .delete: confirmDelete(entry)
        case .prepareAgain: confirmDelete(entry, thenPrepare: true)
        }
    }

    /// Several rows: Start starts each the way Start does one; the rest ask once for the lot, then do to each what the
    /// one-row command does after its question.
    func perform(_ batch: DeviceBatch<FirmwareCatalog.Entry>) {
        guard batch.isEnabled else { return }
        if batch.action == .start {
            for entry in batch.targets { start(entry, select: false) }
            return
        }
        guard let window, window.attachedSheet == nil else { return }
        batchAlert(batch).beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            // Asked again on the answer, as each one-row command is.
            for entry in batch.targets where canPerform(batch.action, for: entry) {
                switch batch.action {
                case .forceStop: host.session(for: entry).map { powerOff($0.emulator) }
                case .jailbreak: DeviceFilesystemEdits.shared.perform(.jailbreak, entry: entry, host: host)
                case .erase: eraseConfirmed(entry, window: window)
                default: break
                }
            }
        }
    }

    private func batchAlert(_ batch: DeviceBatch<FirmwareCatalog.Entry>) -> NSAlert {
        let names = ListFormatter.localizedString(byJoining: batch.targets.map(name))
        let count = batch.targets.count
        let alert = NSAlert()
        alert.alertStyle = batch.action == .erase ? .critical : .warning
        var info: String
        switch batch.action {
        case .forceStop:
            alert.messageText = "Force stop \(count == 1 ? name(batch.targets[0]) : "\(count) devices")?"
            info =
                (count == 1
                    ? "It stops at once, as if its battery were removed."
                    : "They stop at once, as if their batteries were removed.")
                + " Anything an app hasn’t saved is lost."
            alert.addButton(withTitle: "Force Stop")
        case .jailbreak:
            alert.messageText = "Jailbreak \(count == 1 ? name(batch.targets[0]) : "\(count) devices")?"
            let substrate = batch.targets.contains { (3...6).contains(Int($0.version.prefix { $0 != "." }) ?? 0) }
            info =
                "Adds Cydia\(substrate ? ", Substrate on iOS 4 to 6," : "") and afc2, which shows the whole file system in Files, to \(names). Erase All Content and Settings removes them."
            alert.addButton(withTitle: "Jailbreak")
        default:
            alert.messageText = "Erase \(count == 1 ? name(batch.targets[0]) : "\(count) devices")?"
            let installs = batch.targets.contains {
                host.instance(for: $0).map { AppInstaller.hasPendingWork(for: $0.id) } ?? false
            }
            info =
                "This permanently removes all apps, settings, and saved state from \(names) and returns them to how they were prepared."
                + (installs ? " Installs in progress are cancelled." : "")
            alert.addButton(withTitle: "Erase")
        }
        if !batch.skipped.isEmpty {
            info +=
                " " + ListFormatter.localizedString(byJoining: batch.skipped.map(name))
                + (batch.skipped.count == 1 ? " stays as it is." : " stay as they are.")
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = batch.action != .jailbreak
        return alert
    }

    func name(_ entry: FirmwareCatalog.Entry) -> String { library.displayName(for: entry) }

    /// Start: the file system view let go first (an edit open in Finder is saved or discarded, after asking).
    /// `select`: show the device (one row's Start; several rows keep their selection).
    func start(_ entry: FirmwareCatalog.Entry, select: Bool = true) {
        if select { library.select(entry) }
        guard let instance = host.instance(for: entry) else { return launch(entry) }
        let edits = DeviceFilesystemEdits.shared
        func release(commit: Bool?) {
            Task {
                do { try await edits.release(instance, entry: entry, host: host, commit: commit) } catch {
                    if let window { await NSAlert(error: error).beginSheetModal(for: window) }
                    return
                }
                if canPerform(.start, for: entry) { launch(entry) }
            }
        }
        guard edits.hasOpenEdit(instance), let window else { return release(commit: nil) }
        let alert = NSAlert()
        let shortName = entry.profile?.shortName ?? "device"
        alert.messageText = "\(name(entry))’s file system is open in Finder"
        alert.informativeText =
            edits.isEditMounted(instance)
            ? "Starting the \(shortName) unmounts its file system so the \(shortName) can use it. Copies in progress finish first, then your changes are saved."
            : "Starting the \(shortName) saves your changes first."
        alert.addButton(withTitle: "Save and Start")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: release(commit: true)
            case .alertThirdButtonReturn: release(commit: false)
            default: break
            }
        }
    }

    /// Show File System on a 1.x device stopped without shutting down (its FTL is mid-write): start it, shut it down
    /// from iOS, then open it, after asking.
    func offerShutDownFirst(_ entry: FirmwareCatalog.Entry) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "\(name(entry)) wasn’t shut down"
        alert.informativeText =
            "Its file system can be shown once it has been shut down. Light Touch can start it, shut it down, and then show it."
        alert.addButton(withTitle: "Shut Down First")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            start(entry)
            Task { [weak self] in
                // Up to the boot's own budget for iOS to come up, then Shut Down, then the file system.
                let deadline = Date().addingTimeInterval(entry.profile?.bootBudget ?? 240)
                while Date() < deadline {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, let emulator = self.host.session(for: entry)?.emulator else { continue }
                    if emulator.isDead || emulator.isPoweredOff { return }
                    guard emulator.isRunning, emulator.canShutDown else { continue }
                    self.shutDown(emulator) { [weak self] in self?.perform(.openFilesystem, for: entry) }
                    return
                }
            }
        }
    }

    private func launch(_ entry: FirmwareCatalog.Entry) {
        if let session = host.session(for: entry) {
            if session.emulator.isDead { host.restart(session) } else { session.emulator.powerOn() }
            return
        }
        host.start(entry)
    }

    @objc func toggleDeviceRunning(_ sender: Any?) {
        if let batch = library.commandBatch(.start) { return perform(batch) }
        guard let entry = selectedEntry else { return }
        perform([.running, .stopping].contains(host.row(for: entry).state) ? .stop : .start, for: entry)
    }
    @objc func downloadAndPrepare(_ sender: Any?) { selectedEntry.map { perform(.downloadAndPrepare, for: $0) } }
    /// The selected row's IPSW when it takes one, else any number of IPSWs and folders, matched by checksum.
    @objc func importIPSW(_ sender: Any?) {
        guard let entry = selectedEntry, canPerform(.importIPSW, for: entry) else { return chooseIPSWs() }
        perform(.importIPSW, for: entry)
    }
    @objc func cancelFirmwareJob(_ sender: Any?) { selectedEntry.map { perform(.cancel, for: $0) } }
    @objc func showDeviceInFinder(_ sender: Any?) { selectedEntry.map { perform(.showInFinder, for: $0) } }
    @objc func jailbreakDevice(_ sender: Any?) {
        if let batch = library.commandBatch(.jailbreak) { return perform(batch) }
        selectedEntry.map { perform(.jailbreak, for: $0) }
    }

    /// Jailbreak…: asked, then the stopped device's edit, its progress in the device area (DeviceFilesystemEdits).
    private func confirmJailbreak(_ entry: FirmwareCatalog.Entry) {
        guard let window, window.attachedSheet == nil else { return }
        JailbreakAlert.make(name: name(entry), version: entry.version).beginSheetModal(for: window) {
            [weak self] response in
            // Asked again on the answer: the device may have started while the question was up.
            guard response == .alertFirstButtonReturn, let self, canPerform(.jailbreak, for: entry) else { return }
            DeviceFilesystemEdits.shared.perform(.jailbreak, entry: entry, host: host)
        }
    }
    /// Delete Device… for a prepared device (asks, then leaves the sidebar), Remove Device for the rest; with several
    /// rows selected, one question for the lot (DeviceLibraryViewController.removeTargets).
    @objc func deleteDevice(_ sender: Any?) { library.removeTargets() }

    /// The toolbar's +, the Device menu and the empty sidebar: the catalog in a sheet.
    @objc func addDevice(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let catalog = host.catalog
        let downloaded = Set(
            catalog.entries.filter { $0.source.sha1.map { IPSWStore.shared.existing($0) != nil } ?? false }.map(\.id)
        )
        // Weak: the parent holds the sheet while it's up; the view's closures mustn't keep it after.
        weak var sheet: NSWindow?
        let view = AddDeviceView(
            catalog: catalog,
            added: Set(library.entries.map(\.id)),
            downloaded: downloaded,
            guestPackaged: GuestPackage.packaged(catalog.entries) {
                GuestPackage.bundledPack(arch: $0, filesRoot: Bundled.filesRoot, guestRoot: Bundled.guestRoot)
            },
            device: selectedEntry?.board,
            onAdd: { [weak self, weak window] ids in
                sheet.map { window?.endSheet($0) }
                self?.library.add(ids)
            },
            onCancel: { [weak window] in sheet.map { window?.endSheet($0) } }
        )
        let made = view.makeSheet()
        sheet = made
        window.beginSheet(made)
    }

    private func chooseIPSW(for entry: FirmwareCatalog.Entry) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipsw")].compactMap { $0 }
        panel.message = "Choose the IPSW for \(name(entry))."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.handOffIPSWs([url], for: entry)
        }
    }

    private func chooseIPSWs() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipsw")].compactMap { $0 }
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose IPSWs, or folders that contain them."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            FirmwareJobs.shared.importIPSWs(panel.urls)
        }
    }

    /// Files opened from Finder, the Dock or `open` (AppDelegate.application(_:open:)), sorted as a drop is:
    /// an IPSW to the library (the catalog names its entry), an .ipa to the device on screen.
    func open(_ urls: [URL]) {
        showWindow(nil)
        let ipsws = DroppedFiles.files(urls, .ipsw)
        if !ipsws.isEmpty { handOffIPSWs(ipsws, for: nil) }
        let ipas = DroppedFiles.files(urls, .ipa)
        guard !ipas.isEmpty else { return }
        guard let deviceVC else {
            let alert = NSAlert()
            alert.messageText = "No device is running"
            alert.informativeText = "Start a device, then open the app again."
            if let window { alert.beginSheetModal(for: window) { _ in } } else { alert.runModal() }
            return
        }
        ipas.forEach(deviceVC.installDropped)
    }

    /// One IPSW for a row is that row's; anything else is matched by checksum, folders searched.
    func handOffIPSWs(_ urls: [URL], for entry: FirmwareCatalog.Entry?) {
        if let entry, urls.count == 1, !DroppedFiles.isFolder(urls[0]) {
            FirmwareJobs.shared.importIPSW(urls[0], for: entry)
        } else {
            FirmwareJobs.shared.importIPSWs(urls)
        }
    }

    /// Delete, or with `thenPrepare` delete and prepare the entry again (a base from an older recipe): the same question.
    private func confirmDelete(_ entry: FirmwareCatalog.Entry, thenPrepare: Bool = false) {
        guard host.instance(for: entry) != nil else { return }
        askToDelete(name(entry), thenPrepare: thenPrepare) { [weak self] in
            // Asked again on the answer: the device may have started (from the menu bar) while the question was up.
            guard let self, canPerform(thenPrepare ? .prepareAgain : .delete, for: entry) else { return nil }
            return host.instance(for: entry)
        } deleted: { [weak self] in
            if thenPrepare {
                FirmwareJobs.shared.downloadAndPrepare(entry)
            } else {
                self?.library.removeFromList(entry)
            }
        }
    }

    /// Settings ▸ Storage lists every record, also one no row shows: its entry left the catalog, or a newer record
    /// for the same entry is the row's (host.instance(for:)). The row's own device goes the row's way; such a record
    /// has no session, so it goes whenever nothing else works on its storage.
    /// The sidebar's label for the record its row runs (Settings ▸ Storage names a device as its row does); nil for a
    /// record no row runs.
    func sidebarLabel(_ instance: DeviceInstance) -> SidebarList.Label? {
        guard let entry = host.catalog.entry(id: instance.firmware), library.list.contains(entry.id),
            host.instance(for: entry)?.id == instance.id
        else {
            return nil
        }
        return library.label(for: entry)
    }

    func canDeleteFromStorage(_ instance: DeviceInstance) -> Bool {
        if let entry = host.catalog.entry(id: instance.firmware), host.instance(for: entry)?.id == instance.id {
            return canPerform(.delete, for: entry)
        }
        return !host.storageWork.contains(instance.firmware) && !DeviceFilesystemEdits.shared.blocked(instance)
    }

    func deleteFromStorage(_ instance: DeviceInstance) {
        if let entry = host.catalog.entry(id: instance.firmware), host.instance(for: entry)?.id == instance.id {
            return perform(.delete, for: entry)
        }
        guard canDeleteFromStorage(instance) else { return }
        askToDelete("“\(instance.name)”") { [weak self] in
            self?.canDeleteFromStorage(instance) == true ? instance : nil
        } deleted: {
        }
    }

    /// The delete question; on Delete, `target` says what to delete now (nil: nothing, it changed meanwhile), which
    /// the host removes off the main actor while the row says Deleting.
    private func askToDelete(
        _ name: String,
        thenPrepare: Bool = false,
        target: @escaping () -> DeviceInstance?,
        deleted: @escaping () -> Void
    ) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = thenPrepare ? "Prepare \(name) again?" : "Delete \(name)?"
        alert.informativeText = "This permanently removes its apps, settings, and saved state."
        alert.addButton(withTitle: thenPrepare ? "Prepare Again" : "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let instance = target() else { return }
            let deletion = host.delete(instance)
            Task {
                do {
                    try await deletion.value
                    deleted()
                } catch { NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil) }
            }
        }
    }
}
