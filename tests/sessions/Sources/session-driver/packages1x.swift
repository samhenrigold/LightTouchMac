// `single --package`'s part at Home (sessions Packages1x.swift): what the packages installed, through afc2.

import Foundation
import HostServiceWire

/// Each of `paths` (device paths) listed in its folder through afc2. Emits `package1x` for each.
@MainActor func packages1x(_ d: Device, _ paths: [String]) async {
    var root = d.services
    root.wholeFileSystem = true
    for path in paths {
        let folder = String((path as NSString).deletingLastPathComponent.dropFirst())
        do {
            let names = try await root.files(in: folder).map(\.name)
            emit(
                "package1x",
                ["device": d.name, "path": path, "found": names.contains((path as NSString).lastPathComponent)])
        } catch {
            emit("package1x", ["device": d.name, "path": path, "found": false, "error": "\(error)"])
        }
    }
}
