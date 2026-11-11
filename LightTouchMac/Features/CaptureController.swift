// A device window's screenshots and screen recordings: the screenshot
// pipeline (copy, save, save as, open), the recording session with its status
// banner, and where captures are saved.
// The window controller owns the menus and toolbar and
// asks this for what they enable; the device (its screen and canvas capture)
// comes from the selected session.

import Cocoa
import HostRuntime
import LightTouchCore
import UniformTypeIdentifiers

@MainActor final class CaptureController: NSObject {
    let recording = ScreenRecordingSession()
    let captureStatus = CaptureStatusView()
    let capturePreferences: CapturePreferences
    /// The device window; screenshots and recordings put their sheets on it.
    weak var window: NSWindow?
    /// The selected device, nil when none runs.
    var session: () -> DeviceSession? = { nil }
    /// Capture state changed: the toolbar and menus revalidate.
    var onChange: () -> Void = {}
    /// Quit was waiting for the recording to save.
    var terminate: () -> Void = {}

    private(set) var screenshotBusy = false
    private(set) var copiedScreenshot = false
    private var copyConfirmation: Task<Void, Never>?
    private var quitAfterRecording = false
    private var closeAfterRecording = false

    private var emulator: EmulatorController? { session()?.emulator }
    private var deviceVC: DeviceViewController? { session()?.workspace.deviceVC }
    var captureMode: Int { UserDefaults.standard.integer(forKey: "captureMode") == 1 ? 1 : 0 }

    var availability: CaptureAvailability {
        var availability = CaptureAvailability()
        if let emulator {
            availability.isRunning = emulator.isRunning
            availability.machine = emulator.state
            availability.isSleeping = emulator.isSleeping
        }
        availability.screenshotBusy = screenshotBusy
        availability.recordingSaving = recording.phase == .saving
        availability.recordingCanStop = recording.canStop
        return availability
    }
    var canTakeScreenshot: Bool { availability.canTakeScreenshot }
    var canStartRecording: Bool { availability.canStartRecording }
    var canToggleRecording: Bool { availability.canToggleRecording }

    init(preferences: CapturePreferences = .shared) {
        capturePreferences = preferences
        super.init()
        installCaptureStatus()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stopHiddenRecording),
            name: NSApplication.didHideNotification,
            object: nil
        )
        recording.onChange = { [weak self] in self?.refreshRecording() }
        recording.onBeganRecording = { CaptureSound.recordingStarted.play() }
        recording.onStoppedRecording = { CaptureSound.recordingStopped.play() }
        recording.chooseSaveDestination = { [weak self] _ in
            guard let self, let window = self.window else { return nil }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.quickTimeMovie]
            panel.directoryURL = self.captureFolder
            panel.nameFieldStringValue = self.captureName("Recording") + ".mov"
            return await panel.beginSheetModal(for: window) == .OK ? panel.url : nil
        }
        recording.onCompleted = { [weak self] result in
            guard let self else { return }
            switch result {
            case .saved(let url):
                Analytics.signal("Capture.recorded")
                if capturePreferences.openFinderAfterCapture { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            case .failed(let kept?):
                Analytics.failure("Capture.recordingFailed", recording.failure)
                // The unsaved take, beside the alert saying why.
                NSWorkspace.shared.activateFileViewerSelecting([kept])
            case .failed: Analytics.failure("Capture.recordingFailed", recording.failure)
            case .discarded: break
            }
        }
        recording.onFinished = { [weak self] success in
            guard let self else { return }
            if success {
                if quitAfterRecording { terminate() } else if closeAfterRecording { self.window?.performClose(nil) }
            } else if recording.phase == .idle, let failure = recording.failure, let window = self.window {
                NSAlert(error: failure).beginSheetModal(for: window)
            }
            quitAfterRecording = false
            closeAfterRecording = false
        }
    }

    // MARK: - Screenshots

    func copyScreen() { takeScreenshot(.copy) }
    func saveScreenshot() { takeScreenshot(.save) }
    func saveScreenshotAs() { takeScreenshot(.saveAs) }
    func openScreenshot() { takeScreenshot(.open) }

    private func captureImage() async throws -> CGImage {
        guard let workspace = session()?.workspace else { throw CaptureError.failed("No screen image is available.") }
        let deviceVC = workspace.deviceVC
        deviceVC.screen.endLiveText()
        if captureMode == 0 { return try await workspace.canvasCapture.screenshot() }
        guard let image = deviceVC.screen.captureFrame() else {
            throw CaptureError.failed("No screen image is available.")
        }
        return image
    }

    private enum ScreenshotAction { case copy, save, saveAs, open }
    private func takeScreenshot(_ action: ScreenshotAction) {
        guard canTakeScreenshot, let window else { return }
        Analytics.signal("Capture.screenshot", ["action": "\(action)"])
        screenshotBusy = true
        onChange()
        Task { [weak self] in
            guard let self else { return }
            defer {
                screenshotBusy = false
                onChange()
            }
            do {
                let image = try await captureImage()
                guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw CaptureError.failed("Couldn’t create the screenshot.")
                }
                let nsImage = NSImage(cgImage: image, size: .zero)
                var savedURL: URL?
                if action == .copy {
                    try copyImage(nsImage)
                    showCopyConfirmation()
                } else if action == .open {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
                        "Light Touch Screenshots",
                        isDirectory: true
                    )
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent(captureName("Screenshot")).appendingPathExtension("png")
                        .unused
                    try data.write(to: url, options: .atomic)
                    if let application = capturePreferences.openInApplicationURL {
                        _ = try await NSWorkspace.shared.open(
                            [url],
                            withApplicationAt: application,
                            configuration: .init()
                        )
                    } else {
                        _ = try await NSWorkspace.shared.open(url, configuration: .init())
                    }
                } else {
                    if action == .saveAs {
                        guard let url = await chooseScreenshotDestination() else { return }
                        try data.write(to: url, options: .atomic)
                        savedURL = url
                    } else {
                        do {
                            let url = try captureDestination("Screenshot", extension: "png")
                            try data.write(to: url, options: .atomic)
                            savedURL = url
                        } catch {
                            guard let url = await chooseScreenshotDestination() else { return }
                            try data.write(to: url, options: .atomic)
                            savedURL = url
                        }
                    }
                }
                if action != .copy, capturePreferences.copyOnCapture {
                    // Copying is an extra convenience; a clipboard failure must
                    // not turn a successfully saved capture into a save error.
                    if (try? copyImage(nsImage)) != nil { showCopyConfirmation() }
                }
                CaptureSound.screenshot.play()
                if let savedURL, capturePreferences.openFinderAfterCapture {
                    NSWorkspace.shared.activateFileViewerSelecting([savedURL])
                }
                if !recording.isActive, action != .open {
                    // With the bezel in the picture, a way to leave it out of the next ones (Capture Screen Only).
                    captureStatus.showCapture(
                        title: action == .copy ? "Screenshot copied" : "Screenshot saved",
                        image: nsImage,
                        fileURL: savedURL,
                        link: captureMode == 0 ? "Hide bezels for screenshots" : nil
                    )
                    deviceVC?.updateStatusVisibility()
                }
            } catch { NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil) }
        }
    }

    private func copyImage(_ image: NSImage) throws {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([image]) else {
            throw CaptureError.failed("Couldn’t copy the screenshot.")
        }
    }

    private func showCopyConfirmation() {
        copyConfirmation?.cancel()
        copiedScreenshot = true
        onChange()
        copyConfirmation = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            self?.copiedScreenshot = false
            self?.onChange()
        }
    }

    private func chooseScreenshotDestination() async -> URL? {
        guard let window else { return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = captureFolder
        panel.nameFieldStringValue = captureName("Screenshot") + ".png"
        return await panel.beginSheetModal(for: window) == .OK ? panel.url : nil
    }

    /// Screen Only / Canvas: which of the two a screenshot takes, not while one runs.
    func toggleCaptureScreenOnly() {
        guard !recording.isActive, !screenshotBusy else { return }
        UserDefaults.standard.set(captureMode == 0 ? 1 : 0, forKey: "captureMode")
    }

    /// Screen alone (the default) or the canvas with the bezel: which a recording takes, not while one runs.
    func toggleRecordDeviceBezel() {
        guard !recording.isActive else { return }
        capturePreferences.recordsBezel.toggle()
    }

    // MARK: - Where captures go

    var captureFolder: URL { capturePreferences.saveLocation }

    func captureDestination(_ kind: String, extension suffix: String) throws -> URL {
        try capturePreferences.captureDestination(kind, extension: suffix)
    }

    func captureName(_ kind: String, at date: Date = Date()) -> String {
        CapturePreferences.captureName(kind, at: date)
    }

    // MARK: - Recording

    private func installCaptureStatus() {
        captureStatus.isHidden = true
        captureStatus.onLink = { [weak self] in
            guard let self, captureMode == 0 else { return }
            toggleCaptureScreenOnly()
            onChange()
        }
        captureStatus.onSecondary = { [weak self] in
            guard let self else { return }
            // Resolve the file from the displayed banner. A prior recording's
            // saved state must not hijack a newer screenshot's Reveal action.
            if let url = captureStatus.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        captureStatus.onDismiss = { [weak self] in
            self?.recording.dismiss()
            self?.captureStatus.isHidden = true
            self?.deviceVC?.updateStatusVisibility()
        }
    }

    private func refreshRecording() {
        defer { deviceVC?.updateStatusVisibility() }
        onChange()
        switch recording.phase {
        case .idle: captureStatus.isHidden = true
        case .starting, .recording:
            captureStatus.isHidden = true
        case .saving:
            captureStatus.isHidden = true
        case .saved(let url):
            let thumbnail =
                recording.previewImage.map { NSImage(cgImage: $0, size: .zero) }
                ?? NSWorkspace.shared.icon(forFile: url.path)
            captureStatus.showCapture(title: "Recording saved", image: thumbnail, fileURL: url)
        }
    }

    func toggleRecording() {
        if recording.canStop {
            recording.stop()
            return
        }
        guard !recording.isActive, canStartRecording, let workspace = session()?.workspace else { return }
        let screen = workspace.deviceVC.screen
        screen.endLiveText()
        let canvas = capturePreferences.recordsBezel
        let source = workspace.canvasCapture
        let background = NSImage(named: "gradient")?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let emulator = workspace.deviceVC.emulator
        emulator.warnIfLowOnSpace()
        recording.start(
            frame: { [weak screen] in
                if canvas { return try source.frame() }
                return screen?.captureFrame()
            },
            audio: { try await emulator.startAudioCapture() },
            prepare: { [weak screen] in
                if canvas {
                    screen?.isCapturingCanvas = true
                    try await source.start()
                    return source.outputSize
                }
                return nil
            },
            cleanup: { [weak screen] in
                if canvas {
                    await source.stop()
                    screen?.isCapturingCanvas = false
                }
            },
            background: background,
            screenSize: screen.capturedScreenSize,
            destination: { [weak self] in
                guard let self else { throw CaptureError.failed("The capture window was closed.") }
                return try captureDestination("Recording", extension: "mov")
            }
        )
        window?.makeFirstResponder(screen)
    }

    func discardRecording() {
        guard recording.canStop, let window else { return }
        let recordingID = recording.id
        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.informativeText = "The recording so far is deleted."
        // Destructive, so not the default: Return does nothing, Escape cancels.
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, recording.id == recordingID, response == .alertFirstButtonReturn else { return }
            recording.stop(discard: true)
        }
    }

    /// The window may close now; otherwise it closes once the recording has saved.
    func windowShouldClose() -> Bool {
        guard recording.isActive else { return true }
        closeAfterRecording = true
        recording.stop()
        return false
    }

    /// True when quitting waits for the recording to save (then `terminate`).
    func finishRecordingBeforeQuit() -> Bool {
        guard recording.isActive else { return false }
        quitAfterRecording = true
        recording.stop()
        return true
    }

    @objc private func stopHiddenRecording() { recording.stop() }
}
