// A libimobiledevice of the tests' own, for checks that compile the services engine (LIGHTTOUCH_SERVICES, with
// LightTouchServices/Lockdown/Lockdown.h as the bridging header for the real C API): every entry point the engine
// calls, defined here (@_cdecl, so the engine's direct calls link to it) to run IMDFake's closures. A check sets the
// closures it exercises; the rest answer an error, so an unexpected call fails rather than reaching a device.

import Foundation

nonisolated enum IMDFake {
    nonisolated(unsafe) static var ideviceNew:
        (UnsafeMutablePointer<idevice_t?>?, UnsafePointer<CChar>?) -> idevice_error_t = { _, _ in IDEVICE_E_NO_DEVICE }
    nonisolated(unsafe) static var ideviceFree: (idevice_t?) -> idevice_error_t = { _ in IDEVICE_E_SUCCESS }
    /// The lockdown session and the service descriptor every client takes (IMobileDevice.startService).
    nonisolated(unsafe) static var lockdownHandshake:
        (idevice_t?, UnsafeMutablePointer<lockdownd_client_t?>?, UnsafePointer<CChar>?) -> lockdownd_error_t = {
            _,
            client,
            _ in
            client?.pointee = OpaquePointer(bitPattern: 0x10)
            return LOCKDOWN_E_SUCCESS
        }
    nonisolated(unsafe) static var lockdownFree: (lockdownd_client_t?) -> lockdownd_error_t = { _ in LOCKDOWN_E_SUCCESS
    }
    nonisolated(unsafe) static var lockdownStartService:
        (lockdownd_client_t?, UnsafePointer<CChar>?, UnsafeMutablePointer<lockdownd_service_descriptor_t?>?) ->
            lockdownd_error_t = { _, _, service in
                service?.pointee = UnsafeMutablePointer(bitPattern: 0x20)
                return LOCKDOWN_E_SUCCESS
            }
    nonisolated(unsafe) static var lockdownDescriptorFree: (lockdownd_service_descriptor_t?) -> lockdownd_error_t = {
        _ in LOCKDOWN_E_SUCCESS
    }
    nonisolated(unsafe) static var lockdownGetValue:
        (lockdownd_client_t?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutablePointer<plist_t?>?) ->
            lockdownd_error_t = { _, _, _, _ in LOCKDOWN_E_UNKNOWN_ERROR }

    nonisolated(unsafe) static var afcClientNew:
        (idevice_t?, lockdownd_service_descriptor_t?, UnsafeMutablePointer<afc_client_t?>?) -> afc_error_t = {
            _,
            _,
            _ in AFC_E_UNKNOWN_ERROR
        }
    nonisolated(unsafe) static var afcClientFree: (afc_client_t?) -> afc_error_t = { _ in AFC_E_SUCCESS }
    nonisolated(unsafe) static var afcDeviceInfoKey:
        (afc_client_t?, UnsafePointer<CChar>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> afc_error_t = {
            _,
            _,
            _ in AFC_E_UNKNOWN_ERROR
        }
    nonisolated(unsafe) static var afcFileOpen:
        (afc_client_t?, UnsafePointer<CChar>?, afc_file_mode_t, UnsafeMutablePointer<UInt64>?) -> afc_error_t = {
            _,
            _,
            _,
            _ in AFC_E_UNKNOWN_ERROR
        }
    nonisolated(unsafe) static var afcFileRead:
        (afc_client_t?, UInt64, UnsafeMutablePointer<CChar>?, UInt32, UnsafeMutablePointer<UInt32>?) -> afc_error_t = {
            _,
            _,
            _,
            _,
            _ in AFC_E_UNKNOWN_ERROR
        }
    nonisolated(unsafe) static var afcFileWrite:
        (afc_client_t?, UInt64, UnsafePointer<CChar>?, UInt32, UnsafeMutablePointer<UInt32>?) -> afc_error_t = {
            _,
            _,
            _,
            _,
            _ in AFC_E_UNKNOWN_ERROR
        }
    nonisolated(unsafe) static var afcFileClose: (afc_client_t?, UInt64) -> afc_error_t = { _, _ in AFC_E_SUCCESS }
    nonisolated(unsafe) static var afcMakeDirectory: (afc_client_t?, UnsafePointer<CChar>?) -> afc_error_t = { _, _ in
        AFC_E_UNKNOWN_ERROR
    }
    nonisolated(unsafe) static var afcRemovePath: (afc_client_t?, UnsafePointer<CChar>?) -> afc_error_t = { _, _ in
        AFC_E_UNKNOWN_ERROR
    }
    nonisolated(unsafe) static var afcRenamePath:
        (afc_client_t?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> afc_error_t = { _, _, _ in AFC_E_UNKNOWN_ERROR
        }
    nonisolated(unsafe) static var afcReadDirectory:
        (
            afc_client_t?, UnsafePointer<CChar>?,
            UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>?
        ) -> afc_error_t = { _, _, _ in AFC_E_UNKNOWN_ERROR }
    nonisolated(unsafe) static var afcFileInfo:
        (
            afc_client_t?, UnsafePointer<CChar>?,
            UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>?
        ) -> afc_error_t = { _, _, _ in AFC_E_UNKNOWN_ERROR }
    nonisolated(unsafe) static var afcDictionaryFree:
        (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> afc_error_t = { _ in AFC_E_SUCCESS }

    /// The raw service client crashreportmover's ping is read through (DeviceServices.crashReports).
    nonisolated(unsafe) static var serviceClientNew:
        (idevice_t?, lockdownd_service_descriptor_t?, UnsafeMutablePointer<service_client_t?>?) -> service_error_t = {
            _,
            _,
            _ in SERVICE_E_UNKNOWN_ERROR
        }
    nonisolated(unsafe) static var serviceClientFree: (service_client_t?) -> service_error_t = { _ in SERVICE_E_SUCCESS
    }
    nonisolated(unsafe) static var serviceReceive:
        (service_client_t?, UnsafeMutablePointer<CChar>?, UInt32, UnsafeMutablePointer<UInt32>?, UInt32) ->
            service_error_t = { _, _, _, _, _ in SERVICE_E_UNKNOWN_ERROR }

    /// CrashReportCopy's DeviceLink client: what the host sends, and what the device answers in turn.
    nonisolated(unsafe) static var plistServiceNew:
        (idevice_t?, lockdownd_service_descriptor_t?, UnsafeMutablePointer<property_list_service_client_t?>?) ->
            property_list_service_error_t = { _, _, _ in PROPERTY_LIST_SERVICE_E_UNKNOWN_ERROR }
    nonisolated(unsafe) static var plistServiceSend:
        (property_list_service_client_t?, plist_t?) ->
            property_list_service_error_t = { _, _ in PROPERTY_LIST_SERVICE_E_UNKNOWN_ERROR }
    nonisolated(unsafe) static var plistServiceReceive:
        (property_list_service_client_t?, UnsafeMutablePointer<plist_t?>?, UInt32) -> property_list_service_error_t = {
            _, _, _ in PROPERTY_LIST_SERVICE_E_UNKNOWN_ERROR
        }

    nonisolated(unsafe) static var houseArrestClientNew:
        (idevice_t?, lockdownd_service_descriptor_t?, UnsafeMutablePointer<house_arrest_client_t?>?) ->
            house_arrest_error_t = { _, _, _ in HOUSE_ARREST_E_UNKNOWN_ERROR }
    nonisolated(unsafe) static var houseArrestClientFree: (house_arrest_client_t?) -> house_arrest_error_t = { _ in
        HOUSE_ARREST_E_SUCCESS
    }
    nonisolated(unsafe) static var houseArrestSendCommand:
        (house_arrest_client_t?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> house_arrest_error_t = { _, _, _ in
            HOUSE_ARREST_E_UNKNOWN_ERROR
        }
    nonisolated(unsafe) static var houseArrestGetResult:
        (house_arrest_client_t?, UnsafeMutablePointer<plist_t?>?) -> house_arrest_error_t = { _, _ in
            HOUSE_ARREST_E_UNKNOWN_ERROR
        }
    nonisolated(unsafe) static var afcClientFromHouseArrest:
        (house_arrest_client_t?, UnsafeMutablePointer<afc_client_t?>?) -> afc_error_t = { _, _ in AFC_E_UNKNOWN_ERROR }

    nonisolated(unsafe) static var instproxyClientNew:
        (idevice_t?, lockdownd_service_descriptor_t?, UnsafeMutablePointer<instproxy_client_t?>?) -> instproxy_error_t =
            { _, _, _ in INSTPROXY_E_UNKNOWN_ERROR }
    nonisolated(unsafe) static var instproxyClientFree: (instproxy_client_t?) -> instproxy_error_t = { _ in
        INSTPROXY_E_SUCCESS
    }
    nonisolated(unsafe) static var instproxyBrowse:
        (instproxy_client_t?, plist_t?, UnsafeMutablePointer<plist_t?>?) -> instproxy_error_t = { _, _, _ in
            INSTPROXY_E_UNKNOWN_ERROR
        }
    nonisolated(unsafe) static var instproxyLookupArchives:
        (instproxy_client_t?, plist_t?, UnsafeMutablePointer<plist_t?>?) -> instproxy_error_t = { _, _, _ in
            INSTPROXY_E_UNKNOWN_ERROR
        }
    /// install, archive, restore and uninstall: the command's name first.
    nonisolated(unsafe) static var instproxyCommand:
        (String, instproxy_client_t?, UnsafePointer<CChar>?, plist_t?, instproxy_status_cb_t?, UnsafeMutableRawPointer?)
            -> instproxy_error_t = { _, _, _, _, _, _ in INSTPROXY_E_UNKNOWN_ERROR }
    nonisolated(unsafe) static var instproxyStatusError:
        (
            plist_t?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UInt64>?
        ) -> instproxy_error_t = { _, _, _, _ in INSTPROXY_E_SUCCESS }
    nonisolated(unsafe) static var instproxyStatusName:
        (plist_t?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void = { _, _ in }
    nonisolated(unsafe) static var instproxyStatusPercent: (plist_t?, UnsafeMutablePointer<Int32>?) -> Void = { _, _ in
    }

    nonisolated(unsafe) static var npStart:
        (idevice_t?, UnsafeMutablePointer<np_client_t?>?, UnsafePointer<CChar>?) -> np_error_t = { _, _, _ in
            NP_E_UNKNOWN_ERROR
        }
    nonisolated(unsafe) static var npFree: (np_client_t?) -> np_error_t = { _ in NP_E_SUCCESS }
    nonisolated(unsafe) static var npObserve: (np_client_t?, UnsafePointer<CChar>?) -> np_error_t = { _, _ in
        NP_E_UNKNOWN_ERROR
    }
    nonisolated(unsafe) static var npSetCallback:
        (np_client_t?, np_notify_cb_t?, UnsafeMutableRawPointer?) -> np_error_t = { _, _, _ in NP_E_UNKNOWN_ERROR }

    nonisolated(unsafe) static var sbClientNew:
        (idevice_t?, lockdownd_service_descriptor_t?, UnsafeMutablePointer<sbservices_client_t?>?) -> sbservices_error_t =
            { _, _, _ in SBSERVICES_E_UNKNOWN_ERROR }
    nonisolated(unsafe) static var sbClientFree: (sbservices_client_t?) -> sbservices_error_t = { _ in
        SBSERVICES_E_SUCCESS
    }
    nonisolated(unsafe) static var sbGetIconState:
        (sbservices_client_t?, UnsafeMutablePointer<plist_t?>?, UnsafePointer<CChar>?) -> sbservices_error_t = {
            _,
            _,
            _ in SBSERVICES_E_UNKNOWN_ERROR
        }
    nonisolated(unsafe) static var sbSetIconState: (sbservices_client_t?, plist_t?) -> sbservices_error_t = { _, _ in
        SBSERVICES_E_UNKNOWN_ERROR
    }
    nonisolated(unsafe) static var sbOrientation:
        (sbservices_client_t?, UnsafeMutablePointer<sbservices_interface_orientation_t>?) -> sbservices_error_t = {
            _,
            _ in SBSERVICES_E_UNKNOWN_ERROR
        }

    /// plist_t, as Foundation objects behind an opaque box: plist_from_xml parses, plist_to_xml serializes.
    final class Node {
        let value: Any
        init(_ value: Any) { self.value = value }
        /// An array's items or a dictionary's entries (keys sorted), each a node of its own, as libplist's tree has
        /// them; made once, on the first walk (IMobileDevice.withinLimits), and freed with this node.
        lazy var children: [(key: String?, node: Node)] = {
            if let array = value as? [Any] { return array.map { (nil, Node($0)) } }
            if let dict = value as? [String: Any] { return dict.keys.sorted().map { ($0, Node(dict[$0]!)) } }
            return []
        }()
        var bytes: Data? {
            if let string = value as? String { return Data(string.utf8) }
            return value as? Data
        }
    }
    static func node(_ value: Any) -> plist_t { Unmanaged.passRetained(Node(value)).toOpaque() }
    static func value(_ node: plist_t?) -> Any? {
        node.map { Unmanaged<Node>.fromOpaque($0).takeUnretainedValue().value }
    }
}

@_cdecl("idevice_new") nonisolated func fakeIdeviceNew(
    _ d: UnsafeMutablePointer<idevice_t?>?,
    _ u: UnsafePointer<CChar>?
) -> idevice_error_t { IMDFake.ideviceNew(d, u) }
@_cdecl("idevice_free") nonisolated func fakeIdeviceFree(_ d: idevice_t?) -> idevice_error_t { IMDFake.ideviceFree(d) }
@_cdecl("lockdownd_client_new_with_handshake") nonisolated func fakeLockdownHandshake(
    _ d: idevice_t?,
    _ c: UnsafeMutablePointer<lockdownd_client_t?>?,
    _ l: UnsafePointer<CChar>?
) -> lockdownd_error_t { IMDFake.lockdownHandshake(d, c, l) }
@_cdecl("lockdownd_client_free") nonisolated func fakeLockdownFree(_ c: lockdownd_client_t?) -> lockdownd_error_t {
    IMDFake.lockdownFree(c)
}
@_cdecl("lockdownd_start_service") nonisolated func fakeLockdownStartService(
    _ c: lockdownd_client_t?,
    _ n: UnsafePointer<CChar>?,
    _ s: UnsafeMutablePointer<lockdownd_service_descriptor_t?>?
) -> lockdownd_error_t { IMDFake.lockdownStartService(c, n, s) }
@_cdecl("lockdownd_service_descriptor_free") nonisolated func fakeLockdownDescriptorFree(
    _ s: lockdownd_service_descriptor_t?
) -> lockdownd_error_t { IMDFake.lockdownDescriptorFree(s) }
@_cdecl("lockdownd_get_value") nonisolated func fakeLockdownGetValue(
    _ c: lockdownd_client_t?,
    _ d: UnsafePointer<CChar>?,
    _ k: UnsafePointer<CChar>?,
    _ v: UnsafeMutablePointer<plist_t?>?
) -> lockdownd_error_t { IMDFake.lockdownGetValue(c, d, k, v) }

@_cdecl("afc_client_new") nonisolated func fakeAfcClientNew(
    _ d: idevice_t?,
    _ s: lockdownd_service_descriptor_t?,
    _ c: UnsafeMutablePointer<afc_client_t?>?
) -> afc_error_t { IMDFake.afcClientNew(d, s, c) }
@_cdecl("afc_client_free") nonisolated func fakeAfcClientFree(_ c: afc_client_t?) -> afc_error_t {
    IMDFake.afcClientFree(c)
}
@_cdecl("afc_get_device_info_key") nonisolated func fakeAfcDeviceInfoKey(
    _ c: afc_client_t?,
    _ k: UnsafePointer<CChar>?,
    _ v: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> afc_error_t { IMDFake.afcDeviceInfoKey(c, k, v) }
@_cdecl("afc_file_open") nonisolated func fakeAfcFileOpen(
    _ c: afc_client_t?,
    _ p: UnsafePointer<CChar>?,
    _ m: afc_file_mode_t,
    _ h: UnsafeMutablePointer<UInt64>?
) -> afc_error_t { IMDFake.afcFileOpen(c, p, m, h) }
@_cdecl("afc_file_read") nonisolated func fakeAfcFileRead(
    _ c: afc_client_t?,
    _ h: UInt64,
    _ b: UnsafeMutablePointer<CChar>?,
    _ n: UInt32,
    _ r: UnsafeMutablePointer<UInt32>?
) -> afc_error_t { IMDFake.afcFileRead(c, h, b, n, r) }
@_cdecl("afc_file_write") nonisolated func fakeAfcFileWrite(
    _ c: afc_client_t?,
    _ h: UInt64,
    _ b: UnsafePointer<CChar>?,
    _ n: UInt32,
    _ w: UnsafeMutablePointer<UInt32>?
) -> afc_error_t { IMDFake.afcFileWrite(c, h, b, n, w) }
@_cdecl("afc_file_close") nonisolated func fakeAfcFileClose(_ c: afc_client_t?, _ h: UInt64) -> afc_error_t {
    IMDFake.afcFileClose(c, h)
}
@_cdecl("afc_make_directory") nonisolated func fakeAfcMakeDirectory(_ c: afc_client_t?, _ p: UnsafePointer<CChar>?)
    -> afc_error_t
{ IMDFake.afcMakeDirectory(c, p) }
@_cdecl("afc_remove_path") nonisolated func fakeAfcRemovePath(_ c: afc_client_t?, _ p: UnsafePointer<CChar>?)
    -> afc_error_t
{ IMDFake.afcRemovePath(c, p) }
@_cdecl("afc_rename_path") nonisolated func fakeAfcRenamePath(
    _ c: afc_client_t?,
    _ f: UnsafePointer<CChar>?,
    _ t: UnsafePointer<CChar>?
) -> afc_error_t { IMDFake.afcRenamePath(c, f, t) }
@_cdecl("afc_read_directory") nonisolated func fakeAfcReadDirectory(
    _ c: afc_client_t?,
    _ p: UnsafePointer<CChar>?,
    _ l: UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>?
) -> afc_error_t { IMDFake.afcReadDirectory(c, p, l) }
@_cdecl("afc_get_file_info") nonisolated func fakeAfcFileInfo(
    _ c: afc_client_t?,
    _ p: UnsafePointer<CChar>?,
    _ l: UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>?
) -> afc_error_t { IMDFake.afcFileInfo(c, p, l) }
@_cdecl("afc_dictionary_free") nonisolated func fakeAfcDictionaryFree(
    _ d: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> afc_error_t { IMDFake.afcDictionaryFree(d) }

@_cdecl("service_client_new") nonisolated func fakeServiceClientNew(
    _ d: idevice_t?,
    _ s: lockdownd_service_descriptor_t?,
    _ c: UnsafeMutablePointer<service_client_t?>?
) -> service_error_t { IMDFake.serviceClientNew(d, s, c) }
@_cdecl("service_client_free") nonisolated func fakeServiceClientFree(_ c: service_client_t?) -> service_error_t {
    IMDFake.serviceClientFree(c)
}
@_cdecl("service_receive_with_timeout") nonisolated func fakeServiceReceive(
    _ c: service_client_t?,
    _ data: UnsafeMutablePointer<CChar>?,
    _ size: UInt32,
    _ received: UnsafeMutablePointer<UInt32>?,
    _ timeout: UInt32
) -> service_error_t { IMDFake.serviceReceive(c, data, size, received, timeout) }
@_cdecl("property_list_service_client_new") nonisolated func fakePlistServiceNew(
    _ d: idevice_t?,
    _ s: lockdownd_service_descriptor_t?,
    _ c: UnsafeMutablePointer<property_list_service_client_t?>?
) -> property_list_service_error_t { IMDFake.plistServiceNew(d, s, c) }
@_cdecl("property_list_service_client_free") nonisolated func fakePlistServiceFree(
    _ c: property_list_service_client_t?
) -> property_list_service_error_t { PROPERTY_LIST_SERVICE_E_SUCCESS }
@_cdecl("property_list_service_send_binary_plist") nonisolated func fakePlistServiceSend(
    _ c: property_list_service_client_t?,
    _ p: plist_t?
) -> property_list_service_error_t { IMDFake.plistServiceSend(c, p) }
@_cdecl("property_list_service_receive_plist_with_timeout") nonisolated func fakePlistServiceReceive(
    _ c: property_list_service_client_t?,
    _ p: UnsafeMutablePointer<plist_t?>?,
    _ timeout: UInt32
) -> property_list_service_error_t { IMDFake.plistServiceReceive(c, p, timeout) }

@_cdecl("house_arrest_client_new") nonisolated func fakeHouseArrestClientNew(
    _ d: idevice_t?,
    _ s: lockdownd_service_descriptor_t?,
    _ c: UnsafeMutablePointer<house_arrest_client_t?>?
) -> house_arrest_error_t { IMDFake.houseArrestClientNew(d, s, c) }
@_cdecl("house_arrest_client_free") nonisolated func fakeHouseArrestClientFree(_ c: house_arrest_client_t?)
    -> house_arrest_error_t
{ IMDFake.houseArrestClientFree(c) }
@_cdecl("house_arrest_send_command") nonisolated func fakeHouseArrestSendCommand(
    _ c: house_arrest_client_t?,
    _ command: UnsafePointer<CChar>?,
    _ id: UnsafePointer<CChar>?
) -> house_arrest_error_t { IMDFake.houseArrestSendCommand(c, command, id) }
@_cdecl("house_arrest_get_result") nonisolated func fakeHouseArrestGetResult(
    _ c: house_arrest_client_t?,
    _ p: UnsafeMutablePointer<plist_t?>?
) -> house_arrest_error_t { IMDFake.houseArrestGetResult(c, p) }
@_cdecl("afc_client_new_from_house_arrest_client") nonisolated func fakeAfcFromHouseArrest(
    _ c: house_arrest_client_t?,
    _ a: UnsafeMutablePointer<afc_client_t?>?
) -> afc_error_t { IMDFake.afcClientFromHouseArrest(c, a) }
@_cdecl("instproxy_client_new") nonisolated func fakeInstproxyClientNew(
    _ d: idevice_t?,
    _ s: lockdownd_service_descriptor_t?,
    _ c: UnsafeMutablePointer<instproxy_client_t?>?
) -> instproxy_error_t { IMDFake.instproxyClientNew(d, s, c) }
@_cdecl("instproxy_client_free") nonisolated func fakeInstproxyClientFree(_ c: instproxy_client_t?) -> instproxy_error_t
{ IMDFake.instproxyClientFree(c) }
@_cdecl("instproxy_browse") nonisolated func fakeInstproxyBrowse(
    _ c: instproxy_client_t?,
    _ o: plist_t?,
    _ r: UnsafeMutablePointer<plist_t?>?
) -> instproxy_error_t { IMDFake.instproxyBrowse(c, o, r) }
@_cdecl("instproxy_lookup_archives") nonisolated func fakeInstproxyLookupArchives(
    _ c: instproxy_client_t?,
    _ o: plist_t?,
    _ r: UnsafeMutablePointer<plist_t?>?
) -> instproxy_error_t { IMDFake.instproxyLookupArchives(c, o, r) }
@_cdecl("instproxy_install") nonisolated func fakeInstproxyInstall(
    _ c: instproxy_client_t?,
    _ t: UnsafePointer<CChar>?,
    _ o: plist_t?,
    _ cb: instproxy_status_cb_t?,
    _ u: UnsafeMutableRawPointer?
) -> instproxy_error_t { IMDFake.instproxyCommand("install", c, t, o, cb, u) }
@_cdecl("instproxy_archive") nonisolated func fakeInstproxyArchive(
    _ c: instproxy_client_t?,
    _ t: UnsafePointer<CChar>?,
    _ o: plist_t?,
    _ cb: instproxy_status_cb_t?,
    _ u: UnsafeMutableRawPointer?
) -> instproxy_error_t { IMDFake.instproxyCommand("archive", c, t, o, cb, u) }
@_cdecl("instproxy_restore") nonisolated func fakeInstproxyRestore(
    _ c: instproxy_client_t?,
    _ t: UnsafePointer<CChar>?,
    _ o: plist_t?,
    _ cb: instproxy_status_cb_t?,
    _ u: UnsafeMutableRawPointer?
) -> instproxy_error_t { IMDFake.instproxyCommand("restore", c, t, o, cb, u) }
@_cdecl("instproxy_uninstall") nonisolated func fakeInstproxyUninstall(
    _ c: instproxy_client_t?,
    _ t: UnsafePointer<CChar>?,
    _ o: plist_t?,
    _ cb: instproxy_status_cb_t?,
    _ u: UnsafeMutableRawPointer?
) -> instproxy_error_t { IMDFake.instproxyCommand("uninstall", c, t, o, cb, u) }
@_cdecl("instproxy_status_get_error") nonisolated func fakeInstproxyStatusError(
    _ s: plist_t?,
    _ n: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ d: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ c: UnsafeMutablePointer<UInt64>?
) -> instproxy_error_t { IMDFake.instproxyStatusError(s, n, d, c) }
@_cdecl("instproxy_status_get_name") nonisolated func fakeInstproxyStatusName(
    _ s: plist_t?,
    _ n: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) { IMDFake.instproxyStatusName(s, n) }
@_cdecl("instproxy_status_get_percent_complete") nonisolated func fakeInstproxyStatusPercent(
    _ s: plist_t?,
    _ p: UnsafeMutablePointer<Int32>?
) { IMDFake.instproxyStatusPercent(s, p) }

@_cdecl("np_client_start_service") nonisolated func fakeNpStart(
    _ d: idevice_t?,
    _ c: UnsafeMutablePointer<np_client_t?>?,
    _ l: UnsafePointer<CChar>?
) -> np_error_t { IMDFake.npStart(d, c, l) }
@_cdecl("np_client_free") nonisolated func fakeNpFree(_ c: np_client_t?) -> np_error_t { IMDFake.npFree(c) }
@_cdecl("np_observe_notification") nonisolated func fakeNpObserve(_ c: np_client_t?, _ n: UnsafePointer<CChar>?)
    -> np_error_t
{ IMDFake.npObserve(c, n) }
@_cdecl("np_set_notify_callback") nonisolated func fakeNpSetCallback(
    _ c: np_client_t?,
    _ cb: np_notify_cb_t?,
    _ u: UnsafeMutableRawPointer?
) -> np_error_t { IMDFake.npSetCallback(c, cb, u) }

@_cdecl("sbservices_client_new") nonisolated func fakeSbClientNew(
    _ d: idevice_t?,
    _ s: lockdownd_service_descriptor_t?,
    _ c: UnsafeMutablePointer<sbservices_client_t?>?
) -> sbservices_error_t { IMDFake.sbClientNew(d, s, c) }
@_cdecl("sbservices_client_free") nonisolated func fakeSbClientFree(_ c: sbservices_client_t?) -> sbservices_error_t {
    IMDFake.sbClientFree(c)
}
@_cdecl("sbservices_get_icon_state") nonisolated func fakeSbGetIconState(
    _ c: sbservices_client_t?,
    _ s: UnsafeMutablePointer<plist_t?>?,
    _ f: UnsafePointer<CChar>?
) -> sbservices_error_t { IMDFake.sbGetIconState(c, s, f) }
@_cdecl("sbservices_set_icon_state") nonisolated func fakeSbSetIconState(_ c: sbservices_client_t?, _ s: plist_t?)
    -> sbservices_error_t
{ IMDFake.sbSetIconState(c, s) }
@_cdecl("sbservices_get_interface_orientation") nonisolated func fakeSbOrientation(
    _ c: sbservices_client_t?,
    _ o: UnsafeMutablePointer<sbservices_interface_orientation_t>?
) -> sbservices_error_t { IMDFake.sbOrientation(c, o) }

@_cdecl("plist_to_xml") nonisolated func fakePlistToXML(
    _ p: plist_t?,
    _ x: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ n: UnsafeMutablePointer<UInt32>?
) -> plist_err_t {
    guard let value = IMDFake.value(p),
        let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    else { return PLIST_ERR_INVALID_ARG }
    let bytes = malloc(data.count + 1)!.assumingMemoryBound(to: CChar.self)
    data.withUnsafeBytes { bytes.update(from: $0.bindMemory(to: CChar.self).baseAddress!, count: data.count) }
    bytes[data.count] = 0
    x?.pointee = bytes
    n?.pointee = UInt32(data.count)
    return PLIST_ERR_SUCCESS
}
@_cdecl("plist_from_xml") nonisolated func fakePlistFromXML(
    _ x: UnsafePointer<CChar>?,
    _ n: UInt32,
    _ p: UnsafeMutablePointer<plist_t?>?
) -> plist_err_t {
    guard let x,
        let value = try? PropertyListSerialization.propertyList(from: Data(bytes: x, count: Int(n)), format: nil)
    else { return PLIST_ERR_PARSE }
    p?.pointee = IMDFake.node(value)
    return PLIST_ERR_SUCCESS
}
@_cdecl("plist_free") nonisolated func fakePlistFree(_ p: plist_t?) {
    if let p { Unmanaged<IMDFake.Node>.fromOpaque(p).release() }
}
@_cdecl("plist_mem_free") nonisolated func fakePlistMemFree(_ p: UnsafeMutableRawPointer?) { free(p) }

// Walking a tree (IMobileDevice.withinLimits): node types, array items, dictionary entries, string and data lengths.
private nonisolated func fakeNode(_ p: plist_t?) -> IMDFake.Node? {
    p.map { Unmanaged<IMDFake.Node>.fromOpaque($0).takeUnretainedValue() }
}
private nonisolated func opaque(_ node: IMDFake.Node) -> plist_t { Unmanaged.passUnretained(node).toOpaque() }
@_cdecl("plist_get_node_type") nonisolated func fakePlistNodeType(_ p: plist_t?) -> plist_type {
    switch fakeNode(p)?.value {
    case is [Any]: PLIST_ARRAY
    case is [String: Any]: PLIST_DICT
    case is String: PLIST_STRING
    case is Data: PLIST_DATA
    case is Date: PLIST_DATE
    case .some: PLIST_INT
    case nil: PLIST_NONE
    }
}
@_cdecl("plist_array_get_size") nonisolated func fakePlistArraySize(_ p: plist_t?) -> UInt32 {
    UInt32(fakeNode(p)?.children.count ?? 0)
}
@_cdecl("plist_array_get_item") nonisolated func fakePlistArrayItem(_ p: plist_t?, _ n: UInt32) -> plist_t? {
    fakeNode(p).map { opaque($0.children[Int(n)].node) }
}
@_cdecl("plist_dict_new_iter") nonisolated func fakePlistDictNewIter(
    _ p: plist_t?,
    _ i: UnsafeMutablePointer<plist_dict_iter?>?
) {
    let index = malloc(MemoryLayout<Int>.size)!
    index.storeBytes(of: 0, as: Int.self)
    i?.pointee = index
}
@_cdecl("plist_dict_next_item") nonisolated func fakePlistDictNextItem(
    _ p: plist_t?,
    _ i: plist_dict_iter?,
    _ k: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ v: UnsafeMutablePointer<plist_t?>?
) {
    k?.pointee = nil
    v?.pointee = nil
    guard let node = fakeNode(p), let i else { return }
    let index = i.load(as: Int.self)
    guard index < node.children.count else { return }
    i.storeBytes(of: index + 1, as: Int.self)
    k?.pointee = node.children[index].key.map { strdup($0) }
    v?.pointee = opaque(node.children[index].node)
}
@_cdecl("plist_get_string_ptr") nonisolated func fakePlistStringPtr(
    _ p: plist_t?,
    _ n: UnsafeMutablePointer<UInt64>?
) -> UnsafePointer<CChar>? {
    n?.pointee = UInt64(fakeNode(p)?.bytes?.count ?? 0)
    return nil
}
@_cdecl("plist_get_data_ptr") nonisolated func fakePlistDataPtr(
    _ p: plist_t?,
    _ n: UnsafeMutablePointer<UInt64>?
) -> UnsafePointer<CChar>? {
    n?.pointee = UInt64(fakeNode(p)?.bytes?.count ?? 0)
    return nil
}
