import Cocoa

/// AFC's media folder, presented in the device detail pane.
final class DeviceFilesViewController: NSViewController, NSBrowserDelegate {
    var services: DeviceServices?
    var dismiss: (() -> Void)?
    private let browser = NSBrowser()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let upload = NSButton(title: "Import…", target: nil, action: nil)
    private let download = NSButton(title: "Export…", target: nil, action: nil)
    private let refresh = NSButton(title: "Refresh", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private var directories: [String: [DeviceFile]] = [:]
    private var loading = Set<String>()
    private var tasks: [Task<Void, Never>] = []
    private var transfer: Task<Void, Never>?
    private var revision = 0
    private var transferID = UUID()

    override func loadView() {
        let box = FilesBackground()
        box.boxType = .custom
        box.borderWidth = 0
        box.fillColor = .windowBackgroundColor
        box.contentViewMargins = .zero
        view = box
        let back = NSButton(title: "Device", target: self, action: #selector(backToDevice))
        let heading = NSTextField(labelWithString: "Files")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let top = NSStackView(views: [back, heading])
        top.spacing = 12
        browser.delegate = self
        browser.target = self
        browser.action = #selector(selectionChanged)
        browser.minColumnWidth = 160
        browser.maxVisibleColumns = 3
        browser.allowsMultipleSelection = false
        browser.takesTitleFromPreviousColumn = true
        browser.setAccessibilityLabel("Device files")
        for (button, action) in [(upload, #selector(importFile)), (download, #selector(exportFile)),
                                 (refresh, #selector(reload)), (cancel, #selector(cancelTransfer))] {
            button.target = self
            button.action = action
        }
        cancel.keyEquivalent = "\u{1b}"
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.style = .bar
        let actions = NSStackView(views: [NSStackView(views: [upload, download]), NSStackView(views: [refresh, cancel])])
        actions.orientation = .vertical
        actions.alignment = .leading
        actions.spacing = 8
        let stack = NSStackView(views: [top, browser, status, progress, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            browser.widthAnchor.constraint(equalTo: stack.widthAnchor),
            browser.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
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

    @objc private func backToDevice() { dismiss?() }

    @objc func reload() {
        stop()
        directories.removeAll()
        browser.loadColumnZero()
        updateControls()
        guard let services else { status.stringValue = "Connect the device to browse files."; return }
        let generation = revision
        tasks.append(Task { [weak self] in
            do {
                let bytes = try await services.freeSpaceBytes()
                guard let self, generation == revision, !Task.isCancelled else { return }
                status.stringValue = String(format: "%.2f GB available · Media folder", Double(bytes) / 1_000_000_000)
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
                directories[path] = entries
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

    @objc private func selectionChanged() { updateControls() }
    private func updateControls() {
        upload.isEnabled = services != nil && transfer == nil
        download.isEnabled = services != nil && transfer == nil && selected?.isRegular == true
        refresh.isEnabled = transfer == nil
        cancel.isHidden = transfer == nil
        progress.isHidden = transfer == nil
        browser.isEnabled = transfer == nil
    }

    @objc private func cancelTransfer() {
        transfer?.cancel()
        status.stringValue = "Cancelling transfer…"
    }

    @objc private func importFile() {
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

    @objc private func exportFile() {
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
        status.stringValue = "Transferring…"
        transfer = Task { [weak self] in
            do {
                try await work { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self, generation == revision, transferID == id, transfer != nil else { return }
                        progress.doubleValue = value
                    }
                }
                guard let self, generation == revision else { return }
                transfer = nil
                reload()
            } catch {
                guard let self, generation == revision else { return }
                transfer = nil
                status.stringValue = error is CancellationError ? "Transfer cancelled." : error.localizedDescription
                updateControls()
            }
        }
        updateControls()
    }
}

// Unhandled browser events must stop here, not reach the display underneath.
private final class FilesBackground: NSBox {
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
