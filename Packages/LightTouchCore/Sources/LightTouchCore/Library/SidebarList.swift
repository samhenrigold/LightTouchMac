// Which catalog entries the sidebar shows, and the names the user gave them. Persisted in user defaults;
// pure Foundation; SidebarListTests covers it.

import Foundation

public nonisolated struct SidebarList: Equatable {
    public static let entriesKey = "sidebarEntries"
    public static let namesKey = "sidebarNames"
    /// Posted when the sidebar's list or a name changes (a rename, Device Name Style): names shown elsewhere follow.
    public static let didChangeNotification = Notification.Name("SidebarListDidChange")

    /// The saved custom name for an entry, for names shown outside the sidebar.
    public static func savedName(_ id: String, in defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: namesKey) as? [String: String])?[id]
    }

    /// A device in an alert, a panel or a menu: “Lab iPad”, else iPad iOS 3.2.2.
    public static func reference(for entry: FirmwareCatalog.Entry, name: String?) -> String {
        name.map { name in
            "“\(name)”"
        } ?? "\(entry.preferredName) iOS \(entry.version)"
    }

    /// Entry ids, in the order they were added; `entries(in:)` lists them in catalog order.
    public private(set) var ids: [String]
    /// Custom names by entry id.
    public private(set) var names: [String: String]

    public init(ids: [String] = [], names: [String: String] = [:]) {
        self.ids = ids
        self.names = names
    }

    /// The saved list; the first launch after updating saves one from what the user already has (`owned`:
    /// a prepared device or a job in flight), and a fresh install starts with `first_run`. A coming_soon entry,
    /// which can't be added, leaves a list saved before it couldn't.
    public static func load(_ defaults: UserDefaults, catalog: FirmwareCatalog, owned: (FirmwareCatalog.Entry) -> Bool)
        -> SidebarList
    {
        let known = Set(catalog.entries.filter { $0.status != .comingSoon }.map(\.id))
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

    public func save(_ defaults: UserDefaults) {
        defaults.set(ids, forKey: Self.entriesKey)
        defaults.set(names, forKey: Self.namesKey)
    }

    public func contains(_ id: String) -> Bool { ids.contains(id) }

    /// The sidebar's rows: in catalog order (per board, version order, prereleases before their release).
    public func entries(in catalog: FirmwareCatalog) -> [FirmwareCatalog.Entry] {
        catalog.entries.filter { ids.contains($0.id) }
    }

    /// Returns whether anything was added.
    @discardableResult public mutating func add(_ newIDs: some Sequence<String>) -> Bool {
        let before = ids.count
        for id in newIDs where !ids.contains(id) { ids.append(id) }
        return ids.count != before
    }

    public mutating func remove(_ id: String) {
        ids.removeAll { $0 == id }
        names[id] = nil
    }

    /// An empty name, or the row's default title, clears the custom name.
    public mutating func rename(_ id: String, to text: String, defaultTitle: String) {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        names[id] = name.isEmpty || name == defaultTitle ? nil : name
    }

    /// What one row says, and the window's title and subtitle for it: the marketing name ("iPod touch (2nd generation)") over the
    /// version with its beta/GM badge ("iOS 4.1 beta 1"); a custom name over "iPod touch (2nd generation), iOS 4.1".
    public struct Label: Equatable {
        public var title: String
        public var subtitle: String
    }

    public func label(for entry: FirmwareCatalog.Entry) -> Label { Self.label(for: entry, name: names[entry.id]) }

    public static func label(for entry: FirmwareCatalog.Entry, name: String?) -> Label {
        let version = (["iOS \(entry.version)"] + [entry.prereleaseBadge].compactMap { $0 }).joined(separator: " ")
        guard let name else { return Label(title: entry.preferredName, subtitle: version) }
        return Label(title: name, subtitle: "\(entry.preferredName), \(version)")
    }
}
