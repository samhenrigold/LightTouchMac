import Cocoa
import LightTouchCore
import SwiftUI

/// Settings…: one window, a toolbar button per pane, the window sized to the
/// pane and titled after it (HIG, "Settings"). Each pane is a grouped Form.
final class SettingsWindowController: NSWindowController {
    enum Pane: Int { case general, capture, storage }

    private let tabs = SettingsTabViewController()
    private let panes: [NSView]

    /// `storage` is measured again each time its pane is shown.
    init(general: some View, capture: some View, storage: StorageUsage) {
        let resize = SettingsResize()
        panes = [
            NSHostingView(rootView: general.settingsPane(resize)),
            NSHostingView(rootView: capture.settingsPane(resize)),
            NSHostingView(rootView: StorageSettingsView(model: storage).settingsPane(resize, maxHeight: 560))
        ]
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        for (view, (title, symbol)) in zip(
            panes,
            [("General", "gearshape"), ("Capture", "camera"), ("Storage", "internaldrive")]
        ) {
            let pane = NSViewController()
            pane.view = view
            pane.title = title
            let item = NSTabViewItem(viewController: pane)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        // Where it was left; each pane sizes it (fit).
        let restored = WindowRestorationPolicy.configure(window, frameAutosaveName: "Settings")
        super.init(window: window)
        resize.action = { [weak self] in self?.fit() }
        tabs.onSelect = { [weak self] in
            self?.fit()
            if self?.pane == .storage { storage.reload() }
        }
        storage.isShown = { [weak self] in self?.window?.isVisible == true && self?.pane == .storage }
        fit()
        if !restored { window.center() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var pane: Pane {
        get { Pane(rawValue: tabs.selectedTabViewItemIndex) ?? .general }
        set { tabs.selectedTabViewItemIndex = newValue.rawValue }
    }

    func view(for pane: Pane) -> NSView { panes[pane.rawValue] }

    /// The window takes the selected pane's size, keeping its top edge.
    private func fit() {
        guard let window else { return }
        let view = self.view(for: pane)
        view.layoutSubtreeIfNeeded()
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: view.fittingSize))
        guard frame.size != window.frame.size else { return }
        window.setFrame(
            NSRect(x: window.frame.minX, y: window.frame.maxY - frame.height, width: frame.width, height: frame.height),
            display: true,
            animate: window.isVisible
        )
    }
}

/// A pane's content changed height: the window refits.
final class SettingsResize {
    var action: (() -> Void)?
}

/// A Settings pane: a grouped Form at a fixed width and its whole height; one taller than `maxHeight` scrolls
/// inside that. The window is told when the height changes.
private struct SettingsPane<Content: View>: View {
    let content: Content
    let resize: SettingsResize
    var maxHeight: CGFloat = .infinity
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .formStyle(.grouped)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
        }
        .scrollDisabled(height <= maxHeight)
        .frame(width: 500, height: min(height, maxHeight))
        .onChange(of: height) {
            // After this layout pass, so the hosting view's fitting size is the new one.
            DispatchQueue.main.async { resize.action?() }
        }
    }
}

extension View {
    func settingsPane(_ resize: SettingsResize, maxHeight: CGFloat = .infinity) -> some View {
        SettingsPane(content: self, resize: resize, maxHeight: maxHeight)
    }
}

private final class SettingsTabViewController: NSTabViewController {
    var onSelect: (() -> Void)?
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSelect?()
    }
}

/// Settings ▸ General: what every device starts with.
struct GeneralSettingsView: View {
    /// Connect, Use Offline, or no saved answer (the device asks when it starts).
    @AppStorage(NetworkAccessPreference.key) private var internet: Bool?
    @AppStorage(VibrationSound.key) private var vibrationSound = true
    @AppStorage(DisplayRefresh.key) private var refresh120 = false
    @AppStorage(ANGLERenderer.key) private var angle = false
    @AppStorage(FirmwareJobs.withoutMountingKey) private var withoutMounting = false
    @AppStorage(ClipboardSync.key) private var shareClipboard = true
    @AppStorage(Analytics.key) private var shareReports = true

    var body: some View {
        Form {
            Picker("Connect to the internet…", selection: $internet) {
                Text("Always").tag(Bool?.some(true))
                Text("Never").tag(Bool?.some(false))
                Text("Ask When a Device Starts").tag(Bool?.none)
            }
            Toggle("Play vibration sound", isOn: $vibrationSound)
            Toggle("Share clipboard with devices", isOn: $shareClipboard)
            Toggle(isOn: $refresh120) {
                Text("120 Hz refresh (experimental)")
                Text("Takes effect when a device next starts. Games that count frames run too fast.")
            }
            Toggle(isOn: $angle) {
                Text("ANGLE renderer (experimental)")
                Text("Takes effect when a device next starts. Draws with Metal through ANGLE instead of OpenGL.")
            }
            Toggle(isOn: $withoutMounting) {
                Text("Prepare devices without mounting disk images (experimental)")
                Text(
                    "Edits a new device’s disk images directly instead of mounting them in macOS, groundwork for other platforms. May be slower, or fail on some versions."
                )
            }
            Toggle(isOn: $shareReports) {
                Text("Share anonymous usage and error reports")
                Text("Which devices start and what fails, sent to TelemetryDeck. Nothing identifies you or this Mac.")
            }
        }
    }
}
