import Cocoa

/// Settings…: one window, a toolbar button per pane, the window sized to the
/// pane and titled after it (HIG, "Preferences Windows").
final class SettingsWindowController: NSWindowController {
    enum Pane: Int { case general, capture, storage }

    private let tabs = SettingsTabViewController()

    /// Each pane reports its `fittingSize` and calls its `onResize` hook.
    init(general: GeneralSettingsView, capture: CaptureOptionsView, storage: StorageSettingsView) {
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        for (view, title, symbol) in [(general as NSView, "General", "gearshape"),
                                      (capture, "Capture", "camera"),
                                      (storage, "Storage", "internaldrive")] {
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
        WindowRestorationPolicy.configure(window)
        super.init(window: window)
        general.onResize = { [weak self] in self?.fit() }
        capture.onResize = { [weak self] in self?.fit() }
        storage.onResize = { [weak self] in self?.fit() }
        tabs.onSelect = { [weak self] in self?.fit() }
        fit()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var pane: Pane {
        get { Pane(rawValue: tabs.selectedTabViewItemIndex) ?? .general }
        set { tabs.selectedTabViewItemIndex = newValue.rawValue }
    }

    func view(for pane: Pane) -> NSView { tabs.tabViewItems[pane.rawValue].viewController!.view }

    /// The window takes the selected pane's size, keeping its top edge.
    private func fit() {
        guard let window else { return }
        let view = self.view(for: pane)
        view.layoutSubtreeIfNeeded()
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: view.fittingSize))
        guard frame.size != window.frame.size else { return }
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - frame.height, width: frame.width, height: frame.height),
                        display: true, animate: window.isVisible)
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
final class GeneralSettingsView: NSView {
    /// Connect, Use Offline, or no saved answer (the device asks when it starts).
    private let internet = NSPopUpButton(frame: .zero, pullsDown: false)
    private let grid: NSGridView
    var onResize: (() -> Void)?

    init() {
        for (title, tag) in [("Connect", 1), ("Use Offline", 0), ("Ask When a Device Starts", -1)] {
            internet.addItem(withTitle: title)
            internet.lastItem?.tag = tag
        }
        internet.setAccessibilityLabel("Internet access")
        grid = NSGridView(views: [[NSTextField(labelWithString: "Internet access:"), internet]])
        grid.column(at: 0).xPlacement = .trailing
        grid.columnSpacing = 8
        grid.yPlacement = .center
        super.init(frame: .zero)
        internet.target = self
        internet.action = #selector(internetChanged(_:))
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 430),
        ])
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var fittingSize: NSSize { NSSize(width: max(430, grid.fittingSize.width + 40), height: grid.fittingSize.height + 40) }

    func reload() {
        let saved = UserDefaults.standard.object(forKey: NetworkAccessPreference.key) as? Bool
        internet.selectItem(withTag: saved.map { $0 ? 1 : 0 } ?? -1)
    }

    @objc private func internetChanged(_ sender: NSPopUpButton) {
        switch sender.selectedTag() {
        case -1: UserDefaults.standard.removeObject(forKey: NetworkAccessPreference.key)
        case let tag: UserDefaults.standard.set(tag == 1, forKey: NetworkAccessPreference.key)
        }
    }
}
