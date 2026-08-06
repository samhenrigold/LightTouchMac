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
        Task { await abandonedWorkSelfCheck() }
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

    /// On quit: guard an in-flight install, then make the guest's filesystem as
    /// safe as it can be made. Note "as it can be" — 3.1.3 still has no working
    /// shutdown here; see EmulatorController.beginCleanShutdown, which now says
    /// what actually happens rather than what we wished did.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let emulator else { return .terminateNow }

        // Queued installs count too. isInstalling is set only around the install
        // that is executing; jobs waiting their turn are parked on the previous
        // job's task, so quitting with three .ipas queued used to take no notice
        // and drop them without a word.
        if emulator.isInstalling || AppInstaller.hasPendingWork {
            let alert = NSAlert()
            alert.messageText = "An app install is in progress"
            alert.informativeText = "Quitting now will leave an app half-installed on the device, "
                + "and cancel any others still queued. Quit anyway?"
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            // Mid-install is not a clean state to snapshot; quit straight out.
            guard alert.runModal() == .alertFirstButtonReturn else {
                emulator.cancelFactoryReset()   // this quit was the erase; call it off
                return .terminateCancel
            }
            return .terminateNow
        }

        guard !emulator.isDead else { return .terminateNow }

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
        // Past the worst case of whichever path runs below, and no further: a
        // quit the user cannot predict the end of is a quit that feels broken.
        // With resume on, a failed save falls through to the flush, so the
        // budget is both (20s + 20s); otherwise it is the flush's 20s alone.
        let backstop: TimeInterval = EmulatorController.resumeOnLaunch ? 45 : 25
        DispatchQueue.main.asyncAfter(deadline: .now() + backstop) {
            if !replied { NSLog("quit: shutdown did not finish in time — quitting anyway") }
            reply()
        }

        // Exactly ONE of these two runs, and that is the whole point.
        //
        // Both make the session durable, by opposite means. The snapshot freezes
        // RAM while flash stays where it is; the powerdown makes the guest
        // unmount, which pushes RAM's HFS+ catalog INTO flash. Doing the save
        // and then the powerdown — which is what this used to ask for — leaves
        // the snapshot describing a filesystem that has since moved on, i.e.
        // exactly the stale-RAM-over-newer-flash corruption the snapshot code
        // spends its comments warning about. So: save if resume is on, and fall
        // back to unmounting only if the save did not happen.
        if EmulatorController.resumeOnLaunch {
            emulator.beginQuitSnapshot { saved in
                if saved { reply() } else { emulator.beginCleanShutdown { _ in reply() } }
            }
        } else {
            emulator.beginCleanShutdown { _ in reply() }
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Bring the device window back on a Dock click.
    ///
    /// Closing it is normally the same as quitting — but not while Settings is
    /// open, because then it isn't the last window and the app stays alive with
    /// the emulator running and nothing on screen. There is no menu item that
    /// recreates it and the Window menu only lists windows that exist, so the
    /// app was unrecoverable short of ⌘Q. Checked on the window rather than
    /// AppKit's hasVisibleWindows, which counts Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if windowController?.window?.isVisible != true { windowController?.showWindow(nil) }
        return true
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
