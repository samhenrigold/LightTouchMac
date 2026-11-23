// The 1.x jailbreak's verdict in `single --jailbreak` (session-driver jailbreak1x.swift).

import Foundation
import HostRuntime
import LightTouchCore
import SessionKit

/// Installer.app is in /Applications, as afc2 lists it.
func jailbreak1x(_ r: Report, _ events: Events, _ d: String) {
    let installer = events.one("installer1x", ["device": d])
    r.check(
        installer.bool("listed"),
        "\(d): afc2 lists /Applications/Installer.app" + (installer.string("error").map { ": \($0)" } ?? "")
    )
}

/// `--managed --jailbreak` on a base prepared stock: the device jailbroken while stopped, as Device ▸ Jailbreak… does
/// (firmwarekit edit --action jailbreak, the bundled guest tools), before its first boot.
func jailbreakStopped(_ managed: DeviceInstance, base: Base, tools: Tools, work: URL) {
    guard (try? DeviceLock.read(base: base.url))??.jailbroken != true else { return }
    let log = work.appendingPathComponent("jailbreak-edit.log")
    let status = run(
        tools.firmwarekit.path,
        [
            "edit", "--device", managed.paths(state: work, logs: work).directory.path, "--action", "jailbreak",
            "--record-policy", "managed", "--cache", work.appendingPathComponent("cache/Decrypted").path,
            "--guest-tools", tools.guest.appendingPathComponent("guest-tools").path
        ],
        log: log,
        environment: ProcessInfo.processInfo.environment.merging(["LTM_STATE_DIR": work.path]) { $1 }
    )
    guard status == 0 else { die("firmwarekit edit --action jailbreak failed (\(log.path))", code: 1) }
    print("jailbroken while stopped: \(log.path)")
}

/// `ROW+jailbreak`, where matrix-refs has that row's jailbroken Home (1.x's carries Installer.app's icon); nil without
/// `--jailbreak` or a reference, so the row's stock Home judges it.
func jailbrokenReference(_ entryID: String, _ jailbreak: Bool) -> String? {
    let id = entryID + "+jailbreak"
    let ref = repository.appendingPathComponent("tests/sessions/matrix-refs/\(id)-home.png")
    return jailbreak && FileManager.default.fileExists(atPath: ref.path) ? id : nil
}
