// Screen geometry and device art.

import CoreGraphics

nonisolated extension DeviceProfile {
    /// Framebuffer pixels as the panel scans them out. Constants, so geometry
    /// doesn't need the dylib; DeviceProcess logs if the device info in the
    /// helper's hello disagrees.
    var screenPixels: CGSize {
        switch self {
        case .iPodTouch2G, .iPodTouch1G: CGSize(width: 320, height: 480)
        case .iPad1: CGSize(width: 1024, height: 768)
        }
    }

    /// Quarter-turn from the scanned-out panel to the upright (portrait, home
    /// button down) device, clockwise-positive in the view's y-down space. The
    /// iPod LCD pre-rotates its surface; the iPad's panel is landscape-native
    /// and portrait SpringBoard (interface orientation 1) arrives with its
    /// status bar along the panel's left edge, so it is turned a quarter
    /// clockwise to stand upright.
    var panelRotation: CGFloat { self == .iPad1 ? .pi / 2 : 0 }

    /// The screen as it sits in the upright shell.
    var uprightScreenPixels: CGSize {
        let p = screenPixels
        return panelRotation == 0 ? p : CGSize(width: p.height, height: p.width)
    }

    // MARK: - Device art (shell-native pixels, top-left origin)

    /// Each board has a 3D model (<name>.usdz, revision 7 for K48 and N45).
    /// The flat art is the prepare screen's picture and the fallback while the
    /// model loads or where RealityKit can't: the 2G has shell.png (a product
    /// photo), the 1G shell-1g.png (its N45 model rendered face-on, screen off,
    /// by scripts/render-shell-art.py, which prints the numbers below), and the
    /// iPad borrows the iPad chrome from the iPhone Simulator in Xcode 3.2.4
    /// (iPad.deviceinfo: portrait.png, 852x1108, with the 768x1024 screen centred in it).
    var shellImageName: String {
        switch self { case .iPodTouch2G: "shell"; case .iPad1: "ipad-frame"; case .iPodTouch1G: "shell-1g" }
    }
    var deviceModelName: String? {
        switch self { case .iPodTouch2G: "N72"; case .iPad1: "K48"; case .iPodTouch1G: "N45" }
    }

    var shellPixels: CGSize {
        switch self {
        case .iPodTouch2G: CGSize(width: 737, height: 1318)
        case .iPodTouch1G: CGSize(width: 734, height: 1311)
        case .iPad1: CGSize(width: 852, height: 1108)
        }
    }

    var screenCutout: CGRect {
        switch self {
        case .iPodTouch2G: CGRect(x: 74, y: 213, width: 594, height: 891)
        case .iPodTouch1G: CGRect(x: 70, y: 211, width: 594, height: 891)
        // (852 - 768) / 2 and (1108 - 1024) / 2: the Simulator centres its screen.
        case .iPad1: CGRect(x: 42, y: 42, width: 768, height: 1024)
        }
    }

    /// The Home button's hit circle: diameter, and its gap to the shell's
    /// bottom edge. The iPad's comes from iPad.deviceinfo's homeOriginX/Y
    /// (412, 9, bottom-left origin) and its 29x31 home.png.
    var homeButtonDiameter: CGFloat {
        switch self { case .iPodTouch2G: 122; case .iPad1: 31; case .iPodTouch1G: 112 }
    }
    var homeButtonBottomInset: CGFloat {
        switch self { case .iPodTouch2G: 54; case .iPad1: 9; case .iPodTouch1G: 59 }
    }

    /// Height of the real device, for Actual Size zoom.
    var physicalHeightMillimeters: CGFloat { self == .iPad1 ? 242.8 : 110 }
}
