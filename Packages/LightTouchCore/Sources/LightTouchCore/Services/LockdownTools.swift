// lockdownd itself: ActivationState in-process, and the writes that must not be
// in-process (lockdownd_set_value against 3.1.3 corrupts the app's heap) as child
// processes pointed at this device's usbmuxd: the services helper's lockdown-tz
// operation for the time zone, lockdown-mcinstall for the proxy's profile
// (LightTouchServices/Lockdown).

import Foundation
import HostServiceWire
import Subprocess
import System

extension DeviceServices {
    /// Complete activation acknowledgment and an old iPod's first host connection.
    /// Uses the guest protocol, independently of the clock and timezone preferences.
    public func finishActivation() async throws {
        guard let tool = Self.servicesHelper else { throw DeviceToolsError.toolMissing("LightTouchServices") }
        try await Self.finishActivation(tool: tool, socket: clientSocket)
    }

    /// The same child protocol with an explicit services helper, for native session tests.
    public static func finishActivation(tool: String, socket: String) async throws {
        let result = try await lockdownChild(tool, ["lockdown-tz", "--finish-activation"], socket: socket)
        guard result.status == 0 else {
            throw DeviceToolsError.failed("Couldn’t complete device activation. \(result.error)")
        }
    }

    /// Sync the guest's timezone through the services helper's lockdown-tz
    /// operation — a child process ON PURPOSE. lockdownd_set_value called
    /// in-process against 3.1.3's lockdownd corrupts the heap: the app died ~20 s
    /// later in unrelated Swift runtime code, reproducibly, while the identical
    /// call from a child process is clean (LightTouchServices/Lockdown). The
    /// operation reads first, sets only on mismatch, and prints the zone in effect.
    public func setTimeZone(
        _ identifier: String,
        keepClock: Bool = false,
        guest: GuestServices?,
        region: ClockRegion? = nil
    ) async throws {
        guard let tool = Self.servicesHelper else { throw DeviceToolsError.toolMissing("LightTouchServices") }
        let zone = try await Self.setTimeZone(
            identifier,
            keepClock: keepClock,
            tool: tool,
            socket: clientSocket,
            guest: guest,
            region: region
        )
        logEvent("timezone: guest zone now \(zone)")
    }

    /// The lockdown-tz child itself (memory lockdown-setvalue-trap); the zone in effect. A zone the guest kept is
    /// written again, up to 3 times: 4.x's locationd applies only the first external zone (cleared first through the
    /// guest agent, when there is one and it holds such a record), and a write that lands while locationd restarts
    /// (the guest package's it_prefs restarts it once Wi-Fi is up) is dropped, so the same write 5 s later takes.
    /// keepClock: leave the guest's clock alone (a dated device, lock machine rtc-epoch: the Mac's clock would expire it).
    public static func setTimeZone(
        _ identifier: String,
        keepClock: Bool = false,
        tool: String,
        socket: String,
        guest: GuestServices? = nil,
        region: ClockRegion? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        var kept: String
        do {
            return try await lockdownTZ(identifier, keepClock: keepClock, tool: tool, socket: socket, region: region)
        } catch DeviceToolsError.zoneKept(let zone) { kept = zone }
        try Task.checkCancellation()
        let agent = await guest?.agent.waitAlive(seconds: 60) == true ? guest : nil
        for _ in 0..<3 {
            try Task.checkCancellation()
            if let agent, try await agent.forgetExternalTimeZone() {
                logEvent("timezone: the device kept \(kept); cleared locationd's first zone, setting again")
            } else {
                try await Task.sleep(for: .seconds(5))
            }
            do {
                return try await lockdownTZ(
                    identifier,
                    keepClock: keepClock,
                    tool: tool,
                    socket: socket,
                    region: region
                )
            } catch DeviceToolsError.zoneKept(let zone) { kept = zone }
        }
        throw DeviceToolsError.zoneKept(kept)
    }

    private static func lockdownTZ(
        _ identifier: String,
        keepClock: Bool,
        tool: String,
        socket: String,
        region: ClockRegion?
    ) async throws -> String {
        let result = try await lockdownChild(
            tool,
            ["lockdown-tz", identifier] + (keepClock ? ["keep"] : []) + (region?.arguments ?? []),
            socket: socket
        )
        let zone = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status == 4 { throw DeviceToolsError.zoneKept(zone) }
        guard result.status == 0 else {
            throw DeviceToolsError.failed("Couldn’t set the device timezone. \(result.error)")
        }
        return zone
    }

    /// Offer a CA as a configuration profile through lockdown's stock MCInstall
    /// service (the lockdown-mcinstall operation's child, like lockdown-tz), once:
    /// false when one is installed already, true when it was offered and waits for
    /// Install on the device.
    public func offerProfile(_ certificate: String) async throws -> Bool {
        guard let tool = Self.servicesHelper else { throw DeviceToolsError.toolMissing("LightTouchServices") }
        if try await Self.lockdownChild(tool, ["lockdown-mcinstall", "--installed"], socket: clientSocket).status == 0 {
            return false
        }
        let offered = try await Self.lockdownChild(tool, ["lockdown-mcinstall", certificate], socket: clientSocket)
        guard offered.status == 0 else {
            logEvent("proxy: offering the certificate profile failed: \(offered.error)")
            AppReports.failed("Network.proxyProfileFailed")
            throw DeviceToolsError.failed("Couldn’t offer the proxy certificate to the device.")
        }
        logEvent("proxy: no guest agent; certificate profile offered, confirm Install on the device")
        return true
    }

    /// Tweaks' Developer Settings: Apple's Developer Disk Image mounted through lockdown's image mounter (the
    /// lockdown-ddi operation's child, like lockdown-tz); `image` is the .dmg, its .signature beside it. True when
    /// it mounted now, false when one was mounted already. `tool`: LightTouchServices, the bundle's by default.
    public func mountDeveloperImage(_ image: URL, tool: String? = servicesHelper) async throws -> Bool {
        guard let tool else { throw DeviceToolsError.toolMissing("LightTouchServices") }
        let result = try await Self.lockdownChild(
            tool,
            ["lockdown-ddi", image.path, image.path + ".signature"],
            socket: clientSocket,
            timeout: 600  // ~20 MB over the emulated USB
        )
        let said = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0 else {
            throw DeviceToolsError.failed("The device didn’t mount the Developer Disk Image: \(said)")
        }
        return said == "mounted"
    }

    /// One of the lockdown child tools, pointed at this device's usbmuxd: its
    /// status and the first KB of each stream.
    static func lockdownChild(
        _ tool: String,
        _ arguments: [String],
        socket: String,
        timeout: TimeInterval = Timeouts.query
    ) async throws
        -> (status: Int32, output: String, error: String)
    {
        try Task.checkCancellation()
        // The existing subprocess library owns spawn, output draining and reaping.
        // Cancellation (including the deadline) tears down the child before this
        // returns, so a replaced boot cannot leave a timezone writer running.
        let result = try await withThrowingTaskGroup(of: (Int32, String, String).self) { group in
            group.addTask {
                let child = try await Subprocess.run(
                    .path(FilePath(tool)),
                    arguments: Arguments(arguments),
                    environment: .inherit.updating(["USBMUXD_SOCKET_ADDRESS": socket]),
                    input: .none,
                    output: .string(limit: 1024),
                    error: .string(limit: 1024)
                )
                let status: Int32 =
                    switch child.terminationStatus {
                    case .exited(let code): code
                    case .signaled(let signal): -signal
                    }
                return (status, child.standardOutput, child.standardError)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw DeviceToolsError.failed("The device did not answer the lockdown helper in time.")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw DeviceToolsError.failed("The lockdown helper did not run.")
            }
            return first
        }
        try Task.checkCancellation()
        return (result.0, result.1, result.2)
    }

    /// Contents/MacOS/LightTouchServices: Xcode embeds it in Debug and Release builds alike.
    public static var servicesHelper: String? { Bundled.tool("LightTouchServices") }
}
