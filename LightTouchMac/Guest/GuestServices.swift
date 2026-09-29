// Guest services without a shell (qemu-ios docs/archive/guest-services-plan.md, P2).
//
// Everything the app asks of a running iPod goes through the guest agent's
// typed v2 ops (contrib/it-agent/README.md): spawn with no shell, put/get,
// chown/unlink, sync, launch, frontmost, lockstatus, orientation, dlicon,
// halt. Stock lockdown services (installs, AFC, the time zone through the
// lockdown-tz child process) are DeviceServices (Services/).
//
// Capabilities come from the agent's ping: a v2 agent lists its ops; a v1
// agent (older images, which still carry freeze's /bin/sh) answers only its
// version, and each op it lacks falls back here to its `exec` with the same
// command a shell would have run. No SSH anywhere.
//
// Foundation only, so tests/drivers/session-driver compiles it as the app does.

import Foundation

enum AppLaunchError: Error {
    case locked, unavailable, failed

    func message(for profile: DeviceProfile) -> String {
        switch self {
        case .locked: "Unlock the \(profile.shortName), then try again."
        case .unavailable: "Wait for the \(profile.shortName) to finish starting, then try again."
        case .failed: "Try opening the app on the \(profile.shortName)."
        }
    }
}

/// The app's guest operations, over the agent.
nonisolated struct GuestServices: Sendable {
    let agent: GuestAgent
    /// True when the guest runs a package from the loader (a guest-package
    /// report arrived): its binaries are under `packageBin`.
    var packaged = false

    static let packageBin = "/usr/local/lighttouch/current/bin"
    static let launchctl = "/bin/launchctl"

    // MARK: Media

    /// Commit staged media into the library with itmedia (Music, Videos: a
    /// metadata plist) or itphoto (Saved Photos): the package's copy, or the
    /// app's uploaded to /tmp for the one run. The tool must end with `imported`.
    func commitMedia(id: String, helper: String, localHelper: () throws -> URL, metadata: URL?) async throws -> Bool {
        guard UUID(uuidString: id) != nil else { throw DeviceToolsError.failed("Invalid media staging identifier.") }
        try await agent.chown(501, 501, "/var/mobile/Media/LightTouch")
        try await agent.chown(501, 501, "/var/mobile/Media/LightTouch/\(id)")
        var temporary: [String] = []
        var arguments = [id]
        if let metadata {
            let remote = "/tmp/ltm-media-\(id).plist"
            try await agent.put(remote, mode: 0o644, try Data(contentsOf: metadata))
            temporary.append(remote)
            arguments.insert(remote, at: 0)
        }
        do {
            var output: Data?
            if packaged {
                do { output = try await agent.spawn(["\(Self.packageBin)/\(helper)"] + arguments) }
                catch let error as GuestAgentError where error.status == GuestAgentError.notFound { output = nil }
            }
            if output == nil {
                let executable = "/tmp/ltm-\(helper)-\(id)"
                try await agent.put(executable, mode: 0o755, try Data(contentsOf: localHelper()))
                temporary.append(executable)
                output = try await agent.spawn([executable] + arguments)
            }
            for path in temporary { try? await agent.unlink(path) }
            return String(decoding: output ?? Data(), as: UTF8.self).hasSuffix("imported\n")
        } catch {
            for path in temporary { try? await agent.unlink(path) }
            throw error
        }
    }

    // MARK: Trust

    /// Trust a CA in the guest's own trust store the way a profile install
    /// does, through securityd's API (ittrust: SecTrustStoreSetTrustSettings
    /// in the user domain), with no screen on the device. The package's copy,
    /// or the app's uploaded to /tmp for the one run. Idempotent; the store
    /// keeps it across boots, so nothing asks twice. ittrust adapts at runtime
    /// (dlopen), one source for both arches.
    func trustCertificate(_ der: Data, localTool: (String) throws -> Data) async throws {
        let cert = "/tmp/ltm-ca-\(UUID().uuidString).der"
        try await agent.put(cert, mode: 0o644, der)
        let output: String
        do { output = try await runTool("ittrust", ["add", cert], localTool: localTool) }
        catch { try? await agent.unlink(cert); throw error }
        try? await agent.unlink(cert)
        guard output.contains("Guest trust add: 0") else {
            throw DeviceToolsError.failed("The device did not accept the certificate: \(output)")
        }
    }

    /// The image's baked PAC (/usr/local/share/ltm/proxy.pac: every request to the web proxy guestfwd,
    /// DIRECT as fallback) routes the guest through the proxy. An image without it (the legacy iPod
    /// image) goes straight out through slirp, so the trusted CA never sees a request: itproxy points
    /// the Wi-Fi service's HTTP and HTTPS proxies at the guestfwd through configd (idempotent; it keeps
    /// a backup of the keys it owns). The host's "off" mode passes those connections straight through.
    func routeThroughProxy(localTool: (String) throws -> Data) async throws {
        guard try await agent.get(Self.proxyPAC) == nil else { return }
        let output = try await runTool("itproxy", ["on"], localTool: localTool)
        guard output.contains("Proxy enabled") else {
            throw DeviceToolsError.failed("The device did not accept the proxy setting: \(output)")
        }
    }

    static let proxyPAC = "/usr/local/share/ltm/proxy.pac"

    /// A guest tool's output: the package's copy, or the app's uploaded to /tmp for the one run.
    private func runTool(_ name: String, _ arguments: [String], localTool: (String) throws -> Data) async throws -> String {
        if packaged {
            do { return String(decoding: try await agent.spawn(["\(Self.packageBin)/\(name)"] + arguments), as: UTF8.self) }
            catch let error as GuestAgentError where error.status == GuestAgentError.notFound {}
        }
        let executable = "/tmp/ltm-\(name)-\(UUID().uuidString)"
        try await agent.put(executable, mode: 0o755, try localTool(name))
        let output: Data
        do { output = try await agent.spawn([executable] + arguments) }
        catch { try? await agent.unlink(executable); throw error }
        try? await agent.unlink(executable)
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: SpringBoard and launchd

    /// launchd's KeepAlive brings SpringBoard straight back.
    func respring() async throws { try await agent.spawn([Self.launchctl, "stop", "com.apple.SpringBoard"]) }

    /// launchd owns and relaunches lockdownd.
    func reconnectManagement() async throws { try await agent.spawn([Self.launchctl, "stop", "com.apple.mobile.lockdown"]) }

    /// SpringBoardServices' launch, the same path a tap on the icon takes. It
    /// refuses a locked device, which lockstatus then tells apart.
    func launch(_ bundleID: String) async throws {
        do { try await agent.launch(bundleID) }
        catch is CancellationError { throw CancellationError() }
        catch {
            logEvent("launch \(bundleID): \(error.localizedDescription)")
            if (try? await agent.isLocked()) == true { throw AppLaunchError.locked }
            throw AppLaunchError.failed
        }
    }

    func foregroundAppName() async throws -> String? {
        let name = try await agent.frontmost().name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(200))
    }
}
