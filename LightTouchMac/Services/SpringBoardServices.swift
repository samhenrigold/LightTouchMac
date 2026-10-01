// Created by Sam on 2026-08-05.
//
// The home screen's icon order, read and written over com.apple.springboardservices.
//
// libimobiledevice implements sbservices_get_icon_state/set_icon_state but
// ships no tool that calls them, so the library drives them directly. The
// alternative -- editing com.apple.springboard.plist in the guest -- needs a
// respring to take effect, and a respring in the middle of managing apps is a
// worse experience than the reorder is worth.
//
// The state itself is an array of pages; each page is an array of icons; an
// icon is a dict with a displayIdentifier, or a folder (never on 3.1.3) with
// children. Dock icons are page 0. Everything here flattens that to a plain
// list of bundle IDs in home-screen order and puts it back the same shape it
// came in, so pages and the dock survive a reorder untouched.

import Foundation

extension DeviceServices {
    /// Bundle IDs in home-screen order: dock first, then each page, reading
    /// the way the icons are laid out. Throws rather than returning [] so the
    /// caller can tell "SpringBoard says there is nothing" from "we couldn't
    /// ask" — an empty list would silently reorder the sidebar to nothing.
    func homeScreenOrder() async throws -> [String] {
        if !local {
            guard case .strings(let ids) = try await remote(.homeOrder, seconds: Timeouts.query) else { throw DeviceError.unavailable }
            return ids
        }
        return try await withIconState { state, _ in HomeScreenLayout.flatten(state) }
    }

    /// Move `bundleID` into the slot `other` currently occupies, or to the end
    /// when `other` is nil. Keyed on bundle IDs rather than indices because
    /// that is what a dropped table row knows, and because the layout can
    /// change under us between the drop and the write. Returns the order
    /// SpringBoard ACCEPTED, which is not always the one asked for — the
    /// caller should adopt it rather than assume its own.
    ///
    /// Every page keeps its icon count: icons after the insertion point shuffle
    /// up one slot, exactly as dragging on the device does.
    @discardableResult
    func moveOnHomeScreen(_ bundleID: String, before other: String?, deviceName: String) async throws -> [String] {
        if !local {
            guard case .strings(let ids) = try await remote(.move(bundle: bundleID, before: other, deviceName: deviceName), seconds: Timeouts.query) else { throw DeviceError.unavailable }
            return ids
        }
        return try await withIconState { state, client in
            var ids = HomeScreenLayout.flatten(state)
            // Not "return ids". Returning the unchanged order looked like a
            // successful move to the caller, which kept its optimistic row
            // position while the device never got the write — most likely for
            // an app SpringBoard has not added to its layout yet, i.e. a fresh
            // install before a respring.
            guard let from = ids.firstIndex(of: bundleID) else {
                throw DeviceToolsError.failed(
                    "This app isn’t on the Home screen yet. "
                    + "Restart the \(deviceName), then try moving it again.")
            }
            ids.remove(at: from)
            let to = other.flatMap { ids.firstIndex(of: $0) } ?? ids.count
            ids.insert(bundleID, at: to)
            try HomeScreenLayout.write(HomeScreenLayout.rebuild(state, order: ids), to: client)
            return ids
        }
    }

    /// SpringBoard's UIInterfaceOrientation (1 portrait, 2 upside down,
    /// 3 landscape right, 4 landscape left). 3.2's springboardservicesrelay
    /// answers it; 3.1.3's doesn't (see EmulatorController's auto-rotation).
    func interfaceOrientation() async throws -> Int {
        if !local {
            guard case .integer(let orientation) = try await remote(.orientation, seconds: Timeouts.query) else { throw DeviceError.unavailable }
            return Int(orientation)
        }
        return try await withSpringBoard { client in
            guard let get = IMobileDevice.sbservices_get_interface_orientation else {
                throw DeviceToolsError.failed("App services are missing from this copy of Light Touch. Reinstall Light Touch.")
            }
            var orientation: Int32 = 0
            guard get(client, &orientation) == IMobileDevice.success else {
                throw DeviceToolsError.failed("The Home screen didn’t report its orientation. Try again.")
            }
            return Int(orientation)
        }
    }

    // MARK: - libimobiledevice

    /// Connect, run `body` against the current icon state, disconnect. Every
    /// handle is released on the way out, including on a throw — a leaked
    /// lockdown client is a service slot the device does not get back, and
    /// this device only has a handful.
    private func withIconState<T: Sendable>(
        _ body: @Sendable @escaping ([Any], OpaquePointer) throws -> T
    ) async throws -> T {
        return try await withSpringBoard { client in
            let imd = IMobileDevice.self
            guard let sbservices_get_icon_state = imd.sbservices_get_icon_state,
                  let plist_free = imd.plist_free else {
                throw DeviceToolsError.failed("App services are missing from this copy of Light Touch. Reinstall Light Touch.")
            }
            var raw: OpaquePointer?
            // "2" is the format version SpringBoard has spoken since iOS 3 —
            // the one that reports the dock as its own list.
            guard sbservices_get_icon_state(client, &raw, "2") == imd.success,
                  let raw else {
                throw DeviceToolsError.failed("The Home screen didn’t report its layout. Try again.")
            }
            defer { plist_free(raw) }

            guard let state = try HomeScreenLayout.decode(raw) as? [Any] else {
                throw DeviceToolsError.failed("The Home screen reported a layout Light Touch can’t read.")
            }
            return try body(state, client)
        }
    }

    /// Connect to springboardservices, run `body`, disconnect — on the run
    /// kernel, under the same gate and deadline as every other device
    /// operation. This was a bare detached task once: the only device path that
    /// opened a lockdown session without asking the gate first, against a guest
    /// that serves about one, so a home-screen read landing next to a list poll
    /// or an install cost both of them their services ("Invalid service"); and
    /// `lockdownd_client_new_with_handshake` has no timeout of its own.
    private func withSpringBoard<T: Sendable>(
        _ body: @Sendable @escaping (OpaquePointer) throws -> T
    ) async throws -> T {
        return try await run(Timeouts.browse, "home-screen layout") { imd, device in
            guard let lockdownd_client_new_with_handshake = imd.lockdownd_client_new_with_handshake,
                  let lockdownd_start_service = imd.lockdownd_start_service,
                  let sbservices_client_new = imd.sbservices_client_new else {
                throw DeviceToolsError.failed(
                    "App services are missing from this copy of Light Touch. Reinstall Light Touch.")
            }

            var lockdown: OpaquePointer?
            guard lockdownd_client_new_with_handshake(device, &lockdown, "LightTouchMac")
                    == imd.success, let lockdown else {
                throw DeviceToolsError.failed("The device refused the connection. Try again.")
            }
            defer { _ = imd.lockdownd_client_free?(lockdown) }

            var service: OpaquePointer?
            guard lockdownd_start_service(lockdown, "com.apple.springboardservices", &service)
                    == imd.success, let service else {
                throw DeviceToolsError.failed("The Home screen isn’t responding yet. Try again in a moment.")
            }
            defer { _ = imd.lockdownd_service_descriptor_free?(service) }

            var client: OpaquePointer?
            guard sbservices_client_new(device, service, &client) == imd.success,
                  let client else {
                throw DeviceToolsError.failed("Couldn’t reach the Home screen. Try again.")
            }
            defer { _ = imd.sbservices_client_free?(client) }
            return try body(client)
        }
    }
}

/// The icon state's shape: flattened to bundle IDs and refilled from them.
nonisolated enum HomeScreenLayout {
    /// Every displayIdentifier in the state, in layout order. Folders on later
    /// iOS keep their children in `iconLists`; flattening them keeps this
    /// honest on a device that has any, even though 3.1.3 cannot make one.
    static func flatten(_ state: [Any]) -> [String] {
        var ids: [String] = []
        func walk(_ node: Any) {
            if let list = node as? [Any] { list.forEach(walk) }
            else if let icon = node as? [String: Any] {
                if let id = icon["displayIdentifier"] as? String { ids.append(id) }
                if let lists = icon["iconLists"] { walk(lists) }
            }
        }
        walk(state)
        return ids
    }

    /// The same page/dock structure, refilled from `order`. Slot counts are
    /// preserved, so nothing is pushed onto a page that cannot hold it — the
    /// device decides how many icons fit, and we are in no position to argue.
    static func rebuild(_ state: [Any], order: [String]) -> [Any] {
        var remaining = order[...]
        func refill(_ node: Any) -> Any {
            if let list = node as? [Any] { return list.map(refill) }
            if var icon = node as? [String: Any] {
                if icon["displayIdentifier"] != nil, let next = remaining.first {
                    remaining = remaining.dropFirst()
                    icon["displayIdentifier"] = next
                }
                if let lists = icon["iconLists"] { icon["iconLists"] = refill(lists) }
                return icon
            }
            return node
        }
        return state.map(refill)
    }

    #if DEBUG
    /// Flatten and rebuild have to be exact inverses, and a rebuild has to keep
    /// every page and the dock at the size it already was. Getting this wrong
    /// scrambles somebody's home screen, which is not a thing to find out on a
    /// live device.
    static func selfCheck() {
        let dock = [["displayIdentifier": "com.apple.mobilemusic"]]
        let page1 = [["displayIdentifier": "com.apple.MobileAddressBook"],
                     ["displayIdentifier": "com.shazam.Shazam"],
                     ["displayIdentifier": "com.condenet.Epicurious"]]
        let state: [Any] = [dock, page1]
        assert(flatten(state) == ["com.apple.mobilemusic", "com.apple.MobileAddressBook",
                                  "com.shazam.Shazam", "com.condenet.Epicurious"])
        assert(flatten(rebuild(state, order: flatten(state))) == flatten(state),
               "rebuild is not the inverse of flatten")

        // Epicurious dragged to where Shazam sits.
        var ids = flatten(state)
        ids.removeAll { $0 == "com.condenet.Epicurious" }
        ids.insert("com.condenet.Epicurious", at: ids.firstIndex(of: "com.shazam.Shazam")!)
        let moved = rebuild(state, order: ids)
        assert(flatten(moved) == ["com.apple.mobilemusic", "com.apple.MobileAddressBook",
                                  "com.condenet.Epicurious", "com.shazam.Shazam"])
        // Page sizes untouched: the dock still holds exactly one icon.
        assert((moved[0] as? [Any])?.count == 1 && (moved[1] as? [Any])?.count == 3,
               "rebuild changed how many icons a page holds")
    }
    #endif

    /// plist_t -> Foundation, via the XML both sides already speak. Converting
    /// through a string beats walking the plist_t node by node, and an icon
    /// layout is a few KB.
    fileprivate static func decode(_ node: OpaquePointer) throws -> Any {
        var xml: UnsafeMutablePointer<CChar>?
        var length: UInt32 = 0
        IMobileDevice.plist_to_xml?(node, &xml, &length)
        guard let xml else { throw DeviceToolsError.failed("The Home screen reported a layout Light Touch can’t read.") }
        defer { IMobileDevice.plist_mem_free?(xml) }
        let data = Data(bytes: xml, count: Int(length))
        return try PropertyListSerialization.propertyList(from: data, format: nil)
    }

    fileprivate static func write(_ state: [Any], to client: OpaquePointer) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: state,
                                                      format: .xml, options: 0)
        var node: OpaquePointer?
        // plist_from_xml's own return code is dropped: it reports the same
        // failure the nil node does, and the nil check has to be here anyway.
        _ = data.withUnsafeBytes { buffer in
            IMobileDevice.plist_from_xml?(buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                                          UInt32(buffer.count), &node)
        }
        guard let node else { throw DeviceToolsError.failed("Couldn’t save the Home screen layout.") }
        defer { IMobileDevice.plist_free?(node) }
        guard IMobileDevice.sbservices_set_icon_state?(client, node) == IMobileDevice.success else {
            throw DeviceToolsError.failed("The Home screen didn’t accept the new layout.")
        }
    }
}
