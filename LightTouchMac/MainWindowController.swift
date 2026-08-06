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
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
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

    /// Where the green button sends the window.
    ///
    /// Hold Option and it means "fit the device": the pane sized exactly to the
    /// shell at the current zoom, plus the inspector if it is showing, so there
    /// is no letterboxing on any side. Without Option it is the usual zoom, so
    /// the standard behaviour is untouched.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        guard NSEvent.modifierFlags.contains(.option) else { return defaultFrame }

        var content = deviceVC.screen.idealPaneSize
        if !inspectorItem.isCollapsed {
            content.width += inspectorVC.view.frame.width
        }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        // Grow down-and-right from the current top-left, the direction AppKit
        // zooms in, and stay on screen.
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let visible = window.screen?.visibleFrame {
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        return frame
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func windowDidLoad() {
        super.windowDidLoad()
        // Only center on first run. setFrameAutosaveName already restored a
        // saved frame; centering unconditionally threw that away every launch.
        if window?.setFrameUsingName("Main") != true { window?.center() }
        apply(Self.savedZoom())   // restore the zoom the user left it at
    }

    // MARK: - Health / status surfacing

    private func refreshForState() {
        // The window subtitle is where AppKit puts secondary window state, and
        // it styles and truncates itself to match the title. A custom titlebar
        // accessory was carrying this before — more code, its own constraints,
        // and it competed with the toolbar for space.
        window?.subtitle = emulator.statusLine
        window?.toolbar?.validateVisibleItems()
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
    
    // MARK: - Toolbar
    
    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .home:
            return button(id, "Home", "house", #selector(deviceHome(_:)), "Press the Home button")
        case .lock:
            return button(id, "Lock", "lock", #selector(deviceLock(_:)), "Lock or wake the device")
        case .rotate:
            let item = button(id, "Rotate", rotateSymbolName, #selector(deviceRotate(_:)), "Rotate between portrait and landscape")
            rotateItem = item
            return item
        case .installApp:
            return button(id, "Install App", "square.and.arrow.down", #selector(installApp(_:)), "Install a decrypted .ipa")
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
         .flexibleSpace, .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.home, .lock, .rotate, .zoom, .installApp, .openTerminal,
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
        case .physical: encoded = "physical"
        case .pixels(let n): encoded = "pixels:\(n)"
        }
        UserDefaults.standard.set(encoded, forKey: zoomKey)
    }
    static func savedZoom() -> ZoomMode {
        switch UserDefaults.standard.string(forKey: zoomKey) {
        case "physical": return .physical
        case let s? where s.hasPrefix("pixels:"):
            return Int(s.dropFirst("pixels:".count)).map(ZoomMode.pixels) ?? .fit
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
        let current = zoom.percent.map { $0 / 100 } ?? deviceVC.screen.nearestPixelStep
        let index = steps.firstIndex(of: current)
            ?? steps.firstIndex { $0 >= current }
            ?? steps.count - 1
        apply(.pixels(steps[min(max(index + direction, 0), steps.count - 1)]))
    }

    @objc func zoomIn(_ sender: Any?)  { stepZoom(1) }
    @objc func zoomOut(_ sender: Any?) { stepZoom(-1) }
    /// Life size — the device as it measures in the hand, not 1:1 pixels. 100%
    /// is a pixel count and lands wherever the display's density puts it, which
    /// on a Retina Mac is noticeably smaller than the real thing (163 ppi of
    /// original screen against roughly 220 of display).
    @objc func zoomActualSize(_ sender: Any?) { apply(.physical) }
    @objc func zoomToFit(_ sender: Any?) { apply(.fit) }
    
    // MARK: - Device menu actions (routed via the responder chain)
    
    @objc func deviceHome(_ sender: Any?)        { emulator.pressHome() }
    @objc func deviceLock(_ sender: Any?)        { emulator.pressLock() }
    @objc func deviceVolumeUp(_ sender: Any?)    { emulator.pressVolumeUp() }
    @objc func deviceVolumeDown(_ sender: Any?)  { emulator.pressVolumeDown() }
    @objc func deviceRotate(_ sender: Any?) {
        emulator.toggleRotation()
        syncRotateSymbol()
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
    @objc func deviceReset(_ sender: Any?)       { emulator.reset() }
    // No devicePowerDown: system_powerdown never completes on 3.1.3 (PMU gap),
    // so a menu item for it is a trap that wedges the guest at 100% CPU.
    @objc func saveStateNow(_ sender: Any?) { emulator.saveSnapshotNow() }
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
        alert.informativeText = "This wipes everything on the device — installed apps, settings, saved state — back to a clean iOS 3.1.3, and relaunches the app. This cannot be undone."
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
    
    @objc func copyScreen(_ sender: Any?) {
        guard let image = deviceVC.screen.screenImage else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
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

        // ditto zips the staging dir; a host one-shot, so plain Process is fine.
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, dest.path]
        try? ditto.run()
        ditto.waitUntilExit()
        try? fm.removeItem(at: staging)
        NSWorkspace.shared.activateFileViewerSelecting([dest])
    }
}

// MARK: - Toolbar item validation (same command model as the menus)

extension MainWindowController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .installApp, .openTerminal:
            return emulator.canManageApps && emulator.isRunning && !emulator.isInstalling
        case .home, .lock, .rotate:
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
        case #selector(installApp(_:)), #selector(openDeviceTerminal(_:)),
             #selector(restartSpringBoard(_:)):
            return emulator.canManageApps && emulator.isRunning && !emulator.isInstalling
        // Device input only reaches a running guest.
        case #selector(deviceHome(_:)), #selector(deviceLock(_:)),
             #selector(deviceRotate(_:)), #selector(deviceRotateLeft(_:)),
             #selector(deviceRotateRight(_:)), #selector(deviceShake(_:)):
            return emulator.acceptsInput
        case #selector(deviceReset(_:)):  return !emulator.isDead
        case #selector(saveStateNow(_:)): return emulator.isRunning
        case #selector(discardSavedState(_:)): return emulator.hasSavedState
        case #selector(eraseDevice(_:)): return !emulator.isDead
        case #selector(copyScreen(_:)):   return !emulator.isDead
        case #selector(pasteToGuest(_:)):
            return emulator.acceptsInput && NSPasteboard.general.string(forType: .string) != nil
        case #selector(zoomIn(_:)):
            return zoom.percent.map { $0 / 100 } ?? 0 < ZoomMode.steps.last!
        case #selector(zoomOut(_:)):
            return zoom != .pixels(ZoomMode.steps[0])
        case #selector(zoomActualSize(_:)):
            menuItem.state = (zoom == .physical) ? .on : .off
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
