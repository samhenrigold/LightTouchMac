// lockdownd itself: ActivationState in-process, and the writes that must not be
// in-process (lockdownd_set_value against 3.1.3 corrupts the app's heap) as child
// processes pointed at this device's usbmuxd: lockdown-tz for the time zone.

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
    func activationState() async -> String? {
        try? await run(Timeouts.query, "activation state") { imd, device in
            guard let newClient = imd.lockdownd_client_new_with_handshake,
                  let getValue = imd.lockdownd_get_value,
                  let plistFree = imd.plist_free else { throw DeviceError.unavailable }
            var client: OpaquePointer?
            let rc = newClient(device, &client, "LightTouchMac")
            guard rc == imd.success, let client else { throw DeviceError.lockdown(rc) }
            defer { _ = imd.lockdownd_client_free?(client) }

            var value: OpaquePointer?
            let vr = "ActivationState".withCString { getValue(client, nil, $0, &value) }
            guard vr == imd.success, let value else { throw DeviceError.lockdown(vr) }
            defer { plistFree(value) }
            return IMobileDevice.decode(value) as? String
        }
    }

    /// Sync the guest's timezone through the bundled lockdown-tz helper — a
    /// child process ON PURPOSE. lockdownd_set_value called in-process against
    /// 3.1.3's lockdownd corrupts the heap: the app died ~20 s later in
    /// unrelated Swift runtime code, reproducibly, while the identical call
    /// from a child process is clean (scripts/lockdown-tz.c). The tool reads
    /// first, sets only on mismatch, and prints the zone in effect. Dev builds
    /// without the bundled tool skip quietly — the zone is cosmetic.
    func setTimeZone(_ identifier: String) async throws {
        guard let tool = Bundled.tool("lockdown-tz") ?? Self.developmentHelper("lockdown-tz") else {
            logEvent("timezone: no bundled lockdown-tz (dev build) — leaving the guest's zone alone")
            return
        }
        let zone = try await Self.setTimeZone(identifier, tool: tool, socket: clientSocket)
        logEvent("timezone: guest zone now \(zone)")
    }

    /// The lockdown-tz child itself (memory lockdown-setvalue-trap); the zone in effect.
    static func setTimeZone(_ identifier: String, tool: String, socket: String) async throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = [identifier]
        task.environment = ProcessInfo.processInfo.environment.merging(["USBMUXD_SOCKET_ADDRESS": socket]) { $1 }
        let output = Pipe(), error = Pipe()
        task.standardOutput = output
        task.standardError = error
        task.standardInput = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { done in
            task.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try task.run() } catch { task.terminationHandler = nil; done.resume(throwing: error) }
        }
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile().prefix(1024), as: UTF8.self)
        guard status == 0 else {
            let err = String(decoding: error.fileHandleForReading.readDataToEndOfFile().prefix(1024), as: UTF8.self)
            throw DeviceToolsError.failed("Couldn’t set the device timezone. \(err)")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A development build has no bundled lockdown helpers (package.sh builds
    /// them), so the time zone was never synced when running from Xcode.
    /// Debug builds compile scripts/<name>.c against Homebrew's
    /// libimobiledevice into the work directory, once per source change.
    static func developmentHelper(_ name: String) -> String? {
        #if DEBUG
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/\(name).c")
        let binary = Bundled.workDirectory.appendingPathComponent("dev-tools/\(name)")
        let fm = FileManager.default
        guard let sourceDate = (try? fm.attributesOfItem(atPath: source.path))?[.modificationDate] as? Date else { return nil }
        if let built = (try? fm.attributesOfItem(atPath: binary.path))?[.modificationDate] as? Date,
           built >= sourceDate, fm.isExecutableFile(atPath: binary.path) { return binary.path }
        try? fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/bin/sh")
        build.arguments = ["-c", "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; "
            + "cc -O2 -o \"$1\" \"$2\" $(pkg-config --cflags --libs libimobiledevice-1.0 libplist-2.0)",
            "sh", binary.path, source.path]
        do { try build.run() } catch { return nil }
        build.waitUntilExit()
        guard build.terminationStatus == 0 else {
            logEvent("\(name): could not build the development helper")
            return nil
        }
        return binary.path
        #else
        return nil
        #endif
    }
}
