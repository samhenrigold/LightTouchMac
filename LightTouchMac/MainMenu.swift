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
    func pasteAsPlainText(_ sender: Any?)
    func runPageLayout(_ sender: Any?)
    @objc(print:) func printDocument(_ sender: Any?)
}

@MainActor
enum MainMenuBuilder {

    static func install() {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Light Touch"
        let main = NSMenu(title: "Main Menu")
        
        main.addItem(submenu(appMenu(appName), title: appName))
        main.addItem(submenu(fileMenu(), title: "File"))
        main.addItem(submenu(editMenu(), title: "Edit"))
        main.addItem(submenu(viewMenu(), title: "View"))
        main.addItem(submenu(deviceMenu(), title: "Device"))
        main.addItem(submenu(captureMenu(), title: "Capture"))
        main.addItem(submenu(windowMenu(), title: "Window"))
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
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        menu.addItem(submenu(services, title: "Services"))
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.option, .command]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }
    
    private static func captureMenu() -> NSMenu {
        let menu = NSMenu(title: "Capture")
        menu.addItem(item("Save Screenshot…", #selector(MainWindowController.saveScreenshot(_:)), "s", [.shift, .command]))
        menu.addItem(item("Copy Screen", #selector(MainWindowController.copyScreen(_:))))
        menu.addItem(item("Live Text", #selector(MainWindowController.showLiveText(_:)), "l", [.shift, .command]))
        menu.addItem(.separator())
        menu.addItem(item("Start Recording", #selector(MainWindowController.toggleRecording(_:)), "r", [.shift, .command]))
        menu.addItem(.separator())
        menu.addItem(item("Show Finger Dots", #selector(MainWindowController.toggleTouchOverlay(_:))))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        // Not a document app — the New/Open/Save/Print boilerplate was all dead
        // (permanently disabled, targeting NSDocument/NSDocumentController that
        // don't exist here). File carries the app-level actions that fit it:
        // install, and the diagnostics export, plus Close.
        let menu = NSMenu(title: "File")
        menu.addItem(item("Install App…", #selector(MainWindowController.installApp(_:)), "i", [.shift, .command]))
        menu.addItem(item("Sync Media…", #selector(MainWindowController.syncMedia(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("Export Diagnostics…", #selector(MainWindowController.exportDiagnostics(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }
    
    private static func editMenu() -> NSMenu {
        // The standard text-editing block is REQUIRED now that the toolbar has
        // a search field: menu key equivalents are the only thing that
        // delivers ⌘A/⌘C/⌘V/⌘Z to a field editor, so removing them (this menu
        // once held only the two guest items, on the "not a text app" theory)
        // silently disabled selection and editing in the field. The items
        // target the first responder and validate to disabled when no text is
        // focused. The Find/Spelling/Substitutions tree stays out — still no
        // text VIEW anywhere — and AutoFill, Start Dictation and Emoji &
        // Symbols are suppressed in AppDelegate via NSDisabled*MenuItem.
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", #selector(FirstResponderActions.undo(_:)), "z"))
        menu.addItem(item("Redo", #selector(FirstResponderActions.redo(_:)), "Z"))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", #selector(NSResponder.selectAll(_:)), "a"))
        menu.addItem(.separator())
        // One Find item, not the standard submenu: the only searchable thing
        // is the Legacy Store field, and ⌘F should simply put the caret there.
        menu.addItem(item("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f", tag: NSTextFinder.Action.showFindInterface.rawValue))
        menu.addItem(item("Search Store", #selector(MainWindowController.findCatalog(_:)), "f", [.option, .command]))
        menu.addItem(.separator())
        menu.addItem(item("Copy Screen", #selector(MainWindowController.copyScreen(_:)), "c", [.shift, .command]))
        menu.addItem(item("Paste Text to Guest", #selector(MainWindowController.pasteToGuest(_:)), "v", [.control, .command]))
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
        menu.addItem(item("Actual Size", #selector(MainWindowController.zoomActualSize(_:)), "0"))
        menu.addItem(item("Zoom to Fit", #selector(MainWindowController.zoomToFit(_:)), "9"))
        menu.addItem(item("Zoom In", #selector(MainWindowController.zoomIn(_:)), "+"))
        let unshiftedZoomIn = item("Zoom In", #selector(MainWindowController.zoomIn(_:)), "=")
        unshiftedZoomIn.isHidden = true
        unshiftedZoomIn.allowsKeyEquivalentWhenHidden = true
        menu.addItem(unshiftedZoomIn)
        menu.addItem(item("Zoom Out", #selector(MainWindowController.zoomOut(_:)), "-"))
        menu.addItem(.separator())
        menu.addItem(item("Show Inspector", #selector(MainWindowController.toggleAppInspector(_:)), "i", [.option, .command]))
        menu.addItem(.separator())
        menu.addItem(item("Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.option, .command]))
        menu.addItem(item("Customize Toolbar…", #selector(NSWindow.runToolbarCustomizationPalette(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.control, .command]))
        return menu
    }
    
    private static func deviceMenu() -> NSMenu {
        // Home, Lock and rotation retain Simulator shortcuts for this audience.
        // Rotation yields to text editors; volume uses separate chords from zoom.
        // Nil targets route through the window's responder chain.
        let menu = NSMenu(title: "Device")
        menu.addItem(item("Home", #selector(MainWindowController.deviceHome(_:)), "H", [.shift, .command]))
        menu.addItem(item("Lock", #selector(MainWindowController.deviceLock(_:)), "l"))
        menu.addItem(.separator())
        // The arrows are the shortcut anyone reaches for, and they read the way
        // the device turns. No plain "Rotate" item — left and right cover it,
        // and the toolbar keeps the one-button portrait/landscape toggle.
        menu.addItem(item("Rotate Left", #selector(MainWindowController.deviceRotateLeft(_:)),
                          String(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        menu.addItem(item("Rotate Right", #selector(MainWindowController.deviceRotateRight(_:)),
                          String(UnicodeScalar(NSRightArrowFunctionKey)!)))
        menu.addItem(item("Shake", #selector(MainWindowController.deviceShake(_:)), "z", [.option, .command]))
        menu.addItem(item("Volume Up", #selector(MainWindowController.deviceVolumeUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.option, .command]))
        menu.addItem(item("Volume Down", #selector(MainWindowController.deviceVolumeDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.option, .command]))
        menu.addItem(.separator())
        menu.addItem(item("Pause", #selector(MainWindowController.toggleDevicePause(_:)), "p", [.option, .command]))
        menu.addItem(item("Save State Now", #selector(MainWindowController.saveStateNow(_:)), "s", [.option, .command]))
        menu.addItem(item("Discard Saved State…", #selector(MainWindowController.discardSavedState(_:))))
        menu.addItem(.separator())

        menu.addItem(item("Battery…", #selector(MainWindowController.configureBattery(_:))))
        menu.addItem(item("Proxy…", #selector(MainWindowController.configureWebProxy(_:))))
        let advanced = NSMenu(title: "Advanced")
        advanced.addItem(item("Open SSH", #selector(MainWindowController.openDeviceTerminal(_:)), "t", [.shift, .command]))
        advanced.addItem(item("Restart SpringBoard", #selector(MainWindowController.restartSpringBoard(_:))))
        // Applies at the next boot.
        advanced.addItem(item("Verbose Boot", #selector(MainWindowController.toggleVerboseBoot(_:))))
        advanced.addItem(item("Kernel Console", #selector(MainWindowController.toggleKernelConsole(_:))))
        menu.addItem(submenu(advanced, title: "Advanced"))
        menu.addItem(.separator())

        // Keep restart and erase together at the bottom, away from routine input.
        menu.addItem(item("Restart…", #selector(MainWindowController.deviceReset(_:))))
        menu.addItem(item("Power Off", #selector(MainWindowController.devicePowerOff(_:))))
        menu.addItem(item("Erase All Content and Settings…", #selector(MainWindowController.eraseDevice(_:))))
        return menu
    }
    
    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
    
    private static func helpMenu(_ appName: String) -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("\(appName) Help", #selector(AppDelegate.showHelp(_:)), "?"))
        return menu
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
