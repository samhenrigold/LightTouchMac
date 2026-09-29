import Cocoa

/// Capture choices are shared by the toolbar, menus, and focused options panel.
/// The existing folder key is retained so upgrading never moves a user's saves.
struct CapturePreferences {
    static let shared = CapturePreferences()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var saveLocation: URL {
        get {
            guard let path = defaults.string(forKey: "captureFolder"), !path.isEmpty else {
                return Self.desktopDirectory
            }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        nonmutating set {
            guard newValue.isFileURL else { return }
            let url = URL(fileURLWithPath: newValue.standardizedFileURL.path, isDirectory: true)
            defaults.set(url.path, forKey: "captureFolder")
            guard url != Self.desktopDirectory else { return }
            var recent = defaults.stringArray(forKey: "captureRecentFolders") ?? []
            recent.removeAll { URL(fileURLWithPath: $0).standardizedFileURL.path == url.path }
            recent.insert(url.path, at: 0)
            defaults.set(Array(recent.prefix(3)), forKey: "captureRecentFolders")
        }
    }

    var saveLocations: [URL] {
        var locations = [Self.desktopDirectory]
        for url in [saveLocation] + (defaults.stringArray(forKey: "captureRecentFolders") ?? [])
            .map({ URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }) {
            if !locations.contains(url) { locations.append(url) }
        }
        return locations
    }

    static var desktopDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].standardizedFileURL
    }

    var openInApplicationURL: URL? {
        get {
            if let path = defaults.string(forKey: "openInApplicationPath"), !path.isEmpty {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                if Self.isApplication(url) { return url }
            }
            return Self.previewApplicationURL
        }
        nonmutating set {
            guard let newValue else { defaults.removeObject(forKey: "openInApplicationPath"); return }
            guard Self.isApplication(newValue) else { return }
            defaults.set(newValue.standardizedFileURL.path, forKey: "openInApplicationPath")
        }
    }

    var openInApplicationName: String {
        openInApplicationURL.map(Self.applicationName) ?? "Preview"
    }

    static var previewApplicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview")
    }

    static func isApplication(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let bundle = Bundle(url: url), bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL"
        else { return false }
        return true
    }

    static func applicationName(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    var copyOnCapture: Bool {
        get { bool("copyOnCapture", default: false) }
        nonmutating set { defaults.set(newValue, forKey: "copyOnCapture") }
    }
    var openFinderAfterCapture: Bool {
        get { bool("openFinderAfterCapture", default: true) }
        nonmutating set { defaults.set(newValue, forKey: "openFinderAfterCapture") }
    }
    var soundEffectsEnabled: Bool {
        get { bool("soundEffectsEnabled", default: true) }
        nonmutating set { defaults.set(newValue, forKey: "soundEffectsEnabled") }
    }
    var notifyOnRecordingRecovery: Bool {
        get { bool("notifyOnRecordingRecovery", default: false) }
        nonmutating set { defaults.set(newValue, forKey: "notifyOnRecordingRecovery") }
    }
    var reminderAfterDuration: Int {
        get { CaptureReminderDuration(rawValue: defaults.integer(forKey: "reminderAfterDuration"))?.rawValue ?? 0 }
        nonmutating set {
            defaults.set(CaptureReminderDuration(rawValue: newValue)?.rawValue ?? 0, forKey: "reminderAfterDuration")
        }
    }
    var spaceBarAction: CaptureSpaceBarAction {
        get { CaptureSpaceBarAction(rawValue: defaults.integer(forKey: "spaceBarAction")) ?? .none }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "spaceBarAction") }
    }

    private func bool(_ key: String, default fallback: Bool) -> Bool {
        (defaults.object(forKey: key) as? NSNumber)?.boolValue ?? fallback
    }
}

enum CaptureSpaceBarAction: Int, CaseIterable {
    case none = 0, copyScreenshot = 2, saveScreenshot = 3, saveScreenshotAs = 4, toggleRecording = 5
    func title(for profile: DeviceProfile) -> String {
        switch self {
        case .none: "Send to \(profile.shortName)"
        case .copyScreenshot: "Copy Screenshot"
        case .saveScreenshot: "Save Screenshot"
        case .saveScreenshotAs: "Save Screenshot As…"
        case .toggleRecording: "Start/Stop Recording"
        }
    }
}

enum CaptureReminderDuration: Int, CaseIterable {
    case never = 0
    #if DEBUG
    case tenSeconds = 10
    #endif
    case oneMinute = 60, fiveMinutes = 300, tenMinutes = 600, thirtyMinutes = 1800, oneHour = 3600
    var title: String {
        if self == .never { return "Never" }
        return Duration.seconds(rawValue).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}
