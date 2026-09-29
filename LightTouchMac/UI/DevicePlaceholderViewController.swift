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
    private let showLog = NSButton(title: "Show Log", target: nil, action: nil)
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
        model.font = .systemFont(ofSize: NSFont.systemFontSize * 1.7, weight: .semibold)
        version.textColor = .secondaryLabelColor
        version.isSelectable = true
        for label in [status, step, reason, space] {
            label.alignment = .center
            label.preferredMaxLayoutWidth = 320
        }
        status.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        reason.textColor = .secondaryLabelColor
        space.textColor = .secondaryLabelColor
        space.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        info.isBordered = false
        info.contentTintColor = .secondaryLabelColor
        info.target = self
        info.action = #selector(infoClicked(_:))
        progress.style = .bar
        progress.isIndeterminate = false   // NSProgressIndicator starts indeterminate: a bar that never fills
        progress.minValue = 0
        progress.maxValue = 1
        progress.setAccessibilityLabel("Progress")
        step.textColor = .secondaryLabelColor
        step.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        showLog.bezelStyle = .rounded
        showLog.target = self
        showLog.action = #selector(showLogClicked(_:))
        primary.bezelStyle = .rounded
        primary.controlSize = .large
        primary.keyEquivalent = "\r"
        primary.target = self
        primary.action = #selector(primaryClicked(_:))

        let versionLine = NSStackView(views: [version, info])
        versionLine.spacing = 4
        let stack = NSStackView(views: [art, model, versionLine, status, progress, step, reason, showLog, primary, space])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(20, after: art)
        stack.setCustomSpacing(16, after: showLog)
        stack.setCustomSpacing(16, after: primary)
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
            progress.widthAnchor.constraint(equalToConstant: 240),
        ])
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
        info.toolTip = row.catalogNote

        progress.isHidden = true
        progress.stopAnimation(nil)
        step.isHidden = true
        reason.isHidden = true
        showLog.isHidden = true
        status.isHidden = false
        switch row.state {
        // The button says it: Prepare, or Download & Prepare.
        case .bundled, .notDownloaded, .downloaded:
            status.isHidden = true
            if !canDownload, let why = FirmwareJobs.shared.unavailableReason { reason.stringValue = why; reason.isHidden = false }
        case .downloading:
            status.stringValue = "Downloading…"
            show(row)
        case .preparing:
            status.stringValue = "Preparing…"
            show(row)
        case .ready: status.stringValue = "Ready"
        case .running: status.stringValue = "Running"
        case .stopping: status.stringValue = "Stopping…"
        case let .error(message):
            status.stringValue = "Error"
            reason.stringValue = message
            reason.isHidden = false
            showLog.isHidden = false
        case .unavailable(.comingSoon): status.stringValue = "Coming soon"
        case .unavailable(.requiresIPSW): status.stringValue = "Requires an IPSW"
        }

        if let action = row.primaryAction, let title = row.primaryTitle {
            primary.title = title
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
        guard let text = row?.catalogNote else { return }
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = 280
        label.translatesAutoresizingMaskIntoConstraints = false
        let content = NSViewController()
        content.view = NSView()
        content.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.view.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: content.view.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: content.view.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: content.view.trailingAnchor, constant: -14),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { ipsws(sender).isEmpty ? [] : .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = ipsws(sender)
        urls.forEach { onDrop?($0) }
        return !urls.isEmpty
    }
}
