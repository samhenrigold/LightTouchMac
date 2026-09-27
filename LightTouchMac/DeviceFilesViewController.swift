import Cocoa

/// AFC's media folder, presented in its own retained Mac window.
final class DeviceFilesViewController: NSViewController, NSBrowserDelegate, NSMenuItemValidation {
    var services: DeviceServices?
    var onActivityChange: (() -> Void)?
    var hasTransfer: Bool { transfer != nil }
    var transferStatus: String { status.stringValue }
    private let pathLabel = NSTextField(labelWithString: "Media")
    private var showHidden = false
    private var transferMessage: String?
    private let browser = NSBrowser()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let upload = NSButton(title: "Copy to \(DeviceProfile.current.shortName)…", target: nil, action: nil)
    private let download = NSButton(title: "Save to Mac…", target: nil, action: nil)
    private let refresh = NSButton(title: "Refresh", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private var directories: [String: [DeviceFile]] = [:]
    private var loading = Set<String>()
    private var tasks: [Task<Void, Never>] = []
    private var transfer: Task<Void, Never>?
    private var revision = 0
    private var transferID = UUID()
    private var idleStatusWidth: NSLayoutConstraint!
    private var activeStatusWidth: NSLayoutConstraint!

    override func loadView() {
        let box = FilesBackground()
        view = box
        pathLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        let hiddenMenu = NSMenu()
        let hidden = hiddenMenu.addItem(withTitle: "Show Hidden Files", action: #selector(toggleHidden(_:)), keyEquivalent: "")
        hidden.target = self
        browser.menu = hiddenMenu
        browser.delegate = self
        browser.target = self
        browser.action = #selector(selectionChanged)
        browser.minColumnWidth = 160
        browser.maxVisibleColumns = 3
        browser.allowsMultipleSelection = false
        browser.takesTitleFromPreviousColumn = false
        browser.isTitled = false
        browser.hasHorizontalScroller = true
        browser.setAccessibilityLabel("Device files")
        for (button, action) in [(upload, #selector(importFile)), (download, #selector(exportFile)),
                                 (refresh, #selector(refreshFiles(_:))), (cancel, #selector(cancelTransfer))] {
            button.target = self
            button.action = action
        }
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.style = .bar
        let options = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "File options")!, target: self, action: #selector(showOptions(_:)))
        options.isBordered = false
        options.toolTip = "File options"
        let actions = NSStackView(views: [upload, download, refresh, options])
        actions.spacing = 8
        for button in [upload, download, refresh] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 1
        status.lineBreakMode = .byTruncatingMiddle
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        for child in [actions, browser, pathLabel, status, progress, cancel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(child)
        }
        NSLayoutConstraint.activate([
            actions.topAnchor.constraint(equalTo: box.safeAreaLayoutGuide.topAnchor, constant: 10),
            actions.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            actions.heightAnchor.constraint(equalToConstant: 26),
            browser.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 10),
            browser.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            browser.bottomAnchor.constraint(equalTo: pathLabel.topAnchor, constant: -10),
            pathLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            pathLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            pathLabel.heightAnchor.constraint(equalToConstant: 18),
            pathLabel.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.leadingAnchor.constraint(equalTo: pathLabel.leadingAnchor),
            status.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
            status.heightAnchor.constraint(equalToConstant: 18),

            progress.widthAnchor.constraint(equalToConstant: 100),
            progress.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            progress.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -8),
            cancel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            cancel.centerYAnchor.constraint(equalTo: status.centerYAnchor)
        ])
        idleStatusWidth = status.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12)
        activeStatusWidth = status.trailingAnchor.constraint(equalTo: progress.leadingAnchor, constant: -12)
        updateControls()
    }

    func focusBrowser() {
        if view.window?.makeFirstResponder(browser) != true { view.window?.makeFirstResponder(view) }
    }

    func stop() {
        revision += 1
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        transfer?.cancel()
        transfer = nil
        loading.removeAll()
    }

    @objc private func showOptions(_ sender: NSButton) {
        browser.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    @objc func toggleHidden(_ sender: NSMenuItem) {
        guard !hasTransfer else { return }
        showHidden.toggle()
        reload()
    }

    @objc func refreshFiles(_ sender: Any?) {
        guard !hasTransfer else { return }
        reload()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(importFile): return services != nil && !hasTransfer
        case #selector(exportFile): return services != nil && !hasTransfer && selected?.isRegular == true
        case #selector(cancelTransfer): return hasTransfer
        case #selector(refreshFiles(_:)): return !hasTransfer
        case #selector(toggleHidden(_:)):
            item.title = showHidden ? "Hide Hidden Files" : "Show Hidden Files"
            return !hasTransfer
        default: return false
        }
    }

    @objc func reload() {
        stop()
        directories.removeAll()
        browser.loadColumnZero()
        updateControls()
        guard let services else { status.stringValue = "The \(DeviceProfile.current.shortName) is disconnected."; onActivityChange?(); return }
        let generation = revision
        tasks.append(Task { [weak self] in
            do {
                let bytes = try await services.freeSpaceBytes()
                guard let self, generation == revision, !Task.isCancelled else { return }
                status.stringValue = transferMessage ?? "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) available"
                onActivityChange?()
            } catch {
                guard let self, generation == revision, !Task.isCancelled else { return }
                status.stringValue = error.localizedDescription
            }
        })
    }

    private func directory(for column: Int) -> String? {
        if column == 0 { return "" }
        guard let parent = directory(for: column - 1), let entries = directories[parent] else { return nil }
        let row = browser.selectedRow(inColumn: column - 1)
        guard entries.indices.contains(row), entries[row].isDirectory else { return nil }
        return entries[row].path
    }

    func browser(_ sender: NSBrowser, numberOfRowsInColumn column: Int) -> Int {
        guard let path = directory(for: column) else { return 0 }
        if let entries = directories[path] { return entries.count }
        guard let services, loading.insert(path).inserted else { return 0 }
        let generation = revision
        tasks.append(Task { [weak self] in
            do {
                let entries = try await services.files(in: path)
                guard let self, generation == revision, !Task.isCancelled else { return }
                directories[path] = showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") && !$0.name.hasSuffix(".lock") && !$0.name.hasPrefix("com.apple.itdbprep.") }
                loading.remove(path)
                if directory(for: column) == path { browser.reloadColumn(column) }
                updateControls()
            } catch {
                guard let self, generation == revision, !Task.isCancelled else { return }
                loading.remove(path)
                status.stringValue = error.localizedDescription
            }
        })
        return 0
    }

    func browser(_ sender: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let cell = cell as? NSBrowserCell, let path = directory(for: column),
              let entries = directories[path], entries.indices.contains(row) else { return }
        let file = entries[row]
        cell.stringValue = file.name
        cell.isLeaf = !file.isDirectory
        cell.image = NSImage(systemSymbolName: file.isDirectory ? "folder" : "doc", accessibilityDescription: nil)
    }

    private var selected: DeviceFile? {
        let column = browser.selectedColumn
        guard column >= 0, let path = directory(for: column), let entries = directories[path] else { return nil }
        let row = browser.selectedRow(inColumn: column)
        return entries.indices.contains(row) ? entries[row] : nil
    }

    @objc private func selectionChanged() {
        let path = selected?.path ?? directory(for: max(0, browser.selectedColumn)) ?? ""
        pathLabel.stringValue = path.isEmpty ? "Media" : "Media / " + path.replacingOccurrences(of: "/", with: " / ")
        updateControls()
    }
    private func updateControls() {
        upload.isEnabled = services != nil && transfer == nil
        download.isEnabled = services != nil && transfer == nil && selected?.isRegular == true
        refresh.isEnabled = transfer == nil
        cancel.isHidden = transfer == nil
        idleStatusWidth?.isActive = false
        activeStatusWidth?.isActive = false
        (hasTransfer ? activeStatusWidth : idleStatusWidth)?.isActive = true
        progress.isHidden = transfer == nil
        browser.isEnabled = transfer == nil
        onActivityChange?()
    }

    @objc func cancelTransfer() {
        guard hasTransfer else { return }
        transfer?.cancel()
        status.stringValue = "Cancelling…"
        onActivityChange?()
    }

    @objc func importFile() {
        guard let window = view.window, let services, transfer == nil else { return }
        let path = selected.flatMap { $0.isDirectory ? $0.path : nil }
            ?? directory(for: max(0, browser.selectedColumn)) ?? ""
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let generation = revision
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, generation == self.revision, let url = panel.url else { return }
            self.beginTransfer { progress in
                try await services.uploadFile(url, into: path, progress: progress)
            }
        }
    }

    @objc func exportFile() {
        guard let window = view.window, let services, let file = selected,
              file.isRegular, transfer == nil else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        let generation = revision
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, generation == self.revision, let url = panel.url else { return }
            self.beginTransfer { progress in
                try await services.download(file, to: url, progress: progress)
            }
        }
    }

    private func beginTransfer(_ work: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void) {
        let generation = revision
        let id = UUID()
        transferID = id
        progress.doubleValue = 0
        transferMessage = nil
        status.stringValue = "Copying…"
        transfer = Task { [weak self] in
            do {
                try await work { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self, generation == revision, transferID == id, transfer != nil else { return }
                        progress.doubleValue = value
                        status.stringValue = "Copying \(Int(value * 100))%"
                        onActivityChange?()
                    }
                }
                guard let self, generation == revision else { return }
                transfer = nil
                transferMessage = "File copied"
                reload()
            } catch {
                guard let self, generation == revision else { return }
                transfer = nil
                status.stringValue = error is CancellationError ? "Copy cancelled" : error.localizedDescription
                transferMessage = status.stringValue
                updateControls()
            }
        }
        updateControls()
    }
}

// Unhandled browser events must stop here, not reach the display underneath.
private final class FilesBackground: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func rotate(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
}
