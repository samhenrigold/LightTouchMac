// Screen geometry (from the dylib's qemu_ios_device_info()) and device art.

import CoreGraphics

nonisolated extension DeviceProfile {
    /// Framebuffer pixels as the panel scans them out.
    var screenPixels: CGSize {
        guard let info = qemu_ios_device_info(machineName)?.pointee else {
            fatalError("libqemu-arm.dylib does not know machine \(machineName)")
        }
        return CGSize(width: Int(info.screen_width), height: Int(info.screen_height))
    }

    /// Quarter-turn from the scanned-out panel to the upright (portrait, home
    /// button down) device, clockwise-positive in the view's y-down space. The
    /// iPod LCD pre-rotates its surface; the iPad's panel is landscape-native
    /// and portrait SpringBoard arrives with its status bar along the panel's
    /// right edge (seen in a frame dump), so it is turned a quarter back.
    var panelRotation: CGFloat { self == .iPad1 ? -.pi / 2 : 0 }

    /// The screen as it sits in the upright shell.
    var uprightScreenPixels: CGSize {
        let p = screenPixels
        return panelRotation == 0 ? p : CGSize(width: p.height, height: p.width)
    }

    // MARK: - Device art (shell-native pixels, top-left origin)

    /// The iPod has shell.png and the N72 3D model; the iPad has neither yet
    /// and is drawn as a flat black slab with the screen inset by `bezel`.
    var hasShellArt: Bool { self == .iPodTouch2G }
    private static let iPadBezel: CGFloat = 96

    var shellPixels: CGSize {
        switch self {
        case .iPodTouch2G: CGSize(width: 737, height: 1318)
        case .iPad1:
            CGSize(width: uprightScreenPixels.width + 2 * Self.iPadBezel,
                   height: uprightScreenPixels.height + 2 * Self.iPadBezel)
        }
    }

    var screenCutout: CGRect {
        switch self {
        case .iPodTouch2G: CGRect(x: 74, y: 213, width: 594, height: 891)
        case .iPad1: CGRect(origin: CGPoint(x: Self.iPadBezel, y: Self.iPadBezel), size: uprightScreenPixels)
        }
    }
}
