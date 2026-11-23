import Foundation

public nonisolated struct InstalledApp: Identifiable, Codable, Sendable {
    /// The `CFBundleIdentifier`
    public let id: String
    public let name: String
    public let version: String
    public init(id: String, name: String, version: String) {
        self.id = id
        self.name = name
        self.version = version
    }
}

public nonisolated struct DeviceFile: Codable, Sendable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let isRegular: Bool
    public let size: UInt64
    public init(name: String, path: String, isDirectory: Bool, isRegular: Bool, size: UInt64) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isRegular = isRegular
        self.size = size
    }
}

/// A name the device supplies (a file's, an app's), as the Mac shows and saves it: control characters, line breaks
/// and Unicode's bidirectional controls, which can make a name read with another extension than its own, are written
/// as visible [U+XXXX] escapes. Any other name is unchanged.
public nonisolated enum DeviceName {
    static let bidiControls = Set<UInt32>([0x061C, 0x200E, 0x200F, 0x2028, 0x2029])
        .union(0x202A...0x202E).union(0x2066...0x2069)

    public static func visible(_ name: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if scalar.properties.generalCategory == .control || bidiControls.contains(scalar.value) {
                out.append(contentsOf: String(format: "[U+%04X]", scalar.value).unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }
}

/// A host worker can never select another device after it starts. The session
/// distinguishes reused ports and prevents completions crossing a cold boot.
public nonisolated struct HostServiceEndpoint: Hashable, Codable, Sendable {
    public let socket: String
    public let udid: String?
    public let session: UUID
    public init(socket: String, udid: String?, session: UUID) {
        self.socket = socket
        self.udid = udid
        self.session = session
    }
}

public nonisolated enum HostServiceOperation: Codable, Sendable {
    case attachment, apps, archives, freeSpace, installReady, homeOrder, orientation
    /// `domain`: nil for lockdownd's own keys, else one such as "com.apple.mobile.iTunes".
    case lockdownValue(String, domain: String? = nil)
    case uninstall(String)
    case install(ipa: String, staged: String, bundleID: String)
    /// `replace`: publish over an existing file at `remote` (as `reuse` does, through a private name and a rename).
    case upload(source: String, remote: String, reuse: Bool, replace: Bool, allowEmpty: Bool, root: AFCRoot)
    case sweep
    /// iPhone OS 1.x: `source` written to `remote` (of the Media folder) inside an iTunes sync's notifications and lock.
    case syncLibraryFile(source: String, remote: String)
    case remove(String)
    case files(String, root: AFCRoot)
    case download(DeviceFile, destination: String, root: AFCRoot)
    /// The Files browser's edits: a file or a folder with everything in it, a rename within its folder, a new folder.
    case delete(String, root: AFCRoot)
    case rename(String, to: String, root: AFCRoot)
    case makeFolder(String, root: AFCRoot)
    case move(bundle: String, before: String?, deviceName: String)
    case observe
    /// copyTo: a folder the reports CrashReportCopyAgent sends (before 3.0) are also written into.
    case crashReports(copyTo: String?)
}

/// Which AFC a Files request goes through.
public nonisolated enum AFCRoot: Hashable, Codable, Sendable {
    /// com.apple.afc: the media folder.
    case media
    /// com.apple.afc2: a jailbroken device's whole file system (DeviceServices.wholeFileSystem).
    case fileSystem
    /// com.apple.mobile.house_arrest's VendContainer: the app's whole container (its .app, Documents, Library, tmp).
    /// Every iOS the emulator runs, 2.0 to 7.1.2, vends it for any installed app (DeviceServices.app).
    case app(String)
}

public nonisolated enum HostServiceValue: Codable, Sendable {
    case none
    case boolean(Bool)
    case integer(Int64)
    case string(String?)
    case strings([String])
    case apps([InstalledApp])
    case files([DeviceFile])
    /// Paths and a number of seconds each: the crash reports' ages.
    case ages([String: Double])
}

public nonisolated enum HostServiceProgress: Codable, Sendable {
    case fraction(Double)
    case install(Int, String)
    case notification
}
