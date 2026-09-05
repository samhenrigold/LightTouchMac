// Created by Sam on 2026-08-05.
//
// The single window: device centred in the main column, an app-management
// inspector on the trailing edge, and a toolbar whose items mirror the menu bar
// (same selectors, same validation). Menu actions route here through the
// responder chain (the window controller is the window's next responder).

import Cocoa
import UniformTypeIdentifiers

private extension NSToolbarItem.Identifier {
    static let home         = NSToolbarItem.Identifier("home")
    static let lock         = NSToolbarItem.Identifier("lock")
    static let rotate       = NSToolbarItem.Identifier("rotate")
    static let zoom         = NSToolbarItem.Identifier("zoom")
    static let installApp   = NSToolbarItem.Identifier("installApp")
    static let openTerminal = NSToolbarItem.Identifier("openTerminal")
    static let searchCatalog = NSToolbarItem.Identifier("searchCatalog")
}

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    
    private let emulator: EmulatorController
    private let deviceVC: DeviceViewController
    private let inspectorVC: AppsInspectorViewController
    private let inspectorItem: NSSplitViewItem
    private let zoomControl = NSSegmentedControl()
    private var rotateItem: NSToolbarItem?
    private(set) var zoom: ZoomMode = .fit
    private var deadOverlay: NSView?
    
    init(emulator: EmulatorController) {
        self.emulator = emulator
        self.deviceVC = DeviceViewController(emulator: emulator)
        self.inspectorVC = AppsInspectorViewController(emulator: emulator)
        
        let split = NSSplitViewController()
        // Remember the divider position and inspector-collapsed state across
        // launches (state restoration is on; this is the missing piece).
        split.splitView.autosaveName = "MainSplit"
        let deviceItem = NSSplitViewItem(viewController: deviceVC)
        deviceItem.minimumThickness = 200
        split.addSplitViewItem(deviceItem)
        
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorVC)
        // The widths the sidebar guidelines ask for: enough for an app name at a
        // readable size, not so much that it competes with the device.
        inspectorItem.minimumThickness = 240
        inspectorItem.maximumThickness = 400
        if #available(macOS 26.0, *) {
            inspectorItem.addBottomAlignedAccessoryViewController(inspectorVC.makeBottomBar())
        }
        split.addSplitViewItem(inspectorItem)
        
        let window = NSWindow(contentViewController: split)
        window.title = "iPod touch"
        // .fullSizeContentView is what makes the inspector run the FULL HEIGHT
        // of the window rather than starting below the toolbar (WWDC23 "inspectors
        // use the full height of the window when the full size content view mask
        // is set"). Without it the tracking separator splits the toolbar but the
        // inspector's material still stops at it, which is the giveaway that the
        // pane is sitting under the titlebar instead of behind it.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 320 + 260, height: 560))
        window.setFrameAutosaveName("Main")
        super.init(window: window)
        
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        
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
            zoomControl.setToolTip(label, forSegment: index)
        }
        zoomControl.target = self
        zoomControl.action = #selector(zoomSegmentClicked(_:))
        zoomControl.sizeToFit()
        syncZoomControls()

        window.delegate = self
        emulator.onStatusChange = { [weak self] in self?.refreshForState() }
        refreshForState()
    }

    private let movieWriter = ScreenMovieWriter()
    private var recordingTask: Task<Void, Never>?
    private var recordingOutput: URL?
    private var recordingStartedAt: CFTimeInterval = 0
    private var finishingRecording = false
    private var recordingFailure: Error?
    private var quitAfterRecording = false
    private var recordingIndicator: NSTitlebarAccessoryViewController?
    private var liveTextWindow: LiveTextWindowController?

    required init?(coder: NSCoder) { fatalError("not used") }

    override func windowDidLoad() {
        super.windowDidLoad()
        reportEraseFailureIfNeeded()
        // Only center on first run. setFrameAutosaveName already restored a
        // saved frame; centering unconditionally threw that away every launch.
        if window?.setFrameUsingName("Main") != true { window?.center() }
        apply(Self.savedZoom())   // restore the zoom the user left it at
    }

    /// An erase the user confirmed that could not be carried out. Silence here
    /// meant a destructive action appeared to do nothing, with the request still
    /// armed to fire at some later launch.
    private func reportEraseFailureIfNeeded() {
        guard let reason = emulator.eraseFailure, let window else { return }
        emulator.clearEraseFailure()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "The device could not be erased"
        alert.informativeText = "\(reason)\n\nThe device is unchanged, and the erase is still "
            + "pending — it will be tried again the next time you open LightTouchMac. "
            + "Choose Device ▸ Erase All Content and Settings again to cancel it."
        alert.beginSheetModal(for: window) { _ in }
    }

    // MARK: - Health / status surfacing

    private func refreshForState() {
        // The window subtitle is where AppKit puts secondary window state, and
        // it styles and truncates itself to match the title. A custom titlebar
        // accessory was carrying this before — more code, its own constraints,
        // and it competed with the toolbar for space.
        window?.subtitle = emulator.isRunning && !emulator.isSleeping
            ? (emulator.foregroundAppName ?? emulator.statusLine) : emulator.statusLine
        deviceVC.screen.updatePowerPresentation()
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == .lock }) {
            item.label = emulator.isPoweredOff ? "Power On" : "Lock"
            item.image = NSImage(systemSymbolName: emulator.isPoweredOff ? "power" : "lock", accessibilityDescription: item.label)
            item.toolTip = emulator.isPoweredOff ? "Power on the device" : "Lock or wake the device; open the menu for power options"
        }
        window?.toolbar?.validateVisibleItems()
        syncRotateSymbol()      // follows automatic rotations, not just manual ones
        updateDeadOverlay()
    }

    /// When the emulator dies (QEMU can't re-init), cover the device with an
    /// unmistakable overlay — the frozen last frame otherwise looks live.
    private func updateDeadOverlay() {
        guard emulator.isDead else {
            deadOverlay?.removeFromSuperview()
            deadOverlay = nil
            return
        }
        guard deadOverlay == nil, let content = window?.contentView else { return }
        let overlay = NSView()
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        overlay.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "The emulator stopped.")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        let button = NSButton(title: "Relaunch", target: self, action: #selector(relaunchApp(_:)))
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
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])
        deadOverlay = overlay
    }

    /// QEMU is once-per-process, so recovering means a fresh process. Launch a
    /// new instance, then quit this dead one.
    @objc private func relaunchApp(_ sender: Any?) {
        // Exit BEFORE the successor starts. Launching first and terminating in
        // the completion handler overlapped two processes on one NAND overlay,
        // and the new instance's usbmuxd reaper would SIGTERM the old, live
        // daemon. Same reasoning as EmulatorController.coldRelaunch.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open -n \"$1\"", "sh", Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }
    
    /// ⌘F / Edit ▸ Find: focus the Legacy Store search field in the toolbar.
    @objc func findCatalog(_ sender: Any?) {
        inspectorVC.focusSearch()
    }

    // MARK: - Toolbar

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .home:
            return button(id, "Home", "house", #selector(deviceHome(_:)), "Press the Home button")
        case .lock:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Lock"
            item.paletteLabel = "Lock and Power Off"
            item.toolTip = "Lock or wake the device; open the menu for power options"
            item.image = NSImage(systemSymbolName: "lock", accessibilityDescription: "Lock")
            item.target = self
            item.action = #selector(deviceLock(_:))
            item.isBordered = true
            item.showsIndicator = true
            let menu = NSMenu(title: "Device Power")
            let lock = menu.addItem(withTitle: "Lock", action: #selector(deviceLock(_:)), keyEquivalent: "")
            lock.target = self
            lock.image = NSImage(systemSymbolName: "lock", accessibilityDescription: nil)
            let powerOff = menu.addItem(withTitle: "Power Off", action: #selector(devicePowerOff(_:)), keyEquivalent: "")
            powerOff.target = self
            powerOff.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
            powerOff.toolTip = "Shut down the device while keeping this window open"
            item.menu = menu
            return item
        case .rotate:
            let item = button(id, "Rotate", rotateSymbolName, #selector(deviceRotate(_:)), "Rotate between portrait and landscape")
            rotateItem = item
            return item
        case .installApp:
            return button(id, "Install App", "square.and.arrow.down", #selector(installApp(_:)), "Install a decrypted .ipa")
        case .searchCatalog:
            // The inspector owns the field (its text drives the catalog/installed
            // mode switch); the toolbar is just where it lives — the standard
            // Mac home for search, riding above the inspector pane thanks to
            // the tracking separator.
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.label = "Search"
            item.paletteLabel = "Search Legacy Store"
            item.toolTip = "Search Legacy Store for apps the device can run"
            inspectorVC.attachSearchField(to: item)
            return item
        case .openTerminal:
            return button(id, "SSH", "terminal", #selector(openDeviceTerminal(_:)), "Open a root shell on the device")
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
        return item
    }
    
    /// The inspector toggle ships in the default set: an inspector nobody can
    /// find is an inspector nobody uses, and the toolbar is the only place the
    /// control is meant to live. The tracking separator sits on the split
    /// view's divider, so the toggle rides above the inspector rather than
    /// floating in the middle of the titlebar.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.home, .lock, .rotate, .zoom,
         .flexibleSpace, .inspectorTrackingSeparator, .flexibleSpace, .searchCatalog, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.home, .lock, .rotate, .zoom, .installApp, .openTerminal, .searchCatalog,
         .space, .flexibleSpace, .inspectorTrackingSeparator, .toggleInspector]
    }
    
    // MARK: - Zoom (single source of truth for the toggle, menu, and view)
    
    @objc private func zoomSegmentClicked(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? zoomOut(sender) : zoomIn(sender)
    }

    private func apply(_ mode: ZoomMode) {
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
        case .pixels(let n): encoded = "pixels:\(n)"
        }
        UserDefaults.standard.set(encoded, forKey: zoomKey)
    }
    static func savedZoom() -> ZoomMode {
        switch UserDefaults.standard.string(forKey: zoomKey) {
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
        let steps = ZoomMode.steps
        let current = deviceVC.screen.pixelMultiple
        let next = direction > 0
            ? steps.first { CGFloat($0) > current + 0.001 } ?? steps.last!
            : steps.last { CGFloat($0) < current - 0.001 } ?? steps.first!
        apply(.pixels(next))
    }

    @objc func zoomIn(_ sender: Any?)  { stepZoom(1) }
    @objc func zoomOut(_ sender: Any?) { stepZoom(-1) }
    @objc func zoomActualSize(_ sender: Any?) { apply(.pixels(1)) }
    @objc func zoomToFit(_ sender: Any?) { apply(.fit) }
    
    // MARK: - Device menu actions (routed via the responder chain)
    
    @objc func deviceHome(_ sender: Any?)        { emulator.pressHome() }
    @objc func deviceLock(_ sender: Any?) {
        if emulator.isPoweredOff { emulator.powerOn() } else { emulator.pressLock() }
    }
    @objc func deviceVolumeUp(_ sender: Any?)    { emulator.pressVolumeUp() }
    @objc func deviceVolumeDown(_ sender: Any?)  { emulator.pressVolumeDown() }
    @objc func deviceRotate(_ sender: Any?) {
        emulator.toggleRotation()
        syncRotateSymbol()
    }

    @objc func configureWebProxy(_ sender: Any?) {
        guard let window else { return }
        let current = emulator.webProxy
        let alert = NSAlert()
        alert.messageText = "HTTP Proxy"
        alert.informativeText = "Direct HTTP uses your Mac’s internet connection. For WaybackProxy, start its server and enter its address below (usually 127.0.0.1:8888). Configure the archive date in WaybackProxy. Changes apply when the device is awake and ready."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let mode = NSPopUpButton(frame: .zero, pullsDown: false)
        mode.addItems(withTitles: WebProxyConfiguration.Mode.allCases.map(\.title))
        mode.selectItem(at: WebProxyConfiguration.Mode.allCases.firstIndex(of: current.mode) ?? 0)
        let host = NSTextField(string: current.host)
        let port = NSTextField(string: String(current.port))
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Mode"), mode],
            [NSTextField(labelWithString: "External host"), host],
            [NSTextField(labelWithString: "Port"), port],
            [NSTextField(labelWithString: "Status"), NSTextField(wrappingLabelWithString: emulator.webProxyStatus)]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 280
        grid.rowSpacing = 10
        grid.frame.size = grid.fittingSize
        alert.accessoryView = grid
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            var value = current
            value.mode = WebProxyConfiguration.Mode.allCases[mode.indexOfSelectedItem]
            value.host = host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            value.port = Int(port.stringValue) ?? 0
            do { try self.emulator.configureWebProxy(value) }
            catch {
                let failure = NSAlert(error: error)
                failure.beginSheetModal(for: window)
            }
        }
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
        emulator.rotate(clockwise: false)
        syncRotateSymbol()
    }

    @objc func deviceRotateRight(_ sender: Any?) {
        emulator.rotate(clockwise: true)
        syncRotateSymbol()
    }

    /// The symbol always shows which way the *next* toolbar press will rotate.
    private func syncRotateSymbol() {
        rotateItem?.image = NSImage(systemSymbolName: rotateSymbolName, accessibilityDescription: "Rotate")
    }

    private var rotateSymbolName: String { emulator.isLandscape ? "rotate.right" : "rotate.left" }
    @objc func deviceShake(_ sender: Any?)       { emulator.shake() }
    @objc func devicePause(_ sender: Any?)       { emulator.pause() }
    @objc func deviceResume(_ sender: Any?)      { emulator.resume() }
    @objc func deviceReset(_ sender: Any?) {
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
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.emulator.reset()
        }
    }
    @objc func devicePowerOff(_ sender: Any?) {
        emulator.powerOff { [weak self] confirmed in
            guard !confirmed, let self, let window = self.window else { return }
            let alert = NSAlert()
            alert.messageText = "The device did not finish powering off"
            alert.informativeText = "Guest shutdown could not be confirmed. The window remains open so you can retry or restart the device."
            alert.beginSheetModal(for: window) { _ in }
        }
    }

    @objc func saveStateNow(_ sender: Any?) {
        emulator.onSnapshotResult = { [weak self] ok in
            guard !ok, let window = self?.window else { return }
            // Not just "it failed": the unhealthy-guest path also throws away
            // the snapshot that was already there, because it no longer matches
            // the device's storage. Saying nothing meant the user found out at
            // the next launch, as an unexplained cold boot.
            let alert = NSAlert()
            alert.messageText = "Couldn't save the device's state"
            alert.informativeText = "The device isn't responding, so its state could not be "
                + "captured. Any previously saved state has been set aside as well, because it "
                + "no longer matches what is on the device's storage — the next launch will "
                + "start the device fresh."
            alert.beginSheetModal(for: window) { _ in }
        }
        emulator.saveSnapshotNow()
    }
    @objc func discardSavedState(_ sender: Any?) {
        emulator.discardSavedStateByUser()
        let alert = NSAlert()
        alert.messageText = "Saved state discarded"
        alert.informativeText = "The next launch will cold-boot the device. The device's own data is untouched."
        alert.beginSheetModal(for: window!) { _ in }
    }

    /// Factory-reset the device — the "nuke everything" button. Wipes the NAND
    /// overlay (all installed apps + settings) and any snapshot, back to the
    /// base image, then relaunches. The base image is never touched.
    @objc func eraseDevice(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Erase all content and settings?"
        alert.informativeText = "This wipes everything on the device — installed apps, settings, saved state — back to a clean iOS 3.1.3. LightTouchMac quits now and erases the device the next time you open it. This cannot be undone."
        alert.addButton(withTitle: "Erase")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.emulator.requestFactoryReset()
        }
    }
    
    @objc func installApp(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        panel.message = "Choose one or more decrypted .ipa files to install."
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK else { return }
            for url in panel.urls {
                AppInstaller.start(url, with: self.emulator, presenting: self.window)
            }
        }
    }
    
    /// Respring — the quick fix for a freshly sideloaded app that crashes on
    /// launch until the device is restarted.
    @objc func restartSpringBoard(_ sender: Any?) {
        Task {
            do {
                try await emulator.restartSpringBoard()
            } catch {
                AppInstaller.presentError(error, in: window)
            }
        }
    }

    @objc func openDeviceTerminal(_ sender: Any?) {
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
    
    @objc func saveScreenshot(_ sender: Any?) {
        guard let window, let image = deviceVC.screen.captureFrame(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = captureName("Screenshot") + ".png"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) }
            catch { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    private func captureName(_ kind: String) -> String {
        let date = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        return "Light Touch \(kind) \(date)"
    }

    @objc func showLiveText(_ sender: Any?) {
        guard let cg = deviceVC.screen.captureFrame(includeTouches: false) else { return }
        liveTextWindow?.close()
        let controller = LiveTextWindowController(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
        liveTextWindow = controller
        controller.showWindow(nil)
    }

    @objc func toggleTouchOverlay(_ sender: Any?) { deviceVC.screen.showsTouches.toggle() }

    @objc func toggleRecording(_ sender: Any?) {
        if recordingOutput != nil { stopRecording(sender); return }
        guard !finishingRecording, let window else { return }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        recordingOutput = output
        recordingFailure = nil
        NSApp.dockTile.badgeLabel = "REC"
        let indicator = NSTitlebarAccessoryViewController()
        let label = NSTextField(labelWithString: "● Recording")
        label.textColor = .systemRed
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.frame = CGRect(x: 0, y: 0, width: 145, height: 22)
        indicator.view = label
        indicator.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(indicator)
        recordingIndicator = indicator
        recordingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await movieWriter.start(url: output)
                recordingStartedAt = CACurrentMediaTime()
                while !Task.isCancelled {
                    let elapsed = Int(CACurrentMediaTime() - recordingStartedAt)
                    if let label = recordingIndicator?.view as? NSTextField {
                        let seconds = String(elapsed % 60)
                        label.stringValue = "● \(elapsed / 60):\(seconds.count == 1 ? "0" : "")\(seconds)"
                    }
                    if let image = deviceVC.screen.captureFrame() {
                        try await movieWriter.append(image, seconds: CACurrentMediaTime() - recordingStartedAt)
                    }
                    try await Task.sleep(for: .milliseconds(33))
                }
            } catch is CancellationError {
                // Stop waits for this task before finishing the writer.
            } catch {
                recordingFailure = error
                stopRecording(nil)
            }
        }
        window.makeFirstResponder(deviceVC.screen)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !finishRecordingBeforeQuit()
    }

    func finishRecordingBeforeQuit() -> Bool {
        guard recordingOutput != nil else { return false }
        quitAfterRecording = true
        stopRecording(nil)
        return true
    }

    @objc private func stopRecording(_ sender: Any?) {
        guard let output = recordingOutput, !finishingRecording else { return }
        finishingRecording = true
        let producer = recordingTask
        producer?.cancel()
        NSApp.dockTile.badgeLabel = nil
        if let window, let indicator = recordingIndicator,
           let index = window.titlebarAccessoryViewControllers.firstIndex(of: indicator) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
        recordingIndicator = nil
        Task { [weak self] in
            guard let self else { return }
            await producer?.value
            defer {
                recordingOutput = nil
                recordingTask = nil
                finishingRecording = false
                if quitAfterRecording {
                    quitAfterRecording = false
                    NSApp.terminate(nil)
                }
            }
            do {
                try await movieWriter.finish(seconds: max(CACurrentMediaTime() - recordingStartedAt, 0.034))
                if let recordingFailure { throw recordingFailure }
                guard let window else { return }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.quickTimeMovie]
                panel.nameFieldStringValue = captureName("Recording") + ".mov"
                panel.message = "Device video at native resolution on a 480 × 480 canvas. Audio is not included."
                let response = await panel.beginSheetModal(for: window)
                if response != .OK { quitAfterRecording = false }
                if response == .OK, let destination = panel.url {
                    // Copy into the destination volume, then atomically replace
                    // any existing file only after the complete copy succeeds.
                    let staged = destination.deletingLastPathComponent().appendingPathComponent(".ltm-" + UUID().uuidString + ".mov")
                    defer { try? FileManager.default.removeItem(at: staged) }
                    try FileManager.default.copyItem(at: output, to: staged)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
                    } else { try FileManager.default.moveItem(at: staged, to: destination) }
                }
                try? FileManager.default.removeItem(at: output)
            } catch {
                quitAfterRecording = false
                if let window {
                    let alert = NSAlert(error: error)
                    alert.informativeText += "\nRecording recovery file: \(output.path)"
                    await alert.beginSheetModal(for: window)
                }
            }
        }
    }

    @objc func copyScreen(_ sender: Any?) {
        // Capture owns its pixels before handing the image to the pasteboard.
        Task {
            guard let image = await deviceVC.screen.screenImage else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
        }
    }
    
    @objc func pasteToGuest(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        emulator.pasteToGuest(text)
    }

    // MARK: - Diagnostics

    /// Bundle the logs + provenance into a zip for a bug report. The logs are
    /// where the last two nights' failures were finally diagnosed; making them
    /// one click to collect means the next report arrives with its evidence.
    @objc func exportDiagnostics(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "LightTouchMac-diagnostics.zip"
        if let zip = UTType(filenameExtension: "zip") { panel.allowedContentTypes = [zip] }
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let dest = panel.url else { return }
            self.writeDiagnostics(to: dest)
        }
    }

    private func writeDiagnostics(to dest: URL) {
        let fm = FileManager.default
        let staging = Bundled.stateDirectory.appendingPathComponent("diagnostics-staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)

        // Logs from both writers.
        let logs = [
            Bundled.stateDirectory.appendingPathComponent("serial.log"),
            Bundled.stateDirectory.appendingPathComponent("serial.log.1"),
            Bundled.workDirectory.appendingPathComponent("usbmuxd.log"),
            Bundled.workDirectory.appendingPathComponent("usbmuxd.log.1"),
            Bundled.workDirectory.appendingPathComponent("session.env"),
        ]
        for src in logs where fm.fileExists(atPath: src.path) {
            try? fm.copyItem(at: src, to: staging.appendingPathComponent(src.lastPathComponent))
        }

        let info = """
        LightTouchMac diagnostics
        \(emulator.dylibProvenance)
        state: \(emulator.statusLine)
        files-root: \(emulator.options.filesRoot)
        nand: \(emulator.options.nand)
        appsync: \(emulator.options.appsync)   network: \(emulator.options.network)
        canManageApps: \(emulator.canManageApps)
        """
        try? info.write(to: staging.appendingPathComponent("info.txt"), atomically: true, encoding: .utf8)

        // ditto zips the staging dir. Off the main thread: waitUntilExit blocks
        // its caller by contract, and this runs from the save panel's completion
        // handler — i.e. on the main thread, freezing the device screen and the
        // whole window for as long as zipping two rotated serial logs takes.
        Task.detached {
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent",
                               staging.path, dest.path]
            try? ditto.run()
            ditto.waitUntilExit()
            try? FileManager.default.removeItem(at: staging)
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
        }
    }
}

// MARK: - Toolbar item validation (same command model as the menus)

extension MainWindowController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        // Install is NOT gated on isInstalling: AppInstaller queues jobs behind
        // one another, so choosing a second .ipa mid-install is supported and
        // blocking it was a regression. The terminal is gated, because it opens
        // a competing lockdown session.
        case .installApp:
            return emulator.canQueueInstall
        case .openTerminal:
            return emulator.canReachDevice && !emulator.isInstalling
        case .lock:
            item.label = emulator.isPoweredOff ? "Power On" : "Lock"
            item.image = NSImage(systemSymbolName: emulator.isPoweredOff ? "power" : "lock", accessibilityDescription: item.label)
            return emulator.acceptsInput || (emulator.isPoweredOff && !emulator.shuttingDown)
        case .home, .rotate:
            return emulator.acceptsInput
        default:
            return !emulator.isDead
        }
    }
}

// MARK: - Menu validation (enablement + checkmarks)

extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        // App management: needs USB, a live guest, and no install already running
        // (the guest serves ~one lockdown session).
        case #selector(installApp(_:)):
            return emulator.canQueueInstall
        case #selector(openDeviceTerminal(_:)), #selector(restartSpringBoard(_:)):
            return emulator.canReachDevice && !emulator.isInstalling
        // Device input only reaches a running guest.
        case #selector(deviceLock(_:)):
            menuItem.title = emulator.isPoweredOff ? "Power On" : "Lock"
            return emulator.acceptsInput || (emulator.isPoweredOff && !emulator.shuttingDown)
        case #selector(deviceHome(_:)),
             #selector(deviceRotate(_:)), #selector(deviceRotateLeft(_:)),
             #selector(deviceRotateRight(_:)), #selector(deviceShake(_:)):
            return emulator.acceptsInput
        case #selector(configureWebProxy(_:)):
            return emulator.webProxyAvailable
        case #selector(toggleVerboseBoot(_:)):
            menuItem.state = EmulatorController.verboseBoot ? .on : .off
            return true
        case #selector(toggleKernelConsole(_:)):
            menuItem.state = EmulatorController.kernelConsole ? .on : .off
            return true
        case #selector(devicePowerOff(_:)): return emulator.acceptsInput && !emulator.isInstalling && !AppInstaller.hasPendingWork
        case #selector(deviceReset(_:)):  return !emulator.isDead
        case #selector(saveStateNow(_:)): return emulator.isRunning
        case #selector(discardSavedState(_:)): return emulator.hasSavedState
        case #selector(eraseDevice(_:)): return !emulator.isDead
        case #selector(toggleRecording(_:)):
            menuItem.title = recordingOutput == nil ? "Start Recording" : "Stop Recording…"
            menuItem.state = recordingOutput == nil ? .off : .on
            return !finishingRecording && (recordingOutput != nil || emulator.isRunning)
        case #selector(toggleTouchOverlay(_:)):
            menuItem.state = deviceVC.screen.showsTouches ? .on : .off
            return true
        case #selector(showLiveText(_:)), #selector(saveScreenshot(_:)), #selector(copyScreen(_:)):
            return !emulator.isPoweredOff && !emulator.isDead
        case #selector(pasteToGuest(_:)):
            return emulator.acceptsInput && NSPasteboard.general.string(forType: .string) != nil
        case #selector(zoomIn(_:)):
            return zoom.percent.map { $0 / 100 } ?? 0 < ZoomMode.steps.last!
        case #selector(zoomOut(_:)):
            return zoom != .pixels(ZoomMode.steps[0])
        case #selector(zoomActualSize(_:)):
            menuItem.state = (zoom == .pixels(1)) ? .on : .off
            return true
        case #selector(zoomToFit(_:)):
            menuItem.state = (zoom == .fit) ? .on : .off
            return true
        case #selector(toggleAppInspector(_:)):
            menuItem.title = inspectorItem.isCollapsed ? "Show Inspector" : "Hide Inspector"
            return true
        default:
            return true
        }
    }
}
