// Created by Sam on 2026-08-05.

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    
    private var windowController: MainWindowController?
    private var emulator: EmulatorController?
    private var settingsController: SettingsWindowController?

    /// Standard Settings/Preferences window (⌘,). Routed here via the responder
    /// chain (nil-targeted menu item → app → delegate).
    @objc func showSettings(_ sender: Any?) {
        if settingsController == nil { settingsController = SettingsWindowController() }
        settingsController?.show()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // AppKit injects AutoFill, Start Dictation and Emoji & Symbols into the
        // Edit menu, and a Tab Bar section into View. All of them are dead here:
        // there is no editable text and the app is single-window. These defaults
        // are the only supported way to decline them, and must be set before the
        // menu is built.
        UserDefaults.standard.register(defaults: [
            "NSDisabledDictationMenuItem": true,
            "NSDisabledCharacterPaletteMenuItem": true,
        ])
        NSWindow.allowsAutomaticWindowTabbing = false

        MainMenuBuilder.install()
        #if DEBUG
        SpringBoardIcons.selfCheck()
        #endif
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = LaunchOptions.resolved()

        // Report missing device files up front. Booting without them dies deep
        // inside the dylib on the QEMU thread with no error the app can show.
        let missing = options.missingAssets()
        if !missing.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Missing device files"
            alert.informativeText = """
            LightTouchMac could not find these required files:

            \(missing.joined(separator: "\n"))

            Point --files-root or the LTM_FILES environment variable at a valid \
            qemu-ios-files directory.
            """
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let emulator = EmulatorController(options: options)
        // Start before showing the window: the inspector checks the usbmux
        // session in its viewDidLoad, which runs during showWindow.
        emulator.start()

        let controller = MainWindowController(emulator: emulator)
        controller.showWindow(nil)

        self.emulator = emulator
        self.windowController = controller
    }

    func applicationWillTerminate(_ notification: Notification) {
        emulator?.stop()
    }

    /// On quit: guard an in-flight install, then power the guest down so its
    /// filesystem is intact next launch. (The comment here used to say 3.1.3
    /// has no clean shutdown — that stopped being true once the PMU power latch
    /// was modelled; see EmulatorController.beginCleanShutdown.)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let emulator else { return .terminateNow }

        if emulator.isInstalling {
            let alert = NSAlert()
            alert.messageText = "An app install is in progress"
            alert.informativeText = "Quitting now will leave the app half-installed on the device. Quit anyway?"
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            // Mid-install is not a clean state to snapshot; quit straight out.
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }

        guard emulator.isRunning else { return .terminateNow }

        // Quit must ALWAYS complete. .terminateLater hands AppKit an IOU, and
        // if the completion never runs the app just sits there — ⌘Q appears to
        // do nothing and the only way out is force-quit. Nothing below may hold
        // the app hostage. Whichever finishes first wins, and replying twice is
        // not allowed, hence the latch.
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        // Comfortably past beginCleanShutdown's own 25s cap, and no further: a
        // quit the user cannot predict the end of is a quit that feels broken.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if !replied { NSLog("quit: shutdown did not finish in time — quitting anyway") }
            reply()
        }

        // Power the guest down first. HFS+ holds catalog updates in memory and
        // only an unmount flushes them, so quitting without this loses the
        // directory entries for anything installed this session even though
        // every data block already reached the overlay. If resume is on, the
        // snapshot is taken first — it captures RAM, which the powerdown then
        // discards by design.
        if EmulatorController.resumeOnLaunch {
            emulator.beginQuitSnapshot { _ in
                emulator.beginCleanShutdown { _ in reply() }
            }
        } else {
            emulator.beginCleanShutdown { _ in reply() }
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
