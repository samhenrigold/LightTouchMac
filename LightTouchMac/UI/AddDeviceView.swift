// The Add Device sheet: the firmware catalog split by device. Devices on the left, with their artwork and how many of
// their versions are picked; the chosen device's versions on the right, in version order, each with its support
// status and whether its IPSW is here (else its download size), and below them the picks (AddDeviceSummary). Versions
// already in the sidebar are checked and can't be picked again; Coming Soon versions show dimmed and can't be picked. Only stable builds show until Show experimental is on
// (remembered). Picks survive switching devices; Add adds them all. The versions list has the keyboard focus when the
// sheet opens, so the arrow keys move through versions; Tab and Shift-Tab go between it and the devices.
// A sheet, not a window: it belongs to the one main window and is done before the user goes on (HIG, Sheets).

import FirmwareSchema
import HostRuntime
import LightTouchCore
import SwiftUI

struct AddDeviceView: View {
    struct Group: Identifiable {
        let id: String
        let name: String
        let icon: NSImage
        let entries: [FirmwareCatalog.Entry]
    }

    let groups: [Group]
    let added: Set<String>
    let downloaded: Set<String>
    /// Entries the bundled guest tools have a package for (GuestPackage.packaged).
    let guestPackaged: Set<String>
    let onAdd: ([String]) -> Void
    let onCancel: () -> Void
    @State private var selection: Set<String>
    @State private var device: String?
    @AppStorage("addDeviceShowsExperimental") private var showsExperimental = false

    init(
        catalog: FirmwareCatalog,
        added: Set<String>,
        downloaded: Set<String>,
        guestPackaged: Set<String> = [],
        selection: Set<String> = [],
        device: String? = nil,
        onAdd: @escaping ([String]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        var boards: [String] = []
        for entry in catalog.entries where !boards.contains(entry.board) { boards.append(entry.board) }
        groups = boards.map { board in
            let entries = catalog.entries.filter { $0.board == board }
            let profile = entries[0].profile
            return Group(
                id: board,
                name: profile?.preferredName ?? entries[0].productType,
                icon: profile?.icon
                    ?? Board.icon(modelCode: entries[0].productType, fallbackSymbol: "questionmark.square.dashed"),
                entries: entries
            )
        }
        self.added = added
        self.downloaded = downloaded
        self.guestPackaged = guestPackaged
        self.onAdd = onAdd
        self.onCancel = onCancel
        _selection = State(initialValue: selection)
        _device = State(initialValue: device ?? catalog.entries.first { selection.contains($0.id) }?.board)
    }

    /// Stable: supported (`available`), or a release supported from the user's own IPSW (not a beta or GM).
    static func isStable(_ entry: FirmwareCatalog.Entry) -> Bool {
        entry.status == .available || (entry.status == .userIPSW && entry.prerelease == nil)
    }

    /// `groups` with only their stable builds unless `experimental`; a device left with none goes.
    static func shown(_ groups: [Group], experimental: Bool) -> [Group] {
        experimental
            ? groups
            : groups.compactMap { group in
                let entries = group.entries.filter(isStable)
                return entries.isEmpty ? nil : Group(id: group.id, name: group.name, icon: group.icon, entries: entries)
            }
    }

    /// What Add adds: the selected entries still shown, not already added and not coming soon, in catalog order,
    /// whichever device they're under.
    static func picked(_ groups: [Group], selection: Set<String>, added: Set<String>) -> [String] {
        groups.flatMap(\.entries).filter { $0.status != .comingSoon }.map(\.id)
            .filter { selection.contains($0) && !added.contains($0) }
    }

    private var shownGroups: [Group] { Self.shown(groups, experimental: showsExperimental) }
    private var picked: [String] { Self.picked(shownGroups, selection: selection, added: added) }
    /// The device on the right: the chosen one while it's shown, else the first.
    private var shownGroup: Group? { shownGroups.first { $0.id == device } ?? shownGroups.first }

    var body: some View {
        VStack(spacing: 0) {
            // A fixed sidebar, as System Settings has: its names fit, and unlike NavigationSplitView's it can't be
            // collapsed in a sheet that has no toolbar to bring it back.
            HStack(spacing: 0) {
                List(selection: Binding(get: { shownGroup?.id }, set: { id in id.map { device = $0 } })) {
                    ForEach(shownGroups) { group in
                        Label {
                            Text(group.name)
                        } icon: {
                            Image(nsImage: group.icon).resizable().scaledToFit()
                        }
                        .badge(group.entries.count { picked.contains($0.id) })
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 270)
                Divider()
                if let group = shownGroup { versions(group) } else { Spacer() }
            }
            Divider()
            HStack {
                Toggle("Show experimental", isOn: $showsExperimental)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add") { onAdd(picked) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 700, idealWidth: 800, minHeight: 500, idealHeight: 620)
    }

    /// The sheet's window: resizable down to the view's minimum, at its last size (autosaved), else the ideal one.
    /// It opens with the versions list focused; left to itself AppKit would focus its first key view, the devices.
    func makeSheet() -> NSWindow {
        let hosting = NSHostingController(rootView: self)
        hosting.sizingOptions = [.minSize]
        let sheet = NSWindow(contentViewController: hosting)
        sheet.styleMask = [.titled, .resizable]
        sheet.setContentSize(NSSize(width: 800, height: 620))
        sheet.setFrameAutosaveName("AddDeviceSheet")
        hosting.view.layoutSubtreeIfNeeded()
        func lists(_ view: NSView) -> [NSTableView] {
            view.subviews.flatMap { ($0 as? NSTableView).map { [$0] } ?? lists($0) }
        }
        sheet.initialFirstResponder = lists(hosting.view).max {
            $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
        }
        return sheet
    }

    private func versions(_ group: Group) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { list in
                List(group.entries, selection: $selection) { entry in
                    AddDeviceRow(
                        entry: entry,
                        added: added.contains(entry.id),
                        downloaded: downloaded.contains(entry.id)
                    )
                    .selectionDisabled(added.contains(entry.id) || entry.status == .comingSoon)
                }
                .contextMenu(
                    forSelectionType: String.self,
                    menu: { _ in },
                    // Double-click or Return in the list adds what's picked, as Add does.
                    primaryAction: { _ in
                        if !picked.isEmpty { onAdd(picked) }
                    }
                )
                // A device opened on a pick shows it.
                .task(id: group.id) {
                    if let pick = group.entries.first(where: { selection.contains($0.id) }) {
                        list.scrollTo(pick.id, anchor: .center)
                    }
                }
            }
            Divider()
            AddDeviceSummary(
                entries: shownGroups.flatMap(\.entries).filter { picked.contains($0.id) },
                downloaded: downloaded,
                guestPackaged: guestPackaged
            )
        }
    }
}

/// One version: checked when already added, its badge, build and status, and its IPSW (here, shipped, or its size).
struct AddDeviceRow: View {
    let entry: FirmwareCatalog.Entry
    let added: Bool
    let downloaded: Bool

    private var status: String? { Self.statusText(entry.status) }

    /// Nothing for a supported build; only what sets a build apart.
    static func statusText(_ status: FirmwareCatalog.Entry.Status) -> String? {
        switch status {
        case .available: nil
        case .experimental: "Experimental"
        case .untested: "Untested"
        case .comingSoon: "Coming Soon"
        case .userIPSW: "Requires an IPSW"
        }
    }

    /// The bytes a download fetches: a developer beta's RAR archive, else the IPSW.
    static func downloadBytes(_ entry: FirmwareCatalog.Entry) -> Int64 {
        entry.source.archiveBytes ?? entry.source.bytes ?? 0
    }

    /// Where the IPSW stands: shipped prepared with the app, here, or what it takes to download.
    static func ipsw(_ entry: FirmwareCatalog.Entry, downloaded: Bool) -> String {
        if entry.bundled != nil { return "Included" }
        if downloaded { return "Downloaded" }
        return downloadBytes(entry).formatted(.byteCount(style: .file))
    }

    var body: some View {
        HStack(spacing: 6) {
            // Already in the sidebar: checked, as in a menu, and dimmed.
            Image(systemName: "checkmark")
                .foregroundStyle(.tint)
                .opacity(added ? 1 : 0)
                .frame(width: 14)
            Text("iOS \(entry.version)")
                .foregroundStyle(added || entry.status == .comingSoon ? .secondary : .primary)
            if let badge = entry.prereleaseBadge {
                Text(badge)
                    .font(.caption)
                    .padding(.horizontal, 5)
                    .background(.quaternary, in: Capsule())
            }
            Text(entry.build)
                .foregroundStyle(.secondary)
            Spacer()
            if let status {
                Text(status)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            Text(Self.ipsw(entry, downloaded: downloaded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 76, alignment: .trailing)
            // The sidebar's convention: a build that isn't here yet shows the download glyph.
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.tertiary)
                .opacity(downloaded || entry.bundled != nil || entry.status == .comingSoon ? 0 : 1)
                .frame(width: 16)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "iOS \(entry.version)\(entry.prereleaseBadge.map { " \($0)" } ?? ""), build \(entry.build)"
        )
        .accessibilityValue(
            [status, Self.ipsw(entry, downloaded: downloaded), added ? "In the sidebar" : nil]
                .compactMap { $0 }.joined(separator: ", ")
        )
    }
}
