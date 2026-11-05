import Cocoa
import FirmwareSchema
import HostRuntime
import HostServiceWire
import LightTouchCore
import SwiftUI
import UniformTypeIdentifiers

extension MainWindowController {
    /// Selects the launch device, and starts it when it is the only one set up.
    func selectLaunchDevice() {
        guard let entry = host.launchSelection.flatMap({ library.contains($0) ? $0 : nil }) ?? library.entries.first
        else {
            show(nil)
            return
        }
        library.select(entry)
        // With several devices, which to run is the user's call: launch only selects.
        guard library.entries.filter({ host.instance(for: $0) != nil }).count <= 1 else { return }
        // Nor after a run that quit unexpectedly while a device started (CrashGuard): its Start button is right there.
        guard !CrashGuard.skips(.deviceStart) else { return }
        if canPerform(.start, for: entry) { start(entry) }
    }

    /// A device finished preparing. The one on screen starts, as if the user had clicked Start; one in the
    /// background never takes over the window: a notification says it's ready (clicking it selects it).
    @objc func preparationDidPublish(_ notification: Notification) {
        guard let entry = host.catalog.entries.first(where: { $0.id == notification.object as? String }) else { return }
        guard entry.id == selectedEntry?.id else {
            Task { await CaptureNotifications.shared.notifyReady(name(entry), entryID: entry.id) }
            return
        }
        if canPerform(.start, for: entry) { start(entry) }
    }

    func library(_ library: DeviceLibraryViewController, didSelect entry: FirmwareCatalog.Entry?) {
        if let entry { host.lastSelection = entry }
        show(entry)
    }

    func libraryRowsDidChange(_ library: DeviceLibraryViewController) { show(selectedEntry) }

    func librarySessionsDidChange(_ library: DeviceLibraryViewController) {
        show(selectedEntry)
        followCarrierPanels()
        followTweaksPanels()
    }

    @objc func filesystemActivityDidChange() { show(selectedEntry) }

    func library(_ library: DeviceLibraryViewController, perform action: DeviceAction, for entry: FirmwareCatalog.Entry)
    {
        perform(action, for: entry)
    }

    func library(_ library: DeviceLibraryViewController, perform batch: DeviceBatch<FirmwareCatalog.Entry>) {
        perform(batch)
    }

    func library(
        _ library: DeviceLibraryViewController,
        canPerform action: DeviceAction,
        for entry: FirmwareCatalog.Entry
    ) -> Bool {
        canPerform(action, for: entry)
    }

    func library(_ library: DeviceLibraryViewController, importIPSWs urls: [URL], for entry: FirmwareCatalog.Entry?) {
        handOffIPSWs(urls, for: entry)
    }

    private func trackState() {
        if let stateTracking {
            stateTracking.rearm()
        } else {
            stateTracking = ObservationLoop(read: { [weak self] in self?.refreshForState() })
        }
    }

    /// Shows the entry's workspace when it has a session, else its placeholder.
    /// The detail pane's content; the console bar is dark only under the device's gradient.
    func showDetail(_ child: NSViewController) {
        detail.show(child)
        console.split.bar.overGradient = child is DeviceViewController
    }

    func show(_ entry: FirmwareCatalog.Entry?) {
        selectedEntry = entry
        if attachedSession !== session {
            // Recording captures the visible screen; it can't follow a switch.
            recording.stop()
            attachedSession?.workspace.deviceVC.screen.endLiveText()
            attachedSession = session
            attachWorkspace()
        }
        noInspector.managesApps = entry?.managesApps ?? false
        let count = library.selectedEntries.count
        multipleSelected.text = "\(count) Devices"
        if session == nil { showDetail(entry != nil ? placeholder : count > 1 ? multipleSelected : nothingSelected) }
        if let entry, session == nil {
            let instance = host.instance(for: entry)
            let edits = DeviceFilesystemEdits.shared
            let editing = instance.flatMap { edits.hasOpenEdit($0) ? $0 : nil }
            if let editing { edits.watch(editing, library: host.library) }
            placeholder.update(
                host.row(for: entry),
                canDownload: FirmwareJobs.shared.canDownload,
                activity: instance.flatMap { edits.activity[$0.id] },
                editing: editing.map(edits.isEditMounted)
            )
        }
        // The console's picker: the same logs as Device Logs, without the rotated
        // copies, the device's serial log first.
        let logs = diagnosticLogs.filter { $0.pathExtension == "log" }
        console.split.sources =
            logs.filter { $0.lastPathComponent == "serial.log" } + logs.filter { $0.lastPathComponent != "serial.log" }
        if let profile = session?.profile ?? entry?.profile, profile != currentProfile { profileDidChange(to: profile) }
        window?.title = entry.map { library.label(for: $0).title } ?? "Light Touch"
        trackState()
    }

    /// Puts the selected session's cached views in the window, or the placeholder.
    private func attachWorkspace() {
        deadOverlay?.removeFromSuperview()
        deadOverlay = nil
        guard let workspace = session?.workspace else {
            showDetail(placeholder)
            inspectorContainer.show(noInspector)
            MainMenuBuilder.resetAppsMenu()
            return
        }
        showDetail(workspace.deviceVC)
        inspectorContainer.show(workspace.inspectorVC)
        for status in [startupStatus, fileStatus, captureStatus] { workspace.deviceVC.addStatus(status) }
        refreshFileStatus()
        // The view restored its board's own zoom; the toolbar follows what it can still do after each layout.
        workspace.deviceVC.screen.onZoomLayout = { [weak self] in self?.syncZoomControls() }
        workspace.deviceVC.onFreeFormChange = { [weak self] in self?.updateSubtitle() }
        syncZoomControls()
        attachInspectorMenus()
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == .searchCatalog })
            as? NSSearchToolbarItem
        {
            workspace.inspectorVC.attachSearchField(to: item)
        }
        window?.makeFirstResponder(workspace.deviceVC.screen)
    }

    private func attachInspectorMenus() {
        if let appsMenu = NSApp.mainMenu?.item(withTitle: "Apps")?.submenu {
            appsMenu.delegate = inspectorVC
            appsMenu.autoenablesItems = false
        }
    }

    /// Menus, the Files window and the capture options name the board.
    private func profileDidChange(to profile: Board) {
        currentProfile = profile
        noInspector.shortName = profile.shortName
        MainMenuBuilder.install(profile: profile)
        attachInspectorMenus()
        if !hasFileTransfer {
            filesWindow?.close()
            filesWindow = nil
        }
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == .files }) {
            item.label = "\(profile.shortName) Files"
            item.paletteLabel = item.label
            item.toolTip = "Show \(profile.shortName) Files (⌘2)"
        }
        resize(to: profile)
    }

    /// Keeps the device area its own size, plus the sidebar, until the user
    /// sizes the window themselves. Anchored at the top-left, on screen.
    private func resize(to profile: Board) {
        guard sizedToDevice, let window, !window.styleMask.contains(.fullScreen) else { return }
        let size = Self.contentSize(for: profile)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let screen = window.screen ?? NSScreen.main { frame = window.constrainFrameRect(frame, to: screen) }
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    func windowDidEndLiveResize(_ notification: Notification) { sizedToDevice = false }
}
