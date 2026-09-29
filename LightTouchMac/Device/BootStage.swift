// Where a boot stands, from what the device has shown: serial lines, the guest tools reporting in, USB.
// Never a timer. Pure Foundation, so tests/offline/check-boot-stage.py compiles it whole.

import Foundation

nonisolated enum BootStage: Int, Comparable, Sendable {
    /// Nothing from the device yet.
    case poweringOn
    /// iBoot is up and loading the kernel.
    case loading
    /// The kernel printed its banner (serial, with the kernel console on).
    case kernel
    /// iOS userland runs: launchd on serial, the guest tools' loader or agent, it_ethlink.
    case system
    /// The USB bridge sees the device; lockdown and the Home screen are next.
    case usb

    /// What the device proved, in the order a boot shows it.
    enum Event: Equatable, Sendable {
        /// A phrase from `serialMarkers`, the first time the serial log prints it.
        case serial(String)
        case guestTools
        case usbAttached
    }

    /// The serial log phrases the watch reports, and the stage each proves. Whichever the board prints:
    /// iBoot-204 has no banner, and the kernel's own lines need the kernel console.
    static let serialMarkers: [String: BootStage] = [
        ":: iBoot for": .loading,
        "Loading kernel cache": .loading,
        "Darwin Kernel Version": .kernel,
        "iBoot version: ": .kernel,   // the kernel's line, not iBoot's
        "launchd[1] has started up": .system,
    ]

    /// Stages only move forward: a late marker never takes the boot back.
    func after(_ event: Event) -> BootStage {
        let reached: BootStage? = switch event {
        case let .serial(phrase): Self.serialMarkers[phrase]
        case .guestTools: .system
        case .usbAttached: .usb
        }
        return max(self, reached ?? self)
    }

    /// The boot toast's subtitle, under "Starting iOS…".
    var text: String {
        switch self {
        case .poweringOn: "Powering on"
        case .loading: "Loading iOS"
        case .kernel: "Starting the system"
        case .system: "Connecting over USB"
        case .usb: "Waiting for the Home screen"
        }
    }

    static func < (a: BootStage, b: BootStage) -> Bool { a.rawValue < b.rawValue }
}
