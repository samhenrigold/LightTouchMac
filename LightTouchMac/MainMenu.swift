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
        let appName = ProcessInfo.processInfo.processName
        let main = NSMenu(title: "Main Menu")
        
        main.addItem(submenu(appMenu(appName), title: appName))
        main.addItem(submenu(fileMenu(), title: "File"))
        main.addItem(submenu(editMenu(), title: "Edit"))
        main.addItem(submenu(viewMenu(), title: "View"))
        main.addItem(submenu(deviceMenu(), title: "Device"))
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
        // No "Settings…": there is no preferences window (the app is configured
        // by launch options / env), and a permanently-disabled item bound to
        // ⌘, reads as broken.
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
    
    private static func fileMenu() -> NSMenu {
        // Not a document app — the New/Open/Save/Print boilerplate was all dead
        // (permanently disabled, targeting NSDocument/NSDocumentController that
        // don't exist here). File carries the app-level actions that fit it:
        // install, and the diagnostics export, plus Close.
        let menu = NSMenu(title: "File")
        menu.addItem(item("Install App…", #selector(MainWindowController.installApp(_:)), "i", [.shift, .command]))
        menu.addItem(.separator())
        menu.addItem(item("Export Diagnostics…", #selector(MainWindowController.exportDiagnostics(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }
    
    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", #selector(FirstResponderActions.undo(_:)), "z"))
        menu.addItem(item("Redo", #selector(FirstResponderActions.redo(_:)), "Z"))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Paste and Match Style", #selector(FirstResponderActions.pasteAsPlainText(_:)), "V", [.option, .command]))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item("Copy Screen", #selector(MainWindowController.copyScreen(_:)), "c", [.control, .command]))
        menu.addItem(item("Paste Text to Guest", #selector(MainWindowController.pasteToGuest(_:)), "v", [.control, .command]))
        menu.addItem(.separator())
        
        let find = NSMenu(title: "Find")
        find.addItem(item("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f", tag: NSTextFinder.Action.showFindInterface.rawValue))
        find.addItem(item("Find and Replace…", #selector(NSTextView.performFindPanelAction(_:)), "f", [.option, .command], tag: NSTextFinder.Action.showReplaceInterface.rawValue))
        find.addItem(item("Find Next", #selector(NSTextView.performFindPanelAction(_:)), "g", tag: NSTextFinder.Action.nextMatch.rawValue))
        find.addItem(item("Find Previous", #selector(NSTextView.performFindPanelAction(_:)), "G", tag: NSTextFinder.Action.previousMatch.rawValue))
        find.addItem(item("Use Selection for Find", #selector(NSTextView.performFindPanelAction(_:)), "e", tag: NSTextFinder.Action.setSearchString.rawValue))
        find.addItem(item("Jump to Selection", #selector(NSResponder.centerSelectionInVisibleArea(_:)), "j"))
        menu.addItem(submenu(find, title: "Find"))
        
        let spelling = NSMenu(title: "Spelling")
        spelling.addItem(item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"))
        spelling.addItem(item("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"))
        spelling.addItem(.separator())
        spelling.addItem(item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))))
        spelling.addItem(item("Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:))))
        spelling.addItem(item("Correct Spelling Automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))))
        menu.addItem(submenu(spelling, title: "Spelling and Grammar"))
        
        let subs = NSMenu(title: "Substitutions")
        subs.addItem(item("Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:))))
        subs.addItem(.separator())
        subs.addItem(item("Smart Copy/Paste", #selector(NSTextView.toggleSmartInsertDelete(_:))))
        subs.addItem(item("Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))))
        subs.addItem(item("Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:))))
        subs.addItem(item("Smart Links", #selector(NSTextView.toggleAutomaticLinkDetection(_:))))
        subs.addItem(item("Data Detectors", #selector(NSTextView.toggleAutomaticDataDetection(_:))))
        subs.addItem(item("Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:))))
        menu.addItem(submenu(subs, title: "Substitutions"))
        
        let transforms = NSMenu(title: "Transformations")
        transforms.addItem(item("Make Upper Case", #selector(NSResponder.uppercaseWord(_:))))
        transforms.addItem(item("Make Lower Case", #selector(NSResponder.lowercaseWord(_:))))
        transforms.addItem(item("Capitalize", #selector(NSResponder.capitalizeWord(_:))))
        menu.addItem(submenu(transforms, title: "Transformations"))
        
        let speech = NSMenu(title: "Speech")
        speech.addItem(item("Start Speaking", #selector(NSTextView.startSpeaking(_:))))
        speech.addItem(item("Stop Speaking", #selector(NSTextView.stopSpeaking(_:))))
        menu.addItem(submenu(speech, title: "Speech"))
        
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
        // Targets are nil so these route up the responder chain to the window
        // controller (the window's next responder).
        let menu = NSMenu(title: "Device")
        menu.addItem(item("Home", #selector(MainWindowController.deviceHome(_:)), "H", [.shift, .command]))
        menu.addItem(item("Lock", #selector(MainWindowController.deviceLock(_:)), "l"))
        menu.addItem(.separator())
        // No key equivalents: ⌘=/⌘- collide with View ▸ Zoom In/Out, and since
        // View is installed before Device those always win, leaving these
        // showing shortcuts that never fire. Click-only is honest.
        menu.addItem(item("Volume Up", #selector(MainWindowController.deviceVolumeUp(_:))))
        menu.addItem(item("Volume Down", #selector(MainWindowController.deviceVolumeDown(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Rotate", #selector(MainWindowController.deviceRotate(_:)), "r", [.control, .command]))
        // The arrows are the shortcut anyone reaches for, and they read the way
        // the device turns. The menu titles carry the ⌘←/⌘→ display for free.
        menu.addItem(item("Rotate Left", #selector(MainWindowController.deviceRotateLeft(_:)),
                          String(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        menu.addItem(item("Rotate Right", #selector(MainWindowController.deviceRotateRight(_:)),
                          String(UnicodeScalar(NSRightArrowFunctionKey)!)))
        menu.addItem(item("Shake", #selector(MainWindowController.deviceShake(_:))))
        menu.addItem(.separator())
        // Install App… lives in the File menu (with its ⇧⌘I); Terminal is here.
        menu.addItem(item("Open Terminal", #selector(MainWindowController.openDeviceTerminal(_:)), "t", [.shift, .command]))
        menu.addItem(.separator())
        menu.addItem(item("Pause", #selector(MainWindowController.devicePause(_:))))
        menu.addItem(item("Resume", #selector(MainWindowController.deviceResume(_:))))
        menu.addItem(item("Restart", #selector(MainWindowController.deviceReset(_:))))
        // No "Shut Down": system_powerdown never completes on 3.1.3 (PMU gap),
        // so it would wedge the guest rather than power it off.
        menu.addItem(.separator())
        menu.addItem(item("Save State Now", #selector(MainWindowController.saveStateNow(_:)), "s", [.control, .command]))
        menu.addItem(item("Discard Saved State", #selector(MainWindowController.discardSavedState(_:))))
        menu.addItem(.separator())
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
        menu.addItem(item("\(appName) Help", #selector(NSApplication.showHelp(_:)), "?"))
        menu.addItem(.separator())
        menu.addItem(item("Export Diagnostics…", #selector(MainWindowController.exportDiagnostics(_:))))
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
