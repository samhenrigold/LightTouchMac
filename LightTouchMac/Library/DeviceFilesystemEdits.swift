import Cocoa

/// A stopped generation is mounted by FirmwareKit; a durable intent keeps the
/// helper out even if this GUI quits. No filesystem writer lives in the GUI.
@MainActor
final class DeviceFilesystemEdits {
    static let shared = DeviceFilesystemEdits()
    private var busy: Set<UUID> = []
    struct Intent: Decodable { let id: UUID; let phase: String }
    struct Mounted: Decodable { let id: UUID; let mountPoint: String? }
    func pending(_ instance: DeviceInstance) -> Intent? {
        try? JSONDecoder().decode(Intent.self, from: Data(contentsOf: instance.paths.work.appendingPathComponent("edit.json")))
    }
    func blocked(_ instance: DeviceInstance) -> Bool {
        busy.contains(instance.id) || FileManager.default.fileExists(atPath: instance.paths.work.appendingPathComponent("edit.json").path)
    }
    func canPerform(_ action: DeviceAction, instance: DeviceInstance) -> Bool {
        guard FirmwareJobs.preparer != nil, !busy.contains(instance.id), instance.board == "n72ap" else { return false }
        switch action {
        case .openFilesystem: return pending(instance)?.phase == nil || pending(instance)?.phase == "editing"
        case .commitFilesystem: return pending(instance)?.phase == "editing"
        case .recoverFilesystem: return pending(instance).map { $0.phase != "editing" } == true
        case .discardFilesystem: return pending(instance)?.phase == "editing"
        default: return false
        }
    }
    func perform(_ action: DeviceAction, entry: FirmwareCatalog.Entry, host: DeviceSessionHost) {
        guard let instance = host.instance(for: entry), let executable = FirmwareJobs.preparer,
              canPerform(action, instance: instance) else { return }
        busy.insert(instance.id)
        Task {
            defer {
                busy.remove(instance.id)
                host.library.reload()
                NotificationCenter.default.post(name: DeviceLibrary.didChangeNotification, object: host.library)
            }
            do {
                guard await host.releaseStopped(for: entry) else {
                    throw DeviceToolsError.failed("Stop the device before opening its filesystem.")
                }
                var intent = pending(instance)
                let prefix = ["edit", "--device", instance.paths.directory.path]
                if action == .openFilesystem, intent == nil {
                    let result = try await FirmwareTool.run(prefix + ["--action", "begin"], executable: executable)
                    let created = try JSONDecoder().decode(Mounted.self, from: result)
                    intent = Intent(id: created.id, phase: "editing")
                }
                guard let intent else { throw DeviceToolsError.failed("The edit session is unavailable.") }
                let operation: String = switch action {
                case .openFilesystem: "mount"
                case .commitFilesystem: "commit"
                case .discardFilesystem: "discard"
                case .recoverFilesystem: "recover"
                default: throw DeviceToolsError.failed("Unsupported filesystem action.")
                }
                let result = try await FirmwareTool.run(prefix + ["--action", operation, "--session", intent.id.uuidString], executable: executable)
                if action == .openFilesystem, let path = try JSONDecoder().decode(Mounted.self, from: result).mountPoint {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            } catch { NSApp.presentError(error) }
        }
    }
}
