// Created by Sam on 2026-08-05.
//
// Programmatic rebuild of the app-template MainMenu.xib.

import Cocoa

/// First-responder actions AppKit dispatches by selector but exposes no Swift
/// symbol for. Declaring them here lets the menu use `#selector` (verified at
/// compile time) instead of raw selector strings. Nothing implements this — the
/// selectors travel the responder chain to whatever text view is focused.
@objc private protocol FirstResponderActions {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}

@MainActor
enum MainMenuBuilder {

    static func install(profile: DeviceProfile) {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Light Touch"
        let main = NSMenu(title: "Main Menu")
        // Menu titles remain discoverable even when the front window cannot
        // perform any of their commands. Submenus still validate their items.
        main.autoenablesItems = false
        
        main.addItem(submenu(appMenu(appName), title: appName))
        main.addItem(submenu(fileMenu(profile), title: "File"))
        main.addItem(submenu(editMenu(profile), title: "Edit"))
        main.addItem(submenu(viewMenu(), title: "View"))
        main.addItem(submenu(deviceMenu(profile), title: "Device"))
        main.addItem(submenu(NSMenu(title: "Apps"), title: "Apps"))
        main.addItem(submenu(captureMenu(), title: "Capture"))
        main.addItem(submenu(windowMenu(profile), title: "Window"))
        main.addItem(submenu(helpMenu(appName), title: "Help"))
        
        NSApp.mainMenu = main
        NSApp.windowsMenu = main.item(withTitle: "Window")?.submenu
        NSApp.helpMenu = main.item(withTitle: "Help")?.submenu
    }
    
    // MARK: - Menus
    
    private static func appMenu(_ appName: String) -> NSMenu {
        let menu = NSMenu(title: appName)
        menu.addItem(item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        menu.addItem(submenu(services, title: "Services"))
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.option, .command]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(appName)", #selector(AppDelegate.quit(_:)), "q"))
        return menu
    }
    
    private static func captureMenu() -> NSMenu {
        let menu = NSMenu(title: "Capture")
        menu.addItem(item("Save Screenshot", #selector(MainWindowController.saveScreenshot(_:)), "s"))
        menu.addItem(item("Save Screenshot As…", #selector(MainWindowController.saveScreenshotAs(_:)), "s", [.shift, .command]))
        menu.addItem(item("Copy Screenshot", #selector(MainWindowController.copyScreen(_:))))
        menu.addItem(item("Open Screenshot in Preview", #selector(MainWindowController.openScreenshot(_:)), "o"))
        menu.addItem(.separator())
        menu.addItem(item("Start Recording", #selector(MainWindowController.toggleRecording(_:)), "r"))
        menu.addItem(item("Discard Recording…", #selector(MainWindowController.discardRecording(_:)), "."))
        menu.addItem(.separator())
        menu.addItem(item("Capture Screen Only", #selector(MainWindowController.toggleCaptureScreenOnly(_:))))
        menu.addItem(item("Capture Options…", #selector(MainWindowController.showCaptureOptions(_:))))
        return menu
    }

    private static func fileMenu(_ profile: DeviceProfile) -> NSMenu {
        // Transfers belong to the active Files window, through its responder
        // chain. Opening that window belongs to Window; captures to Capture.
        let menu = NSMenu(title: "File")
        menu.addItem(item("Copy to \(profile.shortName)…", #selector(DeviceFilesViewController.importFile)))
        menu.addItem(item("Save to Mac…", #selector(DeviceFilesViewController.exportFile)))
        menu.addItem(item("Cancel Transfer", #selector(DeviceFilesViewController.cancelTransfer)))
        menu.addItem(.separator())
        menu.addItem(item("Refresh Files", #selector(DeviceFilesViewController.refreshFiles(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }
    
    private static func editMenu(_ profile: DeviceProfile) -> NSMenu {
        // Preserve native editing in search, Help, logs, and file panels.
        // Device-specific editing never takes over the standard Copy/Paste keys.
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", #selector(FirstResponderActions.undo(_:)), "z"))
        menu.addItem(item("Redo", #selector(FirstResponderActions.redo(_:)), "z", [.shift, .command]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", #selector(NSResponder.selectAll(_:)), "a"))
        menu.addItem(.separator())
        // Find searches the front window; Search Apps explicitly focuses the
        // device window's search field (HIG's recommended ⌥⌘F).
        menu.addItem(item("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f", tag: NSTextFinder.Action.showFindInterface.rawValue))
        menu.addItem(item("Search Apps", #selector(MainWindowController.findCatalog(_:)), "f", [.option, .command]))
        menu.addItem(.separator())
        menu.addItem(item("Select Text on Screen", #selector(MainWindowController.showLiveText(_:))))
        menu.addItem(item("Paste Text to \(profile.shortName)", #selector(MainWindowController.pasteToGuest(_:)), "v", [.control, .command]))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        // The standard zoom commands, same ones the toolbar buttons drive.
        //
        // Zoom In is listed as ⌘+ because that is what every Mac app shows and
        // what people look for — but + is a shifted key, so an item that really
        // wanted "+" would only fire on ⇧⌘=. The fix is the one Preview uses: a
        // second, hidden item on the unshifted "=" carrying the same action.
        // Hidden items normally give up their key equivalent, hence
        // allowsKeyEquivalentWhenHidden.
        menu.addItem(item("Physical Size", #selector(MainWindowController.zoomPhysicalSize(_:)), "0"))
        menu.addItem(item("Zoom to Fit", #selector(MainWindowController.zoomToFit(_:)), "9"))
        menu.addItem(item("Zoom In", #selector(MainWindowController.zoomIn(_:)), "+"))
        let unshiftedZoomIn = item("Zoom In", #selector(MainWindowController.zoomIn(_:)), "=")
        unshiftedZoomIn.isHidden = true
        unshiftedZoomIn.allowsKeyEquivalentWhenHidden = true
        menu.addItem(unshiftedZoomIn)
        menu.addItem(item("Zoom Out", #selector(MainWindowController.zoomOut(_:)), "-"))
        menu.addItem(.separator())
        menu.addItem(item("Show Inspector", #selector(MainWindowController.toggleAppInspector(_:)), "i", [.option, .command]))
        menu.addItem(item("Show Finger Dots", #selector(MainWindowController.toggleTouchOverlay(_:))))
        menu.addItem(item("Show Hidden Files", #selector(DeviceFilesViewController.toggleHidden(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.option, .command]))
        menu.addItem(item("Customize Toolbar…", #selector(NSWindow.runToolbarCustomizationPalette(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.control, .command]))
        return menu
    }
    
    private static func deviceMenu(_ profile: DeviceProfile) -> NSMenu {
        // Nil targets route through the active window's responder chain.
        // Leave Command-arrow keys to macOS and text navigation.
        let menu = NSMenu(title: "Device")
        menu.addItem(item("Home Screen", #selector(MainWindowController.deviceHome(_:)), "h", [.shift, .command]))
        menu.addItem(item("Lock", #selector(MainWindowController.deviceLock(_:)), "l"))
        menu.addItem(.separator())
        let orientation = NSMenu(title: "Orientation")
        orientation.addItem(item("Rotate Left", #selector(MainWindowController.deviceRotateLeft(_:)),
                                 "["))
        orientation.addItem(item("Rotate Right", #selector(MainWindowController.deviceRotateRight(_:)),
                                 "]"))
        orientation.addItem(.separator())
        orientation.addItem(item("Rotate Automatically", #selector(AppDelegate.toggleAutomaticRotation(_:))))
        orientation.addItem(.separator())
        appendMotionPoseItems(to: orientation)
        if profile.hasCompass {
            orientation.addItem(.separator())
            let compass = NSMenu(title: "Compass Heading")
            for (degrees, title) in [(0, "North"), (90, "East"), (180, "South"), (270, "West")] {
                compass.addItem(item(title, #selector(MainWindowController.setCompassHeading(_:)), tag: degrees))
            }
            orientation.addItem(submenu(compass, title: "Compass Heading"))
        }
        menu.addItem(submenu(orientation, title: "Orientation"))
        let input = NSMenu(title: "Input")
        input.addItem(item("Shake", #selector(MainWindowController.deviceShake(_:))))
        input.addItem(.separator())
        input.addItem(item("Volume Up", #selector(MainWindowController.deviceVolumeUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.option, .command]))
        input.addItem(item("Volume Down", #selector(MainWindowController.deviceVolumeDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.option, .command]))
        input.addItem(.separator())
        input.addItem(item("Send Keyboard Input", #selector(MainWindowController.toggleKeyboardInput(_:))))
        menu.addItem(submenu(input, title: "Input"))
        let network = NSMenu(title: "Network")
        network.addItem(item("Connect to the Internet", #selector(AppDelegate.toggleInternetAccess(_:))))
        network.addItem(.separator())
        network.addItem(item("Proxy…", #selector(MainWindowController.configureWebProxy(_:))))
        menu.addItem(submenu(network, title: "Network"))
        let battery = NSMenu(title: "Battery")
        for level in [100, 80, 50, 20, 5] {
            battery.addItem(item("\(level)%", #selector(MainWindowController.setBatteryLevel(_:)), tag: level))
        }
        battery.addItem(.separator())
        for (mode, title) in ["Charge Automatically", "Charging", "Not Charging"].enumerated() {
            battery.addItem(item(title, #selector(MainWindowController.setBatteryCharging(_:)), tag: mode))
        }
        if profile.canChooseUSBCharger {
            battery.addItem(.separator())
            battery.addItem(item("High-Power USB Port", #selector(MainWindowController.toggleHighPowerUSB(_:))))
        }
        menu.addItem(submenu(battery, title: "Battery"))
        menu.addItem(.separator())
        menu.addItem(item("Pause", #selector(MainWindowController.toggleDevicePause(_:))))
        // Keep restart and erase together at the bottom, away from routine input.
        menu.addItem(item("Restart…", #selector(MainWindowController.deviceReset(_:))))
        // Guest-package recovery (GuestPackage); enabled only when a loader reported.
        menu.addItem(item("Restart with Previous Guest Tools", #selector(MainWindowController.restartWithPreviousGuestTools(_:))))
        menu.addItem(item("Restart with Built-in Guest Tools", #selector(MainWindowController.restartWithBuiltInGuestTools(_:))))
        menu.addItem(item("Restart with Latest Guest Tools", #selector(MainWindowController.restartWithLatestGuestTools(_:))))
        menu.addItem(item("Power Off", #selector(MainWindowController.devicePowerOff(_:))))
        menu.addItem(item("Erase All Content and Settings…", #selector(MainWindowController.eraseDevice(_:))))
        // The sidebar selection's library commands, as in its context menu.
        menu.addItem(.separator())
        menu.addItem(item("Start", #selector(MainWindowController.toggleDeviceRunning(_:))))
        menu.addItem(item("Download & Prepare", #selector(MainWindowController.downloadAndPrepare(_:))))
        menu.addItem(item("Import IPSW…", #selector(MainWindowController.importIPSW(_:))))
        menu.addItem(item("Cancel Download", #selector(MainWindowController.cancelFirmwareJob(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Show in Finder", #selector(MainWindowController.showDeviceInFinder(_:))))
        menu.addItem(item("Delete Device…", #selector(MainWindowController.deleteDevice(_:))))
        return menu
    }
    
    private static func windowMenu(_ profile: DeviceProfile) -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Show Device", #selector(AppDelegate.showDeviceWindow(_:)), "1"))
        menu.addItem(item("Show \(profile.shortName) Files", #selector(AppDelegate.showFilesWindow(_:)), "2"))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
    
    private static func helpMenu(_ appName: String) -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("\(appName) Help", #selector(AppDelegate.showHelp(_:)), "?"))
        menu.addItem(.separator())
        menu.addItem(item("Show Unfinished Recordings", #selector(MainWindowController.showRecordingRecovery(_:))))
        menu.addItem(item("Device Logs", #selector(MainWindowController.showDeviceLogs(_:))))
        menu.addItem(item("Export Diagnostics…", #selector(MainWindowController.exportDiagnostics(_:))))
        return menu
    }

    /// Both the toolbar pop-up and Device menu expose the same motion commands.
    static func motionMenu(target: AnyObject? = nil) -> NSMenu {
        let menu = NSMenu(title: "Motion")
        appendMotionPoseItems(to: menu, target: target)
        menu.addItem(.separator())
        menu.addItem(item("Shake", #selector(MainWindowController.deviceShake(_:)), target: target))
        return menu
    }

    private static func appendMotionPoseItems(to menu: NSMenu, target: AnyObject? = nil) {
        for (tag, title) in ["Upright", "Flat"].enumerated() {
            menu.addItem(item(title, #selector(MainWindowController.selectMotionPose(_:)), tag: tag, target: target))
        }
        menu.addItem(.separator())
        menu.addItem(item("Reset Tilt", #selector(MainWindowController.resetMotion(_:)), target: target))
    }
    
    // MARK: - Helpers
    
    private static func item(_ title: String,
                             _ action: Selector?,
                             _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command,
                             tag: Int = 0,
                             target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        item.target = target
        return item
    }
    
    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
    
}
