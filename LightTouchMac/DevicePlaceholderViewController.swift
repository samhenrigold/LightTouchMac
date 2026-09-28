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
    private let step = NSTextField(labelWithString: "")
    private let reason = NSTextField(wrappingLabelWithString: "")
    private let showLog = NSButton(title: "Show Log", target: nil, action: nil)
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let sizes = NSTextField(labelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
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
        for label in [status, reason, note] {
            label.alignment = .center
            label.preferredMaxLayoutWidth = 320
        }
        status.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        reason.textColor = .secondaryLabelColor
        note.textColor = .systemOrange
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sizes.textColor = .secondaryLabelColor
        sizes.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        progress.style = .bar
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

        let stack = NSStackView(views: [art, model, version, status, progress, step, reason, showLog, primary, sizes, note])
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
        version.stringValue = "iOS \(entry.version) (\(entry.build))"

        progress.isHidden = true
        step.isHidden = true
        reason.isHidden = true
        showLog.isHidden = true
        switch row.state {
        case .notDownloaded: status.stringValue = "Not Downloaded"
        case let .downloading(fraction):
            status.stringValue = "Downloading…"
            show(progress: fraction, step: "\(Int((fraction * 100).rounded()))%")
        case let .preparing(index, count, name):
            status.stringValue = "Preparing…"
            show(progress: count > 0 ? Double(index) / Double(count) : 0, step: "Step \(index) of \(count): \(name)")
        case .ready: status.stringValue = "Ready"
        case .running: status.stringValue = "Running"
        case .stopping: status.stringValue = "Stopping…"
        case let .error(message):
            status.stringValue = "Couldn’t Start"
            reason.stringValue = message
            reason.isHidden = false
            showLog.isHidden = false
        case .unavailable(.comingSoon): status.stringValue = "Coming Soon"
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

        var parts: [String] = []
        let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        if entry.source.kind == .ipsw, let bytes = entry.source.bytes, bytes > 0 { parts.append("Download \(format(bytes))") }
        if entry.estimates.preparedBytes > 0 { parts.append("\(format(entry.estimates.preparedBytes)) on disk") }
        if entry.estimates.peakBytes > 0 { parts.append("\(format(entry.estimates.peakBytes)) free space to prepare") }
        sizes.stringValue = parts.joined(separator: " · ")
        sizes.isHidden = parts.isEmpty || row.isStartable
        note.stringValue = entry.statusNote ?? "Experimental"
        note.isHidden = !row.isExperimental
    }

    private func show(progress value: Double, step text: String) {
        progress.doubleValue = value
        progress.isHidden = false
        step.stringValue = text
        step.isHidden = false
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
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension.lowercased() == "ipsw" }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { ipsws(sender).isEmpty ? [] : .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = ipsws(sender)
        urls.forEach { onDrop?($0) }
        return !urls.isEmpty
    }
}
