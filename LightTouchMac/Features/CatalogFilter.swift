import Foundation

/// The Store list's filter menu, persisted across launches. The family choice
/// only means something on an iPad: an iPod can't run iPad-only apps, so the
/// server already marks them unavailable there (unsupported_device_family).
nonisolated struct CatalogFilter: Equatable {
    var iPadOnly = false
    /// Apps the server judged unable to run here, greyed with the reason.
    var showUnavailable = true

    static func load(_ defaults: UserDefaults = .standard) -> CatalogFilter {
        CatalogFilter(iPadOnly: defaults.bool(forKey: "storeIPadAppsOnly"),
                      showUnavailable: defaults.object(forKey: "storeShowUnavailable") as? Bool ?? true)
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(iPadOnly, forKey: "storeIPadAppsOnly")
        defaults.set(showUnavailable, forKey: "storeShowUnavailable")
    }

    /// Anything narrower than the default list; the menu's icon fills when true.
    func isActive(iPad: Bool) -> Bool { (iPad && iPadOnly) || !showUnavailable }

    func apply(_ apps: [CatalogApp], iPad: Bool) -> [CatalogApp] {
        apps.filter { app in
            if !showUnavailable, app.incompatibility != nil { return false }
            // An app whose family the server didn't report stays: nothing proves it iPhone-only.
            if iPad, iPadOnly, let family = app.compat?.deviceFamily, !family.contains("2") { return false }
            return true
        }
    }
}
