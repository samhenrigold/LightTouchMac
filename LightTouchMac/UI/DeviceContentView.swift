import Cocoa

/// One continuous scene. Transient feedback stays outside window captures.
final class DeviceContentView: NSView {
    private let screen: NSView
    private let statuses = NSStackView()
    private let overlay = NSView()
    private var panel: NSPanel?

    init(screen: NSView) {
        self.screen = screen
        super.init(frame: screen.frame)
        wantsLayer = true
        layer?.contents = NSImage(named: "gradient")?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        screen.translatesAutoresizingMaskIntoConstraints = false
        addSubview(screen)
        NSLayoutConstraint.activate([
            screen.leadingAnchor.constraint(equalTo: leadingAnchor), screen.trailingAnchor.constraint(equalTo: trailingAnchor),
            screen.topAnchor.constraint(equalTo: topAnchor), screen.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        statuses.orientation = .vertical
        statuses.alignment = .centerX
        statuses.spacing = 6
        overlay.addSubview(statuses)
        statuses.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statuses.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            statuses.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -8),
            statuses.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, constant: -16)
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        guard let window else { return }
        if panel == nil {
            let panel = CaptureOverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            WindowRestorationPolicy.configure(panel)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isExcludedFromWindowsMenu = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.contentView = overlay
            self.panel = panel
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didUnhideNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(refreshOverlay), name: name, object: NSApp)
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(refreshOverlay), name: name, object: window)
        }
        updateStatusVisibility()
    }
    override func layout() {
        super.layout()
        positionFeedback()
    }
    func addStatus(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        statuses.addArrangedSubview(view)
        if let status = view as? CaptureStatusView {
            status.onVisibilityChange = { [weak self] in self?.updateStatusVisibility() }
        }
        view.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        updateStatusVisibility()
    }
    @objc private func refreshOverlay() { positionFeedback() }

    func updateStatusVisibility() {
        needsLayout = true
        positionFeedback()
    }
    private func positionFeedback() {
        guard let window, let panel else { return }
        for status in statuses.arrangedSubviews.compactMap({ $0 as? CaptureStatusView }) {
            status.isWindowActive = window.isKeyWindow && NSApp.isActive
        }
        let visible = statuses.arrangedSubviews.filter { !$0.isHidden }
        guard !visible.isEmpty else {
            // orderOut removes a child from the parent's ordering group. Explicitly
            // detach here and reattach on show so app switching cannot lose it.
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            return
        }
        // Leave room for the native glass shadow inside the transparent window.
        let width = min((visible.map { $0.intrinsicContentSize.width }.max() ?? 0) + 16, max(0, bounds.width - 8))
        let height = 16 + visible.reduce(CGFloat.zero) { $0 + $1.intrinsicContentSize.height } + CGFloat(max(0, visible.count - 1)) * 6
        let canvas = window.convertToScreen(convert(bounds, to: nil))
        let frame = CGRect(x: canvas.midX - width / 2, y: canvas.minY + 4, width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        overlay.layoutSubtreeIfNeeded()
        guard window.isVisible, !window.isMiniaturized else { return }
        if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
        panel.order(.above, relativeTo: window.windowNumber)
    }
}

private final class CaptureOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
