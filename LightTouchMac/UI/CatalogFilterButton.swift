import Cocoa

/// The standard filter pull-down beside Installed/Store, over CatalogFilter.
/// The family choice appears only on an iPad; an iPod's menu is just
/// Show Unavailable Apps. Each choice is saved as it's made.
final class CatalogFilterButton: NSPopUpButton {
    private(set) var filter: CatalogFilter
    let isIPad: Bool
    private let defaults: UserDefaults
    var onChange: () -> Void = {}

    init(isIPad: Bool, defaults: UserDefaults = .standard) {
        self.isIPad = isIPad
        self.defaults = defaults
        filter = CatalogFilter.load(defaults)
        super.init(frame: .zero, pullsDown: true)
        isBordered = false
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityLabel("Filter")
        toolTip = "Filter"
        (cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        menu!.addItem(withTitle: "", action: nil, keyEquivalent: "")   // a pull-down's first item is its face
        for (title, tag) in [("iPhone and iPad Apps", 0), ("iPad Apps Only", 1)] {
            menu!.addItem(withTitle: title, action: #selector(familyChosen(_:)), keyEquivalent: "").tag = tag
        }
        menu!.addItem(.separator())
        menu!.addItem(withTitle: "Show Unavailable Apps", action: #selector(unavailableToggled(_:)), keyEquivalent: "")
        for item in menu!.items { item.target = self }
        update()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ apps: [CatalogApp]) -> [CatalogApp] { filter.apply(apps, iPad: isIPad) }

    private func update() {
        let items = menu!.items
        let symbol = filter.isActive(iPad: isIPad) ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
        items[0].image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Filter")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        items[1].state = filter.iPadOnly ? .off : .on
        items[2].state = filter.iPadOnly ? .on : .off
        for item in items[1...3] { item.isHidden = !isIPad }
        items[4].state = filter.showUnavailable ? .on : .off
    }

    @objc private func familyChosen(_ sender: NSMenuItem) {
        filter.iPadOnly = sender.tag == 1
        changed()
    }

    @objc private func unavailableToggled(_ sender: NSMenuItem) {
        filter.showUnavailable.toggle()
        changed()
    }

    private func changed() {
        filter.save(defaults)
        update()
        onChange()
    }
}
