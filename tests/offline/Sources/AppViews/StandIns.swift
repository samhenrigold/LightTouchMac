import Foundation
import HostRuntime
import HostServiceWire
// What the views here reach into and the fixture leaves out: the session host's notification (Settings ▸ Storage);
// the device hub, as the Carrier panel's window controller names it (the panel itself talks only to CarrierBackend);
// and the Files browser's device side, a fake DeviceServices (in place of HostServiceClient's) whose listings answer
// late, which records uploads and writes downloads.
import LightTouchCore

/// Settings ▸ Storage listens for the sessions changing; Settings ▸ General keeps the vibration sound's and the reports' switches.
enum DeviceSessionHost { static let didChangeNotification = Notification.Name("DeviceSessionHostDidChange") }
enum VibrationSound { static let key = "PlayVibrationSound" }
enum Analytics { static let key = "shareUsageReports" }

final class EmulatorController {
    struct Instance { let name = "iPhone" }
    let instance = Instance()
    var carrierSettings = CarrierSettings()
    func setCarrierSettings(_ settings: CarrierSettings) -> Bool { true }
    func modem(_ property: String, _ value: String, done: @escaping @MainActor (Bool) -> Void) {}
    func modemStatus(_ done: @escaping @MainActor (ModemStatus?) -> Void) {}
}

struct DeviceFile: Sendable {
    let name, path: String
    let isDirectory, isRegular: Bool
    let size: UInt64
}

/// Listings handed back; the reply's consumer runs in the same main-actor job, so once the count moves the reply
/// was taken or dropped.
nonisolated(unsafe) var replies = 0
nonisolated(unsafe) var uploads: [(String, String)] = []
nonisolated(unsafe) var edits: [String] = []

struct DeviceServices: Sendable {
    var wholeFileSystem = false
    var app: String?
    /// The listing names the root it came from: an app's lists its own folder.
    func files(in path: String) async throws -> [DeviceFile] {
        try? await Task.sleep(for: .milliseconds(30))  // deliberately delivered after a cancellation
        defer { replies += 1 }
        return path.isEmpty
            ? [DeviceFile(name: app ?? "Folder", path: app ?? "Folder", isDirectory: true, isRegular: false, size: 0)]
            : [
                DeviceFile(name: "file.bin", path: "\(path)/file.bin", isDirectory: false, isRegular: true, size: 10),
                DeviceFile(name: "note.txt", path: "\(path)/note.txt", isDirectory: false, isRegular: true, size: 5)
            ]
    }
    func installedApps() async throws -> [InstalledApp] {
        [InstalledApp(id: "com.example.Game", name: "Game", version: "1.0")]
    }
    func freeSpaceBytes() async throws -> Int64 { 2_500_000_000 }
    func uploadFile(
        _ source: URL,
        into path: String,
        replacing: Bool = false,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        uploads.append((source.lastPathComponent, path))
    }
    func download(_ file: DeviceFile, to path: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try Data(("device:" + file.path).utf8).write(to: path)
    }
    func delete(_ path: String) async throws { edits.append("delete \(path) in \(app ?? "device")") }
    func rename(_ path: String, to name: String) async throws { edits.append("rename \(path) to \(name)") }
    func makeFolder(_ path: String) async throws { edits.append("folder \(path)") }
}
