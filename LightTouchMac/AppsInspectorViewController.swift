// Created by Sam on 2026-08-05.
//
// The right-hand inspector: a plain AppKit table of the apps installed on the
// device, with add (install an .ipa) and remove (uninstall) controls beneath
// it, source-list style. While an install runs, the app appears in the list as
// a pending row with a spinner rather than only a footer indicator.

import Cocoa
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted after an install/uninstall completes so any open list refreshes.
    static let ltmAppsChanged = Notification.Name("LTMAppsChanged")
    /// Posted when an install begins; object is the display name being installed.
    static let ltmInstallStarted = Notification.Name("LTMInstallStarted")
}

/// Shared install flow used by both the inspector's Add button and drag-and-drop
/// onto the device. Announces start and finish so the list can show progress.
enum AppInstaller {
    @MainActor
    static func install(_ ipa: URL, with emulator: EmulatorController,
                        presenting window: NSWindow?) async {
        let name = ipa.deletingPathExtension().lastPathComponent
        NotificationCenter.default.post(name: .ltmInstallStarted, object: name)
        defer { NotificationCenter.default.post(name: .ltmAppsChanged, object: nil) }
        async let learn: Void = AppMetadataCache.shared.learn(from: ipa)
        do {
            _ = try await emulator.install(ipa)
        } catch {
            presentError(error, in: window)
        }
        await learn
    }
    
    @MainActor
    static func presentError(_ error: Error, in window: NSWindow?) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}

final class AppsInspectorViewController: NSViewController {
    
    private let emulator: EmulatorController
    private let tableView = NSTableView()
    private let addRemove = NSSegmentedControl()
    private let placeholder = NSTextField(labelWithString: "")
    private var apps: [InstalledApp] = []
    private var pending: [String] = []       // display names currently installing
    private var loadTask: Task<Void, Never>?
    
    init(emulator: EmulatorController) {
        self.emulator = emulator
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) { fatalError("not used") }
    
    override func loadView() {
        let container = NSView()
        
        let column = NSTableColumn(identifier: .init("app"))
        column.title = "Installed Apps"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = 40
        tableView.dataSource = self
        tableView.delegate = self
        
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        
        addRemove.segmentStyle = .smallSquare
        addRemove.trackingMode = .momentary
        addRemove.segmentCount = 2
        addRemove.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: "Install App"), forSegment: 0)
        addRemove.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: "Uninstall App"), forSegment: 1)
        addRemove.target = self
        addRemove.action = #selector(addOrRemove(_:))
        addRemove.translatesAutoresizingMaskIntoConstraints = false
        
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.font = .systemFont(ofSize: 11)
        placeholder.maximumNumberOfLines = 0
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isHidden = true
        
        [scroll, addRemove, placeholder].forEach(container.addSubview)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: addRemove.topAnchor, constant: -8),
            
            addRemove.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            addRemove.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            
            placeholder.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            placeholder.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            placeholder.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])
        
        view = container
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appsChanged), name: .ltmAppsChanged, object: nil)
        nc.addObserver(self, selector: #selector(installStarted(_:)), name: .ltmInstallStarted, object: nil)
        startInitialLoad()
    }
    
    // MARK: - Loading / refresh
    
    /// Keep polling for the life of the view, not just until the device answers
    /// once: right after boot, ideviceinstaller can connect and report an empty
    /// list before installd has finished registering apps, which used to read
    /// as "answered" and stop the loop — leaving the sidebar empty until an
    /// install/uninstall notification forced a reload. Polling forever instead
    /// self-heals within one more tick either way.
    private func startInitialLoad() {
        guard emulator.canManageApps else {
            showPlaceholder("App management needs a usbmux session. Relaunch with app sync enabled.")
            updateButtons()
            return
        }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.loadOnce()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
    
    @objc private func appsChanged() {
        pending.removeAll()
        Task { await loadOnce() }
    }
    
    @objc private func installStarted(_ note: Notification) {
        guard let name = note.object as? String else { return }
        pending.append(name)
        showPlaceholder(nil)
        tableView.reloadData()
        updateButtons()
    }
    
    /// One attempt to read the installed list.
    private func loadOnce() async {
        guard emulator.canManageApps else { return }
        do {
            apps = try await emulator.installedApps()
            tableView.reloadData()
            showPlaceholder(apps.isEmpty && pending.isEmpty ? "No third-party apps installed." : nil)
            updateButtons()
            AppMetadataCache.shared.prune(keeping: Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0.version) }))
        } catch {
            if pending.isEmpty { showPlaceholder("Waiting for the device…") }
        }
    }
    
    private func showPlaceholder(_ text: String?) {
        placeholder.stringValue = text ?? ""
        placeholder.isHidden = (text == nil)
    }
    
    private func updateButtons() {
        addRemove.setEnabled(emulator.canManageApps, forSegment: 0)
        addRemove.setEnabled(selectedApp != nil, forSegment: 1)
    }
    
    /// The selected row's app, or nil if nothing (or a pending row) is selected.
    private var selectedApp: InstalledApp? {
        let row = tableView.selectedRow - pending.count
        return apps.indices.contains(row) ? apps[row] : nil
    }
    
    // MARK: - Actions
    
    @objc private func addOrRemove(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? add() : remove()
    }
    
    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.message = "Choose a decrypted .ipa to install."
        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            Task { await AppInstaller.install(url, with: self.emulator, presenting: self.view.window) }
        }
    }
    
    private func remove() {
        guard let app = selectedApp else { return }
        let alert = NSAlert()
        alert.messageText = "Uninstall “\(app.name)”?"
        alert.informativeText = "This removes the app and its data from the device."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: view.window!) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            Task {
                do {
                    try await self.emulator.uninstall(app.id)
                    AppMetadataCache.shared.forget(app.id)
                } catch {
                    AppInstaller.presentError(error, in: self.view.window)
                }
                NotificationCenter.default.post(name: .ltmAppsChanged, object: nil)
            }
        }
    }
}

// MARK: - Table data

extension AppsInspectorViewController: NSTableViewDataSource, NSTableViewDelegate {
    
    func numberOfRows(in tableView: NSTableView) -> Int { pending.count + apps.count }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        if row < pending.count {
            let cell = pendingCell(tableView)
            cell.textField?.stringValue = pending[row]
            return cell
        }
        let app = apps[row - pending.count]
        let cell = appCell(tableView)
        let cache = AppMetadataCache.shared
        cell.textField?.stringValue = cache.name(for: app.id, version: app.version) ?? app.name
        cell.imageView?.image = cache.icon(for: app.id, version: app.version) ?? Self.genericAppIcon
        cell.toolTip = "\(app.id)\(app.version.isEmpty ? "" : " — \(app.version)")"
        return cell
    }
    
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    
    // A pending row can't be selected for removal.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row >= pending.count
    }
    
    /// Generic app placeholder for apps we have no cached icon for (installed
    /// from within the guest rather than through our Add button).
    private static let genericAppIcon = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
    
    private func appCell(_ tableView: NSTableView) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("appCell")
        if let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = id
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 28),
            image.heightAnchor.constraint(equalToConstant: 28),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
    
    private func pendingCell(_ tableView: NSTableView) -> NSTableCellView {
        // Built fresh each time (pending rows are few) so the spinner animates.
        let cell = NSTableCellView()
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)
        let text = NSTextField(labelWithString: "")
        text.textColor = .secondaryLabelColor
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = NSTextField(labelWithString: "Installing…")
        subtitle.textColor = .tertiaryLabelColor
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(spinner)
        cell.addSubview(text)
        cell.addSubview(subtitle)
        cell.textField = text
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            spinner.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
            subtitle.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 1),
        ])
        return cell
    }
}
