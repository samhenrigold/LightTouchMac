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

    /// On quit: guard an in-flight install, then snapshot the running guest so
    /// the next launch resumes instantly instead of cold-booting (and doesn't
    /// lose guest-filesystem writes to a torn overlay — 3.1.3 has no clean
    /// shutdown). The snapshot is health-gated in EmulatorController: a wedged
    /// guest is never saved.
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
        // do nothing and the only way out is force-quit. The snapshot is a
        // convenience; never let it hold the app hostage. Whichever of the two
        // fires first wins, and replying twice is not allowed, hence the latch.
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            if !replied { NSLog("quit: snapshot did not finish in time — quitting anyway") }
            reply()
        }
        emulator.beginQuitSnapshot { _ in reply() }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
