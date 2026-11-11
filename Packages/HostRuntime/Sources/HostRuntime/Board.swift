// The boards Light Touch runs: one case each, and the facts only the app has about it (its names, how its
// prepared base boots, its guest architecture, its art). What the hardware is (the -M machine, screen, modem,
// USB host, compass, charger, panel limits) is the emulator's: DeviceInfo, from qemu_ios_device_info, by board.
//
// A new board is a case and its Facts below, and its row in qemu-ios's qemu_ios_device_info table
// (contrib/ios-app/qemu-ios-ui.c). Nothing else lists boards.

import CoreGraphics
import Foundation

public enum Board: String, Sendable, CaseIterable, Codable {
    case n45 = "n45ap"
    case m68 = "m68ap"
    case n72 = "n72ap"
    case n18 = "n18ap"
    case n88 = "n88ap"
    case k48 = "k48ap"
    case n81 = "n81ap"
    case n90 = "n90ap"

    /// The SoC family, which decides the prepared base's boot: the S5L8900's iBoot + NOR (iPhone OS 1), the
    /// S5L8720's direct iBoot or SecureROM chain, the S5L8920/S5L8930's direct-kernel kboot (iBoot too on K48).
    public enum SoC: Sendable { case s5l8900, s5l8720, s5l8920, s5l8930 }
    public enum Kind: String, Sendable {
        case iPod = "iPod touch"
        case iPhone
        case iPad
    }

    /// The device art, in shell-native pixels with a top-left origin. The flat art is the prepare screen's
    /// picture and the fallback while the 3D model loads: the 2G's shell.png (a product photo), the 1G's and 4G's
    /// their N45/N81 models rendered face-on (RealityRenderer, screen off), the 3G the 2G's chassis; the iPad the
    /// Xcode 3.2.4 iPhone Simulator's iPad chrome (852x1108, its 768x1024 screen centered); the iPhone 4 Xcode
    /// 4.6.3's Retina 3.5-inch chrome (730x1426 cropped); the iPhone 2G and 3GS iPhone SDK 3.1.3's frame.png.
    public struct Art: Sendable {
        public var shell: String
        /// The bundled <name>.usdz, or none (the 2D shell or no bezel).
        public var model: String?
        public var shellPixels: CGSize
        public var screenCutout: CGRect
        /// The Home button's hit circle and its gap to the shell's bottom edge.
        public var homeDiameter: CGFloat, homeBottomInset: CGFloat
        /// The real panel's pixels per inch, for Physical Size: the screen's size whatever the bezel.
        public var ppi: CGFloat
    }

    public struct Facts: Sendable {
        public var soc: SoC
        public var kind: Kind
        /// The model ID ("iPod2,1"): macOS's device type, the store's device.
        public var productType: String
        public var marketingName: String
        /// The short name people use ("iPod 2G", "iPhone 3GS", "iPad 1").
        public var abbreviatedName: String
        /// The image carries our guest agent and shell from preparation (iPod touch 2G); the others get theirs as
        /// a guest package at boot.
        public var guestTools = false
        /// A GPS receiver the emulator models: the iPhone 3GS's, part of its modem (qemu-ios ios_baseband_gps.c,
        /// docs/baseband/gps.md). The iPhone 4's BCM4750 isn't modeled; the original iPhone has none.
        public var hasGPS = false
        public var art: Art
    }

    public var facts: Facts {
        func art(
            _ shell: String,
            _ model: String?,
            _ size: (CGFloat, CGFloat),
            _ cut: (CGFloat, CGFloat, CGFloat, CGFloat),
            home: CGFloat,
            inset: CGFloat,
            ppi: CGFloat
        ) -> Art {
            Art(
                shell: shell,
                model: model,
                shellPixels: CGSize(width: size.0, height: size.1),
                screenCutout: CGRect(x: cut.0, y: cut.1, width: cut.2, height: cut.3),
                homeDiameter: home,
                homeBottomInset: inset,
                ppi: ppi
            )
        }
        switch self {
        case .n45:
            return Facts(
                soc: .s5l8900,
                kind: .iPod,
                productType: "iPod1,1",
                marketingName: "iPod touch",
                abbreviatedName: "iPod 1G",
                art: art("shell-1g", "N45", (734, 1311), (70, 211, 594, 891), home: 112, inset: 59, ppi: 163)
            )
        case .m68:
            return Facts(
                soc: .s5l8900,
                kind: .iPhone,
                productType: "iPhone1,1",
                marketingName: "iPhone",
                abbreviatedName: "iPhone 2G",
                art: art("shell-iphone2g", nil, (383, 729), (33, 130, 320, 480), home: 70, inset: 34, ppi: 163)
            )
        case .n72:
            return Facts(
                soc: .s5l8720,
                kind: .iPod,
                productType: "iPod2,1",
                marketingName: "iPod touch (2nd generation)",
                abbreviatedName: "iPod 2G",
                guestTools: true,
                art: art("shell", "N72", (737, 1318), (74, 213, 594, 891), home: 122, inset: 54, ppi: 163)
            )
        case .n18:
            return Facts(
                soc: .s5l8920,
                kind: .iPod,
                productType: "iPod3,1",
                marketingName: "iPod touch (3rd generation)",
                abbreviatedName: "iPod 3G",
                art: art("shell", "N72", (737, 1318), (74, 213, 594, 891), home: 122, inset: 54, ppi: 163)
            )
        case .n88:
            return Facts(
                soc: .s5l8920,
                kind: .iPhone,
                productType: "iPhone2,1",
                marketingName: "iPhone 3GS",
                abbreviatedName: "iPhone 3GS",
                hasGPS: true,
                art: art("shell-iphone2g", "N88", (383, 729), (33, 130, 320, 480), home: 70, inset: 34, ppi: 163)
            )
        // The iPad's home button: iPad.deviceinfo's homeOriginX/Y (412, 9, bottom-left origin) and its 29x31 home.png.
        case .k48:
            return Facts(
                soc: .s5l8930,
                kind: .iPad,
                productType: "iPad1,1",
                marketingName: "iPad",
                abbreviatedName: "iPad 1",
                art: art("ipad-frame", "K48", (852, 1108), (42, 42, 768, 1024), home: 31, inset: 9, ppi: 132)
            )
        case .n81:
            return Facts(
                soc: .s5l8930,
                kind: .iPod,
                productType: "iPod4,1",
                marketingName: "iPod touch (4th generation)",
                abbreviatedName: "iPod 4G",
                art: art("shell-4g", "N81", (696, 1310), (54, 213, 590, 886), home: 119, inset: 49, ppi: 326)
            )
        case .n90:
            return Facts(
                soc: .s5l8930,
                kind: .iPhone,
                productType: "iPhone3,1",
                marketingName: "iPhone 4",
                abbreviatedName: "iPhone 4",
                art: art("shell-iphone4", nil, (730, 1426), (48, 236, 640, 960), home: 140, inset: 52, ppi: 326)
            )
        }
    }

    public init?(productType: String) {
        guard let board = Self.allCases.first(where: { $0.facts.productType == productType }) else { return nil }
        self = board
    }

    public var soc: SoC { facts.soc }

    /// The emulator globals for a panel refreshing at `hz` (Settings ▸ General's experimental 120 Hz), none at the
    /// devices' 60: the panel's frame interrupt, which the guest's compositor draws on, and the touch reports with
    /// it (the 1G's digitizer model has no rate to raise).
    public func refreshGlobals(_ hz: Int) -> [String] {
        guard hz != 60 else { return [] }
        // The long form: these type names have dots, and -global's short one splits at the first.
        let panel = soc == .s5l8900 || soc == .s5l8720 ? "ipodtouch.lcd" : "s5l8930.display"
        var globals = ["-global", "driver=\(panel),property=refresh-hz,value=\(hz)"]
        if soc != .s5l8900 { globals += ["-global", "driver=ipodtouch.multitouch,property=report-hz,value=\(hz)"] }
        return globals
    }

    public var productType: String { facts.productType }
    public var marketingName: String { facts.marketingName }

    /// How the app names a device: Settings ▸ General's Device Names.
    public enum NameStyle: String, CaseIterable, Sendable {
        /// "iPod touch (2nd generation)".
        case marketing
        /// "iPod2,1".
        case model
        /// "iPod 2G".
        case abbreviated

        public static let key = "deviceNameStyle"
        /// Posted when the setting changes, for the names already on screen.
        public static let didChangeNotification = Notification.Name("DeviceNameStyleDidChange")

        public static var current: NameStyle {
            UserDefaults.standard.string(forKey: key).flatMap(NameStyle.init(rawValue:)) ?? .marketing
        }
    }

    public func name(_ style: NameStyle) -> String {
        switch style {
        case .marketing: marketingName
        case .model: productType
        case .abbreviated: facts.abbreviatedName
        }
    }

    /// The device's name as Settings ▸ General's Device Names chose.
    public var preferredName: String { name(.current) }
    /// "iPod touch", "iPhone", "iPad".
    public var displayName: String { facts.kind.rawValue }
    /// What the device is called in menus, titles and messages ("the iPod").
    public var shortName: String { facts.kind == .iPod ? "iPod" : facts.kind.rawValue }
    public var isPhone: Bool { facts.kind == .iPhone }
    /// A vibration motor: every iPhone has one the emulator drives (the original iPhone's through its baseband, the
    /// 3GS's and iPhone 4's from PWM); no iPod touch or iPad has one.
    public var hasVibrator: Bool { isPhone }
    public var hasGPS: Bool { facts.hasGPS }

    /// The S5L8920/S5L8930 boards: FirmwareKit prepares them alike and they boot kboot (iBoot too on K48) through
    /// BootRecipe.iPad.
    public var isKBoot: Bool { soc == .s5l8920 || soc == .s5l8930 }
    /// The guest packages' architecture.
    public var arch: String { soc == .s5l8900 || soc == .s5l8720 ? "armv6" : "armv7" }
    /// The SecureROM image the machine boots, under the device assets (BootRecipe.bootrom).
    public var bootrom: String { soc == .s5l8900 ? "bootrom_s5l8900" : "bootrom_240_4" }
    /// iPhone OS 1: no guest agent, so the web proxy's CA goes into the stopped device's trust store.
    public var trustsStopped: Bool { soc == .s5l8900 }
    /// iPhones prepared through the kboot pipeline (iPhone 3GS, iPhone 4): their identity carries the modem's IMEI
    /// (IPhoneIdentity); the original iPhone's recipe records its own.
    public var kbootPhone: Bool { isKBoot && isPhone }

    /// A prepared base's boot file and the other files its boots need besides nand/, by the lock's boot_strategy.
    /// K48's iboot recipe boots iBoot->kernel from iBoot.bin + nor.bin + gid-blobs.bin, its kboot recipe (and the
    /// older prepared iPads) direct-kernel from kboot.bin; the other kboot boards kboot only, nor.bin carrying the
    /// grafted NOR's effaceable storage. The N72 boots the machine's direct-iBoot (3.x+, no strategy or "iboot"), or
    /// with "bootrom" (2.x) the real SecureROM -> NOR LLB -> iBoot chain from nor.bin. The S5L8900's iBoot.bin
    /// (the machine's `iboot=`) + nor.bin; no GID blobs (1.x's 8900 key is fixed).
    public func requiredFiles(strategy: String?) throws -> (boot: String, files: [String]) {
        func unknown() -> CocoaError {
            CocoaError(
                .fileReadCorruptFile,
                userInfo: [NSLocalizedDescriptionKey: "Unknown boot strategy: \(strategy ?? "none")"]
            )
        }
        switch (soc, strategy) {
        case (.s5l8900, nil), (.s5l8900, "iboot"): return ("iBoot.bin", ["nor.bin"])
        case (.s5l8720, nil), (.s5l8720, "iboot"): return ("iBoot.bin", ["nor.bin", "gid-blobs.bin"])
        case (.s5l8720, "bootrom"): return ("nor.bin", ["gid-blobs.bin"])
        case (_, nil) where self == .k48, (_, "kboot") where self == .k48: return ("kboot.bin", [])
        case (_, "iboot") where self == .k48: return ("iBoot.bin", ["nor.bin", "gid-blobs.bin"])
        case (_, "bootrom") where self == .k48: return ("SecureROM.bin", ["nor.bin", "gid-blobs.bin"])
        case (.s5l8920, nil), (.s5l8920, "kboot"), (.s5l8930, nil), (.s5l8930, "kboot"):
            return ("kboot.bin", ["nor.bin"])
        default: throw unknown()
        }
    }
}
