// Which catalog entries the sidebar shows, and the names the user gave them. Persisted in user defaults;
// pure Foundation, so tests/offline/check-sidebar-list.py compiles it whole.

import Foundation

nonisolated struct SidebarList: Equatable {
    static let entriesKey = "sidebarEntries"
    static let namesKey = "sidebarNames"

    /// Entry ids, in the order they were added; `entries(in:)` lists them in catalog order.
    private(set) var ids: [String]
    /// Custom names by entry id.
    private(set) var names: [String: String]

    init(ids: [String] = [], names: [String: String] = [:]) { self.ids = ids; self.names = names }

    /// The saved list; the first launch after updating saves one from what the user already has (`owned`:
    /// a prepared device, a downloaded IPSW or a job in flight), and a fresh install starts with `first_run`.
    static func load(_ defaults: UserDefaults, catalog: FirmwareCatalog, owned: (FirmwareCatalog.Entry) -> Bool) -> SidebarList {
        let known = Set(catalog.entries.map(\.id))
        if let saved = defaults.stringArray(forKey: entriesKey) {
            let names = defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:]
            return SidebarList(ids: saved.filter(known.contains), names: names.filter { known.contains($0.key) })
        }
        var ids = catalog.entries.filter(owned).map(\.id)
        if ids.isEmpty, let first = catalog.firstRunEntry { ids = [first.id] }
        let list = SidebarList(ids: ids)
        list.save(defaults)
        return list
    }

    func save(_ defaults: UserDefaults) {
        defaults.set(ids, forKey: Self.entriesKey)
        defaults.set(names, forKey: Self.namesKey)
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// The sidebar's rows: in catalog order (per board, version order, prereleases before their release).
    func entries(in catalog: FirmwareCatalog) -> [FirmwareCatalog.Entry] { catalog.entries.filter { ids.contains($0.id) } }

    /// Returns whether anything was added.
    @discardableResult mutating func add(_ newIDs: some Sequence<String>) -> Bool {
        let before = ids.count
        for id in newIDs where !ids.contains(id) { ids.append(id) }
        return ids.count != before
    }

    mutating func remove(_ id: String) {
        ids.removeAll { $0 == id }
        names[id] = nil
    }

    /// An empty name, or the row's default title, clears the custom name.
    mutating func rename(_ id: String, to text: String, defaultTitle: String) {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        names[id] = name.isEmpty || name == defaultTitle ? nil : name
    }

    /// What one row says. With a custom name, the name over "iPod touch 2G, iOS 4.1"; among one kind of device, the version
    /// ("iOS 4.2.1", with its Beta/GM badge beside it); among several, the device over its version.
    struct Label: Equatable {
        var title: String
        var badge: String?
        var subtitle: String?
    }

    func label(for entry: FirmwareCatalog.Entry, in catalog: FirmwareCatalog) -> Label {
        Self.label(for: entry, name: names[entry.id], mixed: Set(entries(in: catalog).map(\.board)).count > 1)
    }

    static func label(for entry: FirmwareCatalog.Entry, name: String?, mixed: Bool) -> Label {
        let version = "iOS \(entry.version)"
        let tagged = ([version] + [entry.prereleaseBadge].compactMap { $0 }).joined(separator: " ")
        let device = entry.profile?.sidebarName ?? entry.productType
        if let name { return Label(title: name, subtitle: "\(device), \(tagged)") }
        if mixed { return Label(title: device, subtitle: tagged) }
        return Label(title: version, badge: entry.prereleaseBadge)
    }
}
