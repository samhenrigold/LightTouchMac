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

final class MainWindowController: NSWindowController, NSToolbarDelegate {
    
    private let emulator: EmulatorController
    private let deviceVC: DeviceViewController
    private let inspectorVC: AppsInspectorViewController
    private let inspectorItem: NSSplitViewItem
    private let zoomButton = NSButton()
    private var rotateItem: NSToolbarItem?
    private(set) var scaleMode: ScaleMode = .zoomed
    
    init(emulator: EmulatorController) {
        self.emulator = emulator
        self.deviceVC = DeviceViewController(emulator: emulator)
        self.inspectorVC = AppsInspectorViewController(emulator: emulator)
        
        let split = NSSplitViewController()
        let deviceItem = NSSplitViewItem(viewController: deviceVC)
        deviceItem.minimumThickness = 200
        split.addSplitViewItem(deviceItem)
        
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorVC)
        inspectorItem.minimumThickness = 220
        inspectorItem.maximumThickness = 360
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
        
        // Zoom is a single on/off toggle: on = zoomed to fill, off = physical size.
        zoomButton.title = ""
        zoomButton.imagePosition = .imageOnly
        zoomButton.setButtonType(.pushOnPushOff)
        zoomButton.bezelStyle = .toolbar
        zoomButton.image = NSImage(systemSymbolName: "plus.magnifyingglass",
                                   accessibilityDescription: "Zoom to Fill")
        zoomButton.state = (scaleMode == .zoomed) ? .on : .off
        zoomButton.target = self
        zoomButton.action = #selector(toggleZoom(_:))
    }
    
    required init?(coder: NSCoder) { fatalError("not used") }
    
    override func windowDidLoad() {
        super.windowDidLoad()
        window?.center()
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
            let item = button(id, "Rotate", rotateSymbolName, #selector(deviceRotate(_:)),
                              "Rotate between portrait and landscape")
            rotateItem = item
            return item
        case .installApp:
            return button(id, "Install App", "square.and.arrow.down", #selector(installApp(_:)),
                          "Install a decrypted .ipa")
        case .openTerminal:
            return button(id, "Terminal", "terminal", #selector(openDeviceTerminal(_:)),
                          "Open a root shell on the device")
        case .zoom:
            let item = NSToolbarItem(itemIdentifier: .zoom)
            item.label = "Zoom"
            item.paletteLabel = "Zoom"
            item.toolTip = "Zoom the device to fill, or show it at its real physical size"
            item.view = zoomButton
            return item
        default:
            return nil          // space / flexibleSpace / toggleInspector are system-made
        }
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
    
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.home, .flexibleSpace, .lock, .flexibleSpace, .rotate, .zoom]
    }
    
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.home, .lock, .rotate, .zoom, .installApp, .openTerminal, .space, .flexibleSpace, .toggleInspector]
    }
    
    // MARK: - Zoom (single source of truth for the toggle, menu, and view)
    
    @objc private func toggleZoom(_ sender: Any?) {
        applyScaleMode(scaleMode == .zoomed ? .actual : .zoomed)
    }
    
    private func applyScaleMode(_ mode: ScaleMode) {
        scaleMode = mode
        deviceVC.setScaleMode(mode)
        zoomButton.state = (mode == .zoomed) ? .on : .off
    }
    
    // MARK: - Device menu actions (routed via the responder chain)
    
    @objc func deviceHome(_ sender: Any?)        { emulator.pressHome() }
    @objc func deviceLock(_ sender: Any?)        { emulator.pressLock() }
    @objc func deviceVolumeUp(_ sender: Any?)    { emulator.pressVolumeUp() }
    @objc func deviceVolumeDown(_ sender: Any?)  { emulator.pressVolumeDown() }
    @objc func deviceRotate(_ sender: Any?) {
        emulator.toggleRotation()
        // Symbol always shows which way the *next* press will rotate.
        rotateItem?.image = NSImage(systemSymbolName: rotateSymbolName, accessibilityDescription: "Rotate")
    }

    private var rotateSymbolName: String { emulator.isLandscape ? "rotate.left" : "rotate.right" }
    @objc func deviceShake(_ sender: Any?)       { emulator.shake() }
    @objc func devicePause(_ sender: Any?)       { emulator.pause() }
    @objc func deviceResume(_ sender: Any?)      { emulator.resume() }
    @objc func deviceReset(_ sender: Any?)       { emulator.reset() }
    @objc func devicePowerDown(_ sender: Any?)   { emulator.powerDown() }
    
    @objc func installApp(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.message = "Choose a decrypted .ipa to install."
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            Task { await AppInstaller.install(url, with: self.emulator, presenting: self.window) }
        }
    }
    
    @objc func openDeviceTerminal(_ sender: Any?) {
        Task {
            do { try await emulator.openTerminal() }
            catch { AppInstaller.presentError(error, in: window) }
        }
    }
    
    // MARK: - View menu (zoom + inspector), synced with the toolbar
    
    @objc func toggleZoomMenu(_ sender: Any?) {
        applyScaleMode(scaleMode == .zoomed ? .actual : .zoomed)
    }
    
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
}

// MARK: - Toolbar item validation (same command model as the menus)

extension MainWindowController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .installApp, .openTerminal: return emulator.canManageApps
        default: return true
        }
    }
}

// MARK: - Menu validation (enablement + checkmarks)

extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(installApp(_:)), #selector(openDeviceTerminal(_:)):
            return emulator.canManageApps
        case #selector(pasteToGuest(_:)):
            return NSPasteboard.general.string(forType: .string) != nil
        case #selector(toggleZoomMenu(_:)):
            menuItem.state = (scaleMode == .zoomed) ? .on : .off
            return true
        case #selector(toggleAppInspector(_:)):
            menuItem.title = inspectorItem.isCollapsed ? "Show Inspector" : "Hide Inspector"
            return true
        default:
            return true
        }
    }
}
