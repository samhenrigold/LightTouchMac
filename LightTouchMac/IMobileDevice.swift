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
    /// lockdownd_get_value(client, domain, key, &value)
    typealias LockdownGetValue = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?,
                                                UnsafePointer<CChar>?,
                                                UnsafeMutablePointer<OpaquePointer?>) -> Int32
    /// lockdownd_set_value(client, domain, key, value) — takes OWNERSHIP of
    /// value and frees it; do not plist_free after a set.
    typealias LockdownSetValue = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?,
                                                UnsafePointer<CChar>?, OpaquePointer?) -> Int32
    typealias PlistNewString = @convention(c) (UnsafePointer<CChar>?) -> OpaquePointer?
    typealias PlistFree = @convention(c) (OpaquePointer?) -> Void
    typealias MemFree = @convention(c) (UnsafeMutableRawPointer?) -> Void

    static let idevice_new = symbol("idevice_new", NewDevice.self)
    static let idevice_free = symbol("idevice_free", FreeHandle.self)
    static let lockdownd_client_new_with_handshake = symbol("lockdownd_client_new_with_handshake", NewClient.self)
    static let lockdownd_client_free = symbol("lockdownd_client_free", FreeHandle.self)
    static let lockdownd_start_service = symbol("lockdownd_start_service", StartService.self)
    static let lockdownd_get_value = symbol("lockdownd_get_value", LockdownGetValue.self)
    static let lockdownd_set_value = symbol("lockdownd_set_value", LockdownSetValue.self)
    static let plist_new_string = symbol("plist_new_string", PlistNewString.self)
    static let lockdownd_service_descriptor_free = symbol("lockdownd_service_descriptor_free", FreeHandle.self)
    static let sbservices_client_new = symbol("sbservices_client_new", NewServiceClient.self)
    static let sbservices_client_free = symbol("sbservices_client_free", FreeHandle.self)
    static let sbservices_get_icon_state = symbol("sbservices_get_icon_state", GetIconState.self)
    static let sbservices_set_icon_state = symbol("sbservices_set_icon_state", SetIconState.self)
    static let plist_to_xml = symbol("plist_to_xml", PlistToXML.self)
    static let plist_from_xml = symbol("plist_from_xml", PlistFromXML.self)
    static let plist_free = symbol("plist_free", PlistFree.self)
    static let plist_mem_free = symbol("plist_mem_free", MemFree.self)

    // MARK: - installation_proxy / afc / notification_proxy
    //
    // The device operations that used to shell out to ideviceinstaller and a
    // 579-line install script. Client handles are opaque pointers; option
    // dictionaries and browse results are plist_t, built and read through the
    // XML bridge already used above (plist_from_xml / plist_to_xml) — which
    // also sidesteps libimobiledevice's variadic option builders, uncallable
    // through a function pointer.

    /// idevice + label -> client. instproxy/afc/np all share this shape; each
    /// does its own lockdown handshake + start_service internally.
    typealias StartService2 = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>, UnsafePointer<CChar>?) -> Int32
    typealias Browse = @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>) -> Int32
    /// (command, status, user_data) — fired on a library thread during install.
    typealias InstproxyStatusCB = @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void
    /// install(pkg_path,…) and uninstall(appid,…) share this signature.
    typealias InstproxyOp = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, OpaquePointer?, InstproxyStatusCB?, UnsafeMutableRawPointer?) -> Int32
    typealias StatusGetName = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Void
    typealias StatusGetPercent = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int32>) -> Void
    typealias StatusGetError = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UInt64>?) -> Int32

    typealias AfcOpen = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UInt32, UnsafeMutablePointer<UInt64>) -> Int32
    typealias AfcWrite = @convention(c) (OpaquePointer?, UInt64, UnsafePointer<CChar>?, UInt32, UnsafeMutablePointer<UInt32>) -> Int32
    typealias AfcClose = @convention(c) (OpaquePointer?, UInt64) -> Int32
    typealias AfcPath = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
    typealias AfcInfoKey = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    /// afc_read_directory(client, path, &list) — a NULL-terminated char* array.
    typealias AfcReadDir = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?,
                                          UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>) -> Int32
    typealias AfcDictFree = @convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32

    typealias NpNotifyCB = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
    typealias NpObserve = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
    typealias NpSetCB = @convention(c) (OpaquePointer?, NpNotifyCB?, UnsafeMutableRawPointer?) -> Int32

    static let instproxy_client_start_service = symbol("instproxy_client_start_service", StartService2.self)
    static let instproxy_client_free = symbol("instproxy_client_free", FreeHandle.self)
    static let instproxy_browse = symbol("instproxy_browse", Browse.self)
    static let instproxy_install = symbol("instproxy_install", InstproxyOp.self)
    static let instproxy_uninstall = symbol("instproxy_uninstall", InstproxyOp.self)
    static let instproxy_status_get_name = symbol("instproxy_status_get_name", StatusGetName.self)
    static let instproxy_status_get_percent_complete = symbol("instproxy_status_get_percent_complete", StatusGetPercent.self)
    static let instproxy_status_get_error = symbol("instproxy_status_get_error", StatusGetError.self)

    static let afc_client_start_service = symbol("afc_client_start_service", StartService2.self)
    static let afc_client_free = symbol("afc_client_free", FreeHandle.self)
    static let afc_file_open = symbol("afc_file_open", AfcOpen.self)
    static let afc_file_write = symbol("afc_file_write", AfcWrite.self)
    static let afc_file_close = symbol("afc_file_close", AfcClose.self)
    static let afc_make_directory = symbol("afc_make_directory", AfcPath.self)
    static let afc_remove_path = symbol("afc_remove_path", AfcPath.self)
    static let afc_get_device_info_key = symbol("afc_get_device_info_key", AfcInfoKey.self)
    static let afc_read_directory = symbol("afc_read_directory", AfcReadDir.self)
    static let afc_dictionary_free = symbol("afc_dictionary_free", AfcDictFree.self)

    static let np_client_start_service = symbol("np_client_start_service", StartService2.self)
    static let np_client_free = symbol("np_client_free", FreeHandle.self)
    static let np_observe_notification = symbol("np_observe_notification", NpObserve.self)
    static let np_set_notify_callback = symbol("np_set_notify_callback", NpSetCB.self)

    /// AFC_FOPEN_WRONLY: w — O_WRONLY | O_CREAT | O_TRUNC.
    static let afcWriteMode: UInt32 = 3

    // MARK: - plist ↔ Foundation (via the XML both sides speak)

    /// plist_t → Foundation. nil on any failure.
    static func decode(_ node: OpaquePointer) -> Any? {
        var xml: UnsafeMutablePointer<CChar>?
        var length: UInt32 = 0
        plist_to_xml?(node, &xml, &length)
        guard let xml else { return nil }
        defer { plist_mem_free?(xml) }
        let data = Data(bytes: xml, count: Int(length))
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    /// Foundation → plist_t. The caller owns the result and must plist_free it.
    static func encode(_ value: Any) -> OpaquePointer? {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: value,
                                                             format: .xml, options: 0) else { return nil }
        var node: OpaquePointer?
        _ = data.withUnsafeBytes { buffer in
            plist_from_xml?(buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                            UInt32(buffer.count), &node)
        }
        return node
    }

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
        // FALSE, not true. Answering "yes" with no library made the poll believe
        // the device was up and call through every tick, so a permanent,
        // host-side, user-fixable condition rendered as "Waiting for the
        // device…" forever.
        guard let idevice_new else { return false }
        setenv("USBMUXD_SOCKET_ADDRESS", socket, 1)
        var device: OpaquePointer?
        guard idevice_new(&device, nil) == success, let device else { return false }
        _ = idevice_free?(device)
        return true
    }
}
