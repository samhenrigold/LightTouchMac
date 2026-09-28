import Cocoa

/// Resolve consent before QEMU can send any guest traffic. Loopback USB and
/// Mac-side app downloads remain available when guest networking is off.
enum NetworkAccessPreference {
    static let key = "guestNetworkEnabled"

    static func configure(_ options: inout LaunchOptions, profile: DeviceProfile) {
        let arguments = CommandLine.arguments
        // Command-line launches already express a choice and do not change the
        // preference used for subsequent Finder launches.
        if arguments.contains("--network") || arguments.contains("--no-network") { return }
        if let enabled = UserDefaults.standard.object(forKey: key) as? Bool {
            options.network = enabled
            return
        }
        let alert = NSAlert()
        alert.messageText = "Connect your \(profile.shortName) to the internet?"
        alert.informativeText = "Your \(profile.shortName) can use your Mac’s internet connection. macOS may ask for Local Network access.\n\nOffline mode still lets you install apps and capture the screen. Change this later in the Device menu."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Use Offline")
        options.network = alert.runModal() == .alertFirstButtonReturn
        UserDefaults.standard.set(options.network, forKey: key)
    }
}
