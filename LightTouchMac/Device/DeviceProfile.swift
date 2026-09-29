// Which board an emulated device is.
//
// Each EmulatorController holds its own, from its device record's board.
// Screen geometry and art live in DeviceProfile+Display.swift; this file
// needs nothing else, so any source that only needs the name can use it.

import Foundation

nonisolated enum DeviceProfile: Equatable {
    case iPodTouch2G
    case iPad1

    /// The name passed to -M; also the key for the hello's device info.
    var machineName: String { self == .iPad1 ? "ipad1" : "iPod-Touch" }
    var displayName: String { self == .iPad1 ? "iPad" : "iPod touch" }
    /// What the device is called in menus, titles and messages ("the iPod").
    var shortName: String { self == .iPad1 ? "iPad" : "iPod" }
    /// A requested stop's reason (the dead overlay, the session's phase); tests compare it.
    var stoppedReason: String { "The \(shortName) stopped." }

    var boardID: String { self == .iPad1 ? "k48ap" : "n72ap" }
    /// A prepared base's boot file and the other files its boots need besides nand/, by the lock's boot_strategy.
    /// The iPad's k48 iboot recipe (default) boots SecureROM->LLB->iBoot->kernel from iBoot.bin + nor.bin +
    /// gid-blobs.bin; the kboot recipe (and the two older prepared iPads) boots direct-kernel from kboot.bin.
    /// The iPod's n72 recipe boots the machine's direct-iBoot from iBoot.bin + nor.bin + gid-blobs.bin (3.x+, no
    /// boot_strategy or "iboot"), or with "bootrom" (2.x) the real SecureROM -> NOR LLB -> iBoot chain from nor.bin.
    func preparedBoot(strategy: String?) -> (boot: String, files: [String]) {
        if self == .iPad1 {
            return strategy == "iboot" ? ("iBoot.bin", ["nor.bin", "gid-blobs.bin"]) : ("kboot.bin", [])
        }
        return strategy == "bootrom" ? ("nor.bin", ["gid-blobs.bin"]) : ("iBoot.bin", ["nor.bin", "gid-blobs.bin"])
    }
    var productType: String { self == .iPad1 ? "iPad1,1" : "iPod2,1" }
    var marketingName: String { self == .iPad1 ? "iPad" : "iPod touch (2nd generation)" }

    /// How long a boot may take until lockdown answers (the app's "iOS is up")
    /// before the app gives up on it. The lock screen is normally there in 25 s
    /// (iPod) / 40 s (iPad) and lockdown ~40 s later; a first boot after an
    /// erase replays journals, rebuilds caches and re-enumerates USB for minutes.
    // ponytail: fixed per board; make it per firmware in the catalog if 4.x first boots need more.
    var bootBudget: TimeInterval { self == .iPad1 ? 300 : 240 }

    /// The iPod image carries our guest shell and agent; the stock iPad has none.
    var hasGuestTools: Bool { self != .iPad1 }
    var hasCompass: Bool { self == .iPad1 }
    /// Whether the board's USB host can be told to grant high-power current.
    var canChooseUSBCharger: Bool { self == .iPad1 }

    enum OrientationSource {
        /// The guest agent's orientation op reports it; the host steps the
        /// accelerometer a quarter-turn at a time (ipod_touch_kbd_rotate).
        case guestHelper
        /// SpringBoard's getInterfaceOrientation over lockdown reports it; the
        /// host sets the accelerometer outright (LinkRequest.orientation).
        case springBoard
    }
    var orientationSource: OrientationSource { self == .iPad1 ? .springBoard : .guestHelper }
}
