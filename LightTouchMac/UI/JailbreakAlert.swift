import Cocoa

/// Device ▸ Jailbreak…'s question: what the jailbreak adds to `name`'s device (Substrate on iOS 3 to 6, as FirmwareKit
/// installs it; on iPhone OS 1 Installer.app, no Cydia) and that Erase, which returns the device to how it was prepared, removes them.
enum JailbreakAlert {
    static func make(name: String, version: String) -> NSAlert {
        let major = Int(version.split(separator: ".").first ?? "") ?? 0
        let alert = NSAlert()
        alert.messageText = "Jailbreak \(name)?"
        alert.informativeText =
            "Adds \(major == 1 ? "Installer.app" : "Cydia\((3...6).contains(major) ? ", Substrate," : "")") and afc2, which shows the whole file system in Files. Erase All Content and Settings removes them."
        alert.addButton(withTitle: "Jailbreak")
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}
