import Cocoa
import DeviceRuntime
import HostRuntime
import HostServiceClient
import HostServiceWire
import LightTouchCore
import UniformTypeIdentifiers

// MARK: - Context menu

extension AppsInspectorViewController: NSMenuDelegate {
    /// The Apps menu and a row's context menu, as LightTouchCore's AppsMenu lays them out.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let isMainMenu = menu !== tableView.menu
        let model = AppsMenu(
            rows: rows,
            isMainMenu: isMainMenu,
            row: isMainMenu ? tableView.selectedRow : tableView.clickedRow,
            selection: tableView.selectedRowIndexes,
            inFrontWindow: view.window === NSApp.mainWindow,
            retainedCopy: { [emulator] in IPALibrary.url(for: $0, device: emulator.instance) },
            targets: (DeviceSessionHost.shared?.sessions ?? []).map { session in
                let entry = FirmwareCatalog.bundled.entry(id: session.instance.firmware)
                return AppsMenuTarget(
                    title: entry.map { entry in
                        SidebarList.reference(for: entry, name: SidebarList.savedName(entry.id))
                    } ?? session.instance.name,
                    canQueueInstall: session.emulator.canQueueInstall,
                    isThisDevice: session.emulator === emulator,
                    device: session.emulator
                )
            }
        )
        for item in model.items { menu.addItem(menuItem(item)) }
    }

    private func menuItem(_ item: AppsMenuItem) -> NSMenuItem {
        if item.isSeparator { return .separator() }
        let (action, object): (Selector?, Any?) =
            switch item.action {
            case .installApp: (#selector(MainWindowController.installApp(_:)), nil)
            case .importMedia: (#selector(MainWindowController.syncMedia(_:)), nil)
            case .resumeTransfers: (#selector(resumeInstallsClicked(_:)), nil)
            case .refresh: (#selector(refreshClicked(_:)), nil)
            case .install(let app): (#selector(installCatalogClicked(_:)), app)
            case .installBatch(let apps): (#selector(installSelectedCatalogClicked(_:)), apps)
            case .chooseVersion(let app): (#selector(catalogDetailsClicked(_:)), app)
            case .viewOnLegacyStore(let app): (#selector(viewOnLegacyStoreClicked(_:)), app)
            case .cancelInstall(let job): (#selector(cancelInstallClicked(_:)), job)
            case .dismissInstall(let job): (#selector(dismissInstallClicked(_:)), job)
            case .open(let app): (#selector(openClicked(_:)), app)
            case .uninstall(let apps): (#selector(uninstallClicked(_:)), apps.count == 1 ? apps[0] : apps)
            case .showInLegacyStore(let app): (#selector(showInLegacyStoreClicked(_:)), app)
            case .installOn(let file, let device):
                (#selector(installOnClicked(_:)), (file: file, device: device))
            case .none, .separator: (nil, nil)
            }
        let result = NSMenuItem(title: item.title, action: action, keyEquivalent: item.keyEquivalent)
        if item.shift { result.keyEquivalentModifierMask = [.shift, .command] }
        // The responder chain finds the window controller's own actions; the rest are this inspector's.
        switch item.action {
        case .installApp, .importMedia, .none: break
        default: result.target = self
        }
        result.representedObject = object
        result.isEnabled = item.isEnabled
        if let submenu = item.submenu {
            let menu = NSMenu()
            for entry in submenu { menu.addItem(menuItem(entry)) }
            result.submenu = menu
        }
        return result
    }
}
