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

    /// The iPod has shell.png and the N72 3D model. The iPad borrows the iPad
    /// chrome from the iPhone Simulator in Xcode 3.2.4 (iPad.deviceinfo:
    /// portrait.png, 852x1108, with the 768x1024 screen centred in it), as a
    /// stand-in until it has a 3D model of its own.
    var shellImageName: String { self == .iPad1 ? "ipad-frame" : "shell" }
    var hasDeviceModel: Bool { self == .iPodTouch2G }

    var shellPixels: CGSize {
        switch self {
        case .iPodTouch2G: CGSize(width: 737, height: 1318)
        case .iPad1: CGSize(width: 852, height: 1108)
        }
    }

    var screenCutout: CGRect {
        switch self {
        case .iPodTouch2G: CGRect(x: 74, y: 213, width: 594, height: 891)
        // (852 - 768) / 2 and (1108 - 1024) / 2: the Simulator centres its screen.
        case .iPad1: CGRect(x: 42, y: 42, width: 768, height: 1024)
        }
    }

    /// The Home button's hit circle: diameter, and its gap to the shell's
    /// bottom edge. The iPad's comes from iPad.deviceinfo's homeOriginX/Y
    /// (412, 9, bottom-left origin) and its 29x31 home.png.
    var homeButtonDiameter: CGFloat { self == .iPad1 ? 31 : 122 }
    var homeButtonBottomInset: CGFloat { self == .iPad1 ? 9 : 54 }

    /// Height of the real device, for Actual Size zoom.
    var physicalHeightMillimeters: CGFloat { self == .iPad1 ? 242.8 : 110 }
}
