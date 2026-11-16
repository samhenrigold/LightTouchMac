import Foundation
import HostRuntime
import Testing
import UserNotifications

@testable import LightTouchCore

/// Capture preferences: defaults written nowhere until chosen, the save location and its three recent folders, the
/// "Open in" app with its fallback, and the device-ready notification's identity payload.
struct CapturePreferencesTests {
    func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let domain = "ltm-capture-preferences-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try body(defaults)
    }

    @Test func defaultsAreImplicit() throws {
        try withDefaults { defaults in
            let preferences = CapturePreferences(defaults: defaults)
            #expect(preferences.saveLocation == CapturePreferences.desktopDirectory)
            #expect(preferences.openFinderAfterCapture && preferences.soundEffectsEnabled)
            #expect(!preferences.copyOnCapture)
            #expect(preferences.includesBezel, "captures include the bezel by default")
            _ = preferences.saveLocations
            _ = preferences.openInApplicationURL
            #expect(
                defaults.dictionaryRepresentation().keys.filter {
                    $0.hasPrefix("capture")
                        || [
                            "copyOnCapture",
                            "openFinderAfterCapture", "soundEffectsEnabled",
                            "openInApplicationPath"
                        ].contains($0)
                }.isEmpty,
                "reading writes nothing"
            )
            // One choice for screenshots and recordings, in the screenshots' earlier key: an existing user's
            // Capture Screen Only (captureMode 1) carries over, and recordings' own key is no longer read.
            defaults.set(1, forKey: "captureMode")
            defaults.set(true, forKey: "recordDeviceBezel")
            #expect(!preferences.includesBezel)
            preferences.includesBezel = true
            #expect(preferences.includesBezel && defaults.integer(forKey: "captureMode") == 0)
            preferences.includesBezel = false
            #expect(!preferences.includesBezel && defaults.integer(forKey: "captureMode") == 1)
        }
    }

    @Test func saveLocationAndRecentFolders() throws {
        try withDefaults { defaults in
            let preferences = CapturePreferences(defaults: defaults)
            let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
                "Capture options " + UUID().uuidString
            )
            let oldFolder = base.appendingPathComponent("Existing save location")
            // an earlier build's key: upgrading never moves saves
            defaults.set(oldFolder.path, forKey: "captureFolder")
            #expect(preferences.saveLocation.path == oldFolder.standardizedFileURL.path)
            #expect(preferences.saveLocations.contains { $0.path == oldFolder.standardizedFileURL.path })
            for name in ["One", "Two", "Three", "Four", "Two"] {
                preferences.saveLocation = base.appendingPathComponent(name)
            }
            #expect(defaults.stringArray(forKey: "captureRecentFolders")?.count == 3)
            #expect(preferences.saveLocations.dropFirst().map(\.lastPathComponent) == ["Two", "Four", "Three"])
            preferences.saveLocation = CapturePreferences.desktopDirectory
            #expect(preferences.saveLocations.count == 4, "the Desktop is always first, never a recent")
            preferences.saveLocation = URL(string: "https://example.com/folder")!
            #expect(preferences.saveLocation == CapturePreferences.desktopDirectory, "only file URLs")
        }
    }

    @Test func openInApplicationFallsBackToPreview() throws {
        try withDefaults { defaults in
            try withTemporaryDirectory { base in
                let preferences = CapturePreferences(defaults: defaults)
                defaults.set("/no-longer-installed/Image.app", forKey: "openInApplicationPath")
                #expect(preferences.openInApplicationURL == CapturePreferences.previewApplicationURL)
                #expect(CapturePreferences.previewApplicationURL?.lastPathComponent == "Preview.app")
                let app = base.appendingPathComponent("Image Editor.app")
                try FileManager.default.createDirectory(
                    at: app.appendingPathComponent("Contents"),
                    withIntermediateDirectories: true
                )
                let info: [String: Any] = [
                    "CFBundlePackageType": "APPL", "CFBundleIdentifier": "test.capture.editor.\(UUID().uuidString)",
                    "CFBundleName": "Image Editor"
                ]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
                    to: app.appendingPathComponent("Contents/Info.plist")
                )
                preferences.openInApplicationURL = app
                #expect(preferences.openInApplicationURL?.path == app.path)
                #expect(preferences.openInApplicationName == "Image Editor")
                // The toolbar asks after every event (issue 107): the name is looked up once per app.
                let lookups = CapturePreferences.nameLookups
                for _ in 0..<100 { _ = preferences.openInApplicationName }
                #expect(CapturePreferences.nameLookups == lookups, "the name was looked up again")
                preferences.openInApplicationURL = base
                #expect(
                    preferences.openInApplicationURL?.path == app.path,
                    "an invalid app must not replace an explicit choice"
                )
                try FileManager.default.removeItem(at: app)
                #expect(
                    preferences.openInApplicationURL == CapturePreferences.previewApplicationURL,
                    "a deleted app must not remain selected through Bundle's metadata cache"
                )
            }
        }
    }

    @Test func choicesPersist() throws {
        try withDefaults { defaults in
            let preferences = CapturePreferences(defaults: defaults)
            preferences.copyOnCapture = true
            preferences.openFinderAfterCapture = false
            preferences.soundEffectsEnabled = false
            let restored = CapturePreferences(defaults: defaults)
            #expect(restored.copyOnCapture && !restored.openFinderAfterCapture && !restored.soundEffectsEnabled)
        }
    }

    @Test func notificationPayloadsCarryTheirIdentity() {
        let ready = CaptureNotificationContent.ready("iPod touch (2nd generation) iOS 3.1.3", entryID: "n72ap-7E18")
        #expect(
            ready.title == "iPod touch (2nd generation) iOS 3.1.3 is ready to use"
                && ready.userInfo["entry"] as? String == "n72ap-7E18"
        )
        #expect(ready.categoryIdentifier == CaptureNotificationContent.readyCategory)
    }
}
