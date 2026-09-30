// lockdownd itself: ActivationState in-process, and the writes that must not be
// in-process (lockdownd_set_value against 3.1.3 corrupts the app's heap) as child
// processes pointed at this device's usbmuxd: lockdown-tz for the time zone,
// lockdown-mcinstall for the proxy's profile.

import Foundation
import Subprocess
import System

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

    /// Complete activation acknowledgement and an old iPod's first host connection.
    /// Uses the guest protocol, independently of the clock and timezone preferences.
    func finishActivation() async throws {
        guard let tool = Bundled.tool("lockdown-tz") ?? Self.developmentHelper("lockdown-tz") else {
            throw DeviceToolsError.toolMissing("lockdown-tz")
        }
        let result = try await Self.lockdownChild(tool, ["--finish-activation"], socket: clientSocket)
        guard result.status == 0 else {
            throw DeviceToolsError.failed("Couldn’t complete device activation. \(result.error)")
        }
    }

    /// Sync the guest's timezone through the bundled lockdown-tz helper — a
    /// child process ON PURPOSE. lockdownd_set_value called in-process against
    /// 3.1.3's lockdownd corrupts the heap: the app died ~20 s later in
    /// unrelated Swift runtime code, reproducibly, while the identical call
    /// from a child process is clean (scripts/lockdown-tz.c). The tool reads
    /// first, sets only on mismatch, and prints the zone in effect. Dev builds
    /// without the bundled tool skip quietly — the zone is cosmetic.
    func setTimeZone(_ identifier: String, guest: GuestServices?) async throws {
        guard let tool = Bundled.tool("lockdown-tz") ?? Self.developmentHelper("lockdown-tz") else {
            logEvent("timezone: no bundled lockdown-tz (dev build) — leaving the guest's zone alone")
            return
        }
        let zone = try await Self.setTimeZone(identifier, tool: tool, socket: clientSocket, guest: guest)
        logEvent("timezone: guest zone now \(zone)")
    }

    /// The lockdown-tz child itself (memory lockdown-setvalue-trap); the zone in effect. When the
    /// guest kept its own zone (4.x's locationd applies only the first external one) and there is
    /// a guest agent, once more after it clears locationd's record of that one.
    static func setTimeZone(_ identifier: String, tool: String, socket: String, guest: GuestServices? = nil) async throws -> String {
        try Task.checkCancellation()
        do { return try await lockdownTZ(identifier, tool: tool, socket: socket) }
        catch DeviceToolsError.zoneKept(let zone) {
            try Task.checkCancellation()
            guard let guest, await guest.agent.waitAlive(seconds: 60) else {
                try Task.checkCancellation()
                throw DeviceToolsError.zoneKept(zone)
            }
            try Task.checkCancellation()
            guard try await guest.forgetExternalTimeZone() else {
                throw DeviceToolsError.zoneKept(zone)
            }
            try Task.checkCancellation()
            logEvent("timezone: the device kept \(zone); cleared locationd's first zone, setting again")
            return try await lockdownTZ(identifier, tool: tool, socket: socket)
        }
    }

    private static func lockdownTZ(_ identifier: String, tool: String, socket: String) async throws -> String {
        let result = try await lockdownChild(tool, [identifier], socket: socket)
        let zone = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status == 4 { throw DeviceToolsError.zoneKept(zone) }
        guard result.status == 0 else {
            throw DeviceToolsError.failed("Couldn’t set the device timezone. \(result.error)")
        }
        return zone
    }

    /// Offer a CA as a configuration profile through lockdown's stock MCInstall
    /// service (the lockdown-mcinstall child, like lockdown-tz), once: false when
    /// one is installed already, true when it was offered and waits for Install
    /// on the device.
    func offerProfile(_ certificate: String) async throws -> Bool {
        // Packaged apps bundle it (package.sh); dev builds find it on the usual PATH directories.
        guard let tool = Bundled.resolve("lockdown-mcinstall", fallbacks: Bundled.binarySearchPaths.map { "\($0)/lockdown-mcinstall" })
        else { throw DeviceToolsError.toolMissing("lockdown-mcinstall") }
        if try await Self.lockdownChild(tool, ["--installed"], socket: clientSocket).status == 0 { return false }
        let offered = try await Self.lockdownChild(tool, [certificate], socket: clientSocket)
        guard offered.status == 0 else {
            logEvent("proxy: offering the certificate profile failed: \(offered.error)")
            throw DeviceToolsError.failed("Couldn’t offer the proxy certificate to the device.")
        }
        logEvent("proxy: no guest agent; certificate profile offered, confirm Install on the device")
        return true
    }

    /// One of the lockdown child tools, pointed at this device's usbmuxd: its
    /// status and the first KB of each stream.
    private static func lockdownChild(_ tool: String, _ arguments: [String], socket: String) async throws
        -> (status: Int32, output: String, error: String) {
        try Task.checkCancellation()
        // The existing subprocess library owns spawn, output draining and reaping.
        // Cancellation (including the deadline) tears down the child before this
        // returns, so a replaced boot cannot leave a timezone writer running.
        let result = try await withThrowingTaskGroup(of: (Int32, String, String).self) { group in
            group.addTask {
                let child = try await Subprocess.run(.path(FilePath(tool)), arguments: Arguments(arguments),
                    environment: .inherit.updating(["USBMUXD_SOCKET_ADDRESS": socket]),
                    input: .none, output: .string(limit: 1024), error: .string(limit: 1024))
                let status: Int32 = switch child.terminationStatus {
                    case .exited(let code): code
                    case .signaled(let signal): -signal
                }
                return (status, child.standardOutput, child.standardError)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(Timeouts.query))
                throw DeviceToolsError.failed("The device did not answer the lockdown helper in time.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        try Task.checkCancellation()
        return (result.0, result.1, result.2)
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
