// libqemu-arm.dylib, dlopen'ed. The helper never links it: which build runs is
// chosen at launch (LTM_QEMU_DYLIB for development, else the bundle's
// Frameworks, else the build rpath) and reported in the hello.

import Foundation

struct QemuDeviceInfoC {
    var machine: UnsafePointer<CChar>?
    var screenWidth: Int32
    var screenHeight: Int32
    var screenScale: Int32
    var defaultOrientation: Int32
    var hasCellular: Bool
}

final class Qemu: @unchecked Sendable {
    let path: String
    private let handle: UnsafeMutableRawPointer

    /// Candidates in order; the first that loads wins.
    static func candidates() -> [String] {
        var list: [String] = []
        if let override = ProcessInfo.processInfo.environment["LTM_QEMU_DYLIB"], !override.isEmpty { list.append(override) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundled = Bundle.main.executableURL?.deletingLastPathComponent() ?? exe.deletingLastPathComponent()
        list.append(bundled.appendingPathComponent("../Frameworks/libqemu-arm.dylib").standardized.path)
        list.append("@rpath/libqemu-arm.dylib")      // Debug: QEMU_BUILD_DIR is on the helper's rpath
        return list
    }

    init(path: String) throws {
        // RTLD_NOW: a missing export fails here, not mid-session.
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw HelperError.dylib(String(cString: dlerror()))
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
            if candidate.hasPrefix("/"), !FileManager.default.fileExists(atPath: candidate) { continue }
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

    lazy var main = sym("qemu_ios_main", (@convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32).self)
    lazy var deviceInfo = sym("qemu_ios_device_info", (@convention(c) (UnsafePointer<CChar>) -> UnsafeRawPointer?).self)
    lazy var attach = sym("qemu_ios_ui_attach", (@convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void).self)
    lazy var frame = sym("qemu_ios_ui_frame", (@convention(c) (UnsafeMutablePointer<UnsafeRawPointer?>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<UInt64>) -> Bool).self)
    lazy var ready = sym("qemu_ios_ui_ready", BoolFn.self)
    lazy var storageFailed = sym("qemu_ios_ui_storage_failed", BoolFn.self)
    lazy var shutdownConfirmed = sym("qemu_ios_ui_guest_shutdown_confirmed", BoolFn.self)
    lazy var displaySleeping = sym("qemu_ios_ui_display_sleeping", BoolFn.self)
    lazy var iconGeneration = sym("qemu_ios_ui_icon_state_generation", (@convention(c) () -> UInt64).self)
    lazy var touch = sym("qemu_ios_ui_touch", (@convention(c) (Int32, Int32, Double, Double) -> Void).self)
    lazy var touch2 = sym("qemu_ios_ui_touch2", (@convention(c) (Int32, Double, Double) -> Void).self)
    lazy var button = sym("qemu_ios_ui_button", (@convention(c) (Int32, Bool) -> Void).self)
    lazy var keyMac = sym("qemu_ios_ui_key_mac", (@convention(c) (Int32, Bool) -> Void).self)
    lazy var rotate = sym("qemu_ios_ui_rotate", (@convention(c) (Bool) -> Void).self)
    lazy var shake = sym("qemu_ios_ui_shake", VoidFn.self)
    lazy var attitude = sym("qemu_ios_ui_attitude", (@convention(c) (Double, Double, Int32) -> Void).self)
    lazy var paste = sym("qemu_ios_ui_paste", (@convention(c) (UnsafePointer<CChar>) -> Void).self)
    lazy var battery = sym("qemu_ios_ui_battery", (@convention(c) (Int32, Int32) -> Bool).self)
    lazy var usbConnection = sym("qemu_ios_ui_usb_connection", (@convention(c) (Bool) -> Bool).self)
    lazy var compass = sym("qemu_ios_ui_compass", (@convention(c) (Int32) -> Bool).self)
    lazy var usbCharger = sym("qemu_ios_ui_usb_charger", (@convention(c) (Bool) -> Bool).self)
    lazy var orientation = sym("qemu_ios_ui_orientation", (@convention(c) (Int32) -> Bool).self)
    lazy var pause = sym("qemu_ios_ui_pause", VoidFn.self)
    lazy var resume = sym("qemu_ios_ui_resume", VoidFn.self)
    lazy var reset = sym("qemu_ios_ui_reset", VoidFn.self)
    lazy var powerdown = sym("qemu_ios_ui_powerdown", VoidFn.self)
    lazy var quit = sym("qemu_ios_ui_quit", VoidFn.self)
    lazy var snapshotSave2 = sym("qemu_ios_snapshot_save2", (@convention(c) (UnsafePointer<CChar>) -> Void).self)
    lazy var snapshotStatus = sym("qemu_ios_snapshot_status", (@convention(c) (UnsafeMutablePointer<CChar>, UInt) -> Int32).self)
    lazy var snapshotResume = sym("qemu_ios_snapshot_resume", VoidFn.self)
    lazy var agentRequest = sym("qemu_ios_agent_request", (@convention(c) (UnsafePointer<CChar>) -> Bool).self)
    lazy var agentCancel = sym("qemu_ios_agent_cancel", (@convention(c) (UnsafePointer<CChar>) -> Void).self)
    lazy var agentResult = sym("qemu_ios_agent_result", (@convention(c) () -> UnsafeMutablePointer<CChar>?).self)
    lazy var agentFreeResult = sym("qemu_ios_agent_free_result", (@convention(c) (UnsafeMutablePointer<CChar>?) -> Void).self)
    lazy var agentStatus = sym("qemu_ios_agent_status", IntFn.self)
    lazy var glesContexts = sym("qemu_ios_gles_contexts", IntFn.self)
    lazy var buildID = optionalSym("qemu_ios_build_id", (@convention(c) () -> UnsafePointer<CChar>?).self)
    lazy var audioStart = sym("qemu_ios_audio_capture_start", (@convention(c) () -> UInt64).self)
    lazy var audioRead = sym("qemu_ios_audio_capture_read", (@convention(c) (UInt64, UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<Double>?) -> Int32).self)
    lazy var audioStop = sym("qemu_ios_audio_capture_stop", (@convention(c) (UInt64) -> Void).self)

    func info(machine: String) -> DeviceInfo? {
        guard let raw = machine.withCString({ deviceInfo($0) }) else { return nil }
        let c = raw.load(as: QemuDeviceInfoC.self)
        return DeviceInfo(machine: c.machine.map { String(cString: $0) } ?? machine,
                          screenWidth: Int(c.screenWidth), screenHeight: Int(c.screenHeight),
                          screenScale: Int(c.screenScale), defaultOrientation: Int(c.defaultOrientation),
                          hasCellular: c.hasCellular)
    }

    var modified: Double {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
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
