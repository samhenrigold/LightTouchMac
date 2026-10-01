// The detail area for a device that isn't running in this window: its art,
// dimmed, what it is, where it stands, and the one thing to do next.

import Cocoa

final class DevicePlaceholderViewController: NSViewController {
    var onAction: ((DeviceAction) -> Void)?
    var onShowLog: (() -> Void)?
    var onDropIPSW: ((URL) -> Void)?

    private let art = NSImageView()
    private let model = NSTextField(labelWithString: "")
    private let version = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let step = NSTextField(wrappingLabelWithString: "")
    private let reason = NSTextField(wrappingLabelWithString: "")
    private let showLog = NSButton(title: "Show Logs", target: nil, action: nil)
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let space = NSTextField(wrappingLabelWithString: "")
    /// The build's catalog note (untested, experimental, where a beta came from), in a popover.
    private let info = NSButton(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About This Build")!,
                                target: nil, action: nil)
    private var row: DeviceRow?

    override func loadView() {
        let drop = IPSWDropView()
        drop.onDrop = { [weak self] url in self?.onDropIPSW?(url) }
        view = drop

        art.imageScaling = .scaleProportionallyDown
        art.alphaValue = 0.35
        art.setAccessibilityElement(false)
        art.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        art.setContentHuggingPriority(.defaultLow, for: .vertical)
        // One column, three tiers: what it is (name, then version), where it stands (state, then its detail),
        // what to do (one button row, the default button last). The same slots in every state.
        model.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title1).pointSize, weight: .semibold)
        version.font = .preferredFont(forTextStyle: .title3)
        version.textColor = .secondaryLabelColor
        version.isSelectable = true
        for label in [status, step, reason, space] {
            label.alignment = .center
            label.preferredMaxLayoutWidth = 340
        }
        status.font = .preferredFont(forTextStyle: .headline)
        reason.textColor = .secondaryLabelColor
        space.textColor = .secondaryLabelColor
        space.font = .preferredFont(forTextStyle: .footnote)
        info.isBordered = false
        info.contentTintColor = .secondaryLabelColor
        info.target = self
        info.action = #selector(infoClicked(_:))
        progress.style = .bar
        progress.isIndeterminate = false   // NSProgressIndicator starts indeterminate: a bar that never fills
        progress.minValue = 0
        progress.maxValue = 1
        step.textColor = .secondaryLabelColor
        step.font = .monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .regular)
        for button in [showLog, primary] {
            button.bezelStyle = .push
            button.controlSize = .large
            button.target = self
        }
        showLog.action = #selector(showLogClicked(_:))
        primary.action = #selector(primaryClicked(_:))

        let versionLine = NSStackView(views: [version, info])
        versionLine.spacing = 4
        let identity = column([model, versionLine], spacing: 2)
        let state = column([status, progress, step, reason], spacing: 6)
        let actions = NSStackView(views: [showLog, primary])
        actions.spacing = 12
        // The row keeps its height with no button (running), so the lockup doesn't move between states.
        actions.heightAnchor.constraint(greaterThanOrEqualTo: primary.heightAnchor).isActive = true
        actions.detachesHiddenViews = true
        let stack = column([art, identity, state, actions, space], spacing: 20)
        stack.setCustomSpacing(28, after: art)
        stack.setCustomSpacing(12, after: actions)
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: guide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 20),
            art.heightAnchor.constraint(lessThanOrEqualToConstant: 320),
            art.heightAnchor.constraint(lessThanOrEqualTo: guide.heightAnchor, multiplier: 0.45),
            progress.widthAnchor.constraint(equalToConstant: 260),
            // The state tier holds a line, a bar and its line: the buttons stay put (a two-line reason adds one line).
            state.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
    }

    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = spacing
        return stack
    }

    func update(_ row: DeviceRow, canDownload: Bool) {
        loadViewIfNeeded()
        self.row = row
        let entry = row.entry
        let profile = entry.profile
        art.image = profile.flatMap { NSImage(named: $0.shellImageName) }
        model.stringValue = profile?.marketingName ?? entry.productType
        version.stringValue = "iOS \(entry.version)" + (row.badge.map { " \($0)" } ?? "") + " (\(entry.build))"
        info.isHidden = row.catalogNote == nil

        progress.isHidden = true
        progress.stopAnimation(nil)
        step.isHidden = true
        reason.isHidden = true
        showLog.isHidden = true
        status.isHidden = false
        switch row.state {
        case .notDownloaded, .downloaded:
            status.stringValue = row.stateDescription
            if !canDownload, let why = FirmwareJobs.shared.unavailableReason { reason.stringValue = why; reason.isHidden = false }
        case .downloading:
            status.stringValue = "Downloading…"
            progress.setAccessibilityLabel("Download progress")
            show(row)
        case .preparing:
            status.stringValue = "Preparing…"
            progress.setAccessibilityLabel("Preparation progress")
            show(row)
        case .ready: status.stringValue = "Ready"
        case .running: status.stringValue = "Running"
        case .stopping: status.stringValue = "Stopping…"
        case let .error(message):
            // What failed, over why (the reason).
            status.stringValue = row.hasSession ? "Stopped unexpectedly" : row.isStartable ? "Couldn’t start" : "Couldn’t prepare"
            reason.stringValue = message
            reason.isHidden = false
            showLog.isHidden = false
        case .unavailable(.comingSoon): status.stringValue = "Coming soon"
        case .unavailable(.requiresIPSW): status.stringValue = "Requires an IPSW"
        }

        if let action = row.primaryAction, let title = row.primaryTitle {
            primary.title = title
            // Return does the next thing; it never cancels a download (Escape does).
            primary.keyEquivalent = action == .cancel ? "\u{1b}" : "\r"
            primary.isEnabled = row.allows(action, canDownload: canDownload)
            primary.isHidden = false
            primary.setAccessibilityLabel("\(title) \(model.stringValue) iOS \(entry.version)")
        } else {
            primary.isHidden = true
        }

        // Disk numbers only when they stop a download or preparation.
        // (spaceShortage(available: 0) is nil for a row that needs no space: skip the volume query on every progress tick.)
        let shortage = row.spaceShortage(available: 0) == nil ? nil
            : (try? IPSWStore.availableSpace(at: Bundled.stateDirectory)).flatMap(row.spaceShortage(available:))
        space.stringValue = shortage ?? ""
        space.isHidden = shortage == nil
    }

    /// The bar (moving without a fraction yet), percent and time left; the preparer's step is the bar's tooltip.
    private func show(_ row: DeviceRow) {
        progress.isIndeterminate = row.progress == nil
        if let value = row.progress { progress.doubleValue = value } else { progress.startAnimation(nil) }
        progress.isHidden = false
        progress.toolTip = row.progressDetail.isEmpty ? nil : row.progressDetail.joined(separator: "\n")
        step.stringValue = row.progressLine ?? ""
        step.isHidden = step.stringValue.isEmpty
    }

    @objc private func infoClicked(_ sender: NSButton) {
        guard let row, let content = Self.infoContent(for: row) else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    /// The ⓘ popover: the support tag and what it means, the catalog's source note, the release date.
    /// Sized to fit before it is shown: a view controller's bare NSView() is 0×0, and a popover that
    /// takes that size shows nothing (RC1).
    static func infoContent(for row: DeviceRow) -> NSViewController? {
        guard row.catalogNote != nil else { return nil }
        func label(_ text: String?, _ style: NSFont.TextStyle, _ color: NSColor = .labelColor) -> NSTextField? {
            guard let text else { return nil }
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .preferredFont(forTextStyle: style)
            label.textColor = color
            label.isSelectable = true
            label.preferredMaxLayoutWidth = 280
            return label
        }
        let stack = NSStackView(views: [label(row.supportNote, .headline), label(row.supportExplanation, .body, .secondaryLabelColor),
                                        label(row.entry.statusNote, .body), label(row.releaseLine, .subheadline, .secondaryLabelColor)]
            .compactMap { $0 })
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.widthAnchor.constraint(equalToConstant: 308).isActive = true
        let content = NSViewController()
        content.view = stack
        stack.frame.size = stack.fittingSize
        content.preferredContentSize = stack.frame.size
        return content
    }

    @objc private func primaryClicked(_ sender: Any?) {
        guard let action = row?.primaryAction else { return }
        onAction?(action)
    }

    @objc private func showLogClicked(_ sender: Any?) { onShowLog?() }
}

/// Takes .ipsw files dropped anywhere on the placeholder.
private final class IPSWDropView: NSView {
    var onDrop: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func ipsws(_ sender: NSDraggingInfo) -> [URL] {
        DroppedFiles.files(sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                                 options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [], .ipsw)
    }

    private lazy var highlight = DropHighlight.install(in: self)
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { highlight.show(for: ipsws(sender).isEmpty ? [] : .copy) }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlight.show(for: []) }
    override func draggingEnded(_ sender: NSDraggingInfo) { highlight.show(for: []) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = ipsws(sender)
        urls.forEach { onDrop?($0) }
        return !urls.isEmpty
    }
}
