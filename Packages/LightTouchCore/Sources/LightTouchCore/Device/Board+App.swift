// What the app derives from a board: HostRuntime's Board (the app's facts) and its DeviceInfo (the emulator's).
// Screen geometry, art, budgets and controls; nothing here lists boards.

import CoreGraphics
import Foundation
import HostRuntime

nonisolated extension Board {
    /// A requested stop's reason (the dead overlay, the session's phase); tests compare it.
    public var stoppedReason: String { "The \(shortName) stopped." }

    /// How long a boot may take until lockdown answers (the app's "iOS is up")
    /// before the app gives up on it. The lock screen is normally there in 25 s
    /// (iPod) / 40 s (iPad) and lockdown ~40 s later; a first boot after an
    /// erase replays journals, rebuilds caches and re-enumerates USB for minutes.
    public var bootBudget: TimeInterval { (isKBoot ? 300 : 240) * Self.hostSlowdown }

    /// Emulation on an Intel Mac (this app's x86_64 slice, native or under Rosetta) takes several times the
    /// CPU time of Apple silicon for the same boot. 2026-09-30, iPod 3.1.3 to its Home screen: 28–34 s of
    /// CPU on an M4 Max, 124 s for the x86_64 slice under Rosetta on it, 122–309 s to the first lit frame on
    /// a 2018 Intel MacBook Pro. The boot's wall-clock budgets scale by it, or an Intel Mac's boot is
    /// stopped while it's still starting.
    #if arch(x86_64)
        public static let hostSlowdown: TimeInterval = 5
    #else
        public static let hostSlowdown: TimeInterval = 1
    #endif

    /// The image carries our guest shell and agent from preparation (Board.Facts.guestTools).
    public var hasGuestTools: Bool { facts.guestTools }

    // MARK: - The emulator's controls (DeviceInfo)

    public var hasCompass: Bool { hardware?.hasCompass ?? false }
    /// The USB keyboard can be unplugged and plugged back while running (qemu_ios_ui_hardware_keyboard).
    public var canToggleHardwareKeyboard: Bool { hardware?.hasUSBHost ?? false }
    /// A cellular modem (the Carrier panel).
    public var hasCellular: Bool { hardware?.hasCellular ?? false }

    public enum OrientationSource {
        /// The guest agent's orientation op reports it; the host steps the
        /// accelerometer a quarter-turn at a time (ipod_touch_kbd_rotate).
        case guestHelper
        /// SpringBoard's getInterfaceOrientation over lockdown reports it; the
        /// host sets the accelerometer outright (LinkRequest.orientation).
        case springBoard
    }
    public var orientationSource: OrientationSource { hasGuestTools ? .guestHelper : .springBoard }

    // MARK: - Screen

    /// Framebuffer pixels as the panel scans them out: the emulator's (DeviceInfo). 320x480 only until the
    /// emulator library has been listed (no library: nothing boots either).
    public var screenPixels: CGSize { hardware?.screenPixels ?? CGSize(width: 320, height: 480) }

    /// Quarter-turn from the scanned-out panel to the upright (portrait, home
    /// button down) device, clockwise-positive in the view's y-down space. Every
    /// panel scans out as is, whatever way the device is held, and the guest
    /// turns its UI inside it. The iPad's panel is landscape-native
    /// and portrait SpringBoard (interface orientation 1) arrives with its
    /// status bar along the panel's left edge, so it is turned a quarter
    /// clockwise to stand upright.
    public var panelRotation: CGFloat { Self.guestTurn(scan: screenPixels) }

    /// The quarter-turn the guest gives its portrait UI on a panel of this scan size. UIKit decides it from the
    /// panel's shape, not the board: +[UIApplication _startWindowServerIfNecessary] (3.2 UIKit 0x3223f2fc) swaps
    /// the display's bounds and calls GSSetMainScreenInfo with orientation π/2 only when it is wider than tall,
    /// so a square or taller panel gets the UI as scanned (docs: qemu-ios-files ipad1/7B500 userland-gl-display
    /// §1.4). The host mirrors that one rule; it gives the shipped iPad π/2 and the iPods 0.
    public static func guestTurn(scan: CGSize) -> CGFloat { scan.width > scan.height ? .pi / 2 : 0 }

    /// The screen as it sits in the upright shell.
    public var uprightScreenPixels: CGSize {
        let p = screenPixels
        return panelRotation == 0 ? p : CGSize(width: p.height, height: p.width)
    }

    // MARK: - Free-form screen (machine panel=WxH, issue #21)

    /// iPhone OS 1's SpringBoard keeps its icons and dock at 320x480 whatever the panel (its machines take panel=);
    /// the iPhone 5's machine takes no panel=.
    public var supportsFreeForm: Bool { soc != .s5l8900 && soc != .s5l8950 }
    public var freeFormUnavailableReason: String? {
        if soc == .s5l8950 { return "The \(preferredName)’s screen has one size." }
        return supportsFreeForm ? nil : "iPhone OS 1 keeps its Home screen at 320 × 480, whatever size the screen is."
    }

    /// The scan of an upright size by the board's convention (the iPad's panel is mounted landscape), and back.
    public func scan(upright size: CGSize) -> CGSize {
        panelRotation != 0 ? CGSize(width: size.height, height: size.width) : size
    }
    public func uprightPanel(scan: CGSize) -> CGSize { self.scan(upright: scan) }

    /// The quarter-turn a free-form scan is shown at: mounted as the shipped panel is, so the screen is the shape
    /// it was dragged to, even wider than tall (the guest lays its UI out by the scan's shape, Board.guestTurn,
    /// so a wide screen's Home screen comes out sideways). A square scan turns nothing on any board.
    public func freeFormTurn(scan: CGSize) -> CGFloat { scan.width == scan.height ? 0 : panelRotation }

    /// device.plist `panel` ("WxH" as the panel scans) for an upright guest size, and back.
    public func panelOption(upright size: CGSize) -> String {
        let scan = scan(upright: size)
        return "\(Int(scan.width))x\(Int(scan.height))"
    }
    public func uprightPanel(_ option: String?) -> CGSize? { Self.panelScan(option).map(uprightPanel(scan:)) }
    public static func panelScan(_ option: String?) -> CGSize? {
        guard let parts = option?.split(separator: "x"), parts.count == 2,
            let w = Int(parts[0]), let h = Int(parts[1])
        else { return nil }
        return CGSize(width: w, height: h)
    }

    // MARK: - Device art (Board.Art: shell-native pixels, top-left origin)

    public var shellImageName: String { facts.art.shell }
    public var deviceModelName: String? { facts.art.model }
    public var shellPixels: CGSize { facts.art.shellPixels }
    public var screenCutout: CGRect { facts.art.screenCutout }
    public var homeButtonDiameter: CGFloat { facts.art.homeDiameter }
    public var homeButtonBottomInset: CGFloat { facts.art.homeBottomInset }
    public var panelPPI: CGFloat { facts.art.ppi }
}
