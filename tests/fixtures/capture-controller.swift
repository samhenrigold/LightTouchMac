// Stand-ins for what Features/CaptureController.swift reaches outside itself, for the offline checks that compile
// it whole (check-capture-destination, check-capture-shortcuts): a scripted recording that records its stops, the
// banner, the reminder notifications, and a selected device whose screen captures nothing. Compiled with the real
// CapturePreferences, CaptureSound and DeviceProfile.

import Cocoa

nonisolated func logEvent(_ message: String) {}
enum CaptureError: Error { case failed(String) }

@MainActor final class ScreenRecordingSession {
    enum Phase: Equatable { case idle, starting, recording, saving, saved(URL), recovery(URL) }
    enum Completion: Equatable { case saved(URL), discarded, recovery(URL), failed }
    struct RecoveryReport { var saved: [URL] = [], deleted: [URL] = [], remaining: [URL] = [] }
    static let recoveryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-recovery-fixture")
    static func recoverRecordings(createdBefore cutoff: Date, destination: (URL) throws -> URL) async throws -> RecoveryReport { .init() }

    var phase = Phase.idle, failure: Error?, previewImage: CGImage?
    var id = UUID(), canStop = true
    var isActive: Bool { canStop }
    var needsRecovery: Bool { if case .recovery = phase { true } else { false } }
    var onChange: (() -> Void)?, onFinished: ((Bool) -> Void)?, onCompleted: ((Completion) -> Void)?
    var chooseSaveDestination: ((Error) async -> URL?)?
    var onBeganRecording: (() -> Void)?, onStoppedRecording: (() -> Void)?
    /// Every stop, true when it discards.
    var stops: [Bool] = []
    func stop(discard: Bool = false) { stops.append(discard); canStop = false }
    func reset() { id = UUID(); canStop = true; stops = [] }
    func start(frame: @escaping () throws -> CGImage?, audio: @escaping () async throws -> Void, prepare: @escaping () async throws -> CGSize?,
               cleanup: @escaping () async -> Void, background: CGImage?, destination: @escaping () throws -> URL) {}
    func dismiss() {}
    func retrySave(to url: URL) {}
}

@MainActor final class CaptureStatusView: NSView {
    enum Appearance { case warning }
    var fileURL: URL?
    var onPrimary: (() -> Void)?, onSecondary: (() -> Void)?, onDismiss: (() -> Void)?
    func showCapture(title: String, image: NSImage, fileURL: URL?) { self.fileURL = fileURL }
    func update(title: String, detail: String, primary: String?, secondary: String?, dismissible: Bool, appearance: Appearance) {}
}

@MainActor final class CaptureNotifications {
    static let shared = CaptureNotifications()
    enum RecordingAction { case stopAndSave, stopAndDelete }
    var onRecordingAction: ((UUID, RecordingAction) -> Void)?
    var reminders: [(TimeInterval, UUID)] = [], cancellations = 0
    func scheduleReminder(after delay: TimeInterval, recordingID: UUID, profile: DeviceProfile) async { reminders.append((delay, recordingID)) }
    func cancelReminder() { cancellations += 1 }
    func notifyRecoveredRecording(_ url: URL) async -> Bool { false }
}

/// The selected device: running, with a screen that is the window's first responder when the check says so.
@MainActor final class TestScreen: NSView {
    var isShowingLiveText = false, isCapturingCanvas = false
    override var acceptsFirstResponder: Bool { true }
    func endLiveText() {}
    func captureFrame() -> CGImage? { nil }
}
@MainActor final class EmulatorController {
    var isRunning = true, isPaused = false, isSleeping = false
    func warnIfLowOnSpace() {}
    func startAudioCapture() async throws {}
}
@MainActor final class CanvasCapture {
    var outputSize: CGSize? { nil }
    func screenshot() async throws -> CGImage { throw CaptureError.failed("no canvas in the fixture") }
    func frame() throws -> CGImage? { nil }
    func start() async throws {}
    func stop() async {}
}
@MainActor final class DeviceViewController {
    let screen = TestScreen()
    let emulator: EmulatorController
    init(emulator: EmulatorController) { self.emulator = emulator }
    func updateStatusVisibility() {}
}
@MainActor final class DeviceWorkspace {
    let deviceVC: DeviceViewController
    let canvasCapture = CanvasCapture()
    init(emulator: EmulatorController) { deviceVC = DeviceViewController(emulator: emulator) }
}
@MainActor final class DeviceSession {
    let emulator = EmulatorController()
    lazy var workspace = DeviceWorkspace(emulator: emulator)
}
