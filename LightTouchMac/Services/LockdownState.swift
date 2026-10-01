import Foundation

extension DeviceServices {
    /// lockdownd's ActivationState: "Activated", "Unactivated", "FactoryActivated".
    ///
    /// The tell for a torn filesystem. A hard exit loses HFS+ catalog updates
    /// that were still in memory, and if the activation record is among them the
    /// guest boots to the Connect-to-iTunes screen — where lockdownd still
    /// answers but every service refuses, so the app's only symptom was an
    /// unexplained "Install service error (connect): code -256". Asking turns
    /// that dead end into something the UI can name and offer a fix for.
    func activationState() async -> String? { try? await lockdownValue("ActivationState") }

    /// Stock lockdown reads share the same endpoint, timeout and error contract.
    func lockdownValue(_ key: String) async throws -> String? {
        if !local {
            guard case .string(let state) = try await remote(.lockdownValue(key), seconds: Timeouts.query) else { return nil }
            return state
        }
        return try await run(Timeouts.query, "lockdown " + key) { imd, device in
            guard let newClient = imd.lockdownd_client_new_with_handshake,
                  let getValue = imd.lockdownd_get_value,
                  let plistFree = imd.plist_free else { throw DeviceError.unavailable }
            var client: OpaquePointer?
            let rc = newClient(device, &client, "LightTouchMac")
            guard rc == imd.success, let client else { throw DeviceError.lockdown(rc) }
            defer { _ = imd.lockdownd_client_free?(client) }

            var value: OpaquePointer?
            let vr = key.withCString { getValue(client, nil, $0, &value) }
            guard vr == imd.success, let value else { throw DeviceError.lockdown(vr) }
            defer { plistFree(value) }
            return IMobileDevice.decode(value) as? String
        }
    }

}
