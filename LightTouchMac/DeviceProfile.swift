// Which emulated device this process runs.
//
// One per process for now (docs/device-library-architecture.md moves each
// device into its own helper later), chosen by LIGHTTOUCH_DEVICE=ipad1 and
// defaulting to the iPod so nothing changes for it. Screen geometry and art
// live in DeviceProfile+Display.swift, which needs the dylib; this file does
// not, so any source that only needs the name can use it.

import Foundation

nonisolated enum DeviceProfile: Equatable {
    case iPodTouch2G
    case iPad1

    static let current: DeviceProfile =
        ProcessInfo.processInfo.environment["LIGHTTOUCH_DEVICE"] == "ipad1" ? .iPad1 : .iPodTouch2G

    /// The name passed to -M; also the key for qemu_ios_device_info().
    var machineName: String { self == .iPad1 ? "ipad1" : "iPod-Touch" }
    var displayName: String { self == .iPad1 ? "iPad" : "iPod touch" }
    /// What the device is called in menus, titles and messages ("the iPod").
    var shortName: String { self == .iPad1 ? "iPad" : "iPod" }
}
