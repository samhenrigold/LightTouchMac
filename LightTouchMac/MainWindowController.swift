// Created by Sam on 2026-08-05.
//
// The device window: device centred in the main column, an app-management
// inspector on the trailing edge, and a toolbar whose items mirror the menu bar
// (same selectors, same validation). Menu actions route here through the
// responder chain (the window controller is the window's next responder).

import Cocoa
import UniformTypeIdentifiers

private extension NSToolbarItem.Identifier {
    static let files = NSToolbarItem.Identifier("files")
    static let motion = NSToolbarItem.Identifier("motion")
    static let screenshot = NSToolbarItem.Identifier("screenshot")
    static let recording = NSToolbarItem.Identifier("recording")
    static let saveScreenshotAs = NSToolbarItem.Identifier("saveScreenshotAs")
    static let openScreenshot = NSToolbarItem.Identifier("openScreenshot")
    static let captureOptions = NSToolbarItem.Identifier("captureOptions")
    static let liveText = NSToolbarItem.Identifier("liveText")
    static let copyScreen = NSToolbarItem.Identifier("copyScreen")
    static let fingerDots = NSToolbarItem.Identifier("fingerDots")
    static let home         = NSToolbarItem.Identifier("home")
    static let lock         = NSToolbarItem.Identifier("lock")
    static let rotate       = NSToolbarItem.Identifier("rotate")
    static let zoom         = NSToolbarItem.Identifier("zoom")
    static let installApp   = NSToolbarItem.Identifier("installApp")
    static let searchCatalog = NSToolbarItem.Identifier("searchCatalog")
}

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate, DeviceLibraryDelegate {

    private let host: DeviceSessionHost
    /// The selected row's session, when it has one. Every device command,
    /// validation and toolbar item follows it.
    private(set) var session: DeviceSession?
    private var selectedEntry: FirmwareCatalog.Entry?
    private var emulator: EmulatorController? { session?.emulator }
    private var deviceVC: DeviceViewController? { session?.workspace.deviceVC }
    private var inspectorVC: AppsInspectorViewController? { session?.workspace.inspectorVC }
    /// The board the menus, Files window and capture options were made for.
    private var currentProfile: DeviceProfile
    private let library: DeviceLibraryViewController
    private let placeholder = DevicePlaceholderViewController()
    private let detail = ContainerViewController()
    private let inspectorContainer = ContainerViewController()
    private let noInspector = NotRunningViewController()
    private let sidebarItem: NSSplitViewItem
    private let inspectorItem: NSSplitViewItem
    private let zoomControl = NSSegmentedControl()
    private(set) var zoom: ZoomMode = .fit
    private var deadOverlay: NSView?
    private var filesWindow: DeviceFilesWindowController?
    private weak var proxySettingsEditor: ProxySettingsView?
    private var filesVC: DeviceFilesViewController? { filesWindow?.browser }
    private var screenshotBusy = false
    private var modifierMonitor: Any?
    private var captureKeyMonitor: Any?
    private var consumedCaptureSpace = false
    private var copyConfirmation: Task<Void, Never>?
    private var copiedScreenshot = false
    private let capturePreferences = CapturePreferences.shared
    private var captureOptionsWindow: NSWindowController?
    private var canTakeScreenshot: Bool {
        guard let emulator else { return false }
        return (emulator.isRunning || emulator.isPaused) && !emulator.isSleeping && !screenshotBusy
    }
    private var canStartRecording: Bool {
        guard let emulator else { return false }
        return emulator.isRunning && !emulator.isSleeping && !screenshotBusy
    }
    private var canToggleRecording: Bool {
        recording.phase != .saving && (recording.canStop || recording.needsRecovery || canStartRecording)
    }
    private let fileStatus = CaptureStatusView()
    private var captureMode: Int { UserDefaults.standard.integer(forKey: "captureMode") == 1 ? 1 : 0 }
    var hasFileTransfer: Bool { filesVC?.hasTransfer == true }
    func cancelFileTransfer() { filesVC?.cancelTransfer() }

    /// Today's device area, before the sidebar: 720×640 for the iPod and
    /// 1100×760 for the iPad (device plus inspector).
    private static let sidebarWidth: CGFloat = 220
    private static func contentSize(for profile: DeviceProfile) -> NSSize {
        let device = profile == .iPad1 ? NSSize(width: 1100, height: 760) : NSSize(width: 720, height: 640)
        return NSSize(width: device.width + sidebarWidth, height: device.height)
    }
    /// Cleared once the user resizes; until then switching devices resizes to fit.
    private var sizedToDevice = true

    init(host: DeviceSessionHost, profile: DeviceProfile) {
        self.host = host
        currentProfile = profile
        library = DeviceLibraryViewController(host: host)

        let split = NSSplitViewController()
        sidebarItem = NSSplitViewItem(sidebarWithViewController: library)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 320
        split.addSplitViewItem(sidebarItem)

        let deviceItem = NSSplitViewItem(viewController: detail)
        deviceItem.minimumThickness = 320
        split.addSplitViewItem(deviceItem)
        
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorContainer)
        // The widths the sidebar guidelines ask for: enough for an app name at a
        // readable size, not so much that it competes with the device.
        inspectorItem.minimumThickness = 280
        inspectorItem.maximumThickness = 400

        split.addSplitViewItem(inspectorItem)
        
        let window = NSWindow(contentViewController: split)
        window.title = profile.displayName
        // .fullSizeContentView is what makes the inspector run the FULL HEIGHT
        // of the window rather than starting below the toolbar (WWDC23 "inspectors
        // use the full height of the window when the full size content view mask
        // is set"). Without it the tracking separator splits the toolbar but the
        // inspector's material still stops at it, which is the giveaway that the
        // pane is sitting under the titlebar instead of behind it.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(Self.contentSize(for: profile))
        window.contentMinSize = NSSize(width: 360, height: 380)
        WindowRestorationPolicy.configure(window)
        window.center()
        super.init(window: window)
        library.delegate = self
        placeholder.onAction = { [weak self] action in
            guard let self, let entry = selectedEntry else { return }
            perform(action, for: entry)
        }
        placeholder.onShowLog = { [weak self] in self?.showDeviceLogs(nil) }
        placeholder.onDropIPSW = { [weak self] url in self?.handOffIPSW(url, for: self?.selectedEntry) }
        detail.show(placeholder)
        inspectorContainer.show(noInspector)
        
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        migrateCaptureToolbar(toolbar)
        migrateSidebarToolbar(toolbar)
        // Out and in. Momentary, because both are commands rather than states
        // to sit in — which state you are in is the menu's job, where the
        // checkmarks live.
        zoomControl.segmentCount = 2
        zoomControl.trackingMode = .momentary
        zoomControl.segmentStyle = .separated
        let symbols = [("minus.magnifyingglass", "Zoom Out"),
                       ("plus.magnifyingglass", "Zoom In")]
        for (index, (symbol, label)) in symbols.enumerated() {
            zoomControl.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: label),
                                 forSegment: index)
            zoomControl.setToolTip(label + (index == 0 ? " (⌘−)" : " (⌘+)"), forSegment: index)
        }
        zoomControl.target = self
        zoomControl.action = #selector(zoomSegmentClicked(_:))
        zoomControl.sizeToFit()
        syncZoomControls()

        window.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(sessionDidChange(_:)),
                                               name: DeviceSession.didChangeNotification, object: nil)
        installCaptureStatus()
        installFileStatus()
        installCaptureKeyboardShortcuts()
        installCaptureNotifications()
        recoverUnfinishedRecordings()
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.syncRotationControls(optionPressed: event.modifierFlags.contains(.option))
            return event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refreshRotationModifiers), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(stopHiddenRecording), name: NSApplication.didHideNotification, object: nil)
        recording.onChange = { [weak self] in self?.refreshRecording() }
        recording.onBeganRecording = { CaptureSound.recordingStarted.play() }
        recording.onStoppedRecording = {
            CaptureSound.recordingStopped.play()
            CaptureNotifications.shared.cancelReminder()
        }
        recording.chooseSaveDestination = { [weak self] _ in
            guard let self, let window = self.window else { return nil }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.quickTimeMovie]
            panel.directoryURL = self.captureFolder
            panel.nameFieldStringValue = self.captureName("Recording") + ".mov"
            return await panel.beginSheetModal(for: window) == .OK ? panel.url : nil
        }
        recording.onCompleted = { [weak self] result in
            guard let self else { return }
            CaptureNotifications.shared.cancelReminder()
            switch result {
            case let .saved(url):
                if capturePreferences.openFinderAfterCapture { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            case let .recovery(url):
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .discarded, .failed: break
            }
        }
        recording.onFinished = { [weak self] success in
            guard let self else { return }
            if success {
                if quitAfterRecording { AppDelegate.requestTermination() }
                else if closeAfterRecording { self.window?.performClose(nil) }
            } else if recording.phase == .idle, let failure = recording.failure, let window = self.window {
                NSAlert(error: failure).beginSheetModal(for: window)
            }
            quitAfterRecording = false
            closeAfterRecording = false
        }
        refreshForState()
    }

    private let recording = ScreenRecordingSession()
    private let captureStatus = CaptureStatusView()
    private let startupStatus = CaptureStatusView()
    private var startupTask: Task<Void, Never>?
    private var startupBegan = Date()
    private var wasStarting = false
    private var quitAfterRecording = false
    private var closeAfterRecording = false

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        if let captureKeyMonitor { NSEvent.removeMonitor(captureKeyMonitor) }
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        window?.center()
        apply(Self.savedZoom())   // restore the zoom the user left it at
    }

    // MARK: - Library and selection

    /// Selects the launch device and starts it, as the single-device app did.
    func selectLaunchDevice() {
        guard let entry = host.launchSelection else { return }
        library.select(entry)
        if canPerform(.start, for: entry) { start(entry) }
    }

    func library(_ library: DeviceLibraryViewController, didSelect entry: FirmwareCatalog.Entry?) {
        if let entry { host.lastSelection = entry }
        show(entry)
    }

    func libraryRowsDidChange(_ library: DeviceLibraryViewController) { show(selectedEntry) }

    func library(_ library: DeviceLibraryViewController, perform action: DeviceAction, for entry: FirmwareCatalog.Entry) {
        perform(action, for: entry)
    }

    func library(_ library: DeviceLibraryViewController, canPerform action: DeviceAction, for entry: FirmwareCatalog.Entry) -> Bool {
        canPerform(action, for: entry)
    }

    func library(_ library: DeviceLibraryViewController, importIPSW url: URL, for entry: FirmwareCatalog.Entry?) {
        handOffIPSW(url, for: entry)
    }

    @objc private func sessionDidChange(_ notification: Notification) {
        guard notification.object as? DeviceSession === session else { return }
        refreshForState()
    }

    /// Shows the entry's workspace when it has a session, else its placeholder.
    private func show(_ entry: FirmwareCatalog.Entry?) {
        selectedEntry = entry
        let next = entry.flatMap(host.session(for:))
        if next !== session {
            // Recording captures the visible screen; it can't follow a switch.
            recording.stop()
            deviceVC?.screen.endLiveText()
            session = next
            attachWorkspace()
        }
        if let entry, session == nil { placeholder.update(host.row(for: entry), canDownload: FirmwareJobs.shared.canDownload) }
        if let profile = session?.profile ?? entry?.profile, profile != currentProfile { profileDidChange(to: profile) }
        window?.title = session?.instance.name
            ?? entry.map { host.instance(for: $0)?.name ?? $0.profile?.displayName ?? $0.productType } ?? "Light Touch"
        refreshForState()
    }

    /// Puts the selected session's cached views in the window, or the placeholder.
    private func attachWorkspace() {
        deadOverlay?.removeFromSuperview()
        deadOverlay = nil
        guard let workspace = session?.workspace else {
            detail.show(placeholder)
            inspectorContainer.show(noInspector)
            NSApp.mainMenu?.item(withTitle: "Apps")?.submenu?.delegate = nil
            return
        }
        detail.show(workspace.deviceVC)
        inspectorContainer.show(workspace.inspectorVC)
        for status in [startupStatus, fileStatus, captureStatus] { workspace.deviceVC.addStatus(status) }
        workspace.deviceVC.screen.onPhysicalSizeUnavailable = { [weak self] in self?.apply(.fit) }
        apply(zoom)
        attachInspectorMenus()
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == .searchCatalog }) as? NSSearchToolbarItem {
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
    private func profileDidChange(to profile: DeviceProfile) {
        currentProfile = profile
        MainMenuBuilder.install(profile: profile)
        attachInspectorMenus()
        if !hasFileTransfer { filesWindow?.close(); filesWindow = nil }
        if captureOptionsWindow?.window?.isVisible != true { captureOptionsWindow = nil }
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == .files }) {
            item.label = "\(profile.shortName) Files"
            item.paletteLabel = item.label
            item.toolTip = "Show \(profile.shortName) Files (⌘2)"
        }
        resize(to: profile)
    }

    /// Keeps the device area its own size, plus the sidebar, until the user
    /// sizes the window themselves. Anchored at the top-left, on screen.
    private func resize(to profile: DeviceProfile) {
        guard sizedToDevice, let window, !window.styleMask.contains(.fullScreen) else { return }
        let size = Self.contentSize(for: profile)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let screen = window.screen ?? NSScreen.main { frame = window.constrainFrameRect(frame, to: screen) }
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    func windowDidEndLiveResize(_ notification: Notification) { sizedToDevice = false }

    // MARK: - Device commands (sidebar, Device menu, placeholder)

    /// Runtime conditions on top of what the row allows.
    private func canPerform(_ action: DeviceAction, for entry: FirmwareCatalog.Entry) -> Bool {
        guard host.row(for: entry).allows(action, canDownload: FirmwareJobs.shared.canDownload) else { return false }
        let emulator = host.session(for: entry)?.emulator
        switch action {
        case .start: return emulator.map { $0.isDead || ($0.isPoweredOff && !$0.shuttingDown) } ?? true
        case .stop: return emulator?.isRunning == true
        case .erase: return emulator?.isErasing != true && !hasFileTransfer && !recording.isActive
        default: return true
        }
    }

    private func perform(_ action: DeviceAction, for entry: FirmwareCatalog.Entry) {
        guard canPerform(action, for: entry) else { return }
        switch action {
        case .start: start(entry)
        case .stop: if let emulator = host.session(for: entry)?.emulator { powerOff(emulator) }
        case .downloadAndPrepare: FirmwareJobs.shared.downloadAndPrepare(entry)
        case .importIPSW: chooseIPSW(for: entry)
        case .cancel: FirmwareJobs.shared.cancel(entry)
        case .erase: erase(entry)
        case .showInFinder:
            if let instance = host.instance(for: entry) { NSWorkspace.shared.activateFileViewerSelecting([instance.paths.directory]) }
        case .delete: confirmDelete(entry)
        }
    }

    private func name(_ entry: FirmwareCatalog.Entry) -> String {
        "\(entry.profile?.displayName ?? entry.productType) iOS \(entry.version)"
    }

    private func start(_ entry: FirmwareCatalog.Entry) {
        library.select(entry)
        if let session = host.session(for: entry) {
            if session.emulator.isDead { host.restart(session) } else { session.emulator.powerOn() }
            return
        }
        host.start(entry)
    }

    @objc func toggleDeviceRunning(_ sender: Any?) {
        guard let entry = selectedEntry else { return }
        perform(host.row(for: entry).state == .running ? .stop : .start, for: entry)
    }
    @objc func downloadAndPrepare(_ sender: Any?) { selectedEntry.map { perform(.downloadAndPrepare, for: $0) } }
    @objc func importIPSW(_ sender: Any?) { selectedEntry.map { perform(.importIPSW, for: $0) } }
    @objc func cancelFirmwareJob(_ sender: Any?) { selectedEntry.map { perform(.cancel, for: $0) } }
    @objc func showDeviceInFinder(_ sender: Any?) { selectedEntry.map { perform(.showInFinder, for: $0) } }
    @objc func deleteDevice(_ sender: Any?) { selectedEntry.map { perform(.delete, for: $0) } }

    private func chooseIPSW(for entry: FirmwareCatalog.Entry) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipsw")].compactMap { $0 }
        panel.message = "Choose the IPSW for \(name(entry))."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.handOffIPSW(url, for: entry)
        }
    }

    private func handOffIPSW(_ url: URL, for entry: FirmwareCatalog.Entry?) {
        FirmwareJobs.shared.importIPSW(url, for: entry)
    }

    private func confirmDelete(_ entry: FirmwareCatalog.Entry) {
        guard let window, let instance = host.instance(for: entry) else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete \(name(entry))?"
        alert.informativeText = "This permanently removes its apps, settings, and saved state. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try host.delete(instance) }
            catch { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    // MARK: - Health / status surfacing

    private func refreshForState() {
        proxySettingsEditor?.updateStatus(emulator?.webProxyStatus ?? .waiting)
        if let filesVC {
            let socket = emulator.flatMap { $0.canReachDevice ? $0.usbmuxSession : nil }
            if filesVC.services?.clientSocket != socket {
                filesVC.services = socket.map { DeviceServices(clientSocket: $0) }
                filesVC.reload()
            }
        }
        updateDeviceNotice()
        updateStartupStatus()
        refreshLockItem()
        window?.toolbar?.validateVisibleItems()
        validateCaptureToolbar()
        updateDeadOverlay()
        guard let emulator, let deviceVC else {
            window?.subtitle = selectedEntry.map { "iOS \($0.version)" } ?? ""
            return
        }
        // The window subtitle is where AppKit puts secondary window state, and
        // it styles and truncates itself to match the title. A custom titlebar
        // accessory was carrying this before — more code, its own constraints,
        // and it competed with the toolbar for space.
        window?.subtitle = emulator.isRunning && !emulator.shuttingDown && !emulator.isSleeping
            ? (emulator.foregroundAppName ?? emulator.statusLine) : emulator.statusLine
        if emulator.isPoweredOff || emulator.isDead { deviceVC.screen.endLiveText() }
        deviceVC.screen.updatePowerPresentation()
        if emulator.isDead || emulator.isPoweredOff { recording.stop() }
    }

    private func refreshLockItem() {
        guard let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == .lock }) else { return }
        let poweredOff = emulator?.isPoweredOff ?? false
        item.label = poweredOff ? "Power On" : emulator?.isSleeping == true ? "Wake" : "Lock"
        item.image = NSImage(systemSymbolName: poweredOff ? "power" : "lock", accessibilityDescription: item.label)
        item.toolTip = item.label + " (⌘L)"
    }

    private func updateStartupStatus() {
        defer { deviceVC?.updateStatusVisibility() }
        guard let emulator, emulator.isErasing || emulator.state == .booting || emulator.preparingMedia else {
            wasStarting = false
            startupTask?.cancel()
            startupTask = nil
            startupStatus.isHidden = true
            return
        }
        if !wasStarting { startupBegan = Date(); wasStarting = true }
        let elapsed = Int(Date().timeIntervalSince(startupBegan))
        startupStatus.update(title: emulator.isErasing ? "Erasing \(emulator.profile.shortName)…" : emulator.preparationStatus,
                             detail: elapsed >= 90 ? "Check Device Logs." : "\(elapsed)s",
                             busy: true, primary: elapsed >= 90 ? "Device Logs" : nil)
        if startupTask == nil {
            startupTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self else { return }
                    updateStartupStatus()
                }
            }
        }
    }

    private var noticeAccessory: DeviceNoticeViewController?
    private func updateDeviceNotice() {
        guard let window else { return }
        guard let emulator, let message = emulator.deviceNotice else {
            if let accessory = noticeAccessory,
               let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            noticeAccessory = nil
            return
        }
        if noticeAccessory == nil {
            let accessory = DeviceNoticeViewController()
            accessory.onShowLogs = { [weak self] in self?.showDeviceLogs(nil) }
            accessory.onDismiss = { [weak self] in self?.emulator?.dismissDeviceNotice() }
            accessory.onAction = { [weak self] in self?.eraseDevice(nil) }
            window.addTitlebarAccessoryViewController(accessory)
            noticeAccessory = accessory
        }
        noticeAccessory?.update(message, canDismiss: !emulator.storageFailed,
                                action: emulator.deviceNoticeOffersErase ? "Erase…" : nil)
    }

    /// When the emulator dies (QEMU can't re-init), cover the device with an
    /// unmistakable overlay — the frozen last frame otherwise looks live.
    private func updateDeadOverlay() {
        guard let emulator, let deviceVC, emulator.isDead, !emulator.isErasing else {
            deadOverlay?.removeFromSuperview()
            deadOverlay = nil
            return
        }
        // Over the device pane only, centred where the device is laid out
        // (its safe area), not on the whole window with the inspector.
        guard deadOverlay == nil else { return }
        let content = deviceVC.view
        let overlay = NSView()
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        overlay.translatesAutoresizingMaskIntoConstraints = false

        // A refused boot says why and offers the remedy; anything else restarts
        // the device in a fresh helper (the app and other devices keep running).
        let refused = emulator.baseImageMismatch
        let label = NSTextField(wrappingLabelWithString: refused
            ? "This \(emulator.profile.shortName)'s data was made with an older system image. Erase it to start fresh."
            : emulator.deathReason ?? "The emulator stopped.")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.preferredMaxLayoutWidth = 280
        let button = refused
            ? NSButton(title: "Erase…", target: self, action: #selector(eraseDevice(_:)))
            : NSButton(title: "Restart", target: self, action: #selector(restartDevice(_:)))
        button.bezelStyle = .rounded
        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(stack)
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: content.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: content.safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.safeAreaLayoutGuide.centerYAnchor),
        ])
        deadOverlay = overlay
    }

    /// A fresh helper for the dead device (DeviceSessionHost.restart).
    @objc private func restartDevice(_ sender: Any?) {
        if let session { host.restart(session) }
    }
    
    /// Search Apps focuses the inspector search field in either mode.
    @objc func findCatalog(_ sender: Any?) {
        if let toolbar = window?.toolbar {
            toolbar.isVisible = true
            if !toolbar.items.contains(where: { $0.itemIdentifier == .searchCatalog }) {
                let index = toolbar.items.firstIndex { $0.itemIdentifier == .inspectorTrackingSeparator } ?? toolbar.items.count
                toolbar.insertItem(withItemIdentifier: .searchCatalog, at: min(index + 1, toolbar.items.count))
            }
        }
        inspectorVC?.focusSearch()
    }

    /// NSTextView handles Find first in Help and logs. In the device window,
    /// the searchable content is the app inspector.
    @objc func performFindPanelAction(_ sender: Any?) { findCatalog(sender) }

    // MARK: - Toolbar

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .screenshot:
            return button(id, "Save Screenshot", "square.and.arrow.down", #selector(saveScreenshot(_:)), "Save Screenshot (⌘S)")
        case .recording:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = RecordingToolbarButton(target: self, action: #selector(toggleRecording(_:)))
            item.target = self
            item.action = #selector(toggleRecording(_:))
            item.label = "Record"
            item.paletteLabel = "Record"
            item.visibilityPriority = .high
            item.isEnabled = validateToolbarItem(item)
            return item
        case .saveScreenshotAs:
            return button(id, "Save Screenshot As…", "square.and.arrow.down.on.square", #selector(saveScreenshotAs(_:)), "Save Screenshot As… (⇧⌘S)")
        case .openScreenshot:
            return button(id, "Open Screenshot", "arrow.up.forward.app", #selector(openScreenshot(_:)), "Open Screenshot (⌘O)")
        case .captureOptions:
            return button(id, "Capture Options", "slider.horizontal.3", #selector(showCaptureOptions(_:)), "Capture Options")
        case .liveText:
            return button(id, "Select Text on Screen", "text.viewfinder", #selector(showLiveText(_:)), "Select text on the device screen")
        case .copyScreen:
            return button(id, "Copy Screenshot", "document.on.document", #selector(copyScreen(_:)), "Copy Screenshot (⌘C)")
        case .fingerDots:
            return button(id, "Show Finger Dots", "hand.draw", #selector(toggleTouchOverlay(_:)), "Show finger dots in the device screen and captures")
        case .motion:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Motion"
            item.paletteLabel = "Motion Controls"
            item.image = NSImage(systemSymbolName: "move.3d", accessibilityDescription: "Motion Controls")
            item.toolTip = "Motion Controls"
            item.showsIndicator = true
            item.isBordered = true
            item.menu = MainMenuBuilder.motionMenu(target: self)
            return item
        case .files:
            return button(id, "\(currentProfile.shortName) Files", "folder", #selector(toggleFiles(_:)), "Show \(currentProfile.shortName) Files (⌘2)")
        case .home:
            return button(id, "Home Screen", "square.grid.3x3.fill", #selector(deviceHome(_:)), "Home Screen (⇧⌘H)")
        case .lock:
            return button(id, "Lock", "lock", #selector(deviceLock(_:)), "Lock (⌘L)")
        case .rotate:
            let action = RotationControlAction(rotationDegrees: emulator?.rotationDegrees ?? 0, optionPressed: NSEvent.modifierFlags.contains(.option))
            return button(id, action.title, action.symbol, #selector(deviceRotate(_:)), action.help)
        case .installApp:
            return button(id, "Install App", "square.and.arrow.down", #selector(installApp(_:)), "Install a decrypted .ipa")
        case .searchCatalog:
            // The inspector owns the field (its text drives the catalog/installed
            // mode switch); the toolbar is just where it lives — the standard
            // Mac home for search, riding above the inspector pane thanks to
            // the tracking separator.
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.label = "Search Apps"
            item.paletteLabel = "Search Apps"
            item.toolTip = "Search Installed Apps or Store (⌥⌘F)"
            if flag { inspectorVC?.attachSearchField(to: item) }
            return item
        case .zoom:
            let item = NSToolbarItem(itemIdentifier: .zoom)
            item.label = "Zoom"
            item.paletteLabel = "Zoom"
            item.toolTip = "How large the device is drawn"
            item.view = zoomControl
            return item
        case .inspectorTrackingSeparator:
            // Must be supplied explicitly with the split view and the divider
            // it tracks. Listing the identifier alone got it silently dropped,
            // so the toolbar never split at the divider — which is why the
            // inspector's material stopped at the toolbar instead of running
            // top to bottom, and the toggle floated over the device pane
            // instead of sitting above the inspector (compare Xcode).
            guard let split = contentSplitViewController else { return nil }
            return NSTrackingSeparatorToolbarItem(identifier: id,
                                                  splitView: split.splitView,
                                                  dividerIndex: 1)
        case .sidebarTrackingSeparator:
            // The same, for the divider between the sidebar and the device.
            guard let split = contentSplitViewController else { return nil }
            return NSTrackingSeparatorToolbarItem(identifier: id,
                                                  splitView: split.splitView,
                                                  dividerIndex: 0)
        default:
            return nil
        }
    }

    private var contentSplitViewController: NSSplitViewController? {
        window?.contentViewController as? NSSplitViewController
    }
    
    private func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String,
                        _ action: Selector, _ help: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = help
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.isBordered = true
        if id == .liveText || id == .fingerDots {
            let control = NSButton(image: item.image!, target: self, action: action)
            control.setButtonType(.pushOnPushOff)
            control.bezelStyle = .texturedRounded
            control.toolTip = help
            control.setAccessibilityLabel(label)
            item.view = control
        }
        return item
    }
    
    /// Frequent capture actions live beside the device controls, as in WireView.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .home, .lock, .rotate, .zoom, .flexibleSpace,
         .openScreenshot, .screenshot, .copyScreen, .recording,
         .inspectorTrackingSeparator, .flexibleSpace, .searchCatalog, .toggleInspector]
    }

    /// Add the actions displaced from the removed floating bar once. Preserve
    /// existing customization and subsequent choices to remove toolbar items.
    private func migrateCaptureToolbar(_ toolbar: NSToolbar) {
        guard !UserDefaults.standard.bool(forKey: "captureToolbarMigrated") else { return }
        for id: NSToolbarItem.Identifier in [.home, .rotate, .openScreenshot, .screenshot, .copyScreen, .recording] {
            guard !toolbar.items.contains(where: { $0.itemIdentifier == id }) else { continue }
            let index = toolbar.items.firstIndex { $0.itemIdentifier == .inspectorTrackingSeparator } ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: id, at: index)
        }
        UserDefaults.standard.set(true, forKey: "captureToolbarMigrated")
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.files, .home, .lock, .rotate, .motion, .zoom, .screenshot, .recording, .saveScreenshotAs, .openScreenshot, .captureOptions, .liveText, .copyScreen, .fingerDots, .installApp, .searchCatalog,
         .space, .flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator, .inspectorTrackingSeparator, .toggleInspector]
    }

    /// The sidebar arrived after toolbars were saved; give them its toggle and
    /// separator once, in front, without disturbing the rest.
    private func migrateSidebarToolbar(_ toolbar: NSToolbar) {
        guard !toolbar.items.contains(where: { $0.itemIdentifier == .sidebarTrackingSeparator }) else { return }
        toolbar.insertItem(withItemIdentifier: .sidebarTrackingSeparator, at: 0)
        if !toolbar.items.contains(where: { $0.itemIdentifier == .toggleSidebar }) {
            toolbar.insertItem(withItemIdentifier: .toggleSidebar, at: 0)
        }
    }
    
    // MARK: - Zoom (single source of truth for the toggle, menu, and view)
    
    @objc private func zoomSegmentClicked(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? zoomOut(sender) : zoomIn(sender)
    }

    private func apply(_ mode: ZoomMode) {
        guard let deviceVC else { return }
        let mode = mode == .physical && deviceVC.screen.physicalScale == nil ? ZoomMode.fit : mode
        zoom = mode
        deviceVC.setZoom(mode)
        syncZoomControls()
        Self.saveZoom(mode)
    }

    private static let zoomKey = "zoomMode"
    private static func saveZoom(_ mode: ZoomMode) {
        let encoded: String
        switch mode {
        case .fit: encoded = "fit"
        case .physical: encoded = "physical"
        case .pixels(let n): encoded = "pixels:\(n)"
        }
        UserDefaults.standard.set(encoded, forKey: zoomKey)
    }
    static func savedZoom() -> ZoomMode {
        switch UserDefaults.standard.string(forKey: zoomKey) {
        case "physical", "pixels:1": return .physical
        case let s? where s.hasPrefix("pixels:"):
            return Int(s.dropFirst("pixels:".count)).flatMap { ZoomMode.steps.contains($0) ? .pixels($0) : nil } ?? .fit
        default: return .fit
        }
    }

    /// Grey out a direction there is no room left in.
    private func syncZoomControls() {
        let step = zoom.percent.map { $0 / 100 }
        zoomControl.setEnabled(step != ZoomMode.steps.first, forSegment: 0)
        zoomControl.setEnabled(step != ZoomMode.steps.last, forSegment: 1)
    }

    /// One notch along the ladder, from the pinch gesture and from ⌘+ / ⌘−.
    /// Stepping out of Fit starts from whatever size Fit happens to be showing,
    /// so the first press nudges the device rather than jumping it.
    func stepZoom(_ direction: Int) {
        guard let deviceVC else { return }
        let steps = ZoomMode.steps
        let current = deviceVC.screen.pixelMultiple
        let next = direction > 0
            ? steps.first { CGFloat($0) > current + 0.001 } ?? steps.last!
            : steps.last { CGFloat($0) < current - 0.001 } ?? steps.first!
        apply(.pixels(next))
    }

    @objc func zoomIn(_ sender: Any?)  { stepZoom(1) }
    @objc func zoomOut(_ sender: Any?) { stepZoom(-1) }
    @objc func zoomPhysicalSize(_ sender: Any?) { apply(.physical) }
    @objc func zoomToFit(_ sender: Any?) { apply(.fit) }
    
    // MARK: - Device menu actions (routed via the responder chain)
    
    @objc func deviceHome(_ sender: Any?)        { emulator?.pressHome() }
    @objc func deviceLock(_ sender: Any?) {
        guard let emulator else { return }
        if emulator.isPoweredOff { emulator.powerOn() } else { emulator.pressLock() }
    }
    @objc func deviceVolumeUp(_ sender: Any?)    { emulator?.pressVolumeUp() }
    @objc func deviceVolumeDown(_ sender: Any?)  { emulator?.pressVolumeDown() }
    @objc func deviceRotate(_ sender: Any?) {
        guard let emulator else { return }
        let action = RotationControlAction(rotationDegrees: emulator.rotationDegrees, optionPressed: NSEvent.modifierFlags.contains(.option))
        emulator.rotate(clockwise: action.clockwise)
    }

    @objc private func refreshRotationModifiers() {
        syncRotationControls(optionPressed: NSEvent.modifierFlags.contains(.option))
    }

    private func syncRotationControls(optionPressed: Bool) {
        let action = RotationControlAction(rotationDegrees: emulator?.rotationDegrees ?? 0, optionPressed: optionPressed)
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == .rotate }) {
            item.label = action.title
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)
            item.toolTip = action.help
        }
    }

    @objc func configureWebProxy(_ sender: Any?) {
        guard let window, let emulator else { return }
        let alert = NSAlert()
        alert.messageText = "Proxy"
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let editor = ProxySettingsView(configuration: emulator.webProxy, status: emulator.webProxyStatus, profile: emulator.profile)
        proxySettingsEditor = editor
        editor.onResize = { [weak alert] in alert?.layout() }
        alert.accessoryView = editor
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.proxySettingsEditor = nil
            guard response == .alertFirstButtonReturn else { return }
            do { try emulator.configureWebProxy(editor.configuration) }
            catch { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    @objc func toggleKeyboardInput(_ sender: Any?) { emulator?.toggleKeyboardInput() }

    @objc func toggleFiles(_ sender: Any?) {
        if filesWindow == nil {
            let files = DeviceFilesWindowController(profile: currentProfile)
            filesWindow = files
            files.browser.services = emulator.flatMap { $0.canReachDevice ? $0.usbmuxSession : nil }.map { DeviceServices(clientSocket: $0) }
            files.browser.onActivityChange = { [weak self] in self?.refreshFileStatus() }
            files.browser.reload()
        }
        filesWindow?.showWindow(sender)
    }

    private func refreshFileStatus() {
        emulator?.hasFileTransfer = hasFileTransfer
        guard let filesVC, filesVC.hasTransfer else { fileStatus.isHidden = true; deviceVC?.updateStatusVisibility(); return }
        fileStatus.update(title: filesVC.transferStatus, primary: "Files", secondary: "Cancel")
        deviceVC?.updateStatusVisibility()
    }

    @objc func focusDeviceScreen(_ sender: Any?) {
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        deviceVC?.screen.endLiveText()
        window?.makeFirstResponder(deviceVC?.screen)
    }

    @objc func toggleVerboseBoot(_ sender: Any?) {
        UserDefaults.standard.set(!EmulatorController.verboseBoot,
                                  forKey: EmulatorController.verboseBootDefaultsKey)
    }

    @objc func toggleKernelConsole(_ sender: Any?) {
        UserDefaults.standard.set(!EmulatorController.kernelConsole,
                                  forKey: EmulatorController.kernelConsoleDefaultsKey)
    }

    @objc func deviceRotateLeft(_ sender: Any?) {
        emulator?.rotate(clockwise: false)
    }

    @objc func deviceRotateRight(_ sender: Any?) {
        emulator?.rotate(clockwise: true)
    }

    @objc func selectMotionPose(_ sender: NSMenuItem) {
        guard let pose = EmulatorController.MotionPose(rawValue: sender.tag) else { return }
        emulator?.setMotionPose(pose)
        deviceVC?.screen.resetMotion()
    }
    @objc func resetMotion(_ sender: Any?) { deviceVC?.screen.resetMotion() }

    @objc func deviceShake(_ sender: Any?)       { emulator?.shake() }
    @objc func setBatteryLevel(_ sender: NSMenuItem)    { emulator?.setBattery(level: sender.tag) }
    @objc func setBatteryCharging(_ sender: NSMenuItem) { emulator?.setBattery(charging: Int32(sender.tag)) }
    @objc func toggleHighPowerUSB(_ sender: Any?)       { emulator.map { $0.setHighPowerUSB(!$0.highPowerUSB) } }
    @objc func setCompassHeading(_ sender: NSMenuItem)  { emulator?.setCompassHeading(sender.tag) }
    @objc func toggleDevicePause(_ sender: Any?) {
        guard let emulator else { return }
        if emulator.isPaused { emulator.resume() } else if emulator.isRunning { emulator.pause() }
    }
    @objc func devicePause(_ sender: Any?)       { emulator?.pause() }
    @objc func deviceResume(_ sender: Any?)      { emulator?.resume() }
    @objc func deviceReset(_ sender: Any?) {
        guard let emulator else { return }
        // Confirmed, because a restart cuts the guest off mid-write much the way
        // a force quit does, and it sits one row above Erase in the same menu.
        let alert = NSAlert()
        alert.messageText = "Restart the device?"
        alert.informativeText = "LightTouchMac will flush the device's filesystem first, "
            + "but anything it hasn't finished writing may still be lost."
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window else {
            if alert.runModal() == .alertFirstButtonReturn { emulator.reset() }
            return
        }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            emulator.reset()
        }
    }
    @objc func devicePowerOff(_ sender: Any?) { emulator.map(powerOff) }

    private func powerOff(_ emulator: EmulatorController) {
        emulator.powerOff { [weak emulator] confirmed in
            if confirmed { emulator?.resolveDeviceNotice(for: .powerOff); return }
            emulator?.reportDeviceNotice("The device did not finish powering off. Try Power Off again or restart the device. Open Device Logs for details.", for: .powerOff)
        }
    }

    @objc func saveStateNow(_ sender: Any?) { emulator?.saveSnapshotNow() }

    @objc func discardSavedState(_ sender: Any?) {
        guard let window, let emulator else { return }
        let alert = NSAlert()
        alert.messageText = "Discard the saved state?"
        alert.informativeText = "This removes the saved memory state. Apps and data stored on the device are kept."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { emulator.discardSavedStateByUser() }
        }
    }

    /// Factory-reset the device — the "nuke everything" button. Wipes the NAND
    /// overlay (all installed apps + settings) and any snapshot, back to the
    /// base image; a running device then restarts. The base image is never touched.
    @objc func eraseDevice(_ sender: Any?) { selectedEntry.map { perform(.erase, for: $0) } }

    /// For a device that isn't running, a controller that never starts does
    /// the same erase.
    private func erase(_ entry: FirmwareCatalog.Entry) {
        guard let window, let emulator = host.session(for: entry)?.emulator ?? host.stoppedController(for: entry) else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Erase all content and settings?"
        alert.informativeText = "This permanently removes all apps, settings, and saved state from this \(emulator.profile.shortName). "
            + (AppInstaller.hasPendingWork ? "Installs in progress are cancelled. " : "")
            + (host.session(for: entry) != nil ? "It restarts after erasing. " : "")
            + "This cannot be undone."
        alert.addButton(withTitle: "Erase")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            emulator.requestFactoryReset()
        }
    }
    
    @objc func installApp(_ sender: Any?) {
        guard let window, let emulator else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        panel.message = "Choose one or more decrypted .ipa files to install."
        panel.beginSheetModal(for: window) { [weak window] response in
            guard response == .OK else { return }
            for url in panel.urls {
                AppInstaller.start(url, with: emulator, presenting: window)
            }
        }
    }
    
    @objc func syncMedia(_ sender: Any?) {
        guard let window, let emulator else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = PreparedMedia.extensions.sorted().compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.message = "Choose photos, audio files or videos to add to the \(emulator.profile.shortName)."
        panel.beginSheetModal(for: window) { [weak window] response in
            guard response == .OK else { return }
            for url in panel.urls {
                AppInstaller.startMedia(url, with: emulator, presenting: window)
            }
        }
    }

    /// Respring — the quick fix for a freshly sideloaded app that crashes on
    /// launch until the device is restarted.
    @objc func restartSpringBoard(_ sender: Any?) {
        guard let emulator else { return }
        Task {
            do {
                try await emulator.restartSpringBoard()
            } catch {
                AppInstaller.presentError(error, in: window)
            }
        }
    }

    @objc func openDeviceTerminal(_ sender: Any?) {
        guard let emulator else { return }
        Task {
            do { try await emulator.openTerminal() }
            catch { AppInstaller.presentError(error, in: window) }
        }
    }
    
    // MARK: - View menu (inspector), synced with the toolbar

    @objc func toggleAppInspector(_ sender: Any?) {
        inspectorItem.animator().isCollapsed.toggle()
    }

    
    // MARK: - Edit menu (guest clipboard / screen)
    
    private func captureImage() async throws -> CGImage {
        guard let workspace = session?.workspace else { throw CaptureError.failed("No screen image is available.") }
        let deviceVC = workspace.deviceVC
        deviceVC.screen.endLiveText()
        if captureMode == 0 { return try await workspace.canvasCapture.screenshot() }
        guard let image = deviceVC.screen.captureFrame() else { throw CaptureError.failed("No screen image is available.") }
        return image
    }

    @objc func saveScreenshot(_ sender: Any?) { takeScreenshot(.save) }
    @objc func saveScreenshotAs(_ sender: Any?) { takeScreenshot(.saveAs) }
    @objc func openScreenshot(_ sender: Any?) { takeScreenshot(.open) }

    /// The standard Copy command reaches here only after focused text and
    /// other native responders have had their turn.
    @objc func copy(_ sender: Any?) {
        guard let screen = deviceVC?.screen, window?.firstResponder === screen, !screen.isShowingLiveText else { return }
        copyScreen(sender)
    }

    private enum ScreenshotAction { case copy, save, saveAs, open }
    private func takeScreenshot(_ action: ScreenshotAction) {
        guard canTakeScreenshot, let window else { return }
        screenshotBusy = true
        validateCaptureToolbar()
        Task { [weak self] in
            guard let self else { return }
            defer { screenshotBusy = false; validateCaptureToolbar() }
            do {
                let image = try await captureImage()
                guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw CaptureError.failed("Could not create the screenshot.")
                }
                let nsImage = NSImage(cgImage: image, size: .zero)
                var savedURL: URL?
                if action == .copy {
                    try copyImage(nsImage)
                    showCopyConfirmation()
                } else if action == .open {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Light Touch Screenshots", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent(captureName("Screenshot") + " " + UUID().uuidString.prefix(8)).appendingPathExtension("png")
                    try data.write(to: url, options: .atomic)
                    if let application = capturePreferences.openInApplicationURL {
                        _ = try await NSWorkspace.shared.open([url], withApplicationAt: application, configuration: .init())
                    } else {
                        _ = try await NSWorkspace.shared.open(url, configuration: .init())
                    }
                } else {
                    if action == .saveAs {
                        guard let url = await chooseScreenshotDestination() else { return }
                        try data.write(to: url, options: .atomic)
                        savedURL = url
                    } else {
                        do {
                            let url = try captureDestination("Screenshot", extension: "png")
                            try data.write(to: url, options: .atomic)
                            savedURL = url
                        } catch {
                            guard let url = await chooseScreenshotDestination() else { return }
                            try data.write(to: url, options: .atomic)
                            savedURL = url
                        }
                    }
                }
                if action != .copy, capturePreferences.copyOnCapture {
                    // Copying is an extra convenience; a clipboard failure must
                    // not turn a successfully saved capture into a save error.
                    if (try? copyImage(nsImage)) != nil { showCopyConfirmation() }
                }
                CaptureSound.screenshot.play()
                if let savedURL, capturePreferences.openFinderAfterCapture {
                    NSWorkspace.shared.activateFileViewerSelecting([savedURL])
                }
                if !recording.isActive, action != .open {
                    captureStatus.showCapture(title: action == .copy ? "Screenshot copied" : "Screenshot saved",
                                              image: nsImage, fileURL: savedURL)
                    deviceVC?.updateStatusVisibility()
                }
            } catch { NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil) }
        }
    }

    private func copyImage(_ image: NSImage) throws {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([image]) else { throw CaptureError.failed("Could not copy the screenshot.") }
    }

    private func showCopyConfirmation() {
        copyConfirmation?.cancel()
        copiedScreenshot = true
        validateCaptureToolbar()
        copyConfirmation = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            self?.copiedScreenshot = false
            self?.validateCaptureToolbar()
        }
    }

    private func chooseScreenshotDestination() async -> URL? {
        guard let window else { return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = captureFolder
        panel.nameFieldStringValue = captureName("Screenshot") + ".png"
        return await panel.beginSheetModal(for: window) == .OK ? panel.url : nil
    }

    @objc func showCaptureOptions(_ sender: Any?) {
        if captureOptionsWindow == nil {
            let editor = CaptureOptionsView(preferences: capturePreferences, profile: currentProfile)
            editor.onChange = { [weak self] in self?.validateCaptureToolbar() }
            editor.layoutSubtreeIfNeeded()
            let panel = NSWindow(contentRect: NSRect(origin: .zero, size: editor.fittingSize), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Capture Options"
            WindowRestorationPolicy.configure(panel)
            panel.contentView = editor
            editor.onResize = { [weak panel, weak editor] in
                guard let panel, let editor else { return }
                panel.setContentSize(editor.fittingSize)
            }
            panel.isReleasedWhenClosed = false
            panel.center()
            captureOptionsWindow = NSWindowController(window: panel)
        }
        (captureOptionsWindow?.window?.contentView as? CaptureOptionsView)?.reload()
        captureOptionsWindow?.showWindow(sender)
        captureOptionsWindow?.window?.makeKeyAndOrderFront(sender)
    }

    private func installCaptureKeyboardShortcuts() {
        captureKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 49, event.type == .keyUp, consumedCaptureSpace {
                consumedCaptureSpace = false
                return nil
            }
            if event.keyCode == 49, event.type == .keyDown {
                if event.isARepeat, consumedCaptureSpace { return nil }
                if !event.isARepeat { consumedCaptureSpace = false }
            }
            guard event.type == .keyDown, event.keyCode == 49,
                  let window, event.window === window, window.isKeyWindow,
                  window.attachedSheet == nil, NSApp.modalWindow == nil,
                  let screen = deviceVC?.screen, window.firstResponder === screen,
                  !screen.isShowingLiveText,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  capturePreferences.spaceBarAction != .none else { return event }
            guard !event.isARepeat else { return consumedCaptureSpace ? nil : event }
            consumedCaptureSpace = true
            switch capturePreferences.spaceBarAction {
            case .none: return event
            case .copyScreenshot: copyScreen(nil)
            case .saveScreenshot: saveScreenshot(nil)
            case .saveScreenshotAs: saveScreenshotAs(nil)
            case .toggleRecording: toggleRecording(nil)
            }
            return nil
        }
    }

    private func installCaptureNotifications() {
        CaptureNotifications.shared.onRecordingAction = { [weak self] id, action in
            guard let self, recording.id == id, recording.canStop else { return }
            switch action {
            case .stopAndSave: recording.stop()
            case .stopAndDelete: recording.stop(discard: true)
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(recordingAppDidResignActive), name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(recordingAppDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func recordingAppDidResignActive() {
        guard recording.canStop else { return }
        let id = recording.id
        let seconds = capturePreferences.reminderAfterDuration
        Task { [weak self] in
            guard let self, recording.id == id, recording.canStop, !NSApp.isActive else { return }
            await CaptureNotifications.shared.scheduleReminder(after: TimeInterval(seconds), recordingID: id, profile: currentProfile)
        }
    }

    @objc private func recordingAppDidBecomeActive() { CaptureNotifications.shared.cancelReminder() }

    private func recoverUnfinishedRecordings() {
        let cutoff = Date()
        Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await ScreenRecordingSession.recoverRecordings(createdBefore: cutoff) { _ in
                    try self.captureDestination("Recording", extension: "mov")
                }
                for url in report.saved {
                    if capturePreferences.notifyOnRecordingRecovery,
                       await CaptureNotifications.shared.notifyRecoveredRecording(url) { continue }
                    if capturePreferences.openFinderAfterCapture || capturePreferences.notifyOnRecordingRecovery {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                if !report.remaining.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(report.remaining) }
            } catch { logEvent("recording recovery: \(error.localizedDescription)") }
        }
    }

    @objc func toggleCaptureScreenOnly(_ sender: Any?) {
        guard !recording.isActive, !screenshotBusy else { return }
        UserDefaults.standard.set(captureMode == 0 ? 1 : 0, forKey: "captureMode")
    }
    private func installFileStatus() {
        fileStatus.isHidden = true
        startupStatus.isHidden = true
        startupStatus.onPrimary = { [weak self] in self?.showDeviceLogs(nil) }
        fileStatus.onPrimary = { [weak self] in self?.toggleFiles(nil) }
        fileStatus.onSecondary = { [weak self] in self?.cancelFileTransfer() }
    }

    private var captureFolder: URL { capturePreferences.saveLocation }

    private func captureDestination(_ kind: String, extension suffix: String) throws -> URL {
        let folder = captureFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(captureName(kind) + " " + UUID().uuidString.prefix(8))
            .appendingPathExtension(suffix)
    }

    private func captureName(_ kind: String) -> String {
        let date = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        return "Light Touch \(kind) \(date)"
    }

    @objc func showLiveText(_ sender: Any?) {
        guard let deviceVC, !recording.isActive, deviceVC.screen.isShowingLiveText || canTakeScreenshot else { return }
        deviceVC.screen.toggleLiveText()
        window?.toolbar?.validateVisibleItems()
        validateCaptureToolbar()
    }

    @objc func toggleTouchOverlay(_ sender: Any?) {
        deviceVC?.screen.showsTouches.toggle()
        window?.toolbar?.validateVisibleItems()
        validateCaptureToolbar()
    }

    private func installCaptureStatus() {
        captureStatus.isHidden = true
        captureStatus.onPrimary = { [weak self] in self?.saveRecordingAs() }
        captureStatus.onSecondary = { [weak self] in
            guard let self else { return }
            // Resolve the file from the displayed banner. A prior recording's
            // saved state must not hijack a newer screenshot's Reveal action.
            if let url = captureStatus.fileURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else if case let .recovery(url) = recording.phase {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        captureStatus.onDismiss = { [weak self] in self?.recording.dismiss(); self?.captureStatus.isHidden = true; self?.deviceVC?.updateStatusVisibility() }
    }

    private func validateCaptureToolbar() {
        refreshRotationModifiers()
        // AppKit does not automatically validate toolbar items with custom
        // views. Update the control explicitly on health and elapsed-time changes.
        for item in window?.toolbar?.items ?? [] where item.itemIdentifier == .recording {
            item.isEnabled = validateToolbarItem(item)
        }
        window?.toolbar?.validateVisibleItems()
    }

    private func refreshRecording() {
        defer { deviceVC?.updateStatusVisibility() }
        if !recording.canStop { CaptureNotifications.shared.cancelReminder() }
        window?.toolbar?.validateVisibleItems()
        validateCaptureToolbar()
        switch recording.phase {
        case .idle: captureStatus.isHidden = true
        case .starting, .recording:
            captureStatus.isHidden = true
        case .saving:
            captureStatus.isHidden = true
        case let .saved(url):
            let thumbnail = recording.previewImage.map { NSImage(cgImage: $0, size: .zero) }
                ?? NSWorkspace.shared.icon(forFile: url.path)
            captureStatus.showCapture(title: "Recording saved", image: thumbnail, fileURL: url)
        case .recovery:
            captureStatus.update(title: "Recording needs attention", detail: recording.failure?.localizedDescription ?? "Save to another folder.",
                                 primary: "Save As…", secondary: "Show in Finder", dismissible: true, appearance: .warning)
        }
    }

    @objc func toggleRecording(_ sender: Any?) {
        if recording.canStop { recording.stop(); return }
        if case .recovery = recording.phase { saveRecordingAs(); return }
        guard !recording.isActive, canStartRecording, let workspace = session?.workspace else { return }
        let screen = workspace.deviceVC.screen
        screen.endLiveText()
        let canvas = captureMode == 0
        let source = workspace.canvasCapture
        let background = NSImage(named: "gradient")?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let emulator = workspace.deviceVC.emulator
        recording.start(frame: { [weak screen] in
            if canvas { return try source.frame() }
            return screen?.captureFrame()
        }, audio: { try await emulator.startAudioCapture() }, prepare: { [weak screen] in
            if canvas {
                screen?.isCapturingCanvas = true
                try await source.start(); return source.outputSize
            }
            return nil
        }, cleanup: { [weak screen] in
            if canvas {
                await source.stop()
                screen?.isCapturingCanvas = false
            }
        }, background: background,
        destination: { [weak self] in
            guard let self else { throw CaptureError.failed("The capture window was closed.") }
            return try captureDestination("Recording", extension: "mov")
        })
        window?.makeFirstResponder(screen)
    }

    @objc func discardRecording(_ sender: Any?) {
        guard recording.canStop, let window else { return }
        let recordingID = recording.id
        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Stop and Save")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[2].keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, recording.id == recordingID else { return }
            if response == .alertFirstButtonReturn { recording.stop(discard: true) }
            else if response == .alertSecondButtonReturn { recording.stop() }
        }
    }

    private func saveRecordingAs() {
        guard let window, case let .recovery(source) = recording.phase else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = captureName("Recording") + ".mov"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, self?.recording.phase == .recovery(source) else { return }
            self?.recording.retrySave(to: url)
        }
    }

    @objc func showRecordingRecovery(_ sender: Any?) {
        do {
            try FileManager.default.createDirectory(at: ScreenRecordingSession.recoveryDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(ScreenRecordingSession.recoveryDirectory)
        } catch { if let window { NSAlert(error: error).beginSheetModal(for: window) } }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard recording.isActive else { return true }
        closeAfterRecording = true
        recording.stop()
        return false
    }

    func finishRecordingBeforeQuit() -> Bool {
        guard recording.isActive else { return false }
        quitAfterRecording = true
        recording.stop()
        return true
    }

    @objc func copyScreen(_ sender: Any?) { takeScreenshot(.copy) }
    @objc private func stopHiddenRecording() { recording.stop() }
    func windowWillMiniaturize(_ notification: Notification) { recording.stop() }

    @objc func pasteToGuest(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        emulator?.pasteToGuest(text)
    }

    // MARK: - Diagnostics

    /// Bundle the logs + provenance into a zip for a bug report. The logs are
    /// where the last two nights' failures were finally diagnosed; making them
    /// one click to collect means the next report arrives with its evidence.
    private var logWindow: LogWindowController?
    private var logInstance: UUID?
    /// The selected device's serial and usbmuxd logs and session file, with
    /// the app-wide ones.
    private var diagnosticInstance: DeviceInstance? { session?.instance ?? selectedEntry.flatMap(host.instance(for:)) }
    private var diagnosticLogs: [URL] {
        let app = ["app.log", "native.log"].map { Bundled.logsDirectory.appendingPathComponent($0) }
        let device = ["serial.log", "usbmuxd.log"].compactMap { diagnosticInstance?.paths.logs.appendingPathComponent($0) }
        return (app + device).flatMap { [$0, $0.appendingPathExtension("1")] }
    }

    @objc func showDeviceLogs(_ sender: Any?) {
        // A window per device: switching the selection opens that device's logs.
        if logWindow == nil || logInstance != diagnosticInstance?.id {
            logWindow?.close()
            logWindow = LogWindowController(logs: diagnosticLogs)
            logInstance = diagnosticInstance?.id
        }
        logWindow?.showWindow(sender)
    }

    @objc func exportDiagnostics(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "LightTouchMac-diagnostics.zip"
        if let zip = UTType(filenameExtension: "zip") { panel.allowedContentTypes = [zip] }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let dest = panel.url else { return }
            Task { await self.writeDiagnostics(to: dest) }
        }
    }

    private func writeDiagnostics(to dest: URL) async {
        await AppEventLog.shared.flush()
        NativeLogging.flush()
        let logs = diagnosticLogs + [diagnosticInstance?.paths.sessionFile].compactMap { $0 }
        let device = emulator.map { emulator in """
            \(emulator.dylibProvenance)
            state: \(emulator.statusLine)
            files-root: \(emulator.options.filesRoot)
            nand: \(emulator.options.nand)
            appsync: \(emulator.options.appsync)   network: \(emulator.options.network)
            canManageApps: \(emulator.canManageApps)
            """ } ?? "state: not running"
        let info = """
        LightTouchMac diagnostics
        device: \(diagnosticInstance.map { "\($0.name) \($0.firmware) \($0.id)" } ?? "none")
        \(device)
        """
        do {
            try await DiagnosticsExport.write(to: dest, logs: logs, info: info)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch is CancellationError {
            // The exporter waits for its child to stop before removing scratch.
        } catch {
            if let window { await NSAlert(error: error).beginSheetModal(for: window) }
        }
    }
}

// MARK: - Diagnostics storage

/// Each export owns its scratch and publishes one complete archive. Kept apart
/// from the window so the failure/cancellation paths can run without a device.
nonisolated enum DiagnosticsExport {
    @concurrent
    static func write(to destination: URL, logs: [URL], info: String,
                      temporaryRoot: URL = FileManager.default.temporaryDirectory,
                      archiver: URL = URL(fileURLWithPath: "/usr/bin/ditto")) async throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        let scratch = temporaryRoot.appendingPathComponent("LightTouch-diagnostics-" + UUID().uuidString,
                                                          isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let staging = scratch.appendingPathComponent("LightTouchMac-diagnostics", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        for source in logs where fm.fileExists(atPath: source.path) {
            try Task.checkCancellation()
            try fm.copyItem(at: source, to: staging.appendingPathComponent(source.lastPathComponent))
        }
        try info.write(to: staging.appendingPathComponent("info.txt"), atomically: true, encoding: .utf8)

        // Keep the final rename on the destination volume. Failure or cancellation
        // leaves an existing user-selected archive untouched.
        let archive = destination.deletingLastPathComponent()
            .appendingPathComponent(".LightTouch-diagnostics-" + UUID().uuidString + ".zip")
        defer { try? fm.removeItem(at: archive) }
        try await runArchiver(archiver, staging: staging, archive: archive)
        let attributes = try fm.attributesOfItem(atPath: archive.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.uint64Value ?? 0 > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()
        guard rename(archive.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func runArchiver(_ executable: URL, staging: URL, archive: URL) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, archive.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { child in
                    continuation.resume(returning: child.terminationStatus)
                }
                do {
                    try process.run()
                    // Cancellation may have arrived before the process was live.
                    if Task.isCancelled, process.isRunning { process.terminate() }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        guard status == 0 else {
            throw NSError(domain: "LightTouch.Diagnostics", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Could not create the diagnostics archive (exit \(status))."
            ])
        }
    }
}

// MARK: - Toolbar item validation (same command model as the menus)

extension MainWindowController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .captureOptions, .files, .motion, .searchCatalog, .toggleSidebar: return true
        default: break
        }
        guard let emulator, let deviceVC else {
            (item.view as? NSControl)?.isEnabled = false
            if item.itemIdentifier == .recording {
                (item.view as? RecordingToolbarButton)?.update(recording.needsRecovery ? .recovery : .idle, elapsed: recording.elapsed, enabled: canToggleRecording)
                return canToggleRecording
            }
            return false
        }
        // Custom views keep their own enabled state; the cases below narrow it.
        if item.itemIdentifier != .recording { (item.view as? NSControl)?.isEnabled = true }
        switch item.itemIdentifier {
        // Install is NOT gated on isInstalling: AppInstaller queues jobs behind
        // one another, so choosing a second .ipa mid-install is supported and
        // blocking it was a regression. The terminal is gated, because it opens
        // a competing lockdown session.
        case .screenshot:
            return canTakeScreenshot
        case .copyScreen:
            item.image = NSImage(systemSymbolName: copiedScreenshot ? "checkmark.circle" : "document.on.document",
                                 accessibilityDescription: "Copy Screenshot")
            return canTakeScreenshot
        case .recording:
            let phase: RecordingToolbarButton.Phase = recording.phase == .saving ? .saving
                : recording.needsRecovery ? .recovery : recording.canStop ? .recording : .idle
            (item.view as? RecordingToolbarButton)?.update(phase, elapsed: recording.elapsed, enabled: canToggleRecording)
            item.label = "Record"
            item.toolTip = (item.view as? NSButton)?.toolTip
            return canToggleRecording
        case .openScreenshot:
            item.label = "Open Screenshot in \(capturePreferences.openInApplicationName)"
            item.toolTip = item.label + " (⌘O)"
            return canTakeScreenshot
        case .saveScreenshotAs:
            return canTakeScreenshot
        case .captureOptions:
            return true
        case .liveText:
            (item.view as? NSButton)?.state = deviceVC.screen.isShowingLiveText ? .on : .off
            item.label = deviceVC.screen.isShowingLiveText ? "Done Selecting Text" : "Select Text on Screen"
            item.toolTip = item.label
            (item.view as? NSButton)?.toolTip = item.label
            (item.view as? NSButton)?.setAccessibilityLabel(item.label)
            let enabled = !recording.isActive && (deviceVC.screen.isShowingLiveText || canTakeScreenshot)
            (item.view as? NSButton)?.isEnabled = enabled
            return enabled
        case .fingerDots:
            (item.view as? NSButton)?.state = deviceVC.screen.showsTouches ? .on : .off
            item.label = deviceVC.screen.showsTouches ? "Hide Finger Dots" : "Show Finger Dots"
            item.toolTip = item.label
            (item.view as? NSButton)?.toolTip = item.label
            (item.view as? NSButton)?.setAccessibilityLabel(item.label)
            return true
        case .installApp:
            return emulator.canQueueInstall
        case .lock:
            item.label = emulator.isPoweredOff ? "Power On" : emulator.isSleeping ? "Wake" : "Lock"
            item.image = NSImage(systemSymbolName: emulator.isPoweredOff ? "power" : "lock", accessibilityDescription: item.label)
            item.toolTip = item.label + " (⌘L)"
            return emulator.acceptsInput || (emulator.isPoweredOff && !emulator.shuttingDown)
        case .home, .rotate:
            return emulator.acceptsInput
        case .files, .motion, .searchCatalog:
            return true
        default:
            return !emulator.isDead
        }
    }
}

// MARK: - Menu validation (enablement + checkmarks)

extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleFiles(_:)) {
            return true
        }
        // The selected row's commands, and the window's own, work without a device.
        switch menuItem.action {
        case #selector(toggleDeviceRunning(_:)):
            let running = selectedEntry.map { host.row(for: $0).state == .running } ?? false
            menuItem.title = running ? "Stop" : "Start"
            return selectedEntry.map { canPerform(running ? .stop : .start, for: $0) } ?? false
        case #selector(downloadAndPrepare(_:)): return selectedEntry.map { canPerform(.downloadAndPrepare, for: $0) } ?? false
        case #selector(importIPSW(_:)): return selectedEntry.map { canPerform(.importIPSW, for: $0) } ?? false
        case #selector(cancelFirmwareJob(_:)):
            if let entry = selectedEntry, case .preparing = host.row(for: entry).state { menuItem.title = "Cancel Preparation" }
            else { menuItem.title = "Cancel Download" }
            return selectedEntry.map { canPerform(.cancel, for: $0) } ?? false
        case #selector(showDeviceInFinder(_:)): return selectedEntry.map { canPerform(.showInFinder, for: $0) } ?? false
        case #selector(deleteDevice(_:)): return selectedEntry.map { canPerform(.delete, for: $0) } ?? false
        case #selector(eraseDevice(_:)): return selectedEntry.map { canPerform(.erase, for: $0) } ?? false
        case #selector(toggleCaptureScreenOnly(_:)):
            menuItem.state = captureMode == 1 ? .on : .off
            return !recording.isActive && !screenshotBusy
        case #selector(toggleVerboseBoot(_:)):
            menuItem.state = EmulatorController.verboseBoot ? .on : .off
            return true
        case #selector(toggleKernelConsole(_:)):
            menuItem.state = EmulatorController.kernelConsole ? .on : .off
            return true
        case #selector(discardRecording(_:)):
            return recording.canStop
        case #selector(toggleRecording(_:)):
            menuItem.title = recording.needsRecovery ? "Save Recording As…" : recording.canStop ? "Stop Recording" : "Start Recording"
            return canToggleRecording
        case #selector(toggleAppInspector(_:)):
            menuItem.title = inspectorItem.isCollapsed ? "Show Inspector" : "Hide Inspector"
            return true
        case #selector(showDeviceLogs(_:)), #selector(exportDiagnostics(_:)), #selector(showRecordingRecovery(_:)),
             #selector(showCaptureOptions(_:)), #selector(focusDeviceScreen(_:)):
            return true
        default: break
        }
        guard let emulator, let deviceVC else { return false }
        switch menuItem.action {
        case #selector(selectMotionPose(_:)):
            menuItem.state = menuItem.tag == emulator.motionPose.rawValue ? .on : .off
            return true
        case #selector(resetMotion(_:)):
            return emulator.acceptsInput && !emulator.isSleeping

        // App management: needs USB, a live guest, and no install already running
        // (the guest serves ~one lockdown session).
        case #selector(installApp(_:)):
            return emulator.canQueueInstall
        case #selector(syncMedia(_:)):
            return emulator.canQueueInstall && emulator.hasGuestTools
        case #selector(openDeviceTerminal(_:)), #selector(restartSpringBoard(_:)):
            return emulator.canReachDevice && !emulator.isInstalling
        // Device input only reaches a running guest.
        case #selector(deviceLock(_:)):
            menuItem.title = emulator.isPoweredOff ? "Power On" : emulator.isSleeping ? "Wake" : "Lock"
            return emulator.acceptsInput || (emulator.isPoweredOff && !emulator.shuttingDown)
        case #selector(deviceRotate(_:)), #selector(deviceRotateLeft(_:)), #selector(deviceRotateRight(_:)):
            return emulator.acceptsInput && !(window?.firstResponder is NSTextView)
        case #selector(setBatteryLevel(_:)):
            menuItem.state = menuItem.tag == emulator.batteryLevel ? .on : .off
            return emulator.acceptsInput
        case #selector(setBatteryCharging(_:)):
            menuItem.state = Int32(menuItem.tag) == emulator.batteryCharging ? .on : .off
            return emulator.acceptsInput
        case #selector(toggleHighPowerUSB(_:)):
            menuItem.state = emulator.highPowerUSB ? .on : .off
            menuItem.toolTip = emulator.canChooseUSBCharger ? nil
                : "The Mac's USB connection always grants high power, as a real Mac does."
            return emulator.acceptsInput && emulator.canChooseUSBCharger
        case #selector(setCompassHeading(_:)):
            menuItem.state = menuItem.tag == emulator.compassHeading ? .on : .off
            return emulator.acceptsInput && emulator.hasCompass
        case #selector(deviceHome(_:)), #selector(deviceShake(_:)),
             #selector(deviceVolumeUp(_:)), #selector(deviceVolumeDown(_:)):
            return emulator.acceptsInput
        case #selector(toggleDevicePause(_:)):
            menuItem.title = emulator.isPaused ? "Resume" : "Pause"
            return (emulator.isRunning || emulator.isPaused) && !emulator.isInstalling && !AppInstaller.hasPendingWork
        case #selector(configureWebProxy(_:)):
            return emulator.webProxyAvailable
        case #selector(toggleKeyboardInput(_:)):
            menuItem.state = emulator.keyboardInputEnabled ? .on : .off
            return true
        case #selector(devicePowerOff(_:)): return emulator.acceptsInput
        case #selector(deviceReset(_:)):  return !emulator.isDead
        case #selector(saveStateNow(_:)): return emulator.isRunning
        case #selector(discardSavedState(_:)): return emulator.hasSavedState
        case #selector(toggleTouchOverlay(_:)):
            menuItem.title = deviceVC.screen.showsTouches ? "Hide Finger Dots" : "Show Finger Dots"
            return true
        case #selector(showLiveText(_:)):
            menuItem.title = deviceVC.screen.isShowingLiveText ? "Done Selecting Text" : "Select Text on Screen"
            return !recording.isActive && (deviceVC.screen.isShowingLiveText || canTakeScreenshot)
        case #selector(openScreenshot(_:)):
            menuItem.title = "Open Screenshot in \(capturePreferences.openInApplicationName)"
            return canTakeScreenshot
        case #selector(copy(_:)):
            return window?.firstResponder === deviceVC.screen && !deviceVC.screen.isShowingLiveText && canTakeScreenshot
        case #selector(saveScreenshot(_:)), #selector(saveScreenshotAs(_:)), #selector(copyScreen(_:)):
            return canTakeScreenshot
        case #selector(pasteToGuest(_:)):
            return emulator.acceptsInput && NSPasteboard.general.string(forType: .string) != nil
        case #selector(zoomIn(_:)):
            return zoom.percent.map { $0 / 100 } ?? 0 < ZoomMode.steps.last!
        case #selector(zoomOut(_:)):
            return zoom != .pixels(ZoomMode.steps[0])
        case #selector(zoomPhysicalSize(_:)):
            menuItem.state = (zoom == .physical) ? .on : .off
            return deviceVC.screen.physicalScale != nil
        case #selector(zoomToFit(_:)):
            menuItem.state = (zoom == .fit) ? .on : .off
            return true
        default:
            return true
        }
    }
}

// MARK: - Split-view panes

/// A split-view pane whose content changes with the selection. The split
/// items stay put, so the tracking separators and collapse state do too.
private final class ContainerViewController: NSViewController {
    override func loadView() { view = NSView() }

    func show(_ child: NSViewController) {
        guard children.first !== child else { return }
        for old in children { old.view.removeFromSuperview(); old.removeFromParent() }
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

/// The inspector while the selected device isn't running.
private final class NotRunningViewController: NSViewController {
    override func loadView() {
        let label = NSTextField(labelWithString: "Not Running")
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        view = NSView()
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
