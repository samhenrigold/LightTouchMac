// The devices in State/Devices, for the sidebar and the sessions it starts.
// Records are the files; this is a cache over them that says when it changes.

import Foundation
import Observation

@MainActor @Observable
final class DeviceLibrary {
    /// Posted on the main actor after `instances` changes. The object is the library.
    static let didChangeNotification = Notification.Name("DeviceLibraryDidChange")

    static let shared = DeviceLibrary(state: Bundled.stateDirectory)

    let state: URL
    /// Oldest first.
    private(set) var instances: [DeviceInstance]

    init(state: URL) {
        self.state = state
        instances = DeviceInstance.all(state: state)
    }

    func instance(id: UUID) -> DeviceInstance? { instances.first { $0.id == id } }

    /// One per entry for now; the model allows more.
    func instances(firmware: String) -> [DeviceInstance] { instances.filter { $0.firmware == firmware } }

    /// Writes the record atomically; also how an existing record is updated.
    func save(_ instance: DeviceInstance) throws {
        try instance.write(state: state)
        reload()
    }

    /// Deletes Devices/<uuid> (the record and whatever the device keeps
    /// there). An adopted device's legacy files outside it stay on disk; a
    /// later launch that resolves to them adopts them again.
    /// The read-only base included (DeviceStateStorage.removeDevice).
    func remove(id: UUID) throws {
        defer { reload() }
        try DeviceStateStorage.removeDevice(id, state: state)
    }

    /// The device a single-device launch runs: LIGHTTOUCH_DEVICE picks the
    /// board and LTM_FILES the files root, choosing the matching record or
    /// adopting that state. Adopts everything on first run.
    func resolve(_ inputs: LegacyAdoption.Inputs, profile: DeviceProfile) throws -> LegacyAdoption.Resolution {
        defer { reload() }
        return try LegacyAdoption.resolve(inputs, profile: profile, state: state)
    }

    func reload() {
        let current = DeviceInstance.all(state: state)
        guard current != instances else { return }
        instances = current
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

extension DeviceInstance {
    /// This device's paths under the app's state and log roots.
    nonisolated var paths: Paths { paths(state: Bundled.stateDirectory, logs: Bundled.logsDirectory) }
}
