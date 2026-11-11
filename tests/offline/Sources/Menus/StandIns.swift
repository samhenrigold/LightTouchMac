// What the menus' items target, as the app's classes answer (MainMenu.swift names them by #selector): no-op actions.
// A new MainWindowController action in MainMenu.swift fails to compile here until it is added below.
import Cocoa
import LightTouchCore

@MainActor final class AppDelegate: NSObject {
    @objc func toggleAutomaticRotation(_ sender: Any?) {}
    @objc func toggleInternetAccess(_ sender: Any?) {}
    @objc func toggleLocalNetwork(_ sender: Any?) {}
    @objc func showDebugPort(_ sender: Any?) {}
    @objc func copyLLDBCommand(_ sender: Any?) {}
    @objc func copyBugReportInfo(_ sender: Any?) {}
    @objc func showHelp(_ sender: Any?) {}
    @objc func showAbout(_ sender: Any?) {}
    @objc func sponsorProject(_ sender: Any?) {}
    @objc func showDeviceWindow(_ sender: Any?) {}
    @objc func showFilesWindow(_ sender: Any?) {}
    @objc func quit(_ sender: Any?) {}
    let updaterController = SPUStandardUpdaterController()
}
/// Sparkle's, which the app menu's Check for Updates… targets.
@MainActor final class SPUStandardUpdaterController: NSObject {
    @objc func checkForUpdates(_ sender: Any?) {}
}
@MainActor final class DeviceFilesViewController: NSObject {
    @objc func importFile() {}
    @objc func exportFile() {}
    @objc func cancelTransfer() {}
    @objc func refreshFiles(_ sender: Any?) {}
    @objc func toggleHidden(_ sender: Any?) {}
}
@MainActor final class MainWindowController: NSWindowController {
    @objc func addDevice(_ sender: Any?) {}
    @objc func cancelFirmwareJob(_ sender: Any?) {}
    @objc func configureWebProxy(_ sender: Any?) {}
    @objc func copyScreen(_ sender: Any?) {}
    @objc func deleteDevice(_ sender: Any?) {}
    @objc func deviceForceStop(_ sender: Any?) {}
    @objc func deviceHome(_ sender: Any?) {}
    @objc func deviceLock(_ sender: Any?) {}
    @objc func deviceReset(_ sender: Any?) {}
    @objc func deviceRotateLeft(_ sender: Any?) {}
    @objc func deviceRotateRight(_ sender: Any?) {}
    @objc func deviceShake(_ sender: Any?) {}
    @objc func deviceShutDown(_ sender: Any?) {}
    @objc func deviceVolumeDown(_ sender: Any?) {}
    @objc func deviceVolumeUp(_ sender: Any?) {}
    @objc func discardRecording(_ sender: Any?) {}
    @objc func downloadAndPrepare(_ sender: Any?) {}
    @objc func eraseDevice(_ sender: Any?) {}
    @objc func jailbreakDevice(_ sender: Any?) {}
    @objc func exportDiagnostics(_ sender: Any?) {}
    @objc func findCatalog(_ sender: Any?) {}
    @objc func importIPSW(_ sender: Any?) {}
    @objc func installApp(_ sender: Any?) {}
    @objc func openScreenshot(_ sender: Any?) {}
    @objc func pasteToGuest(_ sender: Any?) {}
    @objc func resetMotion(_ sender: Any?) {}
    @objc func saveScreenshot(_ sender: Any?) {}
    @objc func saveScreenshotAs(_ sender: Any?) {}
    @objc func selectDeviceBezel(_ sender: Any?) {}
    @objc func selectMotionPose(_ sender: Any?) {}
    @objc func setCompassHeading(_ sender: Any?) {}
    @objc func showCarrier(_ sender: Any?) {}
    @objc func showTweaks(_ sender: Any?) {}
    @objc func showDeviceInFinder(_ sender: Any?) {}
    @objc func showDeviceLogs(_ sender: Any?) {}
    @objc func showLiveText(_ sender: Any?) {}
    @objc func showSettings(_ sender: Any?) {}
    @objc func specialTrick(_ sender: Any?) {}
    @objc func syncMedia(_ sender: Any?) {}
    @objc func toggleAppInspector(_ sender: Any?) {}
    @objc func toggleCaptureScreenOnly(_ sender: Any?) {}
    @objc func toggleRecordDeviceBezel(_ sender: Any?) {}
    @objc func toggleConsole(_ sender: Any?) {}
    @objc func toggleDevicePause(_ sender: Any?) {}
    @objc func toggleDeviceRunning(_ sender: Any?) {}
    @objc func toggleFreeFormScreen(_ sender: Any?) {}
    @objc func freeFormNativeSize(_ sender: Any?) {}
    @objc func toggleHardwareKeyboard(_ sender: Any?) {}
    @objc func toggleKeyboardInput(_ sender: Any?) {}
    @objc func togglePhoneRemote(_ sender: Any?) {}
    @objc func toggleRecording(_ sender: Any?) {}
    @objc func toggleTouchOverlay(_ sender: Any?) {}
    @objc func zoomIn(_ sender: Any?) {}
    @objc func zoomOut(_ sender: Any?) {}
    @objc func zoomPhysicalSize(_ sender: Any?) {}
    @objc func zoomPixelAccurate(_ sender: Any?) {}
    @objc func zoomToFit(_ sender: Any?) {}
    @objc func accessibilityMenu(_ sender: Any?) {}
    @objc func toggleAccessibility(_ sender: NSMenuItem) {}
    func readAccessibility(_ done: @escaping @MainActor () -> Void) {}
}
