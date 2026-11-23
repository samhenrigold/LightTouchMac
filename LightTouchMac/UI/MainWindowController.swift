// The device window: device centered in the main column, an app-management
// inspector on the trailing edge, and a toolbar whose items mirror the menu bar
// (same selectors, same validation). Menu actions route here through the
// responder chain (the window controller is the window's next responder).

import Cocoa
import FirmwareSchema
import HostRuntime
import HostServiceWire
import LightTouchCore
import SwiftUI
import UniformTypeIdentifiers

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate, DeviceLibraryDelegate {
    let host: DeviceSessionHost
    /// The selected row's session, when it has one: always the host's current one, never a copy. Every device
    /// command, validation and toolbar item follows it.
    var session: DeviceSession? { selectedEntry.flatMap(host.session(for:)) }
    /// The session whose workspace is in the window; show() swaps it when `session` changes.
    var attachedSession: DeviceSession?
    var selectedEntry: FirmwareCatalog.Entry?
    /// The selected device's own directory and board, running or not (nil before it is prepared).
    var selectedInstance: DeviceInstance? { selectedEntry.flatMap(host.instance(for:)) }
    var emulator: EmulatorController? { session?.emulator }
    var deviceVC: DeviceViewController? { session?.workspace.deviceVC }
    var inspectorVC: AppsInspectorViewController? { session?.workspace.inspectorVC }
    /// The board the menus, Files window and capture options were made for.
    var currentProfile: Board
    let library: DeviceLibraryViewController
    let placeholder = DevicePlaceholderViewController()
    /// The detail area with no row selected.
    let nothingSelected = ContainerViewController()
    /// With several rows selected (for one Delete): how many, and nothing starts.
    let multipleSelected = PaneLabelViewController()
    let detail = ContainerViewController()
    /// The device pane over its console (ConsoleSplit.swift).
    let console: ConsoleSplitViewController
    let inspectorContainer = ContainerViewController()
    let noInspector = PaneLabelViewController()
    private let sidebarItem: NSSplitViewItem
    let inspectorItem: NSSplitViewItem
    var deadOverlay: NSView?
    var filesWindow: DeviceFilesWindowController?
    weak var proxySettingsEditor: ProxySettingsView?
    var filesVC: DeviceFilesViewController? { filesWindow?.browser }
    // nonisolated(unsafe): set on the main actor; deinit reads it again only after the last use.
    nonisolated(unsafe) private var modifierMonitor: Any?
    /// Screenshots, recordings and their banner (CaptureController).
    let capture = CaptureController()
    var recording: ScreenRecordingSession { capture.recording }
    var capturePreferences: CapturePreferences { capture.capturePreferences }
    var settingsWindow: SettingsWindowController?
    var storageUsage: StorageUsage?
    var canTakeScreenshot: Bool { capture.canTakeScreenshot }
    var canToggleRecording: Bool { capture.canToggleRecording }
    let fileStatus = CaptureStatusView()
    /// A phone's browser as the selected device (PhoneRemoteController).
    let phoneRemote = PhoneRemoteController()
    var hasFileTransfer: Bool { filesVC?.hasTransfer == true }
    func cancelFileTransfer() { filesVC?.cancelTransfer() }

    /// Today's device area, before the sidebar: 720×640 for the iPod and
    /// 1100×760 for the iPad (device plus inspector), plus the console bar.
    /// Wide enough that the toolbar's sidebar section holds its toggle and + beside the window buttons.
    private static let sidebarWidth: CGFloat = 260
    /// The narrowest the panes' own content goes; fitPanesToToolbar raises each to what its toolbar section needs.
    static let sidebarFloor: CGFloat = 180
    static let inspectorFloor: CGFloat = 280
    static func contentSize(for profile: Board) -> NSSize {
        let device = profile == .k48 ? NSSize(width: 1100, height: 760) : NSSize(width: 720, height: 640)
        return NSSize(width: device.width + sidebarWidth, height: device.height + ConsoleBar.height)
    }
    /// Cleared once the user resizes; until then switching devices resizes to fit.
    var sizedToDevice = true
    /// A fit of the panes to the toolbar is queued (fitPanesToToolbarLater).
    var paneFitPending = false

    init(host: DeviceSessionHost, profile: Board) {
        self.host = host
        currentProfile = profile
        library = DeviceLibraryViewController(host: host)

        let split = NSSplitViewController()
        sidebarItem = NSSplitViewItem(sidebarWithViewController: library)
        sidebarItem.minimumThickness = Self.sidebarFloor
        sidebarItem.maximumThickness = 320
        // The split opens the sidebar at its view's width.
        library.view.setFrameSize(NSSize(width: Self.sidebarWidth, height: library.view.frame.height))
        split.addSplitViewItem(sidebarItem)

        console = ConsoleSplitViewController(top: detail, autosaveName: "main")
        let deviceItem = NSSplitViewItem(viewController: console)
        deviceItem.minimumThickness = 320
        split.addSplitViewItem(deviceItem)

        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorContainer)
        // The widths the sidebar guidelines ask for: enough for an app name at a
        // readable size, not so much that it competes with the device.
        inspectorItem.minimumThickness = Self.inspectorFloor
        inspectorItem.maximumThickness = 400

        split.addSplitViewItem(inspectorItem)
        // The sidebar's width and the inspector's, and whether each is shown, as the user left them.
        split.splitView.autosaveName = "Main"

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
        // Panes come and go with the selection; Tab follows whatever is there now.
        window.autorecalculatesKeyViewLoop = true
        // The frame is remembered (HIG: reopen where the user left it); a saved size is the user's, not the device's.
        let restored = WindowRestorationPolicy.configure(window, frameAutosaveName: "Main")
        if !restored { window.center() }
        super.init(window: window)
        sizedToDevice = !restored
        library.delegate = self
        library.onAdd = { [weak self] in self?.addDevice(nil) }
        placeholder.onAction = { [weak self] action in
            guard let self, let entry = selectedEntry else { return }
            perform(action, for: entry)
        }
        placeholder.onShowLog = { [weak self] in self?.showDeviceLogs(nil) }
        placeholder.skipsSetup = (
            { FirmwareJobs.shared.skipsSetup.contains($0) },
            { id, on in
                if on { FirmwareJobs.shared.skipsSetup.insert(id) } else { FirmwareJobs.shared.skipsSetup.remove(id) }
            }
        )
        placeholder.jailbreaks = (
            { FirmwareJobs.shared.jailbreaks($0) },
            { FirmwareJobs.shared.setJailbreaks($0, $1) }
        )
        placeholder.onDropIPSW = { [weak self] urls in self?.handOffIPSWs(urls, for: self?.selectedEntry) }
        // The device keeps its screen, chassis and buttons where they reach under the collapsed console strip.
        console.split.bar.paneTakesPress = { [weak self] point in
            self?.attachedSession?.workspace.deviceVC.screen.takesPress(atWindowPoint: point) ?? false
        }
        showDetail(placeholder)
        noInspector.shortName = profile.shortName
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
        migrateAddDeviceToolbar(toolbar)
        fitPanesToToolbar()

        window.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preparationDidPublish(_:)),
            name: FirmwareJobs.didPublishNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(filesystemActivityDidChange),
            name: DeviceFilesystemEdits.didChangeNotification,
            object: nil
        )
        capture.window = window
        capture.session = { [weak self] in self?.session }
        capture.onChange = { [weak self] in self?.validateCaptureToolbar() }
        capture.terminate = { AppDelegate.requestTermination() }
        phoneRemote.window = window
        DeviceFilesystemEdits.shared.onUncleanShutdown = { [weak self] entry in self?.offerShutDownFirst(entry) }
        CaptureNotifications.shared.onShowDevice = { [weak self] id in
            guard let self, let entry = host.catalog.entry(id: id) else { return }
            showWindow(nil)
            library.select(entry)
        }
        installFileStatus()
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.syncRotationControls(optionPressed: event.modifierFlags.contains(.option))
            return event
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshRotationModifiers),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        refreshForState()
    }

    var captureStatus: CaptureStatusView { capture.captureStatus }
    let startupStatus = CaptureStatusView()
    var startupTask: Task<Void, Never>?

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
    }

    // MARK: - Library and selection
    /// The selected device's state, tracked: whatever refreshForState reads of it (the subtitle's status line,
    /// the notice, the startup toast, the toolbar's validation, the dead overlay) refreshes the window when it
    /// changes. Re-armed on every show(), so it follows the selected session.
    var stateTracking: ObservationLoop?

    // MARK: - Health / status surfacing
    var noticeAccessory: DeviceNoticeViewController?

    // MARK: - Device menu actions (routed via the responder chain)
    /// Device ▸ Carrier…: the running iPhone's fake network, calls and SMS (CarrierPanel), one window per device.
    var carrierWindows: [UUID: CarrierWindowController] = [:]
    /// Device ▸ Tweaks…: a device's hidden switches (TweaksPanel), one window per device, running or stopped.
    var tweaksWindows: [UUID: TweaksWindowController] = [:]

    // MARK: - Diagnostics
    /// Bundle the logs + provenance into a zip for a bug report. The logs are
    /// where the last two nights' failures were finally diagnosed; making them
    /// one click to collect means the next report arrives with its evidence.
    var logWindow: LogWindowController?
    var logInstance: UUID?
}

// MARK: - Split-view panes

/// A split-view pane whose content changes with the selection. The split
/// items stay put, so the tracking separators and collapse state do too.
final class ContainerViewController: NSViewController {
    override func loadView() { view = NSView() }

    func show(_ child: NSViewController) {
        guard children.first !== child else { return }
        for old in children {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}

/// A pane's one centered line: the inspector while the device isn't running, the detail area with several rows selected.
final class PaneLabelViewController: NSViewController {
    let label = NSTextField(labelWithString: "")
    var text = "" { didSet { label.stringValue = text } }
    var shortName = "device" { didSet { update() } }
    /// False for a device with no apps to manage (Entry.managesApps: iPhone OS 1 has no installation service), where
    /// it says nothing.
    var managesApps = true { didSet { update() } }
    func update() { text = managesApps ? "Start the \(shortName) to manage apps." : "" }

    override func loadView() {
        label.stringValue = text
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        view = NSView()
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
}
