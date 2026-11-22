// The 1.x jailbreak's part of `single` (FirmwareKit SystemEdits.installJailbreak1x): Installer.app in Cydia's place.

import Foundation
import HostServiceWire

/// Files through afc2 lists Applications/Installer.app. Emits `installer1x`.
@MainActor func installer1x(_ d: Device) async {
    var root = d.services
    root.wholeFileSystem = true
    do {
        let apps = try await root.files(in: "Applications").map(\.name)
        emit("installer1x", ["device": d.name, "listed": apps.contains("Installer.app")])
    } catch {
        emit("installer1x", ["device": d.name, "listed": false, "error": "\(error)"])
    }
}
