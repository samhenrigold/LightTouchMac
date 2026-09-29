// The sidebar: one group per model, one row per catalog entry, each with a
// trailing accessory for its state (docs/multi-device-plan.md, C). Commands
// go to the window controller, which owns what they do; this view only says
// which entry they are for (the clicked row for its context menu, the
// selection otherwise).

import Cocoa
import UniformTypeIdentifiers

@MainActor protocol DeviceLibraryDelegate: AnyObject {
    func library(_ library: DeviceLibraryViewController, didSelect entry: FirmwareCatalog.Entry?)
    /// Row states changed; the selection didn't.
    func libraryRowsDidChange(_ library: DeviceLibraryViewController)
    func library(_ library: DeviceLibraryViewController, canPerform action: DeviceAction, for entry: FirmwareCatalog.Entry) -> Bool
    func library(_ library: DeviceLibraryViewController, perform action: DeviceAction, for entry: FirmwareCatalog.Entry)
    /// A dropped IPSW, with the row it was dropped on.
    func library(_ library: DeviceLibraryViewController, importIPSW url: URL, for entry: FirmwareCatalog.Entry?)
}

final class DeviceLibraryViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {

    /// Outline items are objects so the outline can keep and autosave them.
    private final class Group {
        let board: String
        let title: String
        let entries: [Entry]
        init(board: String, title: String, entries: [Entry]) { self.board = board; self.title = title; self.entries = entries }
    }
    private final class Entry {
        let entry: FirmwareCatalog.Entry
        init(_ entry: FirmwareCatalog.Entry) { self.entry = entry }
    }

    private static let expandedOnceKey = "deviceLibraryExpandedOnce"
    weak var delegate: DeviceLibraryDelegate?
    private let host: DeviceSessionHost
    private let groups: [Group]
    private let outline = NSOutlineView()
    private var rows: [String: DeviceRow] = [:]

    init(host: DeviceSessionHost) {
        self.host = host
        // Models in catalog order: the board's first entry places it.
        var boards: [String] = []
        for entry in host.catalog.entries where !boards.contains(entry.board) { boards.append(entry.board) }
        groups = boards.map { board in
            let entries = host.catalog.entries.filter { $0.board == board }
            return Group(board: board, title: entries[0].profile?.marketingName ?? entries[0].productType,
                         entries: entries.map { Entry($0) })
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("device"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.allowsEmptySelection = true
        outline.setAccessibilityLabel("Devices")
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.registerForDraggedTypes([.fileURL])

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll

        outline.reloadData()
        // Autosave needs the name AFTER the data source can answer, or the
        // restored items have nothing to match. Everything starts expanded;
        // from then on the saved state rules.
        outline.autosaveName = "DeviceLibrary"
        outline.autosaveExpandedItems = true
        if !UserDefaults.standard.bool(forKey: Self.expandedOnceKey) {
            groups.forEach { outline.expandItem($0) }
            UserDefaults.standard.set(true, forKey: Self.expandedOnceKey)
        }
        refresh()

        for name in [DeviceLibrary.didChangeNotification, DeviceSession.didChangeNotification,
                     DeviceSessionHost.didChangeNotification, FirmwareJobs.didChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(stateDidChange), name: name, object: nil)
        }
    }

    // MARK: - Selection

    var selectedEntry: FirmwareCatalog.Entry? { entry(at: outline.selectedRow) }

    func row(for entry: FirmwareCatalog.Entry) -> DeviceRow { rows[entry.id] ?? host.row(for: entry) }

    func select(_ entry: FirmwareCatalog.Entry) {
        loadViewIfNeeded()
        guard let group = groups.first(where: { $0.board == entry.board }),
              let item = group.entries.first(where: { $0.entry.id == entry.id }) else { return }
        outline.expandItem(group)
        let index = outline.row(forItem: item)
        guard index >= 0 else { return }
        outline.selectRowIndexes([index], byExtendingSelection: false)
        outline.scrollRowToVisible(index)
    }

    private func entry(at row: Int) -> FirmwareCatalog.Entry? {
        row < 0 ? nil : (outline.item(atRow: row) as? Entry)?.entry
    }

    /// The row a command acts on: the clicked one while its context menu is open.
    private var targetEntry: FirmwareCatalog.Entry? {
        outline.clickedRow >= 0 ? entry(at: outline.clickedRow) : selectedEntry
    }

    // MARK: - State

    @objc private func stateDidChange() { refresh() }

    /// Redraws only the rows whose state changed; status changes arrive often.
    private func refresh() {
        var changed = IndexSet()
        for group in groups {
            for item in group.entries {
                let row = host.row(for: item.entry)
                guard rows[item.entry.id] != row else { continue }
                rows[item.entry.id] = row
                let index = outline.row(forItem: item)
                if index >= 0 { changed.insert(index) }
            }
        }
        guard !changed.isEmpty else { return }
        outline.reloadData(forRowIndexes: changed, columnIndexes: [0])
        // The placeholder and menus read the same rows.
        delegate?.libraryRowsDidChange(self)
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? groups.count : (item as? Group)?.entries.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        item == nil ? groups[index] : (item as! Group).entries[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is Group }

    func outlineView(_ outlineView: NSOutlineView, persistentObjectForItem item: Any?) -> Any? {
        (item as? Group)?.board
    }

    func outlineView(_ outlineView: NSOutlineView, itemForPersistentObject object: Any) -> Any? {
        groups.first { $0.board == object as? String }
    }

    // MARK: - Delegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is Group }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is Entry }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        (item as? Entry).map { "iOS \($0.entry.version)" }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? Group {
            let cell = outlineView.makeView(withIdentifier: .init("group"), owner: nil) as? NSTableCellView
                ?? Self.groupCell()
            cell.textField?.stringValue = group.title
            return cell
        }
        guard let entry = (item as? Entry)?.entry else { return nil }
        let cell = outlineView.makeView(withIdentifier: DeviceRowCell.identifier, owner: nil) as? DeviceRowCell
            ?? DeviceRowCell()
        cell.update(row(for: entry))
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        delegate?.library(self, didSelect: selectedEntry)
    }

    private static func groupCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = .init("group")
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: - Context menu

    private static let menuActions: [(DeviceAction?, String)] = [
        (.start, "Start"), (.stop, "Stop"), (nil, ""),
        (.downloadAndPrepare, "Download & Prepare"), (.importIPSW, "Import IPSW…"), (.cancel, "Cancel"), (nil, ""),
        (.showInFinder, "Show in Finder"), (nil, ""),
        (.erase, "Erase All Content and Settings…"), (.delete, "Delete Device…"),
    ]

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let entry = targetEntry else { return }
        for (action, title) in Self.menuActions {
            guard let action else {
                if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
                continue
            }
            guard delegate?.library(self, canPerform: action, for: entry) == true else { continue }
            let item = NSMenuItem(title: title, action: #selector(contextAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            menu.addItem(item)
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
    }

    @objc private func contextAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? DeviceAction, let entry = targetEntry else { return }
        delegate?.library(self, perform: action, for: entry)
    }

    // MARK: - IPSW and .ipa drops

    private static func files(_ info: NSDraggingInfo, _ pathExtension: String) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                        options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension.lowercased() == pathExtension }
    }
    private static func ipsws(_ info: NSDraggingInfo) -> [URL] { files(info, "ipsw") }

    /// The running device behind a row that can take an .ipa now.
    private func installTarget(_ item: Any?) -> EmulatorController? {
        guard let entry = (item as? Entry)?.entry, let emulator = host.session(for: entry)?.emulator,
              emulator.canQueueInstall else { return nil }
        return emulator
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // An .ipa installs on the running device whose row it lands on.
        if !Self.files(info, "ipa").isEmpty {
            guard installTarget(item) != nil else { return [] }
            if index != NSOutlineViewDropOnItemIndex { outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex) }
            return .copy
        }
        guard !Self.ipsws(info).isEmpty else { return [] }
        // Onto a version row names the entry; anywhere else lets the catalog decide.
        if !(item is Entry) { outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex) }
        else if index != NSOutlineViewDropOnItemIndex { outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex) }
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let ipas = Self.files(info, "ipa")
        if !ipas.isEmpty {
            guard let emulator = installTarget(item) else { return false }
            ipas.forEach { AppInstaller.start($0, with: emulator, presenting: view.window) }
            return true
        }
        let urls = Self.ipsws(info)
        for url in urls { delegate?.library(self, importIPSW: url, for: (item as? Entry)?.entry) }
        return !urls.isEmpty
    }
}

// MARK: - Row cell

/// "iOS 3.2.2" with its build in the tooltip, an Experimental tag, and the
/// state accessory. VoiceOver reads the version, the tag and the state.
private final class DeviceRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("entry")

    private let title = NSTextField(labelWithString: "")
    private let experimentalTag = NSTextField(labelWithString: "Experimental")
    private let detail = NSTextField(labelWithString: "")
    private let ring = NSProgressIndicator()
    private let symbol = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        textField = title
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        experimentalTag.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        experimentalTag.textColor = .systemOrange
        experimentalTag.wantsLayer = true
        experimentalTag.layer?.cornerRadius = 4
        experimentalTag.layer?.borderWidth = 1
        experimentalTag.layer?.borderColor = NSColor.systemOrange.cgColor
        experimentalTag.alignment = .center
        experimentalTag.setAccessibilityLabel("Experimental")

        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right

        ring.style = .spinning
        ring.controlSize = .small
        ring.minValue = 0
        ring.maxValue = 1

        let stack = NSStackView()
        stack.setViews([title, experimentalTag], in: .leading)
        stack.setViews([detail, ring, symbol], in: .trailing)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            experimentalTag.widthAnchor.constraint(equalToConstant: experimentalTag.intrinsicContentSize.width + 8),
            ring.widthAnchor.constraint(equalToConstant: 16),
            ring.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ row: DeviceRow) {
        title.stringValue = row.title
        title.textColor = row.isDimmed ? .disabledControlTextColor : .labelColor
        toolTip = (["\(row.entry.productType) · iOS \(row.entry.version) (\(row.entry.build))"] + row.progressLines).joined(separator: "\n")
        experimentalTag.isHidden = !row.isExperimental

        detail.isHidden = true
        ring.isHidden = true
        ring.stopAnimation(nil)
        symbol.isHidden = true
        switch row.state {
        case let .notDownloaded(bytes):
            show(bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
        case .downloaded: show("Downloaded")
        case .bundled: show("Built In")
        case .downloading, .preparing:
            spin(fraction: row.progress)
            show(row.progressSummary)
        case .ready: break
        case .running: show(symbol: "circle.fill", color: .systemGreen, size: 8)
        case .stopping: spin(fraction: nil)
        case .error: show(symbol: "exclamationmark.triangle.fill", color: .systemYellow, size: 12)
        case .unavailable(.comingSoon): show("Coming Soon")
        case .unavailable(.requiresIPSW): show("Requires IPSW")
        }
        if let note = row.note, detail.isHidden { show(note) }
        // One element per row for VoiceOver: "iOS 3.2.2, Experimental, Running".
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
        setAccessibilityLabel(([row.title] + (row.isExperimental ? ["Experimental"] : []) + [row.stateDescription] + [row.note].compactMap { $0 })
            .joined(separator: ", "))
        if case let .error(reason) = row.state { setAccessibilityHelp(reason) } else { setAccessibilityHelp(nil) }
    }

    private func show(_ text: String?) {
        guard let text else { return }
        detail.stringValue = text
        detail.isHidden = false
    }

    private func spin(fraction: Double?) {
        ring.isIndeterminate = fraction == nil
        if let fraction { ring.doubleValue = fraction } else { ring.startAnimation(nil) }
        ring.isHidden = false
    }

    private func show(symbol name: String, color: NSColor, size: CGFloat) {
        symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        symbol.contentTintColor = color
        symbol.isHidden = false
    }
}
