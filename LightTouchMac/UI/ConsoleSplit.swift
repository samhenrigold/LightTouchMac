// The main pane's bottom console, after Xcode's debug area (IDEKit's
// IDEEditorArea + IDEBottomBar; see docs/ui-console-split.md for the evidence).
// The device sits on top, the console below, and the bar between them is the
// divider: drag it, double-click it, or use its toggle.

import Cocoa

/// Where the divider may rest. Pure numbers so the offline check can drive it.
struct ConsoleSplitLayout: Codable, Equatable {
    /// IDEDefaultDebugArea.preferredMinimumSize: 100 pt tall.
    static let minimumHeight: CGFloat = 100
    /// NSSplitView collapses a collapsible pane once the drag passes half its minimum.
    static let collapseThreshold = minimumHeight / 2
    /// DVTTheme.splitViewDividerSnappingTolerance.
    static let snapTolerance: CGFloat = 10
    /// The resting height a fresh window opens the console at, and a detent
    /// (Xcode snaps its navigator divider to navigatorAreaDefaultWidth the same way).
    static let defaultHeight: CGFloat = 200
    /// What the device pane keeps before the console gives up height.
    static let topMinimum: CGFloat = 160

    /// The height the user chose; kept while the window is too short to show it
    /// (IDEEditorArea's _heightToReturnToDebuggerArea), and while collapsed.
    var height = defaultHeight
    var isCollapsed = true

    static func maximumHeight(in available: CGFloat) -> CGFloat {
        max(minimumHeight, available - topMinimum)
    }

    /// The default height, and the middle of the drag range
    /// (IDESplitViewDebugArea snaps its divider to the rounded midpoint).
    static func detents(in available: CGFloat) -> [CGFloat] {
        let maximum = maximumHeight(in: available)
        return [defaultHeight, ((minimumHeight + maximum) / 2).rounded()].filter { $0 <= maximum }
    }

    /// A proposed console height from a drag: nil collapses, else a height
    /// clamped to the range and pulled onto a detent within the tolerance.
    static func resolve(_ proposed: CGFloat, in available: CGFloat) -> CGFloat? {
        if proposed < collapseThreshold { return nil }
        let clamped = min(max(proposed, minimumHeight), maximumHeight(in: available)).rounded(.down)
        return detents(in: available).first { abs(clamped - $0) < snapTolerance } ?? clamped
    }

    mutating func toggle() {
        isCollapsed.toggle()
        if !isCollapsed, height < Self.minimumHeight { height = Self.defaultHeight }
    }

    /// A drag that started at `start`. Collapsing by drag keeps the height it
    /// started from, so the toggle brings back the console the user had.
    mutating func drag(from start: ConsoleSplitLayout, to proposed: CGFloat, in available: CGFloat) {
        if let resolved = Self.resolve(proposed, in: available) {
            height = resolved; isCollapsed = false
        } else {
            height = start.height; isCollapsed = true
        }
    }

    /// Per-window autosave, like DVTSplitView's state token: one key per name.
    static func load(_ name: String, from defaults: UserDefaults = .standard) -> ConsoleSplitLayout {
        defaults.data(forKey: "ConsoleSplit \(name)").flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    func save(_ name: String, to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: "ConsoleSplit \(name)")
    }
}

/// The main pane: `top` above, the bar, then the console.
@MainActor
final class ConsoleSplitView: NSView {
    let bar = ConsoleBar()
    let log = LogTextView()
    private(set) var layout: ConsoleSplitLayout
    private let autosaveName: String
    private let defaults: UserDefaults
    private var consoleHeight: NSLayoutConstraint!
    private var dragStart: (layout: ConsoleSplitLayout, height: CGFloat, y: CGFloat)?

    init(top: NSView, autosaveName: String, defaults: UserDefaults = .standard) {
        self.autosaveName = autosaveName
        self.defaults = defaults
        layout = ConsoleSplitLayout.load(autosaveName, from: defaults)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        log.borderType = .noBorder
        for view in [top, bar, log] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // The chosen height gives way to the device's minimum when the window is
        // short, and comes back when it grows (IDEEditorArea _resizeSubviewsForHeight…).
        consoleHeight = log.heightAnchor.constraint(equalToConstant: 0)
        consoleHeight.priority = .defaultHigh
        let topMinimum = top.heightAnchor.constraint(greaterThanOrEqualToConstant: ConsoleSplitLayout.topMinimum)
        topMinimum.priority = .init(999)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor),
            top.leadingAnchor.constraint(equalTo: leadingAnchor), top.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: top.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor), bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            log.topAnchor.constraint(equalTo: bar.bottomAnchor),
            log.leadingAnchor.constraint(equalTo: leadingAnchor), log.trailingAnchor.constraint(equalTo: trailingAnchor),
            log.bottomAnchor.constraint(equalTo: bottomAnchor),
            consoleHeight, topMinimum,
        ])
        bar.onToggle = { [weak self] in self?.toggle() }
        bar.onDragBegan = { [weak self] y in
            guard let self else { return }
            dragStart = (layout, layout.isCollapsed ? 0 : log.frame.height, y)
        }
        bar.onDrag = { [weak self] y in self?.drag(to: y) }
        bar.onDragEnded = { [weak self] in self?.dragStart = nil; self?.commit() }
        bar.onClear = { [weak self] in self?.log.clear() }
        bar.onFilter = { [weak self] in self?.log.filter = $0 }
        bar.onSource = { [weak self] in self?.sourceChanged() }
        apply(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The logs the picker offers (the selected device's and the app's). The
    /// choice follows the file name across devices.
    var sources: [URL] = [] {
        didSet {
            let chosen = log.url?.lastPathComponent ?? sources.first?.lastPathComponent
            bar.source.removeAllItems()
            bar.source.addItems(withTitles: sources.map(\.lastPathComponent))
            if let chosen { bar.source.selectItem(withTitle: chosen) }
            if bar.source.indexOfSelectedItem < 0, !sources.isEmpty { bar.source.selectItem(at: 0) }
            sourceChanged()
        }
    }

    private func sourceChanged() {
        let index = bar.source.indexOfSelectedItem
        log.url = sources.indices.contains(index) ? sources[index] : nil
    }

    /// The console's share of the view: everything below the bar.
    private var available: CGFloat { bounds.height - ConsoleBar.height }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePolling()
    }

    /// Show or hide, as Xcode's toggleDebuggerVisibility: animated unless Reduce Motion is on.
    func toggle() {
        layout.toggle()
        apply(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        commit()
    }

    private func drag(to y: CGFloat) {
        guard let dragStart else { return }
        let proposed = dragStart.height + (y - dragStart.y)
        layout.drag(from: dragStart.layout, to: proposed, in: available)
        apply(animated: false)
    }

    private func apply(animated: Bool) {
        let collapsed = layout.isCollapsed, target = collapsed ? 0 : layout.height
        bar.isExpanded = !collapsed
        if !collapsed { log.isHidden = false }
        // Out of the key-view loop once it's gone, as a collapsed split pane is.
        let hide = { [weak self] in if let self, collapsed, self.layout.isCollapsed { self.log.isHidden = true } }
        if animated {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; consoleHeight.animator().constant = target } completionHandler: { hide() }
        } else {
            consoleHeight.constant = target
            hide()
        }
        updatePolling()
    }

    private func commit() {
        layout.save(autosaveName, to: defaults)
    }

    private func updatePolling() {
        if window != nil, !layout.isCollapsed { log.startPolling() } else { log.stopPolling() }
    }
}

/// Xcode's debug bar: pinned at the divider, visible when the console isn't,
/// and itself the divider's grab area (IDEBottomBar.additionalGrabRectsForSplitViewDivider).
@MainActor
final class ConsoleBar: NSView {
    /// DVTControlBar.defaultBarHeight: 36 pt in the macOS 26 design, 27 before it.
    static let height: CGFloat = {
        if #available(macOS 26, *) { return 36 }
        return 27
    }()
    let toggleButton = NSButton()
    let source = NSPopUpButton()
    let filter = NSSearchField()
    let clearButton = NSButton()
    private let stack = NSStackView()
    private let spacer = NSView()
    var onToggle: (() -> Void)?
    var onClear: (() -> Void)?
    var onFilter: ((String) -> Void)?
    var onSource: (() -> Void)?
    var onDragBegan: ((CGFloat) -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    var isExpanded = false {
        didSet {
            toggleButton.state = isExpanded ? .on : .off
            toggleButton.contentTintColor = isExpanded ? .controlAccentColor : nil
            let label = isExpanded ? "Hide Console" : "Show Console"
            toggleButton.toolTip = label + " (⇧⌘Y)"
            toggleButton.setAccessibilityLabel(label)
            // The console's own controls go with it, as Xcode's console footer does.
            for control in [source, filter, clearButton] as [NSView] { control.isHidden = !isExpanded }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 36))
        toggleButton.setButtonType(.pushOnPushOff)
        toggleButton.bezelStyle = .toolbar
        toggleButton.isBordered = false
        toggleButton.image = NSImage(systemSymbolName: "inset.filled.bottomthird.square", accessibilityDescription: nil)
        toggleButton.target = self; toggleButton.action = #selector(toggle)
        source.controlSize = .small
        source.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        source.setAccessibilityLabel("Log file")
        source.target = self; source.action = #selector(sourceChosen)
        filter.controlSize = .small
        filter.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        filter.placeholderString = "Filter"
        filter.setAccessibilityLabel("Filter Console")
        filter.sendsSearchStringImmediately = true
        filter.target = self; filter.action = #selector(filterChanged)
        clearButton.bezelStyle = .toolbar
        clearButton.isBordered = false
        clearButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear Console")
        clearButton.toolTip = "Clear Console"
        clearButton.target = self; clearButton.action = #selector(clear)
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        for view in [toggleButton, source, spacer, filter, clearButton] { stack.addArrangedSubview(view) }
        stack.spacing = 8
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            filter.widthAnchor.constraint(equalToConstant: 180),
        ])
        isExpanded = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }

    /// The divider line on top; a second line under the bar while the console
    /// shows (IDEEditorArea sets the bar's borderSides by visibility).
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        if isExpanded { NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill() }
    }

    /// The resize cursor over the bar's empty stretches, not over its controls.
    override func resetCursorRects() {
        var x = bounds.minX
        for control in stack.arrangedSubviews where !control.isHidden && control !== spacer {
            let frame = control.convert(control.bounds, to: self)
            if frame.minX > x { addCursorRect(NSRect(x: x, y: 0, width: frame.minX - x, height: bounds.height), cursor: .resizeUpDown) }
            x = max(x, frame.maxX)
        }
        if bounds.maxX > x { addCursorRect(NSRect(x: x, y: 0, width: bounds.maxX - x, height: bounds.height), cursor: .resizeUpDown) }
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        // IDEEditorArea splitView:doubleClickedOnDividerAtIndex: shows or hides the debug area.
        if event.clickCount == 2 { onToggle?(); return }
        onDragBegan?(event.locationInWindow.y)
    }

    override func mouseDragged(with event: NSEvent) { onDrag?(event.locationInWindow.y) }
    override func mouseUp(with event: NSEvent) { onDragEnded?() }

    @objc private func toggle() { onToggle?() }
    @objc private func clear() { onClear?() }
    @objc private func sourceChosen() { onSource?() }
    @objc private func filterChanged() { onFilter?(filter.stringValue) }
}

/// The split as a pane of the window's NSSplitViewController.
@MainActor
final class ConsoleSplitViewController: NSViewController {
    private let top: NSViewController
    private let autosaveName: String
    var split: ConsoleSplitView { view as! ConsoleSplitView }

    init(top: NSViewController, autosaveName: String) {
        self.top = top
        self.autosaveName = autosaveName
        super.init(nibName: nil, bundle: nil)
        addChild(top)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() { view = ConsoleSplitView(top: top.view, autosaveName: autosaveName) }
}
