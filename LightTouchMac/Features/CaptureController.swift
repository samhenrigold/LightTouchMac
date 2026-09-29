// A device window's screenshots and screen recordings: the screenshot
// pipeline (copy, save, save as, open), the recording session with its status
// banner, reminder notifications and recovery, where captures are saved, and
// the Space-bar shortcut. The window controller owns the menus and toolbar and
// asks this for what they enable; the device (its screen and canvas capture)
// comes from the selected session.

import Cocoa
import UniformTypeIdentifiers

@MainActor class CaptureController: NSObject {
    let recording = ScreenRecordingSession()
    let captureStatus = CaptureStatusView()
    let capturePreferences: CapturePreferences
    /// The device window; screenshots and recordings put their sheets on it.
    weak var window: NSWindow?
    /// The selected device, nil when none runs.
    var session: () -> DeviceSession? = { nil }
    /// The window's device profile (the reminder names it).
    var profile: () -> DeviceProfile = { .iPodTouch2G }
    /// Capture state changed: the toolbar and menus revalidate.
    var onChange: () -> Void = {}
    /// Quit was waiting for the recording to save.
    var terminate: () -> Void = {}

    private(set) var screenshotBusy = false
    private(set) var copiedScreenshot = false
    private var copyConfirmation: Task<Void, Never>?
    private var captureKeyMonitor: Any?
    private var consumedCaptureSpace = false
    private var quitAfterRecording = false
    private var closeAfterRecording = false

    private var emulator: EmulatorController? { session()?.emulator }
    private var deviceVC: DeviceViewController? { session()?.workspace.deviceVC }
    var captureMode: Int { UserDefaults.standard.integer(forKey: "captureMode") == 1 ? 1 : 0 }

    var canTakeScreenshot: Bool {
        guard let emulator else { return false }
        return (emulator.isRunning || emulator.isPaused) && !emulator.isSleeping && !screenshotBusy
    }
    var canStartRecording: Bool {
        guard let emulator else { return false }
        return emulator.isRunning && !emulator.isSleeping && !screenshotBusy
    }
    var canToggleRecording: Bool {
        recording.phase != .saving && (recording.canStop || recording.needsRecovery || canStartRecording)
    }

    init(preferences: CapturePreferences = .shared) {
        capturePreferences = preferences
        super.init()
        installCaptureStatus()
        installCaptureKeyboardShortcuts()
        installCaptureNotifications()
        recoverUnfinishedRecordings()
        NotificationCenter.default.addObserver(self, selector: #selector(stopHiddenRecording), name: NSApplication.didHideNotification, object: nil)
        recording.onChange = { [weak self] in self?.refreshRecording() }
        recording.onBeganRecording = { CaptureSound.recordingStarted.play() }
        recording.onStoppedRecording = {
            CaptureSound.recordingStopped.play()
            CaptureNotifications.shared.cancelReminder()
        }
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
            CaptureNotifications.shared.cancelReminder()
            switch result {
            case let .saved(url):
                if capturePreferences.openFinderAfterCapture { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            case let .recovery(url):
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .discarded, .failed: break
            }
        }
        recording.onFinished = { [weak self] success in
            guard let self else { return }
            if success {
                if quitAfterRecording { terminate() }
                else if closeAfterRecording { self.window?.performClose(nil) }
            } else if recording.phase == .idle, let failure = recording.failure, let window = self.window {
                NSAlert(error: failure).beginSheetModal(for: window)
            }
            quitAfterRecording = false
            closeAfterRecording = false
        }
    }

    deinit {
        if let captureKeyMonitor { NSEvent.removeMonitor(captureKeyMonitor) }
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
        guard let image = deviceVC.screen.captureFrame() else { throw CaptureError.failed("No screen image is available.") }
        return image
    }

    private enum ScreenshotAction { case copy, save, saveAs, open }
    private func takeScreenshot(_ action: ScreenshotAction) {
        guard canTakeScreenshot, let window else { return }
        screenshotBusy = true
        onChange()
        Task { [weak self] in
            guard let self else { return }
            defer { screenshotBusy = false; onChange() }
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
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Light Touch Screenshots", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent(captureName("Screenshot") + " " + UUID().uuidString.prefix(8)).appendingPathExtension("png")
                    try data.write(to: url, options: .atomic)
                    if let application = capturePreferences.openInApplicationURL {
                        _ = try await NSWorkspace.shared.open([url], withApplicationAt: application, configuration: .init())
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
                    captureStatus.showCapture(title: action == .copy ? "Screenshot copied" : "Screenshot saved",
                                              image: nsImage, fileURL: savedURL)
                    deviceVC?.updateStatusVisibility()
                }
            } catch { NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil) }
        }
    }

    private func copyImage(_ image: NSImage) throws {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([image]) else { throw CaptureError.failed("Couldn’t copy the screenshot.") }
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

    /// Screen Only / Canvas: which of the two a capture takes, not while one runs.
    func toggleCaptureScreenOnly() {
        guard !recording.isActive, !screenshotBusy else { return }
        UserDefaults.standard.set(captureMode == 0 ? 1 : 0, forKey: "captureMode")
    }

    // MARK: - Where captures go

    var captureFolder: URL { capturePreferences.saveLocation }

    func captureDestination(_ kind: String, extension suffix: String) throws -> URL {
        let folder = captureFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(captureName(kind) + " " + UUID().uuidString.prefix(8))
            .appendingPathExtension(suffix)
    }

    func captureName(_ kind: String) -> String {
        let date = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        return "Light Touch \(kind) \(date)"
    }

    // MARK: - Space bar

    private func installCaptureKeyboardShortcuts() {
        captureKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 49, event.type == .keyUp, consumedCaptureSpace {
                consumedCaptureSpace = false
                return nil
            }
            if event.keyCode == 49, event.type == .keyDown {
                if event.isARepeat, consumedCaptureSpace { return nil }
                if !event.isARepeat { consumedCaptureSpace = false }
            }
            guard event.type == .keyDown, event.keyCode == 49,
                  let window, event.window === window, window.isKeyWindow,
                  window.attachedSheet == nil, NSApp.modalWindow == nil,
                  let screen = deviceVC?.screen, window.firstResponder === screen,
                  !screen.isShowingLiveText,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  capturePreferences.spaceBarAction != .none else { return event }
            guard !event.isARepeat else { return consumedCaptureSpace ? nil : event }
            consumedCaptureSpace = true
            switch capturePreferences.spaceBarAction {
            case .none: return event
            case .copyScreenshot: copyScreen()
            case .saveScreenshot: saveScreenshot()
            case .saveScreenshotAs: saveScreenshotAs()
            case .toggleRecording: toggleRecording()
            }
            return nil
        }
    }

    // MARK: - Recording

    private func installCaptureNotifications() {
        CaptureNotifications.shared.onRecordingAction = { [weak self] id, action in
            guard let self, recording.id == id, recording.canStop else { return }
            switch action {
            case .stopAndSave: recording.stop()
            case .stopAndDelete: recording.stop(discard: true)
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(recordingAppDidResignActive), name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(recordingAppDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @objc func recordingAppDidResignActive() {
        guard recording.canStop else { return }
        let id = recording.id
        let seconds = capturePreferences.reminderAfterDuration
        Task { [weak self] in
            guard let self, recording.id == id, recording.canStop, !NSApp.isActive else { return }
            await CaptureNotifications.shared.scheduleReminder(after: TimeInterval(seconds), recordingID: id, profile: profile())
        }
    }

    @objc func recordingAppDidBecomeActive() { CaptureNotifications.shared.cancelReminder() }

    private func recoverUnfinishedRecordings() {
        let cutoff = Date()
        Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await ScreenRecordingSession.recoverRecordings(createdBefore: cutoff) { _ in
                    try self.captureDestination("Recording", extension: "mov")
                }
                for url in report.saved {
                    if capturePreferences.notifyOnRecordingRecovery,
                       await CaptureNotifications.shared.notifyRecoveredRecording(url) { continue }
                    if capturePreferences.openFinderAfterCapture || capturePreferences.notifyOnRecordingRecovery {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                for url in report.deleted { logEvent("recording recovery: deleted \(url.lastPathComponent): it can't be played") }
                if !report.remaining.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(report.remaining) }
            } catch { logEvent("recording recovery: \(error.localizedDescription)") }
        }
    }

    private func installCaptureStatus() {
        captureStatus.isHidden = true
        captureStatus.onPrimary = { [weak self] in self?.saveRecordingAs() }
        captureStatus.onSecondary = { [weak self] in
            guard let self else { return }
            // Resolve the file from the displayed banner. A prior recording's
            // saved state must not hijack a newer screenshot's Reveal action.
            if let url = captureStatus.fileURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else if case let .recovery(url) = recording.phase {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        captureStatus.onDismiss = { [weak self] in self?.recording.dismiss(); self?.captureStatus.isHidden = true; self?.deviceVC?.updateStatusVisibility() }
    }

    private func refreshRecording() {
        defer { deviceVC?.updateStatusVisibility() }
        if !recording.canStop { CaptureNotifications.shared.cancelReminder() }
        onChange()
        switch recording.phase {
        case .idle: captureStatus.isHidden = true
        case .starting, .recording:
            captureStatus.isHidden = true
        case .saving:
            captureStatus.isHidden = true
        case let .saved(url):
            let thumbnail = recording.previewImage.map { NSImage(cgImage: $0, size: .zero) }
                ?? NSWorkspace.shared.icon(forFile: url.path)
            captureStatus.showCapture(title: "Recording saved", image: thumbnail, fileURL: url)
        case .recovery:
            captureStatus.update(title: "Recording needs attention", detail: recording.failure?.localizedDescription ?? "Save to another folder.",
                                 primary: "Save As…", secondary: "Show in Finder", dismissible: true, appearance: .warning)
        }
    }

    func toggleRecording() {
        if recording.canStop { recording.stop(); return }
        if case .recovery = recording.phase { saveRecordingAs(); return }
        guard !recording.isActive, canStartRecording, let workspace = session()?.workspace else { return }
        let screen = workspace.deviceVC.screen
        screen.endLiveText()
        let canvas = captureMode == 0
        let source = workspace.canvasCapture
        let background = NSImage(named: "gradient")?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let emulator = workspace.deviceVC.emulator
        emulator.warnIfLowOnSpace()
        recording.start(frame: { [weak screen] in
            if canvas { return try source.frame() }
            return screen?.captureFrame()
        }, audio: { try await emulator.startAudioCapture() }, prepare: { [weak screen] in
            if canvas {
                screen?.isCapturingCanvas = true
                try await source.start(); return source.outputSize
            }
            return nil
        }, cleanup: { [weak screen] in
            if canvas {
                await source.stop()
                screen?.isCapturingCanvas = false
            }
        }, background: background,
        destination: { [weak self] in
            guard let self else { throw CaptureError.failed("The capture window was closed.") }
            return try captureDestination("Recording", extension: "mov")
        })
        window?.makeFirstResponder(screen)
    }

    func discardRecording() {
        guard recording.canStop, let window else { return }
        let recordingID = recording.id
        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Stop and Save")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[2].keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, recording.id == recordingID else { return }
            if response == .alertFirstButtonReturn { recording.stop(discard: true) }
            else if response == .alertSecondButtonReturn { recording.stop() }
        }
    }

    private func saveRecordingAs() {
        guard let window, case let .recovery(source) = recording.phase else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = captureName("Recording") + ".mov"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, self?.recording.phase == .recovery(source) else { return }
            self?.recording.retrySave(to: url)
        }
    }

    func showRecordingRecovery() {
        do {
            try FileManager.default.createDirectory(at: ScreenRecordingSession.recoveryDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(ScreenRecordingSession.recoveryDirectory)
        } catch { if let window { NSAlert(error: error).beginSheetModal(for: window) } }
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
