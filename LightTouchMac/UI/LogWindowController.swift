import Cocoa

/// A live, selectable tail of one log file: the Device Logs window's view and
/// the main window's console. Selecting text (or `isPaused`) holds updates.
@MainActor
final class LogTextView: NSScrollView {
    let text = NSTextView()
    var url: URL? { didSet { if url != oldValue { origin = 0; raw = ""; text.string = "" } } }
    /// Shows only the lines containing it (case-insensitive), like Xcode's console filter.
    var filter = "" { didSet { if filter != oldValue { show(raw) } } }
    var isPaused = false
    private var raw = ""
    /// Clear hides what the file held so far; the file itself is untouched.
    private var origin: UInt64 = 0
    private var polling: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        text.isEditable = false
        text.isSelectable = true
        text.usesFindBar = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel("Log output")
        hasVerticalScroller = true
        documentView = text
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Polls once a second while visible; stop when the view goes away.
    func startPolling() {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }

    func stopPolling() { polling?.cancel(); polling = nil }

    func clear() {
        origin = url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? UInt64 } ?? 0
        raw = ""
        text.string = ""
    }

    func refresh() async {
        guard window?.isVisible == true, !isPaused, text.selectedRange().length == 0, let url else { return }
        let from = origin
        let value = await Task.detached(priority: .utility) { LogWindowController.tail(url, from: from) }.value
        guard !Task.isCancelled, self.url == url, origin == from, !isPaused, text.selectedRange().length == 0 else { return }
        if value.rotated { origin = 0 }
        guard value.text != raw else { return }
        raw = value.text
        show(raw)
    }

    nonisolated static func filtered(_ value: String, by filter: String) -> String {
        filter.isEmpty ? value : value.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(filter) }.joined(separator: "\n")
    }

    private func show(_ value: String) {
        let shown = Self.filtered(value, by: filter)
        guard text.string != shown else { return }
        let atBottom = text.visibleRect.maxY >= text.bounds.maxY - 8
        text.string = shown
        text.sizeToFit()
        if atBottom { text.scrollToEndOfDocument(nil) }
    }
}

@MainActor
final class LogWindowController: NSWindowController, NSWindowDelegate {
    private let logs: [URL]
    private let picker = NSPopUpButton()
    private let log = LogTextView()
    private let pause = NSButton(checkboxWithTitle: "Pause updates", target: nil, action: nil)

    init(logs: [URL]) {
        self.logs = logs
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Device Logs"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 250)
        WindowRestorationPolicy.configure(window)
        window.center()
        window.delegate = self
        picker.addItems(withTitles: logs.map(\.lastPathComponent))
        picker.setAccessibilityLabel("Log file")
        picker.target = self; picker.action = #selector(sourceChanged(_:))
        pause.target = self; pause.action = #selector(pauseChanged(_:))
        log.url = logs.first
        log.borderType = .bezelBorder
        let controls = NSStackView(views: [picker, pause])
        controls.spacing = 12
        let hint = NSTextField(labelWithString: "Latest 64 KB. Selecting text pauses updates.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        let content = window.contentView!
        for view in [controls, log, hint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            log.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
            log.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            log.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            hint.topAnchor.constraint(equalTo: log.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: log.leadingAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        log.startPolling()
    }

    func windowWillClose(_ notification: Notification) { log.stopPolling() }

    @objc private func sourceChanged(_ sender: Any?) {
        log.url = logs.indices.contains(picker.indexOfSelectedItem) ? logs[picker.indexOfSelectedItem] : nil
    }

    @objc private func pauseChanged(_ sender: Any?) { log.isPaused = pause.state == .on }

    nonisolated static func tail(_ url: URL) -> String { tail(url, from: 0).text }

    /// The file's last 64 KB after `from` (a Clear point), whole lines only.
    /// `rotated` when the file is now shorter than `from`: it was replaced, so read it all.
    nonisolated static func tail(_ url: URL, from: UInt64) -> (text: String, rotated: Bool) {
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let size = try file.seekToEnd(), limit: UInt64 = 65536
            let rotated = size < from, start = max(rotated ? 0 : from, size > limit ? size - limit : 0)
            try file.seek(toOffset: start)
            var data = try file.read(upToCount: Int(limit)) ?? Data()
            if start > (rotated ? 0 : from), let newline = data.firstIndex(of: 10) { data = Data(data.suffix(from: data.index(after: newline))) }
            if data.isEmpty { return (from > 0 && !rotated ? "" : "No log output yet.", rotated) }
            return (String(decoding: data, as: UTF8.self), rotated)
        } catch {
            return ("Cannot read \(url.lastPathComponent): \(error.localizedDescription)", false)
        }
    }
}

@MainActor
final class DeviceNoticeViewController: NSTitlebarAccessoryViewController {
    var onShowLogs: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// The notice's own remedy (e.g. "Erase…"), shown only when update() names one.
    var onAction: (() -> Void)?
    private let message = NSTextField(wrappingLabelWithString: "")
    private let dismiss = NSButton()
    private let action = NSButton(title: "", target: nil, action: nil)

    init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .bottom
        view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 56))
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Device needs attention")!)
        icon.contentTintColor = .labelColor
        message.maximumNumberOfLines = 2
        message.preferredMaxLayoutWidth = 400
        message.lineBreakMode = .byTruncatingTail
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let logs = NSButton(title: "Show Logs", target: self, action: #selector(showLogs))
        logs.bezelStyle = .rounded
        action.bezelStyle = .rounded
        action.target = self; action.action = #selector(performAction)
        action.isHidden = true
        let buttons = NSStackView(views: [action, logs])
        buttons.spacing = 8
        buttons.detachesHiddenViews = true
        dismiss.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss status")
        dismiss.isBordered = false
        dismiss.target = self; dismiss.action = #selector(dismissNotice)
        dismiss.toolTip = "Dismiss this status message"
        dismiss.setAccessibilityLabel("Dismiss status")
        for child in [icon, message, buttons, dismiss] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
            child.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            message.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            message.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -12),
            message.heightAnchor.constraint(lessThanOrEqualToConstant: 42),
            buttons.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor, constant: -8),
            dismiss.widthAnchor.constraint(equalToConstant: 24),
            dismiss.heightAnchor.constraint(equalToConstant: 24),
            dismiss.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ value: String, canDismiss: Bool, action actionTitle: String? = nil) {
        action.title = actionTitle ?? ""
        action.isHidden = actionTitle == nil
        message.stringValue = value
        message.toolTip = value
        message.setAccessibilityLabel(value)
        dismiss.isHidden = !canDismiss
        dismiss.isEnabled = canDismiss
    }

    @objc private func showLogs() { onShowLogs?() }
    @objc private func dismissNotice() { onDismiss?() }
    @objc private func performAction() { onAction?() }
}
