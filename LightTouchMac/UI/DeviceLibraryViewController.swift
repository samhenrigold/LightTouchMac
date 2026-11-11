// The sidebar: the catalog entries the user added (SidebarList), in catalog
// order, each with a trailing accessory for its state.
// Double-click renames in place; Delete removes. Commands
// go to the window controller, which owns what they do; this view only says
// which entry they are for (the clicked row for its context menu, the
// selection otherwise).

import Cocoa
import FirmwareSchema
import HostRuntime
import LightTouchCore
import UniformTypeIdentifiers

@MainActor protocol DeviceLibraryDelegate: AnyObject {
    func library(_ library: DeviceLibraryViewController, didSelect entry: FirmwareCatalog.Entry?)
    /// Row states changed; the selection didn't.
    func libraryRowsDidChange(_ library: DeviceLibraryViewController)
    /// Sessions started, ended or were replaced, which can leave every row as it was.
    func librarySessionsDidChange(_ library: DeviceLibraryViewController)
    func library(
        _ library: DeviceLibraryViewController,
        canPerform action: DeviceAction,
        for entry: FirmwareCatalog.Entry
    ) -> Bool
    func library(_ library: DeviceLibraryViewController, perform action: DeviceAction, for entry: FirmwareCatalog.Entry)
    /// A command on several rows: the rows it applies to, after one question for the lot where the command asks.
    func library(_ library: DeviceLibraryViewController, perform batch: DeviceBatch<FirmwareCatalog.Entry>)
    /// Dropped IPSWs or folders of them, with the row they were dropped on.
    func library(_ library: DeviceLibraryViewController, importIPSWs urls: [URL], for entry: FirmwareCatalog.Entry?)
}

final class DeviceLibraryViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSMenuDelegate, NSTextFieldDelegate,
    NSMenuItemValidation
{
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
        // A cached IPSW isn't a device: Caches outlives a reset, and listing every download floods a fresh sidebar.
        list = SidebarList.load(defaults, catalog: host.catalog) { entry in
            host.instance(for: entry) != nil || FirmwareJobs.shared.jobs[entry.id] != nil
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
        // ⌘-click, ⇧-click and ⌘A pick several rows for one Delete; every other command wants exactly one.
        outline.allowsMultipleSelection = true
        outline.setAccessibilityLabel("Devices")
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.registerForDraggedTypes([.fileURL])
        outline.target = self
        outline.doubleAction = #selector(renameClicked(_:))
        outline.onRename = { [weak self] row in self?.beginRename(row: row) }

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
            addButton.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        view = container

        outline.reloadData()
        refresh()

        for name in [
            DeviceLibrary.didChangeNotification, FirmwareJobs.didChangeNotification, IPSWStore.didChangeNotification
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(stateDidChange), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionsDidChange),
            name: DeviceSessionHost.didChangeNotification,
            object: nil
        )
        // Settings ▸ General's Device Names: every row's name, and the window's title with it.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nameStyleDidChange),
            name: Board.NameStyle.didChangeNotification,
            object: nil
        )
        sessionTracking = ObservationLoop(
            read: { [weak self] in self?.trackedSessionState() },
            onChange: { [weak self] in self?.stateDidChange() }
        )
    }

    /// What a row shows of its running device: the session's phase (running, stopping, stopped, dead and why).
    /// The host's notification says when the sessions themselves come and go: the tracking follows them.
    private var sessionTracking: ObservationLoop?
    private func trackedSessionState() { for session in host.sessions { _ = session.phase } }
    @objc private func sessionsDidChange() {
        sessionTracking?.rearm()
        stateDidChange()
        delegate?.librarySessionsDidChange(self)
    }

    // MARK: - The list

    var isEmpty: Bool { items.isEmpty }
    var entries: [FirmwareCatalog.Entry] { items.map(\.entry) }

    /// The row's name in titles and alerts: the user's, else nil.
    func customName(for entry: FirmwareCatalog.Entry) -> String? { list.names[entry.id] }

    /// What the row says; the window's title and subtitle say the same.
    func label(for entry: FirmwareCatalog.Entry) -> SidebarList.Label { list.label(for: entry) }

    /// The row in an alert or a panel: “Lab iPad”, else iPad iOS 3.2.2.
    func displayName(for entry: FirmwareCatalog.Entry) -> String {
        SidebarList.reference(for: entry, name: customName(for: entry))
    }

    /// Edit ▸ Delete while the sidebar has the focus.
    @objc func delete(_ sender: Any?) { removeTargets() }

    /// Dims Edit ▸ Delete and the several-row Delete when none of the rows can go.
    var canRemoveTargets: Bool {
        let targets = targetEntries
        guard targets.count > 1 else {
            return targets.first.map { row(for: $0) }.map {
                $0.instanceID != nil
                    ? delegate?.library(self, canPerform: .delete, for: $0.entry) == true : $0.canRemoveFromSidebar
            } ?? false
        }
        return !batch(targets).isEmpty
    }

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
        FirmwareJobs.shared.dismissFailure(entry)
        list.remove(entry.id)
        listDidChange()
        // The next row takes the selection, as in Finder.
        if let index, !items.isEmpty {
            outline.selectRowIndexes([min(index, items.count - 1)], byExtendingSelection: false)
        }
    }

    /// Saves, rebuilds the rows, keeps the selection.
    private func listDidChange() {
        list.save(defaults)
        NotificationCenter.default.post(name: SidebarList.didChangeNotification, object: nil)
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
        let running = FirmwareJobs.shared.jobs.compactMap { id, job -> String? in
            if case .failed = job { nil } else { id }
        }
        let owned = host.library.instances.map(\.firmware) + running
        if list.add(owned.filter { host.catalog.entry(id: $0) != nil }) { listDidChange() }
    }

    /// What Delete does with several rows: rows with nothing on disk leave the list, prepared devices are deleted
    /// (after one question for the lot), running ones and ones with a job in flight are skipped.
    struct Batch {
        var remove: [FirmwareCatalog.Entry] = []
        var delete: [FirmwareCatalog.Entry] = []
        var skipped: [FirmwareCatalog.Entry] = []
        var isEmpty: Bool { remove.isEmpty && delete.isEmpty }
    }

    func batch(_ entries: [FirmwareCatalog.Entry]) -> Batch {
        var batch = Batch()
        for entry in entries {
            let row = row(for: entry)
            if row.instanceID != nil, row.canRemoveFromSidebar,
                delegate?.library(self, canPerform: .delete, for: entry) == true
            {
                batch.delete.append(entry)
            } else if row.instanceID == nil, row.canRemoveFromSidebar {
                batch.remove.append(entry)
            } else {
                batch.skipped.append(entry)
            }
        }
        return batch
    }

    /// Delete, Edit ▸ Delete, File ▸ Delete Device… and the context menu: one row goes the single-row way
    /// (`remove`); several ask once if any is prepared, else leave at once.
    func removeTargets() {
        let targets = targetEntries
        guard targets.count > 1 else {
            targets.first.map(remove)
            return
        }
        let batch = batch(targets)
        guard !batch.isEmpty else { return }
        guard !batch.delete.isEmpty, let window = view.window else { return finish(batch) }
        presentAlert(Self.batchAlert(batch, name: displayName(for:)), window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            // Asked again on the answer: a device started while the question was up stays.
            finish(self.batch(batch.remove + batch.delete))
        }
    }

    /// Shows the batch question and a failed deletion; a check answers them without a window on screen.
    var presentAlert: (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = {
        alert,
        window,
        done in
        alert.beginSheetModal(for: window, completionHandler: done)
    }

    static func batchAlert(_ batch: Batch, name: (FirmwareCatalog.Entry) -> String) -> NSAlert {
        let count = batch.remove.count + batch.delete.count
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = count == 1 ? "Delete \(name(batch.delete[0]))?" : "Delete \(count) devices?"
        var info =
            "This permanently removes the apps, settings, and saved state of "
            + ListFormatter.localizedString(byJoining: batch.delete.map(name)) + "."
        if !batch.skipped.isEmpty {
            info +=
                " " + ListFormatter.localizedString(byJoining: batch.skipped.map(name))
                + (batch.skipped.count == 1 ? " is" : " are") + " running or busy and stays."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return alert
    }

    /// Rows with nothing on disk leave now; prepared devices show Deleting and each leaves when its storage is gone.
    /// Failures stay listed and are reported together once every deletion has ended.
    private func finish(_ batch: Batch) {
        let deletions = batch.delete.compactMap { entry in host.instance(for: entry).map { (entry, host.delete($0)) } }
        for entry in batch.remove { list.remove(entry.id) }
        listDidChange()
        guard !deletions.isEmpty else { return }
        Task {
            var errors: [Error] = []
            for (entry, deletion) in deletions {
                do {
                    try await deletion.value
                    list.remove(entry.id)
                    listDidChange()
                } catch { errors.append(error) }
            }
            if let error = errors.first, let window = view.window {
                presentAlert(NSAlert(error: error), window) { _ in }
            }
        }
    }

    // MARK: - Selection

    /// The one selected row; nil with none or several (single-device commands need exactly one).
    var selectedEntry: FirmwareCatalog.Entry? {
        outline.selectedRowIndexes.count == 1 ? entry(at: outline.selectedRow) : nil
    }
    var selectedEntries: [FirmwareCatalog.Entry] { outline.selectedRowIndexes.compactMap(entry(at:)) }

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

    /// The rows a command acts on: while a context menu is open, the selection if the clicked row is in it, else
    /// the clicked row alone (AppKit's rule); otherwise the selection.
    var targetEntries: [FirmwareCatalog.Entry] {
        let clicked = outline.clickedRow
        guard clicked >= 0, !outline.selectedRowIndexes.contains(clicked) else { return selectedEntries }
        return entry(at: clicked).map { [$0] } ?? []
    }

    /// A command on several rows (DeviceBatch): the targets the window can do it for; nil with one row or none.
    func commandBatch(_ action: DeviceAction) -> DeviceBatch<FirmwareCatalog.Entry>? {
        let targets = targetEntries
        guard targets.count > 1 else { return nil }
        return DeviceBatch(action, targets) { delegate?.library(self, canPerform: action, for: $0) == true }
    }

    /// A single-row command's row: the one target, nil with several.
    private var targetEntry: FirmwareCatalog.Entry? {
        let targets = targetEntries
        return targets.count == 1 ? targets[0] : nil
    }

    // MARK: - State

    @objc private func nameStyleDidChange() { listDidChange() }

    @objc private func stateDidChange() {
        adoptOwned()
        refresh()
    }

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
        // In place, not reloadData: a reload replaces the cell and ends a rename in progress (a preparing row changes
        // every second).
        for index in changed {
            let entry = items[index].entry
            (outline.view(atColumn: 0, row: index, makeIfNecessary: false) as? DeviceRowCell)?.update(
                row(for: entry),
                label: list.label(for: entry)
            )
        }
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
            list.rename(entry.id, to: control.stringValue, defaultTitle: SidebarList.label(for: entry, name: nil).title)
        }
        cancelledRename = true  // one finish per edit
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

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any)
        -> String?
    {
        (item as? Entry).map { list.label(for: $0.entry).title }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { 38 }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let entry = (item as? Entry)?.entry else { return nil }
        let cell =
            outlineView.makeView(withIdentifier: DeviceRowCell.identifier, owner: nil) as? DeviceRowCell
            ?? DeviceRowCell()
        cell.update(row(for: entry), label: list.label(for: entry))
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        delegate?.library(self, didSelect: selectedEntry)
    }

    // MARK: - Context menu

    /// `.start` stands for the Start/Stop toggle; `.cancel` is always listed, dimmed while there is nothing to cancel.
    private static let menuActions: [(DeviceAction?, String)] = [
        (.start, "Start"), (.forceStop, "Force Stop…"), (nil, ""),
        (.downloadAndPrepare, "Download and Prepare"), (.importIPSW, "Import IPSW…"), (.cancel, "Cancel"), (nil, ""),
        (.showInFinder, "Show in Finder"),
        (.openFilesystem, "Show File System in Finder"), (.commitFilesystem, "Save File System Changes"),
        (.discardFilesystem, "Discard File System Changes"), (.recoverFilesystem, "Finish File System Recovery"),
        (nil, ""),
        (.jailbreak, "Jailbreak…"), (.erase, "Erase All Content and Settings…")
    ]

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let targets = targetEntries
        if targets.count > 1 {
            // Each command for the rows it applies to, with how many; dimmed when none does.
            for action in [DeviceAction.start, .forceStop, nil, .jailbreak, .erase, nil] {
                guard let action, let batch = commandBatch(action) else {
                    menu.addItem(.separator())
                    continue
                }
                let item = NSMenuItem(title: batch.title, action: #selector(batchAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = action
                menu.addItem(item)
            }
            let batch = batch(targets)
            let remove = NSMenuItem(
                title: Self.batchTitle(batch),
                action: #selector(removeFromMenu(_:)),
                keyEquivalent: ""
            )
            remove.target = self
            menu.addItem(remove)
            return
        }
        guard let entry = targetEntry else { return }
        for (action, title) in Self.menuActions {
            guard let action else {
                if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
                continue
            }
            // One item whose title follows the row: Shut Down while it runs, Start otherwise.
            let running = [.running, .stopping].contains(row(for: entry).state)
            let (command, label) =
                action == .start && running
                ? (DeviceAction.stop, "Shut Down…")
                : action == .downloadAndPrepare
                    ? (action, row(for: entry).prepareTitle)
                    : action == .cancel ? (action, row(for: entry).cancelTitle) : (action, title)
            let item = NSMenuItem(title: label, action: #selector(contextAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command
            menu.addItem(item)
        }
        if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
        let rename = NSMenuItem(title: "Rename", action: #selector(renameFromMenu(_:)), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)
        let remove = NSMenuItem(
            title: row(for: entry).removeTitle,
            action: #selector(removeFromMenu(_:)),
            keyEquivalent: ""
        )
        remove.target = self
        menu.addItem(remove)
    }

    @objc private func removeFromMenu(_ sender: Any?) { removeTargets() }

    /// Every command is listed, Cancel too (never hidden, only disabled); what doesn’t apply now is dimmed.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(batchAction(_:)), let action = item.representedObject as? DeviceAction {
            return commandBatch(action)?.isEnabled == true
        }
        if item.action == #selector(contextAction(_:)), let action = item.representedObject as? DeviceAction {
            return targetEntry.map { delegate?.library(self, canPerform: action, for: $0) == true } ?? false
        }
        return [#selector(delete(_:)), #selector(removeFromMenu(_:))].contains(item.action) ? canRemoveTargets : true
    }

    /// The several-row Delete's title: Delete N Devices… when any is prepared (it asks), else Remove N Devices.
    static func batchTitle(_ batch: Batch) -> String {
        let count = batch.remove.count + batch.delete.count
        let noun = count == 1 ? "Device" : count == 0 ? "Devices" : "\(count) Devices"
        return batch.delete.isEmpty ? "Remove \(noun)" : "Delete \(noun)…"
    }

    @objc private func contextAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? DeviceAction, let entry = targetEntry else { return }
        delegate?.library(self, perform: action, for: entry)
    }

    @objc private func batchAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? DeviceAction, let batch = commandBatch(action),
            batch.isEnabled
        else { return }
        delegate?.library(self, perform: batch)
    }

    // MARK: - IPSW and .ipa drops

    private static func files(_ info: NSDraggingInfo, _ kind: DroppedFiles) -> [URL] {
        DroppedFiles.files(
            info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? [],
            kind
        )
    }
    private static func ipsws(_ info: NSDraggingInfo) -> [URL] { files(info, .ipsw) }

    /// The running device behind a row that can take an .ipa now.
    private func installTarget(_ item: Any?) -> EmulatorController? {
        guard let entry = (item as? Entry)?.entry, let emulator = host.session(for: entry)?.emulator,
            emulator.canQueueInstall
        else { return nil }
        return emulator
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        // An .ipa installs on the running device whose row it lands on.
        if !Self.files(info, .ipa).isEmpty {
            guard installTarget(item) != nil else { return [] }
            if index != NSOutlineViewDropOnItemIndex {
                outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
            }
            return .copy
        }
        guard !Self.ipsws(info).isEmpty else { return [] }
        // Onto a version row names the entry; anywhere else lets the catalog decide.
        if !(item is Entry) {
            outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        } else if index != NSOutlineViewDropOnItemIndex {
            outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
        }
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int)
        -> Bool
    {
        let ipas = Self.files(info, .ipa)
        if !ipas.isEmpty {
            guard let emulator = installTarget(item) else { return false }
            for ipa in ipas { AppInstaller.start(ipa, with: emulator, presenting: view.window) }
            return true
        }
        let urls = Self.ipsws(info)
        guard !urls.isEmpty else { return false }
        delegate?.library(self, importIPSWs: urls, for: (item as? Entry)?.entry)
        return true
    }
}

// MARK: - Outline

/// Return on one selected row renames it, as in the Finder's sidebar. Delete and Forward Delete do nothing: a row
/// goes with File ▸ Delete Device… (⌘⌫), Edit ▸ Delete or the context menu.
private final class SidebarOutlineView: NSOutlineView {
    var onRename: ((Int) -> Void)?
    override func keyDown(with event: NSEvent) {
        if [.carriageReturn, .enter].contains(event.specialKey),
            event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]), selectedRowIndexes.count == 1
        {
            onRename?(selectedRow)
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Row cell

/// Two lines (SidebarList.Label): the marketing name or custom name over the version, and the state accessory only
/// when it isn't the usual (DeviceRow.accessory). VoiceOver reads both lines, the state and how well the build is tested.
final class DeviceRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("entry")

    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let ring = NSProgressIndicator()
    private let symbol = NSImageView()
    /// The device's artwork (Board.icon), sized to the row: as the cell's imageView, selection restyles it.
    private let icon = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        textField = title
        imageView = icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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

        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView()
        stack.setViews([icon, text], in: .leading)
        stack.setViews([detail, ring, symbol], in: .trailing)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            ring.widthAnchor.constraint(equalToConstant: 16),
            ring.heightAnchor.constraint(equalToConstant: 16)
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
        if !title.isEditable { title.stringValue = label.title }
        title.textColor = row.isDimmed ? .disabledControlTextColor : .labelColor
        subtitle.stringValue = label.subtitle
        icon.image = row.entry.profile?.icon
        icon.isHidden = icon.image == nil
        icon.alphaValue = row.isDimmed ? 0.5 : 1
        let size = row.entry.source.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        toolTip =
            ([
                "iOS \(row.entry.version) (\(row.entry.build))",
                row.supportNote,
                row.accessory == .notDownloaded ? size.map { "Not downloaded, \($0)" } ?? "Not downloaded" : nil
            ]
            + [row.progressHeadline] + row.progressDetail + [row.progressLine]).compactMap { $0 }.joined(
                separator: "\n"
            )

        detail.isHidden = true
        ring.isHidden = true
        ring.stopAnimation(nil)
        symbol.isHidden = true
        switch row.accessory {
        case .none: break
        case .notDownloaded: show(symbol: "arrow.down.circle", color: .tertiaryLabelColor, size: 12)
        case .progress(let fraction): spin(fraction: fraction)
        case .running: show(symbol: "circle.fill", color: .systemGreen, size: 8)
        case .stopping: spin(fraction: nil)
        case .error: show(symbol: "exclamationmark.triangle.fill", color: .systemYellow, size: 12)
        case .text(let text): show(text)
        }
        if let note = row.note, detail.isHidden { show(note) }
        // One element per row for VoiceOver: "iPad1,1, iOS 4.2 beta 1, Running, Untested".
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
        setAccessibilityLabel(
            ([label.title, label.subtitle, row.stateDescription] + [row.note, row.supportNote].compactMap { $0 })
                .joined(separator: ", ")
        )
        if case .error(let reason) = row.state { setAccessibilityHelp(reason) } else { setAccessibilityHelp(nil) }
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
