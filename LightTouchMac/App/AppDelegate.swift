// Created by Sam on 2026-08-05.

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    
    private var windowController: MainWindowController?
    private var host: DeviceSessionHost?
    /// Every device this launch started; quitting shuts each one down.
    private var emulators: [EmulatorController] { host?.sessions.map(\.emulator) ?? [] }
    /// The running device, for settings that apply to it on its next boot.
    private var emulator: EmulatorController? { windowController?.session?.emulator ?? emulators.first }
    private var helpController: NSWindowController?
    private var awaitingTermination = false
    private var terminationBackstop: Task<Void, Never>?

    /// NSApplication's deferred quit runs a nested modal loop. Invoking it
    /// inside a main-queue callback occupies that serial queue until quit
    /// finishes, starving the Swift main-actor tasks needed to finish it.
    /// A run-loop timer invokes AppKit without holding the dispatch queue.
    /// System logout still uses applicationShouldTerminate's native reply.
    static func requestTermination() {
        guard (NSApp.delegate as? AppDelegate)?.awaitingTermination != true else { return }
        let timer = Timer(timeInterval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard (NSApp.delegate as? AppDelegate)?.awaitingTermination != true else { return }
                NSApp.terminate(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc func quit(_ sender: Any?) { Self.requestTermination() }

    @objc func showDeviceWindow(_ sender: Any?) { windowController?.focusDeviceScreen(sender) }
    @objc func showFilesWindow(_ sender: Any?) { windowController?.toggleFiles(sender) }

    @objc func toggleAutomaticRotation(_ sender: Any?) { emulator?.toggleAutoRotate() }
    @objc func toggleInternetAccess(_ sender: Any?) {
        let current = UserDefaults.standard.object(forKey: NetworkAccessPreference.key) as? Bool ?? emulator?.network ?? true
        UserDefaults.standard.set(!current, forKey: NetworkAccessPreference.key)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleAutomaticRotation(_:)) {
            item.state = emulator?.autoRotateEnabled ?? true ? .on : .off
            return emulator != nil
        } else if item.action == #selector(toggleInternetAccess(_:)) {
            let desired = UserDefaults.standard.object(forKey: NetworkAccessPreference.key) as? Bool ?? emulator?.network ?? true
            item.state = desired ? .on : .off
            item.title = "Connect to the Internet" + (desired != emulator?.network ? " (After Reopening)" : "")
        }
        return true
    }

    @objc func showHelp(_ sender: Any?) {
        if helpController == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Light Touch Help"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 360, height: 300)
            WindowRestorationPolicy.configure(window)
            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.hasVerticalScroller = true
            scroll.autoresizingMask = [.width, .height]
            let text = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
            text.isEditable = false
            text.isSelectable = true
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.usesFindBar = true
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.textContainer?.heightTracksTextView = false
            text.textContainerInset = NSSize(width: 24, height: 20)
            text.font = .systemFont(ofSize: 14)
            text.string = Bundle.main.url(forResource: "Help", withExtension: "txt")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Help is missing from this copy of Light Touch."
            text.setAccessibilityLabel("Light Touch Help")
            scroll.documentView = text
            text.sizeToFit()
            window.contentView!.addSubview(scroll)
            window.center()
            helpController = NSWindowController(window: window)
        }
        helpController?.showWindow(sender)
        helpController?.window?.makeKeyAndOrderFront(sender)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let windowController else { return nil }
        let menu = NSMenu()
        for (title, action) in [("Home Screen", #selector(MainWindowController.deviceHome(_:))),
                                ("Lock", #selector(MainWindowController.deviceLock(_:))),
                                ("Restart…", #selector(MainWindowController.deviceReset(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = windowController
            menu.addItem(item)
        }
        return menu
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Keep AppKit's native editing utilities for search fields and panels.
        // Device, Files, Help, and log windows have distinct jobs, not tabs.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.disableRelaunchOnLogin()

        MainMenuBuilder.install(profile: .iPodTouch2G)
        #if DEBUG
        HomeScreenLayout.selfCheck()
        #endif
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try Bundled.requireStorage() }
        catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            if (error as? CocoaError)?.code == .fileLocking {
                alert.messageText = Bundled.appLockMessage
                alert.informativeText = "Quit the other copy of Light Touch first. This one will quit."
            } else {
                alert.messageText = "Couldn’t open device storage"
                alert.informativeText = error.localizedDescription
            }
            alert.runModal()
            Self.requestTermination()
            return
        }
        do { try NativeLogging.start() }
        catch { logEvent("logging: native output capture unavailable: \(error.localizedDescription)") }
        // State from before the built-in iPod was a prepared device: erased once, or the app quits.
        if let legacy = LegacyState.find(state: Bundled.stateDirectory, applicationSupport: ProcessInfo.processInfo.environment["LTM_STATE_DIR"] == nil
                                            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] : nil) {
            let alert = NSAlert()
            alert.messageText = LegacyState.message
            alert.informativeText = LegacyState.detail
            alert.addButton(withTitle: "Erase & Continue")
            alert.addButton(withTitle: "Quit")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { Self.requestTermination(); return }
            do { try legacy.erase() } catch {
                NSAlert(error: error).runModal()
                Self.requestTermination()
                return
            }
        }
        // The network question belongs to the device being started (DeviceSessionHost.start), not to the app.
        let host = DeviceSessionHost()
        Self.sweepStorage()
        Self.adoptDevelopmentBase(catalog: host.catalog)
        // The built-in device, unpacked on first launch (and again after a Delete, on Prepare).
        if let entry = host.catalog.bundledEntry, FirmwareJobs.bundledBlob(entry) != nil,
           host.library.instances(firmware: entry.id).isEmpty {
            FirmwareJobs.shared.prepareBundled(entry)
        }
        let profile = host.launchSelection?.profile ?? .iPodTouch2G
        MainMenuBuilder.install(profile: profile)
        let controller = MainWindowController(host: host, profile: profile)
        controller.showWindow(nil)
        self.host = host
        self.windowController = controller
        controller.selectLaunchDevice()
    }

    /// Development runs: LTM_DEV_BASE names a `firmwarekit create` output directory to run as a
    /// device; a record naming it (kept in place, never locked) is written once, for the entry its
    /// lock names. The app has no other way to boot anything but a prepared base.
    private static func adoptDevelopmentBase(catalog: FirmwareCatalog) {
        guard let path = ProcessInfo.processInfo.environment["LTM_DEV_BASE"] else { return }
        let base = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let state = Bundled.stateDirectory
        guard !DeviceInstance.all(state: state).contains(where: { DeviceInstance.url($0.base.path, state: state).standardizedFileURL == base }) else { return }
        guard let data = try? Data(contentsOf: base.appendingPathComponent("device.lock.json")),
              let lock = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = (lock["entry"] as? [String: Any])?["id"] as? String, let entry = catalog.entry(id: id) else {
            return logEvent("LTM_DEV_BASE: \(path) has no device.lock.json naming a catalog entry")
        }
        do {
            let instance = try PreparationJob.publish(staging: base, entry: entry, id: UUID(), state: state, keep: true)
            DeviceLibrary.shared.reload()
            logEvent("LTM_DEV_BASE: \(path) is device \(instance.id.uuidString) (\(entry.id))")
        } catch { logEvent("LTM_DEV_BASE: \(error.localizedDescription)") }
    }

    /// Launch, with the library's lock held: finish what a crash or an older
    /// build left. FirmwareJobs' own init sweeps Preparing/ and the IPSW stores.
    private static func sweepStorage() {
        let state = Bundled.stateDirectory, logs = Bundled.logsDirectory
        let records = DeviceInstance.all(state: state)
        _ = FirmwareJobs.shared
        DeviceStateStorage.sweepDeleting(state: state)
        IPALibrary.sweep(devices: records)
        for record in records { USBMux.secure(DeviceInstance.url(record.storage.usbmuxConf, state: state)) }
        // Bases published by earlier builds become immutable too (a development base, outside State, is left alone).
        for record in records where !record.base.path.hasPrefix("/") {
            DeviceStateStorage.lockBase(DeviceInstance.url(record.base.path, state: state))
        }
        // Logs of devices that no longer exist, and the single-device logs
        // from before per-device ones (Logs/serial.log*, usbmuxd.log*).
        let fm = FileManager.default
        let deviceLogs = logs.appendingPathComponent("Devices", isDirectory: true)
        let ids = Set(records.map(\.id.uuidString))
        for name in (try? fm.contentsOfDirectory(atPath: deviceLogs.path)) ?? [] where UUID(uuidString: name) != nil && !ids.contains(name) {
            try? DeviceStateStorage.removeTree(deviceLogs.appendingPathComponent(name))
        }
        for name in (try? fm.contentsOfDirectory(atPath: logs.path)) ?? []
        where ["serial.log", "serial.log.1", "usbmuxd.log", "usbmuxd.log.1"].contains(name) {
            try? fm.removeItem(at: logs.appendingPathComponent(name))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminationBackstop?.cancel()
        // A quit (or a crash, through firmwarekit's parent watch) cancels
        // every preparation; the next launch's sweep removes its staging.
        if host != nil { FirmwareJobs.shared.cancelAll() }
        emulators.forEach { $0.stop() }
    }

    /// On quit: guard an in-flight install, then halt each device
    /// (EmulatorController.halt: storage flushed, no guest shutdown).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if emulators.contains(where: \.isErasing) { return .terminateCancel }
        if awaitingTermination { return .terminateLater }
        if windowController?.finishRecordingBeforeQuit() == true { return .terminateCancel }
        guard !emulators.isEmpty else { return .terminateNow }

        // Queued installs count too. isInstalling is set only around the install
        // that is executing; jobs waiting their turn are parked on the previous
        // job's task, so quitting with three .ipas queued used to take no notice
        // and drop them without a word.
        if emulators.contains(where: \.isInstalling) || AppInstaller.hasPendingWork || windowController?.hasFileTransfer == true {
            let alert = NSAlert()
            alert.messageText = "Device changes are in progress"
            alert.informativeText = "Quitting cancels changes that haven’t finished."
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            AppInstaller.cancelPendingWork()
            windowController?.cancelFileTransfer()
            // Falls through to the SAME shutdown as any other quit. It used to
            // return .terminateNow, on the reasoning that a half-finished
            // install is not a clean state to snapshot — true, and irrelevant
            // to the flush. Skipping the flush threw away every app installed
            // earlier in the session as well as the one in flight.
        }

        let running = emulators.filter { !$0.isDead && !$0.isPoweredOff }
        guard !running.isEmpty else { return .terminateNow }

        awaitingTermination = true
        let reply = { [weak self] in
            // A guard can complete synchronously. Reply only after this
            // delegate invocation has returned terminateLater to AppKit.
            DispatchQueue.main.async {
                guard let self, self.awaitingTermination else { return }
                self.awaitingTermination = false
                self.terminationBackstop?.cancel()
                self.terminationBackstop = nil
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        let backstop = EmulatorController.stopBudget
        terminationBackstop = Task {
            do { try await Task.sleep(for: .seconds(backstop)) } catch { return }
            logEvent("quit: shutdown did not finish in time — quitting anyway")
            reply()
        }

        // Every device shuts down at once; quit waits for the last of them.
        var remaining = running.count
        let finished = {
            remaining -= 1
            if remaining == 0 { reply() }
        }
        for emulator in running { emulator.halt { _ in finished() } }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Reopen the retained device window even when Files or Help is still visible.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if windowController?.window?.isVisible != true { windowController?.showWindow(nil) }
        return true
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        // This selects secure coding if AppKit consults the delegate; returning
        // false would select legacy coding, not disable window restoration.
        // LightTouchApplication and each window independently opt out.
        true
    }
}
