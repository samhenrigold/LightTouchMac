// The 1.x jailbreak's verdict in `single --jailbreak` (session-driver jailbreak1x.swift).

import SessionKit

/// Installer.app is in /Applications, as afc2 lists it.
func jailbreak1x(_ r: Report, _ events: Events, _ d: String) {
    let installer = events.one("installer1x", ["device": d])
    r.check(
        installer.bool("listed"),
        "\(d): afc2 lists /Applications/Installer.app" + (installer.string("error").map { ": \($0)" } ?? "")
    )
}
