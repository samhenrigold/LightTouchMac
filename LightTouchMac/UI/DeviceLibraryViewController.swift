// The sidebar: the catalog entries the user added (SidebarList), in catalog
// order, each with a trailing accessory for its state (docs/multi-device-plan.md,
// C). Double-click renames in place; Delete removes. Commands
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

final class DeviceLibraryViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {

    /// Outline items are objects so the outline can keep them.
    private final class Entry {
        let entry: FirmwareCatalog.Entry
        init(_ entry: FirmwareCatalog.Entry) { self.entry = entry }
    }

    weak var delegate: DeviceLibraryDelegate?
    /// The toolbar's and the empty sidebar's Add Device….
    var onAdd: (() -> Void)?
    private let host: DeviceSessionHost
    private let defaults: UserDefaults
    private(set) var list: SidebarList
    private var items: [Entry] = []
    private let outline = SidebarOutlineView()
    private let addButton = NSButton(title: "Add Device…", target: nil, action: nil)
    private var rows: [String: DeviceRow] = [:]
    private var cancelledRename = false

    init(host: DeviceSessionHost, defaults: UserDefaults = .standard) {
        self.host = host
        self.defaults = defaults
        list = SidebarList.load(defaults, catalog: host.catalog) { entry in
            host.instance(for: entry) != nil || host.row(for: entry).state == .downloaded || FirmwareJobs.shared.jobs[entry.id] != nil
        }
        super.init(nibName: nil, bundle: nil)
        items = list.entries(in: host.catalog).map { Entry($0) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("device"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.dataSource = self
        outline.delegate = self
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.setAccessibilityLabel("Devices")
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.registerForDraggedTypes([.fileURL])
        outline.target = self
        outline.doubleAction = #selector(renameClicked(_:))
        outline.onDelete = { [weak self] in self?.targetEntry.map { self?.remove($0) } }

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        addButton.bezelStyle = .push
        addButton.target = self
        addButton.action = #selector(addClicked(_:))
        let container = NSView()
        for child in [scroll, addButton] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            addButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            addButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container

        outline.reloadData()
        refresh()

        for name in [DeviceLibrary.didChangeNotification, DeviceSession.didChangeNotification,
                     DeviceSessionHost.didChangeNotification, FirmwareJobs.didChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(stateDidChange), name: name, object: nil)
        }
    }

    // MARK: - The list

    var isEmpty: Bool { items.isEmpty }
    var entries: [FirmwareCatalog.Entry] { items.map(\.entry) }

    /// The row's name in titles and alerts: the user's, else nil.
    func customName(for entry: FirmwareCatalog.Entry) -> String? { list.names[entry.id] }

    /// Adds entries (the Add Device sheet) and selects the first of them.
    func add(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        list.add(ids)
        listDidChange()
        if let first = ids.first.flatMap(host.catalog.entry(id:)) { select(first) }
    }

    /// Delete / Remove Device: a prepared device goes through the delegate's delete (it asks first, then calls
    /// `removeFromList`); one with nothing on disk leaves the list at once.
    func remove(_ entry: FirmwareCatalog.Entry) {
        let row = row(for: entry)
        if row.instanceID != nil {
            delegate?.library(self, perform: .delete, for: entry)
        } else if row.canRemoveFromSidebar {
            removeFromList(entry)
        }
    }

    func removeFromList(_ entry: FirmwareCatalog.Entry) {
        let index = items.firstIndex { $0.entry.id == entry.id }
        list.remove(entry.id)
        listDidChange()
        // The next row takes the selection, as in Finder.
        if let index, !items.isEmpty {
            outline.selectRowIndexes([min(index, items.count - 1)], byExtendingSelection: false)
        }
    }

    /// Saves, rebuilds the rows (labels depend on every row: one kind of device or several), keeps the selection.
    private func listDidChange() {
        list.save(defaults)
        let selected = selectedEntry?.id
        items = list.entries(in: host.catalog).map { Entry($0) }
        rows = [:]
        outline.reloadData()
        if let selected, let index = items.firstIndex(where: { $0.entry.id == selected }) {
            outline.selectRowIndexes([index], byExtendingSelection: false)
        } else {
            outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification))
        }
        refresh()
    }

    /// A device prepared, a download started or an IPSW dropped for an entry not in the list: it joins the list.
    private func adoptOwned() {
        // A failed job stays listed for its row's error; it doesn't bring back a row the user removed.
        let running = FirmwareJobs.shared.jobs.compactMap { id, job -> String? in if case .failed = job { nil } else { id } }
        let owned = host.library.instances.map(\.firmware) + running
        if list.add(owned.filter { host.catalog.entry(id: $0) != nil }) { listDidChange() }
    }

    // MARK: - Selection

    var selectedEntry: FirmwareCatalog.Entry? { entry(at: outline.selectedRow) }

    func row(for entry: FirmwareCatalog.Entry) -> DeviceRow { rows[entry.id] ?? host.row(for: entry) }

    func contains(_ entry: FirmwareCatalog.Entry) -> Bool { list.contains(entry.id) }

    func select(_ entry: FirmwareCatalog.Entry) {
        loadViewIfNeeded()
        adoptOwned()
        guard let index = items.firstIndex(where: { $0.entry.id == entry.id }) else { return }
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

    @objc private func stateDidChange() { adoptOwned(); refresh() }

    /// Redraws only the rows whose state changed; status changes arrive often.
    private func refresh() {
        addButton.isHidden = !items.isEmpty
        var changed = IndexSet()
        for (index, item) in items.enumerated() {
            let row = host.row(for: item.entry)
            guard rows[item.entry.id] != row else { continue }
            rows[item.entry.id] = row
            changed.insert(index)
        }
        guard !changed.isEmpty else { return }
        outline.reloadData(forRowIndexes: changed, columnIndexes: [0])
        // The placeholder and menus read the same rows.
        delegate?.libraryRowsDidChange(self)
    }

    @objc private func addClicked(_ sender: Any?) { onAdd?() }

    // MARK: - Rename

    @objc private func renameClicked(_ sender: Any?) {
        guard outline.clickedRow >= 0 else { return }
        beginRename(row: outline.clickedRow)
    }

    @objc private func renameFromMenu(_ sender: Any?) {
        guard let entry = targetEntry, let index = items.firstIndex(where: { $0.entry.id == entry.id }) else { return }
        beginRename(row: index)
    }

    /// Standard source-list rename: the title becomes an editable field in place.
    private func beginRename(row index: Int) {
        guard let cell = outline.view(atColumn: 0, row: index, makeIfNecessary: false) as? DeviceRowCell else { return }
        outline.selectRowIndexes([index], byExtendingSelection: false)
        cancelledRename = false
        cell.beginEditing(delegate: self)
        outline.editColumn(0, row: index, with: nil, select: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelledRename = true
        control.abortEditing()
        finishRename(control)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        finishRename(field)
    }

    private func finishRename(_ control: NSControl) {
        let index = outline.row(for: control)
        (outline.view(atColumn: 0, row: max(index, 0), makeIfNecessary: false) as? DeviceRowCell)?.endEditing()
        guard index >= 0, let entry = entry(at: index) else { return }
        if !cancelledRename {
            let mixed = Set(items.map(\.entry.board)).count > 1
            list.rename(entry.id, to: control.stringValue, defaultTitle: SidebarList.label(for: entry, name: nil, mixed: mixed).title)
        }
        cancelledRename = true   // one finish per edit
        listDidChange()
        view.window?.makeFirstResponder(outline)
        delegate?.libraryRowsDidChange(self)
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? items.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { items[index] }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

    // MARK: - Delegate

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        (item as? Entry).map { list.label(for: $0.entry, in: host.catalog).title }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let entry = (item as? Entry)?.entry, list.label(for: entry, in: host.catalog).subtitle != nil else { return 24 }
        return 38
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let entry = (item as? Entry)?.entry else { return nil }
        let cell = outlineView.makeView(withIdentifier: DeviceRowCell.identifier, owner: nil) as? DeviceRowCell
            ?? DeviceRowCell()
        cell.update(row(for: entry), label: list.label(for: entry, in: host.catalog))
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        delegate?.library(self, didSelect: selectedEntry)
    }

    // MARK: - Context menu

    private static let menuActions: [(DeviceAction?, String)] = [
        (.start, "Start"), (.stop, "Stop"), (nil, ""),
        (.downloadAndPrepare, "Download & Prepare"), (.importIPSW, "Import IPSW…"), (.cancel, "Cancel"), (nil, ""),
        (.showInFinder, "Show in Finder"),
        (.openFilesystem, "Open Filesystem in Finder"), (.commitFilesystem, "Save Filesystem Edits"),
        (.discardFilesystem, "Discard Filesystem Edits"), (.recoverFilesystem, "Finish Filesystem Recovery"), (nil, ""),
        (.erase, "Erase All Content and Settings…"),
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
        if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
        let rename = NSMenuItem(title: "Rename", action: #selector(renameFromMenu(_:)), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)
        let row = row(for: entry)
        if row.canRemoveFromSidebar {
            let remove = NSMenuItem(title: row.removeTitle, action: #selector(removeFromMenu(_:)), keyEquivalent: "")
            remove.target = self
            menu.addItem(remove)
        }
    }

    @objc private func removeFromMenu(_ sender: Any?) { targetEntry.map(remove) }

    @objc private func contextAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? DeviceAction, let entry = targetEntry else { return }
        delegate?.library(self, perform: action, for: entry)
    }

    // MARK: - IPSW and .ipa drops

    private static func files(_ info: NSDraggingInfo, _ kind: DroppedFiles) -> [URL] {
        DroppedFiles.files(info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [], kind)
    }
    private static func ipsws(_ info: NSDraggingInfo) -> [URL] { files(info, .ipsw) }

    /// The running device behind a row that can take an .ipa now.
    private func installTarget(_ item: Any?) -> EmulatorController? {
        guard let entry = (item as? Entry)?.entry, let emulator = host.session(for: entry)?.emulator,
              emulator.canQueueInstall else { return nil }
        return emulator
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // An .ipa installs on the running device whose row it lands on.
        if !Self.files(info, .ipa).isEmpty {
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
        let ipas = Self.files(info, .ipa)
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

// MARK: - Outline

/// Delete and Forward Delete remove the selected row (Remove Device, or Delete Device… for a prepared one).
private final class SidebarOutlineView: NSOutlineView {
    var onDelete: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if [.delete, .deleteForward].contains(event.specialKey), event.modifierFlags.isDisjoint(with: [.command, .option, .control]) {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Row cell

/// The row's title (SidebarList.Label) with a Beta 3 / GM 1 tag in secondary text, the device and version under it
/// when the title doesn't say them, and the state accessory only when it isn't the usual (DeviceRow.accessory).
/// VoiceOver reads the title, the subtitle, the tag, the state and how well the build is tested.
final class DeviceRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("entry")

    private let title = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let ring = NSProgressIndicator()
    private let symbol = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        textField = title
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        badge.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        badge.textColor = .secondaryLabelColor
        badge.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right

        ring.style = .spinning
        ring.controlSize = .small
        ring.minValue = 0
        ring.maxValue = 1

        let titleLine = NSStackView(views: [title, badge])
        titleLine.spacing = 6
        let text = NSStackView(views: [titleLine, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.detachesHiddenViews = true
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView()
        stack.setViews([text], in: .leading)
        stack.setViews([detail, ring, symbol], in: .trailing)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: 16),
            ring.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Only while renaming: a click on a selected row must not start an edit.
    func beginEditing(delegate: NSTextFieldDelegate) {
        title.isEditable = true
        title.delegate = delegate
    }

    func endEditing() {
        title.isEditable = false
        title.delegate = nil
    }

    func update(_ row: DeviceRow, label: SidebarList.Label) {
        title.stringValue = label.title
        title.textColor = row.isDimmed ? .disabledControlTextColor : .labelColor
        subtitle.stringValue = label.subtitle ?? ""
        subtitle.isHidden = label.subtitle == nil
        let size = row.entry.source.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        toolTip = (["\(row.entry.productType) · iOS \(row.entry.version) (\(row.entry.build))",
                    row.supportNote, row.accessory == .notDownloaded ? size.map { "Not downloaded, \($0)" } ?? "Not downloaded" : nil]
                   + row.progressDetail + [row.progressLine]).compactMap { $0 }.joined(separator: "\n")
        badge.stringValue = label.badge ?? ""
        badge.isHidden = label.badge == nil

        detail.isHidden = true
        ring.isHidden = true
        ring.stopAnimation(nil)
        symbol.isHidden = true
        switch row.accessory {
        case .none: break
        case .notDownloaded: show(symbol: "arrow.down.circle", color: .tertiaryLabelColor, size: 12)
        case let .progress(fraction, summary):
            spin(fraction: fraction)
            show(summary)
        case .running: show(symbol: "circle.fill", color: .systemGreen, size: 8)
        case .stopping: spin(fraction: nil)
        case .error: show(symbol: "exclamationmark.triangle.fill", color: .systemYellow, size: 12)
        case let .text(text): show(text)
        }
        if let note = row.note, detail.isHidden { show(note) }
        // One element per row for VoiceOver: "iPad, iOS 4.2.1, Beta 1, Running, Untested".
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
        setAccessibilityLabel(([label.title] + [label.subtitle, label.badge, row.stateDescription, row.note, row.supportNote].compactMap { $0 })
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
