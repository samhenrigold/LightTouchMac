// Created by Sam on 2026-08-06.
//
// A copy of every .ipa this app has successfully installed, keyed by bundle
// id, per device (Devices/<uuid>/IPAs). Installed rows can be dragged out of
// the app as real files because of this — the temp download used to be
// deleted the moment the install finished, leaving nothing to drag. A few MB
// per app; the collection is the point of this program. Per device, so
// uninstalling from one device never takes another's copy, and Delete
// Device takes its copies with it.

import Foundation
import Darwin

nonisolated enum IPALibrary {

    /// Same guard as AppMetadataCache: a bundle id is about to become a path
    /// component, and an archive can claim anything as its identifier.
    private static func safe(_ bundleID: String) -> String? {
        guard !bundleID.isEmpty, !bundleID.hasPrefix("."),
              !bundleID.contains("/"), !bundleID.contains(":"), !bundleID.contains("\0") else { return nil }
        return bundleID
    }

    private static func file(_ id: String, device: DeviceInstance) -> URL {
        device.paths.ipas.appendingPathComponent("\(id).ipa")
    }

    /// The device's copy for this app, or nil if we never kept one.
    static func url(for bundleID: String, device: DeviceInstance) -> URL? {
        guard let id = safe(bundleID) else { return nil }
        let url = file(id, device: device)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Keep a copy of a just-installed .ipa. Best-effort: dragging is a
    /// convenience, never worth failing an install over.
    @concurrent static func adopt(_ ipa: URL, for bundleID: String, device: DeviceInstance) async {
        guard let id = safe(bundleID) else { return }
        let dir = device.paths.ipas
        let temporary = dir.appendingPathComponent(".\(UUID().uuidString).ipa")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try StorageLocations.privateDirectory(dir)
            try FileManager.default.copyItem(at: ipa, to: temporary)
            guard rename(temporary.path, file(id, device: device).path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            logEvent("library: could not preserve IPA for %@: %@", id, error.localizedDescription)
        }
    }

    /// The uninstall path forgets the copy alongside the metadata cache.
    static func forget(_ bundleID: String, device: DeviceInstance) {
        guard let id = safe(bundleID) else { return }
        try? FileManager.default.removeItem(at: file(id, device: device))
    }

    /// Launch, under the app lock: builds before per-device copies kept one
    /// State/IPAs for every device. Each copy is cloned (APFS: no extra
    /// space) into every device, then the shared directory goes. With no
    /// device to give them to, the copies stay where they are.
    // ponytail: every device gets every shared copy, not only the apps it
    // lists (knowing that needs the device running); an unlisted copy is never shown.
    static func migrateShared(state: URL, devices: [DeviceInstance]) {
        let fm = FileManager.default
        let shared = state.appendingPathComponent("IPAs", isDirectory: true)
        guard !devices.isEmpty, let names = try? fm.contentsOfDirectory(atPath: shared.path) else { return }
        var complete = true
        for device in devices {
            let dir = DeviceInstance.directory(device.id, state: state).appendingPathComponent("IPAs", isDirectory: true)
            for name in names where name.hasSuffix(".ipa") && !name.hasPrefix(".") {
                let destination = dir.appendingPathComponent(name)
                guard !fm.fileExists(atPath: destination.path) else { continue }
                do {
                    try StorageLocations.privateDirectory(dir)
                    try fm.copyItem(at: shared.appendingPathComponent(name), to: destination)
                } catch {
                    complete = false
                    logEvent("library: could not move \(name) to \(device.id.uuidString): \(error.localizedDescription)")
                }
            }
        }
        if complete {
            try? fm.removeItem(at: shared)
            logEvent("library: IPA copies are per device now (\(names.count) moved)")
        }
    }
}
