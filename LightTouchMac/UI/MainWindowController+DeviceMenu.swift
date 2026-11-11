import Cocoa
import FirmwareSchema
import HostRuntime
import HostServiceWire
import LightTouchCore
import SwiftUI
import UniformTypeIdentifiers

extension MainWindowController {
    // MARK: - Device menu actions (routed via the responder chain)

    @objc func deviceHome(_ sender: Any?) { emulator?.pressHome() }
    @objc func deviceLock(_ sender: Any?) {
        guard let emulator else { return }
        if emulator.isPoweredOff { emulator.powerOn() } else { emulator.pressLock() }
    }
    /// Device ▸ Accessibility itself: only validated (the submenu is dimmed with no device running).
    @objc func accessibilityMenu(_ sender: Any?) {}
    /// Device ▸ Accessibility opening: what the guest has on, then `done`.
    func readAccessibility(_ done: @escaping @MainActor () -> Void) { emulator?.readAccessibility(done) }
    /// One of Device ▸ Accessibility's switches, by the item's tag (AccessibilityFeature).
    @objc func toggleAccessibility(_ sender: NSMenuItem) {
        guard let emulator, let feature = AccessibilityFeature(rawValue: sender.tag) else { return }
        let on = sender.state != .on
        Task {
            do { try await emulator.setAccessibility(feature, on: on) } catch {
                if let window { await NSAlert(error: error).beginSheetModal(for: window) }
            }
        }
    }
    @objc func deviceVolumeUp(_ sender: Any?) { emulator?.pressVolumeUp() }
    @objc func deviceVolumeDown(_ sender: Any?) { emulator?.pressVolumeDown() }
    @objc func deviceRotate(_ sender: Any?) {
        guard let emulator else { return }
        let action = RotationControlAction(
            rotationDegrees: emulator.rotationDegrees,
            optionPressed: NSEvent.modifierFlags.contains(.option)
        )
        emulator.rotate(clockwise: action.clockwise)
    }

    @objc func refreshRotationModifiers() {
        syncRotationControls(optionPressed: NSEvent.modifierFlags.contains(.option))
    }

    func syncRotationControls(optionPressed: Bool) {
        let action = RotationControlAction(
            rotationDegrees: emulator?.rotationDegrees ?? 0,
            optionPressed: optionPressed
        )
        window?.toolbar?.items.first(where: { $0.itemIdentifier == .rotate })?
            .show(label: action.title, toolTip: action.help, symbol: action.symbol)
    }

    @objc func configureWebProxy(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, let emulator else { return }
        let editor = ProxySettingsView(
            configuration: emulator.webProxy,
            status: emulator.webProxyStatus,
            profile: emulator.profile
        )
        proxySettingsEditor = editor
        weak var presented: NSWindow?
        let sheet = ProxySettingsView.sheet(editor) { apply in
            presented.map { window.endSheet($0, returnCode: apply ? .OK : .cancel) }
        }
        presented = sheet
        window.beginSheet(sheet) { [weak self] response in
            self?.proxySettingsEditor = nil
            guard response == .OK else { return }
            do { try emulator.configureWebProxy(editor.configuration) } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    @objc func toggleKeyboardInput(_ sender: Any?) { emulator?.toggleKeyboardInput() }
    @objc func toggleHardwareKeyboard(_ sender: Any?) { emulator?.toggleHardwareKeyboard() }

    @objc func toggleFiles(_ sender: Any?) {
        if filesWindow == nil {
            let files = DeviceFilesWindowController(profile: currentProfile)
            filesWindow = files
            files.browser.onActivityChange = { [weak self] in self?.refreshFileStatus() }
            bindFilesWindow(reload: true)
        }
        filesWindow?.showWindow(sender)
    }

    /// The copy's status shows over the device it copies with, not over whichever is selected.
    func refreshFileStatus() {
        // A copy pins the window to its device; its end lets the window follow the selection again.
        FilesConnection.shared.setTransferring(hasFileTransfer)
        bindFilesWindow()
        guard let filesVC, let emulator, FilesConnection.shared.isTransferring(emulator.instance.id) else {
            fileStatus.isHidden = true
            deviceVC?.updateStatusVisibility()
            return
        }
        fileStatus.update(title: filesVC.transferStatus, primary: "Files", secondary: "Cancel")
        deviceVC?.updateStatusVisibility()
    }

    @objc func focusDeviceScreen(_ sender: Any?) {
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        deviceVC?.screen.endLiveText()
        window?.makeFirstResponder(deviceVC?.screen)
    }

    @objc func toggleVerboseBoot(_ sender: Any?) {
        UserDefaults.standard.set(
            !EmulatorController.verboseBoot,
            forKey: EmulatorController.verboseBootDefaultsKey
        )
    }

    @objc func toggleKernelConsole(_ sender: Any?) {
        UserDefaults.standard.set(
            !EmulatorController.kernelConsole,
            forKey: EmulatorController.kernelConsoleDefaultsKey
        )
    }

    @objc func deviceRotateLeft(_ sender: Any?) {
        emulator?.rotate(clockwise: false)
    }

    @objc func deviceRotateRight(_ sender: Any?) {
        emulator?.rotate(clockwise: true)
    }

    @objc func selectMotionPose(_ sender: NSMenuItem) {
        guard let pose = EmulatorController.MotionPose(rawValue: sender.tag) else { return }
        emulator?.setMotionPose(pose)
        deviceVC?.screen.resetMotion()
    }
    @objc func resetMotion(_ sender: Any?) { deviceVC?.screen.resetMotion() }

    @objc func deviceShake(_ sender: Any?) { emulator?.shake() }
    @objc func togglePhoneRemote(_ sender: Any?) { phoneRemote.toggle(session) }
    @objc func setCompassHeading(_ sender: NSMenuItem) { emulator?.setCompassHeading(sender.tag) }

    @objc func showCarrier(_ sender: Any?) {
        guard let emulator, emulator.hasCellular else { return }
        let id = emulator.instance.id
        if carrierWindows[id] == nil { carrierWindows[id] = CarrierWindowController(emulator: emulator) }
        carrierWindows[id]?.model.rebind(to: emulator)
        carrierWindows[id]?.showWindow(sender)
    }

    @objc func showTweaks(_ sender: Any?) {
        guard let instance = selectedInstance else { return }
        let id = instance.id
        if tweaksWindows[id] == nil {
            let (tweaks, guest) = tweaksSession(instance)
            let model = TweaksPanelModel(tweaks: tweaks, guest: guest)
            tweaksWindows[id] = TweaksWindowController(model: model, name: instance.name)
        }
        let model = tweaksWindows[id]?.model
        model?.fingerDots = (
            get: { [weak self] in self?.deviceVC?.screen.showsTouches ?? false },
            set: { [weak self] on in
                guard let screen = self?.deviceVC?.screen, screen.showsTouches != on else { return }
                self?.toggleTouchOverlay(nil)
            }
        )
        tweaksWindows[id]?.showWindow(sender)
    }

    /// A device's tweaks and guest: its session's while it runs (applied live), else its settings alone.
    private func tweaksSession(_ instance: DeviceInstance) -> (DeviceTweaks, GuestServices?) {
        guard let emulator = host.sessions.first(where: { $0.instance.id == instance.id })?.emulator else {
            return (DeviceTweaks.stopped(instance), nil)
        }
        return (emulator.tweaks, emulator.guest)
    }

    /// Each Tweaks panel follows its device's session: a new one when it starts, its settings alone when it stops.
    func followTweaksPanels() {
        for (id, panel) in tweaksWindows {
            guard let instance = host.library.instance(id: id) else {
                panel.close()
                tweaksWindows[id] = nil
                continue
            }
            let (tweaks, guest) = tweaksSession(instance)
            panel.model.rebind(tweaks: tweaks, guest: guest)
        }
    }

    /// Each Carrier panel drives its device's current session; one whose device no longer runs closes.
    func followCarrierPanels() {
        for (id, panel) in carrierWindows {
            if let session = host.sessions.first(where: { $0.instance.id == id }) {
                panel.model.rebind(to: session.emulator)
            } else {
                panel.close()
                carrierWindows[id] = nil
            }
        }
    }
    @objc func specialTrick(_ sender: Any?) {
        guard let screen = deviceVC?.screen, screen.canPerformSpecialTrick else { return }
        screen.specialTrick()
        // The chime lands on the pop, a beat after the crouch starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSSound(named: "special_trick")?.play() }
    }
    @objc func toggleDevicePause(_ sender: Any?) {
        guard let emulator else { return }
        if emulator.isPaused { emulator.resume() } else if emulator.isRunning { emulator.pause() }
    }
    @objc func deviceReset(_ sender: Any?) {
        guard let emulator else { return }
        // Confirmed, because a restart cuts the guest off mid-write much the way
        // a force quit does, and it sits one row above Erase in the same menu.
        let alert = NSAlert()
        alert.messageText = "Restart the \(emulator.profile.shortName)?"
        alert.informativeText = "Anything it hasn’t finished saving may be lost."
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window else {
            if alert.runModal() == .alertFirstButtonReturn { emulator.reset() }
            return
        }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            emulator.reset()
        }
    }
    /// Shut Down… (⌘.): the guest powers itself off, after asking.
    @objc func deviceShutDown(_ sender: Any?) { emulator.map(confirmShutDown) }
    func confirmShutDown(_ emulator: EmulatorController) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Shut down this \(emulator.profile.shortName)?"
        alert.informativeText =
            emulator.ladder.shutDownHalts
            ? "It hasn’t finished starting, so it stops at once."
            : "It turns off the way it does when you slide to power off."
        alert.addButton(withTitle: "Shut Down")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self, weak emulator] response in
            guard response == .alertFirstButtonReturn, let self, let emulator else { return }
            shutDown(emulator)
        }
    }

    /// Force Stop…: the hard halt, after asking.
    @objc func deviceForceStop(_ sender: Any?) {
        if let batch = library.commandBatch(.forceStop) { return perform(batch) }
        emulator.map(confirmForceStop)
    }
    func confirmForceStop(_ emulator: EmulatorController) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Force stop this \(emulator.profile.shortName)?"
        alert.informativeText =
            "It stops at once, as if its battery were removed. Anything an app hasn’t saved is lost."
        alert.addButton(withTitle: "Force Stop")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self, weak emulator] response in
            guard response == .alertFirstButtonReturn, let self, let emulator else { return }
            powerOff(emulator)
        }
    }

    /// `then` runs once the guest has powered itself off, not after a Force Stop took over.
    func shutDown(_ emulator: EmulatorController, then: (() -> Void)? = nil) {
        let shutdown = emulator.shutDown()
        Task { [weak emulator] in
            let outcome = await shutdown.value
            guard let emulator else { return }
            switch outcome {
            case .poweredOff:
                emulator.resolveDeviceNotice(for: .powerOff)
                then?()
            case .forced:
                emulator.resolveDeviceNotice(for: .powerOff)
            case .timedOut:
                emulator.reportDeviceNotice(
                    "The \(emulator.profile.shortName) didn’t shut down. Force Stop stops it at once.",
                    for: .powerOff
                )
            }
        }
    }

    func powerOff(_ emulator: EmulatorController) {
        let stop = emulator.powerOff()
        Task { [weak emulator] in
            let confirmed = await stop.value
            if confirmed {
                emulator?.resolveDeviceNotice(for: .powerOff)
                return
            }
            emulator?.reportDeviceNotice(
                "The \(emulator?.profile.shortName ?? "device") didn’t stop. Quit Light Touch to stop it.",
                for: .powerOff
            )
        }
    }

    /// Factory-reset the device — the "nuke everything" button. Wipes the NAND
    /// overlay (all installed apps + settings), back to the base image; a
    /// running device then restarts. The base image is never touched.
    @objc func eraseDevice(_ sender: Any?) {
        if let batch = library.commandBatch(.erase) { return perform(batch) }
        selectedEntry.map { perform(.erase, for: $0) }
    }

    /// A device with no session is erased by the host (its row says Erasing); a started one by its controller.
    func erase(_ entry: FirmwareCatalog.Entry) {
        guard let window, let instance = host.instance(for: entry) else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Erase all content and settings?"
        alert.informativeText =
            "This permanently removes all apps, settings, and saved state from this \(entry.profile?.shortName ?? "device") and returns it to how it was prepared."
            + (AppInstaller.hasPendingWork(for: instance.id) ? " Installs in progress are cancelled." : "")
        alert.addButton(withTitle: "Erase")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            // Asked again on the answer: the device may have started or stopped while the question was up.
            guard response == .alertFirstButtonReturn, let self, canPerform(.erase, for: entry) else { return }
            eraseConfirmed(entry, window: window)
        }
    }

    /// Erase after its question (one device's, or several rows' one for the lot).
    func eraseConfirmed(_ entry: FirmwareCatalog.Entry, window: NSWindow) {
        guard let instance = host.instance(for: entry) else { return }
        if let emulator = host.session(for: entry)?.emulator { return emulator.requestFactoryReset() }
        let erase = host.erase(instance)
        Task {
            do {
                try await erase.value
                Analytics.signal("Device.erased", ["board": instance.board])
            } catch {
                Analytics.failure("Device.eraseFailed", error, ["board": instance.board])
                await NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    @objc func installApp(_ sender: Any?) {
        guard let window, let emulator else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        panel.message = "Choose decrypted .ipa files to install."
        panel.prompt = "Install"
        panel.beginSheetModal(for: window) { [weak window] response in
            guard response == .OK else { return }
            for url in panel.urls {
                AppInstaller.start(url, with: emulator, presenting: window)
            }
        }
    }

    @objc func syncMedia(_ sender: Any?) {
        guard let window, let emulator else { return }
        let panel = NSOpenPanel()
        let firmware = emulator.mediaFirmware
        panel.allowedContentTypes = PreparedMedia.extensions.sorted()
            .filter { MediaSupport.supports(PreparedMedia.destination(forExtension: $0), on: firmware) }
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.beginSheetModal(for: window) { [weak window] response in
            guard response == .OK else { return }
            for url in panel.urls {
                AppInstaller.startMedia(url, with: emulator, presenting: window)
            }
        }
    }

    /// Respring — the quick fix for a freshly sideloaded app that crashes on
    /// launch until the device is restarted.
    @objc func restartSpringBoard(_ sender: Any?) {
        guard let emulator else { return }
        Task {
            do {
                try await emulator.restartSpringBoard()
            } catch {
                AppInstaller.presentError(error, window)
            }
        }
    }

    // MARK: - View menu (inspector), synced with the toolbar

    @objc func toggleAppInspector(_ sender: Any?) {
        inspectorItem.animator().isCollapsed.toggle()
    }

    @objc func toggleConsole(_ sender: Any?) { console.split.toggle() }
}
