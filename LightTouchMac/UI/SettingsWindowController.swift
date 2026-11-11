import Cocoa
import HostRuntime
import LightTouchCore
import SwiftUI

/// Settings…: one window, a toolbar button per pane, the window sized to the selected pane (AppKit, from each
/// hosting controller's preferredContentSize) and titled after it (HIG, "Settings"). Each pane is a grouped Form.
// At a macOS 26 deployment target this class can go: an NSHostingSceneRepresentation of a Settings scene with a
// TabView(selection:), opened by its environment's openSettings(). Before 26 only NSTabViewController has these tabs.
final class SettingsWindowController: NSWindowController {
    enum Pane: Int { case general, capture, storage }

    private let tabs = SettingsTabViewController()

    /// `storage` is measured each time its pane is shown (StorageSettingsView). IPSWs and apps dropped on any pane go
    /// to Storage, which comes forward.
    init(general: some View, capture: some View, storage: StorageUsage) {
        let tabs = tabs
        let drop: ([URL]) -> Bool = { urls in
            guard storage.add(urls) else {
                return false
            }
            tabs.selectedTabViewItemIndex = Pane.storage.rawValue
            return true
        }
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        tabs.addTabViewItem(Self.item(general.settingsPane(), "General", "gearshape", drop: drop))
        tabs.addTabViewItem(Self.item(capture.settingsPane(), "Capture", "camera", drop: drop))
        tabs.addTabViewItem(
            Self.item(
                StorageSettingsView(model: storage).settingsPane(maxHeight: 560),
                "Storage",
                "internaldrive",
                drop: drop
            )
        )

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false

        let restored = WindowRestorationPolicy.configure(window, frameAutosaveName: "Settings")
        super.init(window: window)

        storage.isShown = { [weak self] in
            self?.window?.isVisible == true && self?.pane == .storage
        }

        if !restored {
            window.center()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func item(
        _ content: some View,
        _ title: String,
        _ symbol: String,
        drop: @escaping ([URL]) -> Bool
    ) -> NSTabViewItem {
        let pane = NSHostingController(
            rootView: content.dropDestination(for: URL.self) { urls, _ in
                drop(urls)
            }
        )
        pane.sizingOptions = .preferredContentSize
        pane.title = title
        let item = NSTabViewItem(viewController: pane)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    var pane: Pane {
        get { Pane(rawValue: tabs.selectedTabViewItemIndex) ?? .general }
        set { tabs.selectedTabViewItemIndex = newValue.rawValue }
    }

    func view(for pane: Pane) -> NSView { tabs.tabViewItems[pane.rawValue].viewController!.view }
}

/// A pane switch animates the window to the new pane's height, keeping its top edge, as Settings windows do; AppKit
/// resizes it to the pane's preferredContentSize without animating.
private final class SettingsTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, willSelect: tabViewItem)
        guard let window = view.window, window.isVisible, let size = tabViewItem?.viewController?.preferredContentSize
        else {
            return
        }
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        window.setFrame(
            NSRect(x: window.frame.minX, y: window.frame.maxY - frame.height, width: frame.width, height: frame.height),
            display: true,
            animate: true
        )
    }
}

extension View {
    /// A Settings pane: a grouped Form 500 pt wide at its content's height, which scrolls past `maxHeight`.
    func settingsPane(maxHeight: CGFloat = .infinity) -> some View {
        formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: 500)
            .frame(maxHeight: maxHeight)
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
    @AppStorage(Board.NameStyle.key) private var nameStyle = Board.NameStyle.marketing

    var body: some View {
        Form {
            Section {
                Picker("Device name style", selection: $nameStyle) {
                    ForEach(Board.NameStyle.allCases, id: \.self) { style in
                        Text(Board.n72.name(style))
                            .tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: nameStyle) {
                    NotificationCenter.default.post(name: Board.NameStyle.didChangeNotification, object: nil)
                }
            }

            Section {
                Picker("Connect to the internet…", selection: $internet) {
                    Text("Always").tag(Bool?.some(true))
                    Text("Never").tag(Bool?.some(false))
                    Text("Ask When a Device Starts").tag(Bool?.none)
                }

                Toggle("Sync clipboard between devices and this Mac", isOn: $shareClipboard)

                Toggle("Simulate vibration sounds", isOn: $vibrationSound)
            }

            Section {
                Toggle(isOn: $refresh120) {
                    Text("120Hz refresh rate")
                    Text("Some games may run too fast when enabled.\nTakes effect when a device next starts.")
                }
                Toggle(isOn: $angle) {
                    Text("ANGLE renderer")
                    Text("Experimental. Takes effect when a device next starts.")
                }
            }

            Section {
                Toggle(isOn: $withoutMounting) {
                    Text("Prepare new devices without mounting disk images")
                    Text("Experimental. May be slower, or fail on some versions.")
                }
            }

            Section {
                Toggle("Share anonymous usage and error reports", isOn: $shareReports)
            }

            Section {
                Button("Restore Defaults", action: restoreDefaults)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// This pane's settings only; the defaults are the ones declared above.
    private func restoreDefaults() {
        internet = nil
        vibrationSound = true
        refresh120 = false
        angle = false
        withoutMounting = false
        shareClipboard = true
        shareReports = true
    }
}

/// The Settings window's tabs, opened at `pane`, with Storage's preview data.
@MainActor private func settingsPreview(_ pane: SettingsWindowController.Pane) -> NSViewController {
    let settings = SettingsWindowController(
        general: GeneralSettingsView(),
        capture: CaptureOptionsView(preferences: .shared),
        storage: .preview
    )
    settings.pane = pane
    return settings.window!.contentViewController!
}

#Preview("General", traits: .fixedLayout(width: 520, height: 640)) {
    settingsPreview(.general)
}

#Preview("Capture", traits: .fixedLayout(width: 520, height: 640)) {
    settingsPreview(.capture)
}

#Preview("Storage", traits: .fixedLayout(width: 520, height: 640)) {
    settingsPreview(.storage)
}
