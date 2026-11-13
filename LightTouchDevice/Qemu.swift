import DeviceRuntime
import Foundation
import HostRuntime

// libqemu-arm.dylib, dlopen'ed. The helper never links it: which build runs is
// chosen at launch (LTM_QEMU_DYLIB alone in a Debug build that names one, else
// the bundle's Frameworks, else the build rpath) and reported in the hello.

/// qemu-ios-ui.h QemuIosDeviceInfo (C API 2.0).
struct QemuDeviceInfoC {
    var machine: UnsafePointer<CChar>?
    var board: UnsafePointer<CChar>?
    var screenWidth, screenHeight, screenScale, defaultOrientation: Int32
    // hasUSBCharger: the C layout's, unused (the app no longer chooses the port's charge current).
    var hasCellular, hasUSBHost, hasCompass, hasUSBCharger: Bool
    var panelMin, panelMaxWidth, panelMaxHeight, panelWidthStep, panelMaxPixels: Int32
}

final class Qemu: @unchecked Sendable {
    /// The libqemu-arm.dylib C API major version this helper binds.
    static let apiMajor: UInt32 = 2
    let path: String
    private let handle: UnsafeMutableRawPointer

    /// Candidates in order; the first that loads wins.
    static func candidates() -> [String] {
        var list: [String] = []
        #if DEBUG
            // A named emulator is the only candidate: when it can't load (a library it needs outside the sandbox's
            // grants), the bundle's answering in its place would pass for the build that was asked for.
            if let override = ProcessInfo.processInfo.environment["LTM_QEMU_DYLIB"], !override.isEmpty {
                return [override]
            }
        #endif
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundled = Bundle.main.executableURL?.deletingLastPathComponent() ?? exe.deletingLastPathComponent()
        list.append(bundled.appendingPathComponent("../Frameworks/libqemu-arm.dylib").standardized.path)
        list.append("@rpath/libqemu-arm.dylib")  // Debug: QEMU_BUILD_DIR is on the helper's rpath
        return list
    }

    init(path: String) throws {
        // RTLD_NOW: a missing export fails here, not mid-session.
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw HelperError.dylib(String(cString: dlerror()))
        }
        // The C API's major version must be ours (qemu-macos-extras.h QEMU_IOS_API_VERSION: major << 16 | minor);
        // a dylib from before the version existed is 0.
        let version =
            dlsym(handle, "qemu_ios_api_version").map { unsafeBitCast($0, to: (@convention(c) () -> UInt32).self)() }
            ?? 0
        guard version >> 16 == Self.apiMajor else {
            dlclose(handle)
            throw HelperError.dylib(
                "\(path) has C API \(version >> 16).\(version & 0xffff); this LightTouchDevice needs "
                    + "\(Self.apiMajor).x. Build libqemu-arm.dylib from the qemu-ios commit build-support/sources.json pins."
            )
        }
        self.handle = handle
        var info = Dl_info()
        if let p = dlsym(handle, "qemu_ios_main"), dladdr(p, &info) != 0, let name = info.dli_fname {
            self.path = String(cString: name)
        } else {
            self.path = path
        }
    }

    static func load() throws -> Qemu {
        var errors: [String] = []
        for candidate in candidates() {
            if candidate.hasPrefix("/"), !FileManager.default.fileExists(atPath: candidate) {
                errors.append("\(candidate): not there, or not readable from the sandbox")
                continue
            }
            do { return try Qemu(path: candidate) } catch { errors.append("\(candidate): \(error)") }
        }
        throw HelperError.dylib("no libqemu-arm.dylib loaded: " + errors.joined(separator: "; "))
    }

    private func sym<T>(_ name: String, _: T.Type) -> T {
        guard let p = dlsym(handle, name) else { fatalError("libqemu-arm.dylib lacks \(name)") }
        return unsafeBitCast(p, to: T.self)
    }
    private func optionalSym<T>(_ name: String, _: T.Type) -> T? {
        dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
    }

    typealias VoidFn = @convention(c) () -> Void
    typealias BoolFn = @convention(c) () -> Bool
    typealias IntFn = @convention(c) () -> Int32

    lazy var main = sym(
        "qemu_ios_main",
        (@convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32).self
    )
    lazy var deviceInfoAt = sym("qemu_ios_device_info_at", (@convention(c) (Int32) -> UnsafeRawPointer?).self)
    lazy var attach = sym("qemu_ios_ui_attach", (@convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void).self)
    lazy var frame = sym(
        "qemu_ios_ui_frame",
        (@convention(c) (
            UnsafeMutablePointer<UnsafeRawPointer?>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>,
            UnsafeMutablePointer<UInt64>
        ) -> Bool).self
    )
    lazy var ready = sym("qemu_ios_ui_ready", BoolFn.self)
    lazy var storageFailed = sym("qemu_ios_ui_storage_failed", BoolFn.self)
    lazy var shutdownConfirmed = sym("qemu_ios_ui_guest_shutdown_confirmed", BoolFn.self)
    lazy var displaySleeping = sym("qemu_ios_ui_display_sleeping", BoolFn.self)
    lazy var backlightLevel = optionalSym("qemu_ios_ui_backlight_level", IntFn.self)  // API 2.1
    lazy var vibrator = optionalSym(
        "qemu_ios_ui_vibrator",
        (@convention(c) (UnsafeMutablePointer<UInt64>?) -> Bool).self
    )  // API 2.2
    /// API 2.4: whether a press or lift still waits for the guest's digitizer driver; its reads so far.
    lazy var touchWaiting = optionalSym(
        "qemu_ios_ui_touch_waiting",
        (@convention(c) (UnsafeMutablePointer<UInt64>?) -> Bool).self
    )
    lazy var touch = sym("qemu_ios_ui_touch", (@convention(c) (Int32, Int32, Double, Double) -> Void).self)
    lazy var touch2 = sym("qemu_ios_ui_touch2", (@convention(c) (Int32, Double, Double) -> Void).self)
    lazy var inputSequence = optionalSym(
        "qemu_ios_ui_input_sequence",
        (@convention(c) (
            UInt64, UInt, UnsafePointer<Int64>, UnsafePointer<Int32>, UnsafePointer<Int32>, UnsafePointer<Int32>,
            UnsafePointer<Double>, UnsafePointer<Double>
        ) -> Bool).self
    )
    lazy var inputSequenceStatus = optionalSym(
        "qemu_ios_ui_input_sequence_status",
        (@convention(c) (UInt64) -> Int32).self
    )
    lazy var inputSequenceCancel = optionalSym(
        "qemu_ios_ui_input_sequence_cancel",
        (@convention(c) (UInt64) -> Void).self
    )
    lazy var button = sym("qemu_ios_ui_button", (@convention(c) (Int32, Bool) -> Void).self)
    lazy var keyMac = sym("qemu_ios_ui_key_mac", (@convention(c) (Int32, Bool) -> Void).self)
    lazy var rotate = sym("qemu_ios_ui_rotate", (@convention(c) (Bool) -> Void).self)
    lazy var shake = sym("qemu_ios_ui_shake", VoidFn.self)
    lazy var attitude = sym("qemu_ios_ui_attitude", (@convention(c) (Double, Double, Int32) -> Void).self)
    lazy var paste = sym("qemu_ios_ui_paste", (@convention(c) (UnsafePointer<CChar>) -> Void).self)
    /// API 2.3: the guest's latest copy when newer than the serial (malloc'd, free()).
    lazy var guestPasteboard = optionalSym(
        "qemu_ios_ui_guest_pasteboard",
        (@convention(c) (UnsafeMutablePointer<UInt64>) -> UnsafeMutablePointer<CChar>?).self
    )
    lazy var battery = sym("qemu_ios_ui_battery", (@convention(c) (Int32, Int32) -> Bool).self)
    lazy var usbConnection = sym("qemu_ios_ui_usb_connection", (@convention(c) (Bool) -> Bool).self)
    lazy var compass = sym("qemu_ios_ui_compass", (@convention(c) (Int32) -> Bool).self)
    /// Optional: dylibs before the Carrier panel lack them.
    lazy var modemSet = optionalSym(
        "qemu_ios_ui_modem_set",
        (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Bool).self
    )
    lazy var modemStatus = optionalSym(
        "qemu_ios_ui_modem_status",
        (@convention(c) () -> UnsafeMutablePointer<CChar>?).self
    )
    lazy var modemFree = optionalSym(
        "qemu_ios_ui_modem_free",
        (@convention(c) (UnsafeMutablePointer<CChar>?) -> Void).self
    )
    lazy var orientation = sym("qemu_ios_ui_orientation", (@convention(c) (Int32) -> Bool).self)
    lazy var pause = sym("qemu_ios_ui_pause", VoidFn.self)
    lazy var resume = sym("qemu_ios_ui_resume", VoidFn.self)
    lazy var reset = sym("qemu_ios_ui_reset", VoidFn.self)
    lazy var powerdown = sym("qemu_ios_ui_powerdown", VoidFn.self)
    /// API 1.1: the guest agent's halt, else the board's power-off gesture; 0 when nothing started.
    lazy var hardwareKeyboard = optionalSym("qemu_ios_ui_hardware_keyboard", (@convention(c) (Bool) -> Bool).self)
    lazy var shutdown = optionalSym("qemu_ios_ui_shutdown", (@convention(c) () -> Int32).self)
    lazy var quit = sym("qemu_ios_ui_quit", VoidFn.self)
    // optionalSym: an older dylib without this symbol just leaves networking
    // restricted (safe) rather than trapping.
    lazy var netRestrict = optionalSym(
        "qemu_ios_ui_net_restrict",
        (@convention(c) (UnsafePointer<CChar>, Bool) -> Void).self
    )
    lazy var netLAN = optionalSym("qemu_ios_ui_net_lan", (@convention(c) (UnsafePointer<CChar>, Bool) -> Void).self)
    lazy var snapshotSave2 = sym("qemu_ios_snapshot_save2", (@convention(c) (UnsafePointer<CChar>) -> Void).self)
    lazy var snapshotStatus = sym(
        "qemu_ios_snapshot_status",
        (@convention(c) (UnsafeMutablePointer<CChar>, UInt) -> Int32).self
    )
    lazy var snapshotResume = sym("qemu_ios_snapshot_resume", VoidFn.self)
    lazy var agentRequest = sym("qemu_ios_agent_request", (@convention(c) (UnsafePointer<CChar>) -> Bool).self)
    lazy var agentCancel = sym("qemu_ios_agent_cancel", (@convention(c) (UnsafePointer<CChar>) -> Void).self)
    lazy var agentResult = sym("qemu_ios_agent_result", (@convention(c) () -> UnsafeMutablePointer<CChar>?).self)
    lazy var agentFreeResult = sym(
        "qemu_ios_agent_free_result",
        (@convention(c) (UnsafeMutablePointer<CChar>?) -> Void).self
    )
    lazy var agentStatus = sym("qemu_ios_agent_status", IntFn.self)
    /// API 2.4: the agent's state report when newer than the serial (malloc'd, free()); "" once its session ended.
    lazy var agentReport = optionalSym(
        "qemu_ios_agent_report",
        (@convention(c) (UnsafeMutablePointer<UInt64>) -> UnsafeMutablePointer<CChar>?).self
    )
    lazy var glesContexts = sym("qemu_ios_gles_contexts", IntFn.self)
    /// API 2.5: the GL bridge's refusals whose count moved since the serial ("NAME\tCOUNT\tCALL" lines, malloc'd,
    /// free()); NULL when none did.
    lazy var glesRefusals = optionalSym(
        "qemu_ios_gles_refusals",
        (@convention(c) (UnsafeMutablePointer<UInt64>) -> UnsafeMutablePointer<CChar>?).self
    )
    /// Optional: dylibs before the guest-package hypercalls lack them.
    lazy var guestPackageReport = optionalSym(
        "qemu_ios_guest_package_report",
        (@convention(c) (UnsafeMutablePointer<Int64>?, UnsafeMutablePointer<Int32>?) -> Bool).self
    )
    lazy var glesProtocol = optionalSym(
        "qemu_ios_gles_protocol",
        (@convention(c) (UnsafeMutablePointer<Int64>?) -> Int32).self
    )
    lazy var buildID = optionalSym("qemu_ios_build_id", (@convention(c) () -> UnsafePointer<CChar>?).self)
    lazy var audioStart = sym("qemu_ios_audio_capture_start", (@convention(c) () -> UInt64).self)
    lazy var audioRead = sym(
        "qemu_ios_audio_capture_read",
        (@convention(c) (UInt64, UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<Double>?) -> Int32).self
    )
    lazy var audioStop = sym("qemu_ios_audio_capture_stop", (@convention(c) (UInt64) -> Void).self)

    /// Every machine the library runs (qemu_ios_device_info_at).
    var machines: [DeviceInfo] {
        var list: [DeviceInfo] = []
        while let raw = deviceInfoAt(Int32(list.count)) {
            let c = raw.load(as: QemuDeviceInfoC.self)
            func string(_ p: UnsafePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "" }
            list.append(
                DeviceInfo(
                    machine: string(c.machine),
                    board: string(c.board),
                    screenWidth: Int(c.screenWidth),
                    screenHeight: Int(c.screenHeight),
                    screenScale: Int(c.screenScale),
                    defaultOrientation: Int(c.defaultOrientation),
                    hasCellular: c.hasCellular,
                    hasUSBHost: c.hasUSBHost,
                    hasCompass: c.hasCompass,
                    panelMin: Int(c.panelMin),
                    panelMaxWidth: Int(c.panelMaxWidth),
                    panelMaxHeight: Int(c.panelMaxHeight),
                    panelWidthStep: Int(c.panelWidthStep),
                    panelMaxPixels: Int(c.panelMaxPixels)
                )
            )
        }
        return list
    }

    var modified: Double {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?.timeIntervalSince1970
            ?? 0
    }
}

enum HelperError: Error, CustomStringConvertible {
    case dylib(String)
    case usage(String)
    var description: String {
        switch self {
        case .dylib(let s), .usage(let s): s
        }
    }
}
