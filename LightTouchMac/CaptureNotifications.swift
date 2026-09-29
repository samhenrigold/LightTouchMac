import Cocoa
import UserNotifications

/// Optional capture feedback. Merely creating the service never prompts for access.
@MainActor
final class CaptureNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CaptureNotifications()
    enum RecordingAction { case stopAndSave, stopAndDelete }
    var onRecordingAction: ((UUID, RecordingAction) -> Void)?

    private let center: UNUserNotificationCenter
    private var reminderRevision = 0
    private var reminderIdentifier: String?
    private nonisolated static let recoveryCategory = "CAPTURE_RECORDING_RECOVERED"
    private nonisolated static let reminderCategory = "CAPTURE_STILL_RECORDING"
    private nonisolated static let revealAction = "SHOW_CAPTURE_IN_FINDER"
    private nonisolated static let stopSaveAction = "STOP_SAVE_CAPTURE"
    private nonisolated static let stopDeleteAction = "STOP_DELETE_CAPTURE"

    private override init() {
        center = .current()
        super.init()
        center.delegate = self
        let reveal = UNNotificationAction(identifier: Self.revealAction, title: "Show in Finder")
        let save = UNNotificationAction(identifier: Self.stopSaveAction, title: "Stop and Save", options: .foreground)
        let delete = UNNotificationAction(identifier: Self.stopDeleteAction, title: "Stop and Delete", options: [.destructive, .foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.recoveryCategory, actions: [reveal], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.reminderCategory, actions: [save, delete], intentIdentifiers: []),
        ])
    }

    /// Call only after an explicit opt-in in Capture Options.
    func requestAuthorization() async -> Bool {
        do { return try await center.requestAuthorization(options: [.alert]) }
        catch { return false }
    }

    /// Returns false when notification delivery is unavailable, allowing Finder feedback.
    func notifyRecoveredRecording(_ file: URL) async -> Bool {
        let settings = await center.notificationSettings()
        guard Self.canPresent(settings), FileManager.default.fileExists(atPath: file.path) else { return false }
        do {
            let bookmark = try file.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            let request = UNNotificationRequest(identifier: "recovered-recording-\(UUID().uuidString)",
                                                content: Self.recoveryContent(filename: file.lastPathComponent, bookmark: bookmark),
                                                trigger: nil)
            try await center.add(request)
            return true
        } catch { return false }
    }

    func scheduleReminder(after seconds: TimeInterval, recordingID: UUID, profile: DeviceProfile) async {
        cancelReminder()
        guard seconds > 0, !NSApp.isActive else { return }
        let revision = reminderRevision
        let settings = await center.notificationSettings()
        guard revision == reminderRevision, !NSApp.isActive, Self.canPresent(settings) else { return }
        let identifier = "recording-reminder-\(UUID().uuidString)"
        reminderIdentifier = identifier
        let request = UNNotificationRequest(identifier: identifier, content: Self.reminderContent(recordingID: recordingID, profile: profile),
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false))
        do {
            try await center.add(request)
            if revision != reminderRevision {
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
            }
        } catch {
            if reminderIdentifier == identifier { reminderIdentifier = nil }
        }
    }

    func cancelReminder() {
        reminderRevision += 1
        guard let identifier = reminderIdentifier else { return }
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        reminderIdentifier = nil
    }

    private static func canPresent(_ settings: UNNotificationSettings) -> Bool {
        (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
            && ((settings.alertSetting == .enabled && settings.alertStyle != .none)
                || settings.notificationCenterSetting == .enabled)
    }

    static func recoveryContent(filename: String, bookmark: Data) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Recording recovered"
        content.body = filename
        content.categoryIdentifier = recoveryCategory
        content.userInfo = ["recordingBookmark": bookmark]
        return content
    }

    static func reminderContent(recordingID: UUID, profile: DeviceProfile) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "\(profile.shortName) is still recording"
        content.categoryIdentifier = reminderCategory
        content.userInfo = ["recordingID": recordingID.uuidString]
        return content
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.content.categoryIdentifier == Self.recoveryCategory ? [.banner, .list] : [])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        let action = response.actionIdentifier
        if content.categoryIdentifier == Self.recoveryCategory,
           action == Self.revealAction || action == UNNotificationDefaultActionIdentifier,
           let bookmark = content.userInfo["recordingBookmark"] as? Data {
            await revealRecoveredRecording(bookmark)
        } else if content.categoryIdentifier == Self.reminderCategory,
                  let rawID = content.userInfo["recordingID"] as? String, let id = UUID(uuidString: rawID) {
            if action == Self.stopSaveAction { await recordingAction(id, action: .stopAndSave) }
            else if action == Self.stopDeleteAction { await recordingAction(id, action: .stopAndDelete) }
        }
    }

    private func recordingAction(_ id: UUID, action: RecordingAction) { onRecordingAction?(id, action) }

    private func revealRecoveredRecording(_ bookmark: Data) {
        do {
            var stale = false
            let file = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
            guard try file.checkResourceIsReachable() else { throw CocoaError(.fileReadNoSuchFile) }
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } catch {
            let alert = NSAlert()
            alert.messageText = "Recording not found"
            alert.informativeText = "The recording may have been moved or deleted."
            alert.addButton(withTitle: "OK")
            if let window = NSApp.mainWindow { alert.beginSheetModal(for: window) }
            else { alert.runModal() }
        }
    }
}
