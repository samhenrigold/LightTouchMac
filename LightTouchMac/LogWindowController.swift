import Cocoa

@MainActor
final class LogWindowController: NSWindowController, NSWindowDelegate {
    private let logs: [URL]
    private let picker = NSPopUpButton()
    private let text = NSTextView()
    private let pause = NSButton(checkboxWithTitle: "Pause updates", target: nil, action: nil)
    private var polling: Task<Void, Never>?

    init(logs: [URL]) {
        self.logs = logs
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Device Logs"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 250)
        window.setFrameAutosaveName("DeviceLogs")
        window.delegate = self
        picker.addItems(withTitles: logs.map(\.lastPathComponent))
        picker.setAccessibilityLabel("Log file")
        picker.target = self; picker.action = #selector(sourceChanged(_:))
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
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = text
        let controls = NSStackView(views: [picker, pause])
        controls.spacing = 12
        let hint = NSTextField(labelWithString: "Latest 64 KB. Select text to pause updates while copying. Use Find to search.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        let content = window.contentView!
        for view in [controls, scroll, hint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        polling?.cancel(); polling = nil
    }

    @objc private func sourceChanged(_ sender: Any?) {
        text.string = ""
    }

    private func refresh() async {
        guard window?.isVisible == true, pause.state != .on, text.selectedRange().length == 0,
              logs.indices.contains(picker.indexOfSelectedItem) else { return }
        let index = picker.indexOfSelectedItem, url = logs[index]
        let value = await Task.detached(priority: .utility) { Self.tail(url) }.value
        guard !Task.isCancelled, picker.indexOfSelectedItem == index, pause.state != .on,
              text.selectedRange().length == 0, text.string != value else { return }
        let atBottom = text.visibleRect.maxY >= text.bounds.maxY - 8
        text.string = value
        text.sizeToFit()
        if atBottom { text.scrollToEndOfDocument(nil) }
    }

    nonisolated static func tail(_ url: URL) -> String {
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let size = try file.seekToEnd(), limit: UInt64 = 65536
            try file.seek(toOffset: size > limit ? size - limit : 0)
            var data = try file.read(upToCount: Int(limit)) ?? Data()
            if size > limit, let newline = data.firstIndex(of: 10) { data = Data(data.suffix(from: data.index(after: newline))) }
            return data.isEmpty ? "No log output yet." : String(decoding: data, as: UTF8.self)
        } catch {
            return "Cannot read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
