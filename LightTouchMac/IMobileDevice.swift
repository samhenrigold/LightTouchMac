// Created by Sam on 2026-08-05.
//
// The handful of libimobiledevice entry points SpringBoardIcons needs, looked
// up at runtime instead of linked.
//
// Linking them would be less code, and that is how this started — but Homebrew
// builds its dylibs for whatever macOS the machine is running (26 here), and a
// binary that hard-links one cannot launch below that version at all. This app
// deploys to macOS 14, so the whole app would be gated on the build machine's
// OS for the sake of one optional feature: reading and writing the home
// screen's icon layout, which is the one device operation with no CLI to shell
// out to. Loaded this way it is genuinely optional — no library, no reordering,
// and the sidebar falls back to sorting by name.
//
// Handles are OpaquePointer rather than the library's typedefs for the same
// reason: no headers means no build settings, no search paths, and nothing for
// the deployment target to disagree with.

import Foundation

/// Nonisolated: the project defaults to MainActor isolation, and every one of
/// these is called from the detached task that does the blocking device work.
nonisolated enum IMobileDevice {

    /// All the error enums in these libraries agree that zero is success.
    static let success: Int32 = 0

    static var isAvailable: Bool { handles.isEmpty == false && idevice_new != nil }

    // MARK: - Loading

    /// Contents/Frameworks first, so a packaged app uses the dylibs shipped
    /// beside it and needs no Homebrew at all; then the two places Homebrew
    /// installs, which is what a dev build finds. dlsym searches a handle's own
    /// dependencies too, so libplist's symbols normally resolve through
    /// libimobiledevice — it is opened as well only for the case where it does
    /// not (a static libplist, say).
    private static let handles: [UnsafeMutableRawPointer] = {
        let names = ["libimobiledevice-1.0.dylib", "libplist-2.0.dylib"]
        let directories = [Bundled.frameworksDirectory, "/opt/homebrew/lib", "/usr/local/lib"]
            .compactMap { $0 }
        return names.compactMap { name in
            directories.lazy
                .compactMap { dlopen("\($0)/\(name)", RTLD_LAZY) }
                .first
        }
    }()

    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        for handle in handles where dlsym(handle, name) != nil {
            return unsafeBitCast(dlsym(handle, name)!, to: type)
        }
        return nil
    }

    // MARK: - Entry points
    //
    // Every handle is an opaque pointer and every call returns the library's
    // error code, so the signatures stay this dull on purpose.

    typealias NewDevice = @convention(c) (UnsafeMutablePointer<OpaquePointer?>, UnsafePointer<CChar>?) -> Int32
    typealias FreeHandle = @convention(c) (OpaquePointer?) -> Int32
    typealias NewClient = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>, UnsafePointer<CChar>?) -> Int32
    typealias StartService = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>) -> Int32
    typealias NewServiceClient = @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>) -> Int32
    typealias GetIconState = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>, UnsafePointer<CChar>?) -> Int32
    typealias SetIconState = @convention(c) (OpaquePointer?, OpaquePointer?) -> Int32
    typealias PlistToXML = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UInt32>) -> Void
    typealias PlistFromXML = @convention(c) (UnsafePointer<CChar>?, UInt32, UnsafeMutablePointer<OpaquePointer?>) -> Int32
    typealias PlistFree = @convention(c) (OpaquePointer?) -> Void
    typealias MemFree = @convention(c) (UnsafeMutableRawPointer?) -> Void

    static let idevice_new = symbol("idevice_new", NewDevice.self)
    static let idevice_free = symbol("idevice_free", FreeHandle.self)
    static let lockdownd_client_new_with_handshake = symbol("lockdownd_client_new_with_handshake", NewClient.self)
    static let lockdownd_client_free = symbol("lockdownd_client_free", FreeHandle.self)
    static let lockdownd_start_service = symbol("lockdownd_start_service", StartService.self)
    static let lockdownd_service_descriptor_free = symbol("lockdownd_service_descriptor_free", FreeHandle.self)
    static let sbservices_client_new = symbol("sbservices_client_new", NewServiceClient.self)
    static let sbservices_client_free = symbol("sbservices_client_free", FreeHandle.self)
    static let sbservices_get_icon_state = symbol("sbservices_get_icon_state", GetIconState.self)
    static let sbservices_set_icon_state = symbol("sbservices_set_icon_state", SetIconState.self)
    static let plist_to_xml = symbol("plist_to_xml", PlistToXML.self)
    static let plist_from_xml = symbol("plist_from_xml", PlistFromXML.self)
    static let plist_free = symbol("plist_free", PlistFree.self)
    static let plist_mem_free = symbol("plist_mem_free", MemFree.self)

    // MARK: - Readiness probe

    /// Has the guest attached to this usbmuxd? One in-process round trip to
    /// our own daemon, over in milliseconds — the cheap question to ask before
    /// spawning any of the CLI tools, whose failures each cost a process
    /// launch and their own connect timeout.
    ///
    /// Deliberately NOT a lockdownd handshake: while the guest is still
    /// settling, a handshake can fail — or block, it has no timeout — long
    /// after the tools this gates would already have succeeded, which turned
    /// the gate into the bottleneck. Attachment is the gate; lockdown errors
    /// are the tools' own to report and retry. Blocking; call off the main
    /// actor. Without the library there is nothing to probe with, so answer
    /// yes and fall through to the tools.
    static func deviceReady(socket: String) -> Bool {
        guard let idevice_new else { return true }
        setenv("USBMUXD_SOCKET_ADDRESS", socket, 1)
        var device: OpaquePointer?
        guard idevice_new(&device, nil) == success, let device else { return false }
        _ = idevice_free?(device)
        return true
    }
}
