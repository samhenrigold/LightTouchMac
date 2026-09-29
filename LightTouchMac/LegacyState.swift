// State from before the built-in iPod was a prepared device: the unpacked
// image under State/device with its active-<nand>.json pointer, the
// nandrw-<key> overlay and snapshot-<key> files beside it, device records
// whose base was that image or a development checkout, and the older
// Application Support/LightTouchMac root. None of it can carry over (the
// overlay only fits the base it was made on), so the app offers once, at
// launch, to erase it and continue. What survives: every retained .ipa
// (into the library) and the host's usbmuxd pairing, which the built-in
// device is seeded with when it is published (FirmwareJobs.prepareBundled).

import Foundation

nonisolated struct LegacyState {
    let state: URL
    /// The pre-library root, still in place.
    let oldRoot: URL?
    /// What the old layout left in the state root.
    let items: [URL]
    /// Records made on the old image or a development checkout (`base.kind` other than prepared).
    let records: [UUID]

    static let message = "Light Touch’s built-in iPod has changed format."
    static let detail = "Erase it and continue (apps you’ve saved are kept), or quit."

    /// Whether anything of the old layout is here. `applicationSupport` is
    /// nil for an isolated run (LTM_STATE_DIR), which has no old root.
    static func find(state: URL, applicationSupport: URL?) -> LegacyState? {
        let fm = FileManager.default
        let oldRoot = applicationSupport.map { $0.appendingPathComponent("LightTouchMac", isDirectory: true) }
            .flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
        var items: [URL] = []
        for name in (try? fm.contentsOfDirectory(atPath: state.path)) ?? []
        where name == "device" || name == "AppCache" || name == "IPAs" || name.hasPrefix("nandrw-") || name.hasPrefix("snapshot-")
            || name.hasPrefix(".reset-") || name.hasPrefix("app.log") || name.hasPrefix("serial.log") || name.hasPrefix("web-proxy.") {
            items.append(state.appendingPathComponent(name))
        }
        for name in ["usbmuxd.log", "usbmuxd.log.1", "usbmuxd.pid", "session.env"] {
            let url = state.appendingPathComponent("work/\(name)")
            if fm.fileExists(atPath: url.path) { items.append(url) }
        }
        var records: [UUID] = []
        let devices = state.appendingPathComponent("Devices", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: devices.path)) ?? [] {
            guard let id = UUID(uuidString: name),
                  let data = try? Data(contentsOf: devices.appendingPathComponent("\(name)/\(DeviceInstance.recordName)")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = (json["base"] as? [String: Any])?["kind"] as? String, kind != "prepared" else { continue }
            records.append(id)
        }
        guard oldRoot != nil || !items.isEmpty || !records.isEmpty else { return nil }
        return LegacyState(state: state, oldRoot: oldRoot, items: items, records: records)
    }

    /// The directories whose .ipa files go into the library first.
    var ipaDirectories: [URL] {
        var dirs = [state.appendingPathComponent("IPAs")]
        dirs += records.map { DeviceInstance.directory($0, state: state).appendingPathComponent("IPAs") }
        if let oldRoot { dirs.append(oldRoot.appendingPathComponent("IPAs")) }
        return dirs
    }

    /// The host pairing to keep: the state root's, else the old root's, moved beside it.
    var pairing: URL? {
        let fm = FileManager.default
        let mine = state.appendingPathComponent("work/usbmuxd-conf", isDirectory: true)
        if fm.fileExists(atPath: mine.path) { return mine }
        if let old = oldRoot?.appendingPathComponent("work/usbmuxd-conf", isDirectory: true), fm.fileExists(atPath: old.path) {
            try? fm.createDirectory(at: mine.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if (try? fm.moveItem(at: old, to: mine)) != nil { return mine }
        }
        return nil
    }

    /// Erase & Continue: the .ipa files into the library, the pairing kept
    /// (State/work/usbmuxd-conf), then everything else of the old layout
    /// removed, the old root included. Never a path outside `state` or the
    /// old root.
    @MainActor func erase() throws {
        let fm = FileManager.default
        for directory in ipaDirectories { IPALibrary.adopt(copies: directory) }
        _ = pairing
        for record in records {
            for name in DeviceInstance.perDeviceDefaults { UserDefaults.standard.removeObject(forKey: "\(name).\(record.uuidString)") }
            try DeviceStateStorage.removeDevice(record, state: state)
        }
        for item in items {
            try DeviceStateStorage.checkRemovable(item, state: state, owner: nil)
            try DeviceStateStorage.removeTree(item)
        }
        if let oldRoot { try DeviceStateStorage.removeTree(oldRoot) }
        logEvent("legacy: erased the pre-library state (\(items.count) items, \(records.count) records\(oldRoot == nil ? "" : ", the old root"))")
    }
}
