// The Add Device sheet: the firmware catalog by device, in version order, each build's support status and
// whether its IPSW is here (no download glyph). Entries already in the sidebar are checked and can't be picked again.
// A sheet, not a window: it belongs to the one main window and is done before the user goes on (HIG, Sheets).

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
    let onAdd: ([String]) -> Void
    let onCancel: () -> Void
    @State private var selection: Set<String>

    init(catalog: FirmwareCatalog, added: Set<String>, downloaded: Set<String>, selection: Set<String> = [],
         onAdd: @escaping ([String]) -> Void, onCancel: @escaping () -> Void) {
        var boards: [String] = []
        for entry in catalog.entries where !boards.contains(entry.board) { boards.append(entry.board) }
        groups = boards.map { board in
            let entries = catalog.entries.filter { $0.board == board }
            let profile = entries[0].profile
            return Group(id: board, name: profile?.marketingName ?? entries[0].productType,
                         icon: profile?.icon ?? DeviceProfile.icon(modelCode: entries[0].productType, fallbackSymbol: "questionmark.square.dashed"),
                         entries: entries)
        }
        self.added = added
        self.downloaded = downloaded
        self.onAdd = onAdd
        self.onCancel = onCancel
        _selection = State(initialValue: selection)
    }

    /// Only what can still be added, in catalog order.
    private var picked: [String] {
        groups.flatMap(\.entries).map(\.id).filter { selection.contains($0) && !added.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            AddDeviceRow(entry: entry, added: added.contains(entry.id), downloaded: downloaded.contains(entry.id))
                                .selectionDisabled(added.contains(entry.id))
                        }
                    } header: {
                        Label {
                            Text(group.name)
                        } icon: {
                            Image(nsImage: group.icon).resizable().scaledToFit().frame(width: 20, height: 20)
                        }
                    }
                }
            }
            .contextMenu(forSelectionType: String.self, menu: { _ in }, primaryAction: { ids in
                let ids = ids.filter { !added.contains($0) }
                if !ids.isEmpty { onAdd(groups.flatMap(\.entries).map(\.id).filter(ids.contains)) }
            })
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add") { onAdd(picked) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 440, height: 480)
    }
}

private struct AddDeviceRow: View {
    let entry: FirmwareCatalog.Entry
    let added: Bool
    let downloaded: Bool

    private var status: String {
        switch entry.status {
        case .available: "Supported"
        case .experimental: "Experimental"
        case .untested: "Untested"
        case .comingSoon: "Coming Soon"
        case .userIPSW: "Requires an IPSW"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            // Already in the sidebar: checked, as in a menu, and dimmed.
            Image(systemName: "checkmark")
                .foregroundStyle(.tint)
                .opacity(added ? 1 : 0)
                .frame(width: 14)
            Text("iOS \(entry.version)")
                .foregroundStyle(added ? .secondary : .primary)
            if let badge = entry.prereleaseBadge {
                Text(badge).foregroundStyle(.secondary)
            }
            Spacer()
            Text(status)
                .foregroundStyle(entry.status == .available ? .secondary : .tertiary)
                .lineLimit(1)
            // The sidebar's convention: a build that isn't here yet shows the download glyph.
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.tertiary)
                .opacity(downloaded ? 0 : 1)
                .frame(width: 16)
        }
        .help("\(entry.productType) · iOS \(entry.version) (\(entry.build))\n" + (downloaded ? "Downloaded" : "Not downloaded"))
        .accessibilityElement(children: .combine)
        .accessibilityValue([status, downloaded ? "Downloaded" : "Not downloaded", added ? "In the sidebar" : nil]
            .compactMap { $0 }.joined(separator: ", "))
    }
}
