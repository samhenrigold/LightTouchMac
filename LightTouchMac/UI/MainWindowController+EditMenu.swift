import Cocoa
import FirmwareSchema
import HostRuntime
import HostServiceWire
import LightTouchCore
import SwiftUI
import UniformTypeIdentifiers

extension MainWindowController {
    @objc func saveScreenshot(_ sender: Any?) { capture.saveScreenshot() }
    @objc func saveScreenshotAs(_ sender: Any?) { capture.saveScreenshotAs() }
    @objc func openScreenshot(_ sender: Any?) { capture.openScreenshot() }

    /// The standard Copy command reaches here only after focused text and
    /// other native responders have had their turn.
    @objc func copy(_ sender: Any?) {
        guard let screen = deviceVC?.screen, window?.firstResponder === screen, !screen.isShowingLiveText else {
            return
        }
        copyScreen(sender)
    }

    /// Settings…: General, Capture (the save folder, screenshot app, sounds…) and Storage
    /// (sizes per device and store, Remove IPSW, Clear Caches, Delete Device).
    @objc func showSettings(_ sender: Any?) { openSettings(at: nil) }
    /// The toolbar's Capture Options: Settings, at its Capture pane.
    @objc func showCaptureOptions(_ sender: Any?) { openSettings(at: .capture) }

    private func openSettings(at pane: SettingsWindowController.Pane?) {
        if settingsWindow == nil {
            let capture = CaptureOptionsView(
                preferences: capturePreferences,
                onChange: { [weak self] in self?.validateCaptureToolbar() }
            )
            let storage = StorageUsage(
                catalog: host.catalog,
                jobs: .shared,
                delete: { [weak self] instance in self?.deleteFromStorage(instance) },
                canDelete: { [weak self] instance in self?.canDeleteFromStorage(instance) ?? false },
                label: { [weak self] instance in
                    self?.sidebarLabel(instance)
                }
            )
            let settings = SettingsWindowController(general: GeneralSettingsView(), capture: capture, storage: storage)
            storageUsage = storage
            settingsWindow = settings
        }
        guard let settingsWindow else { return }
        if let pane { settingsWindow.pane = pane }
        storageUsage?.reload()
        settingsWindow.showWindow(nil)
        settingsWindow.window?.makeKeyAndOrderFront(nil)
    }

    @objc func toggleCaptureScreenOnly(_ sender: Any?) { capture.toggleCaptureScreenOnly() }
    @objc func toggleRecordDeviceBezel(_ sender: Any?) { capture.toggleRecordDeviceBezel() }
    func installFileStatus() {
        fileStatus.isHidden = true
        startupStatus.isHidden = true
        startupStatus.onPrimary = { [weak self] in self?.showDeviceLogs(nil) }
        fileStatus.onPrimary = { [weak self] in self?.toggleFiles(nil) }
        fileStatus.onSecondary = { [weak self] in self?.cancelFileTransfer() }
    }

    @objc func showLiveText(_ sender: Any?) {
        guard let deviceVC, !recording.isActive, deviceVC.screen.isShowingLiveText || canTakeScreenshot else { return }
        deviceVC.screen.toggleLiveText()
        validateCaptureToolbar()
    }

    /// View ▸ Device Bezels: every device as the 3D model, the flat art, or the screen alone.
    @objc func selectDeviceBezel(_ sender: NSMenuItem) {
        guard let bezel = DisplayView.Bezel(rawValue: sender.tag) else { return }
        if bezel == .model { CrashGuard.tryAgain(.model) }
        DisplayView.bezel = bezel
    }

    /// View ▸ Free-Form Screen: this device's screen alone, resized by dragging (DisplayView, issue #21).
    @objc func toggleFreeFormScreen(_ sender: Any?) {
        guard let screen = deviceVC?.screen else { return }
        screen.setFreeForm(!screen.isFreeForm)
    }

    /// View ▸ Native Size: the free-form screen back to the shipped size, waiting for Apply like a drag's.
    @objc func freeFormNativeSize(_ sender: Any?) { deviceVC?.screen.showNativeSize() }

    @objc func toggleTouchOverlay(_ sender: Any?) {
        deviceVC?.screen.showsTouches.toggle()
        validateCaptureToolbar()
    }

    func validateCaptureToolbar() {
        refreshRotationModifiers()
        // AppKit does not automatically validate toolbar items with custom
        // views. Update the control explicitly on health and elapsed-time changes.
        for item in window?.toolbar?.items ?? [] where item.itemIdentifier == .recording {
            item.isEnabled = validateToolbarItem(item)
        }
        window?.toolbar?.validateVisibleItems()
    }

    @objc func toggleRecording(_ sender: Any?) { capture.toggleRecording() }
    @objc func discardRecording(_ sender: Any?) { capture.discardRecording() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { capture.windowShouldClose() }
    func windowWillClose(_ notification: Notification) { phoneRemote.stop() }
    func finishRecordingBeforeQuit() -> Bool { capture.finishRecordingBeforeQuit() }

    @objc func copyScreen(_ sender: Any?) { capture.copyScreen() }
    func windowWillMiniaturize(_ notification: Notification) { recording.stop() }

    @objc func pasteToGuest(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        emulator?.pasteToGuest(text)
    }
}
