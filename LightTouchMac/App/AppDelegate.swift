import Cocoa
import DeviceRuntime
import HostRuntime
import LightTouchCore
import Sparkle
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windowController: MainWindowController?
    private let dockProgress = DockProgress()
    private var host: DeviceSessionHost?
    /// Every device this launch started; quitting shuts each one down.
    private var emulators: [EmulatorController] { host?.sessions.map(\.emulator) ?? [] }
    /// The selected device's session (DeviceSettingsMenu.target): nil when the selection isn't running.
    private var emulator: EmulatorController? {
        DeviceSettingsMenu.target(
            hasWindow: windowController != nil,
            selected: windowController?.session?.emulator,
            running: emulators
        )
    }
    /// The selected device when it isn't running: its settings for its next start.
    private var stoppedSelection: DeviceInstance? { emulator == nil ? windowController?.selectedInstance : nil }
    private var helpController: HelpWindowController?
    /// Light Touch ▸ Check for Updates… and Sparkle's scheduled checks.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: Analytics.updates,
        userDriverDelegate: nil
    )
    private let quitting = QuitCoordinator(budget: EmulatorController.stopBudget, retry: AppDelegate.requestTermination)
    {
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// Quit, from a menu or an alert (QuitRequest): not while one is already waiting on the devices.
    static func requestTermination() {
        QuitRequest.post { (NSApp.delegate as? AppDelegate)?.quitting.awaitingTermination == true }
    }

    @objc func quit(_ sender: Any?) { Self.requestTermination() }

    @objc func showDeviceWindow(_ sender: Any?) { windowController?.focusDeviceScreen(sender) }
    @objc func showFilesWindow(_ sender: Any?) { windowController?.toggleFiles(sender) }

    @objc func toggleAutomaticRotation(_ sender: Any?) { emulator?.toggleAutoRotate() }
    /// Device ▸ Debugging ▸ Debug Port…: a sheet with its switch, where it is, what it is, and how to attach (DebugPortView).
    @objc func showDebugPort(_ sender: Any?) {
        guard let emulator, let window = NSApp.mainWindow, window.attachedSheet == nil else { return }
        var sheet: NSWindow?
        let view = DebugPortView(
            shortName: emulator.profile.shortName,
            socket: emulator.debugSocket,
            lldbWithSymbols: emulator.lldbAttachCommand,
            enabled: emulator.debugPortEnabled,
            onToggle: { [weak emulator] in emulator?.toggleDebugPort() },
            onDone: { sheet.map { window.endSheet($0) } }
        )
        let panel = NSWindow(contentViewController: NSHostingController(rootView: view))
        sheet = panel
        window.beginSheet(panel)
    }
    @objc func copyLLDBCommand(_ sender: Any?) {
        guard let command = emulator?.lldbAttachCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
    @objc func copyBugReportInfo(_ sender: Any?) {
        if let windowController { windowController.copyBugReportInfo() } else { BugReportCopy.copy(devices: []) }
    }
    @objc func toggleInternetAccess(_ sender: Any?) { NetworkAccessPreference.toggle(running: emulator?.network) }
    @objc func toggleLocalNetwork(_ sender: Any?) {
        if let emulator { return emulator.toggleLocalNetwork() }
        guard let instance = stoppedSelection else { return }
        DeviceOptions(
            settings: DeviceSettingsFile(directory: instance.paths.directory),
            board: instance.board,
            link: { nil }
        ).toggleLocalNetwork()
    }

    /// The settings items for the running device (DeviceSettingsMenu).
    private var settingsMenu: DeviceSettingsMenu {
        let stopped = stoppedSelection.flatMap { instance in
            instance.profile.map {
                var device = DeviceSettingsMenu.Device(marketingName: $0.preferredName, shortName: $0.shortName)
                device.localNetworkEnabled = DeviceSettings.load(instance.paths.directory).localNetwork ?? false
                device.isRunning = false
                return device
            }
        }
        return DeviceSettingsMenu(
            device: stopped
                ?? emulator.map {
                    var device = DeviceSettingsMenu.Device(
                        marketingName: $0.profile.preferredName,
                        shortName: $0.profile.shortName
                    )
                    device.localNetworkEnabled = $0.localNetworkEnabled
                    device.autoRotateEnabled = $0.autoRotateEnabled
                    device.debugPortEnabled = $0.debugPortEnabled
                    device.debugSocket = $0.debugSocket
                    device.lldbAttachCommand = $0.lldbAttachCommand
                    device.network = $0.network
                    return device
                },
            desiredNetwork: NetworkAccessPreference.desired(running: emulator?.network)
        )
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let menuItem: DeviceSettingsMenu.Item
        switch item.action {
        case #selector(toggleLocalNetwork(_:)): menuItem = .localNetwork
        case #selector(toggleAutomaticRotation(_:)): menuItem = .autoRotate
        case #selector(showDebugPort(_:)): menuItem = .debugPort
        case #selector(copyLLDBCommand(_:)): menuItem = .copyLLDBCommand
        case #selector(toggleInternetAccess(_:)): menuItem = .internet
        default: return true
        }
        let validation = settingsMenu.validate(menuItem)
        if let title = validation.title { item.title = title }
        if let on = validation.isOn { item.state = on ? .on : .off }
        item.toolTip = validation.toolTip
        return validation.isEnabled
    }

    @objc func sponsorProject(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/sponsors/samhenrigold")!)
    }

    @objc func showHelp(_ sender: Any?) {
        if helpController == nil {
            helpController = HelpWindowController(
                text: Bundle.main.url(forResource: "Help", withExtension: "txt")
                    .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                    ?? "# Help\nHelp is missing from this copy of Light Touch."
            )
        }
        helpController?.show(deviceName: emulator?.profile.shortName ?? "iPod")
        helpController?.showWindow(sender)
        helpController?.window?.makeKeyAndOrderFront(sender)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let windowController else { return nil }
        let menu = NSMenu()
        for (title, action) in [
            ("Home Screen", #selector(MainWindowController.deviceHome(_:))),
            ("Lock", #selector(MainWindowController.deviceLock(_:))),
            ("Restart…", #selector(MainWindowController.deviceReset(_:)))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = windowController
            menu.addItem(item)
        }
        return menu
    }

    @objc func showAbout(_ sender: Any?) { AboutCredits.show() }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The boards' hardware facts are the emulator's: the bundled helper lists them once, here off the main thread.
        Machines.helper = DeviceLink.Configuration.bundledHelper
        Task.detached { _ = Board.n72.hardware }
        // Keep AppKit's native editing utilities for search fields and panels.
        // Device, Files, Help, and log windows have distinct jobs, not tabs.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.disableRelaunchOnLogin()

        MainMenuBuilder.install(profile: .n72)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // An Xcode preview's host only draws views: no library lock (the app run beside it would be refused), alerts,
        // reports or devices.
        guard !Bundled.isPreview else {
            return
        }
        Analytics.launch()
        do { try Bundled.requireStorage() } catch {
            let alert = NSAlert()
            if (error as? CocoaError)?.code == .fileLocking {
                alert.messageText = Bundled.appLockMessage
                alert.informativeText = "Quit the other copy first."
            } else {
                Analytics.failure("App.storageUnavailable", error)
                alert.alertStyle = .critical
                alert.messageText = "Couldn’t open device storage"
                alert.informativeText = error.localizedDescription
            }
            // Either way this copy can't go on.
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            Self.requestTermination()
            return
        }
        do { try NativeLogging.start() } catch {
            logEvent("logging: native output capture unavailable: \(error.localizedDescription)")
        }
        // This copy holds the library: the marks of the steps a crash interrupted are its own to read.
        for step in CrashGuard.launch() { Analytics.lastRunDied(in: step) }
        // State from before devices were prepared from IPSWs: erased once, or the app quits. The erase
        // runs off the main actor behind a progress window; a launch after a quit midway resumes without asking.
        if let legacy = LegacyState.find(
            state: Bundled.stateDirectory,
            applicationSupport: Bundled.stateOverride == nil
                ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] : nil
        ) {
            if !legacy.resuming {
                let alert = NSAlert()
                alert.messageText = LegacyState.message
                alert.informativeText = LegacyState.detail
                alert.addButton(withTitle: "Erase and Continue")
                alert.addButton(withTitle: "Quit")
                alert.buttons.first?.hasDestructiveAction = true
                guard alert.runModal() == .alertFirstButtonReturn else {
                    Self.requestTermination()
                    return
                }
            }
            eraseLegacy(legacy)
            return
        }
        finishLaunching()
    }

    /// Erase and Continue's erase; a failure offers Try Again, Show in Finder (the item it couldn't remove, when
    /// known) or Quit, and the next launch asks again (LegacyState.marker).
    private func eraseLegacy(_ legacy: LegacyState) {
        let progress = MigrationProgress()
        progress.window.makeKeyAndOrderFront(nil)
        Task {
            do { try await legacy.erase() } catch {
                progress.window.orderOut(nil)
                let alert = NSAlert(error: error)
                alert.addButton(withTitle: "Try Again")
                alert.addButton(withTitle: "Quit")
                let path = (error as NSError).userInfo[NSFilePathErrorKey] as? String
                if path != nil { alert.addButton(withTitle: "Show in Finder") }
                switch alert.runModal() {
                case .alertFirstButtonReturn: return eraseLegacy(legacy)
                case .alertThirdButtonReturn:
                    if let path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                default: break
                }
                Self.requestTermination()
                return
            }
            progress.window.orderOut(nil)
            finishLaunching()
        }
    }

    /// The rest of the launch, once no legacy state is left.
    private func finishLaunching() {
        warnIfIncomplete()
        // The network question belongs to the device being started (DeviceSessionHost.start), not to the app.
        let host = DeviceSessionHost()
        Self.sweepStorage()
        Board.prepareIcons()
        #if DEBUG
            Self.adoptDevelopmentBase(catalog: host.catalog)
        #endif
        // A fresh install starts unpacking the built-in iPod and selects it (it starts once published).
        if let bundled = FirmwareJobs.shared.prepareBundledIfFresh(
            sidebarSaved: UserDefaults.standard.object(forKey: SidebarList.entriesKey) != nil
        ) {
            host.lastSelection = bundled
        }
        let profile = host.launchSelection?.profile ?? .n72
        MainMenuBuilder.install(profile: profile)
        let controller = MainWindowController(host: host, profile: profile)
        controller.showWindow(nil)
        self.host = host
        self.windowController = controller
        ClipboardSharing.shared.emulators = { [weak self] in self?.emulators ?? [] }
        ClipboardSharing.shared.start()
        controller.selectLaunchDevice()
        Analytics.libraryOpened(host.library.instances)
        dockProgress.start()
        if !pendingOpen.isEmpty {
            controller.open(pendingOpen)
            pendingOpen = []
        }
    }

    /// A copy missing a part it ships (a partial copy, something quarantined, a Debug build without the checkout's
    /// usbmuxd) loses app management or the guest tools without a word, so say so before a device starts, until
    /// "don't show" is checked for that same set of missing parts.
    private func warnIfIncomplete() {
        var missing: [String] = []
        if !FileManager.default.isExecutableFile(atPath: USBMux.binary) { missing.append("usbmuxd") }
        if Bundled.resource("Guest/guest.aar") == nil { missing.append("guest.aar") }
        guard !missing.isEmpty else { return }
        let names = missing.joined(separator: " ")
        Analytics.failure("App.componentsMissing", nil, ["missing": names])
        let ignoredKey = "ignoredMissingComponents"
        guard UserDefaults.standard.string(forKey: ignoredKey) != names else { return }
        let alert = NSAlert()
        alert.messageText = "Some of Light Touch’s files are missing"
        alert.informativeText =
            "Installing apps and transferring files won’t work until you download Light Touch again."
        alert.addButton(withTitle: "Download Light Touch")
        alert.addButton(withTitle: "Continue")
        alert.showsSuppressionButton = true
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://samhenri.gold/lighttouch/")!)
        }
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(names, forKey: ignoredKey) }
    }

    /// Development runs: LTM_DEV_BASE names a `firmwarekit create` output directory to run as a
    /// device; a record naming it (kept in place, never locked) is written once, for the entry its
    /// lock names. The app has no other way to boot anything but a prepared base. Debug only.
    #if DEBUG
        private static func adoptDevelopmentBase(catalog: FirmwareCatalog) {
            guard let path = ProcessInfo.processInfo.environment["LTM_DEV_BASE"] else { return }
            let base = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            let state = Bundled.stateDirectory
            guard
                !DeviceInstance.all(state: state).contains(where: {
                    DeviceInstance.url($0.base.path, state: state).standardizedFileURL == base
                })
            else { return }
            guard let id = (try? DeviceLock.read(base: base))??.entryID, let entry = catalog.entry(id: id) else {
                return logEvent("LTM_DEV_BASE: \(path) has no device.lock.json naming a catalog entry")
            }
            do {
                let instance = try PreparationJob.publish(
                    staging: base,
                    entry: entry,
                    id: UUID(),
                    state: state,
                    keep: true
                )
                DeviceLibrary.shared.reload()
                logEvent("LTM_DEV_BASE: \(path) is device \(instance.id.uuidString) (\(entry.id))")
            } catch { logEvent("LTM_DEV_BASE: \(error.localizedDescription)") }
        }
    #endif

    /// Launch, with the library's lock held: finish what a crash or an older
    /// build left. FirmwareJobs' own init sweeps Preparing/ and the IPSW stores.
    private static func sweepStorage() {
        let state = Bundled.stateDirectory
        let logs = Bundled.logsDirectory
        let records = DeviceInstance.all(state: state)
        _ = FirmwareJobs.shared
        DeviceStateStorage.sweepDeleting(state: state)
        DeviceSettings.migrateDefaults(.standard, state: state, devices: records.map(\.id))
        IPALibrary.sweep(devices: records)
        for record in records { USBMux.secure(DeviceInstance.url(record.storage.usbmuxConf, state: state)) }
        // A crashed or killed run's daemons, reparented to launchd: a device not started again kept its daemon.
        USBMux.reapOrphans(records, state: state, logs: logs)
        // The socket folders earlier builds made in the app group's container for runs that are gone.
        let stale = HelperSandbox.sweepStaleSockets()
        if !stale.isEmpty { logEvent("sockets: removed the folders of processes that are gone: \(stale)") }
        // Bases published by earlier builds become immutable too (a development base, outside State, is left alone).
        for record in records where !record.base.path.hasPrefix("/") {
            DeviceStateStorage.lockBase(DeviceInstance.url(record.base.path, state: state))
        }
        // Logs of devices that no longer exist, and the single-device logs
        // from before per-device ones (Logs/serial.log*, usbmuxd.log*).
        let fm = FileManager.default
        let deviceLogs = logs.appendingPathComponent("Devices", isDirectory: true)
        let ids = Set(records.map(\.id.uuidString))
        for name in (try? fm.contentsOfDirectory(atPath: deviceLogs.path)) ?? []
        where UUID(uuidString: name) != nil && !ids.contains(name) {
            try? DeviceStateStorage.removeTree(deviceLogs.appendingPathComponent(name))
        }
        for name in (try? fm.contentsOfDirectory(atPath: logs.path)) ?? []
        where ["serial.log", "serial.log.1", "usbmuxd.log", "usbmuxd.log.1"].contains(name) {
            try? fm.removeItem(at: logs.appendingPathComponent(name))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        quitting.willTerminate()
        // A quit (or a crash, through firmwarekit's parent watch) cancels
        // every preparation; the next launch's sweep removes its staging.
        if host != nil {
            FirmwareJobs.shared.cancelAll()
            CrashGuard.quit()
        }
        for emulator in emulators { emulator.stop() }
    }

    /// On quit: guard an in-flight install, then halt each device
    /// (EmulatorController.halt: storage flushed, no guest shutdown).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // the trail says a run that ended in a step (CrashGuard) was asked to quit: a force quit after it, not a crash
        Analytics.breadcrumb("App.quitAsked")
        let answer = quitting.shouldTerminate(
            busy: { [weak self] in
                if self?.emulators.contains(where: \.isErasing) == true || self?.host?.storageWork.isErasing == true {
                    return "Erasing a device…"
                }
                return DeviceFilesystemEdits.shared.activity.values.sorted().first
            },
            confirmWait: { work in
                let alert = NSAlert()
                alert.messageText = work
                alert.informativeText = "Quitting now would interrupt it. Light Touch can quit once it’s done."
                alert.addButton(withTitle: "Quit When Done")
                alert.addButton(withTitle: "Cancel")
                return alert.runModal() == .alertFirstButtonReturn
            },
            finishRecording: { windowController?.finishRecordingBeforeQuit() == true },
            preparing: FirmwareJobs.shared.preparing,
            confirmPreparation: { preparing in
                let alert = NSAlert()
                alert.messageText = preparing == 1 ? "A device is being prepared" : "Devices are being prepared"
                alert.informativeText =
                    "Quitting stops the preparation. It starts over the next time you prepare the device."
                alert.addButton(withTitle: "Quit Anyway")
                alert.addButton(withTitle: "Cancel")
                alert.buttons.first?.hasDestructiveAction = true
                return alert.runModal() == .alertFirstButtonReturn
            },
            hasDevices: !emulators.isEmpty,
            changesInProgress: emulators.contains(where: \.isInstalling) || AppInstaller.hasPendingWork
                || windowController?.hasFileTransfer == true,
            confirmChanges: {
                let alert = NSAlert()
                alert.messageText = "Device changes are in progress"
                alert.informativeText = "Quitting cancels changes that haven’t finished."
                alert.addButton(withTitle: "Quit Anyway")
                alert.addButton(withTitle: "Cancel")
                alert.buttons.first?.hasDestructiveAction = true
                return alert.runModal() == .alertFirstButtonReturn
            },
            cancelChanges: {
                AppInstaller.cancelPendingWork()
                windowController?.cancelFileTransfer()
            },
            running: emulators.filter { !$0.isDead && !$0.isPoweredOff }.map { emulator in
                { done in
                    let halt = emulator.halt()
                    Task {
                        _ = await halt.value
                        done()
                    }
                }
            }
        )
        switch answer {
        case .now: return .terminateNow
        case .cancel: return .terminateCancel
        case .later: return .terminateLater
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Finder, the Dock and `open` hand over IPSWs and .ipa files here (Configuration/LightTouchMac-Info.plist).
    /// A launch by opening one arrives before the window exists: held until finishLaunching.
    private var pendingOpen: [URL] = []
    func application(_ application: NSApplication, open urls: [URL]) {
        if let windowController { windowController.open(urls) } else { pendingOpen += urls }
    }

    /// Reopen the retained device window even when Files or Help is still visible.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
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

/// A small window while the legacy erase runs off the main actor.
private final class MigrationProgress {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    private let bar = NSProgressIndicator()

    init() {
        window.title = "Light Touch"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        let label = NSTextField(labelWithString: LegacyState.progressMessage)
        bar.style = .bar
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 1
        bar.startAnimation(nil)
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            bar.widthAnchor.constraint(equalToConstant: 320)
        ])
        window.contentView = content
        window.center()
    }
}
