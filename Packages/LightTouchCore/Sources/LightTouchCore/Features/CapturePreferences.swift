import CoreServices
import Foundation
import HostRuntime

/// Capture choices are shared by the toolbar, menus, and focused options panel.
/// The existing folder key is retained so upgrading never moves a user's saves.
public struct CapturePreferences {
    public static let shared = CapturePreferences()
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var saveLocation: URL {
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

    public var saveLocations: [URL] {
        var locations = [Self.desktopDirectory]
        for url in [saveLocation]
            + (defaults.stringArray(forKey: "captureRecentFolders") ?? [])
            .map({ URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }) where !locations.contains(url)
        {
            locations.append(url)
        }
        return locations
    }

    public static var desktopDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].standardizedFileURL
    }

    public var openInApplicationURL: URL? {
        get {
            if let path = defaults.string(forKey: "openInApplicationPath"), !path.isEmpty {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                if Self.isApplication(url) { return url }
            }
            return Self.previewApplicationURL
        }
        nonmutating set {
            guard let newValue else {
                defaults.removeObject(forKey: "openInApplicationPath")
                return
            }
            guard Self.isApplication(newValue) else { return }
            defaults.set(newValue.standardizedFileURL.path, forKey: "openInApplicationPath")
        }
    }

    public var openInApplicationName: String {
        openInApplicationURL.map(Self.applicationName) ?? "Preview"
    }

    /// Preview's place, asked of Launch Services once (it is a system app and doesn't move).
    public static var previewApplicationURL: URL? {
        if let previewURL { return previewURL }
        previewURL =
            (LSCopyApplicationURLsForBundleIdentifier("com.apple.Preview" as CFString, nil)?.takeRetainedValue()
            as? [URL])?.first
        return previewURL
    }
    private static var previewURL: URL?
    /// Each app's display name by path. The toolbar's Open Screenshot tooltip names the app, and toolbar validation
    /// runs after every event: looking the name up there cost ~110 µs a time (issue 107).
    private static var names: [String: String] = [:]
    /// Display names looked up rather than remembered.
    static private(set) var nameLookups = 0

    public static func isApplication(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
            let bundle = Bundle(url: url),
            bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL"
        else { return false }
        return true
    }

    public static func applicationName(_ url: URL) -> String {
        if let name = names[url.path] { return name }
        nameLookups += 1
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        names[url.path] = name
        return name
    }

    public var copyOnCapture: Bool {
        get { bool("copyOnCapture", default: false) }
        nonmutating set { defaults.set(newValue, forKey: "copyOnCapture") }
    }
    /// Screenshots and recordings show the bezel (the canvas) instead of the screen alone (Capture ▸ Include Device
    /// Bezel). The screenshots' earlier key, captureMode (1 was Capture Screen Only), so a choice made there carries
    /// over; recordings' own recordDeviceBezel is no longer read.
    public var includesBezel: Bool {
        get { defaults.integer(forKey: "captureMode") != 1 }
        nonmutating set { defaults.set(newValue ? 0 : 1, forKey: "captureMode") }
    }
    public var openFinderAfterCapture: Bool {
        get { bool("openFinderAfterCapture", default: true) }
        nonmutating set { defaults.set(newValue, forKey: "openFinderAfterCapture") }
    }
    public var soundEffectsEnabled: Bool {
        get { bool("soundEffectsEnabled", default: true) }
        nonmutating set { defaults.set(newValue, forKey: "soundEffectsEnabled") }
    }

    /// A new capture's file in the save location (created if need be): named for now, " 2" and on when that's taken.
    public func captureDestination(_ kind: String, extension suffix: String, at date: Date = Date()) throws -> URL {
        let folder = saveLocation
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(Self.captureName(kind, at: date)).appendingPathExtension(suffix).unused
    }

    /// "Light Touch Screenshot 2026-10-07 at 17.22.14", in the Mac's time zone (as macOS names its own).
    public static func captureName(_ kind: String, at date: Date = Date()) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Light Touch \(kind) \(format.string(from: date))"
    }

    private func bool(_ key: String, default fallback: Bool) -> Bool {
        (defaults.object(forKey: key) as? NSNumber)?.boolValue ?? fallback
    }
}
