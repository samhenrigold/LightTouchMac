import Cocoa

/// Resolve consent before QEMU can send any guest traffic. Loopback USB and
/// Mac-side app downloads remain available when guest networking is off.
enum NetworkAccessPreference {
    static let key = "guestNetworkEnabled"

    /// Whether the device about to start gets the Mac's network: `--network`/`--no-network`
    /// on the command line (a choice that is not remembered), else the saved answer, else a prompt.
    static func resolve(profile: DeviceProfile) -> Bool {
        let arguments = CommandLine.arguments
        if arguments.contains("--no-network") { return false }
        if arguments.contains("--network") { return true }
        if let enabled = UserDefaults.standard.object(forKey: key) as? Bool { return enabled }
        let alert = NSAlert()
        alert.messageText = "Connect your \(profile.shortName) to the internet?"
        alert.informativeText = "Your \(profile.shortName) can use your Mac’s internet connection. You can change this later in the Device menu."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Use Offline")
        let enabled = alert.runModal() == .alertFirstButtonReturn
        UserDefaults.standard.set(enabled, forKey: key)
        return enabled
    }
}
